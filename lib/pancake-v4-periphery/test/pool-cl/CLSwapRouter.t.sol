// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {FixedPoint96} from "pancake-v4-core/src/pool-cl/libraries/FixedPoint96.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {Vault} from "pancake-v4-core/src/Vault.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
import {CLPoolManagerRouter} from "pancake-v4-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {CLPool} from "pancake-v4-core/src/pool-cl/libraries/CLPool.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {TokenFixture} from "../helpers/TokenFixture.sol";
import {MockV4Router} from "../mocks/MockV4Router.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {ICLRouterBase} from "../../src/pool-cl/interfaces/ICLRouterBase.sol";
import {PathKey} from "../../src/libraries/PathKey.sol";
import {Plan, Planner} from "../../src/libraries/Planner.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";

contract CLSwapRouterTest is TokenFixture, Test, GasSnapshot {
    using Planner for Plan;

    IVault public vault;
    ICLPoolManager public poolManager;
    CLPoolManagerRouter public positionManager;
    MockV4Router public router;

    PoolKey public poolKey0;
    PoolKey public poolKey1;
    PoolKey public poolKey2;

    Plan plan;

    function setUp() public {
        plan = Planner.init();
        vault = new Vault();
        poolManager = new CLPoolManager(vault, 3000);
        vault.registerApp(address(poolManager));

        initializeTokens();
        vm.label(Currency.unwrap(currency0), "token0");
        vm.label(Currency.unwrap(currency1), "token1");
        vm.label(Currency.unwrap(currency2), "token2");

        positionManager = new CLPoolManagerRouter(vault, poolManager);
        IERC20(Currency.unwrap(currency0)).approve(address(positionManager), 1000 ether);
        IERC20(Currency.unwrap(currency1)).approve(address(positionManager), 1000 ether);
        IERC20(Currency.unwrap(currency2)).approve(address(positionManager), 1000 ether);

        router = new MockV4Router(vault, poolManager, IBinPoolManager(address(0)));
        IERC20(Currency.unwrap(currency0)).approve(address(router), 1000 ether);
        IERC20(Currency.unwrap(currency1)).approve(address(router), 1000 ether);
        IERC20(Currency.unwrap(currency2)).approve(address(router), 1000 ether);

        poolKey0 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });
        // price 100
        uint160 sqrtPriceX96_100 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(poolKey0, sqrtPriceX96_100, new bytes(0));

        positionManager.modifyPosition(
            poolKey0,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: 46053,
                tickUpper: 46055,
                liquidityDelta: 1e4 ether,
                salt: bytes32(0)
            }),
            new bytes(0)
        );

        poolKey1 = PoolKey({
            currency0: currency1,
            currency1: currency2,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });
        // price 1
        uint160 sqrtPriceX96_1 = uint160(1 * FixedPoint96.Q96);
        poolManager.initialize(poolKey1, sqrtPriceX96_1, new bytes(0));

        positionManager.modifyPosition(
            poolKey1,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: -5,
                tickUpper: 5,
                liquidityDelta: 1e5 ether,
                salt: bytes32(0)
            }),
            new bytes(0)
        );

        vm.deal(msg.sender, 25 ether);
        poolKey2 = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: currency0,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });
        // price 1
        uint160 sqrtPriceX96_2 = uint160(1 * FixedPoint96.Q96);

        poolManager.initialize(poolKey2, sqrtPriceX96_2, new bytes(0));

        positionManager.modifyPosition{value: 25 ether}(
            poolKey2,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: -5,
                tickUpper: 5,
                liquidityDelta: 1e5 ether,
                salt: bytes32(0)
            }),
            new bytes(0)
        );

        // token0-token1 amount 0.05 ether : 5 ether i.e. price = 100
        // token1-token2 amount 25 ether : 25 ether i.e. price = 1
        // eth-token0 amount 25 ether : 25 ether i.e. price = 1
    }

    function testExactInputSingle_EthPool_zeroForOne() external {
        address alice = makeAddr("alice");
        vm.startPrank(alice);
        vm.deal(alice, 0.01 ether);

        // before assertion
        assertEq(alice.balance, 0.01 ether);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(alice), 0 ether);

        // swap
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(poolKey2, true, 0.01 ether, 0, 0, bytes(""));

        plan = plan.add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey2.currency0, poolKey2.currency1, ActionConstants.MSG_SENDER);

        router.executeActions{value: 0.01 ether}(data);

        // after assertion
        assertEq(alice.balance, 0 ether);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(alice), 9969999005991099);
    }

    function testExactInputSingle_EthPool_OneForZero() external {
        // pre-req: mint and approve for alice
        address alice = makeAddr("alice");
        vm.startPrank(alice);
        MockERC20(Currency.unwrap(currency0)).mint(alice, 0.01 ether);
        IERC20(Currency.unwrap(currency0)).approve(address(router), 0.01 ether);

        // before assertion
        assertEq(alice.balance, 0 ether);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(alice), 0.01 ether);

        // swap
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(poolKey2, false, 0.01 ether, 0, 0, bytes(""));

        plan = plan.add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey2.currency1, poolKey2.currency0, ActionConstants.MSG_SENDER);

        router.executeActions(data);

        // after assertion
        assertEq(alice.balance, 9969999005991099);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(alice), 0);
    }

    function testExactInputSingle_zeroForOne() external {
        address recipient = makeAddr("recipient");
        uint256 recipientBalanceBefore = IERC20(Currency.unwrap(poolKey0.currency1)).balanceOf(recipient);
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(poolKey0, true, 0.01 ether, 0, 0, bytes(""));

        plan = plan.add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency0, poolKey0.currency1, recipient);

        router.executeActions(data);

        uint256 recipientBalanceAfter = IERC20(Currency.unwrap(poolKey0.currency1)).balanceOf(recipient);
        assertEq(recipientBalanceAfter - recipientBalanceBefore, 996990060009101709);
    }

    function testExactInputSingle_oneForZero() external {
        address recipient = makeAddr("recipient");
        uint256 recipientBalanceBefore = IERC20(Currency.unwrap(poolKey0.currency0)).balanceOf(recipient);
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(poolKey0, false, 1 ether, 0, 0, bytes(""));

        plan = plan.add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency1, poolKey0.currency0, recipient);

        router.executeActions(data);

        uint256 recipientBalanceAfter = IERC20(Currency.unwrap(poolKey0.currency0)).balanceOf(recipient);
        assertEq(recipientBalanceAfter - recipientBalanceBefore, 9969900600091017);
    }

    function testExactInputSingle_priceNotMatch() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                CLPool.InvalidSqrtPriceLimit.selector, uint160(10 * FixedPoint96.Q96), uint160(11 * FixedPoint96.Q96)
            )
        );
        address recipient = makeAddr("recipient");
        ICLRouterBase.CLSwapExactInputSingleParams memory params = ICLRouterBase.CLSwapExactInputSingleParams(
            poolKey0, true, 0.01 ether, 0, uint160(11 * FixedPoint96.Q96), bytes("")
        );

        plan = plan.add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency0, poolKey0.currency1, recipient);

        router.executeActions(data);
    }

    function testExactInputSingle_amountOutLessThanExpected() external {
        vm.expectRevert(IV4Router.V4TooLittleReceived.selector);
        address recipient = makeAddr("recipient");
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(poolKey0, true, 0.01 ether, 2 ether, 0, bytes(""));

        plan = plan.add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency0, poolKey0.currency1, recipient);

        router.executeActions(data);
    }

    function testExactInputSingle_gas() external {
        address recipient = makeAddr("recipient");
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(poolKey0, true, 0.01 ether, 0, 0, bytes(""));

        plan = plan.add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency0, poolKey0.currency1, recipient);

        snapStart("CLSwapRouterTest#ExactInputSingle");
        router.executeActions(data);
        snapEnd();
    }

    function testExactInput() external {
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: currency1,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });
        path[1] = PathKey({
            intermediateCurrency: currency2,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });

        address recipient = makeAddr("recipient");
        uint256 recipientBalanceBefore = IERC20(Currency.unwrap(currency2)).balanceOf(recipient);
        ICLRouterBase.CLSwapExactInputParams memory params =
            ICLRouterBase.CLSwapExactInputParams(currency0, path, 0.01 ether, 0);

        plan = plan.add(Actions.CL_SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency2, recipient);

        router.executeActions(data);

        uint256 recipientBalanceAfter = IERC20(Currency.unwrap(currency2)).balanceOf(recipient);
        assertEq(recipientBalanceAfter - recipientBalanceBefore, 993989209585378125);
    }

    function testExactInput_amountOutLessThanExpected() external {
        vm.expectRevert(IV4Router.V4TooLittleReceived.selector);
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: currency1,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });
        path[1] = PathKey({
            intermediateCurrency: currency2,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });

        address recipient = makeAddr("recipient");
        ICLRouterBase.CLSwapExactInputParams memory params =
            ICLRouterBase.CLSwapExactInputParams(currency0, path, 0.01 ether, 2 ether);

        plan = plan.add(Actions.CL_SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency2, recipient);

        router.executeActions(data);
    }

    function testExactInput_gasX() external {
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: currency1,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });
        path[1] = PathKey({
            intermediateCurrency: currency2,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });

        address recipient = makeAddr("recipient");
        ICLRouterBase.CLSwapExactInputParams memory params =
            ICLRouterBase.CLSwapExactInputParams(currency0, path, 0.01 ether, 0);

        plan = plan.add(Actions.CL_SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency2, recipient);

        snapStart("CLSwapRouterTest#ExactInput");
        router.executeActions(data);
        snapEnd();
    }

    function testExactOutputSingle_zeroForOne() external {
        uint256 balanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        address recipient = makeAddr("recipient");
        uint256 recipientBalanceBefore = IERC20(Currency.unwrap(poolKey0.currency1)).balanceOf(recipient);
        ICLRouterBase.CLSwapExactOutputSingleParams memory params =
            ICLRouterBase.CLSwapExactOutputSingleParams(poolKey0, true, 1 ether, 0.0101 ether, 0, bytes(""));

        plan = plan.add(Actions.CL_SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency0, poolKey0.currency1, recipient);

        router.executeActions(data);
        uint256 balanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 recipientBalanceAfter = IERC20(Currency.unwrap(poolKey0.currency1)).balanceOf(recipient);

        uint256 paid = balanceBefore - balanceAfter;
        assertEq(paid, 10030190572718166);
        assertEq(recipientBalanceAfter - recipientBalanceBefore, 1 ether);
    }

    function testExactOutputSingle_oneForZero() external {
        uint256 balanceBefore = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        address recipient = makeAddr("recipient");
        uint256 recipientBalanceBefore = IERC20(Currency.unwrap(poolKey0.currency0)).balanceOf(recipient);

        ICLRouterBase.CLSwapExactOutputSingleParams memory params =
            ICLRouterBase.CLSwapExactOutputSingleParams(poolKey0, false, 0.01 ether, 1.01 ether, 0, bytes(""));

        plan = plan.add(Actions.CL_SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency1, poolKey0.currency0, recipient);

        router.executeActions(data);
        uint256 balanceAfter = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        uint256 recipientBalanceAfter = IERC20(Currency.unwrap(poolKey0.currency0)).balanceOf(recipient);

        uint256 paid = balanceBefore - balanceAfter;
        assertEq(paid, 1003019057271816451);
        assertEq(recipientBalanceAfter - recipientBalanceBefore, 0.01 ether);
    }

    function testExactOutputSingle_priceNotMatch() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                CLPool.InvalidSqrtPriceLimit.selector, uint160(10 * FixedPoint96.Q96), uint160(11 * FixedPoint96.Q96)
            )
        );

        address recipient = makeAddr("recipient");
        ICLRouterBase.CLSwapExactOutputSingleParams memory params = ICLRouterBase.CLSwapExactOutputSingleParams(
            poolKey0, true, 1 ether, 0.0101 ether, uint160(11 * FixedPoint96.Q96), bytes("")
        );

        plan = plan.add(Actions.CL_SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency0, poolKey0.currency1, recipient);

        router.executeActions(data);
    }

    function testExactOutputSingle_amountOutLessThanExpected() external {
        vm.expectRevert(IV4Router.V4TooMuchRequested.selector);

        address recipient = makeAddr("recipient");
        ICLRouterBase.CLSwapExactOutputSingleParams memory params =
            ICLRouterBase.CLSwapExactOutputSingleParams(poolKey0, true, 1 ether, 0.01 ether, 0, bytes(""));

        plan = plan.add(Actions.CL_SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency0, poolKey0.currency1, recipient);

        router.executeActions(data);
    }

    function testExactOutputSingle_gas() external {
        address recipient = makeAddr("recipient");
        ICLRouterBase.CLSwapExactOutputSingleParams memory params =
            ICLRouterBase.CLSwapExactOutputSingleParams(poolKey0, true, 1 ether, 0.0101 ether, 0, bytes(""));

        plan = plan.add(Actions.CL_SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency0, poolKey0.currency1, recipient);

        snapStart("CLSwapRouterTest#ExactOutputSingle");
        router.executeActions(data);
        snapEnd();
    }

    function testExactOutput() external {
        uint256 balanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));

        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: currency0,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });
        path[1] = PathKey({
            intermediateCurrency: currency1,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });

        address recipient = makeAddr("recipient");
        uint256 recipientBalanceBefore = IERC20(Currency.unwrap(currency2)).balanceOf(recipient);
        ICLRouterBase.CLSwapExactOutputParams memory params =
            ICLRouterBase.CLSwapExactOutputParams(currency2, path, 1 ether, 0.0101 ether);

        plan = plan.add(Actions.CL_SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency2, recipient);
        router.executeActions(data);

        uint256 balanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 recipientBalanceAfter = IERC20(Currency.unwrap(currency2)).balanceOf(recipient);
        uint256 paid = balanceBefore - balanceAfter;

        assertEq(paid, 10060472596238902);
        assertEq(recipientBalanceAfter - recipientBalanceBefore, 1 ether);
    }

    function testExactOutput_amountInMoreThanExpected() external {
        vm.expectRevert(IV4Router.V4TooMuchRequested.selector);

        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: currency0,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });
        path[1] = PathKey({
            intermediateCurrency: currency1,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });

        address recipient = makeAddr("recipient");
        ICLRouterBase.CLSwapExactOutputParams memory params =
            ICLRouterBase.CLSwapExactOutputParams(currency2, path, 1 ether, 0.01 ether);

        plan = plan.add(Actions.CL_SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency2, recipient);
        router.executeActions(data);
    }

    function testExactOutput_gas() external {
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: currency0,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });
        path[1] = PathKey({
            intermediateCurrency: currency1,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });

        address recipient = makeAddr("recipient");
        ICLRouterBase.CLSwapExactOutputParams memory params =
            ICLRouterBase.CLSwapExactOutputParams(currency2, path, 1 ether, 0.0101 ether);

        plan = plan.add(Actions.CL_SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency2, recipient);

        snapStart("CLSwapRouterTest#ExactOutput");
        router.executeActions(data);
        snapEnd();
    }

    // allow refund of ETH
    receive() external payable {}
}
