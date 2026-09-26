// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  ILaunchpadAdapter
 * @notice Adapter interface that each supported launchpad must implement.
 *         The Registry calls `verifyFeeRecipient` during token registration to confirm
 *         that (a) the token's fee-recipient address is already set to the provided vault
 *         AND (b) the launchpad does not allow the fee recipient to be changed after the
 *         fact.  Both conditions must hold for the function to return true.
 *
 * @dev    Implementations MUST be view functions — no state changes, no ETH sent.
 *         The Registry whitelists adapter addresses before any call is made, so only
 *         admin-approved implementations can be used.
 */
interface ILaunchpadAdapter {
    /**
     * @notice Check that `token`'s fee recipient on this launchpad is `vault` and is
     *         immutably locked to that address.
     * @param  token  Address of the launched token.
     * @param  vault  Address of the FeeVault that should be the fee recipient.
     * @return true if and only if the fee recipient is `vault` and cannot be changed.
     */
    function verifyFeeRecipient(address token, address vault)
        external
        view
        returns (bool);
}
