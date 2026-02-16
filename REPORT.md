# Rollup Prototype Prover — Academic Report

---

## 1. Overview

This repository implements a **Layer 2 (L2) zero-knowledge rollup** scaling solution for Ethereum. The system batches thousands of off-chain transactions into compact cryptographic proofs that are verified on the Ethereum mainnet (Layer 1), dramatically reducing gas costs while inheriting L1 security guarantees. At its core, the architecture follows the **zkRollup** paradigm: transaction execution happens off-chain, but every state transition is accompanied by a validity proof (a zk-SNARK) that is verified by an on-chain smart contract.

The repository is structured around three principal applications:

| Application | Role |
|---|---|
| **Smart Contract** (Solidity) | Deployed on Ethereum L1; manages user balances, accepts deposits/withdrawals, and verifies zk-SNARK proofs of state transitions. |
| **Server** (Rust) | The L2 node that accepts transactions, executes them against an in-memory state, produces blocks, and coordinates proof generation and L1 submission. |
| **Prover** (Rust) | A stateless worker that receives block witnesses from the server, generates PLONK zk-SNARK proofs, and returns them for on-chain verification. |

Together, these components form a trustless pipeline: users submit transactions to the server, the server batches and executes them, the prover generates a cryptographic proof of correct execution, and the smart contract verifies the proof on Ethereum.

---

## 2. Components

### 2.1 Smart Contracts (`/contracts`)

The Solidity contracts are the trust anchor of the system. They are deployed on Ethereum L1 and fulfil three responsibilities:

- **Bridge**: Accept ETH and ERC-20 deposits (`depositETH`, `depositERC20`) and process withdrawals (`withdrawPendingBalance`).
- **Commitment**: Store block commitments consisting of the new state root, public data, and timestamp (`commitBlocks`).
- **Verification**: Verify PLONK proofs submitted by the operator and, upon success, execute blocks to finalise pending withdrawals (`executeBlocks`).

Key contracts include `Rollup.sol` (main entry point), `Verifier.sol` (PLONK proof verification), `Governance.sol` (token whitelisting and validator management), `Storage.sol` (on-chain state variables), and `Operations.sol` (encoding/decoding of operation public data).

### 2.2 Server (`/core/bin/server`)

The server is the L2 node. It can run either as a **monolithic** binary or as a set of independent **microservices**:

| Microservice | Crate | Responsibility |
|---|---|---|
| Core | `rollup_core` | Maintains the mempool; produces blocks by executing transactions against the state. |
| API | `rollup_api` | Exposes REST, JSON-RPC, and WebSocket APIs for clients. |
| Ethereum Sender | `rollup_eth_sender` | Signs and submits commit/execute/proof transactions to L1. |
| Witness Generator | `rollup_witness_generator` | Generates circuit witness data for each block and serves it to provers via a private API. |

On startup, the server initialises a database connection pool, launches the Ethereum watcher (to track L1 deposits and confirmations), starts the signature checker, fee ticker, state keeper, and API servers, and runs them concurrently with coordinated shutdown.

### 2.3 Core Libraries (`/core/lib`)

| Library | Purpose |
|---|---|
| `types` | Defines all domain types: `Account`, `ZkSyncTx` (Transfer, Withdraw, ChangePubKey, ForcedExit, Swap, MintNFT), `ZkSyncOp`, `Block`, and account update variants. |
| `state` | Fast pre-circuit transaction executor. Maintains an in-memory sparse Merkle tree (`AccountTree`) and applies transactions via `TxHandler`, producing `AccountUpdates`. |
| `storage` | PostgreSQL abstraction using SQLx. Schemas for blocks, accounts, executed transactions, prover jobs, token metadata, and Merkle tree cache. |
| `circuit` | The PLONK arithmetic circuit that encodes the rules of every supported operation (Transfer, Deposit, Withdraw, etc.) as algebraic constraints over BN256. |
| `crypto` | Cryptographic primitives: EdDSA signatures over the JubJub curve, Rescue and Poseidon hash functions, sparse Merkle trees, and PLONK proof/verification key types. |
| `prover_utils` | Utilities for proof generation, setup caching, verification key management, and recursive proof aggregation. |
| `eth_client` | Interface to an Ethereum node for reading events and submitting transactions. |
| `config` | Typed configuration loading from environment variables. |

