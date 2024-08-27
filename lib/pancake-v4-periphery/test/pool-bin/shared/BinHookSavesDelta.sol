// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "pancake-v4-core/src/types/BeforeSwapDelta.sol";
import {BaseBinTestHook} from "pancake-v4-core/test/pool-bin/helpers/BaseBinTestHook.sol";

/// @notice This contract is NOT a production use contract. It is meant to be used in testing to verify the delta amounts against changes in a user's balance.
contract BinHookSavesDelta is BaseBinTestHook {
    BalanceDelta[] public deltas;

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: true,
                afterInitialize: true,
                beforeMint: true,
                afterMint: true,
                beforeBurn: true,
                afterBurn: true,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnsDelta: false,
                afterSwapReturnsDelta: false,
                afterMintReturnsDelta: false,
                afterBurnReturnsDelta: false
            })
        );
    }

    function afterMint(
        address, /* sender **/
        PoolKey calldata, /* key **/
        IBinPoolManager.MintParams calldata, /* params **/
        BalanceDelta delta,
        bytes calldata /* hookData **/
    ) external override returns (bytes4, BalanceDelta) {
        _storeDelta(delta);
        return (this.afterMint.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterBurn(
        address, /* sender **/
        PoolKey calldata, /* key **/
        IBinPoolManager.BurnParams calldata, /* params **/
        BalanceDelta delta,
        bytes calldata /* hookData **/
    ) external override returns (bytes4, BalanceDelta) {
        _storeDelta(delta);
        return (this.afterBurn.selector, BalanceDeltaLibrary.ZERO_DELTA);
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

    function beforeInitialize(address, PoolKey calldata, uint24, bytes calldata)
        external
        virtual
        override
        returns (bytes4)
    {
        return this.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint24, bytes calldata)
        external
        virtual
        override
        returns (bytes4)
    {
        return this.afterInitialize.selector;
    }

    function beforeMint(address, PoolKey calldata, IBinPoolManager.MintParams calldata, bytes calldata)
        external
        virtual
        override
        returns (bytes4, uint24)
    {
        return (this.beforeMint.selector, 0);
    }

    function beforeBurn(address, PoolKey calldata, IBinPoolManager.BurnParams calldata, bytes calldata)
        external
        virtual
        override
        returns (bytes4)
    {
        return this.beforeBurn.selector;
    }

    function beforeSwap(address, PoolKey calldata, bool, int128, bytes calldata)
        external
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata, bool, int128, BalanceDelta, bytes calldata)
        external
        virtual
        override
        returns (bytes4, int128)
    {
        return (this.afterSwap.selector, 0);
    }
}
