// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

abstract contract Permit2ApproveHelper is Test {
    function permit2Approve(address from, IAllowanceTransfer _permit2, address _token, address _spender) internal {
        permit2ApproveWithSpecificAllowance(from, _permit2, _token, _spender, type(uint256).max, type(uint160).max);
    }

    function permit2ApproveWithSpecificAllowance(
        address from,
        IAllowanceTransfer _permit2,
        address _token,
        address _spender,
        uint256 _tokenApproveAllowance,
        uint160 _permit2ApproveAllowance
    ) internal {
        vm.startPrank(from);
        // permit2, we must execute 2 permits/approvals.
        // 1. First, the caller must approve permit2 on the token.
        IERC20(_token).approve(address(_permit2), _tokenApproveAllowance);
        // 2. Then, the caller must approve _spender as a spender of permit2. TODO: This could also be a signature.
        _permit2.approve(_token, _spender, _permit2ApproveAllowance, type(uint48).max);
        vm.stopPrank();
    }
}
