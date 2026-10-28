// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BonusGameLedger} from "../contracts/games/bonus/BonusGameLedger.sol";

contract Bonus1155LedgerMock {
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(uint256 => uint256) public wageredAmount;
    address public ledger;

    function setLedger(address value) external {
        ledger = value;
    }

    function mint(address player, uint256 id, uint256 amount) external {
        balanceOf[player][id] += amount;
    }

    function debitStakeAndRecordWager(address player, address, uint256 bonusId, uint256 stake, uint256 contribution)
        external
    {
        require(msg.sender == ledger, "NOT_LEDGER");
        balanceOf[player][bonusId] -= stake;
        wageredAmount[bonusId] += contribution;
    }

    function creditPayout(address player, address, uint256 bonusId, uint256 payout) external {
        require(msg.sender == ledger, "NOT_LEDGER");
        balanceOf[player][bonusId] += payout;
    }

    function cancelStakeAndWager(address player, address, uint256 bonusId, uint256 refund, uint256 contribution)
        external
    {
        require(msg.sender == ledger, "NOT_LEDGER");
        wageredAmount[bonusId] -= contribution;
        balanceOf[player][bonusId] += refund;
    }
}

contract BonusGameLedgerTest is Test {
    address constant PLAYER = address(0xBEEF);
    address constant TOKEN = address(0xCAFE);
    uint256 constant BONUS_ID = 7;

    Bonus1155LedgerMock bonus;
    BonusGameLedger ledger;

    function setUp() public {
        bonus = new Bonus1155LedgerMock();
        ledger = new BonusGameLedger(address(this), address(this), address(bonus));
        bonus.setLedger(address(ledger));
        bonus.mint(PLAYER, BONUS_ID, 100 ether);
    }

    function testProviderBonusCreditsContinueAfterFirstPayout() public {
        bytes32 round = keccak256("provider-feature");
        _providerBet(round, keccak256("provider-bet"), 19 ether);
        _providerCredit(round, keccak256("first-credit"), 1.25 ether);
        (,,,,,,, uint256 closedAt,,) = ledger.rounds(round);
        assertGt(closedAt, 0);
        _providerCredit(round, keccak256("later-credit"), 0.38 ether);
        assertEq(bonus.balanceOf(PLAYER, BONUS_ID), 82.63 ether);
        assertEq(bonus.wageredAmount(BONUS_ID), 19 ether);
        assertEq(ledger.providerRoundPaidOut(round), 1.63 ether);
    }

    function testProviderCreditsInOneBatchRetainEveryDelta() public {
        bytes32 round = keccak256("provider-batch");
        _providerBet(round, keccak256("provider-bet"), 20 ether);
        uint256[16] memory wins = [uint256(70), 33, 25, 84, 45, 86, 73, 43, 101, 96, 33, 49, 87, 28, 63, 20];
        bytes32[] memory actions = new bytes32[](16);
        bytes32[] memory rounds = new bytes32[](16);
        uint256[] memory payouts = new uint256[](16);
        for (uint256 i; i < 16; ++i) {
            actions[i] = keccak256(abi.encode("credit", i));
            rounds[i] = round;
            payouts[i] = wins[i] * 1 ether;
        }
        ledger.creditProviderBonusBatch(TOKEN, BONUS_ID, actions, rounds, payouts);
        assertEq(ledger.providerRoundPaidOut(round), 936 ether);
        assertEq(bonus.balanceOf(PLAYER, BONUS_ID), 1016 ether);
        assertEq(bonus.wageredAmount(BONUS_ID), 20 ether);
        vm.expectRevert("DUP_ACTION");
        ledger.creditProviderBonusBatch(TOKEN, BONUS_ID, actions, rounds, payouts);
        assertEq(ledger.providerRoundPaidOut(round), 936 ether);
    }

    function testProviderPayoutLimitIsCumulativeAndFailedActionCanRetry() public {
        bytes32 round = keccak256("provider-cap");
        _providerBet(round, keccak256("bet"), 1 ether);
        _providerCredit(round, keccak256("credit"), 60 ether);
        bytes32 action = keccak256("over-cap");
        vm.expectRevert("PAYOUT_LIMIT");
        _providerCredit(round, action, 41 ether);
        assertFalse(ledger.actionUsed(action));
        assertEq(ledger.providerRoundPaidOut(round), 60 ether);
        _providerCredit(round, action, 40 ether);
        assertEq(ledger.providerRoundPaidOut(round), 100 ether);
    }

    function testProviderCanAddPaidDebitsAfterFirstCredit() public {
        bytes32 round = keccak256("provider-more-debits");
        _providerBet(round, keccak256("bet"), 2 ether);
        _providerCredit(round, keccak256("credit"), 1 ether);
        _providerBet(round, keccak256("second-bet"), 3 ether);
        _providerCredit(round, keccak256("second-credit"), 4 ether);
        assertEq(bonus.balanceOf(PLAYER, BONUS_ID), 100 ether);
        assertEq(bonus.wageredAmount(BONUS_ID), 5 ether);
        assertEq(ledger.providerRoundPaidOut(round), 5 ether);
    }

    function testProviderCannotCancelAfterAnyCreditIncludingZero() public {
        bytes32 round = keccak256("provider-zero");
        _providerBet(round, keccak256("bet"), 2 ether);
        _providerCredit(round, keccak256("credit"), 0);
        vm.expectRevert("ALREADY_SETTLED");
        ledger.cancel(round);
        _providerCredit(round, keccak256("later-credit"), 1 ether);
        assertEq(bonus.balanceOf(PLAYER, BONUS_ID), 99 ether);
    }

    function testCanceledProviderRoundCannotPayOrAcceptNewDebits() public {
        bytes32 round = keccak256("provider-cancel");
        _providerBet(round, keccak256("bet"), 19 ether);
        ledger.cancel(round);
        assertEq(bonus.balanceOf(PLAYER, BONUS_ID), 100 ether);
        assertEq(bonus.wageredAmount(BONUS_ID), 0);
        vm.expectRevert("ROUND_CANCELED");
        _providerCredit(round, keccak256("credit"), 1 ether);
        vm.expectRevert("ROUND_CANCELED");
        _providerBet(round, keccak256("later-bet"), 1 ether);
    }

    function testProviderAndHouseRoundModesCannotBeMixed() public {
        bytes32 house = _reserve(10 ether);
        _consume(house, keccak256("house-consume"), 10 ether);
        vm.expectRevert("NOT_PROVIDER_ROUND");
        _providerCredit(house, keccak256("provider-credit"), 1 ether);
        vm.expectRevert("NOT_PROVIDER_ROUND");
        _providerBet(house, keccak256("provider-bet"), 1 ether);
        _settle(house, keccak256("house-settle"), 1 ether);
        vm.expectRevert("ROUND_CLOSED");
        _settle(house, keccak256("house-settle-again"), 1 ether);

        bytes32 provider = keccak256("provider-mode");
        _providerBet(provider, keccak256("bet"), 1 ether);
        vm.expectRevert("PROVIDER_ROUND");
        _settle(provider, keccak256("house-provider-settle"), 1 ether);
        address[] memory players = new address[](1);
        players[0] = PLAYER;
        uint16[] memory bps = new uint16[](1);
        bps[0] = 10_000;
        vm.expectRevert("PROVIDER_ROUND");
        ledger.betBonusBatchFor(
            TOKEN,
            BONUS_ID,
            players,
            _actions(keccak256("house-provider-bet")),
            _rounds(provider),
            _amounts(1 ether),
            bps
        );
    }

    function testProviderValidatesAssetBonusIdAndRoles() public {
        bytes32 round = keccak256("provider-guards");
        _providerBet(round, keccak256("bet"), 1 ether);
        vm.expectRevert("TOKEN_MISMATCH");
        ledger.creditProviderBonusBatch(
            address(1), BONUS_ID, _actions(keccak256("bad-token")), _rounds(round), _amounts(1 ether)
        );
        vm.expectRevert("BONUS_MISMATCH");
        ledger.creditProviderBonusBatch(
            TOKEN, BONUS_ID + 1, _actions(keccak256("bad-bonus")), _rounds(round), _amounts(1 ether)
        );
        vm.prank(address(0xBAD));
        vm.expectRevert("NOT_SETTLE_OPERATOR");
        _providerCredit(round, keccak256("unauthorized-credit"), 1 ether);
        vm.prank(address(0xBAD));
        vm.expectRevert("NOT_BET_OPERATOR");
        _providerBet(round, keccak256("unauthorized-bet"), 1 ether);
    }

    function testProviderKeepsOriginalDeadline() public {
        bytes32 round = keccak256("provider-deadline");
        _providerBet(round, keccak256("bet"), 1 ether);
        (,,,,,,,,, uint256 refundAt) = ledger.rounds(round);
        _providerCredit(round, keccak256("first-credit"), 1 ether);
        vm.warp(refundAt);
        vm.expectRevert("SETTLEMENT_WINDOW_EXPIRED");
        _providerCredit(round, keccak256("late-credit"), 1 ether);
        vm.expectRevert("SETTLEMENT_WINDOW_EXPIRED");
        _providerBet(round, keccak256("late-bet"), 1 ether);
    }

    function _providerBet(bytes32 round, bytes32 action, uint256 stake) internal {
        address[] memory players = new address[](1);
        players[0] = PLAYER;
        uint16[] memory bps = new uint16[](1);
        bps[0] = 10_000;
        ledger.betProviderBonusBatchFor(
            TOKEN, BONUS_ID, players, _actions(action), _rounds(round), _amounts(stake), bps
        );
    }

    function _providerCredit(bytes32 round, bytes32 action, uint256 payout) internal {
        ledger.creditProviderBonusBatch(TOKEN, BONUS_ID, _actions(action), _rounds(round), _amounts(payout));
    }

    function testReservationDoesNotIncreaseWagerProgress() public {
        _reserve(40 ether);
        assertEq(bonus.balanceOf(PLAYER, BONUS_ID), 60 ether);
        assertEq(bonus.wageredAmount(BONUS_ID), 0);
    }

    function testPartialConsumptionReleaseAndSettlement() public {
        bytes32 round = _reserve(40 ether);
        _consume(round, keccak256("base"), 10 ether);
        _consume(round, keccak256("split"), 15 ether);
        _release(round, keccak256("release"), 15 ether);
        _settle(round, keccak256("settle"), 30 ether);

        assertEq(bonus.wageredAmount(BONUS_ID), 25 ether);
        assertEq(bonus.balanceOf(PLAYER, BONUS_ID), 105 ether);
        (,,,, uint256 consumed, uint256 released,, uint256 closedAt,,) = ledger.rounds(round);
        assertEq(consumed, 25 ether);
        assertEq(released, 15 ether);
        assertGt(closedAt, 0);
    }

    function testDuplicateConsumeAndReleaseRevert() public {
        bytes32 round = _reserve(20 ether);
        bytes32 consumeAction = keccak256("consume");
        _consume(round, consumeAction, 5 ether);
        vm.expectRevert("DUP_ACTION");
        _consume(round, consumeAction, 5 ether);

        bytes32 releaseAction = keccak256("release");
        _release(round, releaseAction, 15 ether);
        vm.expectRevert("DUP_ACTION");
        _release(round, releaseAction, 1 ether);
    }

    function testCannotSettleUntilUnusedReserveReleased() public {
        bytes32 round = _reserve(20 ether);
        _consume(round, keccak256("consume"), 5 ether);
        vm.expectRevert("RESERVE_OPEN");
        _settle(round, keccak256("early-settle"), 1 ether);
    }

    function testSettlementIsFinal() public {
        bytes32 round = _reserve(10 ether);
        _consume(round, keccak256("consume"), 10 ether);
        _settle(round, keccak256("settle"), 20 ether);
        vm.expectRevert("ROUND_CLOSED");
        _settle(round, keccak256("settle-again"), 1 ether);
    }

    function testReserveAndSettleBatchIsAtomicForOneShotBonusRounds() public {
        bytes32 round = keccak256("atomic-bonus-round");
        BonusGameLedger.AtomicSettlement[] memory settlements = new BonusGameLedger.AtomicSettlement[](1);
        settlements[0] = BonusGameLedger.AtomicSettlement({
            player: PLAYER,
            reservationActionKey: keccak256("atomic-bonus-reserve"),
            settlementActionKey: keccak256("atomic-bonus-settle"),
            roundKey: round,
            stake: 10 ether,
            wagerContributionBps: 10_000,
            payout: 15 ether
        });

        ledger.reserveAndSettleBatch(TOKEN, BONUS_ID, settlements);

        assertEq(bonus.balanceOf(PLAYER, BONUS_ID), 105 ether);
        assertEq(bonus.wageredAmount(BONUS_ID), 10 ether);
        (,,, uint256 reserved, uint256 consumed, uint256 released,, uint256 closedAt,,) = ledger.rounds(round);
        assertEq(reserved, 10 ether);
        assertEq(consumed, 10 ether);
        assertEq(released, 0);
        assertGt(closedAt, 0);
    }

    function testOnlyOperatorsCanMutate() public {
        bytes32[] memory keys = _keys(keccak256("reserve"), keccak256("round"));
        address[] memory players = new address[](1);
        players[0] = PLAYER;
        uint256[] memory amounts = _amounts(1 ether);
        vm.prank(address(0xBAD));
        vm.expectRevert("NOT_BET_OPERATOR");
        ledger.reserveBonusBatchFor(TOKEN, BONUS_ID, players, keys, _rounds(keys[1]), amounts);

        bytes32 round = _reserve(10 ether);
        vm.startPrank(address(0xBAD));
        vm.expectRevert("NOT_SETTLE_OPERATOR");
        ledger.releaseBonusBatch(
            TOKEN, BONUS_ID, _actions(keccak256("unauthorized-release")), _rounds(round), _amounts(10 ether)
        );
        vm.expectRevert("NOT_SETTLE_OPERATOR");
        ledger.settleBonusBatch(
            TOKEN, BONUS_ID, _actions(keccak256("unauthorized-settle")), _rounds(round), _amounts(0)
        );
        vm.expectRevert("NOT_SETTLE_OPERATOR");
        ledger.cancel(round);
        vm.stopPrank();
    }

    function testCombinedOperatorSettersSupportMixedBatchStates() public {
        address first = address(0x1001);
        address second = address(0x1002);
        address[] memory operators = new address[](2);
        operators[0] = first;
        operators[1] = second;
        bool[] memory allowed = new bool[](2);
        allowed[0] = true;
        allowed[1] = false;

        ledger.setOperators(operators, allowed);
        assertTrue(ledger.isBetOperator(first));
        assertTrue(ledger.isSettleOperator(first));
        assertFalse(ledger.isBetOperator(second));
        assertFalse(ledger.isSettleOperator(second));

        ledger.setOperator(first, false);
        ledger.setOperator(second, true);
        assertFalse(ledger.isBetOperator(first));
        assertFalse(ledger.isSettleOperator(first));
        assertTrue(ledger.isBetOperator(second));
        assertTrue(ledger.isSettleOperator(second));
    }

    function testRoleSpecificOperatorBatchesRemainIndependent() public {
        address first = address(0x1001);
        address second = address(0x1002);
        address[] memory operators = new address[](2);
        operators[0] = first;
        operators[1] = second;
        bool[] memory allowed = new bool[](2);
        allowed[0] = true;
        allowed[1] = false;

        ledger.setBetOperators(operators, allowed);
        assertTrue(ledger.isBetOperator(first));
        assertFalse(ledger.isSettleOperator(first));

        ledger.setSettleOperators(operators, allowed);
        assertTrue(ledger.isSettleOperator(first));
        assertFalse(ledger.isBetOperator(second));
        assertFalse(ledger.isSettleOperator(second));
    }

    function testOperatorBatchesRejectInvalidArraysAtomically() public {
        address[] memory operators = new address[](2);
        operators[0] = address(0x1001);
        operators[1] = address(0);
        bool[] memory allowed = new bool[](2);
        allowed[0] = true;
        allowed[1] = true;

        vm.expectRevert("ZERO_OPERATOR");
        ledger.setOperators(operators, allowed);
        assertFalse(ledger.isBetOperator(operators[0]));
        assertFalse(ledger.isSettleOperator(operators[0]));

        bool[] memory mismatched = new bool[](1);
        vm.expectRevert("LENGTH_MISMATCH");
        ledger.setOperators(operators, mismatched);
    }

    function testAdminSettersSupportMixedBatchStates() public {
        address[] memory admins = new address[](2);
        admins[0] = address(0x2001);
        admins[1] = address(0x2002);
        bool[] memory allowed = new bool[](2);
        allowed[0] = true;
        allowed[1] = false;

        ledger.setAdmins(admins, allowed);
        assertTrue(ledger.isAdmin(admins[0]));
        assertFalse(ledger.isAdmin(admins[1]));

        ledger.setAdmin(admins[0], false);
        assertFalse(ledger.isAdmin(admins[0]));
    }

    function testAdminBatchRejectsInvalidArraysAtomically() public {
        address[] memory admins = new address[](2);
        admins[0] = address(0x2001);
        admins[1] = address(0);
        bool[] memory allowed = new bool[](2);
        allowed[0] = true;
        allowed[1] = true;

        vm.expectRevert("ZERO_ADMIN");
        ledger.setAdmins(admins, allowed);
        assertFalse(ledger.isAdmin(admins[0]));

        bool[] memory mismatched = new bool[](1);
        vm.expectRevert("LENGTH_MISMATCH");
        ledger.setAdmins(admins, mismatched);
    }

    function testV1ImmediateWagerAndSettlementRemainSupported() public {
        bytes32 round = keccak256("legacy-round");
        address[] memory players = new address[](1);
        players[0] = PLAYER;
        uint16[] memory bps = new uint16[](1);
        bps[0] = 10_000;
        ledger.betBonusBatchFor(
            TOKEN, BONUS_ID, players, _actions(keccak256("legacy-wager")), _rounds(round), _amounts(10 ether), bps
        );
        assertEq(bonus.wageredAmount(BONUS_ID), 10 ether);
        ledger.settleBonusBatch(
            TOKEN, BONUS_ID, _actions(keccak256("legacy-settle")), _rounds(round), _amounts(15 ether)
        );
        assertEq(bonus.balanceOf(PLAYER, BONUS_ID), 105 ether);
    }

    function testCancellationRestoresUnusedReservation() public {
        bytes32 round = _reserve(10 ether);
        ledger.cancel(round);
        assertEq(bonus.balanceOf(PLAYER, BONUS_ID), 100 ether);
        assertEq(bonus.wageredAmount(BONUS_ID), 0);
    }

    function testPlayerCanCancelOnlyAfterRefundDelay() public {
        bytes32 round = _reserve(10 ether);

        vm.prank(PLAYER);
        vm.expectRevert("REFUND_NOT_AVAILABLE");
        ledger.cancel(round);

        vm.warp(block.timestamp + ledger.cancelTimeframe());
        vm.prank(PLAYER);
        ledger.cancel(round);

        assertEq(bonus.balanceOf(PLAYER, BONUS_ID), 100 ether);
    }

    function testSettlementAndReleaseRejectAtRefundDeadline() public {
        bytes32 settlementRound = _reserve(10 ether);
        _consume(settlementRound, keccak256("deadline-consume"), 10 ether);
        vm.warp(block.timestamp + ledger.cancelTimeframe());

        vm.expectRevert("SETTLEMENT_WINDOW_EXPIRED");
        _settle(settlementRound, keccak256("deadline-settle"), 10 ether);

        vm.prank(PLAYER);
        ledger.cancel(settlementRound);
        assertEq(bonus.balanceOf(PLAYER, BONUS_ID), 100 ether);

        bytes32 releaseRound = _reserve(11 ether);
        vm.warp(block.timestamp + ledger.cancelTimeframe());
        vm.expectRevert("SETTLEMENT_WINDOW_EXPIRED");
        _release(releaseRound, keccak256("deadline-release"), 11 ether);
    }

    function testRefundDelayHasContractMinimum() public {
        uint256 minimumDelay = ledger.MIN_REFUND_DELAY();
        vm.expectRevert("REFUND_DELAY_TOO_SHORT");
        ledger.setCancelTimeframe(minimumDelay - 1);
    }

    function testRefundDeadlineIsSnapshottedPerRound() public {
        bytes32 round = _reserve(10 ether);
        (,,,,,,,,, uint256 refundAt) = ledger.rounds(round);
        ledger.setCancelTimeframe(30 minutes);
        vm.warp(refundAt);

        vm.expectRevert("SETTLEMENT_WINDOW_EXPIRED");
        _release(round, keccak256("snapshotted-deadline-release"), 10 ether);

        vm.prank(PLAYER);
        ledger.cancel(round);
        assertEq(bonus.balanceOf(PLAYER, BONUS_ID), 100 ether);
    }

    function testSettlementOperatorCanCancelAfterLegacyTimeframe() public {
        bytes32 round = _reserve(10 ether);
        vm.warp(block.timestamp + ledger.cancelTimeframe() + 1);

        ledger.cancel(round);

        assertEq(bonus.balanceOf(PLAYER, BONUS_ID), 100 ether);
        (,,,,, uint256 released,, uint256 closedAt,,) = ledger.rounds(round);
        assertEq(released, 10 ether);
        assertGt(closedAt, 0);
    }

    function testCancellationRestoresConsumedStakeAndWagerProgress() public {
        bytes32 round = keccak256("legacy-cancel-round");
        address[] memory players = new address[](1);
        players[0] = PLAYER;
        uint16[] memory bps = new uint16[](1);
        bps[0] = 10_000;
        ledger.betBonusBatchFor(
            TOKEN,
            BONUS_ID,
            players,
            _actions(keccak256("legacy-cancel-wager")),
            _rounds(round),
            _amounts(10 ether),
            bps
        );
        ledger.cancel(round);
        assertEq(bonus.balanceOf(PLAYER, BONUS_ID), 100 ether);
        assertEq(bonus.wageredAmount(BONUS_ID), 0);
        assertEq(ledger.roundWagerContribution(round), 0);
    }

    function testCancellationAfterPartialReleaseRestoresOnlyUnreleasedReservation() public {
        bytes32 round = _reserve(40 ether);
        _consume(round, keccak256("cancel-consume"), 25 ether);
        _release(round, keccak256("cancel-release"), 15 ether);

        ledger.cancel(round);

        assertEq(bonus.balanceOf(PLAYER, BONUS_ID), 100 ether);
        assertEq(bonus.wageredAmount(BONUS_ID), 0);
        (,,, uint256 reserved, uint256 consumed, uint256 released,, uint256 closedAt,,) = ledger.rounds(round);
        assertEq(reserved, 40 ether);
        assertEq(consumed, 25 ether);
        assertEq(released, 40 ether);
        assertGt(closedAt, 0);
    }

    function testOpenRoundTransitionsKeepReservedBonusContractAfterRotation() public {
        Bonus1155LedgerMock bonusB = _newBonus();
        bonusB.mint(PLAYER, BONUS_ID, 100 ether);

        bytes32 round = _reserve(40 ether);
        ledger.setBonusContract(address(bonusB));

        _consume(round, keccak256("rotated-consume"), 10 ether);
        _release(round, keccak256("rotated-release"), 30 ether);
        _settle(round, keccak256("rotated-settle"), 25 ether);

        assertEq(bonus.balanceOf(PLAYER, BONUS_ID), 115 ether);
        assertEq(bonus.wageredAmount(BONUS_ID), 10 ether);
        assertEq(bonusB.balanceOf(PLAYER, BONUS_ID), 100 ether);
        assertEq(bonusB.wageredAmount(BONUS_ID), 0);
        (,,,,,,,, address roundBonusContract,) = ledger.rounds(round);
        assertEq(roundBonusContract, address(bonus));
    }

    function testCancellationKeepsReservedBonusContractAfterRotation() public {
        Bonus1155LedgerMock bonusB = _newBonus();
        bonusB.mint(PLAYER, BONUS_ID, 100 ether);

        bytes32 round = _reserve(10 ether);
        ledger.setBonusContract(address(bonusB));
        ledger.cancel(round);

        assertEq(bonus.balanceOf(PLAYER, BONUS_ID), 100 ether);
        assertEq(bonusB.balanceOf(PLAYER, BONUS_ID), 100 ether);
    }

    function testNewReservationsUseRotatedBonusContract() public {
        Bonus1155LedgerMock bonusB = _newBonus();
        bonusB.mint(PLAYER, BONUS_ID, 100 ether);
        ledger.setBonusContract(address(bonusB));

        bytes32 round = _reserve(10 ether);

        assertEq(bonus.balanceOf(PLAYER, BONUS_ID), 100 ether);
        assertEq(bonusB.balanceOf(PLAYER, BONUS_ID), 90 ether);
        (,,,,,,,, address roundBonusContract,) = ledger.rounds(round);
        assertEq(roundBonusContract, address(bonusB));
    }

    function testLegacyRoundKeepsBonusContractAfterRotation() public {
        Bonus1155LedgerMock bonusB = _newBonus();
        bonusB.mint(PLAYER, BONUS_ID, 100 ether);
        bytes32 round = keccak256("rotated-legacy-round");
        address[] memory players = new address[](1);
        players[0] = PLAYER;
        uint16[] memory bps = new uint16[](1);
        bps[0] = 10_000;

        ledger.betBonusBatchFor(
            TOKEN,
            BONUS_ID,
            players,
            _actions(keccak256("rotated-legacy-wager")),
            _rounds(round),
            _amounts(10 ether),
            bps
        );
        ledger.setBonusContract(address(bonusB));
        ledger.settleBonusBatch(
            TOKEN, BONUS_ID, _actions(keccak256("rotated-legacy-settle")), _rounds(round), _amounts(15 ether)
        );

        assertEq(bonus.balanceOf(PLAYER, BONUS_ID), 105 ether);
        assertEq(bonusB.balanceOf(PLAYER, BONUS_ID), 100 ether);
    }

    function testBonusContractMustContainCode() public {
        vm.expectRevert("ZERO_BONUS");
        ledger.setBonusContract(address(0));
        vm.expectRevert("BONUS_NOT_CONTRACT");
        ledger.setBonusContract(address(0x1234));
    }

    function _reserve(uint256 amount) private returns (bytes32 round) {
        round = keccak256(abi.encode("round", amount));
        address[] memory players = new address[](1);
        players[0] = PLAYER;
        ledger.reserveBonusBatchFor(
            TOKEN,
            BONUS_ID,
            players,
            _actions(keccak256(abi.encode("reserve", amount))),
            _rounds(round),
            _amounts(amount)
        );
    }

    function _consume(bytes32 round, bytes32 action, uint256 amount) private {
        uint16[] memory bps = new uint16[](1);
        bps[0] = 10_000;
        ledger.consumeBonusBatch(TOKEN, BONUS_ID, _actions(action), _rounds(round), _amounts(amount), bps);
    }

    function _release(bytes32 round, bytes32 action, uint256 amount) private {
        ledger.releaseBonusBatch(TOKEN, BONUS_ID, _actions(action), _rounds(round), _amounts(amount));
    }

    function _settle(bytes32 round, bytes32 action, uint256 payout) private {
        ledger.settleBonusBatch(TOKEN, BONUS_ID, _actions(action), _rounds(round), _amounts(payout));
    }

    function _newBonus() private returns (Bonus1155LedgerMock value) {
        value = new Bonus1155LedgerMock();
        value.setLedger(address(ledger));
    }

    function _actions(bytes32 value) private pure returns (bytes32[] memory values) {
        values = new bytes32[](1);
        values[0] = value;
    }

    function _rounds(bytes32 value) private pure returns (bytes32[] memory values) {
        values = new bytes32[](1);
        values[0] = value;
    }

    function _amounts(uint256 value) private pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }

    function _keys(bytes32 first, bytes32 second) private pure returns (bytes32[] memory values) {
        values = new bytes32[](2);
        values[0] = first;
        values[1] = second;
    }
}
