// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";
import {LiquidityAmounts} from "pancake-v4-core/test/pool-cl/helpers/LiquidityAmounts.sol";
import {CLPosition} from "pancake-v4-core/src/pool-cl/libraries/CLPosition.sol";
import {Constants} from "pancake-v4-core/test/pool-cl/helpers/Constants.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {ICLPositionManager} from "../../../src/pool-cl/interfaces/ICLPositionManager.sol";
import {CLPositionManager} from "../../../src/pool-cl/CLPositionManager.sol";
import {PositionConfig} from "../../../src/pool-cl/libraries/PositionConfig.sol";
import {ActionConstants} from "../../../src/libraries/ActionConstants.sol";
import {Actions} from "../../../src/libraries/Actions.sol";

import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";
import {Planner, Plan} from "../../../src/libraries/Planner.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";

contract ExecuteTest is Test, PosmTestSetup, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using Planner for Plan;

    IVault vault;
    ICLPoolManager manager;

    PoolId poolId;
    PoolKey key;
    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");

    PositionConfig config;

    function setUp() public {
        // This is needed to receive return deltas from modifyLiquidity calls.
        deployPosmHookSavesDelta();

        (vault, manager, key, poolId) = createFreshPool(IHooks(address(hook)), 3000, SQRT_RATIO_1_1, ZERO_BYTES);

        currency0 = key.currency0;
        currency1 = key.currency1;

        // Requires currency0 and currency1 to be set in base Deployers contract.
        deployAndApprovePosm(vault, manager);

        // Give tokens to Alice and Bob.
        seedBalance(alice);
        seedBalance(bob);

        // Approve posm for Alice and bob.
        approvePosmFor(alice);
        approvePosmFor(bob);

        // define a reusable pool position
        config = PositionConfig({poolKey: key, tickLower: -300, tickUpper: 300});
    }

    function test_fuzz_execute_increaseLiquidity_once(uint256 initialLiquidity, uint256 liquidityToAdd) public {
        initialLiquidity = bound(initialLiquidity, 1e18, 1000e18);
        liquidityToAdd = bound(liquidityToAdd, 1e18, 1000e18);
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        increaseLiquidity(tokenId, config, liquidityToAdd, ZERO_BYTES);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId, config);

        assertEq(liquidity, initialLiquidity + liquidityToAdd);
    }

    function test_fuzz_execute_increaseLiquidity_twice_withClose(
        uint256 initialLiquidity,
        uint256 liquidityToAdd,
        uint256 liquidityToAdd2
    ) public {
        initialLiquidity = bound(initialLiquidity, 1e18, 1000e18);
        liquidityToAdd = bound(liquidityToAdd, 1e18, 1000e18);
        liquidityToAdd2 = bound(liquidityToAdd2, 1e18, 1000e18);
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory planner = Planner.init();

        planner.add(
            Actions.CL_INCREASE_LIQUIDITY,
            abi.encode(tokenId, config, liquidityToAdd, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        planner.add(
            Actions.CL_INCREASE_LIQUIDITY,
            abi.encode(tokenId, config, liquidityToAdd2, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );

        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);
        lpm.modifyLiquidities(calls, _deadline);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId, config);

        assertEq(liquidity, initialLiquidity + liquidityToAdd + liquidityToAdd2);
    }

    function test_fuzz_execute_increaseLiquidity_twice_withSettlePair(
        uint256 initialLiquidity,
        uint256 liquidityToAdd,
        uint256 liquidityToAdd2
    ) public {
        initialLiquidity = bound(initialLiquidity, 1e18, 1000e18);
        liquidityToAdd = bound(liquidityToAdd, 1e18, 1000e18);
        liquidityToAdd2 = bound(liquidityToAdd2, 1e18, 1000e18);
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        Plan memory planner = Planner.init();

        planner.add(
            Actions.CL_INCREASE_LIQUIDITY,
            abi.encode(tokenId, config, liquidityToAdd, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        planner.add(
            Actions.CL_INCREASE_LIQUIDITY,
            abi.encode(tokenId, config, liquidityToAdd2, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );

        bytes memory calls = planner.finalizeModifyLiquidityWithSettlePair(config.poolKey);
        lpm.modifyLiquidities(calls, _deadline);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId, config);

        assertEq(liquidity, initialLiquidity + liquidityToAdd + liquidityToAdd2);
    }

    // this case doesnt make sense in real world usage, so it doesnt have a cool name. but its a good test case
    function test_fuzz_execute_mintAndIncrease(uint256 initialLiquidity, uint256 liquidityToAdd) public {
        initialLiquidity = bound(initialLiquidity, 1e18, 1000e18);
        liquidityToAdd = bound(liquidityToAdd, 1e18, 1000e18);

        uint256 tokenId = lpm.nextTokenId(); // assume that the .mint() produces tokenId=1, to be used in increaseLiquidity

        Plan memory planner = Planner.init();

        planner.add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                config,
                initialLiquidity,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        planner.add(
            Actions.CL_INCREASE_LIQUIDITY,
            abi.encode(tokenId, config, liquidityToAdd, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );

        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);
        lpm.modifyLiquidities(calls, _deadline);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId, config);

        assertEq(liquidity, initialLiquidity + liquidityToAdd);
    }

    // rebalance: burn and mint
    function test_execute_rebalance_perfect() public {
        uint256 initialLiquidity = 100e18;

        // mint a position on range [-300, 300]
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();

        // we'll burn and mint a new position on [-60, 60]; calculate the liquidity units for the new range
        PositionConfig memory newConfig = PositionConfig({poolKey: config.poolKey, tickLower: -60, tickUpper: 60});
        uint128 newLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_RATIO_1_1,
            TickMath.getSqrtRatioAtTick(newConfig.tickLower),
            TickMath.getSqrtRatioAtTick(newConfig.tickUpper),
            uint128(-delta.amount0()),
            uint128(-delta.amount1())
        );

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        hook.clearDeltas(); // clear the delta so that we can check the net delta for BURN & MINT

        Plan memory planner = Planner.init();
        planner.add(
            Actions.CL_BURN_POSITION,
            abi.encode(
                tokenId, config, uint128(-delta.amount0()) - 1 wei, uint128(-delta.amount1()) - 1 wei, ZERO_BYTES
            )
        );
        planner.add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                newConfig,
                newLiquidity,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);

        lpm.modifyLiquidities(calls, _deadline);
        {
            BalanceDelta netDelta = getNetDelta();

            uint256 balance0After = currency0.balanceOfSelf();
            uint256 balance1After = currency1.balanceOfSelf();

            // TODO: use clear so user does not pay 1 wei
            assertEq(netDelta.amount0(), -1 wei);
            assertEq(netDelta.amount1(), -1 wei);
            assertApproxEqAbs(balance0Before - balance0After, 0, 1 wei);
            assertApproxEqAbs(balance1Before - balance1After, 0, 1 wei);
        }

        // old position was burned
        vm.expectRevert();
        lpm.ownerOf(tokenId);

        {
            // old position has no liquidity
            uint128 liquidity = lpm.getPositionLiquidity(tokenId, config);
            assertEq(liquidity, 0);

            // new token was minted
            uint256 newTokenId = lpm.nextTokenId() - 1;
            assertEq(lpm.ownerOf(newTokenId), address(this));

            // new token has expected liquidity

            liquidity = lpm.getPositionLiquidity(newTokenId, newConfig);
            assertEq(liquidity, newLiquidity);
        }
    }
}
