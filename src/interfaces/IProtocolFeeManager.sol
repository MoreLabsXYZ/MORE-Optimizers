// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

/// @title Interface for ProtocolFeeManager
interface IProtocolFeeManager {
    function initialize(address owner) external;

    function setProtocolFeeRecipient(address _protocolFeeRecipient) external;

    function setProtocolFee(address strategy, uint256 _protocolFee) external;

    function getProtocolFeeInfo(
        address strategy
    ) external view returns (uint96, address);
}