### 2.4 Prover (`/core/bin/prover`)

The prover is a **stateless, horizontally-scalable worker** application. It polls the server for proof jobs, generates zk-SNARK proofs, and returns them. Multiple provers can run in parallel to handle high throughput. A detailed analysis follows in Section 4.

---

## 3. Steps — End-to-End Transaction Flow

The following describes the life cycle of a transaction from user submission to on-chain finality.

### Step 1 — Transaction Submission

A user constructs a signed L2 transaction (e.g., `Transfer`) using the client SDK and submits it to the server's API (REST or JSON-RPC).

### Step 2 — Signature Verification & Mempool

The server's `SignatureChecker` verifies the EdDSA signature. If valid, the transaction is placed in the **mempool** (`mempool_txs` table in PostgreSQL).

### Step 3 — Block Production (State Keeper)

The **State Keeper** periodically drains the mempool and accumulates transactions into a new block. For each transaction, it invokes the `TxHandler` on the in-memory `ZkSyncState`:

1. Validate nonces, balances, and permissions.
2. Apply debits/credits to the sparse Merkle tree.
3. Collect the resulting `AccountUpdates` and fees.
4. Once the block reaches the configured chunk size or a timeout expires, the block is **sealed**.

The sealed block records the new Merkle root (`new_state_root`), the list of executed operations, and the encoded public data.

### Step 4 — Persistence

The `StorageProcessor` persists the block, executed transactions, and account updates to PostgreSQL. The Merkle tree cache is also updated for efficient future reconstruction.

### Step 5 — L1 Commitment

The **Ethereum Sender** constructs an L1 transaction containing the block commitment (block number, new state root, public data hash, timestamp) and submits it to the Rollup smart contract's `commitBlocks` function.

### Step 6 — Witness Generation

The **Witness Generator** loads the committed block from the database, reconstructs the circuit account tree (using cached nodes), and builds the **block witness** — a `ProverData` structure containing all inputs the circuit needs to re-derive the state transition:

- Previous and new Merkle roots.
- Per-operation data: sender/receiver account states, Merkle proofs (authentication paths), signatures, amounts, token IDs.
- Validator (fee) account state.
- Public data commitment.

The witness is serialised and stored in the `prover_jobs` table as a pending job.

### Step 7 — Proof Generation (Prover)

The prover polls the server's `/get_job` endpoint. Upon receiving a job, it:

1. Deserialises the witness into a `ZkSyncCircuit`.
2. Transpiles the circuit to obtain PLONK step hints.
3. Loads or computes the PLONK setup (cached per block size).
4. Generates a **PLONK proof** using `prove_by_steps`.
5. Verifies the proof locally against the verification key.
6. Returns the `SingleProof` to the server via `/publish`.

For batches of blocks, an **aggregated proof** is generated by recursively combining multiple `SingleProof` values into one `AggregatedProof` using a recursive aggregation circuit.

### Step 8 — On-Chain Verification & Execution

The server submits the proof to the smart contract. The `Verifier.sol` contract checks the PLONK proof against the previously committed state root. If verification succeeds, `executeBlocks` processes any pending on-chain operations (e.g., withdrawal credits), finalising the block.

### Step 9 — Finality

Once executed on L1, the state transition is final. Users can withdraw their funds from the smart contract or continue transacting on L2.

---

## 4. The Prover — Deep Dive

### 4.1 Architecture

The prover is a standalone binary (`core/bin/prover`) that runs independently of the server. Its design priorities are:

- **Statelessness**: The prover holds no persistent state; all inputs come from the server.
- **Horizontal scalability**: Many provers can run concurrently; each polls for and processes one job at a time.
- **Fault tolerance**: Heartbeats keep the server informed; if a prover dies, its job is reassigned.

### 4.2 Key Abstractions

