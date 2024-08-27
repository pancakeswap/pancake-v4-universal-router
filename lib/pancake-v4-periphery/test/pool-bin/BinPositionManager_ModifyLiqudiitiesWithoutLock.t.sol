// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";

import {Vault} from "pancake-v4-core/src/Vault.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {Hooks} from "pancake-v4-core/src/libraries/Hooks.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {BinPoolParametersHelper} from "pancake-v4-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {SafeCast} from "pancake-v4-core/src/pool-bin/libraries/math/SafeCast.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {BinPoolManager} from "pancake-v4-core/src/pool-bin/BinPoolManager.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {PackedUint128Math} from "pancake-v4-core/src/pool-bin/libraries/math/PackedUint128Math.sol";
import {TokenFixture} from "pancake-v4-core/test/helpers/TokenFixture.sol";

import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {IBinPositionManager} from "../../src/pool-bin/interfaces/IBinPositionManager.sol";
import {BinPositionManager} from "../../src/pool-bin/BinPositionManager.sol";
import {IBinFungibleToken} from "../../src/pool-bin/interfaces/IBinFungibleToken.sol";
import {Planner, Plan} from "../../src/libraries/Planner.sol";
import {BinTokenLibrary} from "../../src/pool-bin/libraries/BinTokenLibrary.sol";
import {IBinRouterBase} from "../../src/pool-bin/interfaces/IBinRouterBase.sol";
import {BinLiquidityHelper} from "./helper/BinLiquidityHelper.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {BaseActionsRouter} from "../../src/base/BaseActionsRouter.sol";
import {BinHookModifyLiquidities} from "./shared/BinHookModifyLiquidities.sol";
import {MockV4Router} from "../mocks/MockV4Router.sol";

