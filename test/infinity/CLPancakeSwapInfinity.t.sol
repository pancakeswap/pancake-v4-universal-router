// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IWETH9} from "infinity-periphery/src/interfaces/external/IWETH9.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {FixedPoint96} from "infinity-core/src/pool-cl/libraries/FixedPoint96.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {SqrtPriceMath} from "infinity-core/src/pool-cl/libraries/SqrtPriceMath.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {ActionConstants} from "infinity-periphery/src/libraries/ActionConstants.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";
import {CLPositionDescriptorOffChain} from "infinity-periphery/src/pool-cl/CLPositionDescriptorOffChain.sol";
import {CLPositionManager} from "infinity-periphery/src/pool-cl/CLPositionManager.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {ICLRouterBase} from "infinity-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {LiquidityAmounts} from "infinity-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";
import {PathKey} from "infinity-periphery/src/libraries/PathKey.sol";
import {CLPool} from "infinity-core/src/pool-cl/libraries/CLPool.sol";

import {BasePancakeSwapInfinity} from "./BasePancakeSwapInfinity.sol";
import {UniversalRouter} from "../../src/UniversalRouter.sol";
import {IUniversalRouter} from "../../src/interfaces/IUniversalRouter.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {Commands} from "../../src/libraries/Commands.sol";
import {RouterParameters} from "../../src/base/RouterImmutables.sol";

