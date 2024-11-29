// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "forge-std/console2.sol";
import "forge-std/Script.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {QaSwapRouter} from "../src/QaSwapRouter.sol";

/**
 * Step 1: Deploy
 * forge script script/02_DeployQaSwapRouter.sol:DeployQaSwapRouter -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract DeployQaSwapRouter is Script {
    // ref: https://github.com/pancakeswap/pancake-v4-periphery/blob/main/script/config/bsc-testnet.json
    IVault vault = IVault(0xd557753bde3f0EaF32626F8681Ac6d8c1EBA2BBa);
    ICLPoolManager clPoolManager = ICLPoolManager(0x70890E308DCE727180ac1B9550928fED342dea52);
    IBinPoolManager binPoolManager = IBinPoolManager(0x68554d088F3640Bd2A7B38b43AE70FDcc16ef197);
    IAllowanceTransfer permit2 = IAllowanceTransfer(0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768);

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        QaSwapRouter router = new QaSwapRouter(vault, clPoolManager, binPoolManager, permit2);
        console2.log("QaSwapRouter :", address(router));

        vm.stopBroadcast();
    }
}
