// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "pancake-v4-core/src/types/BeforeSwapDelta.sol";
import {BaseCLTestHook} from "pancake-v4-core/test/pool-cl/helpers/BaseCLTestHook.sol";

/// @notice This contract is NOT a production use contract. It is meant to be used in testing to verify the delta amounts against changes in a user's balance.
contract HookSavesDelta is BaseCLTestHook {
    BalanceDelta[] public deltas;

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: true,
                afterInitialize: true,
                beforeAddLiquidity: true,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: true,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                befreSwapReturnsDelta: false,
                afterSwapReturnsDelta: false,
                afterAddLiquidityReturnsDelta: false,
                afterRemoveLiquidityReturnsDelta: false
            })
        );
    }

    function afterAddLiquidity(
        address, /* sender **/
        PoolKey calldata, /* key **/
        ICLPoolManager.ModifyLiquidityParams calldata, /* params **/
        BalanceDelta delta,
        bytes calldata /* hookData **/
    ) external override returns (bytes4, BalanceDelta) {
        _storeDelta(delta);
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterRemoveLiquidity(
        address, /* sender **/
        PoolKey calldata, /* key **/
        ICLPoolManager.ModifyLiquidityParams calldata, /* params **/
        BalanceDelta delta,
        bytes calldata /* hookData **/
    ) external override returns (bytes4, BalanceDelta) {
        _storeDelta(delta);
        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _storeDelta(BalanceDelta delta) internal {
        deltas.push(delta);
    }

    function numberDeltasReturned() external view returns (uint256) {
        return deltas.length;
    }

    function clearDeltas() external {
        delete deltas;
    }

    function beforeInitialize(address, PoolKey calldata, uint160, bytes calldata)
        external
        virtual
        override
        returns (bytes4)
    {
        return this.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24, bytes calldata)
        external
        virtual
        override
        returns (bytes4)
    {
        return this.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external virtual override returns (bytes4) {
        return this.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external virtual override returns (bytes4) {
        return this.beforeRemoveLiquidity.selector;
    }

    function beforeSwap(address, PoolKey calldata, ICLPoolManager.SwapParams calldata, bytes calldata)
        external
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata, ICLPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        virtual
        override
        returns (bytes4, int128)
    {
        return (this.afterSwap.selector, 0);
    }
}
