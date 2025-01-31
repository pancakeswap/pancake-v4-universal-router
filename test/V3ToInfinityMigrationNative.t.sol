// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import {Test, console} from "forge-std/Test.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IWETH9} from "infinity-periphery/src/interfaces/external/IWETH9.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {BinPoolManager} from "infinity-core/src/pool-bin/BinPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {FixedPoint96} from "infinity-core/src/pool-cl/libraries/FixedPoint96.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {BinPoolParametersHelper} from "infinity-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {ActionConstants} from "infinity-periphery/src/libraries/ActionConstants.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";
import {CLPositionManager} from "infinity-periphery/src/pool-cl/CLPositionManager.sol";
import {CLPositionDescriptorOffChain} from "infinity-periphery/src/pool-cl/CLPositionDescriptorOffChain.sol";
import {BinPositionManager} from "infinity-periphery/src/pool-bin/BinPositionManager.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {IV3NonfungiblePositionManager} from
    "infinity-periphery/src/interfaces/external/IV3NonfungiblePositionManager.sol";
import {IERC721Permit} from "infinity-periphery/src/interfaces/IERC721Permit.sol";
import {IPositionManager} from "infinity-periphery/src/interfaces/IPositionManager.sol";
import {IBinPositionManager} from "infinity-periphery/src/pool-bin/interfaces/IBinPositionManager.sol";
import {OldVersionHelper} from "infinity-periphery/test/helpers/OldVersionHelper.sol";
import {BinLiquidityHelper} from "infinity-periphery/test/pool-bin/helper/BinLiquidityHelper.sol";
import {Constants} from "../src/libraries/Constants.sol";

import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {Commands} from "../src/libraries/Commands.sol";
import {RouterParameters} from "../src/base/RouterImmutables.sol";
import {Dispatcher} from "../src/base/Dispatcher.sol";
import {UniversalRouter} from "../src/UniversalRouter.sol";
import {BasePancakeSwapInfinity} from "./infinity/BasePancakeSwapInfinity.sol";

interface IPancakeV3LikePairFactory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

