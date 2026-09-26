// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Bullcheese / Team Finance MintPlus launcher (Arc mainnet 0x16D4c13aD2A23288AA9b9384F24084edC8CBeF41).
interface IMintPlus {
    /// @return pool Uniswap v3 pool of the token, locker per-token LP locker, tokenId LP NFT, lockId Team Finance lock.
    function deploymentInfo(address token)
        external
        view
        returns (address pool, address locker, uint256 tokenId, uint256 lockId);
}

/// @notice Per-token MintPlus LP locker (EIP-1167 clone). Ownable2Step; `collectFees` is owner-only
///         and pays the owner's share of the position's fees (both pool tokens) to the owner.
interface IMintPlusLocker {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function acceptOwnership() external;
    function collectFees() external;
}
