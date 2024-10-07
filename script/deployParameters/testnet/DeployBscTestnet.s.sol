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
            stableInfo: 0x0A548d59D04096Bc01206D58C3D63c478e1e06dB,
            v4Vault: 0x0a125Bb36e409957Ed951eF1FBe20e81D682EAb6,
            v4ClPoolManager: 0x26Ca53c8C5CE90E22aA1FadDA68AB9a08f7BA06f,
            v4BinPoolManager: 0x1DF0be383e9d17DA4448E57712849aBE5b3Fa33b,
            v3NFTPositionManager: 0x427bF5b37357632377eCbEC9de3626C71A5396c1,
            v4ClPositionManager: 0x095bd2cf90ef113aa8c53904cE54C17f4583046d,
            v4BinPositionManager: 0x26008c91a2D47147d6739db3fFd3598A27da859d
        });

        unsupported = 0xe4da88F38C11C1450c720b8aDeDd94956610a4e5;
    }
}
