// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IdentityAttestor} from "../IdentityAttestor.sol";

contract IdentityAttestorTest is Test {
    IdentityAttestor internal attestor;

    address internal admin   = makeAddr("admin");
    address internal attesterAddr;
    uint256 internal attesterKey;

    address internal pauser  = makeAddr("pauser");
    address internal alice   = makeAddr("alice");
    address internal bob     = makeAddr("bob");

    bytes32 internal PLATFORM     = keccak256("nod");
    bytes32 internal PLATFORM_USER = keccak256("user1");

    function setUp() public {
        (attesterAddr, attesterKey) = makeAddrAndKey("attester");
        attestor = new IdentityAttestor(admin, attesterAddr, pauser);
    }

    // ─── Internal helper: create a valid EIP-712 attestation signature ───────────

    /// @dev Compute the EIP-712 domain separator for the deployed attestor.
    function _domainSeparator() internal view returns (bytes32) {
        (
            ,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            ,

        ) = attestor.eip712Domain();
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
    }

    function _sign(
        bytes32 platform,
        bytes32 platformUserId,
        address wallet,
        uint48  expiry,
        bytes32 nonce
    ) internal view returns (bytes memory sig) {
        bytes32 structHash = keccak256(
            abi.encode(
                attestor.ATTESTATION_TYPEHASH(),
                platform,
                platformUserId,
                wallet,
                expiry,
                nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _attest(
        bytes32 platform,
        bytes32 platformUserId,
        address wallet,
        bytes32 nonce
    ) internal {
        uint48 expiry = uint48(block.timestamp + 1 days);
        bytes memory sig = _sign(platform, platformUserId, wallet, expiry, nonce);
        attestor.attest(platform, platformUserId, wallet, expiry, nonce, sig);
    }

    // ─── Happy path: attest ──────────────────────────────────────────────────────

    function test_Attest_HappyPath() public {
        _attest(PLATFORM, PLATFORM_USER, alice, keccak256("nonce1"));
        assertEq(attestor.walletOf(PLATFORM_USER), alice);
        assertTrue(attestor.isVerifiedWallet(PLATFORM_USER, alice));
    }

    function test_Attest_SetsFirstAttestedAt() public {
        vm.warp(1000);
        _attest(PLATFORM, PLATFORM_USER, alice, keccak256("nonce1"));
        assertEq(attestor.firstAttestedAt(PLATFORM_USER), 1000);
    }

    function test_Attest_FirstAttestedAtNeverChangedByReAttestation() public {
        vm.warp(1000);
        _attest(PLATFORM, PLATFORM_USER, alice, keccak256("nonce1"));
        uint48 first = attestor.firstAttestedAt(PLATFORM_USER);

        vm.warp(2000);
        _attest(PLATFORM, PLATFORM_USER, alice, keccak256("nonce2"));
        // firstAttestedAt must be unchanged
        assertEq(attestor.firstAttestedAt(PLATFORM_USER), first);
    }

    function test_Attest_DifferentWalletRequiresRotation() public {
        _attest(PLATFORM, PLATFORM_USER, alice, keccak256("nonce1"));
        uint48 expiry = uint48(block.timestamp + 1 days);
        bytes32 nonce = keccak256("nonce2");
        bytes memory sig = _sign(PLATFORM, PLATFORM_USER, bob, expiry, nonce);

        vm.expectRevert(abi.encodeWithSelector(
            IdentityAttestor.WalletChangeRequiresRotation.selector, PLATFORM_USER, alice, bob
        ));
        attestor.attest(PLATFORM, PLATFORM_USER, bob, expiry, nonce, sig);
        assertEq(attestor.walletOf(PLATFORM_USER), alice);
    }

    function test_Attest_PlatformMismatchReverts() public {
        _attest(PLATFORM, PLATFORM_USER, alice, keccak256("nonce1"));
        bytes32 other = keccak256("github");
        uint48 expiry = uint48(block.timestamp + 1 days);
        bytes32 nonce = keccak256("nonce2");
        bytes memory sig = _sign(other, PLATFORM_USER, alice, expiry, nonce);

        vm.expectRevert(abi.encodeWithSelector(
            IdentityAttestor.PlatformMismatch.selector, PLATFORM_USER, PLATFORM, other
        ));
        attestor.attest(other, PLATFORM_USER, alice, expiry, nonce, sig);
    }

    function test_InitiateRotation_PlatformMismatchReverts() public {
        _attest(PLATFORM, PLATFORM_USER, alice, keccak256("nonce1"));
        bytes32 other = keccak256("github");
        uint48 expiry = uint48(block.timestamp + 1 days);
        bytes32 nonce = keccak256("nonce2");
        bytes memory sig = _sign(other, PLATFORM_USER, bob, expiry, nonce);

        vm.expectRevert(abi.encodeWithSelector(
            IdentityAttestor.PlatformMismatch.selector, PLATFORM_USER, PLATFORM, other
        ));
        attestor.initiateRotation(other, PLATFORM_USER, bob, expiry, nonce, sig);
    }

    function test_CreatorIdOf_SeparatesPlatforms() public view {
        bytes32 x = attestor.creatorIdOf(keccak256("x"), "12345");
        bytes32 gh = attestor.creatorIdOf(keccak256("github"), "12345");
        assertTrue(x != gh);
        assertEq(x, keccak256(abi.encode(keccak256("x"), "12345")));
    }

    function test_Attest_EmitsEvent() public {
        bytes32 nonce  = keccak256("nonce1");
        uint48  expiry = uint48(block.timestamp + 1 days);
        bytes memory sig = _sign(PLATFORM, PLATFORM_USER, alice, expiry, nonce);

        vm.expectEmit(true, true, false, true, address(attestor));
        emit IdentityAttestor.WalletAttested(PLATFORM_USER, alice, expiry, nonce);
        attestor.attest(PLATFORM, PLATFORM_USER, alice, expiry, nonce, sig);
    }

    // ─── Replay protection ───────────────────────────────────────────────────────

    function test_Attest_ReplayReverts() public {
        bytes32 nonce  = keccak256("nonce1");
        uint48  expiry = uint48(block.timestamp + 1 days);
        bytes memory sig = _sign(PLATFORM, PLATFORM_USER, alice, expiry, nonce);

        attestor.attest(PLATFORM, PLATFORM_USER, alice, expiry, nonce, sig);

        // Same nonce again — must revert
        vm.expectRevert(
            abi.encodeWithSelector(IdentityAttestor.NonceAlreadyUsed.selector, nonce)
        );
        attestor.attest(PLATFORM, PLATFORM_USER, alice, expiry, nonce, sig);
    }

    // ─── Expiry ──────────────────────────────────────────────────────────────────

    function test_Attest_ExpiredReverts() public {
        uint48 expiry = uint48(block.timestamp - 1); // already past
        bytes32 nonce = keccak256("nonce1");
        bytes memory sig = _sign(PLATFORM, PLATFORM_USER, alice, expiry, nonce);

        vm.expectRevert(
            abi.encodeWithSelector(IdentityAttestor.AttestationExpired.selector, expiry)
        );
        attestor.attest(PLATFORM, PLATFORM_USER, alice, expiry, nonce, sig);
    }

    // ─── Revocation ──────────────────────────────────────────────────────────────

    function test_Revoke_SetsRevoked() public {
        _attest(PLATFORM, PLATFORM_USER, alice, keccak256("nonce1"));
        vm.prank(attesterAddr);
        attestor.revoke(PLATFORM_USER);

        assertFalse(attestor.isVerifiedWallet(PLATFORM_USER, alice));
        assertEq(attestor.walletOf(PLATFORM_USER), address(0));
    }

    function test_Revoke_OnlyAttesterRole() public {
        _attest(PLATFORM, PLATFORM_USER, alice, keccak256("nonce1"));
        vm.prank(alice);
        vm.expectRevert(); // AccessControl revert
        attestor.revoke(PLATFORM_USER);
    }

    function test_Attest_RevokedIdentityReverts() public {
        _attest(PLATFORM, PLATFORM_USER, alice, keccak256("nonce1"));
        vm.prank(attesterAddr);
        attestor.revoke(PLATFORM_USER);

        bytes32 nonce  = keccak256("nonce2");
        uint48  expiry = uint48(block.timestamp + 1 days);
        bytes memory sig = _sign(PLATFORM, PLATFORM_USER, bob, expiry, nonce);

        vm.expectRevert(
            abi.encodeWithSelector(IdentityAttestor.IdentityRevoked.selector, PLATFORM_USER)
        );
        attestor.attest(PLATFORM, PLATFORM_USER, bob, expiry, nonce, sig);
    }

    function test_InitiateRotation_RevokedIdentityReverts() public {
        _attest(PLATFORM, PLATFORM_USER, alice, keccak256("nonce1"));
        vm.prank(attesterAddr);
        attestor.revoke(PLATFORM_USER);

        bytes32 nonce  = keccak256("nonce2");
        uint48  expiry = uint48(block.timestamp + 1 days);
        bytes memory sig = _sign(PLATFORM, PLATFORM_USER, bob, expiry, nonce);

        vm.expectRevert(
            abi.encodeWithSelector(IdentityAttestor.IdentityRevoked.selector, PLATFORM_USER)
        );
        attestor.initiateRotation(PLATFORM, PLATFORM_USER, bob, expiry, nonce, sig);
    }

    // ─── Rotation ────────────────────────────────────────────────────────────────

    function test_Rotation_InitiateSetsPhase() public {
        _attest(PLATFORM, PLATFORM_USER, alice, keccak256("nonce1"));

        bytes32 nonce  = keccak256("nonce2");
        uint48  expiry = uint48(block.timestamp + 1 days);
        bytes memory sig = _sign(PLATFORM, PLATFORM_USER, bob, expiry, nonce);
        attestor.initiateRotation(PLATFORM, PLATFORM_USER, bob, expiry, nonce, sig);

        (,address pendingWallet,,,, ) = attestor.attestations(PLATFORM_USER);
        assertEq(pendingWallet, bob);
    }

    function test_Rotation_CompleteBeforeDelayReverts() public {
        _attest(PLATFORM, PLATFORM_USER, alice, keccak256("nonce1"));

        bytes32 nonce  = keccak256("nonce2");
        uint48  expiry = uint48(block.timestamp + 1 days);
        bytes memory sig = _sign(PLATFORM, PLATFORM_USER, bob, expiry, nonce);
        attestor.initiateRotation(PLATFORM, PLATFORM_USER, bob, expiry, nonce, sig);

        // Warp just short of 7 days
        vm.warp(block.timestamp + 7 days - 1);

        vm.expectRevert(); // RotationNotReady
        attestor.completeRotation(PLATFORM_USER);
    }

    function test_Rotation_CompleteAfterDelaySucceeds() public {
        _attest(PLATFORM, PLATFORM_USER, alice, keccak256("nonce1"));

        bytes32 nonce  = keccak256("nonce2");
        uint48  expiry = uint48(block.timestamp + 30 days);
        bytes memory sig = _sign(PLATFORM, PLATFORM_USER, bob, expiry, nonce);
        attestor.initiateRotation(PLATFORM, PLATFORM_USER, bob, expiry, nonce, sig);

        vm.warp(block.timestamp + 7 days + 1);
        attestor.completeRotation(PLATFORM_USER);

        assertEq(attestor.walletOf(PLATFORM_USER), bob);
    }

    function test_Rotation_OldWalletActiveduringDelay() public {
        _attest(PLATFORM, PLATFORM_USER, alice, keccak256("nonce1"));

        bytes32 nonce  = keccak256("nonce2");
        uint48  expiry = uint48(block.timestamp + 30 days);
        bytes memory sig = _sign(PLATFORM, PLATFORM_USER, bob, expiry, nonce);
        attestor.initiateRotation(PLATFORM, PLATFORM_USER, bob, expiry, nonce, sig);

        // Old wallet still active
        assertEq(attestor.walletOf(PLATFORM_USER), alice);
        assertTrue(attestor.isVerifiedWallet(PLATFORM_USER, alice));
    }

    function test_CompleteRotation_NoPendingReverts() public {
        _attest(PLATFORM, PLATFORM_USER, alice, keccak256("nonce1"));
        vm.expectRevert(IdentityAttestor.NoPendingRotation.selector);
        attestor.completeRotation(PLATFORM_USER);
    }

    // ─── isVerifiedWallet ────────────────────────────────────────────────────────

    function test_IsVerifiedWallet_TrueForCurrentWallet() public {
        _attest(PLATFORM, PLATFORM_USER, alice, keccak256("nonce1"));
        assertTrue(attestor.isVerifiedWallet(PLATFORM_USER, alice));
    }

    function test_IsVerifiedWallet_FalseForPendingWallet() public {
        _attest(PLATFORM, PLATFORM_USER, alice, keccak256("nonce1"));

        bytes32 nonce  = keccak256("nonce2");
        uint48  expiry = uint48(block.timestamp + 30 days);
        bytes memory sig = _sign(PLATFORM, PLATFORM_USER, bob, expiry, nonce);
        attestor.initiateRotation(PLATFORM, PLATFORM_USER, bob, expiry, nonce, sig);

        // bob is pending — not yet verified
        assertFalse(attestor.isVerifiedWallet(PLATFORM_USER, bob));
    }

    function test_IsVerifiedWallet_FalseForUnknown() public view {
        assertFalse(attestor.isVerifiedWallet(PLATFORM_USER, alice));
    }

    // ─── Pausing ─────────────────────────────────────────────────────────────────

    function test_Pause_OnlyPauserRole() public {
        vm.prank(alice);
        vm.expectRevert(); // AccessControl
        attestor.pause();
    }

    function test_Pause_BlocksAttest() public {
        vm.prank(pauser);
        attestor.pause();

        bytes32 nonce  = keccak256("nonce1");
        uint48  expiry = uint48(block.timestamp + 1 days);
        bytes memory sig = _sign(PLATFORM, PLATFORM_USER, alice, expiry, nonce);

        vm.expectRevert(); // Pausable: EnforcedPause
        attestor.attest(PLATFORM, PLATFORM_USER, alice, expiry, nonce, sig);
    }

    function test_Unpause_OnlyPauserRole() public {
        vm.prank(pauser);
        attestor.pause();

        vm.prank(alice);
        vm.expectRevert();
        attestor.unpause();
    }

    function test_Unpause_ResumesFunctionality() public {
        vm.prank(pauser);
        attestor.pause();
        vm.prank(pauser);
        attestor.unpause();

        _attest(PLATFORM, PLATFORM_USER, alice, keccak256("nonce1"));
        assertEq(attestor.walletOf(PLATFORM_USER), alice);
    }

    // ─── Handle-agnostic: same platformUserId different platform ─────────────────

    function test_SamePlatformUserIdDifferentPlatformCannotOverwrite() public {
        bytes32 platform2 = keccak256("nod_v2");

        _attest(PLATFORM, PLATFORM_USER, alice, keccak256("nonce1"));
        // The identity is bound to PLATFORM; another platform cannot take it over.
        uint48 expiry = uint48(block.timestamp + 1 days);
        bytes32 nonce = keccak256("nonce2");
        bytes memory sig = _sign(platform2, PLATFORM_USER, bob, expiry, nonce);
        vm.expectRevert(abi.encodeWithSelector(
            IdentityAttestor.PlatformMismatch.selector, PLATFORM_USER, PLATFORM, platform2
        ));
        attestor.attest(platform2, PLATFORM_USER, bob, expiry, nonce, sig);

        assertEq(attestor.walletOf(PLATFORM_USER), alice);
    }

}
