// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {DeployUniversalRouter} from "../../DeployUniversalRouter.s.sol";
import {RouterParameters} from "../../../src/base/RouterImmutables.sol";

/**
 * Step 1: Deploy
 * forge script script/deployParameters/testnet/DeployEthSepolia.s.sol:DeployEthSepolia -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow
 *
 * Step 2: Verify - example_args.txt is the constructor arguments in the form of (args1, args2, args)
 * forge verify-contract <address> UniversalRouter --watch --chain 11155111 --constructor-args-path ./script/deployParameters/testnet/args/eth_sepolia.txt
 */
contract DeployEthSepolia is DeployUniversalRouter {
    /// @notice contract address will be based on deployment salt
    function getDeploymentSalt() public pure override returns (bytes32) {
        return keccak256("INFINITY-UNIVERSAL-ROUTER/UniversalRouter/0.0001");
    }

    // ref from v3 universal router: https://sepolia.etherscan.io/tx/0xb4610521d3fc61f4837edbd899acb6c33a5fe0f3bb32ab84745ac0a8b1859906
    // and from pancake-frontend config
    function setUp() public override {
        params = RouterParameters({
            permit2: 0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768,
            weth9: 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14,
            v2Factory: 0x1bdc540dEB9Ed1fA29964DeEcCc524A8f5e2198e,
            v3Factory: 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865,
            v3Deployer: 0x41ff9AA7e16B8B1a8a8dc4f0eFacd93D02d071c9,
            v2InitCodeHash: 0xd0d4c4cd0848c93cb4fd1f498d7013ee6bfb25783ea21593d5834f5d250ece66,
            v3InitCodeHash: 0x6ce8eb472fa82df5469c6ab6d485f17c3ad13c8cd7af59b3d4a8026c5ce0f7e2,
            stableFactory: UNSUPPORTED_PROTOCOL,
            stableInfo: UNSUPPORTED_PROTOCOL,
            infiVault: 0x4670F769Daa625FF5F89719AE5295E9824f5805f,
            infiClPoolManager: 0xD4EAc75ee0E76EAD6AC6995DF30CA14b38549682,
            infiBinPoolManager: 0x0Ca8430E263A098B998E47e0544C2C82B30CbDB1,
            v3NFTPositionManager: 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364,
            infiClPositionManager: 0x53C9802F47295979c0E154779eD10fa6af27D7cA,
            infiBinPositionManager: 0x21015eF9927e06b7Fc19D986A214e449Aa22FF7d
        });

        unsupported = 0x6879F5C1AdaDDF29892bf650F9C48350C12795D9;
    }
}
