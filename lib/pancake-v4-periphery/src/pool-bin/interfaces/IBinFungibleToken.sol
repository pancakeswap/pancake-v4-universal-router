// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

interface IBinFungibleToken {
    error BinFungibleToken_AddressThisOrZero();
    error BinFungibleToken_InvalidLength();
    error BinFungibleToken_SelfApproval(address owner);
    error BinFungibleToken_SpenderNotApproved(address from, address spender);
    error BinFungibleToken_TransferExceedsBalance(address from, uint256 id, uint256 amount);
    error BinFungibleToken_BurnExceedsBalance(address from, uint256 id, uint256 amount);

    event TransferBatch(
        address indexed sender, address indexed from, address indexed to, uint256[] ids, uint256[] amounts
    );

    event ApprovalForAll(address indexed account, address indexed sender, bool approved);

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    /// @param id ID of the token
    /// @return The total supply of token id
    function totalSupply(uint256 id) external view returns (uint256);

    /// @notice Get the balance of an account's tokens.
    /// @param account The address of the token holder
    /// @param id ID of the token
    /// @return The account's balance of the token type requested
    function balanceOf(address account, uint256 id) external view returns (uint256);

    /// @notice Get the balance of multiple account/token pairs
    /// @param accounts The addresses of the token holders
    /// @param ids ID of the tokens
    /// @return The account's balance of the token types requested (i.e. balance for each (owner, id) pair)
    function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids)
        external
        view
        returns (uint256[] memory);

    function isApprovedForAll(address owner, address spender) external view returns (bool);

    /// @notice Enable or disable approval for a third party ("operator") to manage all of the caller's tokens.
    /// @dev MUST emit the ApprovalForAll event on success.
    /// @param operator Address to add to the set of authorized operators
    /// @param approved True if the operator is approved, false to revoke approval
    function approveForAll(address operator, bool approved) external;

    /// @notice Transfers `amounts` amount(s) of `ids` from the `from` address to the `to` address specified
    /// @param from Source address
    /// @param to Target address
    /// @param ids IDs of each token type (order and length must match _values array)
    /// @param amounts Transfer amounts per token type (order and length must match _ids array)
    function batchTransferFrom(address from, address to, uint256[] calldata ids, uint256[] calldata amounts) external;
}
