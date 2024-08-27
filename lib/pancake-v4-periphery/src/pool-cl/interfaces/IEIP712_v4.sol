// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IEIP712_v4 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
