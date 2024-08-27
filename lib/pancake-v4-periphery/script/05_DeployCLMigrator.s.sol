// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {CLMigrator} from "../src/pool-cl/CLMigrator.sol";

/**
 * forge script script/05_DeployCLMigrator.s.sol:DeployCLMigratorScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract DeployCLMigratorScript is BaseScript {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address weth = getAddressFromConfig("weth");
        emit log_named_address("WETH", weth);

        address clPositionManager = getAddressFromConfig("clPositionManager");
        emit log_named_address("CLPositionManager", clPositionManager);

        address permit2 = getAddressFromConfig("permit2");
        emit log_named_address("Permit2", permit2);

        CLMigrator clMigrator = new CLMigrator(weth, clPositionManager, IAllowanceTransfer(permit2));
        emit log_named_address("CLMigrator", address(clMigrator));

        vm.stopBroadcast();
    }
}
