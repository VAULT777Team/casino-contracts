// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {console, Script} from "forge-std/Script.sol";

import {HouseGameLedger} from "../contracts/games/house/HouseGameLedger.sol";

contract DeployHouseGameLedger is Script {
    function run() public returns (HouseGameLedger ledger) {
        address owner = vm.envAddress("HOUSE_LEDGER_OWNER");
        address operator = vm.envAddress("HOUSE_LEDGER_OPERATOR");
        address registry = vm.envAddress("BANKLP_REGISTRY_ADDRESS");
        uint256 refundDelay = vm.envOr("HOUSE_LEDGER_REFUND_DELAY", uint256(10 minutes));
        require(refundDelay >= 5 minutes, "refund delay below contract minimum");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        ledger = new HouseGameLedger(owner, operator, registry, refundDelay);
        vm.stopBroadcast();

        console.log("HouseGameLedger:", address(ledger));
        console.log("Protocol version:", ledger.PROTOCOL_VERSION());
    }
}
