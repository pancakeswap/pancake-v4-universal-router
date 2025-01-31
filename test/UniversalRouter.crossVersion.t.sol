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
import {CLPositionDescriptorOffChain} from "infinity-periphery/src/pool-cl/CLPositionDescriptorOffChain.sol";
import {CLPositionManager} from "infinity-periphery/src/pool-cl/CLPositionManager.sol";
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
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {Commands} from "../src/libraries/Commands.sol";
import {RouterParameters} from "../src/base/RouterImmutables.sol";
import {Dispatcher} from "../src/base/Dispatcher.sol";
import {UniversalRouter} from "../src/UniversalRouter.sol";
import {BasePancakeSwapInfinity} from "./infinity/BasePancakeSwapInfinity.sol";
import {ICLRouterBase} from "infinity-periphery/src/interfaces/IInfinityRouter.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";

interface IPancakeV3LikePairFactory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

contract UniversalRouterCrossVersionTest is BasePancakeSwapInfinity, OldVersionHelper, BinLiquidityHelper {
    using BinPoolParametersHelper for bytes32;
    using CLPoolParametersHelper for bytes32;
    using Planner for Plan;

    uint24 constant LP_FEE = 500;

    MockERC20 usdt;
    MockERC20 usdc;
    WETH weth = new WETH();

    address liquidityProvider = makeAddr("liquidityProvider");

    // v3 related
    IV3NonfungiblePositionManager v3Nfpm;

    // infinity related
    IVault vault;
    IBinPoolManager binPoolManager;
    BinPositionManager binPositionManager;
    ICLPoolManager clPoolManager;
    CLPositionManager clPositionManager;
    IAllowanceTransfer permit2;
    UniversalRouter router;
    PoolKey clPoolKeyWithETH;
    PoolKey clPoolKeyWithWrappedETH;
    PoolKey binPoolKeyWithETH;
    PoolKey binPoolKeyWithWrappedETH;

    uint24 constant ACTIVE_ID_1_1 = 2 ** 23; // where token0 and token1 price is the same
    uint160 constant SQRT_PRICE_1_1 = uint160(1 * FixedPoint96.Q96); // price 1

    function setUp() public {
        initializeTokens();
        vm.label(Currency.unwrap(currency0), "usdt");
        vm.label(Currency.unwrap(currency1), "usdc");
        usdt = MockERC20(Currency.unwrap(currency0));
        usdc = MockERC20(Currency.unwrap(currency1));

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

        ///////////////////////////////////
        //////////// infinity setup /////////////
        ///////////////////////////////////
        vault = IVault(new Vault());
        binPoolManager = new BinPoolManager(vault);
        clPoolManager = new CLPoolManager(vault);
        vault.registerApp(address(binPoolManager));
        vault.registerApp(address(clPoolManager));

        binPositionManager = new BinPositionManager(vault, binPoolManager, permit2, IWETH9(address(weth)));
        CLPositionDescriptorOffChain pd =
            new CLPositionDescriptorOffChain("https://pancakeswap.finance/infinity/pool-cl/positions/");
        clPositionManager = new CLPositionManager(vault, clPoolManager, permit2, 100_000, pd, IWETH9(address(weth)));

        ///////////////////////////////////
        //////////// Router setup /////////////
        ///////////////////////////////////
        RouterParameters memory params = RouterParameters({
            permit2: address(permit2),
            weth9: address(weth),
            v2Factory: address(0),
            v3Factory: address(v3Factory),
            v3Deployer: deployer,
            v2InitCodeHash: bytes32(0),
            v3InitCodeHash: bytes32(0x6ce8eb472fa82df5469c6ab6d485f17c3ad13c8cd7af59b3d4a8026c5ce0f7e2),
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
        _approvePermit2ForCurrency(address(this), currency0, address(router), permit2);
        _approvePermit2ForCurrency(address(this), currency1, address(router), permit2);
        _approvePermit2ForCurrency(address(this), Currency.wrap(address(weth)), address(router), permit2);

        ///////////////////////////////////
        //////////// Add Liquidity /////////////
        ///////////////////////////////////

        // add liquidity to v3 usdt-weth pool
        _mintV3Liquidity(address(usdt), address(weth), liquidityProvider);

        // add liquidity to infinity usdc-eth cl-pool
        clPoolKeyWithETH = _mintInfiCLLiquidity(address(usdc), address(0), liquidityProvider);
        // add liquidity to infinity usdc-weth cl-pool
        clPoolKeyWithWrappedETH = _mintInfiCLLiquidity(address(usdc), address(weth), liquidityProvider);
    }

    /// @dev case0:
    ///     hop1. swap with a v3 (weth-usdt) pool
    ///     hop2. swap with a infinity native (eth-usdc) pool
    function test_corssVersionSwapCase0() public {
        // 0. user starts with 1 ether USDT
        address trader = makeAddr("trader");
        _deal(address(usdt), trader, 1 ether);
        _approvePermit2ForCurrency(trader, Currency.wrap(address(usdt)), address(router), permit2);

        vm.startPrank(trader);

        // 1. build up univeral router commands list
        bytes memory commands = abi.encodePacked(
            bytes1(uint8(Commands.V3_SWAP_EXACT_IN)), // USDT-> WETH
            bytes1(uint8(Commands.UNWRAP_WETH)), // WETH -> ETH
            bytes1(uint8(Commands.INFI_SWAP)) // ETH -> USDC
        );

        // 2. build up corresponding inputs
        bytes[] memory inputs = new bytes[](3);

        // 2.1. prepare v3 exact in params (i.e. USDT -> WETH):
        bytes memory path = abi.encodePacked(address(usdt), LP_FEE, address(weth));
        // address recipient = ADDRESS_THIS to make sure WETH is send back to universal router
        // uint256 amountIn;
        // uint256 amountOutMin = 0 since we only need to check at the very end
        // bool payerIsUser = true since user is paying USDT
        inputs[0] = abi.encode(ActionConstants.ADDRESS_THIS, 1 ether, 0, path, true);

        // 2.2. unwrap WETH to ETH:

        // address recipient = ADDRESS_THIS to make sure ETH is send back to universal router;
        // uint256 amountMin = 0 (by default all the WETH will be unwrapped);
        inputs[1] = abi.encode(ActionConstants.ADDRESS_THIS, 0);

        // 2.3. prepare infinity exact in params (i.e. ETH -> USDC)
        Plan memory planner = Planner.init();

        // 2.3.1. send ETH to vault ahead of time so that we can use it to pay for the following swap
        // Currency currency = ETH
        // uint256 amount = CONTRACT_BALANCE
        // bool payerIsUser = false i.e. use the ETH we just received from unwrapping WETH
        planner.add(Actions.SETTLE, abi.encode(CurrencyLibrary.NATIVE, ActionConstants.CONTRACT_BALANCE, false));

        // 2.3.2. infinity swap params
        ICLRouterBase.CLSwapExactInputSingleParams memory params = ICLRouterBase.CLSwapExactInputSingleParams({
            poolKey: clPoolKeyWithETH,
            zeroForOne: true, // token0 is ETH
            // OPEN_DELTA indicates using the amount from vault delta
            amountIn: ActionConstants.OPEN_DELTA,
            amountOutMinimum: 0.8 ether,
            hookData: new bytes(0)
        });
        planner.add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));

        // 2.3.3. sweep all the tokens if any
        planner.add(Actions.TAKE_ALL, abi.encode(clPoolKeyWithETH.currency0, 0));
        planner.add(Actions.TAKE_ALL, abi.encode(clPoolKeyWithETH.currency1, 0));

        inputs[2] = planner.encode();

        // 3. execute
        router.execute(commands, inputs);

        // 4. check
        // 4.1. make sure user receives at least 0.8 ether
        assertEq(usdt.balanceOf(trader), 0);
        assertGe(usdc.balanceOf(trader), 0.8 ether);

        // 4.2. make sure no eth or weth left in the router
        assertEq(weth.balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);

        vm.stopPrank();
    }

    /// @dev case1:
    ///     hop1. swap with a v3 (weth-usdt) pool
    ///     hop2. swap with a infinity non-native (weth-usdc) pool
    function test_corssVersionSwapCase1() public {
        // 0. user starts with 1 ether USDT
        address trader = makeAddr("trader");
        _deal(address(usdt), trader, 1 ether);
        _approvePermit2ForCurrency(trader, Currency.wrap(address(usdt)), address(router), permit2);

        vm.startPrank(trader);

        // 1. build up univeral router commands list
        bytes memory commands = abi.encodePacked(
            bytes1(uint8(Commands.V3_SWAP_EXACT_IN)), // USDT-> WETH
            bytes1(uint8(Commands.INFI_SWAP)) // WETH -> USDC
        );

        // 2. build up corresponding inputs
        bytes[] memory inputs = new bytes[](2);

        // 2.1. prepare v3 exact in params (i.e. USDT -> WETH):
        bytes memory path = abi.encodePacked(address(usdt), LP_FEE, address(weth));
        // address recipient = ADDRESS_THIS to make sure WETH is send back to universal router
        // uint256 amountIn;
        // uint256 amountOutMin = 0 since we only need to check at the very end
        // bool payerIsUser = true since user is paying USDT
        inputs[0] = abi.encode(ActionConstants.ADDRESS_THIS, 1 ether, 0, path, true);

        // 2.2. prepare infinity exact in params (i.e. WETH -> USDC)
        Plan memory planner = Planner.init();

        // 2.2.1. send ETH to vault ahead of time so that we can use it to pay for the following swap
        // Currency currency = WETH
        // uint256 amount = CONTRACT_BALANCE
        // bool payerIsUser = false i.e. use the WETH we just received from v3Swap
        planner.add(Actions.SETTLE, abi.encode(Currency.wrap(address(weth)), ActionConstants.CONTRACT_BALANCE, false));

        // 2.2.2. infinity swap params
        bool zeroForOne = Currency.unwrap(clPoolKeyWithWrappedETH.currency0) == address(weth);
        ICLRouterBase.CLSwapExactInputSingleParams memory params = ICLRouterBase.CLSwapExactInputSingleParams({
            poolKey: clPoolKeyWithWrappedETH,
            zeroForOne: zeroForOne,
            // OPEN_DELTA indicates using the amount from vault delta
            amountIn: ActionConstants.OPEN_DELTA,
            amountOutMinimum: 0.8 ether,
            hookData: new bytes(0)
        });
        planner.add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));

        // 2.3.3. sweep all the tokens if any
        planner.add(Actions.TAKE_ALL, abi.encode(clPoolKeyWithWrappedETH.currency0, 0));
        planner.add(Actions.TAKE_ALL, abi.encode(clPoolKeyWithWrappedETH.currency1, 0));

        inputs[1] = planner.encode();

        // 3. execute
        router.execute(commands, inputs);

        // 4. check
        // 4.1. make sure user receives at least 0.8 ether
        assertEq(usdt.balanceOf(trader), 0);
        assertGe(usdc.balanceOf(trader), 0.8 ether);

        // 4.2. make sure no eth or weth left in the router
        assertEq(weth.balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);

        vm.stopPrank();
    }

    /// @dev case2:
    ///     hop1. swap with a infinity native (eth-usdc) pool
    ///     hop2. swap with a v3 (weth-usdt) pool
    function test_corssVersionSwapCase2() public {
        // 0. user starts with 1 ether usdc
        address trader = makeAddr("trader");
        _deal(address(usdc), trader, 1 ether);
        _approvePermit2ForCurrency(trader, Currency.wrap(address(usdc)), address(router), permit2);

        vm.startPrank(trader);

        // 1. build up univeral router commands list
        bytes memory commands = abi.encodePacked(
            bytes1(uint8(Commands.INFI_SWAP)), // USDC -> ETH
            bytes1(uint8(Commands.WRAP_ETH)), // ETH -> WETH
            bytes1(uint8(Commands.V3_SWAP_EXACT_IN)), // WETH -> USDT
            bytes1(uint8(Commands.SWEEP)) // SWEEP WETH
        );

        // 2. build up corresponding inputs
        bytes[] memory inputs = new bytes[](4);

        // 2.1. prepare infinity exact in params (i.e. ETH -> USDC)
        Plan memory planner = Planner.init();

        // 2.1.1. infinity swap params
        ICLRouterBase.CLSwapExactInputSingleParams memory params = ICLRouterBase.CLSwapExactInputSingleParams({
            poolKey: clPoolKeyWithETH,
            zeroForOne: false, // token0 is ETH
            amountIn: 1 ether,
            // we only need to check at the very end
            amountOutMinimum: 0,
            hookData: new bytes(0)
        });
        planner.add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));

        // 2.1.2. withdraw ETH from vault, make sure all the amount is taken to the router
        planner.add(
            Actions.TAKE,
            abi.encode(clPoolKeyWithETH.currency0, ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA)
        );

        // 2.1.3. pay USDC to vault, at most 1 ether
        planner.add(Actions.SETTLE_ALL, abi.encode(clPoolKeyWithETH.currency1, 1 ether));

        inputs[0] = planner.encode();

        // 2.2. wrap ETH to WETH:
        // address recipient = ADDRESS_THIS to make sure WETH is send back to universal router;
        // uint256 amount = ActionConstants.CONTRACT_BALANCE to make sure all the ETH from infinity is wrapped
        inputs[1] = abi.encode(ActionConstants.ADDRESS_THIS, ActionConstants.CONTRACT_BALANCE);

        // 2.3. prepare v3 exact in params (i.e. WETH -> USDT):
        bytes memory path = abi.encodePacked(address(weth), LP_FEE, address(usdt));
        // address recipient = MSG_SENDER to make sure USDT is send to trader
        // uint256 amountIn = CONTRACT_BALANCE
        // uint256 amountOutMin = 0.8 ether, make sure user receives at least 0.8 ether usdt
        // bool payerIsUser = false, since we are using weth balance from universal router itself
        inputs[2] = abi.encode(ActionConstants.MSG_SENDER, ActionConstants.CONTRACT_BALANCE, 0.8 ether, path, false);

        // 2.4 sweep in case partial fulfilled swap
        // address token;
        // address recipient;
        // uint160 amountMin;
        inputs[3] = abi.encode(weth, ActionConstants.MSG_SENDER, 0);

        // 3. execute
        router.execute(commands, inputs);

        // 4. check
        // 4.1. make sure user receives at least 0.8 ether
        assertEq(usdc.balanceOf(trader), 0);
        assertGe(usdt.balanceOf(trader), 0.8 ether);

        // 4.2. make sure no eth or weth left in the router
        assertEq(weth.balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);

        vm.stopPrank();
    }

    /// @dev case3:
    ///     hop1. swap with a infinity non-native (weth-usdc) pool
    ///     hop2. swap with a v3 (weth-usdt) pool
    function test_corssVersionSwapCase3() public {
        // 0. user starts with 1 ether usdc
        address trader = makeAddr("trader");
        _deal(address(usdc), trader, 1 ether);
        _approvePermit2ForCurrency(trader, Currency.wrap(address(usdc)), address(router), permit2);

        vm.startPrank(trader);

        // 1. build up univeral router commands list
        bytes memory commands = abi.encodePacked(
            bytes1(uint8(Commands.INFI_SWAP)), // USDC -> WETH
            bytes1(uint8(Commands.V3_SWAP_EXACT_IN)), // WETH -> USDT
            bytes1(uint8(Commands.SWEEP)) // SWEEP WETH
        );

        // 2. build up corresponding inputs
        bytes[] memory inputs = new bytes[](3);

        // 2.1. prepare infinity exact in params (i.e. WETH -> USDC)
        Plan memory planner = Planner.init();

        // 2.1.1. infinity swap params
        bool zeroForOne = Currency.unwrap(clPoolKeyWithWrappedETH.currency0) != address(weth);
        ICLRouterBase.CLSwapExactInputSingleParams memory params = ICLRouterBase.CLSwapExactInputSingleParams({
            poolKey: clPoolKeyWithWrappedETH,
            zeroForOne: zeroForOne,
            amountIn: 1 ether,
            // we only need to check at the very end
            amountOutMinimum: 0,
            hookData: new bytes(0)
        });
        planner.add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));

        // 2.1.2. withdraw WETH from vault, make sure all the amount is taken to the router
        planner.add(
            Actions.TAKE,
            abi.encode(clPoolKeyWithWrappedETH.currency0, ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA)
        );

        // 2.1.3. pay USDC to vault, at most 1 ether
        planner.add(Actions.SETTLE_ALL, abi.encode(clPoolKeyWithWrappedETH.currency1, 1 ether));

        inputs[0] = planner.encode();

        // 2.2. prepare v3 exact in params (i.e. WETH -> USDT):
        bytes memory path = abi.encodePacked(address(weth), LP_FEE, address(usdt));
        // address recipient = MSG_SENDER to make sure USDT is send to trader
        // uint256 amountIn = CONTRACT_BALANCE
        // uint256 amountOutMin = 0.8 ether, make sure user receives at least 0.8 ether usdt
        // bool payerIsUser = false, since we are using weth balance from universal router itself
        inputs[1] = abi.encode(ActionConstants.MSG_SENDER, ActionConstants.CONTRACT_BALANCE, 0.8 ether, path, false);

        // 2.3 sweep in case partial fulfilled swap
        // address token;
        // address recipient;
        // uint160 amountMin;
        inputs[2] = abi.encode(weth, ActionConstants.MSG_SENDER, 0);

        // 3. execute
        router.execute(commands, inputs);

        // 4. check
        // 4.1. make sure user receives at least 0.8 ether
        assertEq(usdc.balanceOf(trader), 0);
        assertGe(usdt.balanceOf(trader), 0.8 ether);

        // 4.2. make sure no eth or weth left in the router
        assertEq(weth.balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);

        vm.stopPrank();
    }

    /// @dev add 10 eth liquidity to v3 pool with 1:1 price at -100, to 100 tick range
    function _mintV3Liquidity(address _token0, address _token1, address recipient) internal {
        // make sure token pair is in correct order
        if (_token0 > _token1) {
            (_token0, _token1) = (_token1, _token0);
        }

        // make sure we have enough fund for adding liquidity
        _deal(_token0, address(this), 10 ether);
        _deal(_token1, address(this), 10 ether);
        MockERC20(_token0).approve(address(v3Nfpm), type(uint256).max);
        MockERC20(_token1).approve(address(v3Nfpm), type(uint256).max);

        v3Nfpm.createAndInitializePoolIfNecessary(_token0, _token1, LP_FEE, SQRT_PRICE_1_1);
        IV3NonfungiblePositionManager.MintParams memory mintParams = IV3NonfungiblePositionManager.MintParams({
            token0: _token0,
            token1: _token1,
            fee: LP_FEE,
            tickLower: -100,
            tickUpper: 100,
            amount0Desired: 10 ether,
            amount1Desired: 10 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: recipient,
            deadline: block.timestamp + 100
        });

        v3Nfpm.mint(mintParams);
    }

    function _mintInfiCLLiquidity(address _token0, address _token1, address recipient)
        internal
        returns (PoolKey memory key)
    {
        // make sure token pair is in correct order
        if (_token0 > _token1) {
            (_token0, _token1) = (_token1, _token0);
        }

        // make sure we have enough fund for adding liquidity
        _deal(_token0, address(clPositionManager), 10 ether);
        _deal(_token1, address(clPositionManager), 10 ether);

        key = PoolKey({
            currency0: Currency.wrap(_token0),
            currency1: Currency.wrap(_token1),
            hooks: IHooks(address(0)),
            poolManager: clPoolManager,
            fee: uint24(LP_FEE),
            parameters: bytes32(0).setTickSpacing(10)
        });
        clPoolManager.initialize(key, SQRT_PRICE_1_1);

        // prep position manager action to mint liquidity
        Plan memory planner = Planner.init();
        planner.add(Actions.CL_MINT_POSITION, abi.encode(key, -120, 120, 1000 ether, 10 ether, 10 ether, recipient, ""));
        planner.add(Actions.SETTLE, abi.encode(key.currency0, ActionConstants.OPEN_DELTA, false)); // deduct from universal router
        planner.add(Actions.SETTLE, abi.encode(key.currency1, ActionConstants.OPEN_DELTA, false)); // deduct from universal router
        planner.add(Actions.SWEEP, abi.encode(key.currency0, recipient));
        planner.add(Actions.SWEEP, abi.encode(key.currency1, recipient));

        // prep universal router actions
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.INFI_CL_POSITION_CALL)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] =
            abi.encodePacked(IPositionManager.modifyLiquidities.selector, abi.encode(planner.encode(), block.timestamp));

        router.execute(commands, inputs);
    }

    function _deal(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            vm.deal(to, amount);
        } else if (token == address(weth)) {
            vm.deal(to, amount);
            vm.prank(to);
            weth.deposit{value: amount}();
        } else {
            MockERC20(token).mint(to, amount);
        }
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

    // make sure the contract can receive eth
    receive() external payable {}
}
