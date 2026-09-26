// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {Registry} from "../Registry.sol";

/**
 * @title  TimelockOps
 * @notice Schedules, then executes after the 48h delay, the post-deploy admin batch on
 *         the Registry through NodTimelockController:
 *           - setAdapterWhitelist(adapter, true)   for each address in NOD_ADAPTERS
 *           - setSwapRouter(NOD_SWAP_ROUTER)       if set
 *           - grantRole(KEEPER_ROLE, NOD_REGISTRY_KEEPER)   if set
 *
 *         Must be broadcast by the timelock's proposer/executor (NOD_MULTISIG). With an
 *         EOA multisig (testnet) run it with --account; with a Safe, use the printed
 *         targets/payloads in the Safe transaction builder instead.
 *
 *         Addresses default to frontend/src/deployments/<chainId>.json written by
 *         DeployNod; "adapter" from that file is used when NOD_ADAPTERS is unset.
 *
 *         MODE=schedule  forge script contracts/script/TimelockOps.s.sol --rpc-url <rpc> --account <multisig> --broadcast
 *         (48 hours later, same environment)
 *         MODE=execute   forge script contracts/script/TimelockOps.s.sol --rpc-url <rpc> --account <multisig> --broadcast
 */
contract TimelockOps is Script {
    bytes32 internal constant DEFAULT_SALT = keccak256("nod-post-deploy-v1");

    function run() external {
        string memory file = string.concat("./frontend/src/deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(file);
        TimelockController timelock = TimelockController(payable(vm.parseJsonAddress(json, ".timelock")));
        Registry registry = Registry(vm.parseJsonAddress(json, ".registry"));

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _batch(registry, json);
        require(targets.length > 0, "TimelockOps: nothing to do");

        bytes32 salt = vm.envOr("NOD_TIMELOCK_SALT", DEFAULT_SALT);
        bytes32 id = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        string memory mode = vm.envOr("MODE", string("schedule"));

        for (uint256 i; i < targets.length; ++i) {
            console2.log("op", i, targets[i]);
            console2.logBytes(payloads[i]);
        }
        console2.log("operation id:");
        console2.logBytes32(id);

        vm.startBroadcast();
        if (keccak256(bytes(mode)) == keccak256("schedule")) {
            require(!timelock.isOperation(id), "TimelockOps: already scheduled (change NOD_TIMELOCK_SALT for a new batch)");
            timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, timelock.getMinDelay());
            console2.log("Scheduled. Executable after (unix):", timelock.getTimestamp(id));
        } else if (keccak256(bytes(mode)) == keccak256("execute")) {
            require(timelock.isOperationReady(id), "TimelockOps: not ready (still in the 48h delay, or not scheduled)");
            timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
            console2.log("Executed.");
        } else {
            revert("TimelockOps: MODE must be schedule or execute");
        }
        vm.stopBroadcast();
    }

    function _batch(Registry registry, string memory json)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        address[] memory adapters = vm.envOr("NOD_ADAPTERS", ",", new address[](0));
        if (adapters.length == 0 && vm.keyExistsJson(json, ".adapter")) {
            adapters = new address[](1);
            adapters[0] = vm.parseJsonAddress(json, ".adapter");
        }
        address router = vm.envOr("NOD_SWAP_ROUTER", address(0));
        address keeper = vm.envOr("NOD_REGISTRY_KEEPER", address(0));

        uint256 n = adapters.length + (router != address(0) ? 1 : 0) + (keeper != address(0) ? 1 : 0);
        targets = new address[](n);
        values = new uint256[](n);
        payloads = new bytes[](n);

        uint256 k;
        for (uint256 i; i < adapters.length; ++i) {
            targets[k] = address(registry);
            payloads[k++] = abi.encodeCall(Registry.setAdapterWhitelist, (adapters[i], true));
        }
        if (router != address(0)) {
            targets[k] = address(registry);
            payloads[k++] = abi.encodeCall(Registry.setSwapRouter, (router));
        }
        if (keeper != address(0)) {
            targets[k] = address(registry);
            payloads[k++] = abi.encodeWithSignature("grantRole(bytes32,address)", registry.KEEPER_ROLE(), keeper);
        }
    }
}
