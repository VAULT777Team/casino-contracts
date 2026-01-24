// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {
    Common, IBankLP, IBankrollRegistry,
    ChainSpecificUtil,
    IERC20, SafeERC20,
    VRFConsumerBaseV2Plus, IVRFCoordinatorV2Plus,
    IDecimalAggregator
} from "../Common.sol";

/**
 * @title Coin Flip game, players predict if outcome will be heads or tails
 */

contract CoinFlip is Common {
    using SafeERC20 for IERC20;

    constructor(
        address _registry,
        address _vrf,
        address link_eth_feed
    ) VRFConsumerBaseV2Plus(_vrf) {
        b_registry      = IBankrollRegistry(_registry);
        ChainLinkVRF    = _vrf;
        s_Coordinator   = IVRFCoordinatorV2Plus(_vrf);
        LINK_ETH_FEED   = IDecimalAggregator(link_eth_feed);
    }

    struct CoinFlipGame {
        uint256 wager;
        uint256 stopGain;
        uint256 stopLoss;
        uint256 requestID;
        address tokenAddress;
        uint64 blockNumber;
        uint32 numBets;
        uint256 maxPayout;
        bool isHeads;
    }

    mapping(address => CoinFlipGame) coinFlipGames;
    mapping(uint256 => address) coinIDs;

    /**
     * @dev event emitted at the start of the game
     * @param playerAddress address of the player that made the bet
     * @param wager wagered amount
     * @param tokenAddress address of token the wager was made, 0 address is considered the native coin
     * @param isHeads player bet on which side the coin will land  1-> Heads, 0 ->Tails
     * @param numBets number of bets the player intends to make
     * @param stopGain gain value at which the betting stop if a gain is reached
     * @param stopLoss loss value at which the betting stop if a loss is reached
     */
    event CoinFlip_Play_Event(
        address indexed playerAddress,
        uint256 wager,
        address tokenAddress,
        bool isHeads,
        uint32 numBets,
        uint256 stopGain,
        uint256 stopLoss,
        uint256 VRFFee
    );
    /**
     * @dev event emitted by the VRF callback with the bet results
     * @param playerAddress address of the player that made the bet
     * @param wager wager amount
     * @param payout total payout transfered to the player
     * @param tokenAddress address of token the wager was made and payout, 0 address is considered the native coin
     * @param coinOutcomes results of coinFlip, 1-> Heads, 0 ->Tails
     * @param payouts individual payouts for each bet
     * @param numGames number of games performed
     */
    event CoinFlip_Outcome_Event(
        address indexed playerAddress,
        uint256 wager,
        uint256 payout,
        address tokenAddress,
        uint8[] coinOutcomes,
        uint256[] payouts,
        uint32 numGames
    );

    /**
     * @dev event emitted when a refund is done in coin flip
     * @param player address of the player reciving the refund
     * @param wager amount of wager that was refunded
     * @param tokenAddress address of token the refund was made in
     */
    event CoinFlip_Refund_Event(
        address indexed player,
        uint256 wager,
        address tokenAddress
    );

    error WagerAboveLimit(uint256 wager, uint256 maxWager);
    error AwaitingVRF(uint256 requestID);
    error InvalidNumBets(uint256 maxNumBets);
    error NotAwaitingVRF();
    error BlockNumberTooLow(uint256 have, uint256 want);

    /**
     * @dev function to get current request player is await from VRF, returns 0 if none
     * @param player address of the player to get the state
     */
    function CoinFlip_GetState(
        address player
    ) external view returns (CoinFlipGame memory) {
        return (coinFlipGames[player]);
    }

    /**
     * @dev Function to play Coin Flip, takes the user wager saves bet parameters and makes a request to the VRF
     * @param wager wager amount
     * @param tokenAddress address of token to bet, 0 address is considered the native coin
     * @param numBets number of bets to make, and amount of random numbers to request
     * @param stopGain treshold value at which the bets stop if a certain profit is obtained
     * @param stopLoss treshold value at which the bets stop if a certain loss is obtained
     * @param isHeads if bet selected heads or Tails
     */
    function CoinFlip_Play(
        uint256 wager,
        address tokenAddress,
        bool isHeads,
        uint32 numBets,
        uint256 stopGain,
        uint256 stopLoss
    ) external payable nonReentrant {
        address msgSender = _msgSender();
        if (coinFlipGames[msgSender].requestID != 0) {
            revert AwaitingVRF(coinFlipGames[msgSender].requestID);
        }
        if (!(numBets > 0 && numBets <= 100)) {
            revert InvalidNumBets(100);
        }

        uint256 maxPayout;
        if(stopGain > 0){
            maxPayout = stopGain = (wager * numBets);
        } else {
            maxPayout = (wager * numBets * 19800) / 10000;
        }

        _reserveMaxPayout(tokenAddress, maxPayout);

        _kellyWager(wager, tokenAddress);
        uint256 fee = _transferWager(
            tokenAddress,
            wager * numBets,
            700000,
            22,
            msgSender
        );

        uint256 id = _requestRandomWords(numBets);

        coinFlipGames[msgSender] = CoinFlipGame({
            requestID: id,
            wager: wager,
            stopGain: stopGain,
            stopLoss: stopLoss,
            tokenAddress: tokenAddress,
            blockNumber: uint64(ChainSpecificUtil.getBlockNumber()),
            numBets: numBets,
            maxPayout: maxPayout,
            isHeads: isHeads
        });

        coinIDs[id] = msgSender;

        emit CoinFlip_Play_Event(
            msgSender,
            wager,
            tokenAddress,
            isHeads,
            numBets,
            stopGain,
            stopLoss,
            fee
        );
    }

    /**
     * @dev Function to refund user in case of VRF request failling
     */
    function CoinFlip_Refund() external nonReentrant {
        address msgSender = _msgSender();
        CoinFlipGame storage game = coinFlipGames[msgSender];
        if (game.requestID == 0) {
            revert NotAwaitingVRF();
        }
        if (game.blockNumber + 200 > uint64(ChainSpecificUtil.getBlockNumber())) {
            revert BlockNumberTooLow(ChainSpecificUtil.getBlockNumber(), game.blockNumber + 200);
        }

        uint256 wager = game.wager * game.numBets;
        address tokenAddress = game.tokenAddress;

        _releaseReserve(game.tokenAddress, game.maxPayout);

        delete (coinIDs[game.requestID]);
        delete (coinFlipGames[msgSender]);

        if (tokenAddress == address(0)) {
            (bool success, ) = payable(msgSender).call{value: wager}("");
            if (!success) {
                revert TransferFailed();
            }
        } else {
            IERC20(tokenAddress).safeTransfer(msgSender, wager);
        }
        emit CoinFlip_Refund_Event(msgSender, wager, tokenAddress);
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        address playerAddress = coinIDs[requestId];
        if (playerAddress == address(0)) revert();
        CoinFlipGame storage game = coinFlipGames[playerAddress];

        int256 totalValue;
        uint256 payout;
        uint32 i;
        uint8[] memory coinFlip = new uint8[](game.numBets);
        uint256[] memory payouts = new uint256[](game.numBets);

        address tokenAddress = game.tokenAddress;

        for (i = 0; i < game.numBets; i++) {
            if (totalValue >= int256(game.stopGain)) {
                break;
            }
            if (totalValue <= -int256(game.stopLoss)) {
                break;
            }

            coinFlip[i] = uint8(randomWords[i] % 2);

            if (coinFlip[i] == 1 && game.isHeads == true) {
                totalValue += int256((game.wager * 9800) / 10000);
                payout += (game.wager * 19800) / 10000;
                payouts[i] = (game.wager * 19800) / 10000;
                continue;
            }
            if (coinFlip[i] == 0 && game.isHeads == false) {
                totalValue += int256((game.wager * 9800) / 10000);
                payout += (game.wager * 19800) / 10000;
                payouts[i] = (game.wager * 19800) / 10000;
                continue;
            }

            totalValue -= int256(game.wager);
        }

        _releaseReserve(tokenAddress, game.maxPayout);

        payout += (game.numBets - i) * game.wager;

        emit CoinFlip_Outcome_Event(
            playerAddress,
            game.wager,
            payout,
            tokenAddress,
            coinFlip,
            payouts,
            i
        );
        _transferToBankroll(tokenAddress, game.wager * game.numBets);
        delete (coinIDs[requestId]);
        delete (coinFlipGames[playerAddress]);
        if (payout != 0) {
            _transferPayout(playerAddress, payout, tokenAddress);
        }
    }

    /**
     * @dev calculates the maximum wager allowed based on the bankroll size
     take into account numBets
     */
    function _kellyWager(uint256 wager, address tokenAddress) internal view {
        uint256 balance = Bankroll().getAvailableBalance(tokenAddress);
        uint256 maxWager = (balance * 1122448) / 100000000;

        if(wager > maxWager){
            revert WagerAboveLimit(wager, maxWager);
        }
    }
}
