// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Permit} from "../pool-cl/interfaces/IERC721Permit.sol";
import {ISelfPermitERC721} from "../interfaces/ISelfPermitERC721.sol";

/// @title Self Permit For ERC721
/// @notice Functionality to call permit on any EIP-2612-compliant token for use in the route
/// @dev These functions are expected to be embedded in multicalls to allow EOAs to approve a contract and call a function
/// that requires an approval in a single transaction.
abstract contract SelfPermitERC721 is ISelfPermitERC721 {
    /// @inheritdoc ISelfPermitERC721
    function selfPermitERC721(address token, uint256 tokenId, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        public
        payable
        override
    {
        IERC721Permit(token).permit(address(this), tokenId, deadline, v, r, s);
    }

    /// @inheritdoc ISelfPermitERC721
    function selfPermitERC721IfNecessary(
        address token,
        uint256 tokenId,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable override {
        if (
            IERC721(token).getApproved(tokenId) != address(this)
                && !IERC721(token).isApprovedForAll(IERC721(token).ownerOf(tokenId), address(this))
        ) {
            selfPermitERC721(token, tokenId, deadline, v, r, s);
        }
    }
}
