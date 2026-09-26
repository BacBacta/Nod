// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ILaunchpadAdapter} from "./ILaunchpadAdapter.sol";

/**
 * @title  IBullcheeseLaunchpad
 * @notice Minimal interface used by BullcheeseAdapter to query token metadata from the
 *         Bullcheese launchpad contract.  Replace with the real ABI once available.
 */
interface IBullcheeseLaunchpad {
    /**
     * @notice Returns the immutable fee-recipient address set at token creation.
     * @param  token  The launched token address.
     * @return recipient  The address that receives trading fees for this token.
     */
    function feeRecipientOf(address token) external view returns (address recipient);

    /**
     * @notice Returns true if fee recipient is locked immutable for `token`.
     */
    function isFeeRecipientLocked(address token) external view returns (bool);
}

/**
 * @title  BullcheeseAdapter
 * @notice Concrete ILaunchpadAdapter implementation for the Bullcheese memecoin
 *         launchpad on Arc Testnet.
 *
 * @dev    STUB — `feeRecipientOf` is the assumed Bullcheese function name.  Update the
 *         `IBullcheeseLaunchpad` interface and the `launchpad` address once the real
 *         contract is deployed and its ABI is confirmed.
 *
 *         Bullcheese sets the fee recipient immutably at token-creation time, so we
 *         treat a matching address as sufficient proof that it cannot be changed.  If
 *         the real contract ever adds a setter, this adapter must be replaced and
 *         re-whitelisted via the timelock before it can be used for new registrations.
 */
contract BullcheeseAdapter is ILaunchpadAdapter {
    // ─── Errors ─────────────────────────────────────────────────────────────────

    /// @notice Reverts if the Bullcheese launchpad address is zero.
    error ZeroLaunchpadAddress();

    // ─── State ───────────────────────────────────────────────────────────────────

    /// @notice The Bullcheese launchpad contract this adapter queries.
    IBullcheeseLaunchpad public immutable launchpad;

    // ─── Constructor ─────────────────────────────────────────────────────────────

    /**
     * @param _launchpad  Address of the deployed Bullcheese launchpad contract.
     */
    constructor(address _launchpad) {
        if (_launchpad == address(0)) revert ZeroLaunchpadAddress();
        launchpad = IBullcheeseLaunchpad(_launchpad);
    }

    // ─── ILaunchpadAdapter ───────────────────────────────────────────────────────

    /**
     * @inheritdoc ILaunchpadAdapter
     * @dev Returns true iff the launchpad reports `vault` as the fee recipient for
     *      `token`.  The assumption is that Bullcheese sets this immutably at launch.
     */
    function verifyFeeRecipient(address token, address vault)
        external
        view
        override
        returns (bool)
    {
        if (launchpad.feeRecipientOf(token) != vault) return false;
        if (!launchpad.isFeeRecipientLocked(token)) return false;
        return true;
    }
}
