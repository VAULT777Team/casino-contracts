
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library GameConfigLib {
    struct GameConfig {
        string name;
        address gameContract;
        address[] supportedTokens;
        uint256 minBet;
        uint256 maxBet;
        uint256 houseEdgeBps; // basis points
        uint256 payoutMultiplierBps; // basis points
        bytes extraData; // dynamic, game-specific config
    }

    function getSlotsConfig() internal pure returns (GameConfig memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = 0x0000000000000000000000000000000000000000; // Example token
        uint16[] memory multipliers = new uint16[](57);
        multipliers[0] = 5; multipliers[1] = 3; multipliers[2] = 3;
        multipliers[3] = 3; multipliers[4] = 3; multipliers[5] = 3;
        multipliers[6] = 3; multipliers[7] = 2; multipliers[8] = 2;
        multipliers[9] = 2; multipliers[10] = 2; multipliers[11] = 2;
        multipliers[12] = 2; multipliers[13] = 2; multipliers[14] = 2;
        multipliers[15] = 2; multipliers[16] = 2; multipliers[17] = 2;
        multipliers[18] = 2; multipliers[19] = 2; multipliers[20] = 2;
        multipliers[21] = 2; multipliers[22] = 2; multipliers[23] = 2;
        multipliers[24] = 2; multipliers[25] = 2; multipliers[26] = 2;
        multipliers[27] = 2; multipliers[28] = 2; multipliers[29] = 2;
        multipliers[30] = 2; multipliers[31] = 2; multipliers[32] = 2;
        multipliers[33] = 2; multipliers[34] = 2; multipliers[35] = 2;
        multipliers[36] = 2; multipliers[37] = 2; multipliers[38] = 2;
        multipliers[39] = 2; multipliers[40] = 2; multipliers[41] = 2;
        multipliers[42] = 2; multipliers[43] = 2; multipliers[44] = 2;
        multipliers[45] = 2; multipliers[46] = 2; multipliers[47] = 2;
        multipliers[48] = 2; multipliers[49] = 10; multipliers[50] = 10;
        multipliers[51] = 12; multipliers[52] = 12; multipliers[53] = 20;
        multipliers[54] = 20; multipliers[55] = 45; multipliers[56] = 100;

        uint16[] memory outcomes = new uint16[](57);
        outcomes[0] = 0; outcomes[1] = 1; outcomes[2] = 2;
        outcomes[3] = 3; outcomes[4] = 4; outcomes[5] = 5;
        outcomes[6] = 6; outcomes[7] = 7; outcomes[8] = 8;
        outcomes[9] = 9; outcomes[10] = 10; outcomes[11] = 11;
        outcomes[12] = 12; outcomes[13] = 13; outcomes[14] = 14;
        outcomes[15] = 15; outcomes[16] = 16; outcomes[17] = 17;
        outcomes[18] = 18; outcomes[19] = 19; outcomes[20] = 20;
        outcomes[21] = 21; outcomes[22] = 22; outcomes[23] = 23;
        outcomes[24] = 24; outcomes[25] = 25; outcomes[26] = 26;
        outcomes[27] = 27; outcomes[28] = 28; outcomes[29] = 29;
        outcomes[30] = 30; outcomes[31] = 31; outcomes[32] = 32;
        outcomes[33] = 33; outcomes[34] = 34; outcomes[35] = 35;
        outcomes[36] = 36; outcomes[37] = 37; outcomes[38] = 38;
        outcomes[39] = 39; outcomes[40] = 40; outcomes[41] = 41;
        outcomes[42] = 42; outcomes[43] = 43; outcomes[44] = 44;
        outcomes[45] = 45; outcomes[46] = 46; outcomes[47] = 47;
        outcomes[48] = 48; outcomes[49] = 114; outcomes[50] = 117;
        outcomes[51] = 171; outcomes[52] = 173; outcomes[53] = 228;
        outcomes[54] = 229; outcomes[55] = 285; outcomes[56] = 342;

        bytes memory extraData = abi.encode(multipliers, outcomes);

        return GameConfig({
            name: "Slots",
            gameContract: address(0),
            supportedTokens: tokens,
            minBet: 1e18,
            maxBet: 1000e18,
            houseEdgeBps: 300,
            payoutMultiplierBps: 9500,
            extraData: extraData
        });
    }

    function getMinesConfig() internal pure returns (GameConfig memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = 0x0000000000000000000000000000000000000000; // Example token
        uint8[24] memory minesMaxReveal;
        minesMaxReveal[0] = 24; minesMaxReveal[1] = 21; minesMaxReveal[2] = 17; minesMaxReveal[3] = 14;
        minesMaxReveal[4] = 12; minesMaxReveal[5] = 10; minesMaxReveal[6] = 9; minesMaxReveal[7] = 8;
        minesMaxReveal[8] = 7; minesMaxReveal[9] = 6; minesMaxReveal[10] = 5; minesMaxReveal[11] = 5;
        minesMaxReveal[12] = 4; minesMaxReveal[13] = 4; minesMaxReveal[14] = 3; minesMaxReveal[15] = 3;
        minesMaxReveal[16] = 3; minesMaxReveal[17] = 2; minesMaxReveal[18] = 2; minesMaxReveal[19] = 2;
        minesMaxReveal[20] = 2; minesMaxReveal[21] = 1; minesMaxReveal[22] = 1; minesMaxReveal[23] = 1;

        bytes memory extraData = abi.encode(minesMaxReveal);

        return GameConfig({
            name: "Mines",
            gameContract: address(0),
            supportedTokens: tokens,
            minBet: 0.5e18,
            maxBet: 500e18,
            houseEdgeBps: 250,
            payoutMultiplierBps: 8000,
            extraData: extraData
        });
    }


    function getRouletteConfig(uint32 version) internal pure returns (GameConfig memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = 0x0000000000000000000000000000000000000000; // Example token
        bytes memory extraData = "";
        return GameConfig({
            name: "Roulette",
            gameContract: address(0),
            supportedTokens: tokens,
            minBet: 1e18,
            maxBet: 1000e18,
            houseEdgeBps: 200,
            payoutMultiplierBps: 3500,
            extraData: extraData
        });
    }

    function getBlackjackConfig(uint32 version) internal pure returns (GameConfig memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = 0x0000000000000000000000000000000000000000;
        bytes memory extraData = "";
        return GameConfig({
            name: "Blackjack",
            gameContract: address(0),
            supportedTokens: tokens,
            minBet: 1e18,
            maxBet: 500e18,
            houseEdgeBps: 150,
            payoutMultiplierBps: 2000,
            extraData: extraData
        });
    }

    function getDiceConfig(uint32 version) internal pure returns (GameConfig memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = 0x0000000000000000000000000000000000000000;
        bytes memory extraData = "";
        return GameConfig({
            name: "Dice",
            gameContract: address(0),
            supportedTokens: tokens,
            minBet: 0.1e18,
            maxBet: 100e18,
            houseEdgeBps: 100,
            payoutMultiplierBps: 6000,
            extraData: extraData
        });
    }
}
