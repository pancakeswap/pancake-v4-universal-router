// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {ActionConstants} from "infinity-periphery/src/libraries/ActionConstants.sol";

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {UniversalRouter} from "../../src/UniversalRouter.sol";
import {IPancakeV3PoolDeployer} from "../../src/modules/pancakeswap/v3/interfaces/IPancakeV3PoolDeployer.sol";
import {IPancakeV3Factory} from "../../src/modules/pancakeswap/v3/interfaces/IPancakeV3Factory.sol";
import {IPancakeV3Pool} from "../../src/modules/pancakeswap/v3/interfaces/IPancakeV3Pool.sol";
import {V3SwapRouter} from "../../src/modules/pancakeswap/v3/V3SwapRouter.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {Commands} from "../../src/libraries/Commands.sol";
import {RouterParameters} from "../../src/base/RouterImmutables.sol";

/// @dev fork test against BSC network at block 38560000
abstract contract PancakeSwapV3Test is Test {
    address constant RECIPIENT = address(10);
    uint256 constant AMOUNT = 1 ether;
    uint256 constant BALANCE = 100_000 ether;
    IPancakeV3Factory constant FACTORY = IPancakeV3Factory(0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865);
    IPancakeV3PoolDeployer constant V3_DEPLOYER = IPancakeV3PoolDeployer(0x41ff9AA7e16B8B1a8a8dc4f0eFacd93D02d071c9);
    ERC20 constant WETH9 = ERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IPermit2 constant PERMIT2 = IPermit2(0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768);
    address constant FROM = address(1234);

    UniversalRouter public router;

    function setUp() public {
        // BSC: May-09-2024 03:05:23 AM +UTC
        vm.createSelectFork(vm.envString("FORK_URL"), 38560000);

        RouterParameters memory params = RouterParameters({
            permit2: address(PERMIT2),
            weth9: address(WETH9),
            v2Factory: address(0),
            v3Factory: address(FACTORY),
            v3Deployer: address(V3_DEPLOYER),
            v2InitCodeHash: bytes32(0),
            v3InitCodeHash: bytes32(0x6ce8eb472fa82df5469c6ab6d485f17c3ad13c8cd7af59b3d4a8026c5ce0f7e2),
            stableFactory: address(0),
            stableInfo: address(0),
            infiVault: address(0),
            infiClPoolManager: address(0),
            infiBinPoolManager: address(0),
            v3NFTPositionManager: address(0),
            infiClPositionManager: address(0),
            infiBinPositionManager: address(0)
        });
        router = new UniversalRouter(params);

        // pair doesn't exist, revert to keep this test simple without adding to lp etc
        if (FACTORY.getPool(token0(), token1(), fee()) == address(0)) {
            revert("Pair doesn't exist");
        }

        vm.startPrank(FROM);
        deal(FROM, BALANCE);
        deal(token0(), FROM, BALANCE);
        deal(token1(), FROM, BALANCE);
        deal(token2(), FROM, BALANCE);
        ERC20(token0()).approve(address(PERMIT2), type(uint256).max);
        ERC20(token1()).approve(address(PERMIT2), type(uint256).max);
        ERC20(token2()).approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(token0(), address(router), type(uint160).max, type(uint48).max);
        PERMIT2.approve(token1(), address(router), type(uint160).max, type(uint48).max);
        PERMIT2.approve(token2(), address(router), type(uint160).max, type(uint48).max);
    }

    function test_v3Swap_ExactInput0For1() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_IN)));
        bytes memory path = abi.encodePacked(token0(), fee(), token1());
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, 0, path, true);

        router.execute(commands, inputs);
        vm.snapshotGasLastCall("test_v3Swap_ExactInput0For1");
        assertEq(ERC20(token0()).balanceOf(FROM), BALANCE - AMOUNT);
        assertGt(ERC20(token1()).balanceOf(FROM), BALANCE);
    }

    function test_v3Swap_exactInput1For0() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_IN)));
        bytes memory path = abi.encodePacked(token1(), fee(), token0());
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, 0, path, true);

        router.execute(commands, inputs);
        assertEq(ERC20(token1()).balanceOf(FROM), BALANCE - AMOUNT);
        assertGt(ERC20(token0()).balanceOf(FROM), BALANCE);
    }

    function test_v3Swap_ExactInput0For1_ContractBalance() public {
        // pre-req: ensure router has 1 ether
        deal(token0(), address(router), 1 ether);
        assertEq(ERC20(token0()).balanceOf(address(router)), 1 ether);

        // use CONTRACT_BALANCE as amount
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_IN)));
        bytes memory path = abi.encodePacked(token0(), fee(), token1());
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, ActionConstants.CONTRACT_BALANCE, 0, path, true);

        router.execute(commands, inputs);
        vm.snapshotGasLastCall("test_v3Swap_ExactInput0For1_ContractBalance");
        assertEq(ERC20(token0()).balanceOf(FROM), BALANCE - 1 ether);
        assertGt(ERC20(token1()).balanceOf(FROM), BALANCE);
    }

    function test_v3Swap_exactInput_MultiHop() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_IN)));
        bytes memory path = abi.encodePacked(token0(), fee(), token1(), fee(), token2());
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, 0, path, true);

        router.execute(commands, inputs);
        vm.snapshotGasLastCall("test_v3Swap_exactInput_MultiHop");
        assertEq(ERC20(token0()).balanceOf(FROM), BALANCE - AMOUNT);
        assertEq(ERC20(token1()).balanceOf(FROM), BALANCE);
        assertGt(ERC20(token2()).balanceOf(FROM), BALANCE);
    }

    function test_v3Swap_exactInput0For1FromRouter() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_IN)));
        deal(token0(), address(router), AMOUNT);
        bytes memory path = abi.encodePacked(token0(), fee(), token1());
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, 0, path, false);

        router.execute(commands, inputs);
        assertGt(ERC20(token1()).balanceOf(FROM), BALANCE);
    }

    function test_v3Swap_exactInput1For0FromRouter() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_IN)));
        deal(token1(), address(router), AMOUNT);
        bytes memory path = abi.encodePacked(token1(), fee(), token0());
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, 0, path, false);

        router.execute(commands, inputs);
        assertGt(ERC20(token0()).balanceOf(FROM), BALANCE);
    }

    function test_v3Swap_exactOutput0For1() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_OUT)));

        // for exactOut: tokenOut should be the first in path as it execute in reverse order
        bytes memory path = abi.encodePacked(token1(), fee(), token0());
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, type(uint256).max, path, true);

        router.execute(commands, inputs);
        vm.snapshotGasLastCall("test_v3Swap_exactOutput0For1");
        assertLt(ERC20(token0()).balanceOf(FROM), BALANCE);
        assertGe(ERC20(token1()).balanceOf(FROM), BALANCE + AMOUNT);
    }

    function test_v3Swap_exactOutput1For0() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_OUT)));

        // for exactOut: tokenOut should be the first in path as it execute in reverse order
        bytes memory path = abi.encodePacked(token0(), fee(), token1());
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, type(uint256).max, path, true);

        router.execute(commands, inputs);
        assertLt(ERC20(token1()).balanceOf(FROM), BALANCE);
        assertGe(ERC20(token0()).balanceOf(FROM), BALANCE + AMOUNT);
    }

    function test_v3Swap_exactOutput_MultiHop() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_OUT)));

        // for exactOut: tokenOut should be the first in path as it execute in reverse order
        bytes memory path = abi.encodePacked(token2(), fee(), token1(), fee(), token0());
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, type(uint256).max, path, true);

        router.execute(commands, inputs);
        vm.snapshotGasLastCall("test_v3Swap_exactOutput_MultiHop");
        assertLt(ERC20(token0()).balanceOf(FROM), BALANCE);
        assertEq(ERC20(token1()).balanceOf(FROM), BALANCE);
        assertGe(ERC20(token2()).balanceOf(FROM), BALANCE + AMOUNT);
    }

    function test_v3Swap_exactOutput0For1FromRouter() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_OUT)));
        deal(token0(), address(router), BALANCE);
        assertEq(ERC20(token0()).balanceOf(address(router)), BALANCE);

        // for exactOut: tokenOut should be the first in path as it execute in reverse order
        bytes memory path = abi.encodePacked(token1(), fee(), token0());
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, type(uint256).max, path, false);

        router.execute(commands, inputs);
        assertGe(ERC20(token1()).balanceOf(FROM), BALANCE + AMOUNT);
    }

    function test_v3Swap_exactOutput1For0FromRouter() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_OUT)));
        deal(token1(), address(router), BALANCE);

        // for exactOut: tokenOut should be the first in path as it execute in reverse order
        bytes memory path = abi.encodePacked(token0(), fee(), token1());
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, type(uint256).max, path, false);

        router.execute(commands, inputs);
        assertGe(ERC20(token0()).balanceOf(FROM), BALANCE + AMOUNT);
    }

    function test_v3Swap_pancakeV3SwapCallback_InvalidCaller() public {
        bytes memory path = abi.encodePacked(token1(), fee(), token0());
        bytes memory data = abi.encode(path, makeAddr("payer"));

        vm.expectRevert(V3SwapRouter.V3InvalidCaller.selector);
        router.pancakeV3SwapCallback(100, 100, data);
    }

    // token0-token1 will be 1 pair and token1-token2 will be 1 pair
    // for multi pool hop test
    function token0() internal virtual returns (address);
    function token1() internal virtual returns (address);
    function token2() internal virtual returns (address);
    function fee() internal virtual returns (uint24);
}
