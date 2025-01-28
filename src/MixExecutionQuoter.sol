// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

// Command implementations
import {Dispatcher} from "./base/Dispatcher.sol";
import {StableSwapRouter} from "./modules/pancakeswap/StableSwapRouter.sol";
import {V4SwapRouter} from "./modules/pancakeswap/v4/V4SwapRouter.sol";
import {RouterParameters, RouterImmutables} from "./base/RouterImmutables.sol";
import {Commands} from "./libraries/Commands.sol";
import {Actions} from "pancake-v4-periphery/src/libraries/Actions.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {QuoterRevert} from "pancake-v4-periphery/src/libraries/QuoterRevert.sol";
import {CalldataDecoder} from "pancake-v4-periphery/src/libraries/CalldataDecoder.sol";

contract MixExecutionQuoter is RouterImmutables, Dispatcher {
    using QuoterRevert for *;
    using CalldataDecoder for bytes;

    error NotSelf();
    error InvalidEthSender();
    error LengthMismatch();

    constructor(RouterParameters memory params)
        RouterImmutables(params)
        StableSwapRouter(params.stableFactory, params.stableInfo)
        V4SwapRouter(params.v4Vault, params.v4ClPoolManager, params.v4BinPoolManager)
    {}

    /// @dev Only this address may call this function. Used to mimic internal functions, using an
    /// external call to catch and parse revert reasons
    modifier selfOnly() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    /// @notice To receive ETH from WETH
    receive() external payable {
        if (msg.sender != address(WETH9) && msg.sender != address(vault)) revert InvalidEthSender();
    }

    function execute(bytes calldata commands, bytes[] calldata inputs) external payable override {}

    function quoteMixedExactInput(bytes calldata data) external returns (uint256 amountOut, uint256 gasEstimate) {
        uint256 gasBefore = gasleft();
        try this._quoteMixedExactInput(data) {
            revert("NO WAY!");
        } catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            amountOut = reason.parseQuoteAmount();
        }
    }

    function _quoteMixedExactInput(bytes calldata data) external selfOnly {
        _executeActions(data);
    }

    function _lockAcquired(bytes calldata data) internal override returns (bytes memory) {
        ///@dev equivalent to: abi.decode(routesData, (Currency, uint256, bytes, bytes[]));

        // 0. decode necessary parameters
        //  a. Currency inputToken
        //  b. uint256 amountIn
        //  c. Currency outputToken
        //  d. bytes calldata commands
        //  e. bytes[] calldata inputs
        Currency inputToken;
        uint256 amountIn;
        Currency outputToken;
        assembly ("memory-safe") {
            inputToken := calldataload(data.offset)
            amountIn := calldataload(add(data.offset, 0x20))
            outputToken := calldataload(add(data.offset, 0x40))
            data.offset := add(data.offset, 0x60)
        }
        (bytes calldata commands, bytes[] calldata inputs) = data.decodeActionsRouterParams();

        // 1. borrow the amountIn from the vault
        _take(inputToken, address(this), amountIn);

        // 2. execute all the swaps in sequence and accumulate the amountOut
        /// @dev we won't revert until the end so that the context can be reserved
        uint256 numCommands = commands.length;
        if (inputs.length != numCommands) revert LengthMismatch();

        for (uint256 commandIndex = 0; commandIndex < numCommands; commandIndex++) {
            bytes1 command = commands[commandIndex];

            bytes calldata input = inputs[commandIndex];

            _dispatch(command, input);
        }

        // 3. return the amountOut through the revert
        uint256 amountOut = outputToken.balanceOf(address(this));
        amountOut.revertQuote();
    }

    /// @notice dev Dispatches different swap command to the appropriate pcs pools
    function _dispatch(bytes1 commandType, bytes calldata inputs) internal {
        uint256 command = uint8(commandType & Commands.COMMAND_TYPE_MASK);
        if (command == Commands.V4_SWAP) {
            (bytes calldata actions, bytes[] calldata params) = inputs.decodeActionsRouterParams();
            _executeActionsWithoutLock(actions, params);
        } else {
            (bool success,) = dispatch(commandType, inputs);
            // TODO: bubble up the revert reason
            if (!success) {
                revert("DISPATCH_FAILED");
            }
        }
    }
}
