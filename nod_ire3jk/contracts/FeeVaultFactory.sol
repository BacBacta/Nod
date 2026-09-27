// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FeeVault} from "./FeeVault.sol";

/**
 * @title  FeeVaultFactory
 * @notice Deploys one FeeVault per token via CREATE2.  The salt is derived from the
 *         caller address and an auto-incrementing nonce, so the vault address can be
 *         computed deterministically BEFORE the token exists.
 *
 * @dev    Only the admin may set Registry once after deployment. The
 *         deposit cap stored here is the factory-level default; individual vaults can
 *         have their caps updated later by the Registry (after timelock governance).
 */
contract FeeVaultFactory {
    // ─── Errors ──────────────────────────────────────────────────────────────────

    /// @notice Zero-address argument where a non-zero address is required.
    error ZeroAddress();
    /// @notice A vault for this salt already exists.
    error VaultAlreadyDeployed(bytes32 salt);
    /// @notice Caller is not the Registry.
    error NotRegistry();
    /// @notice Registry is already set.
    error RegistryAlreadySet();
    /// @notice Caller is not the factory admin.
    error NotAdmin();

    // ─── Events ──────────────────────────────────────────────────────────────────

    /// @notice Emitted when a new FeeVault is created.
    event VaultDeployed(
        address indexed token,
        address indexed vault,
        bytes32 indexed salt,
        address deployer,
        uint256 nonce
    );

    /// @notice Emitted when the default deposit cap changes.
    event DepositCapUpdated(uint256 oldCap, uint256 newCap);

    // ─── Immutables ──────────────────────────────────────────────────────────────

    /// @notice USDC ERC-20 address on Arc.
    address public immutable USDC;

    /// @notice Admin that can set the Registry once.
    address public immutable admin;

    // ─── State ───────────────────────────────────────────────────────────────────

    /// @notice The Registry authorised to call privileged factory functions.
    address public registry;

    /// @notice Per-deployer nonce for CREATE2 salt derivation.
    mapping(address deployer => uint256 nonce) public deployerNonce;

    /// @notice salt => vault address for already-deployed vaults.
    mapping(bytes32 salt => address vault) public vaults;

    /// @notice Default deposit cap applied to newly deployed vaults.
    ///         0 = uncapped.  Timelocked changes via Registry.
    uint256 public defaultDepositCap;

    // ─── Constructor ─────────────────────────────────────────────────────────────

    /**
     * @param _admin              Factory admin allowed to set registry once.
     * @param _usdc               USDC ERC-20 address on Arc.
     * @param _defaultDepositCap  Initial per-vault deposit cap (6-decimal USDC).
     *                            Pass 0 for no cap.
     */
    constructor(address _admin, address _usdc, uint256 _defaultDepositCap) {
        if (_admin == address(0) || _usdc == address(0)) revert ZeroAddress();
        admin = _admin;
        USDC = _usdc;
        defaultDepositCap = _defaultDepositCap;
    }

    // ─── Registry wiring (one-time) ──────────────────────────────────────────────

    /**
     * @notice Wire this factory to its Registry.  Called once during the deployment
     *         sequence; cannot be changed afterward.
     * @param _registry  Address of the Registry contract.
     */
    function setRegistry(address _registry) external {
        if (msg.sender != admin) revert NotAdmin();
        if (registry != address(0)) revert RegistryAlreadySet();
        if (_registry == address(0)) revert ZeroAddress();
        registry = _registry;
    }

    // ─── Modifiers ───────────────────────────────────────────────────────────────

    modifier onlyRegistry() {
        if (msg.sender != registry) revert NotRegistry();
        _;
    }

    // ─── Vault deployment ────────────────────────────────────────────────────────

    /**
     * @notice Deploy a new FeeVault for `token` using the caller's current nonce.
     *         The Registry calls this during `registerToken`.
     *
     * @param  deployer  Address on whose behalf the vault is created (the entity that
     *                   called `registerToken`, used to derive the salt).
     * @param  token     Launchpad token the new vault will serve.
     * @return vault     Address of the newly deployed FeeVault.
     * @return usedSalt  The CREATE2 salt that was used.
     *
     * @dev    Only the Registry may call this.  `deployer` is the original caller of
     *         `Registry.registerToken`, forwarded through the Registry.
     */
    function deployVault(address deployer, address token)
        external
        onlyRegistry
        returns (address vault, bytes32 usedSalt)
    {
        if (deployer == address(0) || token == address(0)) revert ZeroAddress();

        uint256 nonce = deployerNonce[deployer];
        // Salt from (deployer, token): another registration by the same deployer can
        // never move a vault address that was predicted and fixed on a launchpad.
        usedSalt = keccak256(abi.encodePacked(deployer, token));

        if (vaults[usedSalt] != address(0)) revert VaultAlreadyDeployed(usedSalt);

        // CREATE2: deploy a fresh FeeVault
        FeeVault newVault = new FeeVault{salt: usedSalt}(
            USDC,
            address(this),
            token,
            usedSalt
        );

        vault = address(newVault);
        vaults[usedSalt] = vault;
        unchecked {
            ++deployerNonce[deployer];
        }

        // Wire vault → Registry (one-time call from factory, which IS the factory)
        newVault.setRegistry(registry, defaultDepositCap);

        emit VaultDeployed(token, vault, usedSalt, deployer, nonce);
    }

    // ─── Admin ───────────────────────────────────────────────────────────────────

    /**
     * @notice Update the default deposit cap for vaults deployed from this point
     *         onward.  Existing vaults are NOT affected.  Callers should update
     *         individual vaults via `Registry.setVaultDepositCap` if needed.
     *
     * @dev    Called by the Registry after a timelock-approved governance action.
     * @param newCap  New cap in USDC (6-decimal).  0 = uncapped.
     */
    function setDefaultDepositCap(uint256 newCap) external onlyRegistry {
        uint256 old = defaultDepositCap;
        defaultDepositCap = newCap;
        emit DepositCapUpdated(old, newCap);
    }

    // ─── View / off-chain helpers ────────────────────────────────────────────────

    /**
     * @notice Pre-compute the address a FeeVault would have if deployed right now for
     *         (`deployer`, `token`) at the caller's current nonce.
     *
     * @param  deployer   Address that will call `Registry.registerToken`.
     * @param  token      Token address that will be passed to `deployVault`.
     * @return predicted  The CREATE2 address the vault would land at.
     * @return saltUsed   The salt that would be used.
     */
    function predictVaultAddress(address deployer, address token)
        external
        view
        returns (address predicted, bytes32 saltUsed)
    {
        saltUsed = keccak256(abi.encodePacked(deployer, token));

        bytes memory creationCode = abi.encodePacked(
            type(FeeVault).creationCode,
            abi.encode(
                USDC,
                address(this),
                token,
                saltUsed
            )
        );

        bytes32 initCodeHash = keccak256(creationCode);

        predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(this),
                            saltUsed,
                            initCodeHash
                        )
                    )
                )
            )
        );
    }
}
