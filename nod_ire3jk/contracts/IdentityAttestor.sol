// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * @title  IdentityAttestor
 * @notice EIP-712 identity-attestation registry.  An off-chain key held by a multisig
 *         (ATTESTER_ROLE) signs attestations linking a platform user identity
 *         (immutable `platformUserId`, a bytes32, never a mutable handle) to an
 *         Ethereum wallet address.
 *
 * @dev    ── Identity keying ──────────────────────────────────────────────────────────
 *         Identity is keyed by `platformUserId` (bytes32), never by a handle string.
 *         Handle changes on the platform do not affect the on-chain identity mapping.
 *
 *         ── Replay protection ────────────────────────────────────────────────────────
 *         Each attestation carries a `nonce` (bytes32) that is marked used on first
 *         verification.  Re-using the same nonce reverts.
 *
 *         ── Wallet rotation ──────────────────────────────────────────────────────────
 *         A new wallet can be proposed at any time by the attester.  It enters a
 *         `pendingWallet` state and becomes active only after a 7-day delay, giving
 *         the current wallet holder time to notice and respond.  During the delay, the
 *         old wallet remains the authoritative wallet for all Registry actions.
 *
 *         ── First-claim cooldown ─────────────────────────────────────────────────────
 *         After a creator's FIRST attestation there is a 7-day cooldown before the
 *         Registry will honour their first `accept()` / `refuse()` call.  This is
 *         enforced by the Registry reading `firstAttestedAt` from this contract.
 *
 *         ── Pausing ──────────────────────────────────────────────────────────────────
 *         `PAUSER_ROLE` may pause new attestations and rotations.  Already-attested
 *         wallets continue to be readable (the Registry's claim path is unaffected by
 *         this pause).
 */
