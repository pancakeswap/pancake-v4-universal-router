// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";

import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {PoolId} from "pancake-v4-core/src/types/PoolId.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {Vault} from "pancake-v4-core/src/Vault.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BinPoolManager} from "pancake-v4-core/src/pool-bin/BinPoolManager.sol";
import {BinPoolParametersHelper} from "pancake-v4-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";
import {FixedPoint96} from "pancake-v4-core/src/pool-cl/libraries/FixedPoint96.sol";

import {Actions} from "pancake-v4-periphery/src/libraries/Actions.sol";
import {IWETH9} from "pancake-v4-periphery/src/interfaces/external/IWETH9.sol";
import {BinPositionManager} from "pancake-v4-periphery/src/pool-bin/BinPositionManager.sol";
import {CLPositionManager} from "pancake-v4-periphery/src/pool-cl/CLPositionManager.sol";
import {CLPositionDescriptorOffChain} from "pancake-v4-periphery/src/pool-cl/CLPositionDescriptorOffChain.sol";
import {Plan, Planner} from "pancake-v4-periphery/src/libraries/Planner.sol";
import {BinLiquidityHelper} from "pancake-v4-periphery/test/pool-bin/helper/BinLiquidityHelper.sol";
import {LiquidityAmounts} from "pancake-v4-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";
import {IBinPositionManager} from "pancake-v4-periphery/src/pool-bin/interfaces/IBinPositionManager.sol";
import {ICLRouterBase} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {IBinRouterBase} from "pancake-v4-periphery/src/pool-bin/interfaces/IBinRouterBase.sol";

import {UniversalRouter} from "../src/UniversalRouter.sol";
import {Dispatcher} from "../src/base/Dispatcher.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {Payments} from "../src/modules/Payments.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {BasePancakeSwapV4} from "./v4/BasePancakeSwapV4.sol";
import {QaSwapRouter} from "../src/QaSwapRouter.sol";

