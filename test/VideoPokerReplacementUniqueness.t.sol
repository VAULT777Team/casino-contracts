// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../contracts/games/VideoPoker.sol";

contract MockBankrollRegistry {
    address public bankroll;

    constructor(address _bankroll) {
        bankroll = _bankroll;
    }

    function getCurrentBankroll() external view returns (address, address, address, address) {
        return (bankroll, address(0), address(0), address(0));
    }
}

contract MockBankroll {
    function depositEther() external payable returns (bool) {
        return true;
    }

    function deposit(address, uint256) external {}

    function getIsValidWager(address, address) external pure returns (bool) {
        return true;
    }

    function isPlayerSuspended(address) external pure returns (bool, uint256) {
        return (false, 0);
    }

    function getPlayerReward() external pure returns (uint256) {
        return 0;
    }

    function addPlayerReward(address, uint256) external {}

    function transferPayout(address, uint256, address) external {}

    function getOwner() external view returns (address) {
        return address(this);
    }
}

contract VideoPokerHarness is VideoPoker {
    constructor(address _registry)
        VideoPoker(_registry, address(0xBEEF), address(0xFEED))
    {}

    function setGameForTest(
        address player,
        uint256 wager,
        address tokenAddress,
        bool isFirstRequest,
        bool ingame
    ) external {
        VideoPokerGame storage g = videoPokerGames[player];
        g.wager = wager;
        g.tokenAddress = tokenAddress;
        g.isFirstRequest = isFirstRequest;
        g.ingame = ingame;
    }

    function setRequestForTest(address player, uint256 requestId) external {
        videoPokerIDs[requestId] = player;
        videoPokerGames[player].requestID = requestId;
        videoPokerGames[player].blockNumber = uint64(ChainSpecificUtil.getBlockNumber());
    }

    function setToReplaceForTest(address player, bool[5] calldata toReplace) external {
        videoPokerGames[player].toReplace = toReplace;
    }

    function fulfillForTest(uint256 requestId, uint256[] calldata randomWords) external {
        fulfillRandomWords(requestId, randomWords);
    }
}

contract VideoPokerReplacementUniquenessTest is Test {
    event VideoPoker_Outcome_Event(
        address indexed playerAddress,
        uint256 wager,
        uint256 payout,
        address tokenAddress,
        VideoPoker.Card[5] playerHand,
        uint256 outcome
    );

    function testReplacementCannotCreateDuplicateCards() public {
        MockBankroll bankroll = new MockBankroll();
        MockBankrollRegistry registry = new MockBankrollRegistry(address(bankroll));
        VideoPokerHarness poker = new VideoPokerHarness(address(registry));

        address player = address(0x1234);

        // Phase 1: create a first request that deals an initial hand.
        poker.setGameForTest(player, 0, address(0), true, true);
        poker.setRequestForTest(player, 1);

        // Force first dealt card to be the last card in the initial deck (number=13 suit=3)
        // by making rng % 52 == 51 on the first draw.
        uint256[] memory r1 = new uint256[](5);
        r1[0] = 51;
        r1[1] = 0;
        r1[2] = 0;
        r1[3] = 0;
        r1[4] = 0;
        poker.fulfillForTest(1, r1);

        // Phase 2: request a replacement of ONLY card index 1.
        // We keep card index 0 (which is the (13,3) forced above).
        bool[5] memory toReplace;
        toReplace[1] = true;
        poker.setToReplaceForTest(player, toReplace);

        poker.setGameForTest(player, 0, address(0), false, true);
        poker.setRequestForTest(player, 2);

        // Attempt to force drawing from the old "tail" index (51) again.
        // Pre-fix, `deck.length` stayed 52 and this could draw index 51,
        // duplicating a card already in the hand.
        // Post-fix, the deck length is shrunk first, so rng%deck.length cannot be 51.
        uint256[] memory r2 = new uint256[](5);
        r2[0] = 0;
        r2[1] = 51;
        r2[2] = 0;
        r2[3] = 0;
        r2[4] = 0;

        vm.recordLogs();
        poker.fulfillForTest(2, r2);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Find the VideoPoker_Outcome_Event and decode the final hand.
        bytes32 sig = keccak256(
            "VideoPoker_Outcome_Event(address,uint256,uint256,address,(uint8,uint8)[5],uint256)"
        );

        bool found;
        VideoPoker.Card[5] memory finalHand;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                // topics[1] is indexed player
                (,, , finalHand,) = abi.decode(
                    logs[i].data,
                    (uint256, uint256, address, VideoPoker.Card[5], uint256)
                );
                found = true;
                break;
            }
        }
        assertTrue(found, "Outcome event not found");

        // Assert all 5 cards are unique (no exact duplicates number+suit).
        for (uint256 a = 0; a < 5; a++) {
            for (uint256 b = a + 1; b < 5; b++) {
                bool same = (finalHand[a].number == finalHand[b].number) &&
                    (finalHand[a].suit == finalHand[b].suit);
                assertFalse(same, "Duplicate card detected in final hand");
            }
        }
    }
}
