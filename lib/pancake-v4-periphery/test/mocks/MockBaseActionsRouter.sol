// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {BaseActionsRouter} from "../../src/base/BaseActionsRouter.sol";
import {Actions} from "../../src/libraries/Actions.sol";

contract MockBaseActionsRouter is BaseActionsRouter {
    uint256 public clSwapCount;
    uint256 public binSwapCount;

    uint256 public clIncreaseLiqCount;
    uint256 public binAddLiqCount;

    uint256 public clDecreaseLiqCount;
    uint256 public binRemoveLiqCount;

    uint256 public clDonateCount;
    uint256 public binDonateCount;

    uint256 public clearCount;
    uint256 public settleCount;
    uint256 public takeCount;
    uint256 public mintCount;
    uint256 public burnCount;

    constructor(IVault _vault) BaseActionsRouter(_vault) {}

    function executeActions(bytes calldata params) external {
        _executeActions(params);
    }

    function _handleAction(uint256 action, bytes calldata params) internal override {
        if (action < Actions.SETTLE) {
            if (action == Actions.CL_SWAP_EXACT_IN) _clSwap(params);
            else if (action == Actions.CL_INCREASE_LIQUIDITY) _clIncreaseLiquidity(params);
            else if (action == Actions.CL_DECREASE_LIQUIDITY) _clDecreaseLiquidity(params);
            else if (action == Actions.CL_DONATE) _clDonate(params);
            else revert UnsupportedAction(action);
        } else if (action < Actions.BIN_ADD_LIQUIDITY) {
            if (action == Actions.SETTLE) _settle(params);
            else if (action == Actions.TAKE) _take(params);
            else if (action == Actions.CLEAR_OR_TAKE) _clear(params);
            else if (action == Actions.MINT_6909) _mint6909(params);
            else if (action == Actions.BURN_6909) _burn6909(params);
            else revert UnsupportedAction(action);
        } else {
            if (action == Actions.BIN_SWAP_EXACT_IN) _binSwap(params);
            else if (action == Actions.BIN_ADD_LIQUIDITY) _binAddLiquidity(params);
            else if (action == Actions.BIN_REMOVE_LIQUIDITY) _binRemoveLiquidity(params);
            else if (action == Actions.BIN_DONATE) _binDonate(params);
            else revert UnsupportedAction(action);
        }
    }

    function msgSender() public pure override returns (address) {
        return address(0xdeadbeef);
    }

    function _clSwap(bytes calldata /* params **/ ) internal {
        clSwapCount++;
    }

    function _binSwap(bytes calldata /* params **/ ) internal {
        binSwapCount++;
    }

    function _clIncreaseLiquidity(bytes calldata /* params **/ ) internal {
        clIncreaseLiqCount++;
    }

    function _binAddLiquidity(bytes calldata /* params **/ ) internal {
        binAddLiqCount++;
    }

    function _clDecreaseLiquidity(bytes calldata /* params **/ ) internal {
        clDecreaseLiqCount++;
    }

    function _binRemoveLiquidity(bytes calldata /* params **/ ) internal {
        binRemoveLiqCount++;
    }

    function _clDonate(bytes calldata /* params **/ ) internal {
        clDonateCount++;
    }

    function _binDonate(bytes calldata /* params **/ ) internal {
        binDonateCount++;
    }

    function _settle(bytes calldata /* params **/ ) internal {
        settleCount++;
    }

    function _take(bytes calldata /* params **/ ) internal {
        takeCount++;
    }

    function _mint6909(bytes calldata /* params **/ ) internal {
        mintCount++;
    }

    function _burn6909(bytes calldata /* params **/ ) internal {
        burnCount++;
    }

    function _clear(bytes calldata /* params **/ ) internal {
        clearCount++;
    }

    function mapRecipient(address recipient) external view returns (address) {
        return _mapRecipient(recipient);
    }
}
