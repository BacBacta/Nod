// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {NodTimelockController} from "../NodTimelockController.sol";
import {FeeVaultFactory}       from "../FeeVaultFactory.sol";
import {IdentityAttestor}      from "../IdentityAttestor.sol";
import {Registry}              from "../Registry.sol";
import {PayoutRouter}          from "../PayoutRouter.sol";
import {BuybackModule}         from "../BuybackModule.sol";

/**
 * @title  DeployNod
 * @notice Foundry deployment script for the Nod creator-fee routing protocol on
 *         Arc Testnet (chain ID 5042002).
 *
 * @dev     Pre-requisites 
 *         Set the following environment variables before running:
 *
 *           NOD_MULTISIG        — Gnosis Safe (or EOA for testnet) that will hold
 *                                  PROPOSER + EXECUTOR roles on the TimelockController.
 *           NOD_ATTESTER        — Key that signs EIP-712 identity attestations
 *                                  (ATTESTER_ROLE on IdentityAttestor).
 *           NOD_PAUSER          — Address granted PAUSER_ROLE on both IdentityAttestor
 *                                  and Registry.
 *           NOD_KEEPER          — Address granted KEEPER_ROLE on BuybackModule
 *                                  (keeper bot).
 *           NOD_TREASURY        — Protocol treasury address (receives 50% of protocol
 *                                  fee).  Must NOT be a vault or buyback module.
 *           NOD_FALLBACK1       — First whitelisted fallback recipient (charity /
 *                                  community wallet).  At least one must be set at
 *                                  deploy.
 *           NOD_DEPOSIT_CAP     — Initial per-vault beta deposit cap in raw USDC units
 *                                  (6-decimal).  E.g. "10000000000" = 10,000 USDC.
 *                                  Pass "0" for no cap.
 *           NOD_PROTOCOL_FEE    — Initial protocol fee in basis points.  E.g. "1000"
 *                                  = 10%.  Must be ≤ 1500.
 *
 *         The deployer key is NOT read from the environment.  Import it once into an
 *         encrypted Foundry keystore and pass it with --account:
 *           cast wallet import nod-deployer --interactive
 *
 *          Running 
 *         forge script contracts/script/DeployNod.s.sol \
 *           --rpc-url https://rpc.testnet.arc.io \
 *           --account nod-deployer \
 *           --broadcast \
 *           --verify \
 *           --with-gas-price 20000000000 \
 *           -vvvv
 *
 *          Bootstrap sequence 
 *         After deployment the script:
 *           1.  Deploys NodTimelockController (multisig is proposer + executor).
 *           2.  Deploys FeeVaultFactory (deployer is temporary admin).
 *           3.  Deploys IdentityAttestor (deployer is temporary DEFAULT_ADMIN).
 *           4.  Deploys BuybackModule (starts disabled, nodToken = address(0)).
 *           5.  Deploys Registry (deployer is temporary DEFAULT_ADMIN).
 *           6.  Deploys PayoutRouter (deployer is DEFAULT_ADMIN).
 *           7.  Wires: factory.setRegistry, registry grants PAYOUT_ROUTER_ROLE.
 *           8.  Checks the initial fallback (whitelisted by the Registry constructor).
 *           9.  Grants DEFAULT_ADMIN_ROLE of Registry + IdentityAttestor to timelock,
 *               then deployer renounces DEFAULT_ADMIN_ROLE on both.
 *          10.  Prints all addresses for AGENTS.md.
 *
 *         IMPORTANT: After deployment, the multisig (NOD_MULTISIG) must queue a
 *         TimelockController operation (min 48h delay) to add any adapter to the
 *         whitelist and to set $NOD token on BuybackModule.
 */
