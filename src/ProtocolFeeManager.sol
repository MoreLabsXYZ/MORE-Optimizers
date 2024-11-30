// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable, OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

contract ProtocolFeeManager is Initializable, Ownable2StepUpgradeable {
    uint256 public constant MAX_FEE = 1e18;

    mapping(address => uint96) private protocolFee;
    address private protocolFeeRecipient;

    error ZeroAddress();
    error MaxFeeExceeded();

    event SetProtocolFeeRecipient(address indexed protocolFeeRecipient);
    event SetProtocolFee(address indexed strategy, uint256 indexed protocolFee);

    function initialize(address owner) external initializer {
        __Ownable_init(owner);
    }

    function setProtocolFeeRecipient(
        address _protocolFeeRecipient
    ) external onlyOwner {
        if (_protocolFeeRecipient == address(0)) {
            revert ZeroAddress();
        }

        protocolFeeRecipient = _protocolFeeRecipient;

        emit SetProtocolFeeRecipient(_protocolFeeRecipient);
    }

    function setProtocolFee(
        address strategy,
        uint256 _protocolFee
    ) external onlyOwner {
        if (_protocolFee > MAX_FEE) {
            revert MaxFeeExceeded();
        }
        protocolFee[strategy] = uint96(_protocolFee);

        emit SetProtocolFee(strategy, _protocolFee);
    }

    function getProtocolFeeInfo(
        address strategy
    ) external view returns (uint96, address) {
        return (protocolFee[strategy], protocolFeeRecipient);
    }
}
