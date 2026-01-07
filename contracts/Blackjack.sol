// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {
    Common, IBankrollRegistry,
    ChainSpecificUtil,
    IERC20, SafeERC20,
    VRFConsumerBaseV2Plus, IVRFCoordinatorV2Plus,
    IDecimalAggregator
} from "./Common.sol";

/**
 * @title blackjack game, players play against dealer to reach 21 without going over
 */
contract Blackjack is Common {
    using SafeERC20 for IERC20;

    constructor(
        address _registry,
        address _vrf,
        address link_eth_feed,
        address _forwarder
    ) VRFConsumerBaseV2Plus(_vrf) {
        b_registry      = IBankrollRegistry(_registry);
        ChainLinkVRF    = _vrf;
        s_Coordinator   = IVRFCoordinatorV2Plus(_vrf);
        LINK_ETH_FEED   = IDecimalAggregator(link_eth_feed);
        _trustedForwarder = _forwarder;
    }

    struct BlackjackGame {
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

    event Blackjack_Outcome_Event(
        address indexed playerAddress,
        uint256 wager,
        uint256 payout,
        address tokenAddress,
        uint8 finalPlayerScore,
        uint8 finalDealerScore,
        bool playerWin,
        bool push
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
        uint256 fee = _transferWager(
            tokenAddress,
            wager,
            600000,
            28,
            msgSender
        );

        uint256 id = _requestRandomWords(3); // 2 player + 1 dealer

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

        blackjackIDs[id] = msgSender;

        emit Blackjack_Start_Event(
            msgSender,
            wager,
            tokenAddress,
            [0, 0], // will be filled after VRF
            0,
            0,
            fee
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

        uint256 VRFFee = _payVRFFee(400000, 20);
        uint256 id = _requestRandomWords(1);

        game.requestID = id;
        game.blockNumber = uint64(ChainSpecificUtil.getBlockNumber());
        blackjackIDs[id] = msgSender;

        emit Blackjack_Hit_Event(msgSender, 0, 0, false, VRFFee);
    }

    function Blackjack_Stand() external nonReentrant {
        address msgSender = _msgSender();
        BlackjackGame storage game = blackjackGames[msgSender];

        if (!game.gameActive) {
            revert GameNotActive();
        }
        if (game.requestID != 0) {
            revert AwaitingVRF(game.requestID);
        }

        game.playerStand = true;

        // use request instead for VRF?
        //_requestRandomWords(1);
        _resolveDealerPlay(msgSender);
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

    function fulfillRandomWords(
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
                game.playerStand = true;
                _resolveDealerPlay(player);
            }
        } else {
            // hit: give player one more card
            game.playerCards[game.playerCardCount] = _getCard(randomWords[0]);
            game.playerCardCount++;
            game.playerScore = _calculateScore(game.playerCards, game.playerCardCount);

            if (game.playerScore > 21) {
                game.playerBust = true;
                _endGame(player, false, false);
            }
        }
    }

    /**
        //TODO: add VRF RNG to this
        //FIX: currently uses a hardcoded seed based on block.timestamp
        it should have a random number from VRF passed instead

        #VAU-02: Predictable Dealer Card Generation In _resolveDealerPlay()
        Use Chainlink VRF to generate random dealer cards instead of deterministic on-chain computation. 
        Request additional random words during the initial deal or when the player stands to ensure all dealer cards are truly random.
     */
    function _resolveDealerPlay(address player) internal {
        BlackjackGame storage game = blackjackGames[player];
        
        // dealer must hit on 16 and below, stand on 17 and above
        // simulate dealer drawing cards deterministically based on current state
        uint256 seed = uint256(keccak256(abi.encodePacked(block.timestamp, player, game.playerScore)));
        
        while (game.dealerScore < 17 && game.dealerCardCount < 10) {
            seed = uint256(keccak256(abi.encodePacked(seed, game.dealerCardCount)));
            game.dealerCards[game.dealerCardCount] = _getCard(seed);
            game.dealerCardCount++;
            game.dealerScore = _calculateScore(game.dealerCards, game.dealerCardCount);
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
        uint8 finalPlayerScore = game.playerScore;
        uint8 finalDealerScore = game.dealerScore;

        _transferToBankroll(tokenAddress, wager);
        delete blackjackGames[player];

        if (payout > 0) {
            _transferPayout(player, payout, tokenAddress);
        }

        emit Blackjack_Outcome_Event(
            player,
            wager,
            payout,
            tokenAddress,
            finalPlayerScore,
            finalDealerScore,
            playerWin,
            push
        );
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