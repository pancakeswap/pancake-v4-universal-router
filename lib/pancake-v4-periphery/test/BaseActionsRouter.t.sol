//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {MockBaseActionsRouter} from "./mocks/MockBaseActionsRouter.sol";
import {Planner, Plan} from "../src/libraries/Planner.sol";
import {Actions} from "../src/libraries/Actions.sol";
import {ActionConstants} from "../src/libraries/ActionConstants.sol";
import {Test} from "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {IVault, Vault} from "pancake-v4-core/src/Vault.sol";

contract BaseActionsRouterTest is Test, GasSnapshot {
    using Planner for Plan;

    MockBaseActionsRouter router;

    function setUp() public {
        IVault vault = new Vault();
        router = new MockBaseActionsRouter(vault);
    }

    function test_Swap_suceeds() public {
        Plan memory plan = Planner.init();
        for (uint256 i = 0; i < 5; i++) {
            plan.add(Actions.CL_SWAP_EXACT_IN, "");
            plan.add(Actions.BIN_SWAP_EXACT_IN, "");
        }

        bytes memory data = plan.encode();

        assertEq(router.clSwapCount(), 0);
        assertEq(router.binSwapCount(), 0);
        router.executeActions(data);
        snapLastCall("BaseActionsRouter_mock10commands");
        assertEq(router.clSwapCount(), 5);
        assertEq(router.binSwapCount(), 5);
    }

    function test_increaseLiquidity_suceeds() public {
        Plan memory plan = Planner.init();
        for (uint256 i = 0; i < 5; i++) {
            plan.add(Actions.CL_INCREASE_LIQUIDITY, "");
            plan.add(Actions.BIN_ADD_LIQUIDITY, "");
        }

        assertEq(router.clIncreaseLiqCount(), 0);
        assertEq(router.binAddLiqCount(), 0);

        bytes memory data = plan.encode();
        router.executeActions(data);

        assertEq(router.clIncreaseLiqCount(), 5);
        assertEq(router.binAddLiqCount(), 5);
    }

    function test_decreaseLiquidity_suceeds() public {
        Plan memory plan = Planner.init();
        for (uint256 i = 0; i < 5; i++) {
            plan.add(Actions.CL_DECREASE_LIQUIDITY, "");
            plan.add(Actions.BIN_REMOVE_LIQUIDITY, "");
        }

        assertEq(router.clDecreaseLiqCount(), 0);
        assertEq(router.binRemoveLiqCount(), 0);

        bytes memory data = plan.encode();
        router.executeActions(data);

        assertEq(router.clDecreaseLiqCount(), 5);
        assertEq(router.binRemoveLiqCount(), 5);
    }

    function test_donate_suceeds() public {
        Plan memory plan = Planner.init();
        for (uint256 i = 0; i < 5; i++) {
            plan.add(Actions.CL_DONATE, "");
            plan.add(Actions.BIN_DONATE, "");
        }

        assertEq(router.clDonateCount(), 0);
        assertEq(router.binDonateCount(), 0);

        bytes memory data = plan.encode();
        router.executeActions(data);

        assertEq(router.clDonateCount(), 5);
        assertEq(router.binDonateCount(), 5);
    }

    function test_clear_suceeds() public {
        Plan memory plan = Planner.init();
        for (uint256 i = 0; i < 10; i++) {
            plan.add(Actions.CLEAR_OR_TAKE, "");
        }

        assertEq(router.clearCount(), 0);

        bytes memory data = plan.encode();
        router.executeActions(data);
        assertEq(router.clearCount(), 10);
    }

    function test_settle_suceeds() public {
        Plan memory plan = Planner.init();
        for (uint256 i = 0; i < 10; i++) {
            plan.add(Actions.SETTLE, "");
        }

        assertEq(router.settleCount(), 0);

        bytes memory data = plan.encode();
        router.executeActions(data);
        assertEq(router.settleCount(), 10);
    }

    function test_take_suceeds() public {
        Plan memory plan = Planner.init();
        for (uint256 i = 0; i < 10; i++) {
            plan.add(Actions.TAKE, "");
        }

        assertEq(router.takeCount(), 0);

        bytes memory data = plan.encode();
        router.executeActions(data);
        assertEq(router.takeCount(), 10);
    }

    function test_mint_suceeds() public {
        Plan memory plan = Planner.init();
        for (uint256 i = 0; i < 10; i++) {
            plan.add(Actions.MINT_6909, "");
        }

        assertEq(router.mintCount(), 0);

        bytes memory data = plan.encode();
        router.executeActions(data);
        assertEq(router.mintCount(), 10);
    }

    function test_burn_suceeds() public {
        Plan memory plan = Planner.init();
        for (uint256 i = 0; i < 10; i++) {
            plan.add(Actions.BURN_6909, "");
        }

        assertEq(router.burnCount(), 0);

        bytes memory data = plan.encode();
        router.executeActions(data);
        assertEq(router.burnCount(), 10);
    }

    function test_fuzz_mapRecipient(address recipient) public view {
        address mappedRecipient = router.mapRecipient(recipient);
        if (recipient == ActionConstants.MSG_SENDER) {
            assertEq(mappedRecipient, address(0xdeadbeef));
        } else if (recipient == ActionConstants.ADDRESS_THIS) {
            assertEq(mappedRecipient, address(router));
        } else {
            assertEq(mappedRecipient, recipient);
        }
    }
}
