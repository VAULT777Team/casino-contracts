// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {console, Script} from "forge-std/Script.sol";
import {CoinFlip} from "../contracts/CoinFlip.sol";
import {Dice} from "../contracts/Dice.sol";
import {VideoPoker} from "../contracts/VideoPoker.sol";
import {Blackjack} from "../contracts/Blackjack.sol";
import {Plinko} from "../contracts/Plinko.sol";
import {Keno} from "../contracts/Keno.sol";
import {Slots} from "../contracts/Slots.sol";
import {Mines} from "../contracts/Mines.sol";
import {RockPaperScissors} from "../contracts/RockPaperScissors.sol";
import {AmericanRoulette} from "../contracts/games/Roulette/AmericanRoulette.sol";
import {EuropeanRoulette} from "../contracts/games/Roulette/EuropeanRoulette.sol";

contract DeployAllGames is Script {
    // Core infrastructure addresses (from .env)
    address BANK_LP;
    address BANKLP_REGISTRY;
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
        BANK_LP = vm.envAddress("BANKLP_ADDRESS");
        BANKLP_REGISTRY = vm.envAddress("BANKLP_REGISTRY_ADDRESS");
        vrfCoordinator = vm.envAddress("VRF_ADDRESS");
        linkEthFeed = vm.envAddress("LINK_ETH_FEED_ADDRESS");
        forwarder = vm.envAddress("FORWARDER_ADDRESS");
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);

        console.log("================================");
        console.log("Deploying Casino Game Contracts");
        console.log("================================");
        console.log("");

        // Deploy games without configs
        console.log("Deploying CoinFlip...");
        coinFlip = address(new CoinFlip(BANKLP_REGISTRY, vrfCoordinator, linkEthFeed, forwarder));
        console.log("CoinFlip deployed to:", coinFlip);
        console.log("");

        console.log("Deploying RockPaperScissors...");
        rockPaperScissors = address(new RockPaperScissors(BANKLP_REGISTRY, vrfCoordinator, linkEthFeed, forwarder));
        console.log("RockPaperScissors deployed to:", rockPaperScissors);
        console.log("");

        console.log("Deploying Dice...");
        dice = address(new Dice(BANKLP_REGISTRY, vrfCoordinator, linkEthFeed, forwarder));
        console.log("Dice deployed to:", dice);
        console.log("");

        console.log("Deploying VideoPoker...");
        videoPoker = address(new VideoPoker(BANKLP_REGISTRY, vrfCoordinator, linkEthFeed, forwarder));
        console.log("VideoPoker deployed to:", videoPoker);
        console.log("");

        console.log("Deploying Blackjack...");
        blackjack = address(new Blackjack(BANKLP_REGISTRY, vrfCoordinator, linkEthFeed, forwarder));
        console.log("Blackjack deployed to:", blackjack);
        console.log("");

        console.log("Deploying Plinko...");
        plinko = address(new Plinko(BANKLP_REGISTRY, vrfCoordinator, linkEthFeed, forwarder));
        console.log("Plinko deployed to:", plinko);
        console.log("");

        console.log("Deploying Keno...");
        keno = address(new Keno(BANKLP_REGISTRY, vrfCoordinator, linkEthFeed, forwarder));
        console.log("Keno deployed to:", keno);
        console.log("");

        console.log("Deploying AmericanRoulette...");
        americanRoulette = address(new AmericanRoulette(BANKLP_REGISTRY, vrfCoordinator, linkEthFeed, forwarder));
        console.log("AmericanRoulette deployed to:", americanRoulette);
        console.log("");

        console.log("Deploying EuropeanRoulette...");
        europeanRoulette = address(new EuropeanRoulette(BANKLP_REGISTRY, vrfCoordinator, linkEthFeed, forwarder));
        console.log("EuropeanRoulette deployed to:", europeanRoulette);
        console.log("");

        // Deploy games with configs
        console.log("Deploying Slots...");
        uint16[] memory slotsMultipliers = new uint16[](57);
        slotsMultipliers[0] = 5; slotsMultipliers[1] = 3; slotsMultipliers[2] = 3;
        slotsMultipliers[3] = 3; slotsMultipliers[4] = 3; slotsMultipliers[5] = 3;
        slotsMultipliers[6] = 3; slotsMultipliers[7] = 2; slotsMultipliers[8] = 2;
        slotsMultipliers[9] = 2; slotsMultipliers[10] = 2; slotsMultipliers[11] = 2;
        slotsMultipliers[12] = 2; slotsMultipliers[13] = 2; slotsMultipliers[14] = 2;
        slotsMultipliers[15] = 2; slotsMultipliers[16] = 2; slotsMultipliers[17] = 2;
        slotsMultipliers[18] = 2; slotsMultipliers[19] = 2; slotsMultipliers[20] = 2;
        slotsMultipliers[21] = 2; slotsMultipliers[22] = 2; slotsMultipliers[23] = 2;
        slotsMultipliers[24] = 2; slotsMultipliers[25] = 2; slotsMultipliers[26] = 2;
        slotsMultipliers[27] = 2; slotsMultipliers[28] = 2; slotsMultipliers[29] = 2;
        slotsMultipliers[30] = 2; slotsMultipliers[31] = 2; slotsMultipliers[32] = 2;
        slotsMultipliers[33] = 2; slotsMultipliers[34] = 2; slotsMultipliers[35] = 2;
        slotsMultipliers[36] = 2; slotsMultipliers[37] = 2; slotsMultipliers[38] = 2;
        slotsMultipliers[39] = 2; slotsMultipliers[40] = 2; slotsMultipliers[41] = 2;
        slotsMultipliers[42] = 2; slotsMultipliers[43] = 2; slotsMultipliers[44] = 2;
        slotsMultipliers[45] = 2; slotsMultipliers[46] = 2; slotsMultipliers[47] = 2;
        slotsMultipliers[48] = 2; slotsMultipliers[49] = 10; slotsMultipliers[50] = 10;
        slotsMultipliers[51] = 12; slotsMultipliers[52] = 12; slotsMultipliers[53] = 20;
        slotsMultipliers[54] = 20; slotsMultipliers[55] = 45; slotsMultipliers[56] = 100;

        uint16[] memory slotsOutcomes = new uint16[](57);
        slotsOutcomes[0] = 0; slotsOutcomes[1] = 1; slotsOutcomes[2] = 2;
        slotsOutcomes[3] = 3; slotsOutcomes[4] = 4; slotsOutcomes[5] = 5;
        slotsOutcomes[6] = 6; slotsOutcomes[7] = 7; slotsOutcomes[8] = 8;
        slotsOutcomes[9] = 9; slotsOutcomes[10] = 10; slotsOutcomes[11] = 11;
        slotsOutcomes[12] = 12; slotsOutcomes[13] = 13; slotsOutcomes[14] = 14;
        slotsOutcomes[15] = 15; slotsOutcomes[16] = 16; slotsOutcomes[17] = 17;
        slotsOutcomes[18] = 18; slotsOutcomes[19] = 19; slotsOutcomes[20] = 20;
        slotsOutcomes[21] = 21; slotsOutcomes[22] = 22; slotsOutcomes[23] = 23;
        slotsOutcomes[24] = 24; slotsOutcomes[25] = 25; slotsOutcomes[26] = 26;
        slotsOutcomes[27] = 27; slotsOutcomes[28] = 28; slotsOutcomes[29] = 29;
        slotsOutcomes[30] = 30; slotsOutcomes[31] = 31; slotsOutcomes[32] = 32;
        slotsOutcomes[33] = 33; slotsOutcomes[34] = 34; slotsOutcomes[35] = 35;
        slotsOutcomes[36] = 36; slotsOutcomes[37] = 37; slotsOutcomes[38] = 38;
        slotsOutcomes[39] = 39; slotsOutcomes[40] = 40; slotsOutcomes[41] = 41;
        slotsOutcomes[42] = 42; slotsOutcomes[43] = 43; slotsOutcomes[44] = 44;
        slotsOutcomes[45] = 45; slotsOutcomes[46] = 46; slotsOutcomes[47] = 47;
        slotsOutcomes[48] = 48; slotsOutcomes[49] = 114; slotsOutcomes[50] = 117;
        slotsOutcomes[51] = 171; slotsOutcomes[52] = 173; slotsOutcomes[53] = 228;
        slotsOutcomes[54] = 229; slotsOutcomes[55] = 285; slotsOutcomes[56] = 342;

        slots = address(new Slots(
            BANKLP_REGISTRY,
            vrfCoordinator,
            linkEthFeed,
            forwarder,
            slotsMultipliers,
            slotsOutcomes,
            343
        ));
        console.log("Slots deployed to:", slots);
        console.log("");

        console.log("Deploying Mines...");
        uint8[24] memory minesMaxReveal;
        minesMaxReveal[0] = 24; minesMaxReveal[1] = 21; minesMaxReveal[2] = 17; minesMaxReveal[3] = 14;
        minesMaxReveal[4] = 12; minesMaxReveal[5] = 10; minesMaxReveal[6] = 9; minesMaxReveal[7] = 8;
        minesMaxReveal[8] = 7; minesMaxReveal[9] = 6; minesMaxReveal[10] = 5; minesMaxReveal[11] = 5;
        minesMaxReveal[12] = 4; minesMaxReveal[13] = 4; minesMaxReveal[14] = 3; minesMaxReveal[15] = 3;
        minesMaxReveal[16] = 3; minesMaxReveal[17] = 2; minesMaxReveal[18] = 2; minesMaxReveal[19] = 2;
        minesMaxReveal[20] = 2; minesMaxReveal[21] = 1; minesMaxReveal[22] = 1; minesMaxReveal[23] = 1;
        
        mines = address(new Mines(BANKLP_REGISTRY, vrfCoordinator, linkEthFeed, forwarder, minesMaxReveal));
        console.log("Mines deployed to:", mines);
        console.log("");

        vm.stopBroadcast();

        // Print summary
        console.log("========================================");
        console.log("Deployment Summary");
        console.log("========================================");
        console.log("");
        console.log("Core Infrastructure:");
        console.log("  BankLP:          ", BANK_LP);
        console.log("  BankLP Registry: ", BANKLP_REGISTRY);
        console.log("  VRF:             ", vrfCoordinator);
        console.log("  LINK/ETH Feed:   ", linkEthFeed);
        console.log("  Forwarder:       ", forwarder);
        console.log("");
        console.log("Game Contracts:");
        console.log("  CoinFlip:        ", coinFlip);
        console.log("  Dice:            ", dice);
        console.log("  VideoPoker:      ", videoPoker);
        console.log("  Blackjack:       ", blackjack);
        console.log("  Plinko:          ", plinko);
        console.log("  Slots:           ", slots);
        console.log("  Mines:           ", mines);
        console.log("  Keno:            ", keno);
        console.log("  RockPaperScissors:", rockPaperScissors);
        console.log("  AmericanRoulette:", americanRoulette);
        console.log("  EuropeanRoulette:", europeanRoulette);
        console.log("");
        console.log("========================================");
        console.log("Deployment Complete!");
        console.log("========================================");
    }
}
