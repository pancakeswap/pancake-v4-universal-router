// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {ActionConstants} from "pancake-v4-periphery/src/libraries/ActionConstants.sol";

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {UniversalRouter} from "../../src/UniversalRouter.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {Commands} from "../../src/libraries/Commands.sol";
import {RouterParameters} from "../../src/base/RouterImmutables.sol";
import {IStableSwapFactory} from "../../src/interfaces/IStableSwapFactory.sol";
import {IStableSwapInfo} from "../../src/interfaces/IStableSwapInfo.sol";

abstract contract StableSwapTest is Test, GasSnapshot {
    address constant RECIPIENT = address(10);
    uint256 constant AMOUNT = 1 ether;
    uint256 constant BALANCE = 100000 ether;
    ERC20 constant WETH9 = ERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IPermit2 constant PERMIT2 = IPermit2(0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768);
    address constant FROM = address(1234);

    /// @dev Address found from smart router via https://bscscan.com/address/0x13f4EA83D0bd40E75C8222255bc855a974568Dd4#readContract
    /// @dev StableInfo refers to PancakeStableSwapTwoPoolInfo, threePoolInfo is not present as its not used in PCS
    IStableSwapFactory STABLE_FACTORY = IStableSwapFactory(0x25a55f9f2279A54951133D503490342b50E5cd15);
    IStableSwapInfo STABLE_INFO = IStableSwapInfo(0x150c8AbEB487137acCC541925408e73b92F39A50);

    UniversalRouter public router;

    function setUp() public {
        // BSC: May-09-2024 03:05:23 AM +UTC
        vm.createSelectFork(vm.envString("FORK_URL"), 38560000);

        RouterParameters memory params = RouterParameters({
            permit2: address(PERMIT2),
            weth9: address(WETH9),
            v2Factory: address(0),
            v3Factory: address(0),
            v3Deployer: address(0),
            v2InitCodeHash: bytes32(0),
            v3InitCodeHash: bytes32(0),
            stableFactory: address(STABLE_FACTORY),
            stableInfo: address(STABLE_INFO),
            v4Vault: address(0),
            v4ClPoolManager: address(0),
            v4BinPoolManager: address(0),
            v3NFTPositionManager: address(0),
            v4ClPositionManager: address(0),
            v4BinPositionManager: address(0)
        });
        router = new UniversalRouter(params);

        // pair doesn't exist, revert to keep this test simple without adding to lp etc
        if (STABLE_FACTORY.getPairInfo(token0(), token1()).swapContract == address(0)) {
            revert("Pair doesn't exist");
        }

        vm.startPrank(FROM);
        deal(FROM, BALANCE);
        deal(token0(), FROM, BALANCE);
        deal(token1(), FROM, BALANCE);
        ERC20(token0()).approve(address(PERMIT2), type(uint256).max);
        ERC20(token1()).approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(token0(), address(router), type(uint160).max, type(uint48).max);
        PERMIT2.approve(token1(), address(router), type(uint160).max, type(uint48).max);
    }

    function test_stableSwap_ExactInput0For1() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.STABLE_SWAP_EXACT_IN)));

        // equivalent: abi.decode(inputs, (address, uint256, uint256, address[], uint256[], bool)
        address[] memory path = new address[](2);
        path[0] = token0();
        path[1] = token1();
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, 0, path, flag(), true);

        router.execute(commands, inputs);
        snapLastCall("StableSwapTest#test_stableSwap_ExactInput0For1");
        assertEq(ERC20(token0()).balanceOf(FROM), BALANCE - AMOUNT);
        assertGt(ERC20(token1()).balanceOf(FROM), BALANCE);
    }

    function test_stableSwap_ExactInput1For0() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.STABLE_SWAP_EXACT_IN)));

        // equivalent: abi.decode(inputs, (address, uint256, uint256, address[], uint256[], bool)
        address[] memory path = new address[](2);
        path[0] = token1();
        path[1] = token0();
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, 0, path, flag(), true);

        router.execute(commands, inputs);
        snapLastCall("StableSwapTest#test_stableSwap_ExactInput1For0");
        assertEq(ERC20(token1()).balanceOf(FROM), BALANCE - AMOUNT);
        assertGt(ERC20(token0()).balanceOf(FROM), BALANCE);
    }

    function test_stableSwap_exactInput0For1FromRouter() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.STABLE_SWAP_EXACT_IN)));
        deal(token0(), address(router), AMOUNT);
        // equivalent: abi.decode(inputs, (address, uint256, uint256, address[], uint256[], bool)
        address[] memory path = new address[](2);
        path[0] = token0();
        path[1] = token1();
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, 0, path, flag(), true);

        router.execute(commands, inputs);
        assertGt(ERC20(token1()).balanceOf(FROM), BALANCE);
    }

    function test_stableSwap_exactInput1For0FromRouter() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.STABLE_SWAP_EXACT_IN)));
        deal(token1(), address(router), AMOUNT);
        // equivalent: abi.decode(inputs, (address, uint256, uint256, address[], uint256[], bool)
        address[] memory path = new address[](2);
        path[0] = token1();
        path[1] = token0();
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, 0, path, flag(), true);

        router.execute(commands, inputs);
        assertGt(ERC20(token0()).balanceOf(FROM), BALANCE);
    }

    function test_stableSwap_exactOutput0For1() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.STABLE_SWAP_EXACT_OUT)));

        // equivalent: abi.decode(inputs, (address, uint256, uint256, address[], uint256[], bool)
        address[] memory path = new address[](2);
        path[0] = token0();
        path[1] = token1();
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, type(uint256).max, path, flag(), true);

        router.execute(commands, inputs);
        assertLt(ERC20(token0()).balanceOf(FROM), BALANCE);
        assertGe(ERC20(token1()).balanceOf(FROM), BALANCE + AMOUNT);
    }

    function test_stableSwap_exactOutput1For0() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.STABLE_SWAP_EXACT_OUT)));

        // equivalent: abi.decode(inputs, (address, uint256, uint256, address[], uint256[], bool)
        address[] memory path = new address[](2);
        path[0] = token1();
        path[1] = token0();
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, type(uint256).max, path, flag(), true);

        router.execute(commands, inputs);
        assertLt(ERC20(token1()).balanceOf(FROM), BALANCE);
        assertGe(ERC20(token0()).balanceOf(FROM), BALANCE + AMOUNT);
    }

    function test_stableSwap_exactOutput0For1FromRouter() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.STABLE_SWAP_EXACT_OUT)));
        deal(token0(), address(router), BALANCE);

        // equivalent: abi.decode(inputs, (address, uint256, uint256, address[], uint256[], bool)
        address[] memory path = new address[](2);
        path[0] = token0();
        path[1] = token1();
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, type(uint256).max, path, flag(), true);

        router.execute(commands, inputs);
        assertGe(ERC20(token1()).balanceOf(FROM), BALANCE + AMOUNT);
    }

    function test_stableSwap_exactOutput1For0FromRouter() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.STABLE_SWAP_EXACT_OUT)));
        deal(token1(), address(router), BALANCE);

        // equivalent: abi.decode(inputs, (address, uint256, uint256, address[], uint256[], bool)
        address[] memory path = new address[](2);
        path[0] = token1();
        path[1] = token0();
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, type(uint256).max, path, flag(), true);

        router.execute(commands, inputs);
        assertGe(ERC20(token0()).balanceOf(FROM), BALANCE + AMOUNT);
    }

    function token0() internal virtual returns (address);
    function token1() internal virtual returns (address);
    function flag() internal virtual returns (uint256[] memory);
}
