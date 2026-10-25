// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vault777Lottery} from "../contracts/games/lottery/Vault777Lottery.sol";

contract DeployVault777Lottery is Script {
    function run() public returns (Vault777Lottery lottery) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        IERC20 lotteryToken = IERC20(vm.envAddress("LOTTERY_TOKEN"));
        address admin = vm.envAddress("LOTTERY_ADMIN");
        address operator = vm.envAddress("LOTTERY_OPERATOR");
        address houseRecipient = vm.envAddress("LOTTERY_HOUSE_RECIPIENT");

        vm.startBroadcast(deployerPrivateKey);
        lottery = new Vault777Lottery(lotteryToken, admin, operator, houseRecipient);
        vm.stopBroadcast();

        console.log("Vault777Lottery deployed to:", address(lottery));
    }
}
