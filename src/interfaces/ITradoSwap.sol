// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

/// @title Interface for LiquidityManager
interface ITradoSwap {
    struct SwapDesireParams {
        bytes path;
        address recipient;
        uint128 desire;
        uint256 maxPayed;
        // outFee / 10000 is feeTier
        // outFee must <= 500
        uint16 outFee;
        uint256 deadline;
    }

    /// @notice Swap given amount of target token, usually used in multi-hop case.
    function swapDesire(
        SwapDesireParams calldata params
    ) external payable returns (uint256 cost, uint256 acquire);
}
