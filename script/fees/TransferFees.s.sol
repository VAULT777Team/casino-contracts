// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {console, Script} from "forge-std/Script.sol";

interface ISubscriptionManager {
    function addConsumer(
        uint256 subscriptionId,
        address consumer
    ) external;

    function fundSubscriptionWithNative(
        uint256 subscriptionId
    ) external payable;
}


interface IGame {
    function VRFFees() external view returns (uint256);
    function transferFees(
        address to
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
    address fortuneWheel;
    address lottery;
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
        fortuneWheel = vm.envAddress("FORTUNE_WHEEL_ADDRESS");
        lottery = vm.envAddress("LOTTERY_ADDRESS");
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

        uint256 totalFees = 0;
        
        totalFees += IGame(coinflip).VRFFees();
        totalFees += IGame(dice).VRFFees();
        totalFees += IGame(videoPoker).VRFFees();
        totalFees += IGame(blackjack).VRFFees();
        totalFees += IGame(plinko).VRFFees();
        totalFees += IGame(keno).VRFFees();
        totalFees += IGame(slots).VRFFees();
        totalFees += IGame(mines).VRFFees();
        totalFees += IGame(rockPaperScissors).VRFFees();
        totalFees += IGame(fortuneWheel).VRFFees();
        totalFees += IGame(lottery).VRFFees();
        totalFees += IGame(americanRoulette).VRFFees();
        totalFees += IGame(europeanRoulette).VRFFees(); 

        console.log("Total VRF Fees combined on all games:", totalFees);
        IGame(coinflip).transferFees(address(msg.sender));
        console.log("Transferred fees CoinFlip:", coinflip);

        IGame(dice).transferFees(address(msg.sender));
        console.log("Transferred fees Dice:", dice);

        IGame(videoPoker).transferFees(address(msg.sender));
        console.log("Transferred fees VideoPoker:", videoPoker);

        IGame(blackjack).transferFees(address(msg.sender));
        console.log("Transferred fees Blackjack:", blackjack);

        IGame(plinko).transferFees(address(msg.sender));
        console.log("Transferred fees Plinko:", plinko);

        IGame(slots).transferFees(address(msg.sender));
        console.log("Transferred fees Slots:", slots);

        IGame(rockPaperScissors).transferFees(address(msg.sender));
        console.log("Transferred fees RockPaperScissors:", rockPaperScissors);

        IGame(fortuneWheel).transferFees(address(msg.sender));
        console.log("Transferred fees FortuneWheel:", fortuneWheel);

        //IBankLP(BANK_LP).setGame(lottery, true);
        //ISubscriptionManager(VRF_ADDRESS).addConsumer(VRF_SUB_ID, lottery);
        //console.log("Enabled Lottery:", lottery);

        console.log("");
        console.log("========================================");
        console.log("Transferring fees for Roulette Games");
        console.log("========================================");
        console.log("");

        IGame(americanRoulette).transferFees(address(msg.sender));
        console.log("Transferred fees AmericanRoulette:", americanRoulette);
        
        IGame(europeanRoulette).transferFees(address(msg.sender));
        console.log("Transferred fees EuropeanRoulette:", europeanRoulette);
        
        console.log("");
        console.log("========================================");
        console.log("Funding VRF Subscription with combined fees: ", totalFees);
        console.log("========================================");
        console.log("");

        ISubscriptionManager(VRF_ADDRESS).fundSubscriptionWithNative{value: totalFees}(VRF_SUB_ID);
        
        console.log("Funded VRF Subscription with balance:", totalFees);
        console.log("========================================");

        vm.stopBroadcast();
    }
}
