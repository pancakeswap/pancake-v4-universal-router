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
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {BinPoolParametersHelper} from "pancake-v4-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {SafeCast} from "pancake-v4-core/src/pool-bin/libraries/math/SafeCast.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
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
import {BinLiquidityHelper} from "./helper/BinLiquidityHelper.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {BaseActionsRouter} from "../../src/base/BaseActionsRouter.sol";

// test on the various way to perform delta resolver
contract BinPositionManager_DeltaTest is BinLiquidityHelper, GasSnapshot, TokenFixture, DeployPermit2 {
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
        key1 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });
        binPm.initializePool(key1, activeId, ZERO_BYTES);

        // approval
        approveBinPm(address(this), key1, address(binPm), permit2);
        approveBinPm(alice, key1, address(binPm), permit2);
    }

    function test_settlePair() public {
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        Plan memory planner = Planner.init();
        planner.add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        planner.add(Actions.SETTLE_PAIR, abi.encode(currency0, currency1));

        binPm.modifyLiquidities(planner.encode(), _deadline);
    }

    function test_settle() public {
        // add liquidity then try settle for each token
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        Plan memory planner = Planner.init();
        planner.add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        planner.add(Actions.SETTLE, abi.encode(currency0, ActionConstants.OPEN_DELTA, true));
        planner.add(Actions.SETTLE, abi.encode(currency1, ActionConstants.OPEN_DELTA, false));

        // as Action.Settle for currency1's payerIsUser==false, transfer token to contract manually
        token1.mint(address(binPm), 1 ether);

        binPm.modifyLiquidities(planner.encode(), _deadline);
    }

    function test_takePair_AddressThis() public {
        // pre-req add liquidity
        uint24[] memory binIds = getBinIds(activeId, 3);
        (, uint256[] memory liquidityMinted) = _addLiquidity(binPm, key1, binIds, activeId);

        // remove liquidity, then try take pair
        IBinPositionManager.BinRemoveLiquidityParams memory param =
            _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        Plan memory planner = Planner.init();
        planner.add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param));
        planner.add(Actions.TAKE_PAIR, abi.encode(currency0, currency1, address(this)));

        binPm.modifyLiquidities(planner.encode(), _deadline);
    }

    function test_takePair_AddressAlice() public {
        // pre-req add liquidity
        uint24[] memory binIds = getBinIds(activeId, 3);
        (, uint256[] memory liquidityMinted) = _addLiquidity(binPm, key1, binIds, activeId);

        // before
        assertEq(token0.balanceOf(alice), 0);
        assertEq(token1.balanceOf(alice), 0);

        // remove liquidity, then try take pair
        IBinPositionManager.BinRemoveLiquidityParams memory param =
            _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        Plan memory planner = Planner.init();
        planner.add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param));
        planner.add(Actions.TAKE_PAIR, abi.encode(currency0, currency1, address(alice)));
        binPm.modifyLiquidities(planner.encode(), _deadline);

        // after
        assertEq(token0.balanceOf(alice), 1 ether);
        assertEq(token1.balanceOf(alice), 1 ether);
    }

    function test_take() public {
        // pre-req add liquidity
        uint24[] memory binIds = getBinIds(activeId, 3);
        (, uint256[] memory liquidityMinted) = _addLiquidity(binPm, key1, binIds, activeId);

        // before
        assertEq(token0.balanceOf(address(this)), 999 ether);
        assertEq(token1.balanceOf(address(binPm)), 0);

        // remove liquidity, then try take
        IBinPositionManager.BinRemoveLiquidityParams memory param =
            _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        Plan memory planner = Planner.init();
        planner.add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param));
        planner.add(Actions.TAKE, abi.encode(currency0, ActionConstants.MSG_SENDER, ActionConstants.OPEN_DELTA));
        planner.add(Actions.TAKE, abi.encode(currency1, ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA));
        binPm.modifyLiquidities(planner.encode(), _deadline);

        // after
        assertEq(token0.balanceOf(address(this)), 1000 ether);
        assertEq(token1.balanceOf(address(binPm)), 1 ether);
    }

    function test_take_toAlice() public {
        // pre-req add liquidity
        uint24[] memory binIds = getBinIds(activeId, 3);
        (, uint256[] memory liquidityMinted) = _addLiquidity(binPm, key1, binIds, activeId);

        // before
        assertEq(token0.balanceOf(address(alice)), 0);
        assertEq(token1.balanceOf(address(alice)), 0);

        // remove liquidity, then try take
        IBinPositionManager.BinRemoveLiquidityParams memory param =
            _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        Plan memory planner = Planner.init();
        planner.add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param));
        planner.add(Actions.TAKE, abi.encode(currency0, alice, ActionConstants.OPEN_DELTA));
        planner.add(Actions.TAKE, abi.encode(currency1, alice, ActionConstants.OPEN_DELTA));
        binPm.modifyLiquidities(planner.encode(), _deadline);

        // after
        assertEq(token0.balanceOf(address(alice)), 1 ether);
        assertEq(token1.balanceOf(address(alice)), 1 ether);
    }

    function test_clearOrTake() public {
        // pre-req add liquidity
        uint24[] memory binIds = getBinIds(activeId, 3);
        (, uint256[] memory liquidityMinted) = _addLiquidity(binPm, key1, binIds, activeId);

        // before
        assertEq(token0.balanceOf(address(this)), 999 ether);
        assertEq(token1.balanceOf(address(this)), 999 ether);

        // remove liquidity, then try take
        IBinPositionManager.BinRemoveLiquidityParams memory param =
            _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        Plan memory planner = Planner.init();
        planner.add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param));
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(currency0, 2 ether));
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(currency1, 1 ether - 1));
        binPm.modifyLiquidities(planner.encode(), _deadline);

        // after, as currency1 min amount is 2 ether, clear the debg instead
        assertEq(token0.balanceOf(address(this)), 999 ether);
        assertEq(token1.balanceOf(address(this)), 1000 ether);
    }
}
