# Rollup project architecture

This document covers the structure of this repository.

## High-Level Overview

Rollup repository consists of several applications:

- Rollup smart contract: a Solidity smart contract deployed on the Ethereum blockchain, which manages users' balances
  and verifies the correctness of operations performed within Rollup network.
- Prover application: a worker application that creates a proof for an executed block. Prover applications poll Server
  application for available jobs, and once there is a new block, server provides a witness (input data to generate a
  proof), and prover starts working. Once proof is generated, it is reported to the Server application, and Server
  publishes the proof to the smart contract. Prover application is considered an on-demand worker, thus it is OK to have
  many provers (if server load is high) or no provers at all (if there are no incoming transactions). Generating a proof
  is a very resource consuming work, thus machines that run a prover application must have a modern CPU and a lot of
  RAM.
- Server application: a node running the Rollup network. It is capable of following things:

  - Monitoring the smart contract for the onchain operations (such as deposits).
  - Accepting transactions.
  - Generating Rollup chain blocks.
  - Requesting proofs for executed blocks.
  - Publishing data to the smart contract.

  Server application exists in two available forms:

  - Monolithic application, which provides all the required functionality from one binary. This form is convenient for
    the development needs. Corresponding crate is `core/bin/server`.
  - Microservices applications, which are capable of working independently from each other:
    - `Core` service (`core/bin/Rollup_core`) maintains transactions memory pool and commits new blocks.
    - `API` service (`core/bin/Rollup_api`) provides a server "front-end": REST API & JSON RPC HTTP/WS implementations.
    - `Ethereum Sender` service (`core/bin/Rollup_eth_sender`) finalizes the blocks by sending corresponding Ethereum
      transactions to the L1 smart contract.
    - `Witness Generator` service (`core/bin/Rollup_witness_generator`) creates input data required for provers to prove
      blocks, and implements a private API server for provers to interact with.

Thus, in order to get a local Rollup setup running, the following has to be done:

- Rollup smart contract is compiled and deployed to the Ethereum.
- Rollup server is launched.
- At least one prover is launched and connected to the Server application.

## Low-Level Overview

This section provides an overview on folders / sub-projects that exist in this repository.

- `/bin`: Infrastructure scripts which help to work with Rollup applications.
- `/contracts`: Everything related to Rollup smart-contract.
  - `/contracts`: Smart contracts code
  - `/scripts` && `/src.ts`: TypeScript scripts for smart contracts management.
- `/core`: Code of the sub-projects that implement Rollup network.
  - `/bin`: Applications mandatory for Rollup network to operate.
    - `/server`: Rollup server application.
    - `/prover`: Rollup prover application.
    - `/data_restore`: Utility to restore a state of the Rollup network from a smart contract.
    - `/key_generator`: Utility to generate verification keys for network.
    - `/parse_pub_data`: Utility to parse Rollup operation pubdata.
    - `/Rollup_core`: Rollup server Core microservice.
    - `/Rollup_api`: Rollup server API microservice.
    - `/Rollup_eth_sender`: Rollup server Ethereum sender microservice.
    - `/Rollup_witness_generator`: Rollup server Witness Generator & Prover Server microservice.
  - `/lib`: Dependencies of the binaries above.
    - `/basic_types`: Crate with declaration of the essential Rollup primitives, such as `address`.
    - `/circuit`: Cryptographic environment enforsing the correctness of executed transactions in the Rollup network.
    - `/config`: Utilities to load configuration options of Rollup applications.
    - `/contracts`: Loaders for Rollup contracts interfaces and ABI.
    - `/crypto`: Cryptographical primitives using among Rollup crates.
    - `/eth_client`: Module providing an interface to interact with an Ethereum node.
    - `/prometheus_exporter`: Prometheus data exporter.
    - `/prover_utils`: Utilities related to the proof generation.
    - `/state`: A fast pre-circuit executor for Rollup transactions used on the Server level to generate blocks.
    - `/storage`: An encapsulated database interface.
    - `/types`: Rollup network operations, transactions and common types.
    - `/utils`: Miscellaneous helpers for Rollup crates.
    - `/vlog`: An utility library for verbose logging.
  - `/tests`: Testing infrastructure for Rollup network.
    - `/loadnext`: An application for highload testing of Rollup server.
    - `/test_account`: A representation of Rollup account which can be used for tests.
    - `/testkit`: A relatively low-level testing library and test suite for Rollup.
    - `/ts-tests`: Integration tests set implemented in TypeScript. Requires a running Server and Prover applications to
      operate.
- `/docker`: Dockerfiles used for development of Rollup and for packaging Rollup for a production environment.
- `/etc`: Configration files.
  - `/env`: `.env` files that contain environment variables for different configuration of Rollup Server / Prover.
  - `/js`: Configuration files for JavaScript applications (such as Explorer).
  - `/tokens`: Configuration of supported Ethereum ERC-20 tokens.
- `/infrastructure`: Application that aren't naturally a part of Rollup core, but are related to it.
- `/keys`: Verification keys for `circuit` module.
- `/sdk`: Implementation of client libraries for Rollup network in different programming languages.
  - `/Rollup-crypto`: Rollup network cryptographic primitives, which can be compiled to WASM.
  - `/Rollup.js`: A JavaScript / TypeScript client library for Rollup.
  - `/Rollup-rs`: Rust client library for Rollup.