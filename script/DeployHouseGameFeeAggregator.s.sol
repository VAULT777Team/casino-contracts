// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {console, Script} from "forge-std/Script.sol";
import {HouseGameFeeAggregator} from "../contracts/HouseGameFeeAggregator.sol";

contract DeployHouseGameFeeAggregator is Script {
    function run() public returns (HouseGameFeeAggregator aggregator) {
        HouseGameFeeAggregator.Game[] memory games = new HouseGameFeeAggregator.Game[](14);
        games[0] = _game("Coin Flip", "COIN_FLIP_ADDRESS");
        games[1] = _game("Dice", "DICE_ADDRESS");
        games[2] = _game("Video Poker", "VIDEO_POKER_ADDRESS");
        games[3] = _game("Blackjack", "BLACKJACK_ADDRESS");
        games[4] = _game("Plinko", "PLINKO_ADDRESS");
        games[5] = _game("Keno", "KENO_ADDRESS");
        games[6] = _game("Slots", "SLOTS_ADDRESS");
        games[7] = _game("Bonanza", "BONANZA_ADDRESS");
        games[8] = _game("Mines", "MINES_ADDRESS");
        games[9] = _game("Rock Paper Scissors", "ROCK_PAPER_SCISSORS_ADDRESS");
        games[10] = _game("Fortune Wheel", "FORTUNE_WHEEL_ADDRESS");
        games[11] = _game("Lottery", "LOTTERY_ADDRESS");
        games[12] = _game("American Roulette", "AMERICAN_ROULETTE_ADDRESS");
        games[13] = _game("European Roulette", "EUROPEAN_ROULETTE_ADDRESS");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        aggregator = new HouseGameFeeAggregator(games);
        vm.stopBroadcast();

        console.log("HouseGameFeeAggregator:", address(aggregator));
    }

    function _game(string memory name, string memory environmentKey)
        internal
        view
        returns (HouseGameFeeAggregator.Game memory)
    {
        return HouseGameFeeAggregator.Game(name, vm.envAddress(environmentKey));
    }
}
