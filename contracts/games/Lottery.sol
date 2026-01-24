// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {
    Common, IBankrollRegistry,
    IERC20, SafeERC20,
    VRFConsumerBaseV2Plus, IVRFCoordinatorV2Plus,
    IDecimalAggregator
} from "../Common.sol";

/**
 * @title Lottery game, players purchase tickets and a random winner is selected
 */

contract Lottery is Common {
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
        address[] players;
        mapping(address => uint256) ticketCount;
        bool drawn;
        address winner;
        uint256 winningTicket;
    }

    uint256 public currentRound;
    uint256 public lotteryEpochDuration;
    uint256 public houseEdge = 200; // 2% house edge (basis points)
    
    mapping(uint256 => LotteryRound) public lotteryRounds;
    mapping(uint256 => uint256) public vrfRequestToRound;

    event Lottery_Round_Started(
        uint256 indexed roundId,
        uint256 ticketPrice,
        address tokenAddress,
        uint256 startTime,
        uint256 endTime
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
    error OnlyOwner();

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
    ) external onlyOwner {
        LotteryRound storage prevRound = lotteryRounds[currentRound];
        if (currentRound != 0 && !prevRound.drawn) {
            revert LotteryAlreadyActive();
        }

        currentRound++;
        LotteryRound storage round = lotteryRounds[currentRound];
        
        round.ticketPrice = ticketPrice;
        round.tokenAddress = tokenAddress;
        round.startTime = block.timestamp;
        round.endTime = block.timestamp + duration;
        round.drawn = false;

        emit Lottery_Round_Started(
            currentRound,
            ticketPrice,
            tokenAddress,
            round.startTime,
            round.endTime
        );
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
     * @dev Draw the lottery winner using VRF
     * @param roundId the lottery round to draw
     */
    function drawWinner(uint256 roundId) external onlyOwner {
        LotteryRound storage round = lotteryRounds[roundId];
        
        if (block.timestamp <= round.endTime) {
            revert LotteryNotEnded();
        }
        if (round.drawn) {
            revert LotteryAlreadyDrawn();
        }
        if (round.totalTickets == 0) {
            round.drawn = true;
            return; // No tickets sold, nothing to draw
        }

        uint256 requestId = _requestRandomWords(1);
        round.requestID = requestId;
        vrfRequestToRound[requestId] = roundId;
    }

    /**
     * @dev VRF callback to select winner
     */
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        uint256 roundId = vrfRequestToRound[requestId];
        LotteryRound storage round = lotteryRounds[roundId];

        if (round.totalTickets == 0) return;

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

        // Transfer prize to winner
        if (round.tokenAddress == address(0)) {
            (bool success, ) = payable(winner).call{value: round.prizePool}("");
            require(success, "Prize transfer failed");
        } else {
            IERC20(round.tokenAddress).safeTransfer(winner, round.prizePool);
        }

        emit Lottery_Winner_Drawn(roundId, winner, winningTicket, round.prizePool);
        
        delete vrfRequestToRound[requestId];
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
}