```
┌──────────────────────────────────────────────┐
│  ProverImpl (trait)                          │
│  ├─ create_proof(JobRequestData) → Result    │
│  ├─ get_request_aux_data() → metadata        │
│  └─ create_from_config(ProverConfig) → Self  │
├──────────────────────────────────────────────┤
│  ApiClient (trait)                           │
│  ├─ get_job() → ProverInputResponse          │
│  ├─ working_on(job_id) → ()     [heartbeat] │
│  ├─ publish(job_id, proof) → ()              │
│  └─ prover_stopped() → ()                   │
├──────────────────────────────────────────────┤
│  ShutdownRequest                             │
│  └─ Atomic flags for graceful shutdown       │
└──────────────────────────────────────────────┘
```

- **`ProverImpl`** — Trait defining the proof computation. The concrete implementation is `PlonkStepByStepProver`, which wraps the PLONK proving pipeline.
- **`ApiClient`** — Async trait for communicating with the server over HTTP. Uses JWT bearer tokens for authentication and exponential-backoff retries for resilience.
- **`ShutdownRequest`** — Thread-safe shutdown coordination using atomic flags.

### 4.3 Job Types

The prover handles two kinds of jobs, represented by the `JobRequestData` enum:

| Variant | Input | Output |
|---|---|---|
| `BlockProof(ProverData, block_size)` | Circuit witness for a single block. | `SingleProof` — a PLONK proof. |
| `AggregatedBlockProof(Vec<SingleProof>)` | A vector of previously generated single proofs. | `AggregatedProof` — a recursively aggregated proof. |

### 4.4 Proof Generation Pipeline

#### 4.4.1 Single Block Proof

```
ProverData (witness)
       │
       ▼
 Deserialise into ZkSyncCircuit<Bn256>
       │
       ▼
 Transpile circuit → PLONK step hints
       │
       ▼
 Setup (or load cached) → SetupPolynomials
       │
       ▼
 Load Verification Key for block_size
       │
       ▼
 prove_by_steps(circuit, setup, VK, transcript)
       │
       ▼
 Local verification (verify against VK)
       │
       ▼
 Return SingleProof
```

**Key details:**

- The **circuit** (`ZkSyncCircuit`) encodes every operation type (Transfer, Deposit, Withdraw, Swap, MintNFT, etc.) as algebraic constraints over the BN256 scalar field (`Fr`). Each operation contributes constraints that enforce correct balance updates, signature validity, and Merkle path consistency.
- **Transpilation** converts the circuit into PLONK-compatible gate hints, enabling the step-by-step proving strategy.
- The **setup** consists of precomputed polynomials derived from the Universal CRS (Common Reference String). Setups are cached per block size (the number of operation chunks in a block), because the circuit size varies.
- **`prove_by_steps`** is the core PLONK proving function. It splits the large proof computation into manageable stages to control peak memory usage.
- After generation, the proof is **locally verified** to catch bugs before submission.

#### 4.4.2 Aggregated Proof (Recursive)

When multiple blocks have been individually proved, their proofs are combined into one **aggregated proof** using a recursive PLONK circuit:

```
Vec<SingleProof>
       │
       ▼
 Pad with sample proofs to fixed aggregation size
       │
       ▼
 Load all Verification Keys (one per block size)
       │
       ▼
 Extract VK inputs and map proofs to VK indices
       │
       ▼
 create_zksync_recursive_aggregate(proofs, VKs)
   → Aggregate G1 commitment points
       │
       ▼
 proof_recursive_aggregate_for_zksync()
   → Generate PLONK proof over recursive circuit
       │
       ▼
 Local verification
       │
       ▼
 Return AggregatedProof {
     proof,
     individual_vk_inputs,
     individual_vk_idxs,
     aggr_limbs (G1 elements)
 }
```

Aggregation amortises L1 verification gas costs: instead of verifying N separate proofs on-chain, only one aggregated proof is verified.

### 4.5 Cryptographic Primitives

