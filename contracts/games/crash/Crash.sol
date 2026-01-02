// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {
    Common, IBankrollRegistry,
    ChainSpecificUtil,
    IERC20, SafeERC20,
    VRFConsumerBaseV2Plus, IVRFCoordinatorV2Plus,
    IDecimalAggregator
} from "../../Common.sol";

/**
 * @title Crash game, players continue to multiply their wager until they cash out or the game crashes
 */

contract Crash is Common {
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

    struct CrashGame {
        uint256 wager;
        address tokenAddress;
        uint64 blockNumber;
        bool active;
        bool finished;
        bool crashed;
        uint8 currentStep; // street number (starts at 0)
        uint256 currentMultiplier; // 1e4 precision
        uint256 requestID; // for VRF
    }
    
    // Per round state
    struct CrashRound {
        uint256 crashMultiplier; // 1e4 precision (e.g., 15000 = 1.5x)
        bool    finished;
    }
    
    mapping(address => CrashGame) crashGames;
    mapping(uint256 => address) crashIDs;

    mapping(uint256 => CrashRound) public crashRounds;
    uint256 public currentRoundId;

    /**
     * @dev event emitted at the start of the game
     * @param playerAddress address of the player that made the bet
     * @param wager wagered amount
     * @param tokenAddress address of token the wager was made, 0 address is considered the native coin
     * @param VRFFee VRF fee paid by the player
     */
    event Crash_Play_Event(
        address indexed playerAddress,
        uint256 wager,
        address tokenAddress,
        uint256 VRFFee
    );
    event Crash_Cross_Event(
        address indexed playerAddress,
        uint8 street,
        uint256 multiplier,
        uint256 requestID
    );
    event Crash_Cashout_Event(
        address indexed playerAddress,
        uint8 street,
        uint256 multiplier,
        uint256 payout
    );
    event Crash_Crash_Event(
        address indexed playerAddress,
        uint8 street,
        uint256 multiplier
    );

    // NOTE: Outcome details are emitted via Crash_Cross_Event / Crash_Cashout_Event / Crash_Crash_Event.

    /**
     * @dev event emitted when a refund is done in crash
     * @param player address of the player reciving the refund
     * @param wager amount of wager that was refunded
     * @param tokenAddress address of token the refund was made in
     */
    event Crash_Refund_Event(
        address indexed player,
        uint256 wager,
        address tokenAddress
    );

    error AwaitingVRF(uint256 requestID);
    error InvalidMultiplier(uint256 max, uint256 min, uint256 multiplier);
    error InvalidNumBets(uint256 maxNumBets);
    error WagerAboveLimit(uint256 wager, uint256 maxWager);
    error NotAwaitingVRF();
    error BlockNumberTooLow(uint256 have, uint256 want);

    /**
     * @dev function to get current request player is await from VRF, returns 0 if none
     * @param player address of the player to get the state
     */
    function Crash_GetState(
        address player
    ) external view returns (CrashGame memory) {
        return (crashGames[player]);
    }

    /**
     * @dev Start a new crash session for the caller.
     * @param wager wager amount
     * @param tokenAddress address of token to bet, 0 address is considered the native coin
     */
    function Crash_Play(
        uint256 wager,
        address tokenAddress
    ) external payable nonReentrant {
        address msgSender = _msgSender();
        require(!crashGames[msgSender].active, "Already in game");
        require(wager > 0, "Wager required");
        uint256 fee = _transferWager(
            tokenAddress,
            wager,
            700000,
            21,
            msgSender
        );
        crashGames[msgSender] = CrashGame({
            wager: wager,
            tokenAddress: tokenAddress,
            blockNumber: uint64(ChainSpecificUtil.getBlockNumber()),
            active: true,
            finished: false,
            crashed: false,
            currentStep: 0,
            currentMultiplier: 11000, // 1.10x (1e4 precision)
            requestID: 0
        });
        emit Crash_Play_Event(msgSender, wager, tokenAddress, fee);
    }

    // Player chooses to cross to the next street (step)
    function Crash_Cross() external nonReentrant {
        CrashGame storage game = crashGames[_msgSender()];
        require(game.active && !game.finished && !game.crashed, "Not in active game");
        require(game.currentStep < 10, "Max steps reached");
        // Request randomness for crash check
        uint256 id = _requestRandomWords(1);
        game.requestID = id;
        crashIDs[id] = _msgSender();
        emit Crash_Cross_Event(_msgSender(), game.currentStep + 1, _nextMultiplier(game.currentStep + 1), id);
    }

    // Player can cash out at any time before crash
    function Crash_Cashout() external nonReentrant {
        CrashGame storage game = crashGames[_msgSender()];
        require(game.active && !game.finished && !game.crashed, "Not in active game");
        uint256 payout = (game.wager * game.currentMultiplier) / 1e4;
        game.finished = true;
        game.active = false;
        _transferPayout(_msgSender(), payout, game.tokenAddress);
        emit Crash_Cashout_Event(_msgSender(), game.currentStep, game.currentMultiplier, payout);
    }

    // Multiplier progression per street (step)
    function _nextMultiplier(uint8 step) internal pure returns (uint256) {
        if (step == 1) return 12000; // 1.20x
        if (step == 2) return 14000; // 1.40x
        if (step == 3) return 18000; // 1.80x
        if (step == 4) return 26000; // 2.60x
        if (step == 5) return 40000; // 4.00x
        if (step == 6) return 60000; // 6.00x
        if (step == 7) return 100000; // 10.00x
        return 200000; // 20.00x or more
    }

    /**
     * @dev Function to refund user in case of VRF request failling
     */
    function Crash_Refund() external nonReentrant {
        address msgSender = _msgSender();
        CrashGame storage game = crashGames[msgSender];
        if (!game.active) revert NotAwaitingVRF();
        if (game.blockNumber + 200 > uint64(ChainSpecificUtil.getBlockNumber())) {
            revert BlockNumberTooLow(uint64(ChainSpecificUtil.getBlockNumber()), game.blockNumber + 200);
        }
        uint256 wager = game.wager;
        address tokenAddress = game.tokenAddress;
        delete (crashIDs[game.requestID]);
        delete (crashGames[msgSender]);
        if (tokenAddress == address(0)) {
            (bool success, ) = payable(msgSender).call{value: wager}("");
            if (!success) {
                revert TransferFailed();
            }
        } else {
            IERC20(tokenAddress).safeTransfer(msgSender, wager);
        }
        emit Crash_Refund_Event(msgSender, wager, tokenAddress);
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        address playerAddress = crashIDs[requestId];
        if (playerAddress == address(0)) revert();
        CrashGame storage game = crashGames[playerAddress];
        require(game.active && !game.finished && !game.crashed, "Not in active game");
        // 1 in N chance to crash at each step (e.g., 1/6 for step 6)
        uint8 step = game.currentStep + 1;
        bool didCrash = false;
        if (step == 6) {
            didCrash = true;
        } else {
            // For demo: 1/6 chance to crash at each step after 1
            uint256 crashChance = 6;
            if (step > 1 && (randomWords[0] % crashChance == 0)) {
                didCrash = true;
            }
        }
        if (didCrash) {
            game.crashed = true;
            game.active = false;
            emit Crash_Crash_Event(playerAddress, step, _nextMultiplier(step));
        } else {
            game.currentStep = step;
            game.currentMultiplier = _nextMultiplier(step);
            emit Crash_Cross_Event(playerAddress, step, game.currentMultiplier, requestId);
        }
        delete crashIDs[requestId];
    }

    /**
     * @dev calculates the maximum wager allowed based on the bankroll size
     */
    // No Kelly for Crash, but you may add bankroll risk logic here if needed
}
