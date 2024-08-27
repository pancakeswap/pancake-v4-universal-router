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
import {BinPoolManager} from "pancake-v4-core/src/pool-bin/BinPoolManager.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {BinPoolParametersHelper} from "pancake-v4-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {ActionConstants} from "pancake-v4-periphery/src/libraries/ActionConstants.sol";
import {Plan, Planner} from "pancake-v4-periphery/src/libraries/Planner.sol";
import {BinPositionManager} from "pancake-v4-periphery/src/pool-bin/BinPositionManager.sol";
import {Actions} from "pancake-v4-periphery/src/libraries/Actions.sol";
import {IBinRouterBase} from "pancake-v4-periphery/src/pool-bin/interfaces/IBinRouterBase.sol";
import {BinLiquidityHelper} from "pancake-v4-periphery/test/pool-bin/helper/BinLiquidityHelper.sol";
import {IBinPositionManager} from "pancake-v4-periphery/src/pool-bin/interfaces/IBinPositionManager.sol";
import {PathKey} from "pancake-v4-periphery/src/libraries/PathKey.sol";

import {BasePancakeSwapV4} from "./BasePancakeSwapV4.sol";
import {UniversalRouter} from "../../src/UniversalRouter.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {Commands} from "../../src/libraries/Commands.sol";
import {RouterParameters} from "../../src/base/RouterImmutables.sol";

/// @dev similar to BinPancakeSwapV4, except focus on native ETH transfers
contract BinNativePancakeSwapV4Test is BasePancakeSwapV4, BinLiquidityHelper {
    using BinPoolParametersHelper for bytes32;
    using Planner for Plan;

    IVault public vault;
    IBinPoolManager public poolManager;
    BinPositionManager public positionManager;
    IAllowanceTransfer permit2;
    WETH weth9 = new WETH();
    UniversalRouter router;

    PoolKey public poolKey0;

    MockERC20 token1;

    Plan plan;
    address alice = makeAddr("alice");
    uint24 constant ACTIVE_ID_1_1 = 2 ** 23; // where token0 and token1 price is the same

    function setUp() public {
        vault = IVault(new Vault());
        poolManager = new BinPoolManager(vault, 500000);
        vault.registerApp(address(poolManager));
        permit2 = IAllowanceTransfer(deployPermit2());

        initializeTokens();
        vm.label(Currency.unwrap(currency1), "token1");

        token1 = MockERC20(Currency.unwrap(currency1));

        positionManager = new BinPositionManager(vault, poolManager, permit2);
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
            v4ClPoolManager: address(0),
            v4BinPoolManager: address(poolManager),
            v3NFTPositionManager: address(0),
            v4ClPositionManager: address(0),
            v4BinPositionManager: address(positionManager)
        });
        router = new UniversalRouter(params);
        _approvePermit2ForCurrency(alice, currency1, address(router), permit2);

        poolKey0 = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            parameters: bytes32(0).setBinStep(10)
        });
        poolManager.initialize(poolKey0, ACTIVE_ID_1_1, new bytes(0));
        _mint(poolKey0);
    }

    function test_v4BinSwap_ExactInSingle_NativeIn() public {
        uint128 amountIn = 0.01 ether;
        vm.deal(alice, amountIn);
        vm.startPrank(alice);

        // prepare v4 swap input
        IBinRouterBase.BinSwapExactInputSingleParams memory params =
            IBinRouterBase.BinSwapExactInputSingleParams(poolKey0, true, amountIn, 0, "");
        plan = Planner.init().add(Actions.BIN_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency0, poolKey0.currency1, ActionConstants.MSG_SENDER);

        // call v4_swap
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V4_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = data;

        assertEq(alice.balance, 0.01 ether);
        assertEq(token1.balanceOf(alice), 0 ether);
        snapStart("BinNativePancakeSwapV4Test#test_v4BinSwap_ExactInSingle_NativeIn");
        router.execute{value: amountIn}(commands, inputs);
        snapEnd();
        assertEq(alice.balance, 0 ether);
        assertEq(token1.balanceOf(alice), 9970000000000000); // 0.01 eth * 0.997
    }

    function test_v4BinSwap_ExactInSingle_NativeOut() public {
        uint128 amountIn = 0.01 ether;
        MockERC20(Currency.unwrap(currency1)).mint(alice, amountIn);
        vm.startPrank(alice);

        // prepare v4 swap input
        IBinRouterBase.BinSwapExactInputSingleParams memory params =
            IBinRouterBase.BinSwapExactInputSingleParams(poolKey0, false, amountIn, 0, "");
        plan = Planner.init().add(Actions.BIN_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency1, poolKey0.currency0, ActionConstants.MSG_SENDER);

        // call v4_swap
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V4_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = data;

        assertEq(alice.balance, 0 ether);
        assertEq(token1.balanceOf(alice), 0.01 ether);
        snapStart("BinNativePancakeSwapV4Test#test_v4BinSwap_ExactInSingle_NativeIn");
        router.execute(commands, inputs);
        snapEnd();
        assertEq(alice.balance, 9970000000000000);
        assertEq(token1.balanceOf(alice), 0); // 0.01 eth * 0.997
    }

    function test_v4BinSwap_ExactInSingle_NativeOut_RouterRecipient() public {
        uint128 amountIn = 0.01 ether;
        MockERC20(Currency.unwrap(currency1)).mint(alice, amountIn);
        vm.startPrank(alice);

        // prepare v4 swap input
        IBinRouterBase.BinSwapExactInputSingleParams memory params =
            IBinRouterBase.BinSwapExactInputSingleParams(poolKey0, false, amountIn, 0, "");
        plan = Planner.init().add(Actions.BIN_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency1, poolKey0.currency0, ActionConstants.ADDRESS_THIS);

        // call v4_swap
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V4_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = data;

        assertEq(alice.balance, 0 ether);
        assertEq(token1.balanceOf(alice), 0.01 ether);
        snapStart("BinNativePancakeSwapV4Test#test_v4BinSwap_ExactInSingle_NativeOut_RouterRecipient");
        router.execute(commands, inputs);
        snapEnd();
        assertEq(address(router).balance, 9970000000000000);
        assertEq(token1.balanceOf(alice), 0); // 0.01 eth * 0.997
    }

    /// @dev add 10 ether of token0, token1 at active bin
    function _mint(PoolKey memory key) private {
        uint24[] memory binIds = getBinIds(ACTIVE_ID_1_1, 1);
        IBinPositionManager.BinAddLiquidityParams memory addParams;
        addParams = _getAddParams(key, binIds, 10 ether, 10 ether, ACTIVE_ID_1_1, address(this));

        Plan memory planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(addParams));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key);

        positionManager.modifyLiquidities{value: 10 ether}(payload, block.timestamp + 1);
    }
}
