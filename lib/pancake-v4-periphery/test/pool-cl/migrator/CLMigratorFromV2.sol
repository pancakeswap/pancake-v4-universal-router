// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {OldVersionHelper} from "../../helpers/OldVersionHelper.sol";
import {IPancakePair} from "../../../src/interfaces/external/IPancakePair.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CLMigrator} from "../../../src/pool-cl/CLMigrator.sol";
import {ICLMigrator, IBaseMigrator} from "../../../src/pool-cl/interfaces/ICLMigrator.sol";
import {CLPositionManager} from "../../../src/pool-cl/CLPositionManager.sol";
import {Vault} from "pancake-v4-core/src/Vault.sol";
import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {IPoolManager} from "pancake-v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {PositionConfig} from "../../../src/pool-cl/libraries/PositionConfig.sol";
import {MockReentrantPositionManager} from "../../mocks/MockReentrantPositionManager.sol";
import {ReentrancyLock} from "../../../src/base/ReentrancyLock.sol";
import {Permit2ApproveHelper} from "../../helpers/Permit2ApproveHelper.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Permit2SignatureHelpers} from "../../shared/Permit2SignatureHelpers.sol";
import {Permit2Forwarder} from "../../../src/base/Permit2Forwarder.sol";

interface IPancakeV2LikePairFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

