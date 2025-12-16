// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../contracts/CoinFlip.sol";
import "../contracts/Dice.sol";
import "../contracts/VideoPoker.sol";
import "../contracts/Blackjack.sol";
import "../contracts/Plinko.sol";
import "../contracts/Keno.sol";
import "../contracts/Slots.sol";
import "../contracts/Mines.sol";
import "../contracts/RockPaperScissors.sol";
import "../contracts/games/Roulette/AmericanRoulette.sol";
import "../contracts/games/Roulette/EuropeanRoulette.sol";

contract TransferAllGames is Script {
    // Core infrastructure addresses (from .env)
    address bankLP;
    address vrfCoordinator;
    address linkEthFeed;
    address forwarder;

    // Deployed game addresses
    address public coinFlip;
    address public dice;
    address public videoPoker;
    address public blackjack;
    address public plinko;
    address public keno;
    address public slots;
    address public mines;
    address public rockPaperScissors;
    address public americanRoulette;
    address public europeanRoulette;

    function setUp() public {
        // Load addresses from environment
        bankLP = vm.envAddress("BANKLP_ADDRESS");
        vrfCoordinator = vm.envAddress("VRF_ADDRESS");
        linkEthFeed = vm.envAddress("LINK_ETH_FEED_ADDRESS");
        forwarder = vm.envAddress("FORWARDER_ADDRESS");

        coinFlip            = vm.envAddress("COIN_FLIP_ADDRESS");
        rockPaperScissors   = vm.envAddress("ROCK_PAPER_SCISSORS_ADDRESS");
        dice                = vm.envAddress("DICE_ADDRESS");

        videoPoker          = vm.envAddress("VIDEO_POKER_ADDRESS");
        blackjack           = vm.envAddress("BLACKJACK_ADDRESS");

        plinko              = vm.envAddress("PLINKO_ADDRESS");
        slots               = vm.envAddress("SLOTS_ADDRESS");

        mines               = vm.envAddress("MINES_ADDRESS");
        keno                = vm.envAddress("KENO_ADDRESS");

        americanRoulette    = vm.envAddress("AMERICAN_ROULETTE_ADDRESS");
        europeanRoulette    = vm.envAddress("EUROPEAN_ROULETTE_ADDRESS");
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address newOwner = vm.envAddress("ADDRESS_NEW_OWNERSHIP");
        
        vm.startBroadcast(deployerPrivateKey);

        console.log("================================");
        console.log("Transferring Casino Game Contracts to ", newOwner);
        console.log("================================");
        console.log("");

        CoinFlip(coinFlip).transferOwnership(newOwner);
        Dice(dice).transferOwnership(newOwner);
        RockPaperScissors(rockPaperScissors).transferOwnership(newOwner);

        VideoPoker(videoPoker).transferOwnership(newOwner);
        Blackjack(blackjack).transferOwnership(newOwner);

        Plinko(plinko).transferOwnership(newOwner);
        Slots(slots).transferOwnership(newOwner);

        Mines(mines).transferOwnership(newOwner);
        Keno(keno).transferOwnership(newOwner);

        AmericanRoulette(americanRoulette).transferOwnership(newOwner);
        EuropeanRoulette(europeanRoulette).transferOwnership(newOwner);

    }
}
