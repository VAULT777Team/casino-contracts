// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {HouseGameLedger} from "../contracts/games/house/HouseGameLedger.sol";

contract HouseLedgerToken is ERC20 {
    constructor() ERC20("Test Token", "TEST") {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }
}

contract HouseLedgerBankrollMock {
    mapping(address => uint256) public reservedFunds;
    mapping(address => bool) public allowedToken;
    bool public failPayouts;

    constructor() {
        allowedToken[address(0)] = true;
    }

    function setAllowedToken(address token, bool allowed) external {
        allowedToken[token] = allowed;
    }

    function setFailPayouts(bool fail) external {
        failPayouts = fail;
    }

    function getIsValidWager(address, address token) external view returns (bool) {
        return allowedToken[token];
    }

    function depositEther() external payable returns (bool) {
        return true;
    }

    function deposit(address token, uint256 amount) external {
        ERC20(token).transferFrom(msg.sender, address(this), amount);
    }

    function reserveFunds(address token, uint256 amount) external {
        require(getAvailableBalance(token) >= amount, "INSUFFICIENT");
        reservedFunds[token] += amount;
    }

    function releaseFunds(address token, uint256 amount) external {
        reservedFunds[token] -= amount;
    }

    function getAvailableBalance(address token) public view returns (uint256) {
        uint256 balance = token == address(0) ? address(this).balance : ERC20(token).balanceOf(address(this));
        uint256 reserved = reservedFunds[token];
        return balance > reserved ? balance - reserved : 0;
    }

    function transferPayout(address player, uint256 amount, address token) external {
        require(!failPayouts, "PAYOUT_FAILED");
        if (token == address(0)) {
            (bool success,) = payable(player).call{value: amount}("");
            require(success, "NATIVE_FAILED");
        } else {
            ERC20(token).transfer(player, amount);
        }
    }

    receive() external payable {}
}

contract HouseLedgerRegistryMock {
    address public bankroll;

    constructor(address initialBankroll) {
        bankroll = initialBankroll;
    }

    function setBankroll(address nextBankroll) external {
        bankroll = nextBankroll;
    }

    function getCurrentBankroll() external view returns (address, address, string memory, uint256) {
        return (bankroll, address(0), "test", block.timestamp);
    }
}