abstract contract CLMigratorFromV2 is
    OldVersionHelper,
    PosmTestSetup,
    Permit2ApproveHelper,
    Permit2SignatureHelpers,
    GasSnapshot
{
    using CLPoolParametersHelper for bytes32;
    using PoolIdLibrary for PoolKey;

    WETH weth;
    MockERC20 token0;
    MockERC20 token1;

    Vault vault;
    CLPoolManager poolManager;
    ICLMigrator migrator;
    PoolKey poolKey;
    PoolKey poolKeyWithoutNativeToken;

    IPancakeV2LikePairFactory v2Factory;
    IPancakePair v2Pair;
    IPancakePair v2PairWithoutNativeToken;
    PositionConfig positionConfig;
    bytes32 PERMIT2_DOMAIN_SEPARATOR;

    function _getBytecodePath() internal pure virtual returns (string memory);

    function _getContractName() internal pure virtual returns (string memory);

    function setUp() public {
        weth = new WETH();
        token0 = new MockERC20("Token0", "TKN0", 18);
        token1 = new MockERC20("Token1", "TKN1", 18);
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);
        (vault, poolManager) = createFreshManager();
        deployPosm(vault, poolManager);
        migrator = new CLMigrator(address(weth), address(lpm), permit2);

        PERMIT2_DOMAIN_SEPARATOR = permit2.DOMAIN_SEPARATOR();

        poolKey = PoolKey({
            // WETH after migration will be native token
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token0)),
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: 0,
            parameters: bytes32(0).setTickSpacing(10)
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

        positionConfig = PositionConfig({poolKey: poolKey, tickLower: -100, tickUpper: 100});
    }

    function testCLMigrateFromV2ReentrancyLockRevert() public {
        MockReentrantPositionManager reentrantPM = new MockReentrantPositionManager(permit2);
        reentrantPM.setCLPoolMnager(poolManager);
        migrator = new CLMigrator(address(weth), address(reentrantPM), permit2);
        reentrantPM.setCLMigrator(migrator);
        reentrantPM.setRenentrantType(MockReentrantPositionManager.ReentrantType.CLMigrateFromV2);

        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2Pair);
        uint256 lpTokenBefore = v2Pair.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. make sure migrator can transfer user's v2 lp token

        permit2ApproveWithSpecificAllowance(
            address(this), permit2, address(v2Pair), address(migrator), lpTokenBefore, uint160(lpTokenBefore)
        );

        // 3. initialize the pool
        uint160 initSqrtPrice = 79228162514264337593543950336;
        poolManager.initialize(poolKey, initSqrtPrice, bytes(""));

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2Pair),
            migrateAmount: lpTokenBefore,
            // minor precision loss is acceptable
            amount0Min: 9.999 ether,
            amount1Min: 9.999 ether
        });

        ICLMigrator.V4CLPoolParams memory v4MintParams = ICLMigrator.V4CLPoolParams({
            poolKey: poolKey,
            tickLower: -100,
            tickUpper: 100,
            liquidityMin: 0,
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        vm.expectRevert(ReentrancyLock.ContractLocked.selector);
        migrator.migrateFromV2(v2PoolParams, v4MintParams, 0, 0);
    }

    function testCLMigrateFromV2IncludingInit() public {
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

        ICLMigrator.V4CLPoolParams memory v4MintParams = ICLMigrator.V4CLPoolParams({
            poolKey: poolKey,
            tickLower: -100,
            tickUpper: 100,
            liquidityMin: 0,
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        // 3. multicall, combine initialize and migrateFromV2
        uint160 initSqrtPrice = 79228162514264337593543950336;
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(migrator.initializePool.selector, poolKey, initSqrtPrice, bytes(""));
        data[1] = abi.encodeWithSelector(migrator.migrateFromV2.selector, v2PoolParams, v4MintParams, 0, 0);
        snapStart(string(abi.encodePacked(_getContractName(), "#testCLMigrateFromV2IncludingInit")));
        migrator.multicall(data);
        snapEnd();

        // necessary checks
        // v2 pair should be burned already
        assertEq(v2Pair.balanceOf(address(this)), 0);

        // make sure liuqidty is minted to the correct pool
        assertEq(lpm.ownerOf(1), address(this));

        uint128 liquidity = lpm.getPositionLiquidity(1, positionConfig);

        assertEq(liquidity, 2005104164790027832367);
    }

    function testCLMigrateFromV2TokenMismatch() public {
        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2Pair);
        uint256 lpTokenBefore = v2Pair.balanceOf(address(this));

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

        // v2 weth, token0
        // v4 ETH, token1
        PoolKey memory poolKeyMismatch = poolKey;
        poolKeyMismatch.currency1 = Currency.wrap(address(token1));
        ICLMigrator.V4CLPoolParams memory v4MintParams = ICLMigrator.V4CLPoolParams({
            poolKey: poolKeyMismatch,
            tickLower: -100,
            tickUpper: 100,
            liquidityMin: 0,
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        // 3. multicall, combine initialize and migrateFromV2
        uint160 initSqrtPrice = 79228162514264337593543950336;
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(migrator.initializePool.selector, poolKeyMismatch, initSqrtPrice, bytes(""));
        data[1] = abi.encodeWithSelector(migrator.migrateFromV2.selector, v2PoolParams, v4MintParams, 0, 0);
        vm.expectRevert();
        migrator.multicall(data);

        {
            // v2 weth, token0
            // v4 token0, token1
            poolKeyMismatch.currency0 = Currency.wrap(address(token0));
            poolKeyMismatch.currency1 = Currency.wrap(address(token1));
            v4MintParams.poolKey = poolKeyMismatch;
            data = new bytes[](2);
            data[0] =
                abi.encodeWithSelector(migrator.initializePool.selector, poolKeyMismatch, initSqrtPrice, bytes(""));
            data[1] = abi.encodeWithSelector(migrator.migrateFromV2.selector, v2PoolParams, v4MintParams, 0, 0);
            vm.expectRevert();
            migrator.multicall(data);
        }
    }

    function testCLMigrateFromV2InsufficientLiquidity() public {
        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2Pair);
        uint256 lpTokenBefore = v2Pair.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. make sure migrator can transfer user's v2 lp token

        permit2ApproveWithSpecificAllowance(
            address(this), permit2, address(v2Pair), address(migrator), lpTokenBefore, uint160(lpTokenBefore)
        );

        // 3. initialize the pool
        uint160 initSqrtPrice = 79228162514264337593543950336;
        migrator.initializePool(poolKey, initSqrtPrice, bytes(""));

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2Pair),
            migrateAmount: lpTokenBefore,
            // minor precision loss is acceptable
            amount0Min: 9.999 ether,
            amount1Min: 9.999 ether
        });

        ICLMigrator.V4CLPoolParams memory v4MintParams = ICLMigrator.V4CLPoolParams({
            poolKey: poolKey,
            tickLower: -100,
            tickUpper: 100,
            liquidityMin: 2005104164790027832368, // minted liquidity + 1
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        vm.expectRevert(ICLMigrator.INSUFFICIENT_LIQUIDITY.selector);
        migrator.migrateFromV2(v2PoolParams, v4MintParams, 0, 0);
    }

    function testCLMigrateFromV2WithoutInit() public {
        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2Pair);
        uint256 lpTokenBefore = v2Pair.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. make sure migrator can transfer user's v2 lp token

        permit2ApproveWithSpecificAllowance(
            address(this), permit2, address(v2Pair), address(migrator), lpTokenBefore, uint160(lpTokenBefore)
        );

        // 3. initialize the pool
        uint160 initSqrtPrice = 79228162514264337593543950336;
        migrator.initializePool(poolKey, initSqrtPrice, bytes(""));

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2Pair),
            migrateAmount: lpTokenBefore,
            // minor precision loss is acceptable
            amount0Min: 9.999 ether,
            amount1Min: 9.999 ether
        });

        ICLMigrator.V4CLPoolParams memory v4MintParams = ICLMigrator.V4CLPoolParams({
            poolKey: poolKey,
            tickLower: -100,
            tickUpper: 100,
            liquidityMin: 0,
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        // 4. migrate from v2 to v4
        snapStart(string(abi.encodePacked(_getContractName(), "#testCLMigrateFromV2WithoutInit")));
        migrator.migrateFromV2(v2PoolParams, v4MintParams, 0, 0);
        snapEnd();

        // necessary checks
        // v2 pair should be burned already
        assertEq(v2Pair.balanceOf(address(this)), 0);

        // make sure liuqidty is minted to the correct pool
        assertEq(lpm.ownerOf(1), address(this));
        uint128 liquidity = lpm.getPositionLiquidity(1, positionConfig);

        assertEq(liquidity, 2005104164790027832367);
        assertApproxEqAbs(address(vault).balance, 10 ether, 0.000001 ether);
        assertApproxEqAbs(token0.balanceOf(address(vault)), 10 ether, 0.000001 ether);
    }

    function testCLMigrateFromV2WithoutNativeToken() public {
        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2PairWithoutNativeToken);
        uint256 lpTokenBefore = v2PairWithoutNativeToken.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. make sure migrator can transfer user's v2 lp token
        v2PairWithoutNativeToken.approve(address(migrator), lpTokenBefore);
        permit2ApproveWithSpecificAllowance(
            address(this),
            permit2,
            address(v2PairWithoutNativeToken),
            address(migrator),
            lpTokenBefore,
            uint160(lpTokenBefore)
        );

        // 3. initialize the pool
        uint160 initSqrtPrice = 79228162514264337593543950336;
        migrator.initializePool(poolKeyWithoutNativeToken, initSqrtPrice, bytes(""));

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2PairWithoutNativeToken),
            migrateAmount: lpTokenBefore,
            // minor precision loss is acceptable
            amount0Min: 9.999 ether,
            amount1Min: 9.999 ether
        });

        ICLMigrator.V4CLPoolParams memory v4MintParams = ICLMigrator.V4CLPoolParams({
            poolKey: poolKeyWithoutNativeToken,
            tickLower: -100,
            tickUpper: 100,
            liquidityMin: 0,
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        // 4. migrate from v2 to v4
        snapStart(string(abi.encodePacked(_getContractName(), "#testCLMigrateFromV2WithoutNativeToken")));
        migrator.migrateFromV2(v2PoolParams, v4MintParams, 0, 0);
        snapEnd();

        // necessary checks
        // v2 pair should be burned already
        assertEq(v2PairWithoutNativeToken.balanceOf(address(this)), 0);

        // make sure liuqidty is minted to the correct pool
        assertEq(lpm.ownerOf(1), address(this));
        positionConfig.poolKey = poolKeyWithoutNativeToken;
        uint128 liquidity = lpm.getPositionLiquidity(1, positionConfig);

        assertEq(liquidity, 2005104164790027832367);

        assertApproxEqAbs(token0.balanceOf(address(vault)), 10 ether, 0.000001 ether);
        assertApproxEqAbs(token1.balanceOf(address(vault)), 10 ether, 0.000001 ether);
    }

    function testCLMigrateFromV2AddExtraAmount() public {
        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2Pair);
        uint256 lpTokenBefore = v2Pair.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. make sure migrator can transfer user's v2 lp token

        permit2ApproveWithSpecificAllowance(
            address(this), permit2, address(v2Pair), address(migrator), lpTokenBefore, uint160(lpTokenBefore)
        );

        // 3. initialize the pool
        uint160 initSqrtPrice = 79228162514264337593543950336;
        migrator.initializePool(poolKey, initSqrtPrice, bytes(""));

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2Pair),
            migrateAmount: lpTokenBefore,
            // minor precision loss is acceptable
            amount0Min: 9.999 ether,
            amount1Min: 9.999 ether
        });

        ICLMigrator.V4CLPoolParams memory v4MintParams = ICLMigrator.V4CLPoolParams({
            poolKey: poolKey,
            tickLower: -100,
            tickUpper: 100,
            liquidityMin: 0,
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        uint256 balance0Before = address(this).balance;
        uint256 balance1Before = token0.balanceOf(address(this));

        permit2ApproveWithSpecificAllowance(
            address(this), permit2, address(token0), address(migrator), 20 ether, 20 ether
        );
        // 4. migrate from v2 to v4
        migrator.migrateFromV2{value: 20 ether}(v2PoolParams, v4MintParams, 20 ether, uint160(20 ether));

        // necessary checks
        // consumed extra 20 ether from user
        assertApproxEqAbs(balance0Before - address(this).balance, 20 ether, 0.000001 ether);
        assertEq(balance1Before - token0.balanceOf(address(this)), 20 ether);
        // WETH balance unchanged
        assertEq(weth.balanceOf(address(this)), 90 ether);

        // v2 pair should be burned already
        assertEq(v2Pair.balanceOf(address(this)), 0);

        // make sure liuqidty is minted to the correct pool
        assertEq(lpm.ownerOf(1), address(this));
        uint128 liquidity = lpm.getPositionLiquidity(1, positionConfig);

        // liquidity is 3 times of the original
        assertApproxEqAbs(liquidity, 2005104164790027832367 * 3, 0.000001 ether);

        assertApproxEqAbs(address(vault).balance, 30 ether, 0.000001 ether);
        assertApproxEqAbs(token0.balanceOf(address(vault)), 30 ether, 0.000001 ether);
    }

    function testCLMigrateFromV2AddExtraAmountThroughWETH() public {
        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2Pair);
        uint256 lpTokenBefore = v2Pair.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. make sure migrator can transfer user's v2 lp token

        permit2ApproveWithSpecificAllowance(
            address(this), permit2, address(v2Pair), address(migrator), lpTokenBefore, uint160(lpTokenBefore)
        );

        // 3. initialize the pool
        uint160 initSqrtPrice = 79228162514264337593543950336;
        migrator.initializePool(poolKey, initSqrtPrice, bytes(""));

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2Pair),
            migrateAmount: lpTokenBefore,
            // minor precision loss is acceptable
            amount0Min: 9.999 ether,
            amount1Min: 9.999 ether
        });

        ICLMigrator.V4CLPoolParams memory v4MintParams = ICLMigrator.V4CLPoolParams({
            poolKey: poolKey,
            tickLower: -100,
            tickUpper: 100,
            liquidityMin: 0,
            recipient: address(this),
            deadline: block.timestamp + 100
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
        migrator.migrateFromV2(v2PoolParams, v4MintParams, 20 ether, 20 ether);

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
        assertEq(lpm.ownerOf(1), address(this));
        uint128 liquidity = lpm.getPositionLiquidity(1, positionConfig);

        // liquidity is 3 times of the original
        assertApproxEqAbs(liquidity, 2005104164790027832367 * 3, 0.000001 ether);

        assertApproxEqAbs(address(vault).balance, 30 ether, 0.000001 ether);
        assertApproxEqAbs(token0.balanceOf(address(vault)), 30 ether, 0.000001 ether);
    }

    function testFuzz_CLMigrateFromV2AddExtraAmountThroughWETH(uint256 extraAmount) public {
        extraAmount = bound(extraAmount, 1 ether, 60 ether);

        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2Pair);
        uint256 lpTokenBefore = v2Pair.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. make sure migrator can transfer user's v2 lp token

        permit2ApproveWithSpecificAllowance(
            address(this), permit2, address(v2Pair), address(migrator), lpTokenBefore, uint160(lpTokenBefore)
        );

        // 3. initialize the pool
        uint160 initSqrtPrice = 79228162514264337593543950336;
        migrator.initializePool(poolKey, initSqrtPrice, bytes(""));

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2Pair),
            migrateAmount: lpTokenBefore,
            // minor precision loss is acceptable
            amount0Min: 9.999 ether,
            amount1Min: 9.999 ether
        });

        ICLMigrator.V4CLPoolParams memory v4MintParams = ICLMigrator.V4CLPoolParams({
            poolKey: poolKey,
            tickLower: -100,
            tickUpper: 100,
            liquidityMin: 0,
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        uint256 balance0Before = address(this).balance;
        uint256 balance1Before = token0.balanceOf(address(this));

        permit2ApproveWithSpecificAllowance(
            address(this), permit2, address(weth), address(migrator), extraAmount, uint160(extraAmount)
        );
        permit2ApproveWithSpecificAllowance(
            address(this), permit2, address(token0), address(migrator), extraAmount, uint160(extraAmount)
        );
        // 4. migrate from v2 to v4, not sending ETH denotes pay by WETH
        migrator.migrateFromV2(v2PoolParams, v4MintParams, extraAmount, extraAmount);

        // clPositionManager native balance should be 0
        uint256 lPositionManagerNativeBalance = address(lpm).balance;
        assertEq(lPositionManagerNativeBalance, 0);

        // necessary checks
        // consumed extra extraAmount from user
        // native token balance unchanged
        assertApproxEqAbs(balance0Before - address(this).balance, 0 ether, 0.000001 ether);
        assertEq(balance1Before - token0.balanceOf(address(this)), extraAmount);
        // consumed extraAmount WETH
        assertEq(weth.balanceOf(address(this)), 90 ether - extraAmount);

        // v2 pair should be burned already
        assertEq(v2Pair.balanceOf(address(this)), 0);

        // make sure liuqidty is minted to the correct pool
        assertEq(lpm.ownerOf(1), address(this));
        uint128 liquidity = lpm.getPositionLiquidity(1, positionConfig);

        // liquidity is 3 times of the original
        assertApproxEqAbs(liquidity, 2005104164790027832367 * (10 ether + extraAmount) / 10 ether, 0.000001 ether);

        assertApproxEqAbs(address(vault).balance, 10 ether + extraAmount, 0.000001 ether);
        assertApproxEqAbs(token0.balanceOf(address(vault)), 10 ether + extraAmount, 0.000001 ether);
    }

    function testCLMigrateFromV2Refund() public {
        // 1. mint some liquidity to the v2 pair
        // 10 ether WETH, 5 ether token0
        // addr of weth > addr of token0, hence the order has to be reversed
        bool isWETHFirst = address(weth) < address(token0);
        if (isWETHFirst) {
            _mintV2Liquidity(v2Pair, 10 ether, 5 ether);
        } else {
            _mintV2Liquidity(v2Pair, 5 ether, 10 ether);
        }
        uint256 lpTokenBefore = v2Pair.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. make sure migrator can transfer user's v2 lp token

        permit2ApproveWithSpecificAllowance(
            address(this), permit2, address(v2Pair), address(migrator), lpTokenBefore, uint160(lpTokenBefore)
        );

        // 3. initialize the pool
        uint160 initSqrtPrice = 79228162514264337593543950336;
        migrator.initializePool(poolKey, initSqrtPrice, bytes(""));

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2Pair),
            migrateAmount: lpTokenBefore,
            // the order of token0 and token1 respect to the pair
            // but may mismatch the order of v4 pool key when WETH is invovled
            amount0Min: isWETHFirst ? 9.999 ether : 4.999 ether,
            amount1Min: isWETHFirst ? 4.999 ether : 9.999 ether
        });

        ICLMigrator.V4CLPoolParams memory v4MintParams = ICLMigrator.V4CLPoolParams({
            poolKey: poolKey,
            tickLower: -100,
            tickUpper: 100,
            liquidityMin: 0,
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        uint256 balance0Before = address(this).balance;
        uint256 balance1Before = token0.balanceOf(address(this));

        // 4. migrate from v2 to v4, not sending ETH denotes pay by WETH
        migrator.migrateFromV2(v2PoolParams, v4MintParams, 0, 0);

        // necessary checks
        // refund 5 ether in the form of native token
        assertApproxEqAbs(address(this).balance - balance0Before, 5 ether, 0.000001 ether);
        assertEq(balance1Before - token0.balanceOf(address(this)), 0 ether);
        // WETH balance unchanged
        assertEq(weth.balanceOf(address(this)), 90 ether);

        // v2 pair should be burned already
        assertEq(v2Pair.balanceOf(address(this)), 0);

        // make sure liuqidty is minted to the correct pool
        assertEq(lpm.ownerOf(1), address(this));
        uint128 liquidity = lpm.getPositionLiquidity(1, positionConfig);

        // liquidity is half of the original
        assertApproxEqAbs(liquidity * 2, 2005104164790027832367, 0.000001 ether);

        assertApproxEqAbs(address(vault).balance, 5 ether, 0.000001 ether);
        assertApproxEqAbs(token0.balanceOf(address(vault)), 5 ether, 0.000001 ether);
    }

    function testCLMigrateFromV2RefundNonNativeToken() public {
        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2PairWithoutNativeToken, 10 ether, 5 ether);
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
        uint160 initSqrtPrice = 79228162514264337593543950336;
        migrator.initializePool(poolKeyWithoutNativeToken, initSqrtPrice, bytes(""));

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2PairWithoutNativeToken),
            migrateAmount: lpTokenBefore,
            // the order of token0 and token1 respect to the pair
            // but may mismatch the order of v4 pool key when WETH is invovled
            amount0Min: 9.999 ether,
            amount1Min: 4.999 ether
        });

        ICLMigrator.V4CLPoolParams memory v4MintParams = ICLMigrator.V4CLPoolParams({
            poolKey: poolKeyWithoutNativeToken,
            tickLower: -100,
            tickUpper: 100,
            liquidityMin: 0,
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        // 4. migrate from v2 to v4
        migrator.migrateFromV2(v2PoolParams, v4MintParams, 0, 0);

        // necessary checks

        // refund 5 ether of token0
        assertApproxEqAbs(token0.balanceOf(address(this)) - balance0Before, 5 ether, 0.000001 ether);
        assertEq(balance1Before - token1.balanceOf(address(this)), 0 ether);
        // WETH balance unchanged
        assertEq(weth.balanceOf(address(this)), 100 ether);

        // v2 pair should be burned already
        assertEq(v2PairWithoutNativeToken.balanceOf(address(this)), 0);

        // make sure liuqidty is minted to the correct pool
        assertEq(lpm.ownerOf(1), address(this));
        positionConfig.poolKey = poolKeyWithoutNativeToken;
        uint128 liquidity = lpm.getPositionLiquidity(1, positionConfig);

        // liquidity is half of the original
        assertApproxEqAbs(liquidity * 2, 2005104164790027832367, 0.000001 ether);

        assertApproxEqAbs(token0.balanceOf(address(vault)), 5 ether, 0.000001 ether);
        assertApproxEqAbs(token1.balanceOf(address(vault)), 5 ether, 0.000001 ether);
    }

    function testCLMigrateFromV2ThroughOffchainSign() public {
        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2Pair);
        uint256 lpTokenBefore = v2Pair.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. instead of approve, we generate a offchain signature here

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
                v2Pair.nonces(userAddr),
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

        ICLMigrator.V4CLPoolParams memory v4MintParams = ICLMigrator.V4CLPoolParams({
            poolKey: poolKey,
            tickLower: -100,
            tickUpper: 100,
            liquidityMin: 0,
            recipient: address(this),
            deadline: ddl
        });

        // 3. multicall, combine permit2.permit, initialize and migrateFromV2
        uint160 initSqrtPrice = 79228162514264337593543950336;
        bytes[] memory data = new bytes[](3);
        data[0] = abi.encodeWithSelector(migrator.initializePool.selector, poolKey, initSqrtPrice, bytes(""));
        data[1] = abi.encodeWithSelector(Permit2Forwarder.permit.selector, userAddr, permit, sig);
        data[2] = abi.encodeWithSelector(migrator.migrateFromV2.selector, v2PoolParams, v4MintParams, 0, 0);
        vm.startPrank(userAddr);
        v2Pair.permit(userAddr, address(permit2), lpTokenBefore, ddl, v, r, s);
        migrator.multicall(data);
        vm.stopPrank();

        // necessary checks
        // v2 pair should be burned already
        assertEq(v2Pair.balanceOf(address(this)), 0);

        // make sure liuqidty is minted to the correct pool
        assertEq(lpm.ownerOf(1), address(this));
        uint128 liquidity = lpm.getPositionLiquidity(1, positionConfig);

        assertEq(liquidity, 2005104164790027832367);

        assertApproxEqAbs(address(vault).balance, 10 ether, 0.000001 ether);
        assertApproxEqAbs(token0.balanceOf(address(vault)), 10 ether, 0.000001 ether);
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