| Primitive | Usage |
|---|---|
| **BN256 (alt-bn128)** | Ethereum-compatible elliptic curve for pairing-based proofs. All circuit arithmetic operates over its scalar field `Fr`. |
| **PLONK** | The proof system. Uses a universal trusted setup (powers-of-tau CRS) and supports circuits of varying sizes. |
| **JubJub (Baby JubJub)** | Twisted Edwards curve embedded in BN256. Used for EdDSA signatures on L2 transactions, verified inside the circuit. |
| **Rescue Hash** | ZK-friendly algebraic hash function used for Merkle tree hashing and transcript generation inside circuits. |
| **Poseidon Hash** | Alternative ZK-friendly hash, used alongside Rescue. |
| **Keccak-256** | Used for public data commitment hashing (outside circuits) and Ethereum compatibility. |
| **Sparse Merkle Tree** | Stores all account states. Depth is 32, supporting up to 2³² accounts. The hasher is `BabyRescueHasher`. |

### 4.6 Communication Protocol

The prover communicates with the server over HTTP using a simple polling protocol:

```
┌────────┐                              ┌────────┐
│ Prover │                              │ Server │
└───┬────┘                              └───┬────┘
    │                                       │
    │  GET /get_job                          │
    │  (ProverInputRequest)                  │
    │ ─────────────────────────────────────► │
    │                                       │
    │  ProverInputResponse                  │
    │  { job_id, data: JobRequestData }     │
    │ ◄───────────────────────────────────── │
    │                                       │
    │  ┌──────────────────────────────┐     │
    │  │ Generate proof (CPU-heavy)   │     │
    │  │                              │     │
    │  │  POST /working_on            │     │
    │  │  (heartbeat every 3-6s)      │     │
    │  │ ─────────────────────────────┼──►  │
    │  │                              │     │
    │  └──────────────────────────────┘     │
    │                                       │
    │  POST /publish                        │
    │  (ProverOutputRequest with proof)     │
    │ ─────────────────────────────────────► │
    │                                       │
```

- **Authentication**: JWT bearer tokens with a shared secret (10-second lifetime).
- **Retry strategy**: Exponential backoff — initial 1 s, multiplier 1.5×, max interval 10 s, max elapsed 2 min.
- **Heartbeats**: Sent every 3–6 seconds (randomised) in a concurrent async task to prevent the server from reassigning the job.
- **Shutdown**: On graceful shutdown, the prover sends `POST /stopped` to release any held jobs.

### 4.7 Performance Optimisations

- **Setup caching**: PLONK setup polynomials are cached per block size, avoiding expensive recomputation.
- **Sample proofs**: Precomputed dummy proofs are used to pad aggregation batches to a fixed size, simplifying the recursive circuit.
- **Witness caching**: The witness generator caches the circuit account tree across consecutive blocks, replaying only incremental updates.
- **Async + threading**: Tokio async handles I/O (polling, heartbeats), while proof generation runs on a dedicated OS thread to avoid blocking the async runtime.
- **Parallel witness generation**: Multiple `WitnessGenerator` threads process interleaved blocks concurrently.

---

## 5. Conclusion

This repository implements a complete **zkRollup** stack — from Solidity smart contracts on Ethereum L1 to a Rust-based L2 server and prover. The architecture cleanly separates concerns:

- The **smart contract** provides the trust root: it holds funds, verifies proofs, and enforces data availability.
- The **server** orchestrates transaction execution, block production, witness generation, and L1 interaction. Its microservice-capable design supports both development convenience (monolith) and production scalability (independent services).
- The **prover** is a stateless, horizontally-scalable worker whose sole purpose is transforming block witnesses into PLONK proofs. Its use of recursive proof aggregation further reduces on-chain verification costs.

The cryptographic backbone — PLONK proofs over BN256, EdDSA signatures over JubJub, and Rescue-hashed sparse Merkle trees — is specifically chosen for Ethereum compatibility and ZK-circuit efficiency. The system achieves scalability by moving transaction execution off-chain while preserving L1-grade security through validity proofs, embodying the core promise of zero-knowledge rollups.

---

*Report generated from the `rollup-prototype-prover` repository.*
