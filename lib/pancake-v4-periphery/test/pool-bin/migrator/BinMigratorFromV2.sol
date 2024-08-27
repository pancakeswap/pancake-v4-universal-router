// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {OldVersionHelper} from "../../helpers/OldVersionHelper.sol";
import {IPancakePair} from "../../../src/interfaces/external/IPancakePair.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BinMigrator} from "../../../src/pool-bin/BinMigrator.sol";
import {IBinMigrator, IBaseMigrator} from "../../../src/pool-bin/interfaces/IBinMigrator.sol";
import {IBinPositionManager} from "../../../src/pool-bin/interfaces/IBinPositionManager.sol";
import {BinPositionManager} from "../../../src/pool-bin/BinPositionManager.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {Vault} from "pancake-v4-core/src/Vault.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BinPoolManager} from "pancake-v4-core/src/pool-bin/BinPoolManager.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {BinPoolParametersHelper} from "pancake-v4-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {IPoolManager} from "pancake-v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {BinLiquidityHelper} from "../helper/BinLiquidityHelper.sol";
import {BinTokenLibrary} from "../../../src/pool-bin/libraries/BinTokenLibrary.sol";
import {Plan, Planner} from "../../../src/libraries/Planner.sol";
import {Actions} from "../../../src/libraries/Actions.sol";
import {SafeCallback} from "../../../src/base/SafeCallback.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {MockReentrantPositionManager} from "../../mocks/MockReentrantPositionManager.sol";
import {ReentrancyLock} from "../../../src/base/ReentrancyLock.sol";
import {Permit2ApproveHelper} from "../../helpers/Permit2ApproveHelper.sol";
import {Permit2SignatureHelpers} from "../../shared/Permit2SignatureHelpers.sol";
import {Permit2Forwarder} from "../../../src/base/Permit2Forwarder.sol";
import {IPositionManager} from "../../../src/interfaces/IPositionManager.sol";

interface IPancakeV2LikePairFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

