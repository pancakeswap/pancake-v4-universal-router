// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {Vault} from "pancake-v4-core/src/Vault.sol";
import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {FixedPoint96} from "pancake-v4-core/src/pool-cl/libraries/FixedPoint96.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {SqrtPriceMath} from "pancake-v4-core/src/pool-cl/libraries/SqrtPriceMath.sol";
import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";
import {ActionConstants} from "pancake-v4-periphery/src/libraries/ActionConstants.sol";
import {Plan, Planner} from "pancake-v4-periphery/src/libraries/Planner.sol";
import {CLPositionManager} from "pancake-v4-periphery/src/pool-cl/CLPositionManager.sol";
import {Actions} from "pancake-v4-periphery/src/libraries/Actions.sol";
import {PositionConfig} from "pancake-v4-periphery/src/pool-cl/libraries/PositionConfig.sol";
import {ICLRouterBase} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {LiquidityAmounts} from "pancake-v4-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";
import {PathKey} from "pancake-v4-periphery/src/libraries/PathKey.sol";

import {BasePancakeSwapV4} from "./BasePancakeSwapV4.sol";
import {UniversalRouter} from "../../src/UniversalRouter.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {Commands} from "../../src/libraries/Commands.sol";
import {RouterParameters} from "../../src/base/RouterImmutables.sol";

/// @dev similar to CLPancakeSwapV4, except focus on native ETH transfers
contract CLNativePancakeSwapV4Test is BasePancakeSwapV4 {
    using CLPoolParametersHelper for bytes32;
    using Planner for Plan;

    IVault public vault;
    ICLPoolManager public poolManager;
    CLPositionManager public positionManager;
    IAllowanceTransfer permit2;
    WETH weth9 = new WETH();
    UniversalRouter router;

    PoolKey public poolKey0;

    MockERC20 token1;

    Plan plan;
    address alice = makeAddr("alice");
    uint160 constant SQRT_PRICE_1_1 = uint160(1 * FixedPoint96.Q96); // price 1

    function setUp() public {
        vault = IVault(new Vault());
        poolManager = new CLPoolManager(vault, 3000);
        vault.registerApp(address(poolManager));
        permit2 = IAllowanceTransfer(deployPermit2());

        initializeTokens();
        vm.label(Currency.unwrap(currency1), "token1");

        token1 = MockERC20(Currency.unwrap(currency1));

        positionManager = new CLPositionManager(vault, poolManager, permit2);
        _approvePermit2ForCurrency(address(this), currency1, address(positionManager), permit2);

        RouterParameters memory params = RouterParameters({
            permit2: address(permit2),
            weth9: address(weth9),
            v2Factory: address(0),
            v3Factory: address(0),
            v3Deployer: address(0),
            v2InitCodeHash: bytes32(0),
            v3InitCodeHash: bytes32(0),
            stableFactory: address(0),
            stableInfo: address(0),
            v4Vault: address(vault),
            v4ClPoolManager: address(poolManager),
            v4BinPoolManager: address(0),
            v3NFTPositionManager: address(0),
            v4ClPositionManager: address(positionManager),
            v4BinPositionManager: address(0)
        });
        router = new UniversalRouter(params);
        _approvePermit2ForCurrency(alice, currency1, address(router), permit2);

        poolKey0 = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            parameters: bytes32(0).setTickSpacing(10)
        });
        poolManager.initialize(poolKey0, SQRT_PRICE_1_1, new bytes(0));
        _mint(poolKey0);
    }

    function test_v4ClSwap_ExactInSingle_NativeIn() public {
        uint128 amountIn = 0.01 ether;
        vm.deal(alice, amountIn);
        vm.startPrank(alice);

        // prepare v4 swap input
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(poolKey0, true, amountIn, 0, 0, "");
        plan = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency0, poolKey0.currency1, ActionConstants.MSG_SENDER);

        // call v4_swap
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V4_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = data;

        // gas would be higher as its the first swap
        assertEq(alice.balance, 0.01 ether);
        assertEq(token1.balanceOf(alice), 0 ether);
        snapStart("CLNativePancakeSwapV4Test#test_v4ClSwap_ExactInSingle_NativeIn");
        router.execute{value: amountIn}(commands, inputs);
        snapEnd();
        assertEq(alice.balance, 0 ether);
        assertEq(token1.balanceOf(alice), 9969940541342903); // around 0.01 eth * 0.997 - slippage
    }

    function test_v4ClSwap_ExactInSingle_NativeOut() public {
        uint128 amountIn = 0.01 ether;
        MockERC20(Currency.unwrap(currency1)).mint(alice, amountIn);
        vm.startPrank(alice);

        // prepare v4 swap input
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(poolKey0, false, amountIn, 0, 0, "");
        plan = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency1, poolKey0.currency0, ActionConstants.MSG_SENDER);

        // call v4_swap
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V4_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = data;

        // gas would be higher as its the first swap
        assertEq(alice.balance, 0 ether);
        assertEq(token1.balanceOf(alice), 0.01 ether);
        snapStart("CLNativePancakeSwapV4Test#test_v4ClSwap_ExactInSingle_NativeOut");
        router.execute(commands, inputs);
        snapEnd();
        assertEq(alice.balance, 9969940541342903); // around 0.01 eth * 0.997 - slippage
        assertEq(token1.balanceOf(alice), 0);
    }

    function test_v4ClSwap_ExactInSingle_NativeOut_RouterRecipient() public {
        uint128 amountIn = 0.01 ether;
        MockERC20(Currency.unwrap(currency1)).mint(alice, amountIn);
        vm.startPrank(alice);

        // prepare v4 swap input
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(poolKey0, false, amountIn, 0, 0, "");
        plan = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency1, poolKey0.currency0, ActionConstants.ADDRESS_THIS);

        // call v4_swap
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V4_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = data;

        // gas would be higher as its the first swap
        assertEq(alice.balance, 0 ether);
        assertEq(token1.balanceOf(alice), 0.01 ether);
        router.execute(commands, inputs);
        assertEq(address(router).balance, 9969940541342903); // around 0.01 eth * 0.997 - slippage
        assertEq(token1.balanceOf(alice), 0);
    }

    /// @dev add 10 ether of token0, token1 at tick(-120, 120) to poolKey
    function _mint(PoolKey memory key) private {
        int24 tickLower = -120;
        int24 tickUpper = 120;

        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);
        uint256 liquidity =
            LiquidityAmounts.getLiquidityForAmounts(SQRT_PRICE_1_1, sqrtRatioAX96, sqrtRatioBX96, 10 ether, 10 ether); // around 1671 e18 liquidity

        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: tickLower, tickUpper: tickUpper});
        Plan memory mintPlan = Planner.init();
        mintPlan.add(
            Actions.CL_MINT_POSITION,
            abi.encode(config, liquidity, type(uint128).max, type(uint128).max, address(this), "")
        );

        bytes memory calls = mintPlan.finalizeModifyLiquidityWithClose(config.poolKey);
        positionManager.modifyLiquidities{value: 10 ether}(calls, block.timestamp + 1);
    }
}
