// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {BinMigrator} from "../src/pool-bin/BinMigrator.sol";

/**
 * forge script script/06_DeployBinMigrator.s.sol:DeployBinMigratorScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract DeployBinMigratorScript is BaseScript {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address weth = getAddressFromConfig("weth");
        emit log_named_address("WETH", weth);

        address binPositionManager = getAddressFromConfig("binPositionManager");
        emit log_named_address("BinPositionManager", binPositionManager);

        address permit2 = getAddressFromConfig("permit2");
        emit log_named_address("Permit2", permit2);

        BinMigrator binMigrator = new BinMigrator(weth, binPositionManager, IAllowanceTransfer(permit2));
        emit log_named_address("BinMigrator", address(binMigrator));

        vm.stopBroadcast();
    }
}