abstract contract BinMigratorFromV2 is
    OldVersionHelper,
    BinLiquidityHelper,
    DeployPermit2,
    Permit2ApproveHelper,
    Permit2SignatureHelpers,
    GasSnapshot
{
    using BinPoolParametersHelper for bytes32;
    using PoolIdLibrary for PoolKey;
    using BinTokenLibrary for PoolId;

    // 1 tokenX = 1 tokenY
    uint24 public constant ACTIVE_BIN_ID = 2 ** 23;

    WETH weth;
    MockERC20 token0;
    MockERC20 token1;

    Vault vault;
    BinPoolManager poolManager;
    BinPositionManager binPm;
    IAllowanceTransfer permit2;
    IBinMigrator migrator;
    PoolKey poolKey;
    PoolKey poolKeyWithoutNativeToken;

    IPancakeV2LikePairFactory v2Factory;
    IPancakePair v2Pair;
    IPancakePair v2PairWithoutNativeToken;
    bytes32 PERMIT2_DOMAIN_SEPARATOR;

    function _getBytecodePath() internal pure virtual returns (string memory);

    function _getContractName() internal pure virtual returns (string memory);

    function setUp() public {
        weth = new WETH();
        token0 = new MockERC20("Token0", "TKN0", 18);
        token1 = new MockERC20("Token1", "TKN1", 18);
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);

        // init v4 nfpm & migrator
        vault = new Vault();
        poolManager = new BinPoolManager(IVault(address(vault)), 3000);
        vault.registerApp(address(poolManager));
        permit2 = IAllowanceTransfer(deployPermit2());
        binPm = new BinPositionManager(IVault(address(vault)), IBinPoolManager(address(poolManager)), permit2);
        migrator = new BinMigrator(address(weth), address(binPm), permit2);

        PERMIT2_DOMAIN_SEPARATOR = permit2.DOMAIN_SEPARATOR();

        poolKey = PoolKey({
            // WETH after migration will be native token
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token0)),
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: 0,
            parameters: bytes32(0).setBinStep(1)
        });

        poolKeyWithoutNativeToken = poolKey;
        poolKeyWithoutNativeToken.currency0 = Currency.wrap(address(token0));
        poolKeyWithoutNativeToken.currency1 = Currency.wrap(address(token1));

        // make sure the contract has enough balance
        // WETH: 100 ether
        // Token: 100 ether
        // ETH: 90 ether
        deal(address(this), 1000 ether);
        weth.deposit{value: 100 ether}();
        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 100 ether);

        v2Factory = IPancakeV2LikePairFactory(createContractThroughBytecode(_getBytecodePath()));
        v2Pair = IPancakePair(v2Factory.createPair(address(weth), address(token0)));
        v2PairWithoutNativeToken = IPancakePair(v2Factory.createPair(address(token0), address(token1)));
    }

    function testMigrateFromV2ReentrancyLockRevert() public {
        MockReentrantPositionManager reentrantPM = new MockReentrantPositionManager(permit2);
        migrator = new BinMigrator(address(weth), address(reentrantPM), permit2);
        reentrantPM.setBinMigrator(migrator);
        reentrantPM.setRenentrantType(MockReentrantPositionManager.ReentrantType.BinMigrateFromV2);
        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2Pair);
        uint256 lpTokenBefore = v2Pair.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. make sure migrator can transfer user's v2 lp token
        permit2ApproveWithSpecificAllowance(
            address(this), permit2, address(v2Pair), address(migrator), lpTokenBefore, uint160(lpTokenBefore)
        );

        // 3. initialize the pool
        poolManager.initialize(poolKey, ACTIVE_BIN_ID, bytes(""));

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2Pair),
            migrateAmount: lpTokenBefore,
            // minor precision loss is acceptable
            amount0Min: 9.999 ether,
            amount1Min: 9.999 ether
        });

        IBinPositionManager.BinAddLiquidityParams memory params =
            _getAddParams(poolKey, getBinIds(ACTIVE_BIN_ID, 3), 10 ether, 10 ether, ACTIVE_BIN_ID, address(this));

        IBinMigrator.V4BinPoolParams memory v4BinPoolParams = IBinMigrator.V4BinPoolParams({
            poolKey: params.poolKey,
            amount0Min: params.amount0Min,
            amount1Min: params.amount1Min,
            activeIdDesired: params.activeIdDesired,
            idSlippage: params.idSlippage,
            deltaIds: params.deltaIds,
            distributionX: params.distributionX,
            distributionY: params.distributionY,
            to: params.to,
            deadline: block.timestamp + 1
        });

        vm.expectRevert(ReentrancyLock.ContractLocked.selector);
        migrator.migrateFromV2(v2PoolParams, v4BinPoolParams, 0, 0);
    }

    function testMigrateFromV2IncludingInit() public {
        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2Pair);
        uint256 lpTokenBefore = v2Pair.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. make sure migrator can transfer user's v2 lp token
        permit2ApproveWithSpecificAllowance(
            address(this), permit2, address(v2Pair), address(migrator), lpTokenBefore, uint160(lpTokenBefore)
        );

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2Pair),
            migrateAmount: lpTokenBefore,
            // minor precision loss is acceptable
            amount0Min: 9.999 ether,
            amount1Min: 9.999 ether
        });

        IBinPositionManager.BinAddLiquidityParams memory params =
            _getAddParams(poolKey, getBinIds(ACTIVE_BIN_ID, 3), 10 ether, 10 ether, ACTIVE_BIN_ID, address(this));

        IBinMigrator.V4BinPoolParams memory v4BinPoolParams = IBinMigrator.V4BinPoolParams({
            poolKey: params.poolKey,
            amount0Min: params.amount0Min,
            amount1Min: params.amount1Min,
            activeIdDesired: params.activeIdDesired,
            idSlippage: params.idSlippage,
            deltaIds: params.deltaIds,
            distributionX: params.distributionX,
            distributionY: params.distributionY,
            to: params.to,
            deadline: block.timestamp + 1
        });

        // 3. multicall, combine initialize and migrateFromV2
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(migrator.initializePool.selector, poolKey, ACTIVE_BIN_ID, bytes(""));
        data[1] = abi.encodeWithSelector(migrator.migrateFromV2.selector, v2PoolParams, v4BinPoolParams, 0, 0);
        snapStart(string(abi.encodePacked(_getContractName(), "#testMigrateFromV2IncludingInit")));
        migrator.multicall(data);
        snapEnd();

        // necessary checks
        // v2 pair should be burned already
        assertEq(v2Pair.balanceOf(address(this)), 0);

        // make sure liuqidty is minted to the correct pool
        assertApproxEqAbs(address(vault).balance, 10 ether, 0.000001 ether);
        assertApproxEqAbs(token0.balanceOf(address(vault)), 10 ether, 0.000001 ether);

        uint256 positionId0 = poolKey.toId().toTokenId(ACTIVE_BIN_ID - 1);
        uint256 positionId1 = poolKey.toId().toTokenId(ACTIVE_BIN_ID);
        uint256 positionId2 = poolKey.toId().toTokenId(ACTIVE_BIN_ID + 1);
        uint256 positionId3 = poolKey.toId().toTokenId(ACTIVE_BIN_ID + 2);
        assertGt(binPm.balanceOf(address(this), positionId0), 0);
        assertGt(binPm.balanceOf(address(this), positionId1), 0);
        assertGt(binPm.balanceOf(address(this), positionId2), 0);
        assertEq(binPm.balanceOf(address(this), positionId3), 0);

        (PoolId poolId, Currency currency0, Currency currency1, uint24 fee, uint24 binId) = binPm.positions(positionId0);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKey.toId()));
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token0));
        assertEq(fee, 0);
        assertEq(binId, ACTIVE_BIN_ID - 1);

        (poolId, currency0, currency1, fee, binId) = binPm.positions(positionId1);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKey.toId()));
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token0));
        assertEq(fee, 0);
        assertEq(binId, ACTIVE_BIN_ID);

        (poolId, currency0, currency1, fee, binId) = binPm.positions(positionId2);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKey.toId()));
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token0));
        assertEq(fee, 0);
        assertEq(binId, ACTIVE_BIN_ID + 1);

        vm.expectRevert(IPositionManager.InvalidTokenID.selector);
        (poolId, currency0, currency1, fee, binId) = binPm.positions(positionId3);
    }

    function testMigrateFromV2TokenMismatch() public {
        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2Pair);
        uint256 lpTokenBefore = v2Pair.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. make sure migrator can transfer user's v2 lp token
        permit2ApproveWithSpecificAllowance(
            address(this), permit2, address(v2Pair), address(migrator), lpTokenBefore, uint160(lpTokenBefore)
        );

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2Pair),
            migrateAmount: lpTokenBefore,
            // minor precision loss is acceptable
            amount0Min: 9.999 ether,
            amount1Min: 9.999 ether
        });

        IBinPositionManager.BinAddLiquidityParams memory params =
            _getAddParams(poolKey, getBinIds(ACTIVE_BIN_ID, 3), 10 ether, 10 ether, ACTIVE_BIN_ID, address(this));

        // v2 weth, token0
        // v4 ETH, token1
        PoolKey memory poolKeyMismatch = poolKey;
        poolKeyMismatch.currency1 = Currency.wrap(address(token1));
        IBinMigrator.V4BinPoolParams memory v4BinPoolParams = IBinMigrator.V4BinPoolParams({
            poolKey: poolKeyMismatch,
            amount0Min: params.amount0Min,
            amount1Min: params.amount1Min,
            activeIdDesired: params.activeIdDesired,
            idSlippage: params.idSlippage,
            deltaIds: params.deltaIds,
            distributionX: params.distributionX,
            distributionY: params.distributionY,
            to: params.to,
            deadline: block.timestamp + 1
        });

        // 3. multicall, combine initialize and migrateFromV2
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(migrator.initializePool.selector, poolKeyMismatch, ACTIVE_BIN_ID, bytes(""));
        data[1] = abi.encodeWithSelector(migrator.migrateFromV2.selector, v2PoolParams, v4BinPoolParams, 0, 0);
        vm.expectRevert();
        migrator.multicall(data);

        {
            // v2 weth, token0
            // v4 token0, token1
            poolKeyMismatch.currency0 = Currency.wrap(address(token0));
            poolKeyMismatch.currency1 = Currency.wrap(address(token1));
            v4BinPoolParams.poolKey = poolKeyMismatch;
            data = new bytes[](2);
            data[0] =
                abi.encodeWithSelector(migrator.initializePool.selector, poolKeyMismatch, ACTIVE_BIN_ID, bytes(""));
            data[1] = abi.encodeWithSelector(migrator.migrateFromV2.selector, v2PoolParams, v4BinPoolParams, 0, 0);
            vm.expectRevert();
            migrator.multicall(data);
        }
    }

    function testMigrateFromV2WithoutInit() public {
        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2Pair);
        uint256 lpTokenBefore = v2Pair.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. make sure migrator can transfer user's v2 lp token
        permit2ApproveWithSpecificAllowance(
            address(this), permit2, address(v2Pair), address(migrator), lpTokenBefore, uint160(lpTokenBefore)
        );

        // 3. initialize the pool
        migrator.initializePool(poolKey, ACTIVE_BIN_ID, bytes(""));

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2Pair),
            migrateAmount: lpTokenBefore,
            // minor precision loss is acceptable
            amount0Min: 9.999 ether,
            amount1Min: 9.999 ether
        });

        IBinPositionManager.BinAddLiquidityParams memory params =
            _getAddParams(poolKey, getBinIds(ACTIVE_BIN_ID, 3), 10 ether, 10 ether, ACTIVE_BIN_ID, address(this));

        IBinMigrator.V4BinPoolParams memory v4BinPoolParams = IBinMigrator.V4BinPoolParams({
            poolKey: params.poolKey,
            amount0Min: params.amount0Min,
            amount1Min: params.amount1Min,
            activeIdDesired: params.activeIdDesired,
            idSlippage: params.idSlippage,
            deltaIds: params.deltaIds,
            distributionX: params.distributionX,
            distributionY: params.distributionY,
            to: params.to,
            deadline: block.timestamp + 1
        });

        // 4. migrateFromV2
        snapStart(string(abi.encodePacked(_getContractName(), "#testMigrateFromV2WithoutInit")));
        migrator.migrateFromV2(v2PoolParams, v4BinPoolParams, 0, 0);
        snapEnd();

        // necessary checks
        // v2 pair should be burned already
        assertEq(v2Pair.balanceOf(address(this)), 0);

        // make sure liuqidty is minted to the correct pool
        assertApproxEqAbs(address(vault).balance, 10 ether, 0.000001 ether);
        assertApproxEqAbs(token0.balanceOf(address(vault)), 10 ether, 0.000001 ether);

        uint256 positionId0 = poolKey.toId().toTokenId(ACTIVE_BIN_ID - 1);
        uint256 positionId1 = poolKey.toId().toTokenId(ACTIVE_BIN_ID);
        uint256 positionId2 = poolKey.toId().toTokenId(ACTIVE_BIN_ID + 1);
        uint256 positionId3 = poolKey.toId().toTokenId(ACTIVE_BIN_ID + 2);
        assertGt(binPm.balanceOf(address(this), positionId0), 0);
        assertGt(binPm.balanceOf(address(this), positionId1), 0);
        assertGt(binPm.balanceOf(address(this), positionId2), 0);
        assertEq(binPm.balanceOf(address(this), positionId3), 0);

        (PoolId poolId, Currency currency0, Currency currency1, uint24 fee, uint24 binId) = binPm.positions(positionId0);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKey.toId()));
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token0));
        assertEq(fee, 0);
        assertEq(binId, ACTIVE_BIN_ID - 1);

        (poolId, currency0, currency1, fee, binId) = binPm.positions(positionId1);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKey.toId()));
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token0));
        assertEq(fee, 0);
        assertEq(binId, ACTIVE_BIN_ID);

        (poolId, currency0, currency1, fee, binId) = binPm.positions(positionId2);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKey.toId()));
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token0));
        assertEq(fee, 0);
        assertEq(binId, ACTIVE_BIN_ID + 1);

        vm.expectRevert(IPositionManager.InvalidTokenID.selector);
        (poolId, currency0, currency1, fee, binId) = binPm.positions(positionId3);
    }

    function testMigrateFromV2WithoutNativeToken() public {
        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2PairWithoutNativeToken);
        uint256 lpTokenBefore = v2PairWithoutNativeToken.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. make sure migrator can transfer user's v2 lp token
        permit2ApproveWithSpecificAllowance(
            address(this),
            permit2,
            address(v2PairWithoutNativeToken),
            address(migrator),
            lpTokenBefore,
            uint160(lpTokenBefore)
        );

        // 3. initialize the pool
        migrator.initializePool(poolKeyWithoutNativeToken, ACTIVE_BIN_ID, bytes(""));

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2PairWithoutNativeToken),
            migrateAmount: lpTokenBefore,
            // minor precision loss is acceptable
            amount0Min: 9.999 ether,
            amount1Min: 9.999 ether
        });

        IBinPositionManager.BinAddLiquidityParams memory params = _getAddParams(
            poolKeyWithoutNativeToken, getBinIds(ACTIVE_BIN_ID, 3), 10 ether, 10 ether, ACTIVE_BIN_ID, address(this)
        );

        IBinMigrator.V4BinPoolParams memory v4BinPoolParams = IBinMigrator.V4BinPoolParams({
            poolKey: params.poolKey,
            amount0Min: params.amount0Min,
            amount1Min: params.amount1Min,
            activeIdDesired: params.activeIdDesired,
            idSlippage: params.idSlippage,
            deltaIds: params.deltaIds,
            distributionX: params.distributionX,
            distributionY: params.distributionY,
            to: params.to,
            deadline: block.timestamp + 1
        });

        // 4. migrate from v2 to v4
        snapStart(string(abi.encodePacked(_getContractName(), "#testMigrateFromV2WithoutNativeToken")));
        migrator.migrateFromV2(v2PoolParams, v4BinPoolParams, 0, 0);
        snapEnd();

        // necessary checks
        // v2 pair should be burned already
        assertEq(v2PairWithoutNativeToken.balanceOf(address(this)), 0);

        // make sure liuqidty is minted to the correct pool
        assertApproxEqAbs(token0.balanceOf(address(vault)), 10 ether, 0.000001 ether);
        assertApproxEqAbs(token1.balanceOf(address(vault)), 10 ether, 0.000001 ether);

        uint256 positionId0 = poolKeyWithoutNativeToken.toId().toTokenId(ACTIVE_BIN_ID - 1);
        uint256 positionId1 = poolKeyWithoutNativeToken.toId().toTokenId(ACTIVE_BIN_ID);
        uint256 positionId2 = poolKeyWithoutNativeToken.toId().toTokenId(ACTIVE_BIN_ID + 1);
        uint256 positionId3 = poolKeyWithoutNativeToken.toId().toTokenId(ACTIVE_BIN_ID + 2);
        assertGt(binPm.balanceOf(address(this), positionId0), 0);
        assertGt(binPm.balanceOf(address(this), positionId1), 0);
        assertGt(binPm.balanceOf(address(this), positionId2), 0);
        assertEq(binPm.balanceOf(address(this), positionId3), 0);

        (PoolId poolId, Currency currency0, Currency currency1, uint24 fee, uint24 binId) = binPm.positions(positionId0);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKeyWithoutNativeToken.toId()));
        assertEq(Currency.unwrap(currency0), address(token0));
        assertEq(Currency.unwrap(currency1), address(token1));
        assertEq(fee, 0);
        assertEq(binId, ACTIVE_BIN_ID - 1);

        (poolId, currency0, currency1, fee, binId) = binPm.positions(positionId1);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKeyWithoutNativeToken.toId()));
        assertEq(Currency.unwrap(currency0), address(token0));
        assertEq(Currency.unwrap(currency1), address(token1));
        assertEq(fee, 0);
        assertEq(binId, ACTIVE_BIN_ID);

        (poolId, currency0, currency1, fee, binId) = binPm.positions(positionId2);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKeyWithoutNativeToken.toId()));
        assertEq(Currency.unwrap(currency0), address(token0));
        assertEq(Currency.unwrap(currency1), address(token1));
        assertEq(fee, 0);
        assertEq(binId, ACTIVE_BIN_ID + 1);

        vm.expectRevert(IPositionManager.InvalidTokenID.selector);
        (poolId, currency0, currency1, fee, binId) = binPm.positions(positionId3);
    }

    function testMigrateFromV2AddExtraAmount() public {
        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2Pair);
        uint256 lpTokenBefore = v2Pair.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. make sure migrator can transfer user's v2 lp token
        permit2ApproveWithSpecificAllowance(
            address(this), permit2, address(v2Pair), address(migrator), lpTokenBefore, uint160(lpTokenBefore)
        );

        // 3. initialize the pool
        migrator.initializePool(poolKey, ACTIVE_BIN_ID, bytes(""));

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2Pair),
            migrateAmount: lpTokenBefore,
            // minor precision loss is acceptable
            amount0Min: 9.999 ether,
            amount1Min: 9.999 ether
        });

        IBinPositionManager.BinAddLiquidityParams memory params =
            _getAddParams(poolKey, getBinIds(ACTIVE_BIN_ID, 3), 10 ether, 10 ether, ACTIVE_BIN_ID, address(this));

        IBinMigrator.V4BinPoolParams memory v4BinPoolParams = IBinMigrator.V4BinPoolParams({
            poolKey: params.poolKey,
            amount0Min: params.amount0Min,
            amount1Min: params.amount1Min,
            activeIdDesired: params.activeIdDesired,
            idSlippage: params.idSlippage,
            deltaIds: params.deltaIds,
            distributionX: params.distributionX,
            distributionY: params.distributionY,
            to: params.to,
            deadline: block.timestamp + 1
        });

        uint256 balance0Before = address(this).balance;
        uint256 balance1Before = token0.balanceOf(address(this));

        permit2ApproveWithSpecificAllowance(
            address(this), permit2, address(token0), address(migrator), 20 ether, 20 ether
        );
        // 4. migrate from v2 to v4
        migrator.migrateFromV2{value: 20 ether}(v2PoolParams, v4BinPoolParams, 20 ether, 20 ether);

        // necessary checks
        // consumed extra 20 ether from user
        assertApproxEqAbs(balance0Before - address(this).balance, 20 ether, 0.000001 ether);
        assertEq(balance1Before - token0.balanceOf(address(this)), 20 ether);
        // WETH balance unchanged
        assertEq(weth.balanceOf(address(this)), 90 ether);

        // v2 pair should be burned already
        assertEq(v2Pair.balanceOf(address(this)), 0);

        // make sure liuqidty is minted to the correct pool
        assertApproxEqAbs(address(vault).balance, 30 ether, 0.000001 ether);
        assertApproxEqAbs(token0.balanceOf(address(vault)), 30 ether, 0.000001 ether);

        uint256 positionId0 = poolKey.toId().toTokenId(ACTIVE_BIN_ID - 1);
        uint256 positionId1 = poolKey.toId().toTokenId(ACTIVE_BIN_ID);
        uint256 positionId2 = poolKey.toId().toTokenId(ACTIVE_BIN_ID + 1);
        uint256 positionId3 = poolKey.toId().toTokenId(ACTIVE_BIN_ID + 2);
        assertGt(binPm.balanceOf(address(this), positionId0), 0);
        assertGt(binPm.balanceOf(address(this), positionId1), 0);
        assertGt(binPm.balanceOf(address(this), positionId2), 0);
        assertEq(binPm.balanceOf(address(this), positionId3), 0);

        (PoolId poolId, Currency currency0, Currency currency1, uint24 fee, uint24 binId) = binPm.positions(positionId0);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKey.toId()));
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token0));
        assertEq(fee, 0);
        assertEq(binId, ACTIVE_BIN_ID - 1);

        (poolId, currency0, currency1, fee, binId) = binPm.positions(positionId1);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKey.toId()));
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token0));
        assertEq(fee, 0);
        assertEq(binId, ACTIVE_BIN_ID);

        (poolId, currency0, currency1, fee, binId) = binPm.positions(positionId2);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKey.toId()));
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token0));
        assertEq(fee, 0);
        assertEq(binId, ACTIVE_BIN_ID + 1);

        vm.expectRevert(IPositionManager.InvalidTokenID.selector);
        (poolId, currency0, currency1, fee, binId) = binPm.positions(positionId3);
    }

    function testMigrateFromV2AddExtraAmountThroughWETH() public {
        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2Pair);
        uint256 lpTokenBefore = v2Pair.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. make sure migrator can transfer user's v2 lp token

        permit2ApproveWithSpecificAllowance(
            address(this), permit2, address(v2Pair), address(migrator), lpTokenBefore, uint160(lpTokenBefore)
        );

        // 3. initialize the pool
        migrator.initializePool(poolKey, ACTIVE_BIN_ID, bytes(""));

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2Pair),
            migrateAmount: lpTokenBefore,
            // minor precision loss is acceptable
            amount0Min: 9.999 ether,
            amount1Min: 9.999 ether
        });

        IBinPositionManager.BinAddLiquidityParams memory params =
            _getAddParams(poolKey, getBinIds(ACTIVE_BIN_ID, 3), 10 ether, 10 ether, ACTIVE_BIN_ID, address(this));

        IBinMigrator.V4BinPoolParams memory v4BinPoolParams = IBinMigrator.V4BinPoolParams({
            poolKey: params.poolKey,
            amount0Min: params.amount0Min,
            amount1Min: params.amount1Min,
            activeIdDesired: params.activeIdDesired,
            idSlippage: params.idSlippage,
            deltaIds: params.deltaIds,
            distributionX: params.distributionX,
            distributionY: params.distributionY,
            to: params.to,
            deadline: block.timestamp + 1
        });

        uint256 balance0Before = address(this).balance;
        uint256 balance1Before = token0.balanceOf(address(this));

        permit2ApproveWithSpecificAllowance(
            address(this), permit2, address(weth), address(migrator), 20 ether, 20 ether
        );
        permit2ApproveWithSpecificAllowance(
            address(this), permit2, address(token0), address(migrator), 20 ether, 20 ether
        );
        // 4. migrate from v2 to v4, not sending ETH denotes pay by WETH
        migrator.migrateFromV2(v2PoolParams, v4BinPoolParams, 20 ether, 20 ether);

        // necessary checks
        // consumed extra 20 ether from user
        // native token balance unchanged
        assertApproxEqAbs(balance0Before - address(this).balance, 0 ether, 0.000001 ether);
        assertEq(balance1Before - token0.balanceOf(address(this)), 20 ether);
        // consumed 20 ether WETH
        assertEq(weth.balanceOf(address(this)), 70 ether);

        // v2 pair should be burned already
        assertEq(v2Pair.balanceOf(address(this)), 0);

        // make sure liuqidty is minted to the correct pool
        assertApproxEqAbs(address(vault).balance, 30 ether, 0.000001 ether);
        assertApproxEqAbs(token0.balanceOf(address(vault)), 30 ether, 0.000001 ether);

        uint256 positionId0 = poolKey.toId().toTokenId(ACTIVE_BIN_ID - 1);
        uint256 positionId1 = poolKey.toId().toTokenId(ACTIVE_BIN_ID);
        uint256 positionId2 = poolKey.toId().toTokenId(ACTIVE_BIN_ID + 1);
        uint256 positionId3 = poolKey.toId().toTokenId(ACTIVE_BIN_ID + 2);
        assertGt(binPm.balanceOf(address(this), positionId0), 0);
        assertGt(binPm.balanceOf(address(this), positionId1), 0);
        assertGt(binPm.balanceOf(address(this), positionId2), 0);
        assertEq(binPm.balanceOf(address(this), positionId3), 0);

        (PoolId poolId, Currency currency0, Currency currency1, uint24 fee, uint24 binId) = binPm.positions(positionId0);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKey.toId()));
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token0));
        assertEq(fee, 0);
        assertEq(binId, ACTIVE_BIN_ID - 1);

        (poolId, currency0, currency1, fee, binId) = binPm.positions(positionId1);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKey.toId()));
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token0));
        assertEq(fee, 0);
        assertEq(binId, ACTIVE_BIN_ID);

        (poolId, currency0, currency1, fee, binId) = binPm.positions(positionId2);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKey.toId()));
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token0));
        assertEq(fee, 0);
        assertEq(binId, ACTIVE_BIN_ID + 1);

        vm.expectRevert(IPositionManager.InvalidTokenID.selector);
        (poolId, currency0, currency1, fee, binId) = binPm.positions(positionId3);
    }

    function testMigrateFromV2Refund() public {
        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2Pair, 10 ether, 10 ether);
        uint256 lpTokenBefore = v2Pair.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. make sure migrator can transfer user's v2 lp token
        permit2ApproveWithSpecificAllowance(
            address(this), permit2, address(v2Pair), address(migrator), lpTokenBefore, uint160(lpTokenBefore)
        );

        // 3. initialize the pool
        migrator.initializePool(poolKey, ACTIVE_BIN_ID, bytes(""));

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2Pair),
            migrateAmount: lpTokenBefore,
            // the order of token0 and token1 respect to the pair
            // but may mismatch the order of v4 pool key when WETH is invovled
            amount0Min: 9.99 ether,
            amount1Min: 9.99 ether
        });

        IBinPositionManager.BinAddLiquidityParams memory params =
            _getAddParams(poolKey, getBinIds(ACTIVE_BIN_ID, 3), 10 ether, 10 ether, ACTIVE_BIN_ID, address(this));

        int256[] memory deltaIds = new int256[](2);
        deltaIds[0] = params.deltaIds[0];
        deltaIds[1] = params.deltaIds[1];

        uint256[] memory distributionX = new uint256[](2);
        distributionX[0] = params.distributionX[0];
        distributionX[1] = params.distributionX[1];

        uint256[] memory distributionY = new uint256[](2);
        distributionY[0] = params.distributionY[0];
        distributionY[1] = params.distributionY[1];

        // delete the last distribution point so that the refund is triggered
        // we expect to get 50% of tokenX back
        // (0, 50%) (50%, 50%) (50%, 0) => (0, 50%) (50%, 50%)
        IBinMigrator.V4BinPoolParams memory v4BinPoolParams = IBinMigrator.V4BinPoolParams({
            poolKey: params.poolKey,
            amount0Min: params.amount0Min,
            amount1Min: params.amount1Min,
            activeIdDesired: params.activeIdDesired,
            idSlippage: params.idSlippage,
            deltaIds: deltaIds,
            distributionX: distributionX,
            distributionY: distributionY,
            to: params.to,
            deadline: block.timestamp + 1
        });

        uint256 balance0Before = address(this).balance;
        uint256 balance1Before = token0.balanceOf(address(this));

        // 4. migrate from v2 to v4, not sending ETH denotes pay by WETH
        migrator.migrateFromV2(v2PoolParams, v4BinPoolParams, 0, 0);

        // necessary checks
        // refund 5 ether in the form of native token
        assertApproxEqAbs(address(this).balance - balance0Before, 5 ether, 0.000001 ether);
        assertEq(balance1Before - token0.balanceOf(address(this)), 0 ether);
        // WETH balance unchanged
        assertEq(weth.balanceOf(address(this)), 90 ether);

        // v2 pair should be burned already
        assertEq(v2Pair.balanceOf(address(this)), 0);

        // make sure liuqidty is minted to the correct pool
        assertApproxEqAbs(address(vault).balance, 5 ether, 0.000001 ether);
        assertApproxEqAbs(token0.balanceOf(address(vault)), 10 ether, 0.000001 ether);

        uint256 positionId0 = poolKey.toId().toTokenId(ACTIVE_BIN_ID - 1);
        uint256 positionId1 = poolKey.toId().toTokenId(ACTIVE_BIN_ID);
        uint256 positionId2 = poolKey.toId().toTokenId(ACTIVE_BIN_ID + 1);
        uint256 positionId3 = poolKey.toId().toTokenId(ACTIVE_BIN_ID + 2);
        assertGt(binPm.balanceOf(address(this), positionId0), 0);
        assertGt(binPm.balanceOf(address(this), positionId1), 0);
        assertEq(binPm.balanceOf(address(this), positionId2), 0);
        assertEq(binPm.balanceOf(address(this), positionId3), 0);

        (PoolId poolId, Currency currency0, Currency currency1, uint24 fee, uint24 binId) = binPm.positions(positionId0);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKey.toId()));
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token0));
        assertEq(fee, 0);
        assertEq(binId, ACTIVE_BIN_ID - 1);

        (poolId, currency0, currency1, fee, binId) = binPm.positions(positionId1);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKey.toId()));
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token0));
        assertEq(fee, 0);
        assertEq(binId, ACTIVE_BIN_ID);

        vm.expectRevert(IPositionManager.InvalidTokenID.selector);
        (poolId, currency0, currency1, fee, binId) = binPm.positions(positionId2);

        vm.expectRevert(IPositionManager.InvalidTokenID.selector);
        (poolId, currency0, currency1, fee, binId) = binPm.positions(positionId3);
    }

    function testMigrateFromV2RefundNonNativeToken() public {
        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2PairWithoutNativeToken, 10 ether, 10 ether);
        uint256 lpTokenBefore = v2PairWithoutNativeToken.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. make sure migrator can transfer user's v2 lp token
        permit2ApproveWithSpecificAllowance(
            address(this),
            permit2,
            address(v2PairWithoutNativeToken),
            address(migrator),
            lpTokenBefore,
            uint160(lpTokenBefore)
        );

        // 3. initialize the pool
        migrator.initializePool(poolKeyWithoutNativeToken, ACTIVE_BIN_ID, bytes(""));

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2PairWithoutNativeToken),
            migrateAmount: lpTokenBefore,
            // the order of token0 and token1 respect to the pair
            // but may mismatch the order of v4 pool key when WETH is invovled
            amount0Min: 9.999 ether,
            amount1Min: 9.999 ether
        });

        IBinPositionManager.BinAddLiquidityParams memory params = _getAddParams(
            poolKeyWithoutNativeToken, getBinIds(ACTIVE_BIN_ID, 3), 10 ether, 10 ether, ACTIVE_BIN_ID, address(this)
        );

        int256[] memory deltaIds = new int256[](2);
        deltaIds[0] = params.deltaIds[0];
        deltaIds[1] = params.deltaIds[1];

        uint256[] memory distributionX = new uint256[](2);
        distributionX[0] = params.distributionX[0];
        distributionX[1] = params.distributionX[1];

        uint256[] memory distributionY = new uint256[](2);
        distributionY[0] = params.distributionY[0];
        distributionY[1] = params.distributionY[1];

        // delete the last distribution point so that the refund is triggered
        // we expect to get 50% of tokenX back
        // (0, 50%) (50%, 50%) (50%, 0) => (0, 50%) (50%, 50%)
        IBinMigrator.V4BinPoolParams memory v4BinPoolParams = IBinMigrator.V4BinPoolParams({
            poolKey: params.poolKey,
            amount0Min: params.amount0Min,
            amount1Min: params.amount1Min,
            activeIdDesired: params.activeIdDesired,
            idSlippage: params.idSlippage,
            deltaIds: deltaIds,
            distributionX: distributionX,
            distributionY: distributionY,
            to: params.to,
            deadline: block.timestamp + 1
        });

        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        // 4. migrate from v2 to v4
        migrator.migrateFromV2(v2PoolParams, v4BinPoolParams, 0, 0);

        // necessary checks

        // refund 5 ether of token0
        assertApproxEqAbs(token0.balanceOf(address(this)) - balance0Before, 5 ether, 0.000001 ether);
        assertEq(balance1Before - token1.balanceOf(address(this)), 0 ether);
        // WETH balance unchanged
        assertEq(weth.balanceOf(address(this)), 100 ether);

        // v2 pair should be burned already
        assertEq(v2PairWithoutNativeToken.balanceOf(address(this)), 0);

        // make sure liuqidty is minted to the correct pool
        assertApproxEqAbs(token0.balanceOf(address(vault)), 5 ether, 0.000001 ether);
        assertApproxEqAbs(token1.balanceOf(address(vault)), 10 ether, 0.000001 ether);

        uint256 positionId0 = poolKeyWithoutNativeToken.toId().toTokenId(ACTIVE_BIN_ID - 1);
        uint256 positionId1 = poolKeyWithoutNativeToken.toId().toTokenId(ACTIVE_BIN_ID);
        uint256 positionId2 = poolKeyWithoutNativeToken.toId().toTokenId(ACTIVE_BIN_ID + 1);
        uint256 positionId3 = poolKeyWithoutNativeToken.toId().toTokenId(ACTIVE_BIN_ID + 2);
        assertGt(binPm.balanceOf(address(this), positionId0), 0);
        assertGt(binPm.balanceOf(address(this), positionId1), 0);
        assertEq(binPm.balanceOf(address(this), positionId2), 0);
        assertEq(binPm.balanceOf(address(this), positionId3), 0);

        (PoolId poolId, Currency currency0, Currency currency1, uint24 fee, uint24 binId) = binPm.positions(positionId0);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKeyWithoutNativeToken.toId()));
        assertEq(Currency.unwrap(currency0), address(token0));
        assertEq(Currency.unwrap(currency1), address(token1));
        assertEq(fee, 0);
        assertEq(binId, ACTIVE_BIN_ID - 1);

        (poolId, currency0, currency1, fee, binId) = binPm.positions(positionId1);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKeyWithoutNativeToken.toId()));
        assertEq(Currency.unwrap(currency0), address(token0));
        assertEq(Currency.unwrap(currency1), address(token1));
        assertEq(fee, 0);
        assertEq(binId, ACTIVE_BIN_ID);

        vm.expectRevert(IPositionManager.InvalidTokenID.selector);
        (poolId, currency0, currency1, fee, binId) = binPm.positions(positionId2);

        vm.expectRevert(IPositionManager.InvalidTokenID.selector);
        (poolId, currency0, currency1, fee, binId) = binPm.positions(positionId3);
    }

    function testMigrateFromV2ThroughOffchainSign() public {
        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2Pair);
        uint256 lpTokenBefore = v2Pair.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. make sure migrator can transfer user's v2 lp token

        (address userAddr, uint256 userPrivateKey) = makeAddrAndKey("user");

        // 2.a transfer the lp token to the user
        v2Pair.transfer(userAddr, lpTokenBefore);

        uint256 ddl = block.timestamp + 100;
        // 2.b prepare the hash
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                userAddr,
                address(permit2),
                lpTokenBefore,
                v2Pair.nonces(address(permit2)),
                ddl
            )
        );
        bytes32 hash = keccak256(abi.encodePacked("\x19\x01", v2Pair.DOMAIN_SEPARATOR(), structHash));

        // 2.c generate the signature
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, hash);

        IAllowanceTransfer.PermitSingle memory permit =
            defaultERC20PermitAllowance(address(v2Pair), uint160(lpTokenBefore), type(uint48).max, 0);
        permit.spender = address(migrator);
        bytes memory sig = getPermitSignature(permit, userPrivateKey, PERMIT2_DOMAIN_SEPARATOR);

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2Pair),
            migrateAmount: lpTokenBefore,
            // minor precision loss is acceptable
            amount0Min: 9.999 ether,
            amount1Min: 9.999 ether
        });

        IBinPositionManager.BinAddLiquidityParams memory params =
            _getAddParams(poolKey, getBinIds(ACTIVE_BIN_ID, 3), 10 ether, 10 ether, ACTIVE_BIN_ID, address(this));

        IBinMigrator.V4BinPoolParams memory v4BinPoolParams = IBinMigrator.V4BinPoolParams({
            poolKey: params.poolKey,
            amount0Min: params.amount0Min,
            amount1Min: params.amount1Min,
            activeIdDesired: params.activeIdDesired,
            idSlippage: params.idSlippage,
            deltaIds: params.deltaIds,
            distributionX: params.distributionX,
            distributionY: params.distributionY,
            to: params.to,
            deadline: block.timestamp + 1
        });

        // 3. multicall, combine permit2.permit, initialize and migrateFromV2
        bytes[] memory data = new bytes[](3);
        data[0] = abi.encodeWithSelector(migrator.initializePool.selector, poolKey, ACTIVE_BIN_ID, bytes(""));
        data[1] = abi.encodeWithSelector(Permit2Forwarder.permit.selector, userAddr, permit, sig);
        data[2] = abi.encodeWithSelector(migrator.migrateFromV2.selector, v2PoolParams, v4BinPoolParams, 0, 0);
        vm.startPrank(userAddr);
        v2Pair.permit(userAddr, address(permit2), lpTokenBefore, ddl, v, r, s);
        migrator.multicall(data);
        vm.stopPrank();

        // necessary checks
        // v2 pair should be burned already
        assertEq(v2Pair.balanceOf(address(this)), 0);

        // make sure liuqidty is minted to the correct pool
        assertApproxEqAbs(address(vault).balance, 10 ether, 0.000001 ether);
        assertApproxEqAbs(token0.balanceOf(address(vault)), 10 ether, 0.000001 ether);

        uint256 positionId0 = poolKey.toId().toTokenId(ACTIVE_BIN_ID - 1);
        uint256 positionId1 = poolKey.toId().toTokenId(ACTIVE_BIN_ID);
        uint256 positionId2 = poolKey.toId().toTokenId(ACTIVE_BIN_ID + 1);
        uint256 positionId3 = poolKey.toId().toTokenId(ACTIVE_BIN_ID + 2);
        assertGt(binPm.balanceOf(address(this), positionId0), 0);
        assertGt(binPm.balanceOf(address(this), positionId1), 0);
        assertGt(binPm.balanceOf(address(this), positionId2), 0);
        assertEq(binPm.balanceOf(address(this), positionId3), 0);

        (PoolId poolId, Currency currency0, Currency currency1, uint24 fee, uint24 binId) = binPm.positions(positionId0);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKey.toId()));
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token0));
        assertEq(fee, 0);
        assertEq(binId, ACTIVE_BIN_ID - 1);

        (poolId, currency0, currency1, fee, binId) = binPm.positions(positionId1);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKey.toId()));
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token0));
        assertEq(fee, 0);
        assertEq(binId, ACTIVE_BIN_ID);

        (poolId, currency0, currency1, fee, binId) = binPm.positions(positionId2);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKey.toId()));
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token0));
        assertEq(fee, 0);
        assertEq(binId, ACTIVE_BIN_ID + 1);

        vm.expectRevert(IPositionManager.InvalidTokenID.selector);
        (poolId, currency0, currency1, fee, binId) = binPm.positions(positionId3);
    }

    function _mintV2Liquidity(IPancakePair pair) public {
        IERC20(pair.token0()).transfer(address(pair), 10 ether);
        IERC20(pair.token1()).transfer(address(pair), 10 ether);

        pair.mint(address(this));
    }

    function _mintV2Liquidity(IPancakePair pair, uint256 amount0, uint256 amount1) public {
        IERC20(pair.token0()).transfer(address(pair), amount0);
        IERC20(pair.token1()).transfer(address(pair), amount1);

        pair.mint(address(this));
    }

    receive() external payable {}
}
