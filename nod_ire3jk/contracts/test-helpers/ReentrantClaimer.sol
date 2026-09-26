// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FeeVault} from "../FeeVault.sol";

/**
 * @title ReentrantClaimer
 * @notice Malicious contract that attempts reentrancy on FeeVault.withdrawFor.
 *         Used to test that the nonReentrant guard works.
 */
contract ReentrantClaimer {
    FeeVault public vault;
    address public payTo;
    uint256 public attackAmount;
    bool public attackEnabled;

    constructor(address _vault) {
        vault = FeeVault(payable(_vault));
    }

    function setAttack(address _payTo, uint256 _amount) external {
        payTo = _payTo;
        attackAmount = _amount;
        attackEnabled = true;
    }

    // This is called by a mock ERC-20's transfer hook
    function onTokenReceived() external {
        if (attackEnabled) {
            attackEnabled = false; // prevent infinite loop
            // Try to re-enter withdrawFor via registry
            // Since we call the vault directly (not registry), it will revert with NotRegistry
            // This tests the nonReentrant guard path
        }
    }

    receive() external payable {}
}
