// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {DeployUniversalRouter} from "../../DeployUniversalRouter.s.sol";
import {RouterParameters} from "../../../src/base/RouterImmutables.sol";

/**
 * Step 1: Deploy
 * forge script script/deployParameters/mainnet/DeployBsc.s.sol:DeployBsc -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow
 *
 * Step 2: Verify - example_args.txt is the constructor arguments in the form of (args1, args2, args)
 * forge verify-contract <address> UniversalRouter --watch --chain 56 --constructor-args-path example_args.txt
 */
contract DeployBsc is DeployUniversalRouter {
    /// @notice contract address will be based on deployment salt
    function getDeploymentSalt() public pure override returns (bytes32) {
        return keccak256("INFINITY-UNIVERSAL-ROUTER/UniversalRouter/0.0001");
    }

    function setUp() public override {
        params = RouterParameters({
            permit2: 0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768,
            weth9: 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c,
            v2Factory: 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73,
            v3Factory: 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865,
            v3Deployer: 0x41ff9AA7e16B8B1a8a8dc4f0eFacd93D02d071c9,
            v2InitCodeHash: 0x00fb7f630766e6a796048ea87d01acd3068e8ff67d078148a3fa3f4a84f69bd5,
            v3InitCodeHash: 0x6ce8eb472fa82df5469c6ab6d485f17c3ad13c8cd7af59b3d4a8026c5ce0f7e2,
            stableFactory: 0x25a55f9f2279A54951133D503490342b50E5cd15,
            stableInfo: 0xf3A6938945E68193271Cad8d6f79B1f878b16Eb1,
            infiVault: UNSUPPORTED_PROTOCOL,
            infiClPoolManager: UNSUPPORTED_PROTOCOL,
            infiBinPoolManager: UNSUPPORTED_PROTOCOL,
            v3NFTPositionManager: UNSUPPORTED_PROTOCOL,
            infiClPositionManager: UNSUPPORTED_PROTOCOL,
            infiBinPositionManager: UNSUPPORTED_PROTOCOL
        });

        unsupported = 0x2979d1ea8f04C60423eb7735Cc3ed1BF74b565b8;
    }
}