contract DeployNod is Script {

    //  Arc Testnet constants 

    /// @dev USDC on Arc Testnet — the native gas token IS this ERC-20 (6 decimals).
    address public constant ARC_USDC = 0x3600000000000000000000000000000000000000;

    /// @dev Arc Testnet chain ID.
    uint256 public constant ARC_TESTNET_CHAIN_ID = 5042002;

    //  BuybackModule defaults 

    /// @dev Uniswap V3 router on Arc (placeholder — set via timelock once pool exists).
    address public constant UNISWAP_ROUTER_PLACEHOLDER = address(0);

    /// @dev Default Uniswap V3 pool fee tier (0.3%).
    uint24  public constant DEFAULT_POOL_FEE = 3000;

    /// @dev Default max buyback slippage (1%).
    uint256 public constant DEFAULT_MAX_SLIPPAGE_BPS = 100;

    /// @dev Default schedule interval between buybacks (7 days).
    uint256 public constant DEFAULT_SCHEDULE_INTERVAL = 7 days;

    //  Entry point 

    function run() external {
        //  Validate chain 
        require(
            block.chainid == ARC_TESTNET_CHAIN_ID,
            "DeployNod: wrong chain - Arc Testnet only (chain ID 5042002)"
        );

        //  Load environment 
        address multisig   = vm.envAddress("NOD_MULTISIG");
        address attester   = vm.envAddress("NOD_ATTESTER");
        address pauser     = vm.envAddress("NOD_PAUSER");
        address keeper     = vm.envAddress("NOD_KEEPER");
        address treasury   = vm.envAddress("NOD_TREASURY");
        address fallback1  = vm.envAddress("NOD_FALLBACK1");
        uint256 depositCap = vm.envUint("NOD_DEPOSIT_CAP");
        uint16  feeBps     = uint16(vm.envUint("NOD_PROTOCOL_FEE"));

        _requireNonZero(multisig,  "NOD_MULTISIG");
        _requireNonZero(attester,  "NOD_ATTESTER");
        _requireNonZero(pauser,    "NOD_PAUSER");
        _requireNonZero(keeper,    "NOD_KEEPER");
        _requireNonZero(treasury,  "NOD_TREASURY");
        _requireNonZero(fallback1, "NOD_FALLBACK1");
        require(feeBps <= 1500, "DeployNod: NOD_PROTOCOL_FEE must be <= 1500 bps");

        // Signer comes from --account (encrypted keystore); never from env vars.
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        console2.log("=== Nod Protocol Deployment - Arc Testnet ===");
        console2.log("Deployer:  ", deployer);
        console2.log("Multisig:  ", multisig);
        console2.log("Treasury:  ", treasury);
        console2.log("Fallback1: ", fallback1);
        console2.log("DepCap:    ", depositCap);
        console2.log("FeeBps:    ", feeBps);

        //  Step 1: NodTimelockController 
        NodTimelockController timelock = new NodTimelockController(multisig);
        console2.log("[1] NodTimelockController:", address(timelock));

        //  Step 2: FeeVaultFactory 
        //    deployer is the temporary admin; used only to call setRegistry below.
        FeeVaultFactory factory = new FeeVaultFactory(
            deployer,      // admin (will call setRegistry then not needed again)
            ARC_USDC,
            depositCap
        );
        console2.log("[2] FeeVaultFactory:      ", address(factory));

        //  Step 3: IdentityAttestor 
        IdentityAttestor attestor = new IdentityAttestor(
            deployer,  // temporary DEFAULT_ADMIN (handed off to timelock below)
            attester,
            pauser
        );
        console2.log("[3] IdentityAttestor:     ", address(attestor));

        //  Step 4: BuybackModule 
        //    nodToken = address(0) → accumulate mode until set via timelock.
        //    swapRouter = placeholder → set via timelock once Uniswap pool exists.
        //    disabled = true at construction (hardcoded in contract).
        BuybackModule buyback = new BuybackModule(
            ARC_USDC,
            address(timelock),
            UNISWAP_ROUTER_PLACEHOLDER,  // placeholder — update via timelock
            DEFAULT_POOL_FEE,
            DEFAULT_MAX_SLIPPAGE_BPS,
            DEFAULT_SCHEDULE_INTERVAL,
            deployer,  // temporary admin
            keeper
        );
        console2.log("[4] BuybackModule:        ", address(buyback));

        //  Step 5: Registry 
        Registry registry = new Registry(
            ARC_USDC,
            address(factory),
            address(attestor),
            treasury,
            address(buyback),
            address(timelock),  // timelock immutable reference
            deployer,           // temporary DEFAULT_ADMIN
            pauser,
            feeBps,
            fallback1           // initial whitelisted fallback recipient
        );
        console2.log("[5] Registry:             ", address(registry));

        //  Step 6: PayoutRouter 
        PayoutRouter router = new PayoutRouter(
            address(registry),
            address(attestor),
            ARC_USDC,
            deployer   // DEFAULT_ADMIN (no critical privileges beyond deployment)
        );
        console2.log("[6] PayoutRouter:         ", address(router));

        //  Step 7: Wiring 
        //    7a. Wire factory → registry (one-time, admin-gated)
        factory.setRegistry(address(registry));
        console2.log("[7a] factory.setRegistry done");

        //    7b. Grant PAYOUT_ROUTER_ROLE on Registry to the PayoutRouter
        bytes32 PAYOUT_ROUTER_ROLE = keccak256("PAYOUT_ROUTER_ROLE");
        registry.grantRole(PAYOUT_ROUTER_ROLE, address(router));
        console2.log("[7b] PAYOUT_ROUTER_ROLE granted to PayoutRouter");

        //  Step 8: Initial fallback whitelist 
        //    Set by the Registry constructor (setFallbackWhitelist is timelock-only).
        //    Additional fallback addresses can be added later via timelock.
        require(registry.whitelistedFallback(fallback1), "DeployNod: fallback not whitelisted");
        console2.log("[8] Fallback whitelisted: ", fallback1);

        //  Step 9: Hand off DEFAULT_ADMIN to timelock; deployer renounces 
        //    Registry
        registry.grantRole(registry.DEFAULT_ADMIN_ROLE(), address(timelock));
        registry.renounceRole(registry.DEFAULT_ADMIN_ROLE(), deployer);
        console2.log("[9a] Registry admin handed to timelock; deployer renounced");

        //    IdentityAttestor
        attestor.grantRole(attestor.DEFAULT_ADMIN_ROLE(), address(timelock));
        attestor.renounceRole(attestor.DEFAULT_ADMIN_ROLE(), deployer);
        console2.log("[9b] IdentityAttestor admin handed to timelock; deployer renounced");

        //    BuybackModule — deployer is currently DEFAULT_ADMIN; hand off
        buyback.grantRole(buyback.DEFAULT_ADMIN_ROLE(), address(timelock));
        buyback.renounceRole(buyback.DEFAULT_ADMIN_ROLE(), deployer);
        console2.log("[9c] BuybackModule admin handed to timelock; deployer renounced");

        //    PayoutRouter — no privileged functions requiring admin post-deploy;
        //    still hand off for future-proofing
        router.grantRole(router.DEFAULT_ADMIN_ROLE(), address(timelock));
        router.renounceRole(router.DEFAULT_ADMIN_ROLE(), deployer);
        console2.log("[9d] PayoutRouter admin handed to timelock; deployer renounced");

        vm.stopBroadcast();

        //  Step 10: Summary 
        console2.log("");
        console2.log("=== DEPLOYMENT COMPLETE ===");
        console2.log("NodTimelockController : ", address(timelock));
        console2.log("FeeVaultFactory       : ", address(factory));
        console2.log("IdentityAttestor      : ", address(attestor));
        console2.log("BuybackModule         : ", address(buyback));
        console2.log("Registry              : ", address(registry));
        console2.log("PayoutRouter          : ", address(router));
        console2.log("");
        console2.log("Post-deploy checklist (via multisig + 48h timelock):");
        console2.log("  1. registry.setAdapterWhitelist(<BullcheeseAdapter>, true)  [Arc mainnet: MintPlus 0x16D4c13aD2A23288AA9b9384F24084edC8CBeF41]");
        console2.log("  1b. registry.setSwapRouter(0x53BF6B0684Ec7eF91e1387Da3D1a1769bC5A6F77) + grantRole(KEEPER_ROLE, <keeper>)");
        console2.log("  2. buyback.setSwapRouter(<UniswapV3Router>)");
        console2.log("  3. buyback.setNodToken(<NOD_TOKEN_ADDRESS>)");
        console2.log("  4. buyback.setDisabled(false)  [after pool + router set]");
    }

    //  Internal helpers 

    function _requireNonZero(address a, string memory name) internal pure {
        require(a != address(0), string(abi.encodePacked("DeployNod: ", name, " is zero")));
    }
}
