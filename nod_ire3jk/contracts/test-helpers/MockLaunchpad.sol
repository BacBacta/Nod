// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title MockLaunchpad
 * @notice Mock implementation of IBullcheeseLaunchpad for testing.
 */
contract MockLaunchpad {
    mapping(address => address) public feeRecipients;
    mapping(address => bool) public locked;

    function setFeeRecipient(address token, address recipient) external {
        feeRecipients[token] = recipient;
    }

    function setLocked(address token, bool isLocked) external {
        locked[token] = isLocked;
    }

    function feeRecipientOf(address token) external view returns (address) {
        return feeRecipients[token];
    }

    function isFeeRecipientLocked(address token) external view returns (bool) {
        return locked[token];
    }
}
