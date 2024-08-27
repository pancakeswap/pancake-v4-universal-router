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
import {BaseActionsRouter} from "../../src/base/BaseActionsRouter.sol";

contract BinPositionManager_ModifyLiquidityTest is BinLiquidityHelper, GasSnapshot, TokenFixture, DeployPermit2 {
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

    function test_modifyLiquidity_beforeDeadline() public {
        vm.warp(1000);

        bytes memory payload = Planner.init().finalizeModifyLiquidityWithClose(key1);

        vm.expectRevert(abi.encodeWithSelector(IPositionManager.DeadlinePassed.selector));
        binPm.modifyLiquidities(payload, 900);
    }

    function test_addLiquidity_inputLengthMisMatch() public {
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param;
        bytes memory payload;

        // distributionX mismatch
        param = _getAddParams(key1, binIds, 100, 100, activeId, address(this));
        param.distributionX = new uint256[](0);
        payload = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(BaseActionsRouter.InputLengthMismatch.selector);
        binPm.modifyLiquidities(payload, _deadline);

        // distributionY mismatch
        param = _getAddParams(key1, binIds, 100, 100, activeId, address(this));
        param.distributionY = new uint256[](0);
        payload = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(BaseActionsRouter.InputLengthMismatch.selector);
        binPm.modifyLiquidities(payload, _deadline);

        // deltaIds mismatch
        param = _getAddParams(key1, binIds, 100, 100, activeId, address(this));
        param.deltaIds = new int256[](0);
        payload = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(BaseActionsRouter.InputLengthMismatch.selector);
        binPm.modifyLiquidities(payload, _deadline);
    }

    function test_addLiquidity_inputActiveIdMismatch(uint256 input) public {
        input = bound(input, uint256(type(uint24).max) + 1, type(uint256).max);

        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param;
        bytes memory payload;

        // active id above type(uint24).max
        param = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        param.activeIdDesired = input;
        payload = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(abi.encodeWithSelector(IBinPositionManager.AddLiquidityInputActiveIdMismath.selector));
        binPm.modifyLiquidities(payload, _deadline);

        // active id normal, but slippage above type(uint24).max
        param = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        param.idSlippage = input;
        payload = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(abi.encodeWithSelector(IBinPositionManager.AddLiquidityInputActiveIdMismath.selector));
        binPm.modifyLiquidities(payload, _deadline);
    }

    function test_addLiquidity_idDesiredOverflow() public {
        uint24[] memory binIds = getBinIds(activeId, 3);

        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        param.activeIdDesired = activeId - 1;
        bytes memory payload = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(abi.encodeWithSelector(IBinPositionManager.IdDesiredOverflows.selector, activeId));
        binPm.modifyLiquidities(payload, _deadline);
    }

    function test_addLiquidity_outputAmountSlippage() public {
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param;
        bytes memory payload;

        // overwrite amount0Min
        param = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        param.amount0Min = 1.1 ether;
        payload = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(abi.encodeWithSelector(IBinPositionManager.OutputAmountSlippage.selector));
        binPm.modifyLiquidities(payload, _deadline);

        // overwrite amount1Min
        param = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        param.amount1Min = 1.1 ether;
        payload = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(abi.encodeWithSelector(IBinPositionManager.OutputAmountSlippage.selector));
        binPm.modifyLiquidities(payload, _deadline);

        // overwrite to 1 eth (expected to not fail)
        param = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        param.amount0Min = 1 ether;
        param.amount1Min = 1 ether;
        Plan memory planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        payload = planner.finalizeModifyLiquidityWithClose(key1);
        binPm.modifyLiquidities(payload, _deadline);
    }

    function test_addLiquidity_SingleBin() public {
        uint24[] memory binIds = getBinIds(activeId, 1);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, address(this));
        Plan memory planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);

        snapStart("BinPositionManager_ModifyLiquidityTest#test_addLiquidity_SingleBin");
        binPm.modifyLiquidities(payload, _deadline);
        snapEnd();
    }

    function test_addLiquidity_ThreeBins() public {
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        Plan memory planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);

        // building event to verify
        uint256[] memory liquidityMinted = new uint256[](binIds.length);
        bytes32 binReserves = PackedUint128Math.encode(0, 0); // binReserve=0 for new pool
        liquidityMinted[0] = calculateLiquidityMinted(binReserves, 0 ether, 0.5 ether, binIds[0], 10, 0);
        liquidityMinted[1] = calculateLiquidityMinted(binReserves, 0.5 ether, 0.5 ether, binIds[1], 10, 0);
        liquidityMinted[2] = calculateLiquidityMinted(binReserves, 0.5 ether, 0 ether, binIds[2], 10, 0);
        uint256[] memory tokenIds = new uint256[](binIds.length);
        for (uint256 i; i < binIds.length; i++) {
            tokenIds[i] = key1.toId().toTokenId(binIds[i]);
        }
        vm.expectEmit();
        emit IBinFungibleToken.TransferBatch(address(this), address(0), alice, tokenIds, liquidityMinted);

        snapStart("BinPositionManager_ModifyLiquidityTest#test_addLiquidity_ThreeBins");
        binPm.modifyLiquidities(payload, _deadline);
        snapEnd();
    }

    function test_addLiquidity_OutsideActiveId() public {
        token1.mint(alice, 2 ether);

        // before: 2 ether
        assertEq(token1.balanceOf(alice), 2 ether);
        vm.startPrank(alice);

        uint24[] memory binIds = getBinIds(activeId - 10, 5); // 5 bins to the left
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        Plan memory planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);

        snapStart("BinPositionManager_ModifyLiquidityTest#test_addLiquidity_OutsideActiveId_NewId");
        binPm.modifyLiquidities(payload, _deadline);
        snapEnd();

        // after: 1 ether consumed
        assertEq(token1.balanceOf(alice), 1 ether);

        // verify nft minted to user
        bytes32 binReserves = PackedUint128Math.encode(0, 0); // binReserve=0 for new pool
        for (uint256 i; i < binIds.length; i++) {
            uint256 tokenId = key1.toId().toTokenId(binIds[i]);
            uint256 bal = binPm.balanceOf(alice, tokenId);
            uint256 expectedBal = calculateLiquidityMinted(binReserves, 0, 0.2 ether, binIds[i], 10, 0);
            assertApproxEqAbs(bal, expectedBal, 1);
        }

        // re-add existing id, gas should be way cheaper
        snapStart("BinPositionManager_ModifyLiquidityTest#test_addLiquidity_OutsideActiveId_ExistingId");
        binPm.modifyLiquidities(payload, _deadline);
        snapEnd();
    }

    function test_addLiquidity_WithHook() public {
        // todo: add liquidity, hook do a swap at beforeMint
        // ref: https://github.com/pancakeswap/pancake-v4-periphery/blob/main/test/pool-bin/BinFungiblePositionManager_AddLiquidity.t.sol#L407
    }

    function test_positions() public {
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        Plan memory planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);
        binPm.modifyLiquidities(payload, _deadline);

        for (uint256 i; i < binIds.length; i++) {
            uint256 tokenId = calculateTokenId(key1.toId(), binIds[i]);

            (PoolId poolId, Currency curr0, Currency curr1, uint24 fee, uint24 binId) = binPm.positions(tokenId);
            assertEq(PoolId.unwrap(poolId), PoolId.unwrap(key1.toId()));
            assertEq(Currency.unwrap(curr0), Currency.unwrap(key1.currency0));
            assertEq(Currency.unwrap(curr1), Currency.unwrap(key1.currency1));
            assertEq(fee, key1.fee);
            assertEq(binId, binIds[i]);
        }
    }

    function test_decreaseLiquidity_InputLengthMismatch() public {
        uint24[] memory binIds = getBinIds(activeId, 3);
        (, uint256[] memory liquidityMinted) = _addLiquidity(binPm, key1, binIds, activeId);

        IBinPositionManager.BinRemoveLiquidityParams memory param;
        bytes memory payload;

        // amount mismatch
        param = _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        param.amounts = new uint256[](0);
        payload = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(abi.encodeWithSelector(BaseActionsRouter.InputLengthMismatch.selector));
        binPm.modifyLiquidities(payload, _deadline);

        // id mismatch
        param = _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        param.ids = new uint256[](0);
        payload = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(abi.encodeWithSelector(BaseActionsRouter.InputLengthMismatch.selector));
        binPm.modifyLiquidities(payload, _deadline);
    }

    function test_decreaseLiquidity_OutputAmountSlippage() public {
        uint24[] memory binIds = getBinIds(activeId, 3);
        (, uint256[] memory liquidityMinted) = _addLiquidity(binPm, key1, binIds, activeId);

        IBinPositionManager.BinRemoveLiquidityParams memory param;
        bytes memory payload;

        // amount0 min slippage
        param = _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        param.amount0Min = 2 ether;
        payload = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(abi.encodeWithSelector(IBinPositionManager.OutputAmountSlippage.selector));
        binPm.modifyLiquidities(payload, _deadline);

        // amount1 min slippage
        param = _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        param.amount1Min = 2 ether;
        payload = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(abi.encodeWithSelector(IBinPositionManager.OutputAmountSlippage.selector));
        binPm.modifyLiquidities(payload, _deadline);

        // amount and amount0 min slippage
        param = _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        param.amount0Min = 2 ether;
        param.amount1Min = 2 ether;
        payload = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(abi.encodeWithSelector(IBinPositionManager.OutputAmountSlippage.selector));
        binPm.modifyLiquidities(payload, _deadline);
    }

    function test_decreaseLiquidity_threeBins() public {
        // add liquidity
        uint24[] memory binIds = getBinIds(activeId, 3);
        (uint256[] memory tokenIds, uint256[] memory liquidityMinted) = _addLiquidity(binPm, key1, binIds, activeId);

        // check initial token balance and verify liquidity minted greater than 0
        assertEq(token0.balanceOf(address(this)), 999 ether);
        assertEq(token1.balanceOf(address(this)), 999 ether);
        for (uint256 i; i < tokenIds.length; i++) {
            assertGt(binPm.balanceOf(address(this), tokenIds[i]), 0);
        }

        IBinPositionManager.BinRemoveLiquidityParams memory param =
            _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        Plan memory planner = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);

        // Verify event emitted
        vm.expectEmit();
        emit IBinFungibleToken.TransferBatch(address(this), address(this), address(0), tokenIds, liquidityMinted);

        snapStart("BinPositionManager_ModifyLiquidityTest#test_decreaseLiquidity_threeBins");
        binPm.modifyLiquidities(payload, _deadline);
        snapEnd();

        // check after token balance and verify liquidity owned = 0
        assertEq(token0.balanceOf(address(this)), 1000 ether);
        assertEq(token1.balanceOf(address(this)), 1000 ether);
        for (uint256 i; i < tokenIds.length; i++) {
            assertEq(binPm.balanceOf(address(this), tokenIds[i]), 0);
        }
    }

    function test_decreaseLiquidity_threeBins_half() public {
        uint24[] memory binIds = getBinIds(activeId, 3);
        (, uint256[] memory liquidityMinted) = _addLiquidity(binPm, key1, binIds, activeId);

        IBinPositionManager.BinRemoveLiquidityParams memory param =
            _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        for (uint256 i; i < param.amounts.length; i++) {
            param.amounts[i] = param.amounts[i] / 2;
        }
        Plan memory planner = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);

        snapStart("BinPositionManager_ModifyLiquidityTest#test_decreaseLiquidity_threeBins_half");
        binPm.modifyLiquidities(payload, _deadline);
        snapEnd();
    }

    function test_decreaseLiquidity_overBalance() public {
        uint24[] memory binIds = getBinIds(activeId, 3);
        (, uint256[] memory liquidityMinted) = _addLiquidity(binPm, key1, binIds, activeId);

        IBinPositionManager.BinRemoveLiquidityParams memory param =
            _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        for (uint256 i; i < param.amounts.length; i++) {
            param.amounts[i] = param.amounts[i] * 2;
        }

        Plan memory planner = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);

        vm.expectRevert(stdError.arithmeticError);
        binPm.modifyLiquidities(payload, _deadline);
    }

    function test_decreaseLiquidity_withoutSpenderApproval() public {
        uint24[] memory binIds = getBinIds(activeId, 3);
        (, uint256[] memory liquidityMinted) = _addLiquidity(binPm, key1, binIds, activeId);

        // alice try to remove on behalf of address(this)
        vm.startPrank(alice);
        IBinPositionManager.BinRemoveLiquidityParams memory param =
            _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        Plan memory planner = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);

        vm.expectRevert(
            abi.encodeWithSelector(IBinFungibleToken.BinFungibleToken_SpenderNotApproved.selector, address(this), alice)
        );
        binPm.modifyLiquidities(payload, _deadline);
    }

    function test_decreaseLiquidity_withSpenderApproval() public {
        uint24[] memory binIds = getBinIds(activeId, 3);
        (, uint256[] memory liquidityMinted) = _addLiquidity(binPm, key1, binIds, activeId);
        binPm.approveForAll(alice, true);

        // before, verify alice balance
        assertEq(token1.balanceOf(alice), 0 ether);
        assertEq(token1.balanceOf(alice), 0 ether);

        // alice try to remove on behalf of address(this)
        vm.startPrank(alice);
        IBinPositionManager.BinRemoveLiquidityParams memory param =
            _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        Plan memory planner = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);
        binPm.modifyLiquidities(payload, _deadline);

        // after, verify alice balance increased as tokens sent to alice
        assertEq(token1.balanceOf(alice), 1 ether);
        assertEq(token1.balanceOf(alice), 1 ether);
    }
}
