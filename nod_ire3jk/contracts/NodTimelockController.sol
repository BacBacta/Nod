// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title NodTimelockController
 * @notice Thin wrapper around OpenZeppelin's TimelockController with a 48-hour minimum
 *         delay. This contract is the DEFAULT_ADMIN of every other Nod contract after
 *         the bootstrap sequence, so all privileged parameter changes go through it.
 *
 * @dev    Deployer passes the multisig address as the sole proposer AND executor so the
 *         multisig is the only entity that can queue, cancel, and execute operations.
 *         The admin role is renounced by the TimelockController itself in its
 *         constructor, so no EOA retains admin powers after deployment.
 */
contract NodTimelockController is TimelockController {
    /// @notice The minimum delay enforced by this timelock (48 hours).
    uint256 public constant MIN_DELAY = 48 hours;

    /**
     * @notice Deploy the timelock.
     * @param multisig  Address of the Nod multisig.  Receives both PROPOSER_ROLE and
     *                  EXECUTOR_ROLE.  Must be non-zero.
     */
    constructor(address multisig)
        TimelockController(
            MIN_DELAY,
            _toArray(multisig),  // proposers
            _toArray(multisig),  // executors
            address(0)           // no additional admin — TimelockController becomes its own admin
        )
    {}

    // ─── Helpers ────────────────────────────────────────────────────────────────

    function _toArray(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }
}
