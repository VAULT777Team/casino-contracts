// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {console, Script} from "forge-std/Script.sol";

import {IEntryPoint} from "../contracts/aa/interfaces/IEntryPoint.sol";
import {IAccount} from "../contracts/aa/interfaces/IAccount.sol";
import {AccountFactory} from "../contracts/aa/AccountFactory.sol";

contract DeployOneClickPlay is Script {
    function run() external {
        vm.startBroadcast();

        IEntryPoint entryPoint = IEntryPoint(0x0000000071727De22E5E9d8BAf0edAc6f37da032);
        AccountFactory factory = new AccountFactory(
            address(entryPoint)
        );

        console.log("Deploying OneClickPlay account for", msg.sender);
        address account = factory.createAccount(msg.sender, 0);
        console.log("Deployed OneClickPlay account at:", account);


        vm.stopBroadcast();
    }
}