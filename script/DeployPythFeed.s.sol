// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {PythAggregatorV3} from "@pythnetwork/pyth-sdk-solidity/PythAggregatorV3.sol";

contract DeployPythFeed is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Constructor arguments
        address pythEvmContract = 0xff1a0f4744e8582DF1aE09D5611b887B6a12925C;
        bytes32 pythPriceFeedId = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
        
        // Deploy PythAggregatorV3
        PythAggregatorV3 pythAggregator = new PythAggregatorV3(
            pythEvmContract,
            pythPriceFeedId
        );
        
        console.log("PythAggregatorV3 deployed at:", address(pythAggregator));
        console.log("Pyth EVM Contract:", pythEvmContract);
        console.log("Price Feed ID:", vm.toString(pythPriceFeedId));
        
        vm.stopBroadcast();
    }
}
