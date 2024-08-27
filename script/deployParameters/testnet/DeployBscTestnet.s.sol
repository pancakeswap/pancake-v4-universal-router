// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {DeployUniversalRouter} from "../../DeployUniversalRouter.s.sol";
import {RouterParameters} from "../../../src/base/RouterImmutables.sol";

/**
 * forge script script/deployParameters/testnet/DeployBscTestnet.s.sol:DeployBscTestnet -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract DeployBscTestnet is DeployUniversalRouter {
    // ref from v3 universal router: https://testnet.bscscan.com/tx/0xdfab014e4f5df56d5a8b16375028ad0340f80070bd848eb57c4e0baf41210487
    function setUp() public override {
        params = RouterParameters({
            permit2: 0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768,
            weth9: 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd,
            v2Factory: 0x6725F303b657a9451d8BA641348b6761A6CC7a17,
            v3Factory: 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865,
            v3Deployer: 0x41ff9AA7e16B8B1a8a8dc4f0eFacd93D02d071c9,
            v2InitCodeHash: 0xd0d4c4cd0848c93cb4fd1f498d7013ee6bfb25783ea21593d5834f5d250ece66,
            v3InitCodeHash: 0x6ce8eb472fa82df5469c6ab6d485f17c3ad13c8cd7af59b3d4a8026c5ce0f7e2,
            stableFactory: 0xe6A00f8b819244e8Ab9Ea930e46449C2F20B6609,
            stableInfo: 0xe6A00f8b819244e8Ab9Ea930e46449C2F20B6609,
            v4Vault: 0x08F012b8E2f3021db8bd2A896A7F422F4041F131,
            v4ClPoolManager: 0x969D90aC74A1a5228b66440f8C8326a8dA47A5F9,
            v4BinPoolManager: 0x437ef7C8C00d20a8535ae1786c5800c88413e7Af,
            v3NFTPositionManager: 0x427bF5b37357632377eCbEC9de3626C71A5396c1,
            v4ClPositionManager: 0x89A7D45D007077485CB5aE2abFB740b1fe4FF574,
            v4BinPositionManager: 0xfB84c0D67f217f078E949d791b8d3081FE91Bca2
        });

        unsupported = 0xe4da88F38C11C1450c720b8aDeDd94956610a4e5;
    }
}
