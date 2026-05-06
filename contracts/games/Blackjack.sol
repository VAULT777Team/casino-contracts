// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {
    Common, IBankrollRegistry,
    ChainSpecificUtil,
    IERC20, SafeERC20,
    IDecimalAggregator
} from "../Common.sol";

/**
 * @title blackjack game, players play against dealer to reach 21 without going over
 */
contract Blackjack is Common {
    using SafeERC20 for IERC20;

    constructor(
        address _registry
    ) {
        b_registry      = IBankrollRegistry(_registry);
    }

    struct BlackjackGame {
        uint256 baseWager;
        uint256 wager;
        uint256 requestID;
        address tokenAddress;
        uint64 blockNumber;
        uint8[10] playerCards; // max 10 cards
        uint8[10] dealerCards;
        uint8 playerCardCount;
        uint8 dealerCardCount;
        uint8 playerScore;
        uint8 dealerScore;
        bool playerBust;
        bool dealerBust;
        bool playerStand;
        bool doubledDown;
        bool doubleDownPending;
        bool gameActive;
        bool isInitialDeal;
    }

    mapping(address => BlackjackGame) blackjackGames;
    mapping(uint256 => address) blackjackIDs;

    event Blackjack_Start_Event(
        address indexed playerAddress,
        uint256 wager,
        address tokenAddress,
        uint8[2] playerCards,
        uint8 dealerUpCard,
        uint8 playerScore,
        uint256 VRFFee
    );

    event Blackjack_Hit_Event(
        address indexed playerAddress,
        uint8 newCard,
        uint8 playerScore,
        bool bust,
        uint256 VRFFee
    );

    event Blackjack_Stand_Event(
        address indexed playerAddress,
        uint256 requestID,
        uint256 VRFFee
    );

    event Blackjack_DoubleDown_Event(
        address indexed playerAddress,
        uint256 additionalWager,
        uint256 totalWager,
        uint256 requestID,
        uint256 VRFFee
    );

    event Blackjack_Surrender_Event(
        address indexed playerAddress,
        uint256 wager,
        uint256 refund,
        address tokenAddress
    );

    event Blackjack_Outcome_Event(
        address indexed playerAddress,
        uint256 wager,
        uint256 payout,
        address tokenAddress,
        uint8 finalPlayerScore,
        uint8 finalDealerScore,
        bool playerWin,
        bool push,
        uint8[10] playerCards,
        uint8 playerCardCount,
        uint8[10] dealerCards,
        uint8 dealerCardCount
    );

    event Blackjack_Refund_Event(
        address indexed player,
        uint256 wager,
        address tokenAddress
    );

    error AlreadyInGame();
    error NotInGame();
    error AwaitingVRF(uint256 requestID);
    error GameNotActive();
    error PlayerAlreadyStood();
    error DoubleDownNotAllowed();
    error AlreadyDoubledDown();
    error SurrenderNotAllowed();
    error WagerAboveLimit(uint256 wager, uint256 maxWager);
    error NoRequestPending();
    error BlockNumberTooLow(uint256 have, uint256 want);

    function Blackjack_GetState(
        address player
    ) external view returns (BlackjackGame memory) {
        return blackjackGames[player];
    }

    function Blackjack_Start(
        uint256 wager,
        address tokenAddress
    ) external payable nonReentrant {
        address msgSender = _msgSender();
        BlackjackGame storage game = blackjackGames[msgSender];
        
        if (game.requestID != 0) {
            revert AwaitingVRF(game.requestID);
        }
        if (game.gameActive) {
            revert AlreadyInGame();
        }

        _kellyWager(wager, tokenAddress);
        _transferWager(
            tokenAddress,
            wager,
            600000,
            msgSender
        );

        uint256 id = _requestRandomWords(3); // 2 player + 1 dealer up-card

        game.baseWager = wager;
        game.wager = wager;
        game.tokenAddress = tokenAddress;
        game.requestID = id;
        game.blockNumber = uint64(ChainSpecificUtil.getBlockNumber());
        game.gameActive = true;
        game.isInitialDeal = true;
        game.playerCardCount = 0;
        game.dealerCardCount = 0;
        game.playerScore = 0;
        game.dealerScore = 0;
        game.playerBust = false;
        game.dealerBust = false;
        game.playerStand = false;
        game.doubledDown = false;
        game.doubleDownPending = false;

        blackjackIDs[id] = msgSender;

        emit Blackjack_Start_Event(
            msgSender,
            wager,
            tokenAddress,
            [0, 0], // will be filled after VRF
            0,
            0,
            0
        );
    }

    function Blackjack_Hit() external payable nonReentrant {
        address msgSender = _msgSender();
        BlackjackGame storage game = blackjackGames[msgSender];

        if (!game.gameActive) {
            revert GameNotActive();
        }
        if (game.requestID != 0) {
            revert AwaitingVRF(game.requestID);
        }
        if (game.playerStand) {
            revert PlayerAlreadyStood();
        }

        uint256 id = _requestRandomWords(1);

        game.requestID = id;
        game.blockNumber = uint64(ChainSpecificUtil.getBlockNumber());
        blackjackIDs[id] = msgSender;

        emit Blackjack_Hit_Event(msgSender, 0, 0, false, 0);
    }

    function Blackjack_Stand() external payable nonReentrant {
        address msgSender = _msgSender();
        BlackjackGame storage game = blackjackGames[msgSender];

        if (!game.gameActive) {
            revert GameNotActive();
        }
        if (game.requestID != 0) {
            revert AwaitingVRF(game.requestID);
        }

        game.playerStand = true;

        // Resolve dealer draw using VRF so the outcome can't be computed and reverted
        // within the same transaction.
        uint256 id = _requestRandomWords(9); // dealer can draw up to 9 more cards (10 max, 1 already dealt)

        game.requestID = id;
        game.blockNumber = uint64(ChainSpecificUtil.getBlockNumber());
        blackjackIDs[id] = msgSender;

        emit Blackjack_Stand_Event(msgSender, id, 0);
    }

    function Blackjack_DoubleDown() external payable nonReentrant {
        address msgSender = _msgSender();
        BlackjackGame storage game = blackjackGames[msgSender];

        if (!game.gameActive) {
            revert GameNotActive();
        }
        if (game.requestID != 0) {
            revert AwaitingVRF(game.requestID);
        }
        if (game.playerStand) {
            revert PlayerAlreadyStood();
        }
        if (game.doubledDown || game.doubleDownPending) {
            revert AlreadyDoubledDown();
        }
        if (game.playerBust || game.playerCardCount != 2) {
            revert DoubleDownNotAllowed();
        }

        uint256 additionalWager = game.baseWager;
        uint256 newTotalWager = game.wager + additionalWager;
        _kellyWager(newTotalWager, game.tokenAddress);

        _transferWager(
            game.tokenAddress,
            additionalWager,
            800000,
            msgSender
        );

        uint256 id = _requestRandomWords(10); // 1 player card + up to 9 dealer cards

        game.wager = newTotalWager;
        game.doubledDown = true;
        game.doubleDownPending = true;
        game.requestID = id;
        game.blockNumber = uint64(ChainSpecificUtil.getBlockNumber());
        blackjackIDs[id] = msgSender;

        emit Blackjack_DoubleDown_Event(msgSender, additionalWager, newTotalWager, id, 0);
    }

    function Blackjack_Surrender() external nonReentrant {
        address msgSender = _msgSender();
        BlackjackGame storage game = blackjackGames[msgSender];

        if (!game.gameActive) {
            revert GameNotActive();
        }
        if (game.requestID != 0) {
            revert AwaitingVRF(game.requestID);
        }
        if (game.playerStand) {
            revert PlayerAlreadyStood();
        }
        if (game.doubledDown || game.doubleDownPending || game.playerBust || game.playerCardCount != 2) {
            revert SurrenderNotAllowed();
        }

        uint256 wager = game.wager;
        address tokenAddress = game.tokenAddress;
        uint256 refund = wager / 2;

        _transferToBankroll(tokenAddress, wager);
        delete blackjackGames[msgSender];

        if (refund > 0) {
            _transferPayout(msgSender, refund, tokenAddress);
        }

        emit Blackjack_Surrender_Event(msgSender, wager, refund, tokenAddress);
    }

    function Blackjack_Refund() external nonReentrant {
        address msgSender = _msgSender();
        BlackjackGame storage game = blackjackGames[msgSender];
        
        if (!game.gameActive) {
            revert NotInGame();
        }
        if (game.requestID == 0) {
            revert NoRequestPending();
        }
        if (game.blockNumber + 200 > uint64(ChainSpecificUtil.getBlockNumber())) {
            revert BlockNumberTooLow(ChainSpecificUtil.getBlockNumber(), game.blockNumber + 200);
        }

        uint256 wager = game.wager;
        address tokenAddress = game.tokenAddress;

        delete blackjackGames[msgSender];

        if (tokenAddress == address(0)) {
            (bool success, ) = payable(msgSender).call{value: wager}("");
            if (!success) {
                revert TransferFailed();
            }
        } else {
            IERC20(tokenAddress).safeTransfer(msgSender, wager);
        }
        
        emit Blackjack_Refund_Event(msgSender, wager, tokenAddress);
    }

    function _fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        address player = blackjackIDs[requestId];
        if (player == address(0)) revert();
        
        delete blackjackIDs[requestId];
        BlackjackGame storage game = blackjackGames[player];
        game.requestID = 0;

        if (game.isInitialDeal) {
            // initial deal: 2 cards to player, 1 to dealer
            game.playerCards[0] = _getCard(randomWords[0]);
            game.playerCards[1] = _getCard(randomWords[1]);
            game.dealerCards[0] = _getCard(randomWords[2]);
            
            game.playerCardCount = 2;
            game.dealerCardCount = 1;
            game.playerScore = _calculateScore(game.playerCards, game.playerCardCount);
            game.dealerScore = _calculateScore(game.dealerCards, game.dealerCardCount);
            game.isInitialDeal = false;

            // check for blackjack
            if (game.playerScore == 21) {
                // Auto-resolve dealer via VRF
                game.playerStand = true;
                _resolveDealerPlay(player, randomWords, 3);
                return;
            }
        } else {
            if (game.doubleDownPending) {
                game.doubleDownPending = false;

                game.playerCards[game.playerCardCount] = _getCard(randomWords[0]);
                game.playerCardCount++;
                game.playerScore = _calculateScore(game.playerCards, game.playerCardCount);

                if (game.playerScore > 21) {
                    game.playerBust = true;
                    _endGame(player, false, false);
                    return;
                }

                game.playerStand = true;
                _resolveDealerPlay(player, randomWords, 1);
            } else if (game.playerStand) {
                // stand: resolve dealer play using VRF randomness
                _resolveDealerPlay(player, randomWords, 0);
            } else {
                // hit: give player one more card
                game.playerCards[game.playerCardCount] = _getCard(randomWords[0]);
                game.playerCardCount++;
                game.playerScore = _calculateScore(game.playerCards, game.playerCardCount);

                // auto-stand on 21
                if(game.playerScore == 21){
                    // stand: resolve dealer play using VRF randomness
                    game.playerStand = true;
                    _resolveDealerPlay(player, randomWords, 0);
                }
                if (game.playerScore > 21) {
                    game.playerBust = true;
                    _endGame(player, false, false);
                }
            }
        }
    }

    function _resolveDealerPlay(
        address player,
        uint256[] calldata randomWords,
        uint256 startIndex
    ) internal {
        BlackjackGame storage game = blackjackGames[player];

        // dealer must hit on 16 and below, stand on 17 and above
        uint256 wordIndex = 0;

        while (game.dealerScore < 17 && game.dealerCardCount < 10) {
            uint256 rv;
            if (startIndex + wordIndex < randomWords.length) {
                rv = randomWords[startIndex + wordIndex];
            } else {
                // Safety fallback: derive extra entropy from VRF output if more words are unexpectedly needed.
                uint256 seed = randomWords.length > 0
                    ? randomWords[randomWords.length - 1]
                    : uint256(keccak256(abi.encodePacked(player, game.dealerCardCount)));
                rv = uint256(
                    keccak256(
                        abi.encodePacked(
                            seed,
                            wordIndex,
                            player,
                            game.dealerCardCount
                        )
                    )
                );
            }

            game.dealerCards[game.dealerCardCount] = _getCard(rv);
            game.dealerCardCount++;
            game.dealerScore = _calculateScore(game.dealerCards, game.dealerCardCount);
            wordIndex++;
        }

        if (game.dealerScore > 21) {
            game.dealerBust = true;
        }

        // determine winner
        bool playerWin = false;
        bool push = false;

        if (game.playerBust) {
            playerWin = false;
        } else if (game.dealerBust) {
            playerWin = true;
        } else if (game.playerScore > game.dealerScore) {
            playerWin = true;
        } else if (game.playerScore == game.dealerScore) {
            push = true;
        }

        _endGame(player, playerWin, push);
    }

    function _endGame(address player, bool playerWin, bool push) internal {
        BlackjackGame storage game = blackjackGames[player];
        
        uint256 payout = 0;
        if (push) {
            payout = game.wager; // return original wager
        } else if (playerWin) {
            // check for blackjack (21 with 2 cards)
            if (game.playerScore == 21 && game.playerCardCount == 2) {
                payout = (game.wager * 250) / 100; // 2.5x for blackjack
            } else {
                payout = (game.wager * 200) / 100; // 2x for regular win
            }
        }

        uint256 wager = game.wager;
        address tokenAddress = game.tokenAddress;

        _transferToBankroll(tokenAddress, wager);

        if (payout > 0) {
            _transferPayout(player, payout, tokenAddress);
        }

        emit Blackjack_Outcome_Event(
            player,
            wager,
            payout,
            tokenAddress,
            game.playerScore,
            game.dealerScore,
            playerWin,
            push,
            game.playerCards,
            game.playerCardCount,
            game.dealerCards,
            game.dealerCardCount
        );

        delete blackjackGames[player];
    }

    function _getCard(uint256 randomValue) internal pure returns (uint8) {
        uint8 cardValue = uint8((randomValue % 13) + 1);
        if (cardValue > 10) {
            return 10; // face cards worth 10
        }
        return cardValue;
    }

    function _calculateScore(uint8[10] memory cards, uint8 cardCount) internal pure returns (uint8) {
        uint8 score = 0;
        uint8 aces = 0;

        for (uint8 i = 0; i < cardCount; i++) {
            if (cards[i] == 1) {
                aces++;
                score += 11;
            } else {
                score += cards[i];
            }
        }

        // adjust for aces
        while (score > 21 && aces > 0) {
            score -= 10; // convert ace from 11 to 1
            aces--;
        }

        return score;
    }

    function _kellyWager(uint256 wager, address tokenAddress) internal view {
        uint256 balance;
        if (tokenAddress == address(0)) {
            balance = address(Bankroll()).balance;
        } else {
            balance = IERC20(tokenAddress).balanceOf(address(Bankroll()));
        }
        // conservative kelly for blackjack (~2% house edge)
        uint256 maxWager = (balance * 800000) / 100000000;
        if (wager > maxWager) {
            revert WagerAboveLimit(wager, maxWager);
        }
    }
}