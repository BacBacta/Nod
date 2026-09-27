// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {FeeVaultFactory}   from "../FeeVaultFactory.sol";
import {IdentityAttestor}  from "../IdentityAttestor.sol";
import {Registry}          from "../Registry.sol";
import {PayoutRouter}      from "../PayoutRouter.sol";
import {BuybackModule}     from "../BuybackModule.sol";
import {MockLaunchpadAdapter} from "../test-helpers/MockLaunchpadAdapter.sol";
import {MockERC20}         from "../test-helpers/MockERC20.sol";
import {MockLaunchpad}     from "../test-helpers/MockLaunchpad.sol";
import {BullcheeseAdapter} from "../BullcheeseAdapter.sol";
import {MockMintPlus, MockLocker, MockV3Pool, MockSwapRouter02} from "../test-helpers/MockBullcheese.sol";

/**
 * @title  DevLocal
 * @notice LOCAL DEVELOPMENT ONLY (anvil, chain ID 31337).  Deploys the full Nod stack
 *         against a mock USDC and a mock launchpad, then seeds a demo token so the
 *         frontend has something to show.  Never use this for Arc: it makes the
 *         deployer the "timelock" and uses anvil's public default keys.
 *
 *         Run through `scripts/dev-local.sh`, which starts anvil, runs this script,
 *         skips the 7-day first-claim cooldown and writes addresses for the frontend.
 *
 *         Anvil accounts used:
 *           #0 deployer / attester / timelock / pauser / keeper
 *           #1 creator wallet and split recipient 0 (60%)
 *           #2 split recipient 1 (40%)
 *           #3 fallback recipient
 *           #4 treasury
 *           #5 keeper (KEEPER_ROLE: converts token fees to USDC)
 */