/// @dev Test simplified, assume weth-token pair is already broken and token reside in universal router
contract V3ToInfinityMigrationNativeTest is BasePancakeSwapInfinity, OldVersionHelper, BinLiquidityHelper {
    using BinPoolParametersHelper for bytes32;
    using CLPoolParametersHelper for bytes32;
    using Planner for Plan;

    MockERC20 token0;
    MockERC20 token1;
    WETH weth = new WETH();
    address alice;
    uint256 alicePK;

    // infinity related
    IVault vault;
    IBinPoolManager binPoolManager;
    BinPositionManager binPositionManager;
    ICLPoolManager clPoolManager;
    CLPositionManager clPositionManager;
    IAllowanceTransfer permit2;
    UniversalRouter router;
    PoolKey clPoolKey;
    PoolKey binPoolKey;

    uint24 constant ACTIVE_ID_1_1 = 2 ** 23; // where token0 and token1 price is the same
    uint160 constant SQRT_PRICE_1_1 = uint160(1 * FixedPoint96.Q96); // price 1

    function setUp() public {
        (alice, alicePK) = makeAddrAndKey("ALICE");

        initializeTokens();
        vm.label(Currency.unwrap(currency1), "token1");
        token1 = MockERC20(Currency.unwrap(currency1));

        permit2 = IAllowanceTransfer(deployPermit2());

        ///////////////////////////////////
        ///////// infinity setup //////////
        ///////////////////////////////////
        vault = IVault(new Vault());
        binPoolManager = new BinPoolManager(vault);
        clPoolManager = new CLPoolManager(vault);
        vault.registerApp(address(binPoolManager));
        vault.registerApp(address(clPoolManager));

        binPositionManager = new BinPositionManager(vault, binPoolManager, permit2, IWETH9(address(weth)));
        _approvePermit2ForCurrency(address(this), currency1, address(binPositionManager), permit2);

        CLPositionDescriptorOffChain pd =
            new CLPositionDescriptorOffChain("https://pancakeswap.finance/infinity/pool-cl/positions/");
        clPositionManager = new CLPositionManager(vault, clPoolManager, permit2, 100_000, pd, IWETH9(address(weth)));
        _approvePermit2ForCurrency(address(this), currency1, address(clPositionManager), permit2);

        clPoolKey = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: clPoolManager,
            fee: uint24(3000),
            parameters: bytes32(0).setTickSpacing(10)
        });
        clPoolManager.initialize(clPoolKey, SQRT_PRICE_1_1);

        binPoolKey = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: binPoolManager,
            fee: uint24(3000),
            parameters: bytes32(0).setBinStep(10)
        });
        binPoolManager.initialize(binPoolKey, ACTIVE_ID_1_1);

        ///////////////////////////////////
        //////////// Router setup /////////////
        ///////////////////////////////////
        RouterParameters memory params = RouterParameters({
            permit2: address(permit2),
            weth9: address(weth),
            v2Factory: address(0),
            v3Factory: address(0),
            v3Deployer: address(0),
            v2InitCodeHash: bytes32(0),
            v3InitCodeHash: bytes32(0),
            stableFactory: address(0),
            stableInfo: address(0),
            infiVault: address(vault),
            infiClPoolManager: address(clPoolManager),
            infiBinPoolManager: address(binPoolManager),
            v3NFTPositionManager: address(0),
            infiClPositionManager: address(clPositionManager),
            infiBinPositionManager: address(binPositionManager)
        });
        router = new UniversalRouter(params);
        _approvePermit2ForCurrency(alice, currency1, address(router), permit2);
    }

    /// @dev Assume weth/token1 is aready in universal router from v3 removal liquidity
    ///         then add liquidity to infinity cl and sweep remaining token
    function test_infiCLPositionmanager_Mint_Native() public {
        // assume weth/token1 is in universal router
        vm.deal(address(this), 10 ether);
        weth.deposit{value: 10 ether}();
        weth.transfer(address(router), 10 ether);
        token1.mint(address(router), 10 ether);

        // prep position manager action: mint/ settle/ settle
        Plan memory planner = Planner.init();
        planner.add(Actions.CL_MINT_POSITION, abi.encode(clPoolKey, -120, 120, 1 ether, 10 ether, 10 ether, alice, ""));
        planner.add(Actions.SETTLE, abi.encode(clPoolKey.currency0, ActionConstants.OPEN_DELTA, false)); // deduct from universal router
        planner.add(Actions.SETTLE, abi.encode(clPoolKey.currency1, ActionConstants.OPEN_DELTA, false)); // deduct from universal router
        planner.add(Actions.SWEEP, abi.encode(clPoolKey.currency0, alice));
        planner.add(Actions.SWEEP, abi.encode(clPoolKey.currency1, alice));

        // prep universal router actions
        bytes memory commands = abi.encodePacked(
            bytes1(uint8(Commands.UNWRAP_WETH)),
            bytes1(uint8(Commands.SWEEP)),
            bytes1(uint8(Commands.INFI_CL_POSITION_CALL))
        );
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = abi.encode(address(router), 10 ether); // get native eth to router
        inputs[1] = abi.encode(token1, address(clPositionManager), 0); // send token1 to clPositionmanager
        inputs[2] =
            abi.encodePacked(IPositionManager.modifyLiquidities.selector, abi.encode(planner.encode(), block.timestamp));

        vm.prank(alice);
        router.execute(commands, inputs);
        vm.snapshotGasLastCall("test_infiCLPositionmanager_Mint_Native");

        // verify remaining balance sent back to alice
        assertEq(alice.balance, 9994018262239490337);
        assertEq(token1.balanceOf(address(alice)), 9994018262239490337);
        assertEq(clPositionManager.ownerOf(1), alice);
    }

    /// @dev Assume weth/token1 is aready in universal router from v3 removal liquidity
    ///      then add liquidity to infinity cl and sweep remaining token
    function test_infiBinPositionmanager_BinAddLiquidity_Native() public {
        // assume weth/token1 is in universal router
        vm.deal(address(this), 10 ether);
        weth.deposit{value: 10 ether}();
        weth.transfer(address(router), 10 ether);
        token1.mint(address(router), 10 ether);

        // prep position manager action: mint/ settle/ settle
        uint24[] memory binIds = getBinIds(ACTIVE_ID_1_1, 1);
        IBinPositionManager.BinAddLiquidityParams memory addParams =
            _getAddParams(binPoolKey, binIds, 5 ether, 5 ether, ACTIVE_ID_1_1, address(this));

        Plan memory planner = Planner.init();
        planner.add(Actions.BIN_ADD_LIQUIDITY, abi.encode(addParams));
        planner.add(Actions.SETTLE, abi.encode(binPoolKey.currency0, ActionConstants.OPEN_DELTA, false)); // deduct from universal router
        planner.add(Actions.SETTLE, abi.encode(binPoolKey.currency1, ActionConstants.OPEN_DELTA, false)); // deduct from universal router
        planner.add(Actions.SWEEP, abi.encode(binPoolKey.currency0, alice));
        planner.add(Actions.SWEEP, abi.encode(binPoolKey.currency1, alice));

        // prep universal router actions
        bytes memory commands = abi.encodePacked(
            bytes1(uint8(Commands.UNWRAP_WETH)),
            bytes1(uint8(Commands.SWEEP)),
            bytes1(uint8(Commands.INFI_BIN_POSITION_CALL))
        );
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = abi.encode(address(router), 10 ether); // get native eth to universal router
        inputs[1] = abi.encode(token1, address(binPositionManager), 0); // send token1 to binPositionManager
        inputs[2] =
            abi.encodePacked(IPositionManager.modifyLiquidities.selector, abi.encode(planner.encode(), block.timestamp));

        vm.prank(alice);
        router.execute(commands, inputs);
        vm.snapshotGasLastCall("test_infiBinPositionmanager_BinAddLiquidity_Native");

        // verify remaining balance sent back to alice
        assertEq(alice.balance, 5 ether);
        assertEq(token1.balanceOf(address(alice)), 5 ether);
    }
}