contract BinPositionManager_ModifyLiquidityWithoutLockTest is
    BinLiquidityHelper,
    GasSnapshot,
    TokenFixture,
    DeployPermit2
{
    using Planner for Plan;
    using BinPoolParametersHelper for bytes32;
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;
    using BinTokenLibrary for PoolId;

    bytes constant ZERO_BYTES = new bytes(0);
    uint256 _deadline = block.timestamp + 1;

    PoolKey key1;
    Vault vault;
    BinPoolManager poolManager;
    BinPositionManager binPm;
    IAllowanceTransfer permit2;
    MockERC20 token0;
    MockERC20 token1;
    BinHookModifyLiquidities hookModifyLiquidities;

    MockV4Router public router;
    bytes32 poolParam;
    address alice = makeAddr("alice");
    uint24 activeId = 2 ** 23; // where token0 and token1 price is the same

    function setUp() public {
        vault = new Vault();
        poolManager = new BinPoolManager(IVault(address(vault)), 500000);
        vault.registerApp(address(poolManager));
        permit2 = IAllowanceTransfer(deployPermit2());
        initializeTokens();
        (token0, token1) = (MockERC20(Currency.unwrap(currency0)), MockERC20(Currency.unwrap(currency1)));

        binPm = new BinPositionManager(IVault(address(vault)), IBinPoolManager(address(poolManager)), permit2);

        // create hook and seed with 1000 ether of token0/token1
        hookModifyLiquidities = new BinHookModifyLiquidities();
        hookModifyLiquidities.setAddresses(binPm, permit2);
        token0.mint(address(hookModifyLiquidities), 1000 ether);
        token1.mint(address(hookModifyLiquidities), 1000 ether);

        key1 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(hookModifyLiquidities)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: bytes32(uint256(hookModifyLiquidities.getHooksRegistrationBitmap())).setBinStep(10) // binStep
        });
        binPm.initializePool(key1, activeId, ZERO_BYTES);

        // approval
        approveBinPm(address(this), key1, address(binPm), permit2);
        approveBinPm(alice, key1, address(binPm), permit2);

        router = new MockV4Router(vault, ICLPoolManager(address(0)), IBinPoolManager(address(poolManager)));
        token0.approve(address(router), 1000 ether);
        token1.approve(address(router), 1000 ether);
    }

    function test_hook_increaseLiquidity() public {
        // Add liquidity in activeId
        uint24[] memory binIds = getBinIds(activeId, 1);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, address(this));
        Plan memory planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);
        binPm.modifyLiquidities(payload, _deadline);

        // before: verify pool
        (uint128 binReserveX, uint128 binReserveY,) = poolManager.getBin(key1.toId(), activeId);
        assertEq(binReserveX, 1 ether);
        assertEq(binReserveY, 1 ether);

        // do a swap and see if hook manage to mint a position
        param = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, address(hookModifyLiquidities));
        planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        payload = planner.finalizeModifyLiquidityWithClose(key1);
        _swapExactIn(key1, 0.1 ether, payload);

        // after: verify pool reserve increase due to hook minting
        (binReserveX, binReserveY,) = poolManager.getBin(key1.toId(), activeId);
        assertEq(binReserveX, 2100000000000000000); // +2eth from liquidity, +0.1eth from swap
        assertEq(binReserveY, 1900300000000000000); // +2eth from liquidity, -0.1eth from swap
    }

    function test_hook_decreaseLiquidity() public {
        // add liquidity and set hookModifyLiquidities as recipipent
        uint24[] memory binIds = getBinIds(activeId, 1);
        (, uint256[] memory liquidityMinted) =
            _addLiquidity(binPm, key1, binIds, activeId, address(hookModifyLiquidities));

        // before: verify pool
        (uint128 binReserveX, uint128 binReserveY,) = poolManager.getBin(key1.toId(), activeId);
        assertEq(binReserveX, 1 ether);
        assertEq(binReserveY, 1 ether);

        // do a swap and hook to decrease liquidity by half
        for (uint256 i; i < liquidityMinted.length; i++) {
            liquidityMinted[i] = liquidityMinted[i] / 2;
        }
        IBinPositionManager.BinRemoveLiquidityParams memory param =
            _getRemoveParams(key1, binIds, liquidityMinted, address(hookModifyLiquidities));
        Plan memory planner = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);
        _swapExactIn(key1, 0.1 ether, payload);

        // after: verify pool reserve decrease due to hook decreasing liquidity too
        (binReserveX, binReserveY,) = poolManager.getBin(key1.toId(), activeId);
        assertEq(binReserveX, 600000000000000000); // +1eth from add, -0.5eth from remove, +0.1 eth from swapIn
        assertEq(binReserveY, 400300000000000000); // +1eth from add, -0.5eth from remove, -0.1 eth from swapOut
    }

    function test_hook_decreaseLiquidity_RevertNoLp() public {
        // add liquidity for address(this) as recipeint
        uint24[] memory binIds = getBinIds(activeId, 1);
        (, uint256[] memory liquidityMinted) = _addLiquidity(binPm, key1, binIds, activeId, address(this));

        // do a swap and decrease liquidity and notice revert
        IBinPositionManager.BinRemoveLiquidityParams memory param =
            _getRemoveParams(key1, binIds, liquidityMinted, address(hookModifyLiquidities));
        Plan memory planner = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);

        vm.expectRevert(
            abi.encodeWithSelector(
                Hooks.Wrap__FailedHookCall.selector,
                address(hookModifyLiquidities),
                abi.encodeWithSelector(
                    IBinFungibleToken.BinFungibleToken_BurnExceedsBalance.selector,
                    address(hookModifyLiquidities),
                    key1.toId().toTokenId(binIds[0]),
                    liquidityMinted[0] // amount to Burn
                )
            )
        );
        _swapExactIn(key1, 0.1 ether, payload);
    }

    /// @dev swap 1 ether of token0 for token1
    function _swapExactIn(PoolKey memory key, uint128 amountIn, bytes memory hookData) internal {
        IBinRouterBase.BinSwapExactInputSingleParams memory params =
            IBinRouterBase.BinSwapExactInputSingleParams(key, true, amountIn, 0, hookData);

        Plan memory planner = Planner.init().add(Actions.BIN_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = planner.finalizeSwap(key.currency0, key.currency1, alice);
        router.executeActions{value: 1 ether}(data);
    }
}
