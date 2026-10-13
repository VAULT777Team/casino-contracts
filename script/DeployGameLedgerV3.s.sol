// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {console, Script} from "forge-std/Script.sol";

import {GameLedgerV3} from "../contracts/games/ocg/GameLedger.sol";

contract DeployGameLedgerV3 is Script {
    function run() external returns (GameLedgerV3 ledger) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address owner = vm.envAddress("GAME_LEDGER_V3_OWNER");
        address operator = vm.envAddress("GAME_LEDGER_V3_OPERATOR");
        address registry = vm.envAddress("BANKLP_REGISTRY_ADDRESS");
        uint256 maxPayoutMultiplierX = vm.envOr("GAME_LEDGER_V3_MAX_PAYOUT_MULTIPLIER_X", uint256(100));
        uint256 cancelTimeframe = vm.envOr("GAME_LEDGER_V3_CANCEL_TIMEFRAME", uint256(10 minutes));

        require(owner != address(0), "ZERO_OWNER");
        require(operator != address(0), "ZERO_OPERATOR");
        require(registry != address(0), "ZERO_REGISTRY");
        require(maxPayoutMultiplierX >= 1, "PAYOUT_CAP_TOO_LOW");

        vm.startBroadcast(privateKey);

        ledger = new GameLedgerV3(operator, registry);
        if (maxPayoutMultiplierX != ledger.maxPayoutMultiplierX()) {
            ledger.setMaxPayoutMultiplierX(maxPayoutMultiplierX);
        }
        if (cancelTimeframe != ledger.cancelTimeframe()) {
            ledger.setCancelTimeframe(cancelTimeframe);
        }
        if (owner != deployer) {
            ledger.transferOwnership(owner);
        }

        vm.stopBroadcast();

        console.log("GameLedgerV3:", address(ledger));
        console.log("Owner:", owner);
        console.log("Operator:", operator);
        console.log("Bankroll registry:", registry);
        console.log("Max payout multiplier X:", maxPayoutMultiplierX);
    }
}
