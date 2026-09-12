// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {GameLedgerV3} from "../contracts/games/ocg/GameLedger.sol";

contract GameLedgerBankrollMock {
    function depositEther() external payable {}

    function deposit(address, uint256) external {}

    function transferPayout(
        address player,
        uint256 amount,
        address token
    ) external {
        require(token == address(0), "TOKEN_UNSUPPORTED");
        (bool success, ) = payable(player).call{value: amount}("");
        require(success, "PAYOUT_FAILED");
    }

    receive() external payable {}
}

contract GameLedgerRegistryMock {
    address internal immutable bankroll;

    constructor(address bankroll_) {
        bankroll = bankroll_;
    }

    function getCurrentBankroll()
        external
        view
        returns (
            address,
            address,
            string memory,
            uint256
        )
    {
        return (bankroll, address(0), "test", block.timestamp);
    }
}

contract GameLedgerTest is Test {
    GameLedgerV3 internal ledger;
    GameLedgerBankrollMock internal bankroll;

    address internal constant PLAYER = address(0xBEEF);
    uint256 internal constant STAKE = 1 ether;

    function setUp() public {
        bankroll = new GameLedgerBankrollMock();
        GameLedgerRegistryMock registry = new GameLedgerRegistryMock(
            address(bankroll)
        );
        ledger = new GameLedgerV3(address(this), address(registry));
        ledger.setMaxPayoutMultiplierX(5);

        vm.deal(address(this), 100 ether);
        vm.deal(address(bankroll), 100 ether);
    }

    function testMultipleSettlementsShareOneCumulativePayoutLimit() public {
        bytes32 roundKey = keccak256("round-cumulative");
        _placeBet(roundKey, keccak256("bet-cumulative"), STAKE);

        _settle(roundKey, keccak256("settle-one"), 2 ether);
        _settle(roundKey, keccak256("settle-two"), 3 ether);

        assertEq(ledger.roundPaidOut(roundKey), 5 ether);

        vm.expectRevert(bytes("PAYOUT_LIMIT"));
        _settle(roundKey, keccak256("settle-three"), 1);
    }

    function testCumulativeLimitAppliesWithinOneBatch() public {
        bytes32 roundKey = keccak256("round-batch");
        bytes32 firstAction = keccak256("settle-batch-one");
        bytes32 secondAction = keccak256("settle-batch-two");
        _placeBet(roundKey, keccak256("bet-batch"), STAKE);

        bytes32[] memory actionKeys = new bytes32[](2);
        actionKeys[0] = firstAction;
        actionKeys[1] = secondAction;

        bytes32[] memory roundKeys = new bytes32[](2);
        roundKeys[0] = roundKey;
        roundKeys[1] = roundKey;

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 3 ether;
        payouts[1] = 3 ether;

        vm.expectRevert(bytes("PAYOUT_LIMIT"));
        ledger.settleBatch(address(0), actionKeys, roundKeys, payouts);

        assertEq(ledger.roundPaidOut(roundKey), 0);
        assertFalse(ledger.actionUsed(firstAction));
        assertFalse(ledger.actionUsed(secondAction));
    }

    function testCanceledRoundCannotBeSettled() public {
        bytes32 roundKey = keccak256("round-canceled");
        _placeBet(roundKey, keccak256("bet-canceled"), STAKE);

        ledger.cancel(roundKey);

        assertTrue(ledger.roundCanceled(roundKey));
        vm.expectRevert(bytes("ROUND_CANCELED"));
        _settle(roundKey, keccak256("settle-canceled"), STAKE);
    }

    function testClosedRoundCannotAcceptMoreBets() public {
        bytes32 settledRound = keccak256("round-settled");
        _placeBet(settledRound, keccak256("bet-before-settle"), STAKE);
        _settle(settledRound, keccak256("settle-close"), STAKE);

        vm.expectRevert(bytes("ROUND_CLOSED"));
        _placeBet(settledRound, keccak256("bet-after-settle"), STAKE);

        bytes32 canceledRound = keccak256("round-cancel-then-bet");
        _placeBet(canceledRound, keccak256("bet-before-cancel"), STAKE);
        ledger.cancel(canceledRound);

        vm.expectRevert(bytes("ROUND_CLOSED"));
        _placeBet(canceledRound, keccak256("bet-after-cancel"), STAKE);
    }

    function _placeBet(
        bytes32 roundKey,
        bytes32 actionKey,
        uint256 stake
    ) internal {
        address[] memory players = new address[](1);
        players[0] = PLAYER;

        bytes32[] memory actionKeys = new bytes32[](1);
        actionKeys[0] = actionKey;

        bytes32[] memory roundKeys = new bytes32[](1);
        roundKeys[0] = roundKey;

        uint256[] memory stakes = new uint256[](1);
        stakes[0] = stake;

        ledger.betBatchFor{value: stake}(
            address(0),
            players,
            actionKeys,
            roundKeys,
            stakes
        );
    }

    function _settle(
        bytes32 roundKey,
        bytes32 actionKey,
        uint256 payout
    ) internal {
        bytes32[] memory actionKeys = new bytes32[](1);
        actionKeys[0] = actionKey;

        bytes32[] memory roundKeys = new bytes32[](1);
        roundKeys[0] = roundKey;

        uint256[] memory payouts = new uint256[](1);
        payouts[0] = payout;

        ledger.settleBatch(address(0), actionKeys, roundKeys, payouts);
    }
}
