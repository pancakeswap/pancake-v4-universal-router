// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title Self Permit For ERC721
/// @notice Functionality to call permit on any EIP-2612-compliant token
/// This is for PancakeSwapV3 styled Nonfungible Position Manager which supports permit extension
interface ISelfPermitERC721 {
    /// @notice Permits this contract to spend a given position token from `msg.sender`
    /// @dev The `owner` is always msg.sender and the `spender` is always address(this).
    /// @param token The address of the token spent
    /// @param tokenId The token ID of the token spent
    /// @param deadline A timestamp, the current blocktime must be less than or equal to this timestamp
    /// @param v Must produce valid secp256k1 signature from the holder along with `r` and `s`
    /// @param r Must produce valid secp256k1 signature from the holder along with `v` and `s`
    /// @param s Must produce valid secp256k1 signature from the holder along with `r` and `v`
    function selfPermitERC721(address token, uint256 tokenId, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        payable;

    /// @notice Permits this contract to spend a given token from `msg.sender`
    /// @dev The `owner` is always msg.sender and the `spender` is always address(this).
    /// Please always use selfPermitERC721IfNecessary if possible prevent calls from failing due to a frontrun of a call to #selfPermitERC721.
    /// For details check https://github.com/pancakeswap/pancake-v4-periphery/pull/62#discussion_r1675410282
    /// @param token The address of the token spent
    /// @param tokenId The token ID of the token spent
    /// @param deadline A timestamp, the current blocktime must be less than or equal to this timestamp
    /// @param v Must produce valid secp256k1 signature from the holder along with `r` and `s`
    /// @param r Must produce valid secp256k1 signature from the holder along with `v` and `s`
    /// @param s Must produce valid secp256k1 signature from the holder along with `r` and `v`
    function selfPermitERC721IfNecessary(
        address token,
        uint256 tokenId,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable;
}
