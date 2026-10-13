// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {IBankLP} from "../../bankroll/interfaces/IBankLP.sol";
import {IBankrollRegistry} from "../../bankroll/interfaces/IBankrollRegistry.sol";

/// @title House Game Ledger
/// @notice Reserves player funds for off-chain house games and closes each round once.
/// @dev Authorized operators submit player-funded ERC-20 reservations and final results.
///      The ledger enforces reservation, maximum payout, replay, player, and token constraints.
contract HouseGameLedger is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MIN_REFUND_DELAY = 5 minutes;
    uint256 public constant MIN_SETTLEMENT_LOCK_DURATION = 1 minutes;
    uint256 public constant MAX_SETTLEMENT_LOCK_DURATION = 30 minutes;

    enum RoundStatus {
        None,
        Reserved,
        Closed,
        Cancelled
    }

    struct Reservation {
        bytes32 gameId;
        bytes32 actionKey;
        bytes32 roundKey;
        uint256 amount;
        uint256 maxPayout;
    }

    struct Settlement {
        bytes32 actionKey;
        bytes32 roundKey;
        uint256 actualWager;
        uint256 grossPlayerReturn;
        bool finalClose;
    }

    struct SettlementInitiation {
        bytes32 roundKey;
        bytes32 settlementActionKey;
    }

    struct Round {
        RoundStatus status;
        bytes32 gameId;
        address player;
        address token;
        address bankroll;
        uint64 reservedAt;
        uint64 closedAt;
        uint256 refundAt;
        uint256 reservation;
        uint256 bankrollReservation;
        uint256 actualWager;
        uint256 grossPlayerReturn;
        bytes32 settlementLockActionKey;
        bytes32 lockedSettlementActionKey;
        uint256 settlementLockExpiresAt;
    }

    struct PendingPayout {
        uint256 amount;
        uint256 reservedAmount;
    }

    address public owner;
    IBankrollRegistry public registry;
    bool public paused;
    bool public bankrollReservationsEnabled;
    uint256 public refundDelay;

    mapping(address => bool) public isAdmin;
    mapping(address => bool) public isOperator;
    mapping(bytes32 => bool) public actionUsed;
    mapping(bytes32 => Round) private _rounds;
    mapping(bytes32 => uint256) public roundBankrollReservationAmount;
    mapping(address player => mapping(address bankroll => mapping(address token => PendingPayout))) public
        pendingPayouts;
    mapping(address bankroll => mapping(address token => uint256)) public totalPendingPayouts;

    error AlreadyPaused();
    error BatchLengthMismatch();
    error DuplicateAction(bytes32 actionKey);
    error InvalidFinalClose();
    error InvalidRoundStatus(bytes32 roundKey, RoundStatus status);
    error InvalidValue();
    error NativeValueNotAllowed();
    error NoPendingPayout();
    error NotAdmin();
    error NotOperator();
    error NotOwner();
    error NotPlayer();
    error Paused();
    error PayoutLimitExceeded();
    error ReservationTooSmall();
    error RefundNotAvailable(uint256 availableAt);
    error RefundDelayTooShort();
    error RoundAlreadyExists(bytes32 roundKey);
    error SettlementAlreadyInitiated(bytes32 roundKey);
    error SettlementLockExpired(bytes32 roundKey, uint256 expiredAt);
    error SettlementLockInvalidExpiry();
    error SettlementLocked(bytes32 roundKey, uint256 expiresAt);
    error SettlementNotInitiated(bytes32 roundKey);
    error SettlementActionMismatch(bytes32 roundKey);
    error TokenNotAllowed();
    error UnusedReservationNotReturned();
    error WagerExceedsReservation();
    error ZeroAddress();
    error ZeroKey();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event AdminUpdated(address indexed admin, bool allowed);
    event OperatorUpdated(address indexed operator, bool allowed);
    event RegistryUpdated(address indexed registry);
    event PauseUpdated(bool paused, address indexed caller);
    event BankrollReservationsEnabledUpdated(bool enabled, address indexed caller);
    event RefundDelayUpdated(uint256 refundDelay);
    event RoundReserved(
        bytes32 indexed actionKey,
        bytes32 indexed roundKey,
        bytes32 indexed gameId,
        address player,
        address token,
        address bankroll,
        uint256 reservation,
        uint256 bankrollReservation
    );
    event RoundClosed(
        bytes32 indexed actionKey,
        bytes32 indexed roundKey,
        address indexed player,
        uint256 actualWager,
        uint256 grossPlayerReturn
    );
    event SettlementInitiated(
        bytes32 indexed actionKey, bytes32 indexed roundKey, bytes32 indexed settlementActionKey, uint256 expiresAt
    );
    event RoundCancelled(bytes32 indexed actionKey, bytes32 indexed roundKey, address indexed player, uint256 refund);
    event PendingPayoutRecorded(
        address indexed player, address indexed bankroll, address indexed token, uint256 amount
    );
    event PendingPayoutClaimed(address indexed player, address indexed bankroll, address indexed token, uint256 amount);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != owner && !isAdmin[msg.sender]) revert NotAdmin();
        _;
    }

    modifier onlyOperator() {
        if (!isOperator[msg.sender]) revert NotOperator();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    constructor(address initialOwner, address initialOperator, address bankrollRegistry, uint256 initialRefundDelay) {
        if (initialOwner == address(0) || bankrollRegistry == address(0)) {
            revert ZeroAddress();
        }

        owner = initialOwner;
        registry = IBankrollRegistry(bankrollRegistry);
        bankrollReservationsEnabled = true;
        if (initialRefundDelay < MIN_REFUND_DELAY) revert RefundDelayTooShort();
        refundDelay = initialRefundDelay;

        emit OwnershipTransferred(address(0), initialOwner);
        emit RegistryUpdated(bankrollRegistry);
        emit RefundDelayUpdated(initialRefundDelay);

        if (initialOperator != address(0)) {
            isOperator[initialOperator] = true;
            emit OperatorUpdated(initialOperator, true);
        }
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setAdmin(address admin, bool allowed) external onlyOwner {
        if (admin == address(0)) revert ZeroAddress();
        isAdmin[admin] = allowed;
        emit AdminUpdated(admin, allowed);
    }

    function setAdmins(address[] calldata admins, bool[] calldata allowed) external onlyOwner {
        uint256 length = admins.length;
        if (length == 0 || length != allowed.length) revert InvalidValue();
        for (uint256 i; i < length; ++i) {
            address admin = admins[i];
            if (admin == address(0)) revert ZeroAddress();
            isAdmin[admin] = allowed[i];
            emit AdminUpdated(admin, allowed[i]);
        }
    }

    function setOperator(address operator, bool allowed) external onlyAdmin {
        if (operator == address(0)) revert ZeroAddress();
        isOperator[operator] = allowed;
        emit OperatorUpdated(operator, allowed);
    }

    function setOperators(address[] calldata operators, bool[] calldata allowed) external onlyAdmin {
        uint256 length = operators.length;
        if (length == 0 || length != allowed.length) revert InvalidValue();
        for (uint256 i; i < length; ++i) {
            address operator = operators[i];
            if (operator == address(0)) revert ZeroAddress();
            isOperator[operator] = allowed[i];
            emit OperatorUpdated(operator, allowed[i]);
        }
    }

    function setRegistry(address bankrollRegistry) external onlyAdmin {
        if (bankrollRegistry == address(0)) revert ZeroAddress();
        registry = IBankrollRegistry(bankrollRegistry);
        emit RegistryUpdated(bankrollRegistry);
    }

    /// @dev Retained for storage and ABI compatibility; this delay no longer authorizes player cancellation.
    function setRefundDelay(uint256 newRefundDelay) external onlyAdmin {
        if (newRefundDelay < MIN_REFUND_DELAY) revert RefundDelayTooShort();
        refundDelay = newRefundDelay;
        emit RefundDelayUpdated(newRefundDelay);
    }

    function setPaused(bool shouldPause) external onlyAdmin {
        if (paused == shouldPause) {
            if (shouldPause) revert AlreadyPaused();
            return;
        }
        paused = shouldPause;
        emit PauseUpdated(shouldPause, msg.sender);
    }

    function setBankrollReservationsEnabled(bool enabled) external onlyAdmin {
        bankrollReservationsEnabled = enabled;
        emit BankrollReservationsEnabledUpdated(enabled, msg.sender);
    }

    /// @notice Reserves ERC-20-funded rounds submitted by an authorized operator for explicit players.
    /// @dev Players and reservations are aligned one-to-one. Each player must approve this ledger
    ///      for the corresponding reservation amount.
    function reserveBatchFor(address token, address[] calldata players, Reservation[] calldata reservations)
        external
        onlyOperator
        nonReentrant
        whenNotPaused
    {
        uint256 count = reservations.length;
        if (count == 0 || players.length != count) revert BatchLengthMismatch();
        if (token == address(0)) revert NativeValueNotAllowed();

        address bankroll = _currentBankroll(token);
        uint256 totalReservation;
        uint256 totalBankrollReservation;

        for (uint256 i; i < count;) {
            address player = players[i];
            if (player == address(0)) revert ZeroAddress();

            uint256 reservationAmount = _recordReservation(player, token, bankroll, reservations[i]);
            IERC20(token).safeTransferFrom(player, address(this), reservationAmount);
            totalReservation += reservationAmount;
            totalBankrollReservation += roundBankrollReservationAmount[reservations[i].roundKey];

            unchecked {
                ++i;
            }
        }

        IERC20(token).safeApprove(bankroll, 0);
        IERC20(token).safeApprove(bankroll, totalReservation);
        IBankLP(bankroll).deposit(token, totalReservation);
        if (totalBankrollReservation != 0) {
            IBankLP(bankroll).reserveFunds(token, totalBankrollReservation);
        }
    }

    function _currentBankroll(address token) private view returns (address bankroll) {
        (bankroll,,,) = registry.getCurrentBankroll();
        if (bankroll == address(0)) revert ZeroAddress();
        if (!IBankLP(bankroll).getIsValidWager(address(this), token)) {
            revert TokenNotAllowed();
        }
    }

    function _recordReservation(address player, address token, address bankroll, Reservation calldata item)
        private
        returns (uint256 reservationAmount)
    {
        if (item.gameId == bytes32(0) || item.actionKey == bytes32(0) || item.roundKey == bytes32(0)) {
            revert ZeroKey();
        }
        if (item.amount == 0) revert ReservationTooSmall();
        if (item.maxPayout < item.amount) revert PayoutLimitExceeded();
        if (actionUsed[item.actionKey]) {
            revert DuplicateAction(item.actionKey);
        }
        if (_rounds[item.roundKey].status != RoundStatus.None) {
            revert RoundAlreadyExists(item.roundKey);
        }

        uint256 riskReservation = item.maxPayout;

        actionUsed[item.actionKey] = true;
        Round storage round = _rounds[item.roundKey];
        round.status = RoundStatus.Reserved;
        round.gameId = item.gameId;
        round.player = player;
        round.token = token;
        round.bankroll = bankroll;
        round.reservedAt = uint64(block.timestamp);
        round.refundAt = block.timestamp + refundDelay;
        round.reservation = item.amount;
        round.bankrollReservation = riskReservation;
        roundBankrollReservationAmount[item.roundKey] = bankrollReservationsEnabled ? riskReservation : 0;

        emit RoundReserved(
            item.actionKey, item.roundKey, item.gameId, player, token, bankroll, item.amount, riskReservation
        );
        return item.amount;
    }

    /// @notice Binds reserved rounds to replay-protected settlement actions without disclosing outcomes.
    /// @dev Each round can only be initiated once. The expiry bounds the initiation window but does not
    ///      invalidate the bound settlement action or allow a player-triggered refund.
    function initiateSettlementBatch(bytes32 actionKey, SettlementInitiation[] calldata initiations, uint256 expiresAt)
        external
        onlyOperator
    {
        if (actionKey == bytes32(0)) revert ZeroKey();
        if (actionUsed[actionKey]) revert DuplicateAction(actionKey);
        uint256 duration = expiresAt > block.timestamp ? expiresAt - block.timestamp : 0;
        if (duration < MIN_SETTLEMENT_LOCK_DURATION || duration > MAX_SETTLEMENT_LOCK_DURATION) {
            revert SettlementLockInvalidExpiry();
        }
        uint256 count = initiations.length;
        if (count == 0) revert BatchLengthMismatch();

        actionUsed[actionKey] = true;
        for (uint256 i; i < count;) {
            SettlementInitiation calldata initiation = initiations[i];
            if (initiation.roundKey == bytes32(0) || initiation.settlementActionKey == bytes32(0)) revert ZeroKey();
            if (actionUsed[initiation.settlementActionKey]) {
                revert DuplicateAction(initiation.settlementActionKey);
            }
            Round storage round = _rounds[initiation.roundKey];
            if (round.status != RoundStatus.Reserved) {
                revert InvalidRoundStatus(initiation.roundKey, round.status);
            }
            if (round.settlementLockActionKey != bytes32(0)) {
                revert SettlementAlreadyInitiated(initiation.roundKey);
            }
            round.settlementLockActionKey = actionKey;
            round.lockedSettlementActionKey = initiation.settlementActionKey;
            round.settlementLockExpiresAt = expiresAt;
            emit SettlementInitiated(actionKey, initiation.roundKey, initiation.settlementActionKey, expiresAt);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Atomically records final outcomes after a confirmed, outcome-free settlement initiation.
    function settleBatch(Settlement[] calldata settlements) external nonReentrant onlyOperator {
        uint256 count = settlements.length;
        if (count == 0) revert BatchLengthMismatch();

        for (uint256 i; i < count;) {
            Settlement calldata settlement = settlements[i];
            if (settlement.actionKey == bytes32(0) || settlement.roundKey == bytes32(0)) revert ZeroKey();
            if (actionUsed[settlement.actionKey]) {
                revert DuplicateAction(settlement.actionKey);
            }
            if (!settlement.finalClose) revert InvalidFinalClose();

            Round storage round = _rounds[settlement.roundKey];
            if (round.status != RoundStatus.Reserved) {
                revert InvalidRoundStatus(settlement.roundKey, round.status);
            }
            if (round.settlementLockActionKey == bytes32(0)) {
                revert SettlementNotInitiated(settlement.roundKey);
            }
            if (round.lockedSettlementActionKey != settlement.actionKey) {
                revert SettlementActionMismatch(settlement.roundKey);
            }
            if (settlement.actualWager > round.reservation) {
                revert WagerExceedsReservation();
            }

            uint256 unusedReservation = round.reservation - settlement.actualWager;
            if (settlement.grossPlayerReturn < unusedReservation) {
                revert UnusedReservationNotReturned();
            }

            if (settlement.grossPlayerReturn > round.bankrollReservation) {
                revert PayoutLimitExceeded();
            }

            actionUsed[settlement.actionKey] = true;
            round.status = RoundStatus.Closed;
            round.closedAt = uint64(block.timestamp);
            round.actualWager = settlement.actualWager;
            round.grossPlayerReturn = settlement.grossPlayerReturn;

            _payoutAndRelease(
                round.player,
                round.bankroll,
                round.token,
                settlement.grossPlayerReturn,
                roundBankrollReservationAmount[settlement.roundKey]
            );

            emit RoundClosed(
                settlement.actionKey,
                settlement.roundKey,
                round.player,
                settlement.actualWager,
                settlement.grossPlayerReturn
            );

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Cancels and refunds a reservation after the operator determines settlement cannot complete.
    function cancelRound(bytes32 actionKey, bytes32 roundKey) external nonReentrant onlyOperator {
        if (actionKey == bytes32(0) || roundKey == bytes32(0)) {
            revert ZeroKey();
        }
        if (actionUsed[actionKey]) revert DuplicateAction(actionKey);

        Round storage round = _rounds[roundKey];
        if (round.status != RoundStatus.Reserved) {
            revert InvalidRoundStatus(roundKey, round.status);
        }

        actionUsed[actionKey] = true;
        round.status = RoundStatus.Cancelled;
        round.closedAt = uint64(block.timestamp);
        round.actualWager = 0;
        round.grossPlayerReturn = round.reservation;

        _payoutAndRelease(
            round.player, round.bankroll, round.token, round.reservation, roundBankrollReservationAmount[roundKey]
        );

        emit RoundCancelled(actionKey, roundKey, round.player, round.reservation);
    }

    function claimPending(address bankroll, address token) external nonReentrant {
        PendingPayout storage pending = pendingPayouts[msg.sender][bankroll][token];
        uint256 amount = pending.amount;
        if (amount == 0) revert NoPendingPayout();

        pending.amount = 0;
        uint256 reservedAmount = pending.reservedAmount;
        pending.reservedAmount = 0;
        totalPendingPayouts[bankroll][token] -= amount;

        IBankLP(bankroll).transferPayout(msg.sender, amount, token);
        if (reservedAmount != 0) {
            IBankLP(bankroll).releaseFunds(token, reservedAmount);
        }

        emit PendingPayoutClaimed(msg.sender, bankroll, token, amount);
    }

    function getRound(bytes32 roundKey) external view returns (Round memory) {
        return _rounds[roundKey];
    }

    function getRoundStatus(bytes32 roundKey) external view returns (RoundStatus) {
        return _rounds[roundKey].status;
    }

    /// @dev Returns legacy metadata only; cancellation always requires an operator.
    function refundAvailableAt(bytes32 roundKey) external view returns (uint256) {
        Round storage round = _rounds[roundKey];
        if (round.status == RoundStatus.None) return 0;
        return round.refundAt;
    }

    function _payoutAndRelease(address player, address bankroll, address token, uint256 payout, uint256 reservedAmount)
        private
    {
        if (payout == 0) {
            if (reservedAmount != 0) {
                IBankLP(bankroll).releaseFunds(token, reservedAmount);
            }
            return;
        }

        try IBankLP(bankroll).transferPayout(player, payout, token) {
            if (reservedAmount != 0) {
                IBankLP(bankroll).releaseFunds(token, reservedAmount);
            }
        } catch {
            pendingPayouts[player][bankroll][token].amount += payout;
            uint256 retainedReservation = reservedAmount < payout ? reservedAmount : payout;
            pendingPayouts[player][bankroll][token].reservedAmount += retainedReservation;
            totalPendingPayouts[bankroll][token] += payout;
            uint256 releasable = reservedAmount - retainedReservation;
            if (releasable != 0) {
                IBankLP(bankroll).releaseFunds(token, releasable);
            }
            emit PendingPayoutRecorded(player, bankroll, token, payout);
        }
    }
}