contract QaSwapRouterTest is BasePancakeSwapV4, BinLiquidityHelper {
    using BinPoolParametersHelper for bytes32;
    using CLPoolParametersHelper for bytes32;
    using Planner for Plan;

    QaSwapRouter router;
    MockERC20 erc20;
    MockERC20 erc20_2;

    IVault public vault;
    ICLPoolManager public clPoolManager;
    CLPositionManager public clPositionManager;
    IBinPoolManager public binPoolManager;
    BinPositionManager public binPositionManager;

    WETH weth9 = new WETH();
    IAllowanceTransfer permit2;

    address alice = makeAddr("alice");
    uint160 constant SQRT_PRICE_1_1 = uint160(1 * FixedPoint96.Q96); // price 1
    uint24 constant ACTIVE_ID_1_1 = 2 ** 23; // where token0 and token1 price is the same

    MockERC20 token0;
    MockERC20 token1;

    PoolKey public clPoolKey;
    PoolKey public clNativePoolKey;
    PoolKey public binPoolKey;
    PoolKey public binNativePoolKey;

    function setUp() public {
        initializeTokens();
        vm.label(Currency.unwrap(currency0), "token0");
        vm.label(Currency.unwrap(currency1), "token1");

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        // pre-req: create vault
        vault = IVault(new Vault());
        clPoolManager = new CLPoolManager(vault);
        binPoolManager = new BinPoolManager(vault);
        vault.registerApp(address(clPoolManager));
        vault.registerApp(address(binPoolManager));

        permit2 = IAllowanceTransfer(deployPermit2());

        CLPositionDescriptorOffChain pd =
            new CLPositionDescriptorOffChain("https://pancakeswap.finance/v4/pool-cl/positions/");
        clPositionManager = new CLPositionManager(vault, clPoolManager, permit2, 100_000, pd, IWETH9(address(weth9)));
        binPositionManager = new BinPositionManager(vault, binPoolManager, permit2, IWETH9(address(weth9)));
        _approvePermit2ForCurrency(address(this), currency0, address(clPositionManager), permit2);
        _approvePermit2ForCurrency(address(this), currency1, address(clPositionManager), permit2);
        _approvePermit2ForCurrency(address(this), currency0, address(binPositionManager), permit2);
        _approvePermit2ForCurrency(address(this), currency1, address(binPositionManager), permit2);

        router = new QaSwapRouter(vault, clPoolManager, binPoolManager, permit2);
        _approvePermit2ForCurrency(alice, currency0, address(router), permit2);
        _approvePermit2ForCurrency(alice, currency1, address(router), permit2);

        clPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: clPoolManager,
            fee: uint24(3000),
            parameters: bytes32(0).setTickSpacing(10)
        });
        clPoolManager.initialize(clPoolKey, SQRT_PRICE_1_1);
        _mintCl(clPoolKey);

        clNativePoolKey = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: clPoolManager,
            fee: uint24(3000),
            parameters: bytes32(0).setTickSpacing(10)
        });
        clPoolManager.initialize(clNativePoolKey, SQRT_PRICE_1_1);
        _mintCl(clNativePoolKey);

        binPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: binPoolManager,
            fee: uint24(3000),
            parameters: bytes32(0).setBinStep(10)
        });
        binPoolManager.initialize(binPoolKey, ACTIVE_ID_1_1);
        _mintBin(binPoolKey);

        binNativePoolKey = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: binPoolManager,
            fee: uint24(3000),
            parameters: bytes32(0).setBinStep(10)
        });
        binPoolManager.initialize(binNativePoolKey, ACTIVE_ID_1_1);
        _mintBin(binNativePoolKey);
    }

    function test_clSwapExactInputSingle_ZeroForOne() external {
        uint128 amountIn = 0.01 ether;
        MockERC20(Currency.unwrap(currency0)).mint(alice, amountIn);
        vm.startPrank(alice);

        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(clPoolKey, true, amountIn, 0, "");

        // before
        assertEq(token0.balanceOf(alice), 0.01 ether);
        assertEq(token1.balanceOf(alice), 0 ether);

        router.clSwapExactInputSingle(params);

        // after
        assertEq(token0.balanceOf(alice), 0);
        assertEq(token1.balanceOf(alice), 9969940541342903);
    }

    function test_clSwapExactInputSingle_OneForZero() external {
        uint128 amountIn = 0.01 ether;
        MockERC20(Currency.unwrap(currency1)).mint(alice, amountIn);
        vm.startPrank(alice);

        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(clPoolKey, false, amountIn, 0, "");

        // before
        assertEq(token0.balanceOf(alice), 0 ether);
        assertEq(token1.balanceOf(alice), 0.01 ether);

        router.clSwapExactInputSingle(params);

        // after
        assertEq(token0.balanceOf(alice), 9969940541342903);
        assertEq(token1.balanceOf(alice), 0);
    }

    function test_clSwapExactInputSingle_NativePool() external {
        uint128 amountIn = 0.01 ether;
        vm.deal(alice, amountIn);
        vm.startPrank(alice);

        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(clNativePoolKey, true, amountIn, 0, "");

        // before
        assertEq(alice.balance, 0.01 ether);
        assertEq(token1.balanceOf(alice), 0 ether);

        router.clSwapExactInputSingle{value: amountIn}(params);

        // after
        assertEq(alice.balance, 0);
        assertEq(token1.balanceOf(alice), 9969940541342903);
    }

    function test_clSwapExactInputSingle_NativePool_PoolId() external {
        uint128 amountIn = 0.01 ether;
        vm.deal(alice, amountIn);
        vm.startPrank(alice);

        // before
        assertEq(alice.balance, 0.01 ether);
        assertEq(token1.balanceOf(alice), 0 ether);

        router.clSwapExactInputSingle{value: amountIn}(clNativePoolKey.toId(), true, amountIn, 0, "");

        // after
        assertEq(alice.balance, 0);
        assertEq(token1.balanceOf(alice), 9969940541342903);
    }

    function test_binSwapExactInputSingle_NativePool() external {
        uint128 amountIn = 0.01 ether;
        vm.deal(alice, amountIn);
        vm.startPrank(alice);

        IBinRouterBase.BinSwapExactInputSingleParams memory params =
            IBinRouterBase.BinSwapExactInputSingleParams(binNativePoolKey, true, amountIn, 0, "");

        // before
        assertEq(alice.balance, 0.01 ether);
        assertEq(token1.balanceOf(alice), 0 ether);

        router.binSwapExactInputSingle{value: amountIn}(params);

        // after
        assertEq(alice.balance, 0);
        assertEq(token1.balanceOf(alice), 9970000000000000); // 0.01 eth * 0.997
    }

    function test_binSwapExactInputSingle_ZeroForOne() external {
        uint128 amountIn = 0.01 ether;
        MockERC20(Currency.unwrap(currency0)).mint(alice, amountIn);
        vm.startPrank(alice);

        IBinRouterBase.BinSwapExactInputSingleParams memory params =
            IBinRouterBase.BinSwapExactInputSingleParams(binPoolKey, true, amountIn, 0, "");

        // before
        assertEq(token0.balanceOf(alice), 0.01 ether);
        assertEq(token1.balanceOf(alice), 0 ether);

        router.binSwapExactInputSingle(params);

        // after
        assertEq(token0.balanceOf(alice), 0 ether);
        assertEq(token1.balanceOf(alice), 9970000000000000); // 0.01 eth * 0.997
    }

    function test_binSwapExactInputSingle_OneForZero() external {
        uint128 amountIn = 0.01 ether;
        MockERC20(Currency.unwrap(currency1)).mint(alice, amountIn);
        vm.startPrank(alice);

        IBinRouterBase.BinSwapExactInputSingleParams memory params =
            IBinRouterBase.BinSwapExactInputSingleParams(binPoolKey, false, amountIn, 0, "");

        // before
        assertEq(token0.balanceOf(alice), 0 ether);
        assertEq(token1.balanceOf(alice), 0.01 ether);

        router.binSwapExactInputSingle(params);

        // after
        assertEq(token0.balanceOf(alice), 9970000000000000);
        assertEq(token1.balanceOf(alice), 0 ether); // 0.01 eth * 0.997
    }

    function test_binSwapExactInputSingle_OneForZero_poolId() external {
        uint128 amountIn = 0.01 ether;
        MockERC20(Currency.unwrap(currency1)).mint(alice, amountIn);
        vm.startPrank(alice);

        // before
        assertEq(token0.balanceOf(alice), 0 ether);
        assertEq(token1.balanceOf(alice), 0.01 ether);

        router.binSwapExactInputSingle(binPoolKey.toId(), false, amountIn, 0, "");

        // after
        assertEq(token0.balanceOf(alice), 9970000000000000);
        assertEq(token1.balanceOf(alice), 0 ether); // 0.01 eth * 0.997
    }

    function test_poolKeyToPoolId() external {
        bytes32 clPoolId = router.poolKeyToPoolId(
            clPoolKey.currency0,
            clPoolKey.currency1,
            clPoolKey.hooks,
            clPoolKey.poolManager,
            clPoolKey.fee,
            clPoolKey.parameters
        );
        assertEq(clPoolId, PoolId.unwrap(clPoolKey.toId()));

        bytes32 binNativePoolId = router.poolKeyToPoolId(
            binNativePoolKey.currency0,
            binNativePoolKey.currency1,
            binNativePoolKey.hooks,
            binNativePoolKey.poolManager,
            binNativePoolKey.fee,
            binNativePoolKey.parameters
        );
        assertEq(binNativePoolId, PoolId.unwrap(binNativePoolKey.toId()));
    }

    /// @dev add 10 ether of token0, token1 at tick(-120, 120) to poolKey
    function _mintCl(PoolKey memory key) private {
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

        if (key.currency0 == CurrencyLibrary.NATIVE) {
            clPositionManager.modifyLiquidities{value: 10 ether}(calls, block.timestamp + 1);
        } else {
            clPositionManager.modifyLiquidities(calls, block.timestamp + 1);
        }
    }

    function _mintBin(PoolKey memory key) private {
        uint24[] memory binIds = getBinIds(ACTIVE_ID_1_1, 1);
        IBinPositionManager.BinAddLiquidityParams memory addParams;
        addParams = _getAddParams(key, binIds, 10 ether, 10 ether, ACTIVE_ID_1_1, address(this));

        Plan memory planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(addParams));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key);

        if (key.currency0 == CurrencyLibrary.NATIVE) {
            binPositionManager.modifyLiquidities{value: 10 ether}(payload, block.timestamp + 1);
        } else {
            binPositionManager.modifyLiquidities(payload, block.timestamp + 1);
        }
    }
}