contract DevLocal is Script {
    uint256 internal constant ANVIL_KEY_0 =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    address internal constant CREATOR  = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address internal constant RECIP_2  = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address internal constant FALLBACK = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address internal constant TREASURY = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;
    address internal constant KEEPER   = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc; // anvil #5

    // Canonical ids, as issued by attestation-service: creatorId = creatorIdOf(platform, id).
    bytes32 internal constant PLATFORM   = keccak256("x");
    bytes32 internal constant CREATOR_ID = keccak256(abi.encode(PLATFORM, "12345"));

    function run() external {
        require(block.chainid == 31337, "DevLocal: anvil (31337) only");
        address dev = vm.addr(ANVIL_KEY_0);

        vm.startBroadcast(ANVIL_KEY_0);

        MockERC20 usdc = new MockERC20("USD Coin (mock)", "USDC", 6);
        MockLaunchpad launchpad = new MockLaunchpad();
        MockLaunchpadAdapter adapter = new MockLaunchpadAdapter(address(launchpad));

        FeeVaultFactory factory = new FeeVaultFactory(dev, address(usdc), 0);
        IdentityAttestor attestor = new IdentityAttestor(dev, dev, dev);
        attestor.grantRole(attestor.REVOKER_ROLE(), dev);
        BuybackModule buyback = new BuybackModule(
            address(usdc), dev, address(0), 3000, 100, 7 days, dev, dev
        );
        Registry registry = new Registry(
            address(usdc), address(factory), address(attestor), TREASURY,
            address(buyback), dev /* timelock: dev only */, dev, dev, 1000, FALLBACK
        );
        PayoutRouter router = new PayoutRouter(
            address(registry), address(attestor), address(usdc), dev
        );
        factory.setRegistry(address(registry));
        registry.grantRole(keccak256("PAYOUT_ROUTER_ROLE"), address(router));
        registry.setAdapterWhitelist(address(adapter), true);

        // Verify the demo creator's wallet (account #1).
        uint48 expiry = uint48(block.timestamp + 365 days);
        bytes32 nonce = keccak256("dev-attestation");
        attestor.attest(
            PLATFORM, CREATOR_ID, CREATOR, expiry, nonce,
            _signAttestation(attestor, CREATOR, expiry, nonce)
        );

        // Demo token launched on the mock launchpad with its vault as fee recipient.
        MockERC20 demoToken = new MockERC20("Demo Meme", "DEMO", 18);
        (address predicted,) = factory.predictVaultAddress(dev, address(demoToken));
        launchpad.setFeeRecipient(address(demoToken), predicted);
        launchpad.setLocked(address(demoToken), true);

        Registry.SplitInput[] memory splits = new Registry.SplitInput[](2);
        splits[0] = Registry.SplitInput({recipient: CREATOR, bps: 6000});
        splits[1] = Registry.SplitInput({recipient: RECIP_2, bps: 4000});
        registry.registerToken(
            address(demoToken), address(adapter), CREATOR_ID, splits, FALLBACK,
            keccak256("dev-launchpad")
        );

        // Bullcheese-style (pull model) demo: DEMO2's LP locker belongs to the creator,
        // who hands it to the Nod vault from the frontend's registration form.
        MockMintPlus mintPlus = new MockMintPlus();
        BullcheeseAdapter bcAdapter = new BullcheeseAdapter(address(mintPlus), address(usdc));
        registry.setAdapterWhitelist(address(bcAdapter), true);
        MockERC20 bcToken = new MockERC20("Bull Demo", "BULL", 18);
        MockLocker locker = new MockLocker(CREATOR, usdc, bcToken);
        mintPlus.set(address(bcToken), address(new MockV3Pool(address(usdc), address(bcToken))), address(locker));
        locker.accrue(200e6, 0); // 200 USDC of creator fees waiting in the locker

        // Token-fee conversion: mock router (1:1 raw units, matching the mock pool's TWAP tick 0).
        registry.setSwapRouter(address(new MockSwapRouter02()));
        registry.grantRole(registry.KEEPER_ROLE(), KEEPER);

        // Trading fees accrued so far, plus some USDC for test wallets.
        usdc.mint(predicted, 1_000e6);
        usdc.mint(CREATOR, 100e6);
        usdc.mint(RECIP_2, 100e6);

        vm.stopBroadcast();

        string memory o = "deployments";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "usdc", address(usdc));
        vm.serializeAddress(o, "registry", address(registry));
        vm.serializeAddress(o, "payoutRouter", address(router));
        vm.serializeAddress(o, "attestor", address(attestor));
        vm.serializeAddress(o, "factory", address(factory));
        vm.serializeAddress(o, "adapter", address(adapter));
        vm.serializeAddress(o, "launchpad", address(launchpad));
        vm.serializeAddress(o, "fallback", FALLBACK);
        vm.serializeAddress(o, "demoToken", address(demoToken));
        vm.serializeAddress(o, "bullcheeseAdapter", address(bcAdapter));
        vm.serializeAddress(o, "bullcheeseDemoToken", address(bcToken));
        vm.serializeAddress(o, "bullcheeseLocker", address(locker));
        vm.serializeAddress(o, "keeper", KEEPER);
        string memory json = vm.serializeBytes32(o, "demoCreatorId", CREATOR_ID);
        vm.writeJson(json, "./frontend/src/deployments/31337.json");

        console2.log("Registry:   ", address(registry));
        console2.log("Demo token: ", address(demoToken));
        console2.log("Demo vault: ", predicted);
    }

    function _signAttestation(
        IdentityAttestor attestor,
        address wallet,
        uint48 expiry,
        bytes32 nonce
    ) internal view returns (bytes memory) {
        (, string memory name, string memory version, uint256 chainId, address verifying,,) =
            attestor.eip712Domain();
        bytes32 domain = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifying
        ));
        bytes32 structHash = keccak256(abi.encode(
            attestor.ATTESTATION_TYPEHASH(), PLATFORM, CREATOR_ID, wallet, expiry, nonce
        ));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(ANVIL_KEY_0, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }
}
