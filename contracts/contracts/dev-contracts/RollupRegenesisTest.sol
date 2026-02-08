// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.7.0;

pragma experimental ABIEncoderV2;

import "../rollup.sol";
//import "../Additionalrollup.sol";

contract RollupRegenesisTest is Rollup {
    function getStoredBlockHash() external view returns (bytes32) {
        require(totalBlocksCommitted == totalBlocksProven, "wq1"); // All the blocks must be processed
        require(totalBlocksCommitted == totalBlocksExecuted, "w12"); // All the blocks must be processed

        return storedBlockHashes[totalBlocksExecuted];
    }

    function getAdditionalRollup() external view returns (AdditionalRollup) {
        return additionalRollup;
    }
}