contract CLPancakeSwapInfinityTest is BasePancakeSwapInfinity {
    using CLPoolParametersHelper for bytes32;
    using Planner for Plan;

    IVault public vault;
    ICLPoolManager public poolManager;
    CLPositionManager public positionManager;
    IAllowanceTransfer permit2;
    WETH weth9 = new WETH();
    UniversalRouter router;

    PoolKey public poolKey0;
    PoolKey public poolKey1;

    MockERC20 token0;
    MockERC20 token1;
    MockERC20 token2;

    Plan plan;
    address alice = makeAddr("alice");
    uint160 constant SQRT_PRICE_1_1 = uint160(1 * FixedPoint96.Q96); // price 1

    function setUp() public {
        vault = IVault(new Vault());
        poolManager = new CLPoolManager(vault);
        vault.registerApp(address(poolManager));
        permit2 = IAllowanceTransfer(deployPermit2());

        initializeTokens();
        vm.label(Currency.unwrap(currency0), "token0");
        vm.label(Currency.unwrap(currency1), "token1");
        vm.label(Currency.unwrap(currency2), "token2");

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));
        token2 = MockERC20(Currency.unwrap(currency2));

        CLPositionDescriptorOffChain pd =
            new CLPositionDescriptorOffChain("https://pancakeswap.finance/infinity/pool-cl/positions/");
        positionManager = new CLPositionManager(vault, poolManager, permit2, 100_000, pd, IWETH9(address(weth9)));
        _approvePermit2ForCurrency(address(this), currency0, address(positionManager), permit2);
        _approvePermit2ForCurrency(address(this), currency1, address(positionManager), permit2);
        _approvePermit2ForCurrency(address(this), currency2, address(positionManager), permit2);

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
            infiVault: address(vault),
            infiClPoolManager: address(poolManager),
            infiBinPoolManager: address(0),
            v3NFTPositionManager: address(0),
            infiClPositionManager: address(positionManager),
            infiBinPositionManager: address(0)
        });
        router = new UniversalRouter(params);
        _approvePermit2ForCurrency(alice, currency0, address(router), permit2);
        _approvePermit2ForCurrency(alice, currency1, address(router), permit2);
        _approvePermit2ForCurrency(alice, currency2, address(router), permit2);

        poolKey0 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            parameters: bytes32(0).setTickSpacing(10)
        });
        poolManager.initialize(poolKey0, SQRT_PRICE_1_1);
        _mint(poolKey0);

        // initialize poolKey1 via universal-router
        poolKey1 = PoolKey({
            currency0: currency1,
            currency1: currency2,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            parameters: bytes32(0).setTickSpacing(10)
        });
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.INFI_CL_INITIALIZE_POOL)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(poolKey1, SQRT_PRICE_1_1);
        router.execute(commands, inputs);
        _mint(poolKey1);
    }

    function test_infiClSwap_infiInitializeClPool() public {
        PoolKey memory _poolKey = PoolKey({
            currency0: currency0,
            currency1: currency2,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            parameters: bytes32(0).setTickSpacing(10)
        });

        // before
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(_poolKey.toId());
        assertEq(sqrtPriceX96, 0);

        // initialize
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.INFI_CL_INITIALIZE_POOL)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(_poolKey, SQRT_PRICE_1_1);
        router.execute(commands, inputs);
        vm.snapshotGasLastCall("test_infiClSwap_infiInitializeClPool");

        // verify
        (sqrtPriceX96,,,) = poolManager.getSlot0(_poolKey.toId());
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1);

        // initialize again
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniversalRouter.ExecutionFailed.selector, 0, abi.encodePacked(CLPool.PoolAlreadyInitialized.selector)
            )
        );
        router.execute(commands, inputs);
    }

    function test_infiClSwap_ExactInSingle() public {
        uint128 amountIn = 0.01 ether;
        MockERC20(Currency.unwrap(currency0)).mint(alice, amountIn);
        vm.startPrank(alice);

        // prepare infinity swap input
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(poolKey0, true, amountIn, 0, "");
        plan = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency0, poolKey0.currency1, ActionConstants.MSG_SENDER);

        // call infi_swap
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.INFI_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = data;

        // gas would be higher as its the first swap
        assertEq(token0.balanceOf(alice), 0.01 ether);
        assertEq(token1.balanceOf(alice), 0 ether);
        router.execute(commands, inputs);
        vm.snapshotGasLastCall("test_infiClSwap_ExactInSingle");
        assertEq(token0.balanceOf(alice), 0 ether);
        assertEq(token1.balanceOf(alice), 9969940541342903); // around 0.01 eth * 0.997 - slippage
    }

    function test_infiClSwap_ExactIn_SingleHop() public {
        uint128 amountIn = 0.01 ether;
        MockERC20(Currency.unwrap(currency0)).mint(alice, amountIn);
        vm.startPrank(alice);

        // prepare infinity swap input
        PathKey[] memory path = new PathKey[](1);
        path[0] = PathKey({
            intermediateCurrency: currency1,
            fee: poolKey0.fee,
            hooks: poolKey0.hooks,
            hookData: "",
            poolManager: poolKey0.poolManager,
            parameters: poolKey0.parameters
        });
        ICLRouterBase.CLSwapExactInputParams memory params =
            ICLRouterBase.CLSwapExactInputParams(currency0, path, 0.01 ether, 0);
        plan = Planner.init().add(Actions.CL_SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency1, ActionConstants.MSG_SENDER);

        // call infi_swap
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.INFI_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = data;

        // gas would be higher as its the first swap
        assertEq(token0.balanceOf(alice), 0.01 ether);
        assertEq(token1.balanceOf(alice), 0 ether);
        router.execute(commands, inputs);
        vm.snapshotGasLastCall("test_infiClSwap_ExactIn_SingleHop");
        assertEq(token0.balanceOf(alice), 0 ether);
        assertEq(token1.balanceOf(alice), 9969940541342903); // around 0.01 eth * 0.997 - slippage
    }

    function test_infiClSwap_ExactIn_MultiHop() public {
        uint128 amountIn = 0.01 ether;
        MockERC20(Currency.unwrap(currency0)).mint(alice, amountIn);
        vm.startPrank(alice);

        // prepare infinity swap input
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: currency1,
            fee: poolKey0.fee,
            hooks: poolKey0.hooks,
            hookData: "",
            poolManager: poolKey0.poolManager,
            parameters: poolKey0.parameters
        });
        path[1] = PathKey({
            intermediateCurrency: currency2,
            fee: poolKey1.fee,
            hooks: poolKey1.hooks,
            hookData: "",
            poolManager: poolKey1.poolManager,
            parameters: poolKey1.parameters
        });
        ICLRouterBase.CLSwapExactInputParams memory params =
            ICLRouterBase.CLSwapExactInputParams(currency0, path, 0.01 ether, 0);
        plan = Planner.init().add(Actions.CL_SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency2, ActionConstants.MSG_SENDER);

        // call infi_swap
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.INFI_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = data;

        // gas would be higher as its the first swap
        assertEq(token0.balanceOf(alice), 0.01 ether);
        assertEq(token2.balanceOf(alice), 0 ether);
        router.execute(commands, inputs);
        vm.snapshotGasLastCall("test_infiClSwap_ExactIn_MultiHop");
        assertEq(token0.balanceOf(alice), 0 ether);
        assertEq(token2.balanceOf(alice), 9939971617982475); // around 0.01 eth - fee/slippage
    }

    function test_infiClSwap_ExactOutSingle() public {
        uint128 amountOut = 0.01 ether;
        MockERC20(Currency.unwrap(currency0)).mint(alice, amountOut * 2); // *2 to handle slippage
        vm.startPrank(alice);

        // prepare infinity swap input
        ICLRouterBase.CLSwapExactOutputSingleParams memory params =
            ICLRouterBase.CLSwapExactOutputSingleParams(poolKey0, true, amountOut, amountOut * 2, "");
        plan = Planner.init().add(Actions.CL_SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency0, poolKey0.currency1, ActionConstants.MSG_SENDER);

        // call infi_swap
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.INFI_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = data;

        // gas would be higher as its the first swap
        assertEq(token0.balanceOf(alice), 0.02 ether);
        assertEq(token1.balanceOf(alice), 0 ether);
        router.execute(commands, inputs);
        vm.snapshotGasLastCall("test_infiClSwap_ExactOutSingle");
        assertEq(token0.balanceOf(alice), 9969849731458956); // around 0.02 eth - 0.01 eth - slippage
        assertEq(token1.balanceOf(alice), 0.01 ether);
    }

    function test_infiClSwap_ExactOut_SingleHop() public {
        uint128 amountOut = 0.01 ether;
        MockERC20(Currency.unwrap(currency0)).mint(alice, amountOut * 2); // *2 to handle slippage
        vm.startPrank(alice);

        // prepare infinity swap input
        PathKey[] memory path = new PathKey[](1);
        path[0] = PathKey({
            intermediateCurrency: currency0,
            fee: poolKey0.fee,
            hooks: poolKey0.hooks,
            hookData: "",
            poolManager: poolKey0.poolManager,
            parameters: poolKey0.parameters
        });
        ICLRouterBase.CLSwapExactOutputParams memory params =
            ICLRouterBase.CLSwapExactOutputParams(currency1, path, amountOut, amountOut * 2);
        plan = Planner.init().add(Actions.CL_SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency1, ActionConstants.MSG_SENDER);

        // call infi_swap
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.INFI_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = data;

        // gas would be higher as its the first swap
        assertEq(token0.balanceOf(alice), 0.02 ether);
        assertEq(token1.balanceOf(alice), 0 ether);
        router.execute(commands, inputs);
        vm.snapshotGasLastCall("test_infiClSwap_ExactOut_SingleHop");
        assertEq(token0.balanceOf(alice), 9969849731458956); // around 0.02 eth - 0.01 eth - slippage
        assertEq(token1.balanceOf(alice), 0.01 ether);
    }

    function test_infiClSwap_ExactOut_MultiHop() public {
        uint128 amountOut = 0.01 ether;
        MockERC20(Currency.unwrap(currency0)).mint(alice, amountOut * 2); // *2 to handle slippage
        vm.startPrank(alice);

        // prepare infinity swap input
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: currency0,
            fee: poolKey0.fee,
            hooks: poolKey0.hooks,
            hookData: "",
            poolManager: poolKey0.poolManager,
            parameters: poolKey0.parameters
        });
        path[1] = PathKey({
            intermediateCurrency: currency1,
            fee: poolKey1.fee,
            hooks: poolKey1.hooks,
            hookData: "",
            poolManager: poolKey1.poolManager,
            parameters: poolKey1.parameters
        });
        ICLRouterBase.CLSwapExactOutputParams memory params =
            ICLRouterBase.CLSwapExactOutputParams(currency2, path, amountOut, amountOut * 2);
        plan = Planner.init().add(Actions.CL_SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency2, ActionConstants.MSG_SENDER);

        // call infi_swap
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.INFI_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = data;

        // gas would be higher as its the first swap
        assertEq(token0.balanceOf(alice), 0.02 ether);
        assertEq(token2.balanceOf(alice), 0 ether);
        router.execute(commands, inputs);
        vm.snapshotGasLastCall("test_infiClSwap_ExactOut_MultiHop");
        assertEq(token0.balanceOf(alice), 9939608377607349);
        assertEq(token2.balanceOf(alice), 0.01 ether);
    }

    /// @dev add 10 ether of token0, token1 at tick(-120, 120) to poolKey
    function _mint(PoolKey memory key) private {
        int24 tickLower = -120;
        int24 tickUpper = 120;

        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);
        uint256 liquidity =
            LiquidityAmounts.getLiquidityForAmounts(SQRT_PRICE_1_1, sqrtRatioAX96, sqrtRatioBX96, 10 ether, 10 ether); // around 1671 e18 liquidity

        Plan memory mintPlan = Planner.init();
        mintPlan.add(
            Actions.CL_MINT_POSITION,
            abi.encode(key, tickLower, tickUpper, liquidity, type(uint128).max, type(uint128).max, address(this), "")
        );

        bytes memory calls = mintPlan.finalizeModifyLiquidityWithClose(key);
        positionManager.modifyLiquidities(calls, block.timestamp + 1);
    }
}
