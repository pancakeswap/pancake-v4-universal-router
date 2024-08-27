// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {ERC721} from "solmate/src/tokens/ERC721.sol";

contract MockERC721 is ERC721 {
    constructor() ERC721("TEST", "test") {}

    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}
