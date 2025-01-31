// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import {Test, console} from "forge-std/Test.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IWETH9} from "infinity-periphery/src/interfaces/external/IWETH9.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
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

import {IPancakeV3PoolDeployer} from "../src/modules/pancakeswap/v3/interfaces/IPancakeV3PoolDeployer.sol";
import {IPancakeV3Factory} from "../src/modules/pancakeswap/v3/interfaces/IPancakeV3Factory.sol";
import {V3ToInfinityMigrator} from "../src/modules/V3ToInfinityMigrator.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {Commands} from "../src/libraries/Commands.sol";
import {RouterParameters} from "../src/base/RouterImmutables.sol";
import {Dispatcher} from "../src/base/Dispatcher.sol";
import {UniversalRouter} from "../src/UniversalRouter.sol";
import {BasePancakeSwapInfinity} from "./infinity/BasePancakeSwapInfinity.sol";

interface IPancakeV3LikePairFactory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

contract V3ToInfinityMigrationTest is BasePancakeSwapInfinity, OldVersionHelper, BinLiquidityHelper {
    using BinPoolParametersHelper for bytes32;
    using CLPoolParametersHelper for bytes32;
    using Planner for Plan;

    MockERC20 token0;
    MockERC20 token1;
    WETH weth = new WETH();

    // v3 related
    IV3NonfungiblePositionManager v3Nfpm;
    address alice;
    uint256 alicePK;
    uint256 v3TokenId;

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
        vm.label(Currency.unwrap(currency0), "token0");
        vm.label(Currency.unwrap(currency1), "token1");
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        permit2 = IAllowanceTransfer(deployPermit2());

        ///////////////////////////////////
        //////////// v3 setup /////////////
        ///////////////////////////////////
        address deployer = createContractThroughBytecode(_getDeployerBytecodePath());
        IPancakeV3LikePairFactory v3Factory = IPancakeV3LikePairFactory(
            createContractThroughBytecode(_getFactoryBytecodePath(), toBytes32(address(deployer)))
        );
        (bool success,) = deployer.call(abi.encodeWithSignature("setFactoryAddress(address)", address(v3Factory)));
        require(success, "setFactoryAddress failed");
        v3Nfpm = IV3NonfungiblePositionManager(
            createContractThroughBytecode(
                _getNfpmBytecodePath(), toBytes32(deployer), toBytes32(address(v3Factory)), toBytes32(address(weth)), 0
            )
        );

        // Get alice to mint some v3 liqudiity to migrate later
        token0.mint(alice, 10 ether);
        token1.mint(alice, 10 ether);
        vm.startPrank(alice);
        token0.approve(address(v3Nfpm), type(uint256).max);
        token1.approve(address(v3Nfpm), type(uint256).max);
        v3TokenId = _mintV3Liquidity(address(token0), address(token1), alice);
        vm.stopPrank();

        ///////////////////////////////////
        ////////// infinity setup /////////
        ///////////////////////////////////
        vault = IVault(new Vault());
        binPoolManager = new BinPoolManager(vault);
        clPoolManager = new CLPoolManager(vault);
        vault.registerApp(address(binPoolManager));
        vault.registerApp(address(clPoolManager));

        binPositionManager = new BinPositionManager(vault, binPoolManager, permit2, IWETH9(address(weth)));
        _approvePermit2ForCurrency(address(this), currency0, address(binPositionManager), permit2);
        _approvePermit2ForCurrency(address(this), currency1, address(binPositionManager), permit2);

        CLPositionDescriptorOffChain pd =
            new CLPositionDescriptorOffChain("https://pancakeswap.finance/infinity/pool-cl/positions/");
        clPositionManager = new CLPositionManager(vault, clPoolManager, permit2, 100_000, pd, IWETH9(address(weth)));
        _approvePermit2ForCurrency(address(this), currency0, address(clPositionManager), permit2);
        _approvePermit2ForCurrency(address(this), currency1, address(clPositionManager), permit2);

        clPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: clPoolManager,
            fee: uint24(3000),
            parameters: bytes32(0).setTickSpacing(10)
        });
        clPoolManager.initialize(clPoolKey, SQRT_PRICE_1_1);

        binPoolKey = PoolKey({
            currency0: currency0,
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
            v3NFTPositionManager: address(v3Nfpm),
            infiClPositionManager: address(clPositionManager),
            infiBinPositionManager: address(binPositionManager)
        });
        router = new UniversalRouter(params);
        _approvePermit2ForCurrency(alice, currency0, address(router), permit2);
        _approvePermit2ForCurrency(alice, currency1, address(router), permit2);
    }

    function test_v3PositionManager_onlyAuthorizedForToken() public {
        //valid action: decreaseLiquidity, collect, burn
        IV3NonfungiblePositionManager.CollectParams memory params = IV3NonfungiblePositionManager.CollectParams({
            tokenId: v3TokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_POSITION_MANAGER_CALL)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encodePacked(IV3NonfungiblePositionManager.collect.selector, abi.encode(params));

        vm.expectRevert(abi.encodeWithSelector(V3ToInfinityMigrator.NotAuthorizedForToken.selector, params.tokenId));
        router.execute(commands, inputs);
    }

    function test_v3PositionManager_invalidAction() public {
        IV3NonfungiblePositionManager.MintParams memory params = IV3NonfungiblePositionManager.MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: 500,
            tickLower: -100,
            tickUpper: 100,
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_POSITION_MANAGER_CALL)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encodePacked(IV3NonfungiblePositionManager.mint.selector, abi.encode(params));

        vm.expectRevert(
            abi.encodeWithSelector(
                V3ToInfinityMigrator.InvalidAction.selector, IV3NonfungiblePositionManager.mint.selector
            )
        );
        router.execute(commands, inputs);
    }

    function test_v3PositionManager_erc721Permit() public {
        vm.startPrank(alice);

        (uint8 v, bytes32 r, bytes32 s) = _getErc721PermitSignature(address(router), v3TokenId, block.timestamp);
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_POSITION_MANAGER_PERMIT)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encodePacked(
            IERC721Permit.permit.selector, abi.encode(address(router), v3TokenId, block.timestamp, v, r, s)
        );

        router.execute(commands, inputs);

        assertEq(v3Nfpm.getApproved(v3TokenId), address(router));
    }

    /// @dev simulate permit -> decrease -> collect (token0/token1 to universal router) -> burn
    function test_v3PositionManager_burn() public {
        vm.startPrank(alice);

        // before: verify token0/token1 balance in router
        assertEq(token0.balanceOf(address(router)), 0);
        assertEq(token1.balanceOf(address(router)), 0);

        // build up the params for (permit -> decrease -> collect)
        (,,,,,,, uint128 liqudiity,,,,) = v3Nfpm.positions(v3TokenId);
        (uint8 v, bytes32 r, bytes32 s) = _getErc721PermitSignature(address(router), v3TokenId, block.timestamp);
        IV3NonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams = IV3NonfungiblePositionManager
            .DecreaseLiquidityParams({
            tokenId: v3TokenId,
            liquidity: liqudiity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });
        IV3NonfungiblePositionManager.CollectParams memory collectParam = IV3NonfungiblePositionManager.CollectParams({
            tokenId: v3TokenId,
            recipient: address(router),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        // build up univeral router commands
        bytes memory commands = abi.encodePacked(
            bytes1(uint8(Commands.V3_POSITION_MANAGER_PERMIT)),
            bytes1(uint8(Commands.V3_POSITION_MANAGER_CALL)), // decrease
            bytes1(uint8(Commands.V3_POSITION_MANAGER_CALL)), // collect
            bytes1(uint8(Commands.V3_POSITION_MANAGER_CALL)) // burn
        );

        bytes[] memory inputs = new bytes[](4);
        inputs[0] = abi.encodePacked(
            IERC721Permit.permit.selector, abi.encode(address(router), v3TokenId, block.timestamp, v, r, s)
        );
        inputs[1] =
            abi.encodePacked(IV3NonfungiblePositionManager.decreaseLiquidity.selector, abi.encode(decreaseParams));
        inputs[2] = abi.encodePacked(IV3NonfungiblePositionManager.collect.selector, abi.encode(collectParam));
        inputs[3] = abi.encodePacked(IV3NonfungiblePositionManager.burn.selector, abi.encode(v3TokenId));

        router.execute(commands, inputs);
        vm.snapshotGasLastCall("test_v3PositionManager_burn");

        // after: verify token0/token1 balance in router
        assertEq(token0.balanceOf(address(router)), 9999999999999999999);
        assertEq(token1.balanceOf(address(router)), 9999999999999999999);
    }

    function test_infiCLPositionmanger_InvalidAction() public {
        Plan memory planner = Planner.init();

        // prep universal router actions
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.INFI_CL_POSITION_CALL)));
        bytes[] memory inputs = new bytes[](1);

        bytes4 invalidSelector = IPositionManager.modifyLiquiditiesWithoutLock.selector;
        inputs[0] = abi.encodePacked(invalidSelector, abi.encode(planner.encode(), block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(V3ToInfinityMigrator.InvalidAction.selector, invalidSelector));
        router.execute(commands, inputs);
    }

    function test_infiCLPositionmanger_BlacklistedAction() public {
        Plan memory planner = Planner.init();
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.INFI_CL_POSITION_CALL)));
        bytes[] memory inputs = new bytes[](1);

        uint256[] memory invalidActions = new uint256[](3);
        invalidActions[0] = Actions.CL_INCREASE_LIQUIDITY;
        invalidActions[1] = Actions.CL_DECREASE_LIQUIDITY;
        invalidActions[2] = Actions.CL_BURN_POSITION;

        for (uint256 i; i < invalidActions.length; i++) {
            planner.add(invalidActions[i], "");
            inputs[0] = abi.encodePacked(
                IPositionManager.modifyLiquidities.selector, abi.encode(planner.encode(), block.timestamp)
            );

            // verify revert for invalid actions
            vm.expectRevert(V3ToInfinityMigrator.OnlyMintAllowed.selector);
            router.execute(commands, inputs);
        }
    }

    function test_infiBinPositionmanger_InvalidAction() public {
        Plan memory planner = Planner.init();

        // prep universal router actions
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.INFI_BIN_POSITION_CALL)));
        bytes[] memory inputs = new bytes[](1);

        bytes4 invalidSelector = IPositionManager.modifyLiquiditiesWithoutLock.selector;
        inputs[0] = abi.encodePacked(invalidSelector, abi.encode(planner.encode(), block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(V3ToInfinityMigrator.InvalidAction.selector, invalidSelector));
        router.execute(commands, inputs);
    }

    function test_infiBinPositionmanger_BlacklistedAction() public {
        Plan memory planner = Planner.init();
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.INFI_BIN_POSITION_CALL)));
        bytes[] memory inputs = new bytes[](1);

        uint256[] memory invalidActions = new uint256[](1);
        invalidActions[0] = Actions.BIN_REMOVE_LIQUIDITY;

        for (uint256 i; i < invalidActions.length; i++) {
            planner.add(invalidActions[i], "");
            inputs[0] = abi.encodePacked(
                IPositionManager.modifyLiquidities.selector, abi.encode(planner.encode(), block.timestamp)
            );

            // verify revert for invalid actions
            vm.expectRevert(V3ToInfinityMigrator.OnlyAddLiqudityAllowed.selector);
            router.execute(commands, inputs);
        }
    }

    /// @dev Assume token0/token1 is aready in universal router from earlier steps on v3
    ///      then add liquidity to infinity cl and sweep remaining token
    function test_infiCLPositionmanager_Mint() public {
        // assume token0/token1 is in universal router
        token0.mint(address(router), 10 ether);
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
            bytes1(uint8(Commands.SWEEP)), bytes1(uint8(Commands.SWEEP)), bytes1(uint8(Commands.INFI_CL_POSITION_CALL))
        );
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = abi.encode(token0, address(clPositionManager), 0); // send token to clPositionmanager
        inputs[1] = abi.encode(token1, address(clPositionManager), 0); // send token to clPositionmanager
        inputs[2] =
            abi.encodePacked(IPositionManager.modifyLiquidities.selector, abi.encode(planner.encode(), block.timestamp));

        vm.prank(alice);
        router.execute(commands, inputs);
        vm.snapshotGasLastCall("test_infiCLPositionmanager_Mint");

        // verify balance sent back to alice
        assertEq(token0.balanceOf(address(alice)), 9994018262239490337);
        assertEq(token1.balanceOf(address(alice)), 9994018262239490337);
        assertEq(clPositionManager.ownerOf(1), alice);
    }

    /// @dev Assume token0/token1 is aready in universal router from earlier steps on v3
    ///      then add liquidity to infinity cl and sweep remaining token
    function test_infiBinPositionmanager_BinAddLiquidity() public {
        // assume token0/token1 is in universal router
        token0.mint(address(router), 10 ether);
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
            bytes1(uint8(Commands.SWEEP)), bytes1(uint8(Commands.SWEEP)), bytes1(uint8(Commands.INFI_BIN_POSITION_CALL))
        );
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = abi.encode(token0, address(binPositionManager), 0); // send token to binPositionManager
        inputs[1] = abi.encode(token1, address(binPositionManager), 0); // send token to binPositionManager
        inputs[2] =
            abi.encodePacked(IPositionManager.modifyLiquidities.selector, abi.encode(planner.encode(), block.timestamp));

        vm.prank(alice);
        router.execute(commands, inputs);
        vm.snapshotGasLastCall("test_infiBinPositionmanager_BinAddLiquidity");

        // verify balance sent back to alice
        assertEq(token0.balanceOf(address(alice)), 5 ether);
        assertEq(token1.balanceOf(address(alice)), 5 ether);
    }

    /// @dev add 10 eth liquidity to v3 pool with 1:1 price at -100, to 100 tick range
    function _mintV3Liquidity(address _token0, address _token1, address recipient) internal returns (uint256 tokenId) {
        v3Nfpm.createAndInitializePoolIfNecessary(_token0, _token1, 500, SQRT_PRICE_1_1);
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
            recipient: recipient,
            deadline: block.timestamp + 100
        });

        (tokenId,,,) = v3Nfpm.mint(mintParams);
    }

    /// @dev generate erc721 signature, signing from alice
    function _getErc721PermitSignature(address spender, uint256 tokenId, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        (uint256 nonce,,,,,,,,,,,) = v3Nfpm.positions(tokenId);
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                v3Nfpm.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(v3Nfpm.PERMIT_TYPEHASH(), spender, tokenId, nonce, deadline))
            )
        );

        (v, r, s) = vm.sign(alicePK, digest);
    }

    function _getDeployerBytecodePath() internal pure returns (string memory) {
        // https://etherscan.io/address/0x41ff9AA7e16B8B1a8a8dc4f0eFacd93D02d071c9#code
        return "./test/bin/pcsV3Deployer.bytecode";
    }

    function _getFactoryBytecodePath() internal pure returns (string memory) {
        // https://etherscan.io/address/0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865#code
        return "./test/bin/pcsV3Factory.bytecode";
    }

    function _getNfpmBytecodePath() internal pure returns (string memory) {
        // https://etherscan.io/address/0x46A15B0b27311cedF172AB29E4f4766fbE7F4364#code
        return "./test/bin/pcsV3Nfpm.bytecode";
    }
}
