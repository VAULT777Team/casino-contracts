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
 * @title Crash game with provably fair round results
 * Players continue to multiply their wager until they cash out or the game crashes
 * Round results are published continuously, linked to round seeds, with server seeds revealed after batch finalization
 */

contract Crash is Common {
    using SafeERC20 for IERC20;

    // Provably fair structures
    struct Round {
        uint256 id;
        uint256 batchId;
        bytes32 clientSeed;
        bytes32 roundSeed;
        uint256 result; // Crash multiplier in 1e4 precision (e.g., 10000 = 1x, 20000 = 2x)
        bool published;
    }

    struct Batch {
        uint256 id;
        bytes32 serverSeedHash;
        bytes32 serverSeed;
        bool finalized;
        uint256[] roundIds;
    }

    mapping(uint256 => Batch) public batches;
    mapping(uint256 => Round) public rounds;
    uint256 public nextBatchId = 1;
    uint256 public nextRoundId = 1;

    event BatchStarted(uint256 batchId, bytes32 serverSeedHash);
    event RoundResult(uint256 batchId, uint256 roundId, bytes32 roundSeed, uint256 result, bytes32 proof);
    event BatchFinalized(uint256 batchId, bytes32 serverSeed);

    constructor(
        address _registry
    )  {
        b_registry = IBankrollRegistry(_registry);
    }

    /**
     * @dev Starts a new batch by committing to the server seed hash
     * @param serverSeedHash Hash of the server seed for this batch
     */
    function startBatch(bytes32 serverSeedHash) external onlyOwner {
        uint256 batchId = nextBatchId++;
        batches[batchId] = Batch({
            id: batchId,
            serverSeedHash: serverSeedHash,
            serverSeed: bytes32(0),
            finalized: false,
            roundIds: new uint256[](0)
        });
        emit BatchStarted(batchId, serverSeedHash);
    }

    /**
     * @dev Publishes the result for a round
     * @param roundId The round ID
     * @param roundSeed The round seed
     * @param result The crash multiplier result
     */
    function publishRoundResult(uint256 roundId, bytes32 roundSeed, uint256 result) external onlyOwner {
        Round storage round = rounds[roundId];
        require(!round.published, "Round already published");
        require(result == computeResult(roundSeed, round.clientSeed), "Invalid result");

        round.roundSeed = roundSeed;
        round.result = result;
        round.published = true;

        emit RoundResult(round.batchId, roundId, roundSeed, result, keccak256(abi.encodePacked(roundSeed, round.clientSeed)));
    }

    /**
     * @dev Finalizes a batch by revealing the server seed
     * @param batchId The batch ID
     * @param serverSeed The server seed
     */
    function finalizeBatch(uint256 batchId, bytes32 serverSeed) external onlyOwner {
        Batch storage batch = batches[batchId];
        require(!batch.finalized, "Batch already finalized");
        require(keccak256(abi.encodePacked(serverSeed)) == batch.serverSeedHash, "Invalid server seed");

        for (uint256 i = 0; i < batch.roundIds.length; i++) {
            uint256 rId = batch.roundIds[i];
            Round storage round = rounds[rId];
            require(round.published, "Round not published");
            require(keccak256(abi.encodePacked(serverSeed, rId)) == round.roundSeed, "Invalid round seed");
        }

        batch.serverSeed = serverSeed;
        batch.finalized = true;
        emit BatchFinalized(batchId, serverSeed);
    }

    /**
     * @dev Computes the crash result from round seed and client seed
     * @param roundSeed The round seed
     * @param clientSeed The client seed
     * @return result The crash multiplier in 1e4 precision
     */
    function computeResult(bytes32 roundSeed, bytes32 clientSeed) public pure returns (uint256) {
        bytes32 combined = keccak256(abi.encodePacked(roundSeed, clientSeed));
        uint256 random = uint256(combined);
        // Crash multiplier from 1.00x to 100.00x (10000 to 1000000 in 1e4 precision)
        uint256 multiplier = 10000 + (random % 990000); // 1.00x to 100.00x
        return multiplier;
    }

    /**
     * @dev Plays a round in the specified batch
     * @param batchId The batch ID
     * @param clientSeed The client's seed
     * @return roundId The created round ID
     */
    function playRound(uint256 batchId, bytes32 clientSeed) external returns (uint256 roundId) {
        require(batches[batchId].id != 0, "Batch does not exist");
        require(!batches[batchId].finalized, "Batch finalized");

        roundId = nextRoundId++;
        rounds[roundId] = Round({
            id: roundId,
            batchId: batchId,
            clientSeed: clientSeed,
            roundSeed: bytes32(0),
            result: 0,
            published: false
        });
        batches[batchId].roundIds.push(roundId);

        // Here you would add wager logic, but for publishing, this is the start
    }

    /**
     * @dev calculates the maximum wager allowed based on the bankroll size
     */
    // Limit max wager so that max payout (at 100x multiplier) is 20% of available bankroll
    function _maxWagerAllowed(address token) internal view returns (uint256) {
        uint256 available = Bankroll().getAvailableBalance(token);
        uint256 maxMultiplier = 1000000; // 100x (1e4 precision)
        uint256 maxPayout = (available * 20) / 100; // 20% of available balance
        uint256 maxWager = (maxPayout * 10000) / maxMultiplier;
        return maxWager;
    }
}
