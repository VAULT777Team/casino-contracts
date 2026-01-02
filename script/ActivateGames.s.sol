// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {console, Script} from "forge-std/Script.sol";

import {IBankLP} from "../contracts/bankroll/interfaces/IBankLP.sol";

interface ISubscriptionManager {
    function addConsumer(
        uint256 subscriptionId,
        address consumer
    ) external;
}

contract ActivateGames is Script {
    // Core infrastructure addresses (from .env)
    address BANK_LP;
    address VRF_ADDRESS;
    uint256 VRF_SUB_ID;

    // Deployed game addresses
    address coinflip;
    address dice;
    address videoPoker;
    address blackjack;
    address plinko;
    address keno;
    address slots;
    address mines;
    address rockPaperScissors;
    address americanRoulette;
    address europeanRoulette;

    function setUp() public {
        // Load addresses from environment
        BANK_LP = vm.envAddress("BANKLP_ADDRESS");
        VRF_ADDRESS = vm.envAddress("VRF_ADDRESS");
        VRF_SUB_ID = vm.envUint("VRF_SUBSCRIPTION_ID");

        coinflip = vm.envAddress("COIN_FLIP_ADDRESS");
        dice = vm.envAddress("DICE_ADDRESS");
        videoPoker = vm.envAddress("VIDEO_POKER_ADDRESS");
        blackjack = vm.envAddress("BLACKJACK_ADDRESS");
        plinko = vm.envAddress("PLINKO_ADDRESS");
        keno = vm.envAddress("KENO_ADDRESS");
        slots = vm.envAddress("SLOTS_ADDRESS");
        mines = vm.envAddress("MINES_ADDRESS");
        rockPaperScissors = vm.envAddress("ROCK_PAPER_SCISSORS_ADDRESS");
        americanRoulette = vm.envAddress("AMERICAN_ROULETTE_ADDRESS");
        europeanRoulette = vm.envAddress("EUROPEAN_ROULETTE_ADDRESS");
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);

        console.log("================================");
        console.log("Enabling all Casino Game Contracts");
        console.log("================================");
        console.log("");

        // Activate each game
        IBankLP(BANK_LP).setGame(coinflip, true);
        ISubscriptionManager(VRF_ADDRESS).addConsumer(VRF_SUB_ID, coinflip);
        console.log("Enabled CoinFlip:", coinflip);

        IBankLP(BANK_LP).setGame(dice, true);
        ISubscriptionManager(VRF_ADDRESS).addConsumer(VRF_SUB_ID, dice);
        console.log("Enabled Dice:", dice);

        IBankLP(BANK_LP).setGame(videoPoker, true);
        ISubscriptionManager(VRF_ADDRESS).addConsumer(VRF_SUB_ID, videoPoker);
        console.log("Enabled VideoPoker:", videoPoker);

        IBankLP(BANK_LP).setGame(blackjack, true);
        ISubscriptionManager(VRF_ADDRESS).addConsumer(VRF_SUB_ID, blackjack);
        console.log("Enabled Blackjack:", blackjack);

        IBankLP(BANK_LP).setGame(plinko, true);
        ISubscriptionManager(VRF_ADDRESS).addConsumer(VRF_SUB_ID, plinko);
        console.log("Enabled Plinko:", plinko);

        IBankLP(BANK_LP).setGame(keno, true);
        ISubscriptionManager(VRF_ADDRESS).addConsumer(VRF_SUB_ID, keno);
        console.log("Enabled Keno:", keno);

        IBankLP(BANK_LP).setGame(slots, true);
        ISubscriptionManager(VRF_ADDRESS).addConsumer(VRF_SUB_ID, slots);
        console.log("Enabled Slots:", slots);

        IBankLP(BANK_LP).setGame(mines, true);
        ISubscriptionManager(VRF_ADDRESS).addConsumer(VRF_SUB_ID, mines);
        console.log("Enabled Mines:", mines);

        IBankLP(BANK_LP).setGame(rockPaperScissors, true);
        ISubscriptionManager(VRF_ADDRESS).addConsumer(VRF_SUB_ID, rockPaperScissors);
        console.log("Enabled RockPaperScissors:", rockPaperScissors);

        console.log("");
        console.log("========================================");
        console.log("Enabling Roulette Games");
        console.log("========================================");
        console.log("");
        IBankLP(BANK_LP).setGame(americanRoulette, true);
        console.log("Enabled AmericanRoulette:", americanRoulette);
        IBankLP(BANK_LP).setGame(europeanRoulette, true);
        console.log("Enabled EuropeanRoulette:", europeanRoulette);
        vm.stopBroadcast();
        console.log("");
        console.log("========================================");
    }
}
