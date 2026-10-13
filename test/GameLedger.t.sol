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
    event OperatorUpdated(address indexed operator, bool allowed);

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

    function testBooleanSetOperatorEnablesAndRevokes() public {
        address operator = address(0xCAFE);

        vm.expectEmit(true, false, false, true);
        emit OperatorUpdated(operator, true);
        ledger.setOperator(operator, true);
        assertTrue(ledger.isOperator(operator));

        vm.expectEmit(true, false, false, true);
        emit OperatorUpdated(operator, false);
        ledger.setOperator(operator, false);
        assertFalse(ledger.isOperator(operator));
    }

    function testBooleanSetOperatorRequiresOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes("NOT_OWNER"));
        ledger.setOperator(address(0xCAFE), false);
    }

    function testBooleanSetOperatorRejectsZeroAddress() public {
        vm.expectRevert(bytes("ZERO_OPERATOR"));
        ledger.setOperator(address(0), false);
    }

    function testBooleanSetOperatorsEnablesAndRevokesAtomically() public {
        address[] memory operators = new address[](3);
        operators[0] = address(0xCAFE);
        operators[1] = address(0xF00D);
        operators[2] = address(0xD00D);
        bool[] memory enabled = new bool[](3);
        enabled[0] = true;
        enabled[1] = false;
        enabled[2] = true;

        ledger.setOperators(operators, enabled);
        assertTrue(ledger.isOperator(operators[0]));
        assertFalse(ledger.isOperator(operators[1]));
        assertTrue(ledger.isOperator(operators[2]));

        for (uint256 i; i < enabled.length; ++i) enabled[i] = false;
        ledger.setOperators(operators, enabled);
        for (uint256 i; i < operators.length; ++i) {
            assertFalse(ledger.isOperator(operators[i]));
        }
    }

    function testBooleanSetOperatorsRejectsEmptyAndRollsBackZeroAddress() public {
        address[] memory empty = new address[](0);
        bool[] memory emptyEnabled = new bool[](0);
        vm.expectRevert(bytes("EMPTY_OPERATORS"));
        ledger.setOperators(empty, emptyEnabled);

        address[] memory operators = new address[](2);
        operators[0] = address(0xCAFE);
        operators[1] = address(0);
        bool[] memory enabled = new bool[](2);
        enabled[0] = true;
        enabled[1] = true;

        vm.expectRevert(bytes("ZERO_OPERATOR"));
        ledger.setOperators(operators, enabled);
        assertFalse(ledger.isOperator(operators[0]));

        bool[] memory mismatched = new bool[](1);
        vm.expectRevert(bytes("LENGTH_MISMATCH"));
        ledger.setOperators(operators, mismatched);
    }

    function testBooleanAdminSettersSupportMixedBatchStates() public {
        address[] memory admins = new address[](2);
        admins[0] = address(0x2001);
        admins[1] = address(0x2002);
        bool[] memory enabled = new bool[](2);
        enabled[0] = true;
        enabled[1] = false;

        ledger.setAdmins(admins, enabled);
        assertTrue(ledger.isAdmin(admins[0]));
        assertFalse(ledger.isAdmin(admins[1]));

        ledger.setAdmin(admins[0], false);
        assertFalse(ledger.isAdmin(admins[0]));
    }

    function testBooleanAdminBatchRejectsInvalidArraysAtomically() public {
        address[] memory admins = new address[](2);
        admins[0] = address(0x2001);
        admins[1] = address(0);
        bool[] memory enabled = new bool[](2);
        enabled[0] = true;
        enabled[1] = true;

        vm.expectRevert(bytes("ZERO_ADMIN"));
        ledger.setAdmins(admins, enabled);
        assertFalse(ledger.isAdmin(admins[0]));

        bool[] memory mismatched = new bool[](1);
        vm.expectRevert(bytes("LENGTH_MISMATCH"));
        ledger.setAdmins(admins, mismatched);
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

    function testOperatorCanCancelAfterLegacyTimeframe() public {
        bytes32 roundKey = keccak256("round-late-cancel");
        _placeBet(roundKey, keccak256("bet-late-cancel"), STAKE);

        vm.warp(block.timestamp + ledger.cancelTimeframe() + 1);
        ledger.cancel(roundKey);

        assertTrue(ledger.roundCanceled(roundKey));
        assertEq(PLAYER.balance, STAKE);
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
