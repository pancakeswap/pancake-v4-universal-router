// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {Hooks} from "pancake-v4-core/src/libraries/Hooks.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {LiquidityAmounts} from "pancake-v4-core/test/pool-cl/helpers/LiquidityAmounts.sol";
import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {CLPosition} from "pancake-v4-core/src/pool-cl/libraries/CLPosition.sol";
import {SafeCast} from "pancake-v4-core/src/libraries/SafeCast.sol";
import {SafeCastTemp} from "../../../src/libraries/SafeCast.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/interfaces/IERC721.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ReentrancyLock} from "../../../src/base/ReentrancyLock.sol";
import {CLPositionManager} from "../../../src/pool-cl/CLPositionManager.sol";
import {DeltaResolver} from "../../../src/base/DeltaResolver.sol";
import {PositionConfig, PositionConfigLibrary} from "../../../src/pool-cl/libraries/PositionConfig.sol";
import {SlippageCheckLibrary} from "../../../src/pool-cl/libraries/SlippageCheck.sol";
import {ICLPositionManager} from "../../../src/pool-cl/interfaces/ICLPositionManager.sol";
import {Actions} from "../../../src/libraries/Actions.sol";
import {Planner, Plan} from "../../../src/libraries/Planner.sol";
import {FeeMath} from "../shared/FeeMath.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {ActionConstants} from "../../../src/libraries/ActionConstants.sol";

import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";

