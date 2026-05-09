// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {console, Script} from "forge-std/Script.sol";
import {CoinFlip} from "../contracts/games/CoinFlip.sol";
import {Dice} from "../contracts/games/Dice.sol";
import {VideoPoker} from "../contracts/games/VideoPoker.sol";
import {Blackjack} from "../contracts/games/Blackjack.sol";
import {Plinko} from "../contracts/games/Plinko.sol";
import {Keno} from "../contracts/games/Keno.sol";
import {Slots} from "../contracts/games/Slots.sol";
import {Mines} from "../contracts/games/Mines.sol";
import {RockPaperScissors} from "../contracts/games/RockPaperScissors.sol";
import {FortuneWheel} from "../contracts/games/FortuneWheel.sol";
import {Lottery} from "../contracts/games/Lottery.sol";
import {AmericanRoulette} from "../contracts/games/Roulette/AmericanRoulette.sol";
import {EuropeanRoulette} from "../contracts/games/Roulette/EuropeanRoulette.sol";
import {VRFConfig} from "../contracts/Common.sol";

contract DeployAllGames is Script {
    uint64 internal constant DEFAULT_REFUND_COOLDOWN_BLOCKS = 20;

    // Core infrastructure addresses (from .env)
    address BANK_LP;
    address BANKLP_REGISTRY;
    address vrfCoordinator;
    address linkEthFeed;
    address forwarder;
    uint64 refundCooldownBlocks;

    // Deployed game addresses
    address public coinFlip;
    address public dice;
    address public videoPoker;
    address public blackjack;
    address public plinko;
    address public keno;
    address public slots;
    address public vaultBonanza;
    address public mines;
    address public rockPaperScissors;
    address public fortuneWheel;
    address public lottery;
    address public americanRoulette;
    address public europeanRoulette;

    function setUp() public {
        // Load addresses from environment
        BANK_LP = vm.envAddress("BANKLP_ADDRESS");
        BANKLP_REGISTRY = vm.envAddress("BANKLP_REGISTRY_ADDRESS");
        vrfCoordinator = vm.envAddress("VRF_ADDRESS");
        linkEthFeed = vm.envAddress("LINK_ETH_FEED_ADDRESS");
        refundCooldownBlocks = uint64(vm.envOr("REFUND_COOLDOWN_BLOCKS", uint256(DEFAULT_REFUND_COOLDOWN_BLOCKS)));
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        VRFConfig memory vrf = _buildVRFConfig();
        
        vm.startBroadcast(deployerPrivateKey);

        console.log("================================");
        console.log("Deploying Casino Game Contracts");
        console.log("================================");
        console.log("");

        // Deploy games without configs
        console.log("Deploying CoinFlip...");
        coinFlip = address(new CoinFlip(BANKLP_REGISTRY, vrf, refundCooldownBlocks));
        console.log("CoinFlip deployed to:", coinFlip);
        console.log("");

        console.log("Deploying RockPaperScissors...");
        rockPaperScissors = address(new RockPaperScissors(BANKLP_REGISTRY, vrf, refundCooldownBlocks));
        console.log("RockPaperScissors deployed to:", rockPaperScissors);
        console.log("");

        console.log("Deploying Dice...");
        dice = address(new Dice(BANKLP_REGISTRY, vrf, refundCooldownBlocks));
        console.log("Dice deployed to:", dice);
        console.log("");

        console.log("Deploying VideoPoker...");
        videoPoker = address(new VideoPoker(BANKLP_REGISTRY, vrf, refundCooldownBlocks));
        console.log("VideoPoker deployed to:", videoPoker);
        console.log("");

        console.log("Deploying Blackjack...");
        blackjack = address(new Blackjack(BANKLP_REGISTRY, vrf, refundCooldownBlocks));
        console.log("Blackjack deployed to:", blackjack);
        console.log("");

        console.log("Deploying Plinko...");
        plinko = address(new Plinko(BANKLP_REGISTRY, vrf, refundCooldownBlocks));
        console.log("Plinko deployed to:", plinko);
        console.log("");

        console.log("Deploying Keno...");
        keno = address(new Keno(BANKLP_REGISTRY, vrf, refundCooldownBlocks));
        console.log("Keno deployed to:", keno);
        console.log("");

        console.log("Deploying FortuneWheel...");
        fortuneWheel = address(new FortuneWheel(BANKLP_REGISTRY, vrf, refundCooldownBlocks));
        console.log("FortuneWheel deployed to:", fortuneWheel);
        console.log("");

        console.log("Deploying Lottery...");
        lottery = address(new Lottery(BANKLP_REGISTRY, vrf));
        console.log("Lottery deployed to:", lottery);
        console.log("");

        console.log("Deploying AmericanRoulette...");
        americanRoulette = address(new AmericanRoulette(BANKLP_REGISTRY, vrf, refundCooldownBlocks));
        console.log("AmericanRoulette deployed to:", americanRoulette);
        console.log("");

        console.log("Deploying EuropeanRoulette...");
        europeanRoulette = address(new EuropeanRoulette(BANKLP_REGISTRY, vrf, refundCooldownBlocks));
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

        uint16[] memory slotsBonusMultipliers = new uint16[](0);
        uint8[] memory slotsBonusRounds = new uint8[](0);
        uint16[] memory slotsBonusOutcomes = new uint16[](0);

        slots = address(new Slots(
            BANKLP_REGISTRY,
            vrf,
            refundCooldownBlocks,
            slotsMultipliers,
            slotsOutcomes,
            343,
            slotsBonusMultipliers,
            slotsBonusRounds,
            slotsBonusOutcomes,
            1,
            3
        ));
        console.log("Slots deployed to:", slots);
        console.log("");

        console.log("Deploying Vault Bonanza (Slots)...");
        uint16[] memory vaultBonanzaMultipliers;
        uint16[] memory vaultBonanzaOutcomes;
        uint16[] memory vaultBonanzaBonusMultipliers;
        uint8[] memory vaultBonanzaBonusRounds;
        uint16[] memory vaultBonanzaBonusOutcomes;

        uint16[] memory emptyU16 = new uint16[](0);
        uint8[] memory emptyU8 = new uint8[](0);

        Slots vaultBonanzaContract = new Slots(
            BANKLP_REGISTRY,
            vrf,
            refundCooldownBlocks,
            emptyU16,
            emptyU16,
            0,
            emptyU16,
            emptyU8,
            emptyU16,
            0,
            0
        );
        vaultBonanza = address(vaultBonanzaContract);

        console.log("Configuring Vault Bonanza with symbol-based outcomes...");

        // Symbol-driven config (additive):
        // - 7 symbols (0..6) can win base multipliers when a symbol appears 3+ times.
        // - If multiple symbols qualify in an outcome, all qualifying multipliers are summed.
        // - Symbols 0..4: free-spin bonus only when appearing 4+ times.
        // - Symbols 5..6: free-spin + bonus-multiplier when appearing 4+ times.
        // - If multiple bonus conditions qualify, bonus rounds and bonus multipliers are summed.
        // Outcome IDs are generated from symbol tuples [c0..c4] in base-7.
        (
            vaultBonanzaMultipliers,
            vaultBonanzaOutcomes,
            vaultBonanzaBonusMultipliers,
            vaultBonanzaBonusRounds,
            vaultBonanzaBonusOutcomes
        ) = _buildVaultBonanzaSymbolConfig();

        _configureVaultBonanzaInBatches(
            vaultBonanzaContract,
            vaultBonanzaMultipliers,
            vaultBonanzaOutcomes,
            vaultBonanzaBonusMultipliers,
            vaultBonanzaBonusRounds,
            vaultBonanzaBonusOutcomes
        );

        console.log("Vault Bonanza configured:");
        console.log("  Base outcomes:", vaultBonanzaOutcomes.length);
        console.log("  Bonus outcomes:", vaultBonanzaBonusOutcomes.length);
        console.log("");

        console.log("Deploying Mines...");
        uint8[24] memory minesMaxReveal;
        minesMaxReveal[0] = 24; minesMaxReveal[1] = 21; minesMaxReveal[2] = 17; minesMaxReveal[3] = 14;
        minesMaxReveal[4] = 12; minesMaxReveal[5] = 10; minesMaxReveal[6] = 9; minesMaxReveal[7] = 8;
        minesMaxReveal[8] = 7; minesMaxReveal[9] = 6; minesMaxReveal[10] = 5; minesMaxReveal[11] = 5;
        minesMaxReveal[12] = 4; minesMaxReveal[13] = 4; minesMaxReveal[14] = 3; minesMaxReveal[15] = 3;
        minesMaxReveal[16] = 3; minesMaxReveal[17] = 2; minesMaxReveal[18] = 2; minesMaxReveal[19] = 2;
        minesMaxReveal[20] = 2; minesMaxReveal[21] = 1; minesMaxReveal[22] = 1; minesMaxReveal[23] = 1;
        
        mines = address(new Mines(BANKLP_REGISTRY, vrf, minesMaxReveal, refundCooldownBlocks));
        console.log("Mines deployed to:", mines);
        console.log("");

        vm.stopBroadcast();

        // Print summary
        console.log("========================================");
        console.log("Deployment Summary");
        console.log("========================================");
        console.log("");
        console.log("Core Infrastructure:");
        console.log("  BankLP:            ", BANK_LP);
        console.log("  BankLP Registry:   ", BANKLP_REGISTRY);
        console.log("  VRF:               ", vrfCoordinator);
        console.log("  LINK/ETH Feed:     ", linkEthFeed);
        console.log("  Forwarder:         ", forwarder);
        console.log("");
        console.log("Game Contracts:");
        console.log("  CoinFlip:          ", coinFlip);
        console.log("  Dice:              ", dice);
        console.log("  VideoPoker:        ", videoPoker);
        console.log("  Blackjack:         ", blackjack);
        console.log("  Plinko:            ", plinko);
        console.log("  Slots:             ", slots);
        console.log("  Vault Bonanza:     ", vaultBonanza);
        console.log("  Mines:             ", mines);
        console.log("  Keno:              ", keno);
        console.log("  FortuneWheel:      ", fortuneWheel);
        console.log("  Lottery:           ", lottery);
        console.log("  RockPaperScissors: ", rockPaperScissors);
        console.log("  AmericanRoulette:  ", americanRoulette);
        console.log("  EuropeanRoulette:  ", europeanRoulette);
        console.log("");
        console.log("========================================");
        console.log("Deployment Complete!");
        console.log("========================================");
    }

    function _buildVRFConfig() internal view returns (VRFConfig memory) {
        return VRFConfig({
            coordinator: vrfCoordinator,
            keyHash: vm.envBytes32("VRF_KEY_HASH"),
            subId: vm.envUint("VRF_SUBSCRIPTION_ID"),
            reqConfirmations: uint16(vm.envUint("VRF_MIN_CONFIRMATIONS")),
            callbackGasLimit: uint32(vm.envUint("VRF_CALLBACK_GAS_LIMIT")),
            linkEthFeed: linkEthFeed
        });
    }

    function _configureVaultBonanzaInBatches(
        Slots vaultBonanzaContract,
        uint16[] memory multipliers,
        uint16[] memory outcomes,
        uint16[] memory bonusMultipliers,
        uint8[] memory bonusRounds,
        uint16[] memory bonusOutcomes
    ) internal {
        uint256 baseBatchSize = 300;
        uint256 bonusBatchSize = 300;

        // not row specific, so set to false
        vaultBonanzaContract.Slots_BeginSetup(16807, 2, 5, false);

        for (uint256 start = 0; start < outcomes.length; start += baseBatchSize) {
            uint256 end = start + baseBatchSize;
            if (end > outcomes.length) {
                end = outcomes.length;
            }

            uint256 size = end - start;
            uint16[] memory batchMultipliers = new uint16[](size);
            uint16[] memory batchOutcomes = new uint16[](size);

            for (uint256 i = 0; i < size; i++) {
                batchMultipliers[i] = multipliers[start + i];
                batchOutcomes[i] = outcomes[start + i];
            }

            vaultBonanzaContract.Slots_SetMultipliersBatch(batchMultipliers, batchOutcomes);
        }

        for (uint256 start = 0; start < bonusOutcomes.length; start += bonusBatchSize) {
            uint256 end = start + bonusBatchSize;
            if (end > bonusOutcomes.length) {
                end = bonusOutcomes.length;
            }

            uint256 size = end - start;
            uint16[] memory batchBonusMultipliers = new uint16[](size);
            uint8[] memory batchBonusRounds = new uint8[](size);
            uint16[] memory batchBonusOutcomes = new uint16[](size);

            for (uint256 i = 0; i < size; i++) {
                batchBonusMultipliers[i] = bonusMultipliers[start + i];
                batchBonusRounds[i] = bonusRounds[start + i];
                batchBonusOutcomes[i] = bonusOutcomes[start + i];
            }

            vaultBonanzaContract.Slots_SetBonusesBatch(
                batchBonusMultipliers,
                batchBonusRounds,
                batchBonusOutcomes
            );
        }

        vaultBonanzaContract.Slots_FinalizeSetup();
    }

    function _buildVaultBonanzaSymbolConfig()
        internal
        pure
        returns (
            uint16[] memory multipliers,
            uint16[] memory outcomes,
            uint16[] memory bonusMultipliers,
            uint8[] memory bonusRounds,
            uint16[] memory bonusOutcomes
        )
    {
        uint16[] memory tmpOutcomes = new uint16[](16807);
        uint16[] memory tmpMultipliers = new uint16[](16807);
        uint16[] memory tmpBonusOutcomes = new uint16[](16807);
        uint16[] memory tmpBonusMultipliers = new uint16[](16807);
        uint8[] memory tmpBonusRounds = new uint8[](16807);

        uint16 winCount;
        uint16 bonusCount;

        for (uint16 outcomeId = 0; outcomeId < 16807; outcomeId++) {
            (uint16 mult, uint8 bonusRoundsTotal, uint16 bonusAddTotal) = _calcOutcomeValues(outcomeId);

            if (mult > 0) {
                tmpOutcomes[winCount] = outcomeId;
                tmpMultipliers[winCount] = mult;
                winCount++;
            }

            if (bonusRoundsTotal > 0 || bonusAddTotal > 0) {
                tmpBonusOutcomes[bonusCount] = outcomeId;
                tmpBonusMultipliers[bonusCount] = bonusAddTotal;
                tmpBonusRounds[bonusCount] = bonusRoundsTotal;
                bonusCount++;
            }
        }

        outcomes = new uint16[](winCount);
        multipliers = new uint16[](winCount);
        for (uint16 i = 0; i < winCount; i++) {
            outcomes[i] = tmpOutcomes[i];
            multipliers[i] = tmpMultipliers[i];
        }

        bonusOutcomes = new uint16[](bonusCount);
        bonusMultipliers = new uint16[](bonusCount);
        bonusRounds = new uint8[](bonusCount);
        for (uint16 i = 0; i < bonusCount; i++) {
            bonusOutcomes[i] = tmpBonusOutcomes[i];
            bonusMultipliers[i] = tmpBonusMultipliers[i];
            bonusRounds[i] = tmpBonusRounds[i];
        }
    }

    function _calcOutcomeValues(uint16 outcomeId)
        internal
        pure
        returns (uint16, uint8, uint16)
    {
        uint16[7] memory threeKindMult = [uint16(5), 2, 2, 2, 2, 1, 1];
        uint16[7] memory fourKindMult = [uint16(15), 12, 8, 6, 4, 3, 2];
        uint16[7] memory fiveKindMult = [uint16(110), 30, 85, 30, 70, 50, 25];

        uint16 mult;
        uint8 bonusRoundsTotal;
        uint16 bonusAddTotal;

        uint8[7] memory counts = _symbolCounts(outcomeId);

        for (uint8 symbol = 0; symbol < 7; symbol++) {
            uint8 count = counts[symbol];

            if (count == 3) {
                mult += threeKindMult[symbol];
            } else if (count == 4) {
                mult += fourKindMult[symbol];
            } else if (count == 5) {
                mult += fiveKindMult[symbol];
            }

            if (count >= 4) {
                uint8 rounds = count == 4 ? 6 : 10;
                bonusRoundsTotal += rounds;

                if (symbol >= 5) {
                    bonusAddTotal += count == 4 ? 6 : 13;
                }
            }
        }

        return (mult, bonusRoundsTotal, bonusAddTotal);
    }

    function _symbolCounts(uint16 outcomeId) internal pure returns (uint8[7] memory counts) {
        uint16 v = outcomeId;

        for (uint8 i = 0; i < 5; i++) {
            uint8 s = uint8(v % 7);
            counts[s]++;
            v /= 7;
        }
    }
}
