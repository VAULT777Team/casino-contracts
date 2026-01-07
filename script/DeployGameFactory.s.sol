// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {GameFactory} from "../contracts/sdk/GameFactory.sol";
import {BankLP} from "../contracts/bankroll/facets/BankLP.sol";
import {GameOwnershipNFT} from "../contracts/sdk/GameOwnershipNFT.sol";
import {GameRegistry} from "../contracts/sdk/GameRegistry.sol";

contract DeployGameFactory is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying GameFactory...");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Load addresses from environment or deploy new ones
        address banklp = vm.envAddress("BANKLP");
        address nft = vm.envAddress("GAME_NFT");
        address registry = vm.envAddress("GAME_REGISTRY");

        // If not set, deploy new NFT and registry
        if (nft == address(0)) {
            GameOwnershipNFT nftContract = new GameOwnershipNFT();
            nft = address(nftContract);
            console.log("GameOwnershipNFT deployed:", nft);
        }
        if (registry == address(0)) {
            GameRegistry registryContract = new GameRegistry();
            registry = address(registryContract);
            console.log("GameRegistry deployed:", registry);
        }

        // Deploy GameFactory
        GameFactory factory = new GameFactory(nft, registry);
        console.log("GameFactory deployed:", address(factory));

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("GameOwnershipNFT:", nft);
        console.log("GameRegistry:", registry);
        console.log("BankLP:", banklp);
        console.log("GameFactory:", address(factory));
        console.log("=========================");
    }
}
