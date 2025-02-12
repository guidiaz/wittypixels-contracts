// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ITokenVault.sol";

interface ITokenVaultFactory {

    /// @dev Possible status of an ERC721Token Vault, based on current ownership
    /// @dev of a previously fractionalized token. 
    enum TokenVaultStatus {
        Unknown,    // unknown token vault (index out of range)
        Active,     // vault still owns fractionalized token
        Acquired,   // vault has been acquired, but was not yet deleted
        Deleted     // vault was acquired and deleted
    }
    
    /// @notice A new token has been fractionalized from this factory.
    event Fractionalized(
        address indexed from,   // owner of the token being fractionalized
        address indexed token,  // token collection address
        uint256 tokenId,        // token id
        address tokenVault      // token vault contract just created
    );

    /// @notice Fractionalize given token by transferring ownership to new instance of ERC-20 ERC721Token Vault. 
    /// @dev Caller must be the owner of specified token.
    /// @param token Address of ERC-721 collection.
    /// @param tokenId ERC721Token identifier within that collection.
    /// @param tokenVaultSettings Extra settings to be passed when initializing the token vault contract.
    function fractionalize(
            address token,
            uint256 tokenId,
            bytes   memory tokenVaultSettings
        )
        external returns (ITokenVault);

    /// @notice Fractionalize given token by transferring ownership to new instance of ERC-20 ERC721Token Vault. 
    /// @dev Fails should the factory not be also a token minting contract.
    /// @dev Caller must be the owner of specified token.
    /// @param tokenId ERC721Token identifier within that collection.
    /// @param tokenVaultSettings Extra settings to be passed when initializing the token vault contract.
    function fractionalize(
            uint256 tokenId,
            bytes   memory tokenVaultSettings
        )
        external returns (ITokenVault);
    
    /// @notice Gets indexed token vault contract created by this factory.
    /// @dev First created vault should be assigned index 1.
    function getTokenVaultByIndex(uint256 index) external view returns (ITokenVault);
    
    /// @notice Gets current status of indexed token vault created by this factory.
    /// @dev First created vault should be assigned index 1.
    function getTokenVaultStatusByIndex(uint256 index) external view returns (TokenVaultStatus);

    /// @notice Returns token vault prototype being instantiated when fractionalizing. 
    /// @dev If destructible, it must be owned by the factory contract.
    function tokenVaultPrototype() external view returns (ITokenVault);

    /// @notice Returns number of vaults created so far.
    function totalTokenVaults() external view returns (uint256);
}