contract IdentityAttestor is AccessControl, Pausable, EIP712 {
    using ECDSA for bytes32;

    // ─── Errors ──────────────────────────────────────────────────────────────────

    /// @notice The provided signature does not recover to an ATTESTER_ROLE address.
    error InvalidSignature();
    /// @notice This nonce has already been consumed.
    error NonceAlreadyUsed(bytes32 nonce);
    /// @notice The attestation has expired (block.timestamp > expiry).
    error AttestationExpired(uint48 expiry);
    /// @notice The platform identity is currently revoked.
    error IdentityRevoked(bytes32 platformId);
    /// @notice The pending wallet's activation time has not arrived yet.
    error RotationNotReady(uint48 activatesAt);
    /// @notice There is no pending wallet rotation to complete.
    error NoPendingRotation();
    /// @notice Zero-address argument where a non-zero address is required.
    error ZeroAddress();
    /// @notice The wallet attempting the action is not the current verified wallet.
    error NotVerifiedWallet(bytes32 platformId, address expected, address got);
    /// @notice Changing an existing identity's wallet must go through the 7-day rotation.
    error WalletChangeRequiresRotation(bytes32 platformId, address current, address requested);
    /// @notice The identity is bound to a different platform.
    error PlatformMismatch(bytes32 platformId, bytes32 bound, bytes32 given);

    // ─── Events ──────────────────────────────────────────────────────────────────

    /// @notice A new attestation was recorded (first time or re-attestation with the same wallet).
    event WalletAttested(
        bytes32 indexed platformId,
        address indexed wallet,
        uint48 expiry,
        bytes32 nonce
    );
    /// @notice A wallet rotation was initiated (7-day delay started).
    event WalletRotationInitiated(
        bytes32 indexed platformId,
        address indexed newWallet,
        uint48 activatesAt
    );
    /// @notice A pending wallet rotation was completed (new wallet is now active).
    event WalletRotationCompleted(bytes32 indexed platformId, address indexed newWallet);
    /// @notice An attestation was revoked.
    event AttestationRevoked(bytes32 indexed platformId);
    /// @notice A revocation was lifted; the identity can be attested again.
    event AttestationUnrevoked(bytes32 indexed platformId);

    // ─── Types ───────────────────────────────────────────────────────────────────

    struct AttestationRecord {
        /// @notice Current verified wallet for this platform identity.
        address wallet;
        /// @notice Wallet rotation candidate (address(0) if none pending).
        address pendingWallet;
        /// @notice Timestamp at which `pendingWallet` becomes the active wallet.
        uint48 pendingWalletActivatesAt;
        /// @notice Block timestamp of the very first attestation (for claim cooldown).
        uint48 firstAttestedAt;
        /// @notice Block timestamp of the most recent successful attestation.
        uint48 lastAttestedAt;
        /// @notice True if the attester has revoked this identity.
        bool revoked;
    }

    // ─── EIP-712 typehash ────────────────────────────────────────────────────────

    /**
     * @dev EIP-712 type string for attestation payloads.
     *      Fields:
     *        platform       — bytes32 identifier of the originating platform.
     *        platformUserId — bytes32 immutable user ID (never a handle).
     *        wallet         — the wallet being attested.
     *        expiry         — unix timestamp after which the attestation is invalid.
     *        nonce          — unique per-attestation bytes32 for replay protection.
     */
    bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
        "Attestation(bytes32 platform,bytes32 platformUserId,address wallet,uint48 expiry,bytes32 nonce)"
    );

    // ─── Roles ───────────────────────────────────────────────────────────────────

    bytes32 public constant ATTESTER_ROLE = keccak256("ATTESTER_ROLE");
    bytes32 public constant PAUSER_ROLE   = keccak256("PAUSER_ROLE");
    /// @notice May revoke identities. Held by the multisig, not by the online attester key,
    ///         so a leaked attester key cannot lock creators out.
    bytes32 public constant REVOKER_ROLE  = keccak256("REVOKER_ROLE");

    // ─── Constants ───────────────────────────────────────────────────────────────

    /// @notice Delay before a new wallet becomes active after rotation is initiated.
    uint48 public constant ROTATION_DELAY = 7 days;

    /// @notice Cooldown from first attestation to first Registry claim.
    uint48 public constant FIRST_CLAIM_COOLDOWN = 7 days;

    // ─── State ───────────────────────────────────────────────────────────────────

    /// @notice platformUserId => attestation record.
    mapping(bytes32 platformId => AttestationRecord) public attestations;

    /// @notice nonce => consumed flag for replay protection.
    mapping(bytes32 nonce => bool) public usedNonces;

    /// @notice platformUserId => platform it was first attested on (bound forever).
    mapping(bytes32 platformId => bytes32 platform) public platformOf;

    // ─── Constructor ─────────────────────────────────────────────────────────────

    /**
     * @param admin     DEFAULT_ADMIN_ROLE holder (should be NodTimelockController
     *                  after bootstrap).
     * @param attester  ATTESTER_ROLE holder (multisig signing key).
     * @param pauser    PAUSER_ROLE holder.
     */
    constructor(address admin, address attester, address pauser)
        EIP712("NodIdentityAttestor", "1")
    {
        if (admin == address(0) || attester == address(0) || pauser == address(0)) {
            revert ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ATTESTER_ROLE, attester);
        _grantRole(PAUSER_ROLE, pauser);
    }

    // ─── Attestation ─────────────────────────────────────────────────────────────

    /**
     * @notice Record an attestation linking `platformUserId` to `wallet`.
     *         Callable by anyone who holds a valid ATTESTER_ROLE signature.
     *
     * @param platform        bytes32 identifier of the originating platform.
     * @param platformUserId  Immutable user ID (NOT a handle).
     * @param wallet          Wallet being attested.
     * @param expiry          Unix timestamp after which the signature is invalid.
     * @param nonce           Per-attestation unique bytes32.
     * @param signature       EIP-712 signature from an ATTESTER_ROLE key.
     *
     * @dev   If a pending rotation exists for this identity it is cleared because the
     *        attester is now explicitly setting the wallet.
     */
    function attest(
        bytes32 platform,
        bytes32 platformUserId,
        address wallet,
        uint48 expiry,
        bytes32 nonce,
        bytes calldata signature
    ) external whenNotPaused {
        if (wallet == address(0)) revert ZeroAddress();
        _verifySignature(platform, platformUserId, wallet, expiry, nonce, signature);

        AttestationRecord storage rec = attestations[platformUserId];
        if (rec.revoked) revert IdentityRevoked(platformUserId);
        _bindPlatform(platformUserId, platform);
        // A different wallet must use initiateRotation (7-day delay), so a hijacked
        // platform account cannot redirect an existing creator's fees instantly.
        if (rec.wallet != address(0) && rec.wallet != wallet) {
            revert WalletChangeRequiresRotation(platformUserId, rec.wallet, wallet);
        }

        // First attestation
        if (rec.firstAttestedAt == 0) {
            rec.firstAttestedAt = uint48(block.timestamp);
        }

        rec.wallet = wallet;
        rec.pendingWallet = address(0);
        rec.pendingWalletActivatesAt = 0;
        rec.lastAttestedAt = uint48(block.timestamp);

        emit WalletAttested(platformUserId, wallet, expiry, nonce);
    }

    /**
     * @notice Initiate a wallet rotation.  The new wallet becomes active after
     *         ROTATION_DELAY seconds.  Until then the current wallet remains active.
     *
     * @param platform        Platform identifier (must match existing record).
     * @param platformUserId  User whose wallet is rotating.
     * @param newWallet       The wallet to rotate to.
     * @param expiry          Expiry of the attester's signature.
     * @param nonce           Per-attestation nonce.
     * @param signature       EIP-712 signature from an ATTESTER_ROLE key.
     */
    function initiateRotation(
        bytes32 platform,
        bytes32 platformUserId,
        address newWallet,
        uint48 expiry,
        bytes32 nonce,
        bytes calldata signature
    ) external whenNotPaused {
        if (newWallet == address(0)) revert ZeroAddress();
        _verifySignature(platform, platformUserId, newWallet, expiry, nonce, signature);

        AttestationRecord storage rec = attestations[platformUserId];
        if (rec.revoked) revert IdentityRevoked(platformUserId);
        // Must already have an attestation to rotate
        if (rec.wallet == address(0)) revert ZeroAddress();
        _bindPlatform(platformUserId, platform);

        uint48 activatesAt = uint48(block.timestamp) + ROTATION_DELAY;
        rec.pendingWallet = newWallet;
        rec.pendingWalletActivatesAt = activatesAt;

        emit WalletRotationInitiated(platformUserId, newWallet, activatesAt);
    }

    /**
     * @notice Complete a pending rotation once ROTATION_DELAY has elapsed.
     *         Anyone may call this (permissionless) once the delay has passed.
     * @param platformUserId  User whose pending rotation is ready.
     */
    function completeRotation(bytes32 platformUserId) external {
        AttestationRecord storage rec = attestations[platformUserId];
        if (rec.pendingWallet == address(0)) revert NoPendingRotation();
        if (block.timestamp < rec.pendingWalletActivatesAt) {
            revert RotationNotReady(rec.pendingWalletActivatesAt);
        }

        address newWallet = rec.pendingWallet;
        rec.wallet = newWallet;
        rec.pendingWallet = address(0);
        rec.pendingWalletActivatesAt = 0;
        rec.lastAttestedAt = uint48(block.timestamp);

        emit WalletRotationCompleted(platformUserId, newWallet);
    }

    // ─── Revocation ──────────────────────────────────────────────────────────────

    /**
     * @notice Revoke the attestation for `platformUserId`.  Only REVOKER_ROLE (the multisig).
     *         After revocation, `walletOf` returns address(0) and Registry actions
     *         for this identity will revert.
     */
    function revoke(bytes32 platformUserId) external onlyRole(REVOKER_ROLE) {
        AttestationRecord storage rec = attestations[platformUserId];
        rec.revoked = true;
        rec.wallet = address(0);
        rec.pendingWallet = address(0);
        rec.pendingWalletActivatesAt = 0;
        emit AttestationRevoked(platformUserId);
    }

    /**
     * @notice Lift a revocation (e.g. a mistaken or malicious one). DEFAULT_ADMIN_ROLE
     *         (the timelock). The wallet stays unset: the creator attests again.
     */
    function unrevoke(bytes32 platformUserId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        attestations[platformUserId].revoked = false;
        emit AttestationUnrevoked(platformUserId);
    }

    // ─── Pausing ─────────────────────────────────────────────────────────────────

    /// @notice Pause new attestations and rotations.  Only PAUSER_ROLE.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resume attestations and rotations.  Only PAUSER_ROLE.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ─── View helpers ────────────────────────────────────────────────────────────

    /**
     * @notice Canonical `platformUserId` for an account: hashing the platform in keeps
     *         identical numeric ids on different platforms (e.g. GitHub 123 and X 123)
     *         from colliding.  The attestation service must derive ids this way.
     * @param platform    keccak256 of the platform name, e.g. keccak256("x").
     * @param externalId  The platform's immutable account id, as a string.
     */
    function creatorIdOf(bytes32 platform, string calldata externalId)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(platform, externalId));
    }

    /**
     * @notice Return the current verified wallet for `platformUserId`, or address(0)
     *         if unattested or revoked.
     */
    function walletOf(bytes32 platformUserId) external view returns (address) {
        return attestations[platformUserId].wallet;
    }

    /**
     * @notice Return the timestamp of the first attestation for `platformUserId`, or 0
     *         if unattested.  The Registry reads this to enforce the 7-day first-claim
     *         cooldown.
     */
    function firstAttestedAt(bytes32 platformUserId) external view returns (uint48) {
        return attestations[platformUserId].firstAttestedAt;
    }

    /**
     * @notice Return true if `wallet` is the current verified wallet for
     *         `platformUserId`.
     */
    function isVerifiedWallet(bytes32 platformUserId, address wallet)
        external
        view
        returns (bool)
    {
        return attestations[platformUserId].wallet == wallet
            && wallet != address(0)
            && !attestations[platformUserId].revoked;
    }

    // ─── Internal ────────────────────────────────────────────────────────────────

    /// @dev Bind `platformUserId` to `platform` on first use; reject any other platform.
    function _bindPlatform(bytes32 platformUserId, bytes32 platform) internal {
        bytes32 bound = platformOf[platformUserId];
        if (bound == bytes32(0)) {
            platformOf[platformUserId] = platform;
        } else if (bound != platform) {
            revert PlatformMismatch(platformUserId, bound, platform);
        }
    }

    /**
     * @dev Verify an EIP-712 attestation signature and consume the nonce.
     *      Reverts on invalid signature, expired attestation, or replayed nonce.
     */
    function _verifySignature(
        bytes32 platform,
        bytes32 platformUserId,
        address wallet,
        uint48 expiry,
        bytes32 nonce,
        bytes calldata signature
    ) internal {
        if (block.timestamp > expiry) revert AttestationExpired(expiry);
        if (usedNonces[nonce]) revert NonceAlreadyUsed(nonce);

        bytes32 structHash = keccak256(
            abi.encode(
                ATTESTATION_TYPEHASH,
                platform,
                platformUserId,
                wallet,
                expiry,
                nonce
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = digest.recover(signature);

        if (!hasRole(ATTESTER_ROLE, signer)) revert InvalidSignature();

        // Mark nonce consumed AFTER all checks (CEI)
        usedNonces[nonce] = true;
    }
}
