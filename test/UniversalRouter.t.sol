// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {ActionConstants} from "pancake-v4-periphery/src/libraries/ActionConstants.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";

import {UniversalRouter} from "../src/UniversalRouter.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {Payments} from "../src/modules/Payments.sol";
import {Constants} from "../src/libraries/Constants.sol";
import {Commands} from "../src/libraries/Commands.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {MockERC721} from "./mock/MockERC721.sol";
import {MockERC1155} from "./mock/MockERC1155.sol";
import {Callbacks} from "../src/base/Callbacks.sol";
import {RouterParameters} from "../src/base/RouterImmutables.sol";

contract UniversalRouterTest is Test, GasSnapshot {
    error ContractSizeTooLarge(uint256 diff);

    address RECIPIENT = makeAddr("alice");
    uint256 constant AMOUNT = 10 ** 18;

    UniversalRouter router;
    MockERC20 erc20;
    MockERC721 erc721;
    MockERC1155 erc1155;
    Callbacks callbacks;
    WETH weth9 = new WETH();

    function setUp() public {
        RouterParameters memory params = RouterParameters({
            permit2: address(0),
            weth9: address(weth9),
            v2Factory: address(0),
            v3Factory: address(0),
            v3Deployer: address(0),
            v2InitCodeHash: bytes32(0),
            v3InitCodeHash: bytes32(0),
            stableFactory: address(0),
            stableInfo: address(0),
            v4Vault: address(0),
            v4ClPoolManager: address(0),
            v4BinPoolManager: address(0),
            v3NFTPositionManager: address(0),
            v4ClPositionManager: address(0),
            v4BinPositionManager: address(0)
        });
        router = new UniversalRouter(params);

        router = new UniversalRouter(params);
        erc20 = new MockERC20();
        erc721 = new MockERC721();
        erc1155 = new MockERC1155();
        callbacks = new Callbacks();
    }

    function test_bytecodeSize() public {
        snapSize("UniversalRouterBytecodeSize", address(router));
        if (address(router).code.length > 24576) {
            revert ContractSizeTooLarge(address(router).code.length - 24576);
        }
    }

    function testCallModule() public {
        uint256 bytecodeSize;
        address theRouter = address(router);
        assembly {
            bytecodeSize := extcodesize(theRouter)
        }
        emit log_uint(bytecodeSize);
    }

    function test_sweep_token() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.SWEEP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(erc20), RECIPIENT, AMOUNT);

        erc20.mint(address(router), AMOUNT);
        assertEq(erc20.balanceOf(RECIPIENT), 0);

        router.execute(commands, inputs);
        snapLastCall("UniversalRouterTest#test_sweep_token");

        assertEq(erc20.balanceOf(RECIPIENT), AMOUNT);
    }

    function test_sweep_token_insufficientOutput() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.SWEEP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(erc20), RECIPIENT, AMOUNT + 1);

        erc20.mint(address(router), AMOUNT);
        assertEq(erc20.balanceOf(RECIPIENT), 0);

        vm.expectRevert(Payments.InsufficientToken.selector);
        router.execute(commands, inputs);
    }

    function test_sweep_ETH() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.SWEEP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(Constants.ETH, RECIPIENT, AMOUNT);

        assertEq(RECIPIENT.balance, 0);

        router.execute{value: AMOUNT}(commands, inputs);
        assertEq(RECIPIENT.balance, AMOUNT);
    }

    function test_sweep_ETH_insufficientOutput() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.SWEEP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(Constants.ETH, RECIPIENT, AMOUNT + 1);

        erc20.mint(address(router), AMOUNT);

        vm.expectRevert(Payments.InsufficientETH.selector);
        router.execute(commands, inputs);
    }

    function test_supportsInterface() public {
        bool supportsERC165 = router.supportsInterface(type(IERC165).interfaceId);
        assertEq(supportsERC165, true);
    }

    function test_receive_onlyWeth9() public {
        vm.expectRevert(IUniversalRouter.InvalidEthSender.selector);
        (bool success,) = address(router).call{value: 1 ether}("");
    }

    function test_wrapEth() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.WRAP_ETH)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.ADDRESS_THIS, ActionConstants.CONTRACT_BALANCE);

        // assert and verify
        assertEq(weth9.balanceOf(address(router)), 0 ether);
        router.execute{value: 1 ether}(commands, inputs);
        assertEq(weth9.balanceOf(address(router)), 1 ether);
    }

    function test_wrapEth_differentRecipient() public {
        address alice = makeAddr("alice");
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.WRAP_ETH)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(alice), ActionConstants.CONTRACT_BALANCE);

        // assert and verify
        assertEq(weth9.balanceOf(address(router)), 0 ether);
        assertEq(weth9.balanceOf(address(alice)), 0 ether);
        router.execute{value: 1 ether}(commands, inputs);
        assertEq(weth9.balanceOf(address(router)), 0 ether);
        assertEq(weth9.balanceOf(address(alice)), 1 ether);
    }

    function test_wrapEth_insufficientEth() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.WRAP_ETH)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.ADDRESS_THIS, 1 ether + 1);

        vm.expectRevert(Payments.InsufficientETH.selector);
        router.execute{value: 1 ether}(commands, inputs);
    }

    function test_unwrapWeth() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.WRAP_ETH)), bytes1(uint8(Commands.UNWRAP_WETH)));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(ActionConstants.ADDRESS_THIS, ActionConstants.CONTRACT_BALANCE);
        inputs[1] = abi.encode(ActionConstants.ADDRESS_THIS, 1 ether);

        // assert and verify
        assertEq(address(router).balance, 0 ether);
        router.execute{value: 1 ether}(commands, inputs);
        assertEq(address(router).balance, 1 ether);
    }

    function test_unwrapWeth_differentRecipient() public {
        address alice = makeAddr("alice");
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.WRAP_ETH)), bytes1(uint8(Commands.UNWRAP_WETH)));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(ActionConstants.ADDRESS_THIS, ActionConstants.CONTRACT_BALANCE);
        inputs[1] = abi.encode(alice, 1 ether);

        // assert and verify
        assertEq(address(router).balance, 0 ether);
        assertEq(alice.balance, 0 ether);
        router.execute{value: 1 ether}(commands, inputs);
        assertEq(address(router).balance, 0 ether);
        assertEq(alice.balance, 1 ether);
    }

    function test_unwrapWeth_insufficientETH() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.WRAP_ETH)), bytes1(uint8(Commands.UNWRAP_WETH)));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(ActionConstants.ADDRESS_THIS, ActionConstants.CONTRACT_BALANCE);
        inputs[1] = abi.encode(ActionConstants.ADDRESS_THIS, 1 ether + 1);

        // assert and verify
        vm.expectRevert(Payments.InsufficientETH.selector);
        router.execute{value: 1 ether}(commands, inputs);
    }
}
