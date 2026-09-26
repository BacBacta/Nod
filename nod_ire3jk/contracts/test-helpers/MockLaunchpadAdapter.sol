// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ILaunchpadAdapter} from "../ILaunchpadAdapter.sol";
import {MockLaunchpad} from "./MockLaunchpad.sol";

/// @notice Push-model adapter for tests and local dev: the launchpad sends fees to a
///         fee recipient fixed (and locked) at launch.
contract MockLaunchpadAdapter is ILaunchpadAdapter {
    MockLaunchpad public immutable launchpad;

    constructor(address _launchpad) {
        launchpad = MockLaunchpad(_launchpad);
    }

    function verifyFeeRecipient(address token, address vault) external view returns (bool) {
        return launchpad.feeRecipientOf(token) == vault && launchpad.isFeeRecipientLocked(token);
    }

    function feeSource(address) external pure returns (address) {
        return address(0);
    }

    function usdcPool(address) external pure returns (address) {
        return address(0);
    }
}
