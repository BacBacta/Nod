// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  ILaunchpadAdapter
 * @notice Adapter interface that each supported launchpad must implement.
 *
 *         Two fee models are supported:
 *         - Push: the launchpad sends fees to a fee-recipient address fixed at launch.
 *           `feeSource` returns address(0) and `verifyFeeRecipient` checks that the
 *           recipient is the vault and cannot change.
 *         - Pull (e.g. Bullcheese): fees accrue to whoever owns a per-token contract
 *           (an LP locker). The owner transfers it to the vault (two-step ownership);
 *           at registration the Registry makes the vault accept it, then
 *           `verifyFeeRecipient` checks that the vault is the owner.
 *
 * @dev    All functions MUST be views. The Registry only calls whitelisted adapters.
 */
interface ILaunchpadAdapter {
    /**
     * @notice True iff `vault` receives `token`'s creator fees and that cannot be changed
     *         by anyone else.
     */
    function verifyFeeRecipient(address token, address vault) external view returns (bool);

    /**
     * @notice Pull model: the Ownable2Step contract the vault must accept at registration
     *         and later call `collectFees()` on. address(0) for push launchpads.
     */
    function feeSource(address token) external view returns (address);

    /**
     * @notice Uniswap v3 pool pairing `token` with USDC, used to convert fees paid in the
     *         token into USDC. address(0) if fees are only ever paid in USDC.
     */
    function usdcPool(address token) external view returns (address);
}
