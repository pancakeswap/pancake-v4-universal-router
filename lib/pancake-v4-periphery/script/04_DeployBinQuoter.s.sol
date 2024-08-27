// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {BinQuoter} from "../src/pool-bin/lens/BinQuoter.sol";

/**
 * forge script script/04_DeployBinQuoter.s.sol:DeployBinQuoterScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract DeployBinQuoterScript is BaseScript {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address binPoolManager = getAddressFromConfig("binPoolManager");
        emit log_named_address("BinPoolManager", binPoolManager);

        BinQuoter binQuoter = new BinQuoter(binPoolManager);
        emit log_named_address("BinQuoter", address(binQuoter));

        vm.stopBroadcast();
    }
}
