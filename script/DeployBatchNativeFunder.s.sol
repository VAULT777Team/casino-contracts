// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {console, Script} from "forge-std/Script.sol";
import {BatchNativeFunder} from "../contracts/BatchNativeFunder.sol";

contract DeployBatchNativeFunder is Script {
    function run() public returns (BatchNativeFunder funder) {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        funder = new BatchNativeFunder();
        vm.stopBroadcast();

        console.log("BatchNativeFunder:", address(funder));
    }
}
