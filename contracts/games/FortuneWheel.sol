// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {
    Common, VRFConfig, IBankrollRegistry,
    ChainSpecificUtil,
    IERC20, SafeERC20
} from "../Common.sol";

/**
 * @title Fortune Wheel game, players spin a wheel for a multiplier payout
 */

contract FortuneWheel is Common {
    using SafeERC20 for IERC20;

    uint16 private constant DEFAULT_SEGMENTS = 24;
    uint32 private constant BP = 10_000;
    uint32 private constant KELLY_LIMIT_BP = 112; // 1.12%
    uint32 private constant MAX_BETS = 50;
    uint8 private constant LEGACY_CONFIG_ID = 0;
    uint8 private constant HIGH_VARIANCE_CONFIG_ID = 1;

    struct WheelConfig {
        uint16 segmentCount;
        uint32 totalInternalSegments;
        uint32 maxMultiplierBp;
        uint8 maxBonusSpins;
        bool enabled;
        uint32[] multipliersBp;
        bool[] isBonus;
        uint32[] segmentWeights;
    }

    constructor(
        address _registry,
        VRFConfig memory vrf
    ) Common(vrf) {
        b_registry = IBankrollRegistry(_registry);

        _initializeDefaultConfigs();
        activeConfigId = LEGACY_CONFIG_ID;
    }

    struct FortuneWheelGame {
        uint256 wager; // wager per bet
        uint256 requestID;
        address tokenAddress;
        uint256 tokenId;
        uint64 blockNumber;
        uint32 numBets;
        uint256 totalWager;
        uint256 maxPayout; // max payout total across all bets
        uint8 configId;
    }

    mapping(address => FortuneWheelGame) fortuneWheelGames;
    mapping(uint256 => address) fortuneWheelIDs;
    mapping(uint8 => WheelConfig) private wheelConfigs;

    uint8 public activeConfigId;

    /**
     * @dev event emitted at the start of the game
     * @param playerAddress address of the player that made the bet
     * @param wager wagered amount
     * @param numBets number of bets the player intends to make
     * @param tokenAddress address of token the wager was made, 0 address is considered the native coin
     */
    event FortuneWheel_Play_Event(
        address indexed playerAddress,
        uint256 wager,
        uint32 numBets,
        address tokenAddress,
        uint256 VRFFee,
        uint8 configId
    );

    /**
     * @dev event emitted by the VRF callback with the bet results
     * @param playerAddress address of the player that made the bet
     * @param wagerPerBet wager amount per bet
     * @param tokenAddress address of token the wager was made and payout, 0 address is considered the native coin
     * @param payouts total payouts transferred to the player per bet
     * @param multipliers multipliers in basis points
     * @param segments resulting wheel segments
     * @param numBets number of bets placed
     */
    event FortuneWheel_Outcome_Event(
        address indexed playerAddress,
        uint256 wagerPerBet,
        address tokenAddress,
        uint256[] payouts,
        uint32[] multipliers,
        uint16[] segments,
        uint8[] bonusSpins,
        uint32 numBets,
        uint8 configId
    );

    event FortuneWheel_ConfigUpdated(
        uint8 indexed configId,
        uint16 segmentCount,
        uint32 totalInternalSegments,
        uint32 maxMultiplierBp,
        uint8 maxBonusSpins,
        bool enabled
    );

    event FortuneWheel_ActiveConfigUpdated(uint8 indexed configId);

    /**
     * @dev event emitted when a refund is done in fortune wheel
     * @param player address of the player reciving the refund
     * @param wager amount of wager that was refunded
     * @param tokenAddress address of token the refund was made in
     */
    event FortuneWheel_Refund_Event(
        address indexed player,
        uint256 wager,
        address tokenAddress
    );

    error WagerAboveLimit(uint256 wager, uint256 maxWager);
    error AwaitingVRF(uint256 requestID);
    error NotAwaitingVRF();
    error BlockNumberTooLow(uint256 have, uint256 want);
    error InvalidNumBets(uint32 numBets);
    error InvalidConfigId(uint8 configId);
    error DisabledConfig(uint8 configId);
    error InvalidConfig();
    error InvalidConfigLength(uint256 have, uint256 want);
    error InvalidBonusMultiplier(uint256 segment, uint32 multiplierBp);

    /**
     * @dev function to get current request player is await from VRF, returns 0 if none
     * @param player address of the player to get the state
     */
    function FortuneWheel_GetState(
        address player
    ) external view returns (FortuneWheelGame memory) {
        return (fortuneWheelGames[player]);
    }

    /**
     * @dev Function to play Fortune Wheel, takes the user wager saves bet parameters and makes a request to the VRF
     * @param wager wager amount
     * @param tokenAddress address of token to bet, 0 address is considered the native coin
     * @param numBets number of bets the player intends to make
     * @param configId configuration ID to use for the game
     */
    function FortuneWheel_Play(
        uint256 wager,
        address tokenAddress,
        uint256 tokenId,
        uint32 numBets,
        uint8 configId
    ) external payable nonReentrant {
        _play(wager, tokenAddress, tokenId, numBets, configId);
    }

    function _play(
        uint256 wager,
        address tokenAddress,
        uint256 tokenId,
        uint32 numBets,
        uint8 configId
    ) internal {
        WheelConfig storage config = wheelConfigs[configId];
        if (!config.enabled) {
            revert DisabledConfig(configId);
        }

        address msgSender = _msgSender();
        if (fortuneWheelGames[msgSender].requestID != 0) {
            revert AwaitingVRF(fortuneWheelGames[msgSender].requestID);
        }

        if (numBets == 0 || numBets > MAX_BETS) {
            revert InvalidNumBets(numBets);
        }

        uint256 totalWager = wager * uint256(numBets);

        uint256 maxPayoutPerBet = (wager * config.maxMultiplierBp) / BP;
        uint256 maxPayoutTotal = maxPayoutPerBet * uint256(numBets);

        _kellyWager(wager, maxPayoutPerBet, tokenAddress, tokenId, configId);

        _reserveMaxPayout(tokenAddress, tokenId, maxPayoutTotal);
        // Scale the VRF callback gas estimate with number of bets.
        uint256 gasAmount = 700000 + (uint256(numBets) * 45000);
        _transferWager(
            tokenAddress,
            tokenId,
            totalWager,
            gasAmount,
            20,
            msgSender
        );

        uint256 id = _requestRandomWords(numBets);

        fortuneWheelGames[msgSender] = FortuneWheelGame({
            requestID: id,
            wager: wager,
            tokenAddress: tokenAddress,
            tokenId: tokenId,
            blockNumber: uint64(ChainSpecificUtil.getBlockNumber()),
            numBets: numBets,
            totalWager: totalWager,
            maxPayout: maxPayoutTotal,
            configId: configId
        });

        fortuneWheelIDs[id] = msgSender;

        emit FortuneWheel_Play_Event(
            msgSender,
            wager,
            numBets,
            tokenAddress,
            0,
            configId
        );
    }

    /**
     * @dev Function to refund user in case of VRF request failling
     */
    function FortuneWheel_Refund() external nonReentrant {
        address msgSender = _msgSender();
        FortuneWheelGame storage game = fortuneWheelGames[msgSender];
        if (game.requestID == 0) {
            revert NotAwaitingVRF();
        }
        if (game.blockNumber + 200 > uint64(ChainSpecificUtil.getBlockNumber())) {
            revert BlockNumberTooLow(ChainSpecificUtil.getBlockNumber(), game.blockNumber + 200);
        }

        address tokenAddress = game.tokenAddress;

        uint256 totalWager = game.totalWager;

        _releaseReserve(tokenAddress, game.tokenId, game.maxPayout);

        delete (fortuneWheelIDs[game.requestID]);
        delete (fortuneWheelGames[msgSender]);

        _refundPlayer(msgSender, tokenAddress, game.tokenId, totalWager);
        emit FortuneWheel_Refund_Event(msgSender, totalWager, tokenAddress);
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        address playerAddress = fortuneWheelIDs[requestId];
        if (playerAddress == address(0)) revert();
        FortuneWheelGame storage game = fortuneWheelGames[playerAddress];

        address tokenAddress = game.tokenAddress;

        uint256 totalPayout = 0;
        uint32 numBets = game.numBets;
        uint256 wagerPerBet = game.wager;
        WheelConfig storage config = wheelConfigs[game.configId];

        // Safety: if VRF returns fewer words than expected, cap to available.
        uint32 spins = numBets;
        if (randomWords.length < spins) {
            spins = uint32(randomWords.length);
        }

        uint256[] memory payouts = new uint256[](spins);
        uint32[] memory multipliers = new uint32[](spins);
        uint16[] memory segments = new uint16[](spins);
        uint8[] memory bonusSpins = new uint8[](spins);
        
        for (uint32 i = 0; i < spins; i++) {
            (
                uint16 segment,
                uint32 multiplierBps,
                uint8 bonusSpinCount
            ) = _resolveBet(config, randomWords[i]);
            uint256 payoutPerBet = (wagerPerBet * multiplierBps) / BP;
            totalPayout += payoutPerBet;

            payouts[i] = payoutPerBet;
            multipliers[i] = multiplierBps;
            segments[i] = segment;
            bonusSpins[i] = bonusSpinCount;
        }

        _releaseReserve(tokenAddress, game.tokenId, game.maxPayout);

        _transferToBankroll(tokenAddress, game.tokenId, game.totalWager);
        delete (fortuneWheelIDs[requestId]);
        delete (fortuneWheelGames[playerAddress]);

        if (totalPayout != 0) {
            _transferPayout(playerAddress, totalPayout, tokenAddress, game.tokenId);
        }

        emit FortuneWheel_Outcome_Event(
            playerAddress,
            wagerPerBet,
            tokenAddress,
            payouts,
            multipliers,
            segments,
            bonusSpins,
            numBets,
            game.configId
        );
    }

    /**
     * @dev updates (or creates) a wheel config profile
     */
    function FortuneWheel_SetConfig(
        uint8 configId,
        uint16 segmentCount,
        uint32[] calldata multipliersBp,
        bool[] calldata isBonus,
        uint32[] calldata segmentWeights,
        uint8 maxBonusSpins,
        bool enabled
    ) external onlyOwner {
        _setConfig(
            configId,
            segmentCount,
            multipliersBp,
            isBonus,
            segmentWeights,
            maxBonusSpins,
            enabled
        );
    }

    /**
     * @dev sets the config id used by FortuneWheel_Play()
     */
    function FortuneWheel_SetActiveConfig(uint8 configId) external onlyOwner {
        if (!wheelConfigs[configId].enabled) {
            revert DisabledConfig(configId);
        }
        activeConfigId = configId;
        emit FortuneWheel_ActiveConfigUpdated(configId);
    }

    function FortuneWheel_GetConfig(uint8 configId) external view returns (WheelConfig memory) {
        return wheelConfigs[configId];
    }

    function _resolveBet(
        WheelConfig storage config,
        uint256 randomWord
    ) internal view returns (uint16 visibleSegment, uint32 multiplierBp, uint8 bonusSpinCount) {
        uint256 seed = randomWord;

        for (uint8 i = 0; i <= config.maxBonusSpins; i++) {
            uint16 landedSegment = _pickWeightedSegment(config, seed);
            if (i == 0) {
                visibleSegment = landedSegment;
            }

            if (!config.isBonus[landedSegment]) {
                return (visibleSegment, config.multipliersBp[landedSegment], bonusSpinCount);
            }

            bonusSpinCount += 1;
            seed = uint256(keccak256(abi.encodePacked(seed, landedSegment, i)));
        }

        // If we keep hitting bonus beyond maxBonusSpins, settle at 0x.
        return (visibleSegment, 0, bonusSpinCount);
    }

    function _pickWeightedSegment(
        WheelConfig storage config,
        uint256 randomWord
    ) internal view returns (uint16 segment) {
        uint256 value = randomWord % config.totalInternalSegments;
        uint256 cumulative = 0;

        for (uint16 i = 0; i < config.segmentCount; i++) {
            cumulative += config.segmentWeights[i];
            if (value < cumulative) {
                return i;
            }
        }

        return config.segmentCount - 1;
    }

    function _setConfig(
        uint8 configId,
        uint16 segmentCount,
        uint32[] memory multipliersBp,
        bool[] memory isBonus,
        uint32[] memory segmentWeights,
        uint8 maxBonusSpins,
        bool enabled
    ) internal {
        if (segmentCount == 0) {
            revert InvalidConfig();
        }

        if (multipliersBp.length != segmentCount) {
            revert InvalidConfigLength(multipliersBp.length, segmentCount);
        }

        if (isBonus.length != segmentCount) {
            revert InvalidConfigLength(isBonus.length, segmentCount);
        }

        if (segmentWeights.length != segmentCount) {
            revert InvalidConfigLength(segmentWeights.length, segmentCount);
        }

        uint256 totalInternalSegments = 0;
        uint32 maxMultiplierBp = 0;

        for (uint16 i = 0; i < segmentCount; i++) {
            totalInternalSegments += segmentWeights[i];

            if (isBonus[i] && multipliersBp[i] != 0) {
                revert InvalidBonusMultiplier(i, multipliersBp[i]);
            }

            if (!isBonus[i] && multipliersBp[i] > maxMultiplierBp) {
                maxMultiplierBp = multipliersBp[i];
            }
        }

        if (totalInternalSegments == 0 || totalInternalSegments > type(uint32).max) {
            revert InvalidConfig();
        }

        if (maxMultiplierBp == 0) {
            revert InvalidConfig();
        }

        WheelConfig storage config = wheelConfigs[configId];
        config.segmentCount = segmentCount;
        config.totalInternalSegments = uint32(totalInternalSegments);
        config.maxMultiplierBp = maxMultiplierBp;
        config.maxBonusSpins = maxBonusSpins;
        config.enabled = enabled;
        config.multipliersBp = multipliersBp;
        config.isBonus = isBonus;
        config.segmentWeights = segmentWeights;

        emit FortuneWheel_ConfigUpdated(
            configId,
            config.segmentCount,
            config.totalInternalSegments,
            config.maxMultiplierBp,
            config.maxBonusSpins,
            config.enabled
        );
    }

    function _initializeDefaultConfigs() internal {
        uint32[DEFAULT_SEGMENTS] memory legacyMultipliers = [
            uint32(100_000),
            0,
            0,
            0,
            20_000,
            0,
            0,
            0,
            20_000,
            0,
            0,
            0,
            50_000,
            0,
            0,
            0,
            20_000,
            0,
            0,
            0,
            20_000,
            0,
            0,
            0
        ];
        bool[DEFAULT_SEGMENTS] memory legacyBonus;
        uint32[DEFAULT_SEGMENTS] memory legacyWeights = [
            uint32(1),
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1
        ];

        _setConfig(
            LEGACY_CONFIG_ID,
            DEFAULT_SEGMENTS,
            _toDynamicUint32(legacyMultipliers),
            _toDynamicBool(legacyBonus),
            _toDynamicUint32(legacyWeights),
            0,
            true
        );

        // High-variance profile with 24 visible segments and 1,000,000 weighted internal slots.
        // Approx RTP is ~97.98% with 1% bonus-spin chance and capped recursive bonus handling.
        uint32[DEFAULT_SEGMENTS] memory highVarianceMultipliers = [
            uint32(1_000_000),
            500_000,
            0,
            10_000_000,
            20_000,
            200_000,
            1_000_000,
            10_000_000,
            200_000,
            500_000,
            0,
            1_000_000,
            0,
            200_000,
            500_000,
            0,
            1_000_000,
            10_000_000,
            50_000,
            20_000,
            0,
            300_000,
            10_000_000,
            500_000
        ];

        bool[DEFAULT_SEGMENTS] memory highVarianceBonus;
        highVarianceBonus[12] = true;

        uint32[DEFAULT_SEGMENTS] memory highVarianceWeights = [
            uint32(125),
            375,
            200_450,
            50,
            80_000,
            2_667,
            125,
            50,
            2_667,
            375,
            200_450,
            125,
            10_000,
            2_666,
            375,
            200_450,
            125,
            50,
            15_000,
            80_000,
            200_450,
            3_000,
            50,
            375
        ];

        _setConfig(
            HIGH_VARIANCE_CONFIG_ID,
            DEFAULT_SEGMENTS,
            _toDynamicUint32(highVarianceMultipliers),
            _toDynamicBool(highVarianceBonus),
            _toDynamicUint32(highVarianceWeights),
            3,
            true
        );
    }

    function _toDynamicUint32(
        uint32[DEFAULT_SEGMENTS] memory fixedArray
    ) internal pure returns (uint32[] memory dynamicArray) {
        dynamicArray = new uint32[](DEFAULT_SEGMENTS);
        for (uint16 i = 0; i < DEFAULT_SEGMENTS; i++) {
            dynamicArray[i] = fixedArray[i];
        }
    }

    function _toDynamicBool(
        bool[DEFAULT_SEGMENTS] memory fixedArray
    ) internal pure returns (bool[] memory dynamicArray) {
        dynamicArray = new bool[](DEFAULT_SEGMENTS);
        for (uint16 i = 0; i < DEFAULT_SEGMENTS; i++) {
            dynamicArray[i] = fixedArray[i];
        }
    }

    /**
     * @dev calculates the maximum wager allowed based on the bankroll size
     */
    function _kellyWager(
        uint256 wagerPerBet,
        uint256 maxPayoutPerBet,
        address tokenAddress,
        uint256 tokenId,
        uint8 configId
    ) internal view {
        uint256 balance = Bankroll().isERC1155Token(tokenAddress)
            ? Bankroll().getAvailableBalance(tokenAddress, tokenId)
            : Bankroll().getAvailableBalance(tokenAddress);
        uint256 maxWager = (balance * KELLY_LIMIT_BP) / BP;

        // Legacy profile caps wager-per-bet, while high-variance-style profiles
        // cap max payout per bet to the same bankroll percentage.
        if (configId == LEGACY_CONFIG_ID) {
            if (wagerPerBet > maxWager) {
                revert WagerAboveLimit(wagerPerBet, maxWager);
            }
            return;
        }

        if (maxPayoutPerBet > maxWager) {
            revert WagerAboveLimit(maxPayoutPerBet, maxWager);
        }
    }
}