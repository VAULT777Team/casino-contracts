// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {
    Common, IBankrollRegistry,
    IERC20, SafeERC20,
    IDecimalAggregator
} from "../Common.sol";

/**
 * @title Lottery game, players purchase tickets and a random winner is selected
 */

contract Lottery is Common {
    using SafeERC20 for IERC20;

    constructor(
        address _registry
    ) {
        b_registry      = IBankrollRegistry(_registry);
        
        lotteryEpochDuration = 1 days;
    }

    struct LotteryRound {
        uint256 prizePool;
        uint256 ticketPrice;
        uint256 totalTickets;
        uint256 startTime;
        uint256 endTime;
        uint256 requestID;
        address tokenAddress;
        address completer;
        address[] players;
        mapping(address => uint256) ticketCount;
        bool drawn;
        address winner;
        uint256 winningTicket;
    }

    /// @dev Monotonically increasing round id.
    uint256 public currentRound;
    uint256 public lotteryEpochDuration;
    uint256 public houseEdge = 200; // 2% house edge (basis points)

    /// @dev Reward paid to the user that triggers VRF completion after epoch end.
    ///      50 = 0.5%.
    uint256 public completionRewardBps = 50;

    /// @dev Active round per token (address(0) for native).
    mapping(address => uint256) public activeRoundId;

    /// @dev List of tokens with active rounds (for enumeration in UIs).
    address[] private activeTokens;
    mapping(address => uint256) private activeTokenIndexPlusOne;
    
    mapping(uint256 => LotteryRound) public lotteryRounds;
    mapping(uint256 => uint256) public vrfRequestToRound;

    event Lottery_Round_Started(
        uint256 indexed roundId,
        uint256 ticketPrice,
        address tokenAddress,
        uint256 startTime,
        uint256 endTime
    );

    event Lottery_Completion_Requested(
        uint256 indexed roundId,
        address indexed tokenAddress,
        uint256 indexed requestId,
        address completer,
        uint256 VRFFee
    );

    event Lottery_Round_Closed_NoTickets(
        uint256 indexed roundId,
        address indexed tokenAddress
    );

    event Lottery_Ticket_Purchased(
        uint256 indexed roundId,
        address indexed player,
        uint256 numTickets,
        uint256 totalCost
    );

    event Lottery_Winner_Drawn(
        uint256 indexed roundId,
        address indexed winner,
        uint256 winningTicket,
        uint256 prize
    );

    error LotteryNotActive();
    error LotteryAlreadyActive();
    error LotteryNotEnded();
    error LotteryAlreadyDrawn();
    error InvalidTicketCount();
    error LotteryAwaitingVRF(uint256 requestID);
    error InvalidTicketPrice();
    error InvalidEpochDuration(uint256 duration);

    function _startRound(uint256 ticketPrice, address tokenAddress, uint256 duration) internal returns (uint256) {
        if (ticketPrice == 0) revert InvalidTicketPrice();

        // Enforce epoch-based rounds (caller may pass 0 as "use default").
        uint256 roundDuration = duration == 0 ? lotteryEpochDuration : duration;
        if (roundDuration != lotteryEpochDuration) {
            revert InvalidEpochDuration(duration);
        }

        uint256 existing = activeRoundId[tokenAddress];
        if (existing != 0) {
            LotteryRound storage active = lotteryRounds[existing];
            // If it hasn't been drawn yet (even if ended), it is still the active round.
            if (!active.drawn) revert LotteryAlreadyActive();

            // Defensive cleanup in case a drawn round wasn't removed properly.
            activeRoundId[tokenAddress] = 0;
            _removeActiveToken(tokenAddress);
        }

        currentRound++;
        LotteryRound storage round = lotteryRounds[currentRound];

        round.ticketPrice = ticketPrice;
        round.tokenAddress = tokenAddress;
        round.startTime = block.timestamp;
        round.endTime = block.timestamp + roundDuration;
        round.drawn = false;
        round.requestID = 0;
        round.completer = address(0);

        activeRoundId[tokenAddress] = currentRound;
        _addActiveToken(tokenAddress);

        emit Lottery_Round_Started(
            currentRound,
            ticketPrice,
            tokenAddress,
            round.startTime,
            round.endTime
        );
    }

    /**
     * @dev Start a new lottery round
     * @param ticketPrice price per ticket
     * @param tokenAddress address of token (0 for native)
     * @param duration duration of the lottery in seconds
     */
    function startLotteryRound(
        uint256 ticketPrice,
        address tokenAddress,
        uint256 duration
    ) external {
        _startRound(ticketPrice, tokenAddress, duration);
    }

    /// @dev Convenience function: start a default-epoch round.
    function startLotteryRoundForToken(address tokenAddress, uint256 ticketPrice) external {
        _startRound(ticketPrice, tokenAddress, lotteryEpochDuration);
    }

    /**
     * @dev Purchase lottery tickets
     * @param roundId the lottery round to enter
     * @param numTickets number of tickets to purchase
     */
    function buyTickets(
        uint256 roundId,
        uint256 numTickets
    ) external payable nonReentrant {
        _buyTickets(roundId, numTickets);
    }

    /// @dev Purchase tickets for the currently active round for a token.
    function buyTicketsForToken(address tokenAddress, uint256 numTickets) external payable nonReentrant {
        uint256 roundId = activeRoundId[tokenAddress];
        if (roundId == 0) revert LotteryNotActive();
        _buyTickets(roundId, numTickets);
    }

    function _buyTickets(uint256 roundId, uint256 numTickets) internal {
        if (numTickets == 0 || numTickets > 100) {
            revert InvalidTicketCount();
        }

        LotteryRound storage round = lotteryRounds[roundId];
        
        if (block.timestamp < round.startTime || block.timestamp > round.endTime) {
            revert LotteryNotActive();
        }
        if (round.drawn) {
            revert LotteryAlreadyDrawn();
        }

        address msgSender = _msgSender();
        uint256 totalCost = round.ticketPrice * numTickets;

        // Transfer payment
        if (round.tokenAddress == address(0)) {
            if (msg.value < totalCost) {
                revert("Insufficient payment");
            }
            // Refund excess
            if (msg.value > totalCost) {
                (bool success, ) = payable(msgSender).call{value: msg.value - totalCost}("");
                require(success, "Refund failed");
            }
        } else {
            IERC20(round.tokenAddress).safeTransferFrom(msgSender, address(this), totalCost);
        }

        // Add tickets to player
        if (round.ticketCount[msgSender] == 0) {
            round.players.push(msgSender);
        }

        round.ticketCount[msgSender] += numTickets;
        round.totalTickets += numTickets;
        
        // House edge goes to bankroll
        uint256 houseCut = (totalCost * houseEdge) / 10000;
        uint256 addToPrize = totalCost - houseCut;
        
        round.prizePool += addToPrize;
        
        // Transfer house cut to bankroll
        if (round.tokenAddress == address(0)) {
            (bool success, ) = payable(address(Bankroll())).call{value: houseCut}("");
            require(success, "Transfer to bankroll failed");
        } else {
            IERC20(round.tokenAddress).safeTransfer(address(Bankroll()), houseCut);
        }

        emit Lottery_Ticket_Purchased(roundId, msgSender, numTickets, totalCost);
    }

    /**
     * @dev Request VRF and complete the active round for a token once its epoch is over.
     *      Caller pays VRF fee (native) and receives `completionRewardBps` of the round prize pool.
     */
    function completeLotteryRound(address tokenAddress) external payable nonReentrant {
        uint256 roundId = activeRoundId[tokenAddress];
        if (roundId == 0) revert LotteryNotActive();

        LotteryRound storage round = lotteryRounds[roundId];

        if (block.timestamp <= round.endTime) {
            revert LotteryNotEnded();
        }
        if (round.drawn) {
            revert LotteryAlreadyDrawn();
        }
        if (round.requestID != 0) {
            revert LotteryAwaitingVRF(round.requestID);
        }

        // If no tickets sold, close the round without VRF.
        if (round.totalTickets == 0) {
            round.drawn = true;
            _closeActiveRound(tokenAddress);
            emit Lottery_Round_Closed_NoTickets(roundId, tokenAddress);
            return;
        }

        uint256 requestId = _requestRandomWords(1);
        round.requestID = requestId;
        round.completer = _msgSender();
        vrfRequestToRound[requestId] = roundId;

        emit Lottery_Completion_Requested(roundId, tokenAddress, requestId, round.completer, 0);
    }

    /**
     * @dev VRF callback to select winner
     */
    function _fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        uint256 roundId = vrfRequestToRound[requestId];
        LotteryRound storage round = lotteryRounds[roundId];

        if (round.totalTickets == 0) {
            delete vrfRequestToRound[requestId];
            _closeActiveRound(round.tokenAddress);
            return;
        }

        // Select winning ticket
        uint256 winningTicket = (randomWords[0] % round.totalTickets) + 1;
        round.winningTicket = winningTicket;

        // Find winner by counting through tickets
        uint256 ticketCounter = 0;
        address winner;
        
        for (uint256 i = 0; i < round.players.length; i++) {
            address player = round.players[i];
            ticketCounter += round.ticketCount[player];
            
            if (ticketCounter >= winningTicket) {
                winner = player;
                break;
            }
        }

        round.winner = winner;
        round.drawn = true;

        // Close the active round before transfers (state is finalized either way; a revert rolls back).
        _closeActiveRound(round.tokenAddress);

        // Pay completion reward to the user that triggered the VRF request.
        uint256 completionReward = 0;
        if (round.completer != address(0) && completionRewardBps != 0) {
            completionReward = (round.prizePool * completionRewardBps) / 10000;
        }

        uint256 winnerPrize = round.prizePool - completionReward;

        if (completionReward > 0) {
            if (round.tokenAddress == address(0)) {
                (bool ok, ) = payable(round.completer).call{value: completionReward}("");
                require(ok, "Completion reward transfer failed");
            } else {
                IERC20(round.tokenAddress).safeTransfer(round.completer, completionReward);
            }
        }

        // Transfer prize to winner
        if (round.tokenAddress == address(0)) {
            (bool success, ) = payable(winner).call{value: winnerPrize}("");
            require(success, "Prize transfer failed");
        } else {
            IERC20(round.tokenAddress).safeTransfer(winner, winnerPrize);
        }

        emit Lottery_Winner_Drawn(roundId, winner, winningTicket, winnerPrize);
        
        delete vrfRequestToRound[requestId];
    }

    function _addActiveToken(address tokenAddress) internal {
        if (activeTokenIndexPlusOne[tokenAddress] != 0) return;
        activeTokens.push(tokenAddress);
        activeTokenIndexPlusOne[tokenAddress] = activeTokens.length; // 1-based
    }

    function _removeActiveToken(address tokenAddress) internal {
        uint256 indexPlusOne = activeTokenIndexPlusOne[tokenAddress];
        if (indexPlusOne == 0) return;

        uint256 index = indexPlusOne - 1;
        uint256 last = activeTokens.length - 1;
        if (index != last) {
            address lastToken = activeTokens[last];
            activeTokens[index] = lastToken;
            activeTokenIndexPlusOne[lastToken] = index + 1;
        }

        activeTokens.pop();
        delete activeTokenIndexPlusOne[tokenAddress];
    }

    function _closeActiveRound(address tokenAddress) internal {
        activeRoundId[tokenAddress] = 0;
        _removeActiveToken(tokenAddress);
    }

    /**
     * @dev Get lottery round info
     */
    function getLotteryInfo(uint256 roundId) external view returns (
        uint256 prizePool,
        uint256 ticketPrice,
        uint256 totalTickets,
        uint256 startTime,
        uint256 endTime,
        bool drawn,
        address winner,
        address tokenAddress
    ) {
        LotteryRound storage round = lotteryRounds[roundId];
        return (
            round.prizePool,
            round.ticketPrice,
            round.totalTickets,
            round.startTime,
            round.endTime,
            round.drawn,
            round.winner,
            round.tokenAddress
        );
    }

    struct ActiveLotteryRoundInfo {
        uint256 roundId;
        address tokenAddress;
        uint256 prizePool;
        uint256 ticketPrice;
        uint256 totalTickets;
        uint256 startTime;
        uint256 endTime;
        uint256 requestID;
    }

    /// @notice List all currently active rounds across tokens (native token uses address(0)).
    function listActiveLotteryRounds() external view returns (ActiveLotteryRoundInfo[] memory rounds) {
        uint256 count = 0;
        for (uint256 i = 0; i < activeTokens.length; i++) {
            uint256 id = activeRoundId[activeTokens[i]];
            if (id != 0) count++;
        }

        rounds = new ActiveLotteryRoundInfo[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < activeTokens.length; i++) {
            address token = activeTokens[i];
            uint256 id = activeRoundId[token];
            if (id == 0) continue;
            LotteryRound storage round = lotteryRounds[id];
            rounds[j++] = ActiveLotteryRoundInfo({
                roundId: id,
                tokenAddress: token,
                prizePool: round.prizePool,
                ticketPrice: round.ticketPrice,
                totalTickets: round.totalTickets,
                startTime: round.startTime,
                endTime: round.endTime,
                requestID: round.requestID
            });
        }
    }

    function listActiveLotteryTokens() external view returns (address[] memory) {
        return activeTokens;
    }

    /**
     * @dev Get player's ticket count for a round
     */
    function getPlayerTickets(uint256 roundId, address player) external view returns (uint256) {
        return lotteryRounds[roundId].ticketCount[player];
    }

    /**
     * @dev Get all players in a round
     */
    function getRoundPlayers(uint256 roundId) external view returns (address[] memory) {
        return lotteryRounds[roundId].players;
    }

    /**
     * @dev Set house edge (only owner)
     */
    function setHouseEdge(uint256 _houseEdge) external onlyOwner {
        require(_houseEdge <= 1000, "House edge too high"); // Max 10%
        houseEdge = _houseEdge;
    }

    function setLotteryEpochDuration(uint256 _duration) external onlyOwner {
        require(_duration >= 1 hours && _duration <= 30 days, "Invalid epoch duration");
        lotteryEpochDuration = _duration;
    }

    function setCompletionRewardBps(uint256 _bps) external onlyOwner {
        require(_bps <= 500, "Completion reward too high"); // max 5%
        completionRewardBps = _bps;
    }
}