contract HouseGameLedgerTest is Test {
    uint256 internal constant OPERATOR_KEY = 0xA11CE;
    address internal constant PLAYER = address(0xBEEF);
    address internal constant OTHER_PLAYER = address(0xCAFE);
    bytes32 internal constant GAME_ID = keccak256("coinflip-v1");
    bytes32 internal constant PLINKO_ID = keccak256("plinko-v1");

    HouseGameLedger internal ledger;
    HouseLedgerBankrollMock internal bankroll;
    HouseLedgerRegistryMock internal registry;
    HouseLedgerToken internal token;
    address internal operator;

    function setUp() public {
        operator = vm.addr(OPERATOR_KEY);
        bankroll = new HouseLedgerBankrollMock();
        registry = new HouseLedgerRegistryMock(address(bankroll));
        ledger = new HouseGameLedger(address(this), operator, address(registry), 10 minutes);
        token = new HouseLedgerToken();
        bankroll.setAllowedToken(address(token), true);

        vm.deal(PLAYER, 100 ether);
        vm.deal(OTHER_PLAYER, 100 ether);
        vm.deal(address(bankroll), 20_000 ether);
        token.mint(PLAYER, 100 ether);
        token.mint(OTHER_PLAYER, 100 ether);
        token.mint(address(bankroll), 20_000 ether);

        vm.prank(PLAYER);
        token.approve(address(ledger), type(uint256).max);
        vm.prank(OTHER_PLAYER);
        token.approve(address(ledger), type(uint256).max);
    }

    function testOwnerCanSetOperatorsInOneCall() public {
        address[] memory operators = new address[](3);
        operators[0] = address(0x1001);
        operators[1] = address(0x1002);
        operators[2] = address(0x1003);
        bool[] memory allowed = new bool[](3);
        allowed[0] = true;
        allowed[1] = true;
        allowed[2] = true;

        ledger.setOperators(operators, allowed);
        for (uint256 i; i < operators.length; ++i) {
            assertTrue(ledger.isOperator(operators[i]));
            allowed[i] = false;
        }

        ledger.setOperators(operators, allowed);
        for (uint256 i; i < operators.length; ++i) {
            assertFalse(ledger.isOperator(operators[i]));
        }
    }

    function testSetOperatorsIsAtomicAndAdminOnly() public {
        address[] memory operators = new address[](2);
        operators[0] = address(0x1001);
        operators[1] = address(0);
        bool[] memory allowed = new bool[](2);
        allowed[0] = true;
        allowed[1] = true;

        vm.expectRevert(HouseGameLedger.ZeroAddress.selector);
        ledger.setOperators(operators, allowed);
        assertFalse(ledger.isOperator(operators[0]));

        operators[1] = address(0x1002);
        vm.prank(address(0xBAD));
        vm.expectRevert(HouseGameLedger.NotAdmin.selector);
        ledger.setOperators(operators, allowed);

        bool[] memory mismatched = new bool[](1);
        vm.expectRevert(HouseGameLedger.InvalidValue.selector);
        ledger.setOperators(operators, mismatched);
    }

    function testOwnerCanSetMixedAdminStatesInOneCall() public {
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

    function testSetAdminsRejectsInvalidArraysAtomically() public {
        address[] memory admins = new address[](2);
        admins[0] = address(0x2001);
        admins[1] = address(0);
        bool[] memory allowed = new bool[](2);
        allowed[0] = true;
        allowed[1] = true;

        vm.expectRevert(HouseGameLedger.ZeroAddress.selector);
        ledger.setAdmins(admins, allowed);
        assertFalse(ledger.isAdmin(admins[0]));

        bool[] memory mismatched = new bool[](1);
        vm.expectRevert(HouseGameLedger.InvalidValue.selector);
        ledger.setAdmins(admins, mismatched);
    }

    function testDuplicateReservationActionIsRejected() public {
        HouseGameLedger.Reservation[] memory first =
            _oneReservation(GAME_ID, keccak256("reserve-action"), keccak256("round-one"), 1 ether);
        _reserveNative(PLAYER, first);

        HouseGameLedger.Reservation[] memory duplicate =
            _oneReservation(GAME_ID, keccak256("reserve-action"), keccak256("round-two"), 1 ether);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _sign(PLAYER, address(0), duplicate, deadline);

        vm.expectRevert(abi.encodeWithSelector(HouseGameLedger.DuplicateAction.selector, keccak256("reserve-action")));
        vm.prank(PLAYER);
        ledger.reserveBatch{value: 1 ether}(address(0), duplicate, deadline, signature);
    }

    function testDuplicateSettlementActionRevertsWholeBatch() public {
        HouseGameLedger.Reservation[] memory reservations = new HouseGameLedger.Reservation[](2);
        reservations[0] = HouseGameLedger.Reservation({
            gameId: GAME_ID,
            actionKey: keccak256("batch-reserve-one"),
            roundKey: keccak256("batch-round-one"),
            amount: 1 ether,
            maxPayout: 5 ether
        });
        reservations[1] = HouseGameLedger.Reservation({
            gameId: GAME_ID,
            actionKey: keccak256("batch-reserve-two"),
            roundKey: keccak256("batch-round-two"),
            amount: 1 ether,
            maxPayout: 5 ether
        });
        _reserveNative(PLAYER, reservations);

        bytes32 duplicateAction = keccak256("duplicate-settlement");
        HouseGameLedger.Settlement[] memory settlements = new HouseGameLedger.Settlement[](2);
        settlements[0] = HouseGameLedger.Settlement({
            actionKey: duplicateAction,
            roundKey: reservations[0].roundKey,
            actualWager: 1 ether,
            grossPlayerReturn: 1 ether,
            finalClose: true
        });
        settlements[1] = HouseGameLedger.Settlement({
            actionKey: duplicateAction,
            roundKey: reservations[1].roundKey,
            actualWager: 1 ether,
            grossPlayerReturn: 1 ether,
            finalClose: true
        });

        HouseGameLedger.SettlementInitiation[] memory initiations = new HouseGameLedger.SettlementInitiation[](2);
        initiations[0] = HouseGameLedger.SettlementInitiation({
            roundKey: reservations[0].roundKey, settlementActionKey: duplicateAction
        });
        initiations[1] = HouseGameLedger.SettlementInitiation({
            roundKey: reservations[1].roundKey, settlementActionKey: duplicateAction
        });
        vm.prank(operator);
        ledger.initiateSettlementBatch(keccak256("duplicate-initiation"), initiations, block.timestamp + 5 minutes);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(HouseGameLedger.DuplicateAction.selector, duplicateAction));
        ledger.settleBatch(settlements);

        assertEq(
            uint256(ledger.getRoundStatus(reservations[0].roundKey)), uint256(HouseGameLedger.RoundStatus.Reserved)
        );
        assertEq(
            uint256(ledger.getRoundStatus(reservations[1].roundKey)), uint256(HouseGameLedger.RoundStatus.Reserved)
        );
        assertFalse(ledger.actionUsed(duplicateAction));
    }

    function testReservationSignatureBindsPlayerAndToken() public {
        HouseGameLedger.Reservation[] memory reservations =
            _oneReservation(GAME_ID, keccak256("bound-action"), keccak256("bound-round"), 1 ether);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory playerSignature = _sign(PLAYER, address(0), reservations, deadline);

        vm.prank(OTHER_PLAYER);
        vm.expectRevert(HouseGameLedger.InvalidOperatorSignature.selector);
        ledger.reserveBatch{value: 1 ether}(address(0), reservations, deadline, playerSignature);

        vm.prank(PLAYER);
        vm.expectRevert(HouseGameLedger.InvalidOperatorSignature.selector);
        ledger.reserveBatch(address(token), reservations, deadline, playerSignature);
    }

    function testRoundFinalityRejectsPostCloseActions() public {
        bytes32 roundKey = keccak256("final-round");
        _reserveNative(PLAYER, _oneReservation(GAME_ID, keccak256("final-reserve"), roundKey, 2 ether));
        _settle(keccak256("final-settle"), roundKey, 2 ether, 3 ether, true);

        assertEq(uint256(ledger.getRoundStatus(roundKey)), uint256(HouseGameLedger.RoundStatus.Closed));

        vm.expectRevert(
            abi.encodeWithSelector(
                HouseGameLedger.InvalidRoundStatus.selector, roundKey, HouseGameLedger.RoundStatus.Closed
            )
        );
        _settleOnly(keccak256("post-close-settle"), roundKey, 1 ether, 1 ether, true);

        HouseGameLedger.Reservation[] memory duplicateRound =
            _oneReservation(GAME_ID, keccak256("post-close-reserve"), roundKey, 1 ether);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _sign(PLAYER, address(0), duplicateRound, deadline);
        vm.expectRevert(abi.encodeWithSelector(HouseGameLedger.RoundAlreadyExists.selector, roundKey));
        vm.prank(PLAYER);
        ledger.reserveBatch{value: 1 ether}(address(0), duplicateRound, deadline, signature);
    }

    function testSettlementRequiresExplicitFinalClose() public {
        bytes32 roundKey = keccak256("non-final-round");
        _reserveNative(PLAYER, _oneReservation(GAME_ID, keccak256("non-final-reserve"), roundKey, 1 ether));

        bytes32 actionKey = keccak256("non-final-settle");
        _initiate(keccak256("non-final-initiation"), roundKey, actionKey, block.timestamp + 5 minutes);
        vm.expectRevert(HouseGameLedger.InvalidFinalClose.selector);
        _settleOnly(actionKey, roundKey, 1 ether, 1 ether, false);
    }

    function testActualWagerCannotExceedReservation() public {
        bytes32 roundKey = keccak256("wager-limit-round");
        _reserveNative(PLAYER, _oneReservation(GAME_ID, keccak256("wager-limit-reserve"), roundKey, 1 ether));

        bytes32 actionKey = keccak256("wager-limit-settle");
        _initiate(keccak256("wager-limit-initiation"), roundKey, actionKey, block.timestamp + 5 minutes);
        vm.expectRevert(HouseGameLedger.WagerExceedsReservation.selector);
        _settleOnly(actionKey, roundKey, 1 ether + 1, 1 ether, true);
    }

    function testUnusedReservationMustBeIncludedInGrossReturn() public {
        bytes32 roundKey = keccak256("unused-round");
        _reserveNative(PLAYER, _oneReservation(GAME_ID, keccak256("unused-reserve"), roundKey, 2 ether));

        bytes32 actionKey = keccak256("unused-settle");
        _initiate(keccak256("unused-initiation"), roundKey, actionKey, block.timestamp + 5 minutes);
        vm.expectRevert(HouseGameLedger.UnusedReservationNotReturned.selector);
        _settleOnly(actionKey, roundKey, 1 ether, 1 ether - 1, true);
    }

    function testPayoutLimitsSupportOneThousandXPlinko() public {
        bytes32 winningRound = keccak256("plinko-winning-round");
        HouseGameLedger.Reservation[] memory winning =
            _oneReservation(PLINKO_ID, keccak256("plinko-winning-reserve"), winningRound, 1 ether);
        winning[0].maxPayout = 1_000 ether;
        _reserveNative(PLAYER, winning);
        _settle(keccak256("plinko-winning-settle"), winningRound, 1 ether, 1_000 ether, true);
        assertEq(PLAYER.balance, 1_099 ether);

        bytes32 excessiveRound = keccak256("plinko-excessive-round");
        HouseGameLedger.Reservation[] memory excessive =
            _oneReservation(PLINKO_ID, keccak256("plinko-excessive-reserve"), excessiveRound, 1 ether);
        excessive[0].maxPayout = 1_000 ether;
        _reserveNative(PLAYER, excessive);
        bytes32 actionKey = keccak256("plinko-excessive-settle");
        _initiate(keccak256("plinko-excessive-initiation"), excessiveRound, actionKey, block.timestamp + 5 minutes);
        vm.expectRevert(HouseGameLedger.PayoutLimitExceeded.selector);
        _settleOnly(actionKey, excessiveRound, 1 ether, 1_000 ether + 1, true);
    }

    function testPlayerCanCancelAfterRefundDelay() public {
        bytes32 roundKey = keccak256("cancel-round");
        _reserveNative(PLAYER, _oneReservation(GAME_ID, keccak256("cancel-reserve"), roundKey, 3 ether));

        vm.prank(PLAYER);
        vm.expectRevert(
            abi.encodeWithSelector(HouseGameLedger.RefundNotAvailable.selector, block.timestamp + 10 minutes)
        );
        ledger.cancelRound(keccak256("cancel-action"), roundKey);

        vm.warp(block.timestamp + 10 minutes);
        vm.prank(PLAYER);
        ledger.cancelRound(keccak256("cancel-action"), roundKey);

        assertEq(PLAYER.balance, 100 ether);
        assertEq(uint256(ledger.getRoundStatus(roundKey)), uint256(HouseGameLedger.RoundStatus.Cancelled));

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                HouseGameLedger.InvalidRoundStatus.selector, roundKey, HouseGameLedger.RoundStatus.Cancelled
            )
        );
        ledger.cancelRound(keccak256("cancel-again"), roundKey);
    }

    function testPlayerCannotCancelAfterSettlementInitiation() public {
        bytes32 roundKey = keccak256("locked-round");
        bytes32 settlementAction = keccak256("locked-settlement");
        _reserveNative(PLAYER, _oneReservation(GAME_ID, keccak256("locked-reserve"), roundKey, 3 ether));
        vm.warp(block.timestamp + 10 minutes);
        _initiate(keccak256("locked-initiation"), roundKey, settlementAction, block.timestamp + 5 minutes);

        vm.prank(PLAYER);
        vm.expectRevert(
            abi.encodeWithSelector(HouseGameLedger.SettlementLocked.selector, roundKey, block.timestamp + 5 minutes)
        );
        ledger.cancelRound(keccak256("locked-cancel"), roundKey);

        HouseGameLedger.Round memory round = ledger.getRound(roundKey);
        assertEq(round.lockedSettlementActionKey, settlementAction);
        assertEq(uint256(round.status), uint256(HouseGameLedger.RoundStatus.Reserved));
    }

    function testExpiredSettlementLockAllowsPlayerRecoveryAndCannotBeRenewed() public {
        bytes32 roundKey = keccak256("stale-lock-round");
        _reserveNative(PLAYER, _oneReservation(GAME_ID, keccak256("stale-lock-reserve"), roundKey, 3 ether));
        bytes32 expiry = bytes32(block.timestamp + 5 minutes);
        _initiate(keccak256("stale-lock-initiation"), roundKey, keccak256("stale-lock-settlement"), uint256(expiry));
        vm.warp(uint256(expiry) + 1);

        HouseGameLedger.SettlementInitiation[] memory retry = new HouseGameLedger.SettlementInitiation[](1);
        retry[0] = HouseGameLedger.SettlementInitiation({
            roundKey: roundKey, settlementActionKey: keccak256("stale-lock-settlement")
        });
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(HouseGameLedger.SettlementAlreadyInitiated.selector, roundKey));
        ledger.initiateSettlementBatch(keccak256("stale-lock-retry"), retry, block.timestamp + 5 minutes);

        vm.warp(block.timestamp + 5 minutes);
        vm.prank(PLAYER);
        ledger.cancelRound(keccak256("stale-lock-cancel"), roundKey);
        assertEq(uint256(ledger.getRoundStatus(roundKey)), uint256(HouseGameLedger.RoundStatus.Cancelled));
    }

    function testSettlementRequiresActiveMatchingInitiation() public {
        bytes32 roundKey = keccak256("init-required-round");
        _reserveNative(PLAYER, _oneReservation(GAME_ID, keccak256("init-required-reserve"), roundKey, 1 ether));

        HouseGameLedger.Settlement[] memory settlements = new HouseGameLedger.Settlement[](1);
        settlements[0] = HouseGameLedger.Settlement({
            actionKey: keccak256("init-required-settle"),
            roundKey: roundKey,
            actualWager: 1 ether,
            grossPlayerReturn: 0,
            finalClose: true
        });
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(HouseGameLedger.SettlementNotInitiated.selector, roundKey));
        ledger.settleBatch(settlements);

        _initiate(
            keccak256("init-required-initiation"),
            roundKey,
            keccak256("different-settlement"),
            block.timestamp + 5 minutes
        );
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(HouseGameLedger.SettlementActionMismatch.selector, roundKey));
        ledger.settleBatch(settlements);
    }

    function testSettlementFailsAfterLockExpiry() public {
        bytes32 roundKey = keccak256("expired-settlement-round");
        bytes32 settlementAction = keccak256("expired-settlement-action");
        _reserveNative(PLAYER, _oneReservation(GAME_ID, keccak256("expired-settlement-reserve"), roundKey, 1 ether));
        uint256 expiresAt = block.timestamp + 1 minutes;
        _initiate(keccak256("expired-settlement-initiation"), roundKey, settlementAction, expiresAt);
        vm.warp(expiresAt + 1);

        HouseGameLedger.Settlement[] memory settlements = new HouseGameLedger.Settlement[](1);
        settlements[0] = HouseGameLedger.Settlement({
            actionKey: settlementAction,
            roundKey: roundKey,
            actualWager: 1 ether,
            grossPlayerReturn: 0,
            finalClose: true
        });
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(HouseGameLedger.SettlementLockExpired.selector, roundKey, expiresAt));
        ledger.settleBatch(settlements);
    }

    function testRefundDelayHasContractMinimum() public {
        vm.expectRevert(HouseGameLedger.RefundDelayTooShort.selector);
        ledger.setRefundDelay(5 minutes - 1);

        vm.expectRevert(HouseGameLedger.RefundDelayTooShort.selector);
        new HouseGameLedger(address(this), operator, address(registry), 0);
    }

    function testNativeBatchReservationAndSettlement() public {
        HouseGameLedger.Reservation[] memory reservations = new HouseGameLedger.Reservation[](2);
        reservations[0] = HouseGameLedger.Reservation({
            gameId: GAME_ID,
            actionKey: keccak256("native-reserve-one"),
            roundKey: keccak256("native-round-one"),
            amount: 2 ether,
            maxPayout: 10 ether
        });
        reservations[1] = HouseGameLedger.Reservation({
            gameId: GAME_ID,
            actionKey: keccak256("native-reserve-two"),
            roundKey: keccak256("native-round-two"),
            amount: 3 ether,
            maxPayout: 15 ether
        });
        _reserveNative(PLAYER, reservations);

        assertEq(address(bankroll).balance, 20_005 ether);
        assertEq(bankroll.reservedFunds(address(0)), 25 ether);

        HouseGameLedger.Settlement[] memory settlements = new HouseGameLedger.Settlement[](2);
        settlements[0] = HouseGameLedger.Settlement({
            actionKey: keccak256("native-settle-one"),
            roundKey: reservations[0].roundKey,
            actualWager: 1 ether,
            grossPlayerReturn: 3 ether,
            finalClose: true
        });
        settlements[1] = HouseGameLedger.Settlement({
            actionKey: keccak256("native-settle-two"),
            roundKey: reservations[1].roundKey,
            actualWager: 2 ether,
            grossPlayerReturn: 1 ether,
            finalClose: true
        });
        _initiateBatch(keccak256("native-batch-initiation"), settlements, block.timestamp + 5 minutes);
        vm.prank(operator);
        ledger.settleBatch(settlements);

        assertEq(PLAYER.balance, 99 ether);
        assertEq(bankroll.reservedFunds(address(0)), 0);
    }

    function testErc20BatchReservationAndSettlement() public {
        uint256 playerStart = token.balanceOf(PLAYER);
        HouseGameLedger.Reservation[] memory reservations = new HouseGameLedger.Reservation[](2);
        reservations[0] = HouseGameLedger.Reservation({
            gameId: GAME_ID,
            actionKey: keccak256("token-reserve-one"),
            roundKey: keccak256("token-round-one"),
            amount: 2 ether,
            maxPayout: 10 ether
        });
        reservations[1] = HouseGameLedger.Reservation({
            gameId: GAME_ID,
            actionKey: keccak256("token-reserve-two"),
            roundKey: keccak256("token-round-two"),
            amount: 3 ether,
            maxPayout: 15 ether
        });
        _reserveToken(PLAYER, address(token), reservations);

        assertEq(token.balanceOf(PLAYER), playerStart - 5 ether);
        assertEq(bankroll.reservedFunds(address(token)), 25 ether);

        HouseGameLedger.Settlement[] memory settlements = new HouseGameLedger.Settlement[](2);
        settlements[0] = HouseGameLedger.Settlement({
            actionKey: keccak256("token-settle-one"),
            roundKey: reservations[0].roundKey,
            actualWager: 2 ether,
            grossPlayerReturn: 4 ether,
            finalClose: true
        });
        settlements[1] = HouseGameLedger.Settlement({
            actionKey: keccak256("token-settle-two"),
            roundKey: reservations[1].roundKey,
            actualWager: 1 ether,
            grossPlayerReturn: 2 ether,
            finalClose: true
        });
        _initiateBatch(keccak256("token-batch-initiation"), settlements, block.timestamp + 5 minutes);
        vm.prank(operator);
        ledger.settleBatch(settlements);

        assertEq(token.balanceOf(PLAYER), playerStart + 1 ether);
        assertEq(bankroll.reservedFunds(address(token)), 0);
    }

    function testOperatorCanReserveRepeatedPlayerErc20Batch() public {
        uint256 playerStart = token.balanceOf(PLAYER);
        HouseGameLedger.Reservation[] memory reservations = new HouseGameLedger.Reservation[](2);
        reservations[0] = HouseGameLedger.Reservation({
            gameId: GAME_ID,
            actionKey: keccak256("operator-repeat-action-one"),
            roundKey: keccak256("operator-repeat-round-one"),
            amount: 2 ether,
            maxPayout: 8 ether
        });
        reservations[1] = HouseGameLedger.Reservation({
            gameId: PLINKO_ID,
            actionKey: keccak256("operator-repeat-action-two"),
            roundKey: keccak256("operator-repeat-round-two"),
            amount: 3 ether,
            maxPayout: 12 ether
        });
        address[] memory players = new address[](2);
        players[0] = PLAYER;
        players[1] = PLAYER;

        vm.prank(operator);
        ledger.reserveBatchFor(address(token), players, reservations);

        assertEq(token.balanceOf(PLAYER), playerStart - 5 ether);
        assertEq(token.balanceOf(operator), 0);
        assertEq(token.balanceOf(address(bankroll)), 20_005 ether);
        assertEq(bankroll.reservedFunds(address(token)), 20 ether);
        HouseGameLedger.Round memory first = ledger.getRound(reservations[0].roundKey);
        HouseGameLedger.Round memory second = ledger.getRound(reservations[1].roundKey);
        assertEq(first.player, PLAYER);
        assertEq(first.gameId, GAME_ID);
        assertEq(first.reservation, 2 ether);
        assertEq(second.player, PLAYER);
        assertEq(second.gameId, PLINKO_ID);
        assertEq(second.reservation, 3 ether);
    }

    function testOperatorCanReserveForMultiplePlayers() public {
        HouseGameLedger.Reservation[] memory reservations = new HouseGameLedger.Reservation[](2);
        reservations[0] = HouseGameLedger.Reservation({
            gameId: GAME_ID,
            actionKey: keccak256("operator-multi-action-one"),
            roundKey: keccak256("operator-multi-round-one"),
            amount: 4 ether,
            maxPayout: 10 ether
        });
        reservations[1] = HouseGameLedger.Reservation({
            gameId: GAME_ID,
            actionKey: keccak256("operator-multi-action-two"),
            roundKey: keccak256("operator-multi-round-two"),
            amount: 6 ether,
            maxPayout: 15 ether
        });
        address[] memory players = new address[](2);
        players[0] = PLAYER;
        players[1] = OTHER_PLAYER;

        vm.prank(operator);
        ledger.reserveBatchFor(address(token), players, reservations);

        assertEq(token.balanceOf(PLAYER), 96 ether);
        assertEq(token.balanceOf(OTHER_PLAYER), 94 ether);
        assertEq(ledger.getRound(reservations[0].roundKey).player, PLAYER);
        assertEq(ledger.getRound(reservations[1].roundKey).player, OTHER_PLAYER);
        assertEq(bankroll.reservedFunds(address(token)), 25 ether);
    }

    function testReserveBatchForIsOperatorOnly() public {
        HouseGameLedger.Reservation[] memory reservations =
            _oneReservation(GAME_ID, keccak256("unauthorized-action"), keccak256("unauthorized-round"), 1 ether);
        address[] memory players = _onePlayer(PLAYER);

        vm.expectRevert(HouseGameLedger.NotOperator.selector);
        ledger.reserveBatchFor(address(token), players, reservations);
    }

    function testReserveBatchForRejectsNativeToken() public {
        HouseGameLedger.Reservation[] memory reservations =
            _oneReservation(GAME_ID, keccak256("native-for-action"), keccak256("native-for-round"), 1 ether);

        vm.prank(operator);
        vm.expectRevert(HouseGameLedger.NativeValueNotAllowed.selector);
        ledger.reserveBatchFor(address(0), _onePlayer(PLAYER), reservations);
    }

    function testReserveBatchForRejectsEmptyAndMismatchedLengths() public {
        HouseGameLedger.Reservation[] memory emptyReservations = new HouseGameLedger.Reservation[](0);
        address[] memory emptyPlayers = new address[](0);
        vm.prank(operator);
        vm.expectRevert(HouseGameLedger.BatchLengthMismatch.selector);
        ledger.reserveBatchFor(address(token), emptyPlayers, emptyReservations);

        HouseGameLedger.Reservation[] memory reservations =
            _oneReservation(GAME_ID, keccak256("length-action"), keccak256("length-round"), 1 ether);
        vm.prank(operator);
        vm.expectRevert(HouseGameLedger.BatchLengthMismatch.selector);
        ledger.reserveBatchFor(address(token), emptyPlayers, reservations);
    }

    function testReserveBatchForRejectsZeroPlayer() public {
        HouseGameLedger.Reservation[] memory reservations =
            _oneReservation(GAME_ID, keccak256("zero-player-action"), keccak256("zero-player-round"), 1 ether);

        vm.prank(operator);
        vm.expectRevert(HouseGameLedger.ZeroAddress.selector);
        ledger.reserveBatchFor(address(token), _onePlayer(address(0)), reservations);
    }

    function testReserveBatchForRevertsAtomicallyOnInsufficientAllowance() public {
        HouseGameLedger.Reservation[] memory reservations =
            _oneReservation(GAME_ID, keccak256("allowance-action"), keccak256("allowance-round"), 2 ether);
        vm.prank(PLAYER);
        token.approve(address(ledger), 1 ether);

        vm.prank(operator);
        vm.expectRevert();
        ledger.reserveBatchFor(address(token), _onePlayer(PLAYER), reservations);

        assertEq(uint256(ledger.getRoundStatus(reservations[0].roundKey)), uint256(HouseGameLedger.RoundStatus.None));
        assertFalse(ledger.actionUsed(reservations[0].actionKey));
        assertEq(token.balanceOf(PLAYER), 100 ether);
    }

    function testReserveBatchForRevertsAtomicallyOnInsufficientBalance() public {
        address unfundedPlayer = address(0xD00D);
        vm.prank(unfundedPlayer);
        token.approve(address(ledger), type(uint256).max);
        HouseGameLedger.Reservation[] memory reservations =
            _oneReservation(GAME_ID, keccak256("balance-action"), keccak256("balance-round"), 1 ether);

        vm.prank(operator);
        vm.expectRevert();
        ledger.reserveBatchFor(address(token), _onePlayer(unfundedPlayer), reservations);

        assertEq(uint256(ledger.getRoundStatus(reservations[0].roundKey)), uint256(HouseGameLedger.RoundStatus.None));
        assertFalse(ledger.actionUsed(reservations[0].actionKey));
    }

    function testExistingReserveBatchStillSupportsNativePlayerFunding() public {
        HouseGameLedger.Reservation[] memory reservations =
            _oneReservation(GAME_ID, keccak256("legacy-native-action"), keccak256("legacy-native-round"), 2 ether);

        _reserveNative(PLAYER, reservations);

        HouseGameLedger.Round memory round = ledger.getRound(reservations[0].roundKey);
        assertEq(round.player, PLAYER);
        assertEq(round.token, address(0));
        assertEq(round.reservation, 2 ether);
        assertEq(address(bankroll).balance, 20_002 ether);
    }

    function testPayoutFailureBecomesPendingAndKeepsFundsReserved() public {
        bytes32 roundKey = keccak256("pending-round");
        _reserveNative(PLAYER, _oneReservation(GAME_ID, keccak256("pending-reserve"), roundKey, 2 ether));
        bankroll.setFailPayouts(true);

        _settle(keccak256("pending-settle"), roundKey, 1 ether, 3 ether, true);

        (uint256 pendingAmount) = ledger.pendingPayouts(PLAYER, address(bankroll), address(0));
        assertEq(pendingAmount, 3 ether);
        assertEq(bankroll.reservedFunds(address(0)), 3 ether);

        bankroll.setFailPayouts(false);
        vm.prank(PLAYER);
        ledger.claimPending(address(bankroll), address(0));

        (pendingAmount) = ledger.pendingPayouts(PLAYER, address(bankroll), address(0));
        assertEq(pendingAmount, 0);
        assertEq(bankroll.reservedFunds(address(0)), 0);
        assertEq(PLAYER.balance, 101 ether);
    }

    function testPauseBlocksReservationsButNotSettlementOrRefund() public {
        bytes32 roundKey = keccak256("pause-round");
        _reserveNative(PLAYER, _oneReservation(GAME_ID, keccak256("pause-reserve"), roundKey, 1 ether));
        ledger.setPaused(true);

        HouseGameLedger.Reservation[] memory pausedReservation =
            _oneReservation(GAME_ID, keccak256("paused-new-reserve"), keccak256("paused-new-round"), 1 ether);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _sign(PLAYER, address(0), pausedReservation, deadline);
        vm.expectRevert(HouseGameLedger.Paused.selector);
        vm.prank(PLAYER);
        ledger.reserveBatch{value: 1 ether}(address(0), pausedReservation, deadline, signature);

        vm.expectRevert(HouseGameLedger.Paused.selector);
        vm.prank(operator);
        ledger.reserveBatchFor(address(token), _onePlayer(PLAYER), pausedReservation);

        _settle(keccak256("pause-settle"), roundKey, 1 ether, 1 ether, true);
    }

    function testSignedMaximumPayoutMustCoverReservationAndCapsSettlement() public {
        HouseGameLedger.Reservation[] memory invalid =
            _oneReservation(GAME_ID, keccak256("invalid-action"), keccak256("invalid-round"), 2 ether);
        invalid[0].maxPayout = 2 ether - 1;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _sign(PLAYER, address(0), invalid, deadline);
        vm.expectRevert(HouseGameLedger.PayoutLimitExceeded.selector);
        vm.prank(PLAYER);
        ledger.reserveBatch{value: 2 ether}(address(0), invalid, deadline, signature);

        bytes32 roundKey = keccak256("absolute-cap-round");
        HouseGameLedger.Reservation[] memory capped =
            _oneReservation(GAME_ID, keccak256("absolute-cap-reserve"), roundKey, 1 ether);
        capped[0].maxPayout = 10 ether;
        _reserveNative(PLAYER, capped);
        bytes32 actionKey = keccak256("absolute-cap-settle");
        _initiate(keccak256("absolute-cap-initiation"), roundKey, actionKey, block.timestamp + 5 minutes);
        vm.expectRevert(HouseGameLedger.PayoutLimitExceeded.selector);
        _settleOnly(actionKey, roundKey, 1 ether, 10 ether + 1, true);
    }

    function _oneReservation(bytes32 gameId, bytes32 actionKey, bytes32 roundKey, uint256 amount)
        internal
        pure
        returns (HouseGameLedger.Reservation[] memory items)
    {
        items = new HouseGameLedger.Reservation[](1);
        items[0] = HouseGameLedger.Reservation({
            gameId: gameId, actionKey: actionKey, roundKey: roundKey, amount: amount, maxPayout: amount * 5
        });
    }

    function _onePlayer(address player) internal pure returns (address[] memory players) {
        players = new address[](1);
        players[0] = player;
    }

    function _reserveNative(address player, HouseGameLedger.Reservation[] memory reservations) internal {
        uint256 total;
        for (uint256 i; i < reservations.length; ++i) {
            total += reservations[i].amount;
        }
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _sign(player, address(0), reservations, deadline);
        vm.prank(player);
        ledger.reserveBatch{value: total}(address(0), reservations, deadline, signature);
    }

    function _reserveToken(address player, address wagerToken, HouseGameLedger.Reservation[] memory reservations)
        internal
    {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _sign(player, wagerToken, reservations, deadline);
        vm.prank(player);
        ledger.reserveBatch(wagerToken, reservations, deadline, signature);
    }

    function _settle(
        bytes32 actionKey,
        bytes32 roundKey,
        uint256 actualWager,
        uint256 grossPlayerReturn,
        bool finalClose
    ) internal {
        _initiate(keccak256(abi.encodePacked("initiate", actionKey)), roundKey, actionKey, block.timestamp + 5 minutes);
        _settleOnly(actionKey, roundKey, actualWager, grossPlayerReturn, finalClose);
    }

    function _settleOnly(
        bytes32 actionKey,
        bytes32 roundKey,
        uint256 actualWager,
        uint256 grossPlayerReturn,
        bool finalClose
    ) internal {
        HouseGameLedger.Settlement[] memory settlements = new HouseGameLedger.Settlement[](1);
        settlements[0] = HouseGameLedger.Settlement({
            actionKey: actionKey,
            roundKey: roundKey,
            actualWager: actualWager,
            grossPlayerReturn: grossPlayerReturn,
            finalClose: finalClose
        });
        vm.prank(operator);
        ledger.settleBatch(settlements);
    }

    function _initiate(bytes32 actionKey, bytes32 roundKey, bytes32 settlementActionKey, uint256 expiresAt) internal {
        HouseGameLedger.SettlementInitiation[] memory initiations = new HouseGameLedger.SettlementInitiation[](1);
        initiations[0] =
            HouseGameLedger.SettlementInitiation({roundKey: roundKey, settlementActionKey: settlementActionKey});
        vm.prank(operator);
        ledger.initiateSettlementBatch(actionKey, initiations, expiresAt);
    }

    function _initiateBatch(bytes32 actionKey, HouseGameLedger.Settlement[] memory settlements, uint256 expiresAt)
        internal
    {
        HouseGameLedger.SettlementInitiation[] memory initiations =
            new HouseGameLedger.SettlementInitiation[](settlements.length);
        for (uint256 i; i < settlements.length; ++i) {
            initiations[i] = HouseGameLedger.SettlementInitiation({
                roundKey: settlements[i].roundKey, settlementActionKey: settlements[i].actionKey
            });
        }
        vm.prank(operator);
        ledger.initiateSettlementBatch(actionKey, initiations, expiresAt);
    }

    function _sign(
        address player,
        address wagerToken,
        HouseGameLedger.Reservation[] memory reservations,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = ledger.reservationDigest(player, wagerToken, reservations, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OPERATOR_KEY, digest);
        return abi.encodePacked(r, s, v);
    }
}
