// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IStableSwapInfo {
    function get_dx(address _swap, uint256 i, uint256 j, uint256 dy, uint256 max_dx) external view returns (uint256);
}
