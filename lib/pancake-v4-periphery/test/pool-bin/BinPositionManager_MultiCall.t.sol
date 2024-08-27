// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";

import {Vault} from "pancake-v4-core/src/Vault.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {BinPoolParametersHelper} from "pancake-v4-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {SafeCast} from "pancake-v4-core/src/pool-bin/libraries/math/SafeCast.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BinPoolManager} from "pancake-v4-core/src/pool-bin/BinPoolManager.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {PackedUint128Math} from "pancake-v4-core/src/pool-bin/libraries/math/PackedUint128Math.sol";
import {TokenFixture} from "pancake-v4-core/test/helpers/TokenFixture.sol";

import {Permit2Forwarder} from "../../src/base/Permit2Forwarder.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {IBinPositionManager} from "../../src/pool-bin/interfaces/IBinPositionManager.sol";
import {BinPositionManager} from "../../src/pool-bin/BinPositionManager.sol";
import {IBinFungibleToken} from "../../src/pool-bin/interfaces/IBinFungibleToken.sol";
import {Planner, Plan} from "../../src/libraries/Planner.sol";
import {BinTokenLibrary} from "../../src/pool-bin/libraries/BinTokenLibrary.sol";
import {BinLiquidityHelper} from "./helper/BinLiquidityHelper.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {BaseActionsRouter} from "../../src/base/BaseActionsRouter.sol";
import {Permit2SignatureHelpers} from "../shared/Permit2SignatureHelpers.sol";

contract BinPositionManager_MultiCallTest is
    Permit2SignatureHelpers,
    BinLiquidityHelper,
    GasSnapshot,
    TokenFixture,
    DeployPermit2
{
    // <WIP>: maybe
    // 1. try swap -> trigger hook#beforeSwap
    // 2. try removeLiquidity -> trigger hook#beforeRemoveLiquidity
    // 2. try addLiquidity -> trigger hook#addRemoveLiquidity

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
    uint24 activeId = 2 ** 23; // where token0 and token1 price is the same

    address alice;
    uint256 alicePK;
    address bob;
    // bob used for permit2 signature tests
    uint256 bobPK;

    bytes32 PERMIT2_DOMAIN_SEPARATOR;
    uint160 permitAmount = type(uint160).max;
    // the expiration of the allowance is large
    uint48 permitExpiration = uint48(block.timestamp + 10e18);
    uint48 permitNonce = 0;

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

        (alice, alicePK) = makeAddrAndKey("ALICE");
        (bob, bobPK) = makeAddrAndKey("BOB");
        PERMIT2_DOMAIN_SEPARATOR = permit2.DOMAIN_SEPARATOR();

        // approval
        approveBinPm(address(this), key1, address(binPm), permit2);
        approveBinPm(alice, key1, address(binPm), permit2);
        approveBinPm(bob, key1, address(binPm), permit2);
    }

    function test_multicall_initializePool_mint() public {
        vm.deal(address(this), 1 ether);

        // approval for token1 was done earlier, so no new approval required
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: Currency.wrap(address(token1)),
            hooks: IHooks(address(0)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });

        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key, binIds, 1 ether, 1 ether, activeId, address(this));
        Plan memory planner = Planner.init();
        planner.add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        bytes memory actions = planner.finalizeModifyLiquidityWithClose(key);

        // Use multicall to initialize a pool and mint liquidity
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(binPm.initializePool.selector, key, activeId, ZERO_BYTES);
        calls[1] = abi.encodeWithSelector(binPm.modifyLiquidities.selector, actions, _deadline);
        binPm.multicall{value: 1 ether}(calls);

        // verify pool
        (uint128 binReserveX, uint128 binReserveY,) = poolManager.getBin(key.toId(), activeId);
        assertGt(binReserveX, 0);
        assertGt(binReserveY, 0);
    }

    function test_multicall_bubbleRevertX() public {
        uint24[] memory binIds = getBinIds(activeId, 3);
        (, uint256[] memory liquidityMinted) = _addLiquidity(binPm, key1, binIds, activeId);

        // try to decrease liqudiity from another user
        IBinPositionManager.BinRemoveLiquidityParams memory param =
            _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        Plan memory planner = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(binPm.modifyLiquidities.selector, payload, _deadline);

        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IBinFungibleToken.BinFungibleToken_SpenderNotApproved.selector, address(this), alice)
        );
        binPm.multicall(calls);
        vm.stopPrank();
    }

    function test_multicall_bubbleRevert_core() public {
        // add liquidity
        uint24[] memory binIds = getBinIds(activeId, 3);
        (, uint256[] memory liquidityMinted) = _addLiquidity(binPm, key1, binIds, activeId);

        // try to decrease liqudiity from another user
        IBinPositionManager.BinRemoveLiquidityParams memory param =
            _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        Plan memory planner = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param));

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(binPm.modifyLiquidities.selector, planner.encode(), _deadline);
        vm.expectRevert(IVault.CurrencyNotSettled.selector);
        binPm.multicall(calls);
    }

    function test_multicall_permitAndDecrease() public {
        token0.mint(bob, 1 ether);
        token1.mint(bob, 1 ether);

        // 1. revoke the auto permit we give to posm earlier
        vm.prank(bob);
        permit2.approve(Currency.unwrap(currency0), address(binPm), 0, 0);

        // 1b. verify that the approval is gone
        (uint160 _amount,, uint48 _expiration) =
            permit2.allowance(address(bob), Currency.unwrap(currency0), address(this));
        assertEq(_amount, 0);
        assertEq(_expiration, 0);

        // 2 . call a mint that reverts because position manager doesn't have permission on permit2
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, address(this));
        Plan memory planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);
        vm.expectRevert(abi.encodeWithSelector(IAllowanceTransfer.InsufficientAllowance.selector, 0));
        vm.prank(bob);
        binPm.modifyLiquidities(payload, _deadline);

        // 3. encode a permit for that revoked token
        IAllowanceTransfer.PermitSingle memory permit =
            defaultERC20PermitAllowance(Currency.unwrap(currency0), permitAmount, permitExpiration, permitNonce);
        permit.spender = address(binPm);
        bytes memory sig = getPermitSignature(permit, bobPK, PERMIT2_DOMAIN_SEPARATOR);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(Permit2Forwarder.permit.selector, bob, permit, sig);
        calls[1] = abi.encodeWithSelector(binPm.modifyLiquidities.selector, payload, _deadline);
        vm.prank(bob);
        binPm.multicall(calls);

        // verify pool
        (uint128 binReserveX, uint128 binReserveY,) = poolManager.getBin(key1.toId(), activeId);
        assertGt(binReserveX, 0);
        assertGt(binReserveY, 0);
    }
}