contract CLPositionManagerModifyLiquiditiesTest is Test, PosmTestSetup, LiquidityFuzzers {
    using PoolIdLibrary for PoolKey;

    IVault vault;
    ICLPoolManager manager;

    PoolId poolId;
    PoolKey key;

    address alice;
    uint256 alicePK;
    address bob;

    PositionConfig config;

    function setUp() public {
        (alice, alicePK) = makeAddrAndKey("ALICE");
        (bob,) = makeAddrAndKey("BOB");

        (currency0, currency1) = deployCurrencies(2 ** 255);

        (vault, manager) = createFreshManager();
        deployAndApproveRouter(vault, manager);

        // Requires currency0 and currency1 to be set in base Deployers contract.
        deployAndApprovePosm(vault, manager);

        // must deploy after posm
        // Deploys a hook which can accesses IPositionManager.modifyLiquiditiesWithoutUnlock
        deployPosmHookModifyLiquidities();

        key = PoolKey(
            currency0,
            currency1,
            IHooks(address(hookModifyLiquidities)),
            manager,
            3000,
            bytes32(uint256(((3000 / 100 * 2) << 16) | 0x00ff))
        );
        poolId = key.toId();
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        seedBalance(alice);
        approvePosmFor(alice);
        seedBalance(address(hookModifyLiquidities));

        config = PositionConfig({poolKey: key, tickLower: -60, tickUpper: 60});
    }

    /// @dev minting liquidity without approval is allowable
    function test_hook_mint() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        // hook mints a new position in beforeSwap via hookData
        uint256 hookTokenId = lpm.nextTokenId();
        uint256 newLiquidity = 10e18;
        bytes memory calls = getMintEncoded(config, newLiquidity, address(hookModifyLiquidities), ZERO_BYTES);

        swap(key, true, -1e18, calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId, config);

        // original liquidity unchanged
        assertEq(liquidity, initialLiquidity, "fuck");

        // hook minted its own position
        liquidity = lpm.getPositionLiquidity(hookTokenId, config);
        assertEq(liquidity, newLiquidity);

        assertEq(lpm.ownerOf(tokenId), address(this)); // original position owned by this contract
        assertEq(lpm.ownerOf(hookTokenId), address(hookModifyLiquidities)); // hook position owned by hook
    }

    /// @dev hook must be approved to increase liquidity
    function test_hook_increaseLiquidity() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        // approve the hook for increasing liquidity
        lpm.approve(address(hookModifyLiquidities), tokenId);

        // hook increases liquidity in beforeSwap via hookData
        uint256 newLiquidity = 10e18;
        bytes memory calls = getIncreaseEncoded(tokenId, config, newLiquidity, ZERO_BYTES);

        swap(key, true, -1e18, calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId, config);

        assertEq(liquidity, initialLiquidity + newLiquidity);
    }

    /// @dev hook can decrease liquidity with approval
    function test_hook_decreaseLiquidity() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        // approve the hook for decreasing liquidity
        lpm.approve(address(hookModifyLiquidities), tokenId);

        // hook decreases liquidity in beforeSwap via hookData
        uint256 liquidityToDecrease = 10e18;
        bytes memory calls = getDecreaseEncoded(tokenId, config, liquidityToDecrease, ZERO_BYTES);

        swap(key, true, -1e18, calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId, config);

        assertEq(liquidity, initialLiquidity - liquidityToDecrease);
    }

    /// @dev hook can collect liquidity with approval
    function test_hook_collect() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        // approve the hook for collecting liquidity
        lpm.approve(address(hookModifyLiquidities), tokenId);

        // donate to generate revenue
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        router.donate(config.poolKey, feeRevenue0, feeRevenue1, ZERO_BYTES);

        uint256 balance0HookBefore = currency0.balanceOf(address(hookModifyLiquidities));
        uint256 balance1HookBefore = currency1.balanceOf(address(hookModifyLiquidities));

        // hook collects liquidity in beforeSwap via hookData
        bytes memory calls = getCollectEncoded(tokenId, config, ZERO_BYTES);
        swap(key, true, -1e18, calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId, config);

        // liquidity unchanged
        assertEq(liquidity, initialLiquidity);

        // hook collected the fee revenue
        assertEq(currency0.balanceOf(address(hookModifyLiquidities)), balance0HookBefore + feeRevenue0 - 1 wei); // imprecision, core is keeping 1 wei
        assertEq(currency1.balanceOf(address(hookModifyLiquidities)), balance1HookBefore + feeRevenue1 - 1 wei);
    }

    /// @dev hook can burn liquidity with approval
    function test_hook_burn() public {
        // mint some liquidity that is NOT burned in beforeSwap
        mint(config, 100e18, address(this), ZERO_BYTES);

        // the position to be burned by the hook
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);
        // TODO: make this less jank since HookModifyLiquidites also has delta saving capabilities
        // BalanceDelta mintDelta = getLastDelta();
        BalanceDelta mintDelta = hookModifyLiquidities.deltas(hookModifyLiquidities.numberDeltasReturned() - 1);

        // approve the hook for burning liquidity
        lpm.approve(address(hookModifyLiquidities), tokenId);

        uint256 balance0HookBefore = currency0.balanceOf(address(hookModifyLiquidities));
        uint256 balance1HookBefore = currency1.balanceOf(address(hookModifyLiquidities));

        // hook burns liquidity in beforeSwap via hookData
        bytes memory calls = getBurnEncoded(tokenId, config, ZERO_BYTES);
        swap(key, true, -1e18, calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId, config);

        // liquidity burned
        assertEq(liquidity, 0);
        // 721 will revert if the token does not exist
        vm.expectRevert();
        lpm.ownerOf(tokenId);

        // hook claimed the burned liquidity
        assertEq(
            currency0.balanceOf(address(hookModifyLiquidities)),
            balance0HookBefore + uint128(-mintDelta.amount0() - 1 wei) // imprecision since core is keeping 1 wei
        );
        assertEq(
            currency1.balanceOf(address(hookModifyLiquidities)),
            balance1HookBefore + uint128(-mintDelta.amount1() - 1 wei)
        );
    }

    // --- Revert Scenarios --- //
    /// @dev Hook does not have approval so increasing liquidity should revert
    function test_hook_increaseLiquidity_revert() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        // hook decreases liquidity in beforeSwap via hookData
        uint256 liquidityToAdd = 10e18;
        bytes memory calls = getIncreaseEncoded(tokenId, config, liquidityToAdd, ZERO_BYTES);

        // should revert because hook is not approved
        vm.expectRevert(
            abi.encodeWithSelector(
                Hooks.Wrap__FailedHookCall.selector,
                address(hookModifyLiquidities),
                abi.encodeWithSelector(ICLPositionManager.NotApproved.selector, address(hookModifyLiquidities))
            )
        );
        swap(key, true, -1e18, calls);
    }

    /// @dev Hook does not have approval so decreasing liquidity should revert
    function test_hook_decreaseLiquidity_revert() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        // hook decreases liquidity in beforeSwap via hookData
        uint256 liquidityToDecrease = 10e18;
        bytes memory calls = getDecreaseEncoded(tokenId, config, liquidityToDecrease, ZERO_BYTES);

        // should revert because hook is not approved
        vm.expectRevert(
            abi.encodeWithSelector(
                Hooks.Wrap__FailedHookCall.selector,
                address(hookModifyLiquidities),
                abi.encodeWithSelector(ICLPositionManager.NotApproved.selector, address(hookModifyLiquidities))
            )
        );
        swap(key, true, -1e18, calls);
    }

    /// @dev hook does not have approval so collecting liquidity should revert
    function test_hook_collect_revert() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        // donate to generate revenue
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        router.donate(config.poolKey, feeRevenue0, feeRevenue1, ZERO_BYTES);

        // hook collects liquidity in beforeSwap via hookData
        bytes memory calls = getCollectEncoded(tokenId, config, ZERO_BYTES);

        // should revert because hook is not approved
        vm.expectRevert(
            abi.encodeWithSelector(
                Hooks.Wrap__FailedHookCall.selector,
                address(hookModifyLiquidities),
                abi.encodeWithSelector(ICLPositionManager.NotApproved.selector, address(hookModifyLiquidities))
            )
        );
        swap(key, true, -1e18, calls);
    }

    /// @dev hook does not have approval so burning liquidity should revert
    function test_hook_burn_revert() public {
        // the position to be burned by the hook
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        // hook burns liquidity in beforeSwap via hookData
        bytes memory calls = getBurnEncoded(tokenId, config, ZERO_BYTES);

        // should revert because hook is not approved
        vm.expectRevert(
            abi.encodeWithSelector(
                Hooks.Wrap__FailedHookCall.selector,
                address(hookModifyLiquidities),
                abi.encodeWithSelector(ICLPositionManager.NotApproved.selector, address(hookModifyLiquidities))
            )
        );
        swap(key, true, -1e18, calls);
    }

    /// @dev hook cannot re-enter modifyLiquiditiesWithoutUnlock in beforeRemoveLiquidity
    function test_hook_increaseLiquidity_reenter_revert() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        uint256 newLiquidity = 10e18;

        // to be provided as hookData, so beforeAddLiquidity attempts to increase liquidity
        bytes memory hookCall = getIncreaseEncoded(tokenId, config, newLiquidity, ZERO_BYTES);
        bytes memory calls = getIncreaseEncoded(tokenId, config, newLiquidity, hookCall);

        // should revert because hook is re-entering modifyLiquiditiesWithoutUnlock
        vm.expectRevert(
            abi.encodeWithSelector(
                Hooks.Wrap__FailedHookCall.selector,
                address(hookModifyLiquidities),
                abi.encodeWithSelector(ReentrancyLock.ContractLocked.selector)
            )
        );
        lpm.modifyLiquidities(calls, _deadline);
    }
}
