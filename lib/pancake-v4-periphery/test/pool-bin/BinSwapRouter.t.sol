// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BinPoolManager} from "pancake-v4-core/src/pool-bin/BinPoolManager.sol";
import {BinPoolParametersHelper} from "pancake-v4-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {Vault} from "pancake-v4-core/src/Vault.sol";
import {BinPositionManager} from "../../src/pool-bin/BinPositionManager.sol";
import {IBinPositionManager} from "../../src/pool-bin/interfaces/IBinPositionManager.sol";
import {BinLiquidityHelper} from "./helper/BinLiquidityHelper.sol";
import {SafeCast} from "pancake-v4-core/src/pool-bin/libraries/math/SafeCast.sol";
import {MockV4Router} from "../mocks/MockV4Router.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {IBinRouterBase} from "../../src/pool-bin/interfaces/IBinRouterBase.sol";
import {PathKey} from "../../src/libraries/PathKey.sol";
import {Plan, Planner} from "../../src/libraries/Planner.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {SafeCallback} from "../../src/base/SafeCallback.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";

contract BinSwapRouterTest is Test, GasSnapshot, BinLiquidityHelper, DeployPermit2 {
    using SafeCast for uint256;
    using Planner for Plan;
    using BinPoolParametersHelper for bytes32;
    using Planner for Plan;

    bytes constant ZERO_BYTES = new bytes(0);
    uint256 _deadline = block.timestamp + 1;

    IVault public vault;
    PoolKey key;
    PoolKey key2;
    PoolKey key3;
    BinPoolManager poolManager;
    BinPositionManager binPm;
    MockERC20 token0;
    MockERC20 token1;
    MockERC20 token2;
    bytes32 poolParam;
    MockV4Router public router;
    IAllowanceTransfer permit2;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint24 activeId = 2 ** 23; // where token0 and token1 price is the same

    Plan plan;

    function setUp() public {
        plan = Planner.init();
        vault = new Vault();
        poolManager = new BinPoolManager(IVault(address(vault)), 500000);
        vault.registerApp(address(poolManager));
        router = new MockV4Router(vault, ICLPoolManager(address(0)), IBinPoolManager(address(poolManager)));
        permit2 = IAllowanceTransfer(deployPermit2());

        binPm = new BinPositionManager(IVault(address(vault)), IBinPoolManager(address(poolManager)), permit2);

        token0 = new MockERC20("TestA", "A", 18);
        token1 = new MockERC20("TestB", "B", 18);
        token2 = new MockERC20("TestC", "C", 18);

        // sort token
        (token0, token1) = token0 > token1 ? (token1, token0) : (token0, token1);
        if (token2 < token0) {
            (token0, token1, token2) = (token2, token0, token1);
        } else if (token2 < token1) {
            (token1, token2) = (token2, token1);
        }

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            hooks: IHooks(address(0)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });
        key2 = PoolKey({
            currency0: Currency.wrap(address(token1)),
            currency1: Currency.wrap(address(token2)),
            hooks: IHooks(address(0)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });
        key3 = PoolKey({
            currency0: Currency.wrap(address(address(0))),
            currency1: Currency.wrap(address(token0)),
            hooks: IHooks(address(0)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });

        poolManager.initialize(key, activeId, ZERO_BYTES);
        poolManager.initialize(key2, activeId, ZERO_BYTES);
        poolManager.initialize(key3, activeId, ZERO_BYTES);

        approveBinPmForCurrency(alice, Currency.wrap(address(token0)), address(binPm), permit2);
        approveBinPmForCurrency(alice, Currency.wrap(address(token1)), address(binPm), permit2);
        approveBinPmForCurrency(alice, Currency.wrap(address(token2)), address(binPm), permit2);

        vm.startPrank(alice);
        token0.approve(address(router), 1000 ether);
        token1.approve(address(router), 1000 ether);
        token2.approve(address(router), 1000 ether);

        // add liquidity, 10 ether across 3 bins for both pool
        token0.mint(alice, 10 ether);
        token1.mint(alice, 20 ether); // 20 as token1 is used in both pool
        token2.mint(alice, 10 ether);
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory addParams;
        addParams = _getAddParams(key, binIds, 10 ether, 10 ether, activeId, alice);
        Plan memory planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(addParams));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key);
        binPm.modifyLiquidities(payload, _deadline);

        addParams = _getAddParams(key2, binIds, 10 ether, 10 ether, activeId, alice);
        planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(addParams));
        payload = planner.finalizeModifyLiquidityWithClose(key2);
        binPm.modifyLiquidities(payload, _deadline);

        // add liquidity for ETH-token0 native pool (10 eth each)
        token0.mint(alice, 10 ether);
        vm.deal(alice, 10 ether);
        addParams = _getAddParams(key3, binIds, 10 ether, 10 ether, activeId, alice);
        planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(addParams));
        payload = planner.finalizeModifyLiquidityWithClose(key3);
        binPm.modifyLiquidities{value: 10 ether}(payload, _deadline);
    }

    function testLockAcquired_VaultOnly() public {
        vm.expectRevert(SafeCallback.NotVault.selector);
        router.lockAcquired(new bytes(0));
    }

    function testExactInputSingle_EthPool_SwapEthForToken() public {
        vm.startPrank(alice);

        vm.deal(alice, 1 ether);
        assertEq(alice.balance, 1 ether);
        assertEq(token0.balanceOf(alice), 0 ether);

        IBinRouterBase.BinSwapExactInputSingleParams memory params =
            IBinRouterBase.BinSwapExactInputSingleParams(key3, true, 1 ether, 0, bytes(""));

        plan = plan.add(Actions.BIN_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key3.currency0, key3.currency1, alice);

        snapStart("BinSwapRouterTest#testExactInputSingle_EthPool_SwapEthForToken");
        router.executeActions{value: 1 ether}(data);
        snapEnd();
        uint256 aliceToken0Balance = token0.balanceOf(alice);

        assertEq(aliceToken0Balance, 997000000000000000);
        assertEq(alice.balance, 0 ether);
    }

    function testExactInputSingle_EthPool_SwapEthForToken_RefundETH() public {
        vm.startPrank(alice);

        vm.deal(alice, 2 ether);
        assertEq(alice.balance, 2 ether);
        assertEq(token0.balanceOf(alice), 0 ether);

        IBinRouterBase.BinSwapExactInputSingleParams memory params =
            IBinRouterBase.BinSwapExactInputSingleParams(key3, true, 1 ether, 0, bytes(""));

        plan = plan.add(Actions.BIN_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key3.currency0, key3.currency1, alice);
        // provide 2 eth but swap only required 1 eth
        router.executeActionsAndSweepExcessETH{value: 2 ether}(data);

        assertEq(alice.balance, 1 ether);
        assertEq(address(router).balance, 0 ether);
    }

    function testExactInputSingle_EthPool_SwapTokenForEth() public {
        vm.startPrank(alice);

        token0.mint(alice, 1 ether);
        assertEq(alice.balance, 0 ether);
        assertEq(token0.balanceOf(alice), 1 ether);

        IBinRouterBase.BinSwapExactInputSingleParams memory params =
            IBinRouterBase.BinSwapExactInputSingleParams(key3, false, 1 ether, 0, bytes(""));

        plan = plan.add(Actions.BIN_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key3.currency1, key3.currency0, alice);

        snapStart("BinSwapRouterTest#testExactInputSingle_EthPool_SwapTokenForEth");
        router.executeActions(data);
        snapEnd();

        assertEq(alice.balance, 997000000000000000);
        assertEq(token0.balanceOf(alice), 0 ether);
    }

    function testExactInputSingle_EthPool_InsufficientETH() public {
        vm.deal(alice, 1 ether);

        vm.expectRevert(); // OutOfFund
        IBinRouterBase.BinSwapExactInputSingleParams memory params =
            IBinRouterBase.BinSwapExactInputSingleParams(key3, true, 1 ether, 0, bytes(""));

        plan = plan.add(Actions.BIN_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key3.currency0, key3.currency1, alice);
        router.executeActions{value: 0.5 ether}(data);
    }

    // /// @param swapForY if true = swap token0 for token1
    function testExactInputSingle_SwapForY(bool swapForY) public {
        vm.startPrank(alice);

        // before swap
        if (swapForY) {
            token0.mint(alice, 1 ether);
            assertEq(token0.balanceOf(alice), 1 ether);
            assertEq(token1.balanceOf(alice), 0 ether);
        } else {
            token1.mint(alice, 1 ether);
            assertEq(token0.balanceOf(alice), 0 ether);
            assertEq(token1.balanceOf(alice), 1 ether);
        }

        string memory gasSnapshotName = swapForY
            ? "BinSwapRouterTest#testExactInputSingle_SwapForY_1"
            : "BinSwapRouterTest#testExactInputSingle_SwapForY_2";

        IBinRouterBase.BinSwapExactInputSingleParams memory params =
            IBinRouterBase.BinSwapExactInputSingleParams(key, swapForY, 1 ether, 0, bytes(""));

        plan = plan.add(Actions.BIN_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data;
        if (swapForY) {
            data = plan.finalizeSwap(key.currency0, key.currency1, alice);
        } else {
            data = plan.finalizeSwap(key.currency1, key.currency0, alice);
        }
        snapStart(gasSnapshotName);
        router.executeActions(data);
        snapEnd();
        if (swapForY) {
            assertEq(token0.balanceOf(alice), 0 ether);
            assertEq(token1.balanceOf(alice), 997000000000000000);
        } else {
            assertEq(token0.balanceOf(alice), 997000000000000000);
            assertEq(token1.balanceOf(alice), 0 ether);
        }
    }

    function testExactInputSingle_AmountOutMin() public {
        vm.startPrank(alice);

        token0.mint(alice, 1 ether);

        vm.expectRevert(IV4Router.V4TooLittleReceived.selector);
        IBinRouterBase.BinSwapExactInputSingleParams memory params =
            IBinRouterBase.BinSwapExactInputSingleParams(key, true, 1 ether, 1 ether, bytes(""));

        plan = plan.add(Actions.BIN_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key.currency0, key.currency1, alice);
        router.executeActions(data);
    }

    function testExactInputSingle_DifferentRecipient() public {
        vm.startPrank(alice);

        token0.mint(alice, 1 ether);
        vm.warp(1000); // set block.timestamp

        IBinRouterBase.BinSwapExactInputSingleParams memory params =
            IBinRouterBase.BinSwapExactInputSingleParams(key, true, 1 ether, 0, bytes(""));

        plan = plan.add(Actions.BIN_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key.currency0, key.currency1, bob);
        snapStart("BinSwapRouterTest#testExactInputSingle_DifferentRecipient");
        router.executeActions(data);
        snapEnd();

        assertEq(token1.balanceOf(bob), 997000000000000000);
        assertEq(token1.balanceOf(alice), 0);
    }

    function testExactInput_SingleHop() public {
        vm.startPrank(alice);
        token0.mint(alice, 1 ether);

        PathKey[] memory path = new PathKey[](1);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });

        IBinRouterBase.BinSwapExactInputParams memory params =
            IBinRouterBase.BinSwapExactInputParams(Currency.wrap(address(token0)), path, 1 ether, 0);

        plan = plan.add(Actions.BIN_SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(Currency.wrap(address(token0)), Currency.wrap(address(token1)), alice);
        router.executeActions(data);

        assertEq(token1.balanceOf(alice), 997000000000000000);
    }

    function testExactInput_MultiHopDifferentRecipient() public {
        vm.startPrank(alice);
        token0.mint(alice, 1 ether);

        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });
        path[1] = PathKey({
            intermediateCurrency: Currency.wrap(address(token2)),
            fee: key2.fee,
            hooks: key2.hooks,
            hookData: new bytes(0),
            poolManager: key2.poolManager,
            parameters: key2.parameters
        });

        IBinRouterBase.BinSwapExactInputParams memory params =
            IBinRouterBase.BinSwapExactInputParams(Currency.wrap(address(token0)), path, 1 ether, 0);

        plan = plan.add(Actions.BIN_SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(Currency.wrap(address(token0)), Currency.wrap(address(token2)), bob);
        snapStart("BinSwapRouterTest#testExactInput_MultiHopDifferentRecipient");
        router.executeActions(data);
        snapEnd();

        // 1 ether * 0.997 * 0.997 (0.3% fee twice)
        assertEq(token2.balanceOf(alice), 0);
        assertEq(token2.balanceOf(bob), 994009000000000000);
    }

    function testExactInput_AmountOutMin() public {
        vm.startPrank(alice);
        token0.mint(alice, 1 ether);

        PathKey[] memory path = new PathKey[](1);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });

        vm.expectRevert(IV4Router.V4TooLittleReceived.selector);
        IBinRouterBase.BinSwapExactInputParams memory params =
            IBinRouterBase.BinSwapExactInputParams(Currency.wrap(address(token0)), path, 1 ether, 1 ether);

        plan = plan.add(Actions.BIN_SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(Currency.wrap(address(token0)), Currency.wrap(address(token1)), alice);
        router.executeActions(data);
    }

    function testExactOutputSingle_SwapForY(bool swapForY) public {
        vm.startPrank(alice);

        // before swap
        if (swapForY) {
            token0.mint(alice, 1 ether);
            assertEq(token0.balanceOf(alice), 1 ether);
            assertEq(token1.balanceOf(alice), 0 ether);
        } else {
            token1.mint(alice, 1 ether);
            assertEq(token0.balanceOf(alice), 0 ether);
            assertEq(token1.balanceOf(alice), 1 ether);
        }

        string memory gasSnapshotName = swapForY
            ? "BinSwapRouterTest#testExactOutputSingle_SwapForY_1"
            : "BinSwapRouterTest#testExactOutputSingle_SwapForY_2";

        IBinRouterBase.BinSwapExactOutputSingleParams memory params =
            IBinRouterBase.BinSwapExactOutputSingleParams(key, swapForY, 0.5 ether, 1 ether, bytes(""));

        plan = plan.add(Actions.BIN_SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data;
        if (swapForY) {
            data = plan.finalizeSwap(key.currency0, key.currency1, alice);
        } else {
            data = plan.finalizeSwap(key.currency1, key.currency0, alice);
        }
        snapStart(gasSnapshotName);
        router.executeActions(data);
        snapEnd();

        // amountIn is 501504513540621866
        if (swapForY) {
            assertEq(token0.balanceOf(alice), 1 ether - 501504513540621866);
            assertEq(token1.balanceOf(alice), 0.5 ether);
        } else {
            assertEq(token0.balanceOf(alice), 0.5 ether);
            assertEq(token1.balanceOf(alice), 1 ether - 501504513540621866);
        }
    }

    function testExactOutputSingle_DifferentRecipient() public {
        vm.startPrank(alice);
        token0.mint(alice, 1 ether);

        IBinRouterBase.BinSwapExactOutputSingleParams memory params =
            IBinRouterBase.BinSwapExactOutputSingleParams(key, true, 0.5 ether, 1 ether, bytes(""));

        plan = plan.add(Actions.BIN_SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key.currency0, key.currency1, bob);
        snapStart("BinSwapRouterTest#testExactOutputSingle_DifferentRecipient");
        router.executeActions(data);
        snapEnd();

        assertEq(token0.balanceOf(alice), 1 ether - 501504513540621866);
        assertEq(token1.balanceOf(alice), 0 ether);
        assertEq(token1.balanceOf(bob), 0.5 ether);
    }

    function testExactOutputSingle_AmountInMax() public {
        vm.startPrank(alice);

        // Give alice > amountInMax so TooMuchRequestedError instead of TransferFromFailed
        token0.mint(alice, 2 ether);

        vm.expectRevert(abi.encodeWithSelector(IV4Router.V4TooMuchRequested.selector));
        IBinRouterBase.BinSwapExactOutputSingleParams memory params =
            IBinRouterBase.BinSwapExactOutputSingleParams(key, true, 1 ether, 1 ether, bytes(""));

        plan = plan.add(Actions.BIN_SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key.currency0, key.currency1, bob);
        router.executeActions(data);
    }

    function testExactOutput_SingleHop() public {
        // swap token0 input -> token1 output
        vm.startPrank(alice);
        token0.mint(alice, 1 ether);

        PathKey[] memory path = new PathKey[](1);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(token0)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });

        // before test validation
        assertEq(token0.balanceOf(alice), 1 ether);
        assertEq(token1.balanceOf(alice), 0);

        IBinRouterBase.BinSwapExactOutputParams memory params =
            IBinRouterBase.BinSwapExactOutputParams(Currency.wrap(address(token1)), path, 0.5 ether, 1 ether);

        plan = plan.add(Actions.BIN_SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(Currency.wrap(address(token0)), Currency.wrap(address(token1)), alice);
        snapStart("BinSwapRouterTest#testExactOutput_SingleHop");
        router.executeActions(data);
        snapEnd();

        // amountIs is 501504513540621866
        assertEq(token0.balanceOf(alice), 1 ether - 501504513540621866);
        assertEq(token1.balanceOf(alice), 0.5 ether);
    }

    function testExactOutput_MultiHopDifferentRecipient() public {
        // swap token0 input -> token1 -> token2 output
        vm.startPrank(alice);
        token0.mint(alice, 1 ether);

        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(token0)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });
        path[1] = PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
            fee: key2.fee,
            hooks: key2.hooks,
            hookData: new bytes(0),
            poolManager: key2.poolManager,
            parameters: key2.parameters
        });

        // before test validation
        assertEq(token0.balanceOf(alice), 1 ether);
        assertEq(token1.balanceOf(alice), 0);
        assertEq(token2.balanceOf(alice), 0);
        assertEq(token2.balanceOf(bob), 0 ether);

        IBinRouterBase.BinSwapExactOutputParams memory params =
            IBinRouterBase.BinSwapExactOutputParams(Currency.wrap(address(token2)), path, 0.5 ether, 1 ether);

        plan = plan.add(Actions.BIN_SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(Currency.wrap(address(token0)), Currency.wrap(address(token2)), bob);
        snapStart("BinSwapRouterTest#testExactOutput_MultiHopDifferentRecipient");
        router.executeActions(data);
        snapEnd();

        // after test validation
        // amountIn is 503013554203231561
        assertEq(token0.balanceOf(alice), 1 ether - 503013554203231561);
        assertEq(token2.balanceOf(bob), 0.5 ether);
    }

    function testExactOutput_TooMuchRequested() public {
        vm.startPrank(alice);
        token0.mint(alice, 2 ether);

        PathKey[] memory path = new PathKey[](1);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(token0)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });

        vm.expectRevert(abi.encodeWithSelector(IV4Router.V4TooMuchRequested.selector));
        IBinRouterBase.BinSwapExactOutputParams memory params =
            IBinRouterBase.BinSwapExactOutputParams(Currency.wrap(address(token1)), path, 1 ether, 1 ether);

        plan = plan.add(Actions.BIN_SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(Currency.wrap(address(token0)), Currency.wrap(address(token1)), alice);
        router.executeActions(data);
    }
}
