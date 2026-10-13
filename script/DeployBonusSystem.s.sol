// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console, Script} from "forge-std/Script.sol";

import {Bonus1155} from "../contracts/games/bonus/Bonus1155.sol";
import {BonusGameLedger} from "../contracts/games/bonus/BonusGameLedger.sol";

contract DeployBonusSystem is Script {
    function run() external returns (Bonus1155 bonus, BonusGameLedger ledger) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address owner = vm.envAddress("BONUS_OWNER");
        address operator = vm.envAddress("BONUS_LEDGER_OPERATOR");
        address registry = vm.envAddress("BANKLP_REGISTRY_ADDRESS");
        address backendSigner = vm.envAddress("BONUS_BACKEND_SIGNER");
        string memory uri = vm.envString("BONUS_1155_URI");
        uint256 maxPayoutMultiplierX = vm.envOr("BONUS_LEDGER_MAX_PAYOUT_MULTIPLIER_X", uint256(100_000));

        require(owner != address(0), "ZERO_OWNER");
        require(operator != address(0), "ZERO_OPERATOR");
        require(registry != address(0), "ZERO_REGISTRY");
        require(backendSigner != address(0), "ZERO_SIGNER");
        require(bytes(uri).length != 0, "EMPTY_URI");
        require(maxPayoutMultiplierX >= 100_000, "BONUS_PAYOUT_CAP_BELOW_GLOBAL_MAX");

        vm.startBroadcast(privateKey);

        bonus = new Bonus1155(uri, registry, backendSigner);
        ledger = new BonusGameLedger(deployer, operator, address(bonus));
        ledger.setMaxPayoutMultiplierX(maxPayoutMultiplierX);
        bonus.setBonusGameLedger(address(ledger));

        if (owner != deployer) {
            ledger.transferOwnership(owner);
            bonus.transferOwnership(owner);
        }

        vm.stopBroadcast();

        console.log("Bonus1155:", address(bonus));
        console.log("BonusGameLedger:", address(ledger));
        console.log("Owner:", owner);
        console.log("Operator:", operator);
        console.log("Max payout multiplier X:", maxPayoutMultiplierX);
    }
}
