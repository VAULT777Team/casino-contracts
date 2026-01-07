// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "../../Common.sol";

/**
 * @title American Roulette Game (00 wheel)
 * @notice Based on the same architecture as CoinFlip — batch bets using VRF
 */

contract EuropeanRoulette is Common {
    using SafeERC20 for IERC20;

    constructor(
        address _bankroll,
        address _vrf,
        address link_eth_feed,
        address _forwarder
    ) VRFConsumerBaseV2Plus(_vrf) {
        Bankroll        = IBankRoll(_bankroll);
        ChainLinkVRF    = _vrf;
        s_Coordinator   = IVRFCoordinatorV2Plus(_vrf);
        LINK_ETH_FEED   = IDecimalAggregator(link_eth_feed);
        _trustedForwarder = _forwarder;
    }

    // -----------------------------
    // ROULETTE BET TYPES
    // -----------------------------
    enum BetType {
        STRAIGHT,      // betValue = number 0–36 or 37 for 00   (pays 35:1)
        RED,           // betValue ignored                      (pays 1:1)
        BLACK,         // betValue ignored                      (pays 1:1)
        ODD,           // pays 1:1
        EVEN,          // pays 1:1
        LOW,           // 1–18 (pays 1:1)
        HIGH,          // 19–36 (pays 1:1)
        DOZEN,         // betValue = 1,2,3 (pays 2:1)
        COLUMN         // betValue = 1,2,3 (pays 2:1)
    }

    struct RouletteGame {
        uint256 wager;
        uint256 stopGain;
        uint256 stopLoss;
        uint256 requestID;
        address tokenAddress;
        uint64 blockNumber;
        uint32 numBets;

        BetType betType;
        uint32 betValue; // depends on type
    }

    mapping(address => RouletteGame) public rouletteGames;
    mapping(uint256 => address) public rouletteIDs;

    // -----------------------------
    // EVENTS
    // -----------------------------
    event Roulette_Play_Event(
        address indexed playerAddress,
        uint256 wager,
        address tokenAddress,
        BetType betType,
        uint32 betValue,
        uint32 numBets,
        uint256 stopGain,
        uint256 stopLoss,
        uint256 VRFFee
    );

    event Roulette_Outcome_Event(
        address indexed playerAddress,
        uint256 wager,
        uint256 payout,
        address tokenAddress,
        uint8[] results,
        uint256[] payouts,
        uint32 numGames
    );

    event Roulette_Refund_Event(
        address indexed player,
        uint256 wager,
        address tokenAddress
    );

    // -----------------------------
    // ERROR TYPES
    // -----------------------------
    error WagerAboveLimit(uint256 wager, uint256 maxWager);
    error AwaitingVRF(uint256 requestID);
    error InvalidNumBets(uint256 maxNumBets);
    error NotAwaitingVRF();
    error BlockNumberTooLow(uint256 have, uint256 want);

    // -----------------------------
    // READ STATE
    // -----------------------------
    function Roulette_GetState(
        address player
    ) external view returns (RouletteGame memory) {
        return rouletteGames[player];
    }

    // -----------------------------
    // PLAY FUNCTION
    // -----------------------------
    function Roulette_Play(
        uint256 wager,
        address tokenAddress,
        BetType betType,
        uint32 betValue,
        uint32 numBets,
        uint256 stopGain,
        uint256 stopLoss
    ) external payable nonReentrant {
        address msgSender = _msgSender();

        if (rouletteGames[msgSender].requestID != 0)
            revert AwaitingVRF(rouletteGames[msgSender].requestID);

        if (!(numBets > 0 && numBets <= 200))
            revert InvalidNumBets(200);

        _kellyWager(wager, numBets, tokenAddress);

        uint256 fee = _transferWager(
            tokenAddress,
            wager * numBets,
            900000,
            22,
            msgSender
        );

        uint256 requestID = _requestRandomWords(numBets);

        rouletteGames[msgSender] = RouletteGame(
            wager,
            stopGain,
            stopLoss,
            requestID,
            tokenAddress,
            uint64(ChainSpecificUtil.getBlockNumber()),
            numBets,
            betType,
            betValue
        );

        rouletteIDs[requestID] = msgSender;

        emit Roulette_Play_Event(
            msgSender,
            wager,
            tokenAddress,
            betType,
            betValue,
            numBets,
            stopGain,
            stopLoss,
            fee
        );
    }

    // -----------------------------
    // REFUND FUNCTION
    // -----------------------------
    function Roulette_Refund() external nonReentrant {
        address msgSender = _msgSender();
        RouletteGame storage game = rouletteGames[msgSender];

        if (game.requestID == 0) revert NotAwaitingVRF();

        if (game.blockNumber + 200 > uint64(ChainSpecificUtil.getBlockNumber()))
            revert BlockNumberTooLow(
                ChainSpecificUtil.getBlockNumber(),
                game.blockNumber + 200
            );

        uint256 wagerAmount = game.wager * game.numBets;
        address tokenAddress = game.tokenAddress;

        delete rouletteIDs[game.requestID];
        delete rouletteGames[msgSender];

        if (tokenAddress == address(0)) {
            (bool success, ) = payable(msgSender).call{value: wagerAmount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(tokenAddress).safeTransfer(msgSender, wagerAmount);
        }

        emit Roulette_Refund_Event(msgSender, wagerAmount, tokenAddress);
    }

    // -----------------------------
    // PAY TABLE LOGIC
    // multiplier * 10000
    // -----------------------------
    function _payoutFor(
        BetType betType,
        uint32 betValue,
        uint8 result
    ) internal pure returns (uint256 multiplier) {
        // Straight number
        if (betType == BetType.STRAIGHT) {
            if (result == betValue) return 360000; // 36.00x
            return 0;
        }

        // Red/Black (American wheel reds)
        if (betType == BetType.RED) {
            bool isRed = (
                result == 1 || result == 3 || result == 5 || result == 7 ||
                result == 9 || result == 12|| result == 14|| result == 16||
                result == 18|| result == 19|| result == 21|| result == 23||
                result == 25|| result == 27|| result == 30|| result == 32||
                result == 34|| result == 36
            );
            return isRed ? 20000 : 0; // 2.00x
        }

        if (betType == BetType.BLACK) {
            bool isBlack = (
                result == 2 || result == 4 || result == 6 || result == 8 ||
                result == 10|| result == 11|| result == 13|| result == 15||
                result == 17|| result == 20|| result == 22|| result == 24||
                result == 26|| result == 28|| result == 29|| result == 31||
                result == 33|| result == 35
            );
            return isBlack ? 20000 : 0;
        }

        // EVEN/ODD  
        if (betType == BetType.ODD) {
            return (result != 0 && result != 37 && result % 2 == 1) ? 20000 : 0;
        }
        if (betType == BetType.EVEN) {
            return (result != 0 && result != 37 && result % 2 == 0) ? 20000 : 0;
        }

        // HIGH/LOW
        if (betType == BetType.LOW) {
            return (result >= 1 && result <= 18) ? 20000 : 0;
        }
        if (betType == BetType.HIGH) {
            return (result >= 19 && result <= 36) ? 20000 : 0;
        }

        // DOZEN (1st, 2nd, 3rd)
        if (betType == BetType.DOZEN) {
            if (result >= 1 && result <= 12 && betValue == 1) return 30000;
            if (result >= 13 && result <= 24 && betValue == 2) return 30000;
            if (result >= 25 && result <= 36 && betValue == 3) return 30000;
            return 0;
        }

        // COLUMN (1,2,3)
        if (betType == BetType.COLUMN) {
            if (betValue == ((result % 3 == 0) ? 3 : (result % 3))) return 30000;
        }

        return 0;
    }

    // -----------------------------
    // VRF CALLBACK
    // -----------------------------
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        address playerAddress = rouletteIDs[requestId];
        if (playerAddress == address(0)) revert();

        RouletteGame storage game = rouletteGames[playerAddress];

        int256 totalValue;
        uint256 payout;

        uint8[] memory results = new uint8[](game.numBets);
        uint256[] memory payouts = new uint256[](game.numBets);

        address tokenAddress = game.tokenAddress;

        uint32 i = 0;
        for (; i < game.numBets; i++) {
            if (totalValue >= int256(game.stopGain)) break;
            if (totalValue <= -int256(game.stopLoss)) break;

            uint8 result = uint8(randomWords[i] % 38); // 0–36, 37 = "00"
            results[i] = result;

            uint256 m = _payoutFor(game.betType, game.betValue, result);

            if (m > 0) {
                uint256 win = (game.wager * m) / 10000;
                payouts[i] = win;
                payout += win;
                totalValue += int256(win) - int256(game.wager);
            } else {
                totalValue -= int256(game.wager);
            }
        }

        payout += (game.numBets - i) * game.wager; // refund remaining unplayed

        emit Roulette_Outcome_Event(
            playerAddress,
            game.wager,
            payout,
            tokenAddress,
            results,
            payouts,
            i
        );

        _transferToBankroll(tokenAddress, game.wager * game.numBets);

        delete rouletteIDs[requestId];
        delete rouletteGames[playerAddress];

        if (payout != 0) {
            _transferPayout(playerAddress, payout, tokenAddress);
        }
    }

    // -----------------------------
    // KELLY LIMIT
    // -----------------------------
    function _kellyWager(
        uint256 wager,
        uint256 numBets,
        address tokenAddress
    ) internal view {
        uint256 balance = tokenAddress == address(0)
            ? address(Bankroll).balance
            : IERC20(tokenAddress).balanceOf(address(Bankroll));

        uint256 maxWager = (balance * 1122448) / 100000000;
        uint256 exposure = wager * numBets;

        if (wager > maxWager || exposure > maxWager)
            revert WagerAboveLimit(wager, maxWager);
    }
}
