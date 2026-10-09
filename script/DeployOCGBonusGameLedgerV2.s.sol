// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {OCGBonusGameLedgerV2} from "../contracts/games/bonus/OCGBonusGameLedgerV2.sol";

contract DeployOCGBonusGameLedgerV2 is Script {
    function run() external returns (OCGBonusGameLedgerV2 ledger) {
        address owner = vm.envAddress("BONUS_LEDGER_OWNER");
        address operator = vm.envAddress("BONUS_LEDGER_OPERATOR");
        address bonusContract = vm.envAddress("BONUS_1155_ADDRESS");
        uint256 maxPayoutMultiplierX = vm.envOr("BONUS_LEDGER_MAX_PAYOUT_MULTIPLIER_X", uint256(100_000));
        require(maxPayoutMultiplierX >= 100_000, "BONUS_PAYOUT_CAP_BELOW_GLOBAL_MAX");

        vm.startBroadcast();
        ledger = new OCGBonusGameLedgerV2(owner, operator, bonusContract);
        ledger.setMaxPayoutMultiplierX(maxPayoutMultiplierX);
        vm.stopBroadcast();
    }
}
