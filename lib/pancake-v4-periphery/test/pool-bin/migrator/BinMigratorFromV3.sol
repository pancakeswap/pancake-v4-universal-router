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
import {IV3NonfungiblePositionManager} from "../../../src/interfaces/external/IV3NonfungiblePositionManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PackedUint128Math} from "pancake-v4-core/src/pool-bin/libraries/math/PackedUint128Math.sol";
import {MockReentrantPositionManager} from "../../mocks/MockReentrantPositionManager.sol";
import {ReentrancyLock} from "../../../src/base/ReentrancyLock.sol";
import {Permit2ApproveHelper} from "../../helpers/Permit2ApproveHelper.sol";
import {IPositionManager} from "../../../src/interfaces/IPositionManager.sol";

interface IPancakeV3LikePairFactory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

abstract contract BinMigratorFromV3 is
    OldVersionHelper,
    BinLiquidityHelper,
    DeployPermit2,
    Permit2ApproveHelper,
    GasSnapshot
{
    using BinPoolParametersHelper for bytes32;
    using PackedUint128Math for bytes32;
    using PoolIdLibrary for PoolKey;
    using BinTokenLibrary for PoolId;

    uint160 public constant INIT_SQRT_PRICE = 79228162514264337593543950336;
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

    IPancakeV3LikePairFactory v3Factory;
    IV3NonfungiblePositionManager v3Nfpm;

    function _getDeployerBytecodePath() internal pure virtual returns (string memory);
    function _getFactoryBytecodePath() internal pure virtual returns (string memory);
    function _getNfpmBytecodePath() internal pure virtual returns (string memory);

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

        // pcs v3
        if (bytes(_getDeployerBytecodePath()).length != 0) {
            address deployer = createContractThroughBytecode(_getDeployerBytecodePath());
            v3Factory = IPancakeV3LikePairFactory(
                createContractThroughBytecode(_getFactoryBytecodePath(), toBytes32(address(deployer)))
            );
            (bool success,) = deployer.call(abi.encodeWithSignature("setFactoryAddress(address)", address(v3Factory)));
            require(success, "setFactoryAddress failed");
            v3Nfpm = IV3NonfungiblePositionManager(
                createContractThroughBytecode(
                    _getNfpmBytecodePath(),
                    toBytes32(deployer),
                    toBytes32(address(v3Factory)),
                    toBytes32(address(weth)),
                    0
                )
            );
        } else {
            v3Factory = IPancakeV3LikePairFactory(createContractThroughBytecode(_getFactoryBytecodePath()));

            v3Nfpm = IV3NonfungiblePositionManager(
                createContractThroughBytecode(
                    _getNfpmBytecodePath(), toBytes32(address(v3Factory)), toBytes32(address(weth)), 0
                )
            );
        }

        // make sure v3Nfpm has allowance
        weth.approve(address(v3Nfpm), type(uint256).max);
        token0.approve(address(v3Nfpm), type(uint256).max);
        token1.approve(address(v3Nfpm), type(uint256).max);
    }

    function testMigrateFromV3ReentrancyLockRevert() public {
        MockReentrantPositionManager reentrantPM = new MockReentrantPositionManager(permit2);
        migrator = new BinMigrator(address(weth), address(reentrantPM), permit2);
        reentrantPM.setBinMigrator(migrator);

        // 1. mint some liquidity to the v3 pool
        _mintV3Liquidity(address(weth), address(token0));
        assertEq(v3Nfpm.ownerOf(1), address(this));
        (,,,,,,, uint128 liquidityFromV3Before,,,,) = v3Nfpm.positions(1);
        assertGt(liquidityFromV3Before, 0);

        // 2. make sure migrator can transfer user's v3 lp token
        v3Nfpm.approve(address(migrator), 1);

        // 3. initialize the pool
        poolManager.initialize(poolKey, ACTIVE_BIN_ID, bytes(""));

        IBaseMigrator.V3PoolParams memory v3PoolParams = IBaseMigrator.V3PoolParams({
            nfp: address(v3Nfpm),
            tokenId: 1,
            liquidity: liquidityFromV3Before,
            amount0Min: 9.9 ether,
            amount1Min: 9.9 ether,
            collectFee: false,
            deadline: block.timestamp + 100
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
        migrator.migrateFromV3(v3PoolParams, v4BinPoolParams, 0, 0);
    }

    function testMigrateFromV3IncludingInit() public {
        // 1. mint some liquidity to the v3 pool
        _mintV3Liquidity(address(weth), address(token0));
        assertEq(v3Nfpm.ownerOf(1), address(this));
        (,,,,,,, uint128 liquidityFromV3Before,,,,) = v3Nfpm.positions(1);
        assertGt(liquidityFromV3Before, 0);

        // 2. make sure migrator can transfer user's v3 lp token
        v3Nfpm.approve(address(migrator), 1);

        IBaseMigrator.V3PoolParams memory v3PoolParams = IBaseMigrator.V3PoolParams({
            nfp: address(v3Nfpm),
            tokenId: 1,
            liquidity: liquidityFromV3Before,
            amount0Min: 9.9 ether,
            amount1Min: 9.9 ether,
            collectFee: false,
            deadline: block.timestamp + 100
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

        // 3. multicall, combine initialize and migrateFromV3
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(migrator.initializePool.selector, poolKey, ACTIVE_BIN_ID, bytes(""));
        data[1] = abi.encodeWithSelector(migrator.migrateFromV3.selector, v3PoolParams, v4BinPoolParams, 0, 0);
        snapStart(string(abi.encodePacked(_getContractName(), "#testMigrateFromV3IncludingInit")));
        migrator.multicall(data);
        snapEnd();

        // necessary checks
        // v3 liqudity should be 0
        (,,,,,,, uint128 liquidityFromV3After,,,,) = v3Nfpm.positions(1);
        assertEq(liquidityFromV3After, 0);

        // make sure liuqidty is minted to the correct pooA
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

    function testMigrateFromV3TokenMismatch() public {
        // 1. mint some liquidity to the v3 pool
        _mintV3Liquidity(address(weth), address(token0));
        assertEq(v3Nfpm.ownerOf(1), address(this));
        (,,,,,,, uint128 liquidityFromV3Before,,,,) = v3Nfpm.positions(1);
        assertGt(liquidityFromV3Before, 0);

        // 2. make sure migrator can transfer user's v3 lp token
        v3Nfpm.approve(address(migrator), 1);

        IBaseMigrator.V3PoolParams memory v3PoolParams = IBaseMigrator.V3PoolParams({
            nfp: address(v3Nfpm),
            tokenId: 1,
            liquidity: liquidityFromV3Before,
            amount0Min: 9.9 ether,
            amount1Min: 9.9 ether,
            collectFee: false,
            deadline: block.timestamp + 100
        });

        IBinPositionManager.BinAddLiquidityParams memory params =
            _getAddParams(poolKey, getBinIds(ACTIVE_BIN_ID, 3), 10 ether, 10 ether, ACTIVE_BIN_ID, address(this));

        // v3 weth, token0
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

        // 3. multicall, combine initialize and migrateFromV3
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(migrator.initializePool.selector, poolKeyMismatch, ACTIVE_BIN_ID, bytes(""));
        data[1] = abi.encodeWithSelector(migrator.migrateFromV3.selector, v3PoolParams, v4BinPoolParams, 0, 0);
        vm.expectRevert();
        migrator.multicall(data);

        {
            // v3 weth, token0
            // v4 token0, token1
            poolKeyMismatch.currency0 = Currency.wrap(address(token0));
            poolKeyMismatch.currency1 = Currency.wrap(address(token1));
            v4BinPoolParams.poolKey = poolKeyMismatch;
            data = new bytes[](2);
            data[0] =
                abi.encodeWithSelector(migrator.initializePool.selector, poolKeyMismatch, ACTIVE_BIN_ID, bytes(""));
            data[1] = abi.encodeWithSelector(migrator.migrateFromV3.selector, v3PoolParams, v4BinPoolParams, 0, 0);
            vm.expectRevert();
            migrator.multicall(data);
        }
    }

    function testMigrateFromV3WithoutInit() public {
        // 1. mint some liquidity to the v3 pool
        _mintV3Liquidity(address(weth), address(token0));
        assertEq(v3Nfpm.ownerOf(1), address(this));
        (,,,,,,, uint128 liquidityFromV3Before,,,,) = v3Nfpm.positions(1);
        assertGt(liquidityFromV3Before, 0);

        // 2. make sure migrator can transfer user's v3 lp token
        v3Nfpm.approve(address(migrator), 1);

        // 3. initialize the pool
        migrator.initializePool(poolKey, ACTIVE_BIN_ID, bytes(""));

        IBaseMigrator.V3PoolParams memory v3PoolParams = IBaseMigrator.V3PoolParams({
            nfp: address(v3Nfpm),
            tokenId: 1,
            liquidity: liquidityFromV3Before,
            amount0Min: 9.9 ether,
            amount1Min: 9.9 ether,
            collectFee: false,
            deadline: block.timestamp + 100
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

        // 4. migrateFromV3 directly given pool has been initialized
        snapStart(string(abi.encodePacked(_getContractName(), "#testMigrateFromV3WithoutInit")));
        migrator.migrateFromV3(v3PoolParams, v4BinPoolParams, 0, 0);
        snapEnd();

        // necessary checks
        // v3 liqudity should be 0
        (,,,,,,, uint128 liquidityFromV3After,,,,) = v3Nfpm.positions(1);
        assertEq(liquidityFromV3After, 0);

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

    function testMigrateFromV3WithoutNativeToken() public {
        // 1. mint some liquidity to the v3 pool
        _mintV3Liquidity(address(token0), address(token1));

        assertEq(v3Nfpm.ownerOf(1), address(this));
        (,,,,,,, uint128 liquidityFromV3Before,,,,) = v3Nfpm.positions(1);
        assertGt(liquidityFromV3Before, 0);

        // 2. make sure migrator can transfer user's v3 lp token
        v3Nfpm.approve(address(migrator), 1);

        // 3. initialize the pool
        migrator.initializePool(poolKeyWithoutNativeToken, ACTIVE_BIN_ID, bytes(""));

        IBaseMigrator.V3PoolParams memory v3PoolParams = IBaseMigrator.V3PoolParams({
            nfp: address(v3Nfpm),
            tokenId: 1,
            liquidity: liquidityFromV3Before,
            amount0Min: 9.9 ether,
            amount1Min: 9.9 ether,
            collectFee: false,
            deadline: block.timestamp + 100
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

        // 4. migrate from v3 to v4
        snapStart(string(abi.encodePacked(_getContractName(), "#testMigrateFromV3WithoutNativeToken")));
        migrator.migrateFromV3(v3PoolParams, v4BinPoolParams, 0, 0);
        snapEnd();

        // necessary checks
        // v3 liqudity should be 0
        (,,,,,,, uint128 liquidityFromV3After,,,,) = v3Nfpm.positions(1);
        assertEq(liquidityFromV3After, 0);

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

    function testMigrateFromV3AddExtraAmount() public {
        // 1. mint some liquidity to the v3 pool
        _mintV3Liquidity(address(weth), address(token0));
        assertEq(v3Nfpm.ownerOf(1), address(this));
        (,,,,,,, uint128 liquidityFromV3Before,,,,) = v3Nfpm.positions(1);
        assertGt(liquidityFromV3Before, 0);

        // 2. make sure migrator can transfer user's v3 lp token
        v3Nfpm.approve(address(migrator), 1);

        // 3. init the pool
        migrator.initializePool(poolKey, ACTIVE_BIN_ID, bytes(""));

        IBaseMigrator.V3PoolParams memory v3PoolParams = IBaseMigrator.V3PoolParams({
            nfp: address(v3Nfpm),
            tokenId: 1,
            liquidity: liquidityFromV3Before,
            amount0Min: 9.9 ether,
            amount1Min: 9.9 ether,
            collectFee: false,
            deadline: block.timestamp + 100
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
        // 4. migrate from v3 to v4
        migrator.migrateFromV3{value: 20 ether}(v3PoolParams, v4BinPoolParams, 20 ether, 20 ether);

        // necessary checks
        // consumed extra 20 ether from user
        assertApproxEqAbs(balance0Before - address(this).balance, 20 ether, 0.000001 ether);
        assertApproxEqAbs(balance1Before - token0.balanceOf(address(this)), 20 ether, 0.000001 ether);
        // WETH balance unchanged
        assertEq(weth.balanceOf(address(this)), 90 ether);

        // v3 liqudity should be 0
        (,,,,,,, uint128 liquidityFromV3After,,,,) = v3Nfpm.positions(1);
        assertEq(liquidityFromV3After, 0);

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

    function testMigrateFromV3WhenPMHaveNativeBalance() public {
        // 1. mint some liquidity to the v3 pool
        _mintV3Liquidity(address(weth), address(token0));
        assertEq(v3Nfpm.ownerOf(1), address(this));
        (,,,,,,, uint128 liquidityFromV3Before,,,,) = v3Nfpm.positions(1);
        assertGt(liquidityFromV3Before, 0);

        // 2. make sure migrator can transfer user's v3 lp token
        v3Nfpm.approve(address(migrator), 1);

        // 3. init the pool
        migrator.initializePool(poolKey, ACTIVE_BIN_ID, bytes(""));

        IBaseMigrator.V3PoolParams memory v3PoolParams = IBaseMigrator.V3PoolParams({
            nfp: address(v3Nfpm),
            tokenId: 1,
            liquidity: liquidityFromV3Before,
            amount0Min: 9.9 ether,
            amount1Min: 9.9 ether,
            collectFee: false,
            deadline: block.timestamp + 100
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

        uint256 nativeBlanceBefore = address(this).balance;

        permit2ApproveWithSpecificAllowance(
            address(this), permit2, address(token0), address(migrator), 20 ether, 20 ether
        );
        // deposit native token to the PM
        vm.deal(address(binPm), 100 ether);

        // user can collect native token by removing liquidity
        uint256 v3PositionNativeAmount = 9999999999999999999;
        // mint bin position data
        bytes32[] memory mintAmounts = new bytes32[](3);
        mintAmounts[0] = 0x0000000000000000d02ab486cedbffff00000000000000000000000000000000;
        mintAmounts[1] = 0x0000000000000000d02ab486cedbffff0000000000000000d02ab486cedbffff;
        mintAmounts[2] = 0x000000000000000000000000000000000000000000000000d02ab486cedbffff;
        uint256[] memory ids = new uint256[](3);
        ids[0] = 8388607;
        ids[1] = 8388608;
        ids[2] = 8388609;
        // check v3 position collect
        vm.expectEmit(true, true, true, true);
        emit IV3NonfungiblePositionManager.Collect(1, address(migrator), v3PositionNativeAmount, 9999999999999999999);
        // check bin pool mint event
        vm.expectEmit(false, false, false, true);
        emit IBinPoolManager.Mint(
            PoolId.wrap(0x0000000000000000000000000000000000000000000000000000000000000000),
            address(0),
            ids,
            0x0000000000000000000000000000000000000000000000000000000000000000,
            mintAmounts,
            0x0000000000000000000000000000000000000000000000000000000000000000,
            0x0000000000000000000000000000000000000000000000000000000000000000
        );
        // 4. migrate from v3 to v4
        migrator.migrateFromV3{value: 20 ether}(v3PoolParams, v4BinPoolParams, 20 ether, 20 ether);

        uint256 nativeBlanceAfter = address(this).balance;
        // user did not consume any native token, and also get the v3 liquidity native token as refund
        assertEq(nativeBlanceAfter - nativeBlanceBefore, v3PositionNativeAmount);

        migrator.refundETH();

        // calculate the mint consuemd native token
        uint128 totalConsumedNative = mintAmounts[0].decodeX() + mintAmounts[1].decodeX() + mintAmounts[2].decodeX();
        uint256 nativeBlanceAfterRefund = address(this).balance;
        assertTrue(nativeBlanceAfterRefund > nativeBlanceBefore);
        assertEq(
            nativeBlanceAfterRefund - nativeBlanceBefore,
            100 ether + v3PositionNativeAmount - uint256(totalConsumedNative)
        );
    }

    function testMigrateFromV3AddExtraAmountThroughWETH() public {
        // 1. mint some liquidity to the v3 pool
        _mintV3Liquidity(address(weth), address(token0));
        assertEq(v3Nfpm.ownerOf(1), address(this));
        (,,,,,,, uint128 liquidityFromV3Before,,,,) = v3Nfpm.positions(1);
        assertGt(liquidityFromV3Before, 0);

        // 2. make sure migrator can transfer user's v3 lp token
        v3Nfpm.approve(address(migrator), 1);

        // 3. init the pool
        migrator.initializePool(poolKey, ACTIVE_BIN_ID, bytes(""));

        IBaseMigrator.V3PoolParams memory v3PoolParams = IBaseMigrator.V3PoolParams({
            nfp: address(v3Nfpm),
            tokenId: 1,
            liquidity: liquidityFromV3Before,
            amount0Min: 9.9 ether,
            amount1Min: 9.9 ether,
            collectFee: false,
            deadline: block.timestamp + 100
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
        // 4. migrate from v3 to v4, not sending ETH denotes pay by WETH
        migrator.migrateFromV3(v3PoolParams, v4BinPoolParams, 20 ether, 20 ether);

        // necessary checks
        // consumed extra 20 ether from user
        // native token balance unchanged
        assertApproxEqAbs(address(this).balance - balance0Before, 0 ether, 0.000001 ether);
        assertApproxEqAbs(balance1Before - token0.balanceOf(address(this)), 20 ether, 0.00001 ether);
        // consumed 20 ether WETH
        assertEq(weth.balanceOf(address(this)), 70 ether);

        // v3 liqudity should be 0
        (,,,,,,, uint128 liquidityFromV3After,,,,) = v3Nfpm.positions(1);
        assertEq(liquidityFromV3After, 0);

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

    function testMigrateFromV3Refund() public {
        // 1. mint some liquidity to the v3 pool
        _mintV3Liquidity(address(weth), address(token0));
        assertEq(v3Nfpm.ownerOf(1), address(this));
        (,,,,,,, uint128 liquidityFromV3Before,,,,) = v3Nfpm.positions(1);
        assertGt(liquidityFromV3Before, 0);

        // 2. make sure migrator can transfer user's v3 lp token
        v3Nfpm.approve(address(migrator), 1);

        // 3. init the pool
        migrator.initializePool(poolKey, ACTIVE_BIN_ID, bytes(""));

        IBaseMigrator.V3PoolParams memory v3PoolParams = IBaseMigrator.V3PoolParams({
            nfp: address(v3Nfpm),
            tokenId: 1,
            liquidity: liquidityFromV3Before,
            amount0Min: 0,
            amount1Min: 0,
            collectFee: false,
            deadline: block.timestamp + 100
        });

        // adding half of the liquidity to the pool
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

        // 4. migrate from v3 to v4, not sending ETH denotes pay by WETH
        migrator.migrateFromV3(v3PoolParams, v4BinPoolParams, 0, 0);

        // necessary checks
        // refund 5 ether in the form of native token
        assertApproxEqAbs(address(this).balance - balance0Before, 5.0 ether, 0.1 ether);
        assertApproxEqAbs(token0.balanceOf(address(this)) - balance1Before, 0 ether, 1);
        // WETH balance unchanged
        assertApproxEqAbs(weth.balanceOf(address(this)), 90 ether, 0.1 ether);

        // v3 liqudity should be 0
        (,,,,,,, uint128 liquidityFromV3After,,,,) = v3Nfpm.positions(1);
        assertEq(liquidityFromV3After, 0);

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

    function testMigrateFromV3RefundNonNativeToken() public {
        // 1. mint some liquidity to the v3 pool
        _mintV3Liquidity(address(token0), address(token1));
        assertEq(v3Nfpm.ownerOf(1), address(this));
        (,,,,,,, uint128 liquidityFromV3Before,,,,) = v3Nfpm.positions(1);
        assertGt(liquidityFromV3Before, 0);

        // 2. make sure migrator can transfer user's v3 lp token
        v3Nfpm.approve(address(migrator), 1);

        // 3. init the pool
        migrator.initializePool(poolKeyWithoutNativeToken, ACTIVE_BIN_ID, bytes(""));

        IBaseMigrator.V3PoolParams memory v3PoolParams = IBaseMigrator.V3PoolParams({
            nfp: address(v3Nfpm),
            tokenId: 1,
            liquidity: liquidityFromV3Before,
            amount0Min: 0,
            amount1Min: 0,
            collectFee: false,
            deadline: block.timestamp + 100
        });

        // adding half of the liquidity to the pool
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

        // 4. migrate from v3 to v4
        migrator.migrateFromV3(v3PoolParams, v4BinPoolParams, 0, 0);

        // necessary checks

        // refund 5 ether of token0
        assertApproxEqAbs(token0.balanceOf(address(this)) - balance0Before, 5 ether, 0.1 ether);
        assertApproxEqAbs(token1.balanceOf(address(this)) - balance1Before, 0 ether, 1);
        // WETH balance unchanged
        assertEq(weth.balanceOf(address(this)), 100 ether);

        // v3 liqudity should be 0
        (,,,,,,, uint128 liquidityFromV3After,,,,) = v3Nfpm.positions(1);
        assertEq(liquidityFromV3After, 0);

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

    function testMigrateFromV3FromNonOwner() public {
        // 1. mint some liquidity to the v3 pool
        _mintV3Liquidity(address(weth), address(token0));
        assertEq(v3Nfpm.ownerOf(1), address(this));
        (,,,,,,, uint128 liquidityFromV3Before,,,,) = v3Nfpm.positions(1);
        assertGt(liquidityFromV3Before, 0);

        // 2. make sure migrator can transfer user's v3 lp token
        v3Nfpm.approve(address(migrator), 1);

        // 3. init the pool
        migrator.initializePool(poolKey, ACTIVE_BIN_ID, bytes(""));

        IBaseMigrator.V3PoolParams memory v3PoolParams = IBaseMigrator.V3PoolParams({
            nfp: address(v3Nfpm),
            tokenId: 1,
            // half of the liquidity
            liquidity: liquidityFromV3Before / 2,
            amount0Min: 9.9 ether / 2,
            amount1Min: 9.9 ether / 2,
            collectFee: false,
            deadline: block.timestamp + 100
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

        // 4. migrate half
        migrator.migrateFromV3(v3PoolParams, v4BinPoolParams, 0, 0);

        // make sure there are still liquidity left in v3 position token
        (,,,,,,, uint128 liquidityFromV3After,,,,) = v3Nfpm.positions(1);
        assertEq(liquidityFromV3After, liquidityFromV3Before - liquidityFromV3Before / 2);

        // 5. make sure non-owner can't migrate the rest
        vm.expectRevert(IBaseMigrator.NOT_TOKEN_OWNER.selector);
        vm.prank(makeAddr("someone"));
        migrator.migrateFromV3(v3PoolParams, v4BinPoolParams, 0, 0);
    }

    function testMigrateFromV3ThroughOffchainSign() public {
        // 1. mint some liquidity to the v3 pool
        _mintV3Liquidity(address(weth), address(token0));
        assertEq(v3Nfpm.ownerOf(1), address(this));
        (uint96 nonce,,,,,,, uint128 liquidityFromV3Before,,,,) = v3Nfpm.positions(1);
        assertGt(liquidityFromV3Before, 0);

        // 2. make sure migrator can transfer user's v3 lp token through offchain sign
        // v3Nfpm.approve(address(migrator), 1);
        (address userAddr, uint256 userPrivateKey) = makeAddrAndKey("user");

        // 2.a transfer the lp token to the user
        v3Nfpm.transferFrom(address(this), userAddr, 1);

        uint256 ddl = block.timestamp + 100;
        // 2.b prepare the hash
        bytes32 structHash = keccak256(abi.encode(v3Nfpm.PERMIT_TYPEHASH(), address(migrator), 1, nonce, ddl));
        bytes32 hash = keccak256(abi.encodePacked("\x19\x01", v3Nfpm.DOMAIN_SEPARATOR(), structHash));

        // 2.c generate the signature
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, hash);

        IBaseMigrator.V3PoolParams memory v3PoolParams = IBaseMigrator.V3PoolParams({
            nfp: address(v3Nfpm),
            tokenId: 1,
            liquidity: liquidityFromV3Before,
            amount0Min: 9.9 ether,
            amount1Min: 9.9 ether,
            collectFee: false,
            deadline: block.timestamp + 100
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

        // 3. multicall, combine selfPermitERC721, initialize and migrateFromV3
        bytes[] memory data = new bytes[](3);
        data[0] = abi.encodeWithSelector(migrator.selfPermitERC721.selector, v3Nfpm, 1, ddl, v, r, s);
        data[1] = abi.encodeWithSelector(migrator.initializePool.selector, poolKey, ACTIVE_BIN_ID, bytes(""));
        data[2] = abi.encodeWithSelector(migrator.migrateFromV3.selector, v3PoolParams, v4BinPoolParams, 0, 0);
        vm.prank(userAddr);
        migrator.multicall(data);

        // necessary checks
        // v3 liqudity should be 0
        (,,,,,,, uint128 liquidityFromV3After,,,,) = v3Nfpm.positions(1);
        assertEq(liquidityFromV3After, 0);

        // make sure liuqidty is minted to the correct pooA
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

    function testMigrateFromV3ThroughOffchainSignPayWithETH() public {
        // 1. mint some liquidity to the v3 pool
        _mintV3Liquidity(address(weth), address(token0));
        assertEq(v3Nfpm.ownerOf(1), address(this));
        (uint96 nonce,,,,,,, uint128 liquidityFromV3Before,,,,) = v3Nfpm.positions(1);
        assertGt(liquidityFromV3Before, 0);

        // 2. make sure migrator can transfer user's v3 lp token through offchain sign
        // v3Nfpm.approve(address(migrator), 1);
        (address userAddr, uint256 userPrivateKey) = makeAddrAndKey("user");

        // 2.a transfer the lp token to the user
        v3Nfpm.transferFrom(address(this), userAddr, 1);

        uint256 ddl = block.timestamp + 100;
        // 2.b prepare the hash
        bytes32 structHash = keccak256(abi.encode(v3Nfpm.PERMIT_TYPEHASH(), address(migrator), 1, nonce, ddl));
        bytes32 hash = keccak256(abi.encodePacked("\x19\x01", v3Nfpm.DOMAIN_SEPARATOR(), structHash));

        // 2.c generate the signature
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, hash);

        IBaseMigrator.V3PoolParams memory v3PoolParams = IBaseMigrator.V3PoolParams({
            nfp: address(v3Nfpm),
            tokenId: 1,
            liquidity: liquidityFromV3Before,
            amount0Min: 9.9 ether,
            amount1Min: 9.9 ether,
            collectFee: false,
            deadline: block.timestamp + 100
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

        // make the guy rich
        token0.transfer(userAddr, 10 ether);
        deal(userAddr, 10 ether);

        permit2ApproveWithSpecificAllowance(
            userAddr, permit2, address(token0), address(migrator), 10 ether, uint160(10 ether)
        );

        // 3. multicall, combine selfPermitERC721, initialize and migrateFromV3
        bytes[] memory data = new bytes[](3);
        data[0] = abi.encodeWithSelector(migrator.selfPermitERC721.selector, v3Nfpm, 1, ddl, v, r, s);
        data[1] = abi.encodeWithSelector(migrator.initializePool.selector, poolKey, ACTIVE_BIN_ID, bytes(""));
        data[2] =
            abi.encodeWithSelector(migrator.migrateFromV3.selector, v3PoolParams, v4BinPoolParams, 10 ether, 10 ether);
        vm.prank(userAddr);
        migrator.multicall{value: 10 ether}(data);

        // necessary checks
        // v3 liqudity should be 0
        (,,,,,,, uint128 liquidityFromV3After,,,,) = v3Nfpm.positions(1);
        assertEq(liquidityFromV3After, 0);

        // make sure liuqidty is minted to the correct pooA
        assertApproxEqAbs(address(vault).balance, 20 ether, 0.000001 ether);
        assertApproxEqAbs(token0.balanceOf(address(vault)), 20 ether, 0.000001 ether);

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

    function _mintV3Liquidity(address _token0, address _token1) internal {
        (_token0, _token1) = _token0 < _token1 ? (_token0, _token1) : (_token1, _token0);
        v3Nfpm.createAndInitializePoolIfNecessary(_token0, _token1, 500, INIT_SQRT_PRICE);
        IV3NonfungiblePositionManager.MintParams memory mintParams = IV3NonfungiblePositionManager.MintParams({
            token0: _token0,
            token1: _token1,
            fee: 500,
            tickLower: -100,
            tickUpper: 100,
            amount0Desired: 10 ether,
            amount1Desired: 10 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        v3Nfpm.mint(mintParams);
    }

    receive() external payable {}
}
