// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {ActionConstants} from "pancake-v4-periphery/src/libraries/ActionConstants.sol";
import {Permit2SignatureHelpers} from "pancake-v4-periphery/test/shared/Permit2SignatureHelpers.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";

import {UniversalRouter} from "../src/UniversalRouter.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {Payments} from "../src/modules/Payments.sol";
import {Constants} from "../src/libraries/Constants.sol";
import {Commands} from "../src/libraries/Commands.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {MockERC721} from "./mock/MockERC721.sol";
import {MockERC1155} from "./mock/MockERC1155.sol";
import {RouterParameters} from "../src/base/RouterImmutables.sol";

contract UniversalRouterTest is Test, GasSnapshot, Permit2SignatureHelpers, DeployPermit2 {
    error ContractSizeTooLarge(uint256 diff);
    error InvalidNonce();

    address RECIPIENT = makeAddr("alice");
    uint256 constant AMOUNT = 10 ** 18;

    UniversalRouter router;
    MockERC20 erc20;
    MockERC20 erc20_2;
    MockERC721 erc721;
    MockERC1155 erc1155;
    WETH weth9 = new WETH();
    IAllowanceTransfer permit2;

    function setUp() public {
        permit2 = IAllowanceTransfer(deployPermit2());

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
            v4Vault: address(0),
            v4ClPoolManager: address(0),
            v4BinPoolManager: address(0),
            v3NFTPositionManager: address(0),
            v4ClPositionManager: address(0),
            v4BinPositionManager: address(0)
        });
        router = new UniversalRouter(params);
        assertEq(router.owner(), address(this));

        router = new UniversalRouter(params);
        erc20 = new MockERC20();
        erc20_2 = new MockERC20();
        erc721 = new MockERC721();
        erc1155 = new MockERC1155();
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

    function test_Owner_TransferOwnership() public {
        address alice = makeAddr("alice");
        assertEq(router.owner(), address(this));

        router.transferOwnership(alice);
        assertEq(router.owner(), address(this));
        assertEq(router.pendingOwner(), alice);

        vm.prank(alice);
        router.acceptOwnership();
        assertEq(router.owner(), alice);
        assertEq(router.pendingOwner(), address(0));
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

    function test_permit2Single() public {
        // pre-req:
        (address charlie, uint256 charliePK) = makeAddrAndKey("charlie");
        uint160 permitAmount = type(uint160).max;
        uint48 permitExpiration = uint48(block.timestamp + 10e18);
        uint48 permitNonce = 0;

        IAllowanceTransfer.PermitSingle memory permit =
            defaultERC20PermitAllowance(address(erc20), permitAmount, permitExpiration, permitNonce);
        permit.spender = address(router);
        bytes memory sig = getPermitSignature(permit, charliePK, permit2.DOMAIN_SEPARATOR());

        // before verify
        (uint160 _amount, uint48 _expiration, uint48 _nonce) =
            permit2.allowance(charlie, address(erc20), address(router));
        assertEq(_amount, 0);
        assertEq(_expiration, 0);
        assertEq(_nonce, 0);

        // execute
        vm.startPrank(charlie);
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PERMIT2_PERMIT)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(permit, sig);
        router.execute(commands, inputs);

        // after verify
        (_amount, _expiration, _nonce) = permit2.allowance(charlie, address(erc20), address(router));
        assertEq(_amount, permitAmount);
        assertEq(_expiration, permitExpiration);
        assertEq(_nonce, permitNonce + 1);
    }

    function test_permit2Batch() public {
        // pre-req:
        (address charlie, uint256 charliePK) = makeAddrAndKey("charlie");
        uint160 permitAmount = type(uint160).max;
        uint48 permitExpiration = uint48(block.timestamp + 10e18);
        uint48 permitNonce = 0;

        address[] memory tokens = new address[](2);
        tokens[0] = address(erc20);
        tokens[1] = address(erc20_2);

        IAllowanceTransfer.PermitBatch memory permit =
            defaultERC20PermitBatchAllowance(tokens, permitAmount, permitExpiration, permitNonce);
        permit.spender = address(router);
        bytes memory sig = getPermitBatchSignature(permit, charliePK, permit2.DOMAIN_SEPARATOR());

        // before verify
        for (uint256 i; i < tokens.length; i++) {
            (uint160 _amount, uint48 _expiration, uint48 _nonce) =
                permit2.allowance(charlie, tokens[i], address(router));
            assertEq(_amount, 0);
            assertEq(_expiration, 0);
            assertEq(_nonce, 0);
        }

        // execute
        vm.startPrank(charlie);
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PERMIT2_PERMIT_BATCH)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(permit, sig);
        router.execute(commands, inputs);

        // after verify
        for (uint256 i; i < tokens.length; i++) {
            (uint160 _amount, uint48 _expiration, uint48 _nonce) =
                permit2.allowance(charlie, address(tokens[i]), address(router));
            assertEq(_amount, permitAmount);
            assertEq(_expiration, permitExpiration);
            assertEq(_nonce, permitNonce + 1);
        }
    }

    /// @dev test showing that if permit command have ALLOW_REVERT flag and was front-run, the next command can still execute
    function test_permit2Single_frontrun() public {
        // pre-req
        address bob = makeAddr("bob");
        (address charlie, uint256 charliePK) = makeAddrAndKey("charlie");
        uint160 permitAmount = type(uint160).max;
        uint48 permitExpiration = uint48(block.timestamp + 10e18);
        uint48 permitNonce = 0;

        IAllowanceTransfer.PermitSingle memory permit =
            defaultERC20PermitAllowance(address(erc20), permitAmount, permitExpiration, permitNonce);
        permit.spender = address(router);
        bytes memory sig = getPermitSignature(permit, charliePK, permit2.DOMAIN_SEPARATOR());

        // bob front-runs the permits
        vm.prank(bob);
        permit2.permit(charlie, permit, sig);

        // bob's front-run was successful
        (uint160 _amount, uint48 _expiration, uint48 _nonce) =
            permit2.allowance(charlie, address(erc20), address(router));
        assertEq(_amount, permitAmount);
        assertEq(_expiration, permitExpiration);
        assertEq(_nonce, permitNonce + 1);

        // before
        assertEq(weth9.balanceOf(address(router)), 0);

        // charlie tries to call universal router permit2_permit and wrap_eth command
        vm.deal(charlie, 1 ether);
        vm.startPrank(charlie);

        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(permit, sig);
        inputs[1] = abi.encode(ActionConstants.ADDRESS_THIS, ActionConstants.CONTRACT_BALANCE);

        bytes memory commands;

        // attempt 1: execute and expect revert
        commands = abi.encodePacked(bytes1(uint8(Commands.PERMIT2_PERMIT)), bytes1(uint8(Commands.WRAP_ETH)));
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniversalRouter.ExecutionFailed.selector, 0, abi.encodePacked(InvalidNonce.selector)
            )
        );
        router.execute{value: 1 ether}(commands, inputs);

        // attempt 2: execute with allow revert flag and no revert expected
        commands = abi.encodePacked(
            bytes1(uint8(Commands.PERMIT2_PERMIT)) | Commands.FLAG_ALLOW_REVERT, bytes1(uint8(Commands.WRAP_ETH))
        );
        router.execute{value: 1 ether}(commands, inputs);

        // after
        assertEq(weth9.balanceOf(address(router)), 1 ether);
    }

    /// @dev test showing that if permit command have ALLOW_REVERT flag and was front-run, the next command can still execute
    function test_permit2Batch_frontrun() public {
        // pre-req
        address bob = makeAddr("bob");
        (address charlie, uint256 charliePK) = makeAddrAndKey("charlie");
        uint160 permitAmount = type(uint160).max;
        uint48 permitExpiration = uint48(block.timestamp + 10e18);
        uint48 permitNonce = 0;

        address[] memory tokens = new address[](2);
        tokens[0] = address(erc20);
        tokens[1] = address(erc20_2);

        IAllowanceTransfer.PermitBatch memory permit =
            defaultERC20PermitBatchAllowance(tokens, permitAmount, permitExpiration, permitNonce);
        permit.spender = address(router);
        bytes memory sig = getPermitBatchSignature(permit, charliePK, permit2.DOMAIN_SEPARATOR());

        // bob front-runs the permits
        vm.prank(bob);
        permit2.permit(charlie, permit, sig);

        // bob's front-run was successful
        for (uint256 i; i < tokens.length; i++) {
            (uint160 _amount, uint48 _expiration, uint48 _nonce) =
                permit2.allowance(charlie, address(tokens[i]), address(router));
            assertEq(_amount, permitAmount);
            assertEq(_expiration, permitExpiration);
            assertEq(_nonce, permitNonce + 1);
        }

        // before
        assertEq(weth9.balanceOf(address(router)), 0);

        // charlie tries to call universal router permit2_permit and wrap_eth command
        vm.deal(charlie, 1 ether);
        vm.startPrank(charlie);

        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(permit, sig);
        inputs[1] = abi.encode(ActionConstants.ADDRESS_THIS, ActionConstants.CONTRACT_BALANCE);

        bytes memory commands;

        // attempt 1: execute and expect revert
        commands = abi.encodePacked(bytes1(uint8(Commands.PERMIT2_PERMIT_BATCH)), bytes1(uint8(Commands.WRAP_ETH)));
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniversalRouter.ExecutionFailed.selector, 0, abi.encodePacked(InvalidNonce.selector)
            )
        );
        router.execute{value: 1 ether}(commands, inputs);

        // attempt 2: execute with allow revert flag and no revert expected
        commands = abi.encodePacked(
            bytes1(uint8(Commands.PERMIT2_PERMIT_BATCH)) | Commands.FLAG_ALLOW_REVERT, bytes1(uint8(Commands.WRAP_ETH))
        );
        router.execute{value: 1 ether}(commands, inputs);

        // after
        assertEq(weth9.balanceOf(address(router)), 1 ether);
    }
}
