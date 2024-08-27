// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {Hooks} from "pancake-v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {Deployers} from "pancake-v4-core/test/pool-cl/helpers/Deployers.sol";
import {CLPositionManager} from "../../../src/pool-cl/CLPositionManager.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {CLLiquidityOperations} from "./CLLiquidityOperations.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {HookSavesDelta} from "./HookSavesDelta.sol";
import {HookModifyLiquidities} from "./HookModifyLiquidities.sol";
import {ERC721PermitHashLibrary} from "../../../src/pool-cl/libraries/ERC721PermitHash.sol";
import {CLPoolManagerRouter} from "pancake-v4-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

/// @notice A shared test contract that wraps the v4-core deployers contract and exposes basic liquidity operations on posm.
contract PosmTestSetup is Test, Deployers, DeployPermit2, CLLiquidityOperations {
    CLPoolManagerRouter router;
    Currency currency0;
    Currency currency1;

    uint256 constant STARTING_USER_BALANCE = 10_000_000 ether;

    IAllowanceTransfer permit2;
    HookSavesDelta hook;

    HookModifyLiquidities hookModifyLiquidities;

    function deployAndApproveRouter(IVault vault, ICLPoolManager poolManager) public {
        router = new CLPoolManagerRouter(vault, poolManager);
        if (!currency0.isNative()) {
            IERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        }
        IERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
    }

    function deployPosmHookSavesDelta() public {
        hook = new HookSavesDelta();
    }

    /// @dev deploys a special test hook where beforeSwap hookData is used to modify liquidity
    function deployPosmHookModifyLiquidities() public {
        hookModifyLiquidities = new HookModifyLiquidities();

        // set posm address since constructor args are not easily copied by vm.etch
        hookModifyLiquidities.setAddresses(lpm, permit2);
    }

    function deployAndApprovePosm(IVault vault, ICLPoolManager poolManager) public {
        deployPosm(vault, poolManager);
        approvePosm();
    }

    function deployPosm(IVault vault, ICLPoolManager poolManager) internal {
        // We use deployPermit2() to prevent having to use via-ir in this repository.
        permit2 = IAllowanceTransfer(deployPermit2());
        lpm = new CLPositionManager(vault, poolManager, permit2);
    }

    function seedBalance(address to) internal {
        IERC20(Currency.unwrap(currency0)).transfer(to, STARTING_USER_BALANCE);
        IERC20(Currency.unwrap(currency1)).transfer(to, STARTING_USER_BALANCE);
    }

    function approvePosm() internal {
        approvePosmCurrency(currency0);
        approvePosmCurrency(currency1);
    }

    function approvePosmCurrency(Currency currency) internal {
        // Because POSM uses permit2, we must execute 2 permits/approvals.
        // 1. First, the caller must approve permit2 on the token.
        IERC20(Currency.unwrap(currency)).approve(address(permit2), type(uint256).max);
        // 2. Then, the caller must approve POSM as a spender of permit2. TODO: This could also be a signature.
        permit2.approve(Currency.unwrap(currency), address(lpm), type(uint160).max, type(uint48).max);
    }

    // Does the same approvals as approvePosm, but for a specific address.
    function approvePosmFor(address addr) internal {
        vm.startPrank(addr);
        approvePosm();
        vm.stopPrank();
    }

    function permit(uint256 privateKey, uint256 tokenId, address operator, uint256 nonce) internal {
        bytes32 digest = getDigest(operator, tokenId, 1, block.timestamp + 1);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(operator);
        lpm.permit(operator, tokenId, block.timestamp + 1, nonce, signature);
    }

    function getDigest(address spender, uint256 tokenId, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32 digest)
    {
        digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                lpm.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(ERC721PermitHashLibrary.PERMIT_TYPEHASH, spender, tokenId, nonce, deadline))
            )
        );
    }

    function getLastDelta() internal view returns (BalanceDelta delta) {
        delta = hook.deltas(hook.numberDeltasReturned() - 1); // just want the most recently written delta
    }

    function getNetDelta() internal view returns (BalanceDelta delta) {
        uint256 numDeltas = hook.numberDeltasReturned();
        for (uint256 i = 0; i < numDeltas; i++) {
            delta = delta + hook.deltas(i);
        }
    }

    /// @notice Helper function for a simple ERC20 swaps that allows for unlimited price impact
    function swap(PoolKey memory _key, bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        // allow native input for exact-input, guide users to the `swapNativeInput` function
        bool isNativeInput = zeroForOne && _key.currency0.isNative();
        if (isNativeInput) require(0 > amountSpecified, "Use swapNativeInput() for native-token exact-output swaps");

        uint256 value = isNativeInput ? uint256(-amountSpecified) : 0;

        return router.swap{value: value}(
            _key,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            hookData
        );
    }
}
