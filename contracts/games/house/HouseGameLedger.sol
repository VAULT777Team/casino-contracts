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

    uint256 public constant PROTOCOL_VERSION = 2;
    bytes32 public constant SETTLEMENT_ACTION_DOMAIN = keccak256("vault777.house-game.settlement.v2");
    uint256 public constant MIN_REFUND_DELAY = 5 minutes;

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

    struct RoundData {
        bytes32 gameId;
        address player;
        uint64 reservedAt;
        RoundStatus status;
        address token;
        address bankroll;
        uint64 closedAt;
        uint128 reservation;
        uint128 bankrollReservation;
        uint128 actualWager;
        uint128 grossPlayerReturn;
    }

    struct PendingPayout {
        uint256 amount;
        uint256 reservedAmount;
    }

    struct SettlementScope {
        address bankroll;
        address token;
        uint256 depositAmount;
        uint256 reservedAmount;
        uint256 retainedAmount;
    }

    struct SettlementAccount {
        address player;
        address bankroll;
        address token;
        uint256 refundAmount;
        uint256 payoutAmount;
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
    mapping(bytes32 => RoundData) private _rounds;
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
    event BankrollAllowanceRevoked(address indexed bankroll, address indexed token, address indexed caller);
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

    function revokeBankrollAllowance(address bankroll, address token) external onlyAdmin {
        if (bankroll == address(0) || token == address(0)) revert ZeroAddress();
        IERC20(token).forceApprove(bankroll, 0);
        emit BankrollAllowanceRevoked(bankroll, token, msg.sender);
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
        uint256 totalBankrollReservation;

        for (uint256 i; i < count;) {
            address player = players[i];
            if (player == address(0)) revert ZeroAddress();

            uint256 reservationAmount = _recordReservation(player, token, bankroll, reservations[i]);
            IERC20(token).safeTransferFrom(player, address(this), reservationAmount);
            totalBankrollReservation += roundBankrollReservationAmount[reservations[i].roundKey];

            unchecked {
                ++i;
            }
        }

        if (totalBankrollReservation != 0) {
            IBankLP(bankroll).reserveFunds(token, totalBankrollReservation);
        }
    }

    function settlementActionKey(bytes32 roundKey) public pure returns (bytes32) {
        if (roundKey == bytes32(0)) revert ZeroKey();
        return keccak256(abi.encode(SETTLEMENT_ACTION_DOMAIN, roundKey));
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
        if (item.amount > type(uint128).max || item.maxPayout > type(uint128).max) revert InvalidValue();
        if (actionUsed[item.actionKey]) {
            revert DuplicateAction(item.actionKey);
        }
        if (_rounds[item.roundKey].status != RoundStatus.None) {
            revert RoundAlreadyExists(item.roundKey);
        }

        uint256 riskReservation = item.maxPayout;

        actionUsed[item.actionKey] = true;
        RoundData storage round = _rounds[item.roundKey];
        round.status = RoundStatus.Reserved;
        round.gameId = item.gameId;
        round.player = player;
        round.token = token;
        round.bankroll = bankroll;
        round.reservedAt = uint64(block.timestamp);
        round.reservation = uint128(item.amount);
        round.bankrollReservation = uint128(riskReservation);
        roundBankrollReservationAmount[item.roundKey] =
            bankrollReservationsEnabled ? riskReservation : 0;

        emit RoundReserved(
            item.actionKey, item.roundKey, item.gameId, player, token, bankroll, item.amount, riskReservation
        );
        return item.amount;
    }

    /// @notice Atomically records final outcomes using deterministic settlement keys.
    function settleBatch(Settlement[] calldata settlements) external nonReentrant onlyOperator {
        uint256 count = settlements.length;
        if (count == 0) revert BatchLengthMismatch();

        SettlementScope[] memory scopes = new SettlementScope[](count);
        SettlementAccount[] memory accounts = new SettlementAccount[](count);
        uint256 scopeCount;
        uint256 accountCount;

        for (uint256 i; i < count;) {
            Settlement calldata settlement = settlements[i];
            if (settlement.actionKey == bytes32(0) || settlement.roundKey == bytes32(0)) revert ZeroKey();
            if (!settlement.finalClose) revert InvalidFinalClose();

            RoundData storage round = _rounds[settlement.roundKey];
            if (round.status != RoundStatus.Reserved) {
                revert InvalidRoundStatus(settlement.roundKey, round.status);
            }
            bytes32 expectedActionKey = settlementActionKey(settlement.roundKey);
            if (settlement.actionKey != expectedActionKey) {
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

            round.status = RoundStatus.Closed;
            round.closedAt = uint64(block.timestamp);
            round.actualWager = uint128(settlement.actualWager);
            round.grossPlayerReturn = uint128(settlement.grossPlayerReturn);

            uint256 reservedAmount = roundBankrollReservationAmount[settlement.roundKey];
            scopeCount = _addSettlementScope(
                scopes,
                scopeCount,
                round.bankroll,
                round.token,
                settlement.actualWager,
                reservedAmount
            );
            accountCount = _addSettlementAccount(
                accounts,
                accountCount,
                round.player,
                round.bankroll,
                round.token,
                unusedReservation,
                settlement.grossPlayerReturn - unusedReservation,
                reservedAmount
            );

            unchecked {
                ++i;
            }
        }

        for (uint256 i; i < scopeCount;) {
            SettlementScope memory scope = scopes[i];
            uint256 amount = scope.depositAmount;
            if (amount != 0) {
                IERC20 token = IERC20(scope.token);
                if (token.allowance(address(this), scope.bankroll) < amount) {
                    token.forceApprove(scope.bankroll, type(uint256).max);
                }
                IBankLP(scope.bankroll).deposit(scope.token, amount);
            }
            unchecked {
                ++i;
            }
        }

        for (uint256 i; i < accountCount;) {
            SettlementAccount memory account = accounts[i];
            if (account.refundAmount != 0) {
                IERC20(account.token).safeTransfer(account.player, account.refundAmount);
            }
            if (account.payoutAmount != 0) {
                try IBankLP(account.bankroll).transferPayout(account.player, account.payoutAmount, account.token) {}
                catch {
                    pendingPayouts[account.player][account.bankroll][account.token].amount += account.payoutAmount;
                    uint256 retainedAmount =
                        account.reservedAmount < account.payoutAmount ? account.reservedAmount : account.payoutAmount;
                    pendingPayouts[account.player][account.bankroll][account.token].reservedAmount += retainedAmount;
                    totalPendingPayouts[account.bankroll][account.token] += account.payoutAmount;
                    _retainSettlementScope(scopes, scopeCount, account.bankroll, account.token, retainedAmount);
                    emit PendingPayoutRecorded(
                        account.player, account.bankroll, account.token, account.payoutAmount
                    );
                }
            }
            unchecked {
                ++i;
            }
        }

        for (uint256 i; i < scopeCount;) {
            SettlementScope memory scope = scopes[i];
            uint256 releasable = scope.reservedAmount - scope.retainedAmount;
            if (releasable != 0) {
                IBankLP(scope.bankroll).releaseFunds(scope.token, releasable);
            }
            unchecked {
                ++i;
            }
        }

        for (uint256 i; i < count;) {
            Settlement calldata settlement = settlements[i];
            RoundData storage round = _rounds[settlement.roundKey];
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

    function _addSettlementScope(
        SettlementScope[] memory scopes,
        uint256 count,
        address bankroll,
        address token,
        uint256 depositAmount,
        uint256 reservedAmount
    ) private pure returns (uint256) {
        for (uint256 i; i < count;) {
            if (scopes[i].bankroll == bankroll && scopes[i].token == token) {
                scopes[i].depositAmount += depositAmount;
                scopes[i].reservedAmount += reservedAmount;
                return count;
            }
            unchecked {
                ++i;
            }
        }
        scopes[count] = SettlementScope(bankroll, token, depositAmount, reservedAmount, 0);
        return count + 1;
    }

    function _addSettlementAccount(
        SettlementAccount[] memory accounts,
        uint256 count,
        address player,
        address bankroll,
        address token,
        uint256 refundAmount,
        uint256 payoutAmount,
        uint256 reservedAmount
    ) private pure returns (uint256) {
        for (uint256 i; i < count;) {
            if (
                accounts[i].player == player && accounts[i].bankroll == bankroll && accounts[i].token == token
            ) {
                accounts[i].refundAmount += refundAmount;
                accounts[i].payoutAmount += payoutAmount;
                accounts[i].reservedAmount += reservedAmount;
                return count;
            }
            unchecked {
                ++i;
            }
        }
        accounts[count] =
            SettlementAccount(player, bankroll, token, refundAmount, payoutAmount, reservedAmount);
        return count + 1;
    }

    function _retainSettlementScope(
        SettlementScope[] memory scopes,
        uint256 count,
        address bankroll,
        address token,
        uint256 retainedAmount
    ) private pure {
        for (uint256 i; i < count;) {
            if (scopes[i].bankroll == bankroll && scopes[i].token == token) {
                scopes[i].retainedAmount += retainedAmount;
                return;
            }
            unchecked {
                ++i;
            }
        }
        revert InvalidValue();
    }

    /// @notice Cancels and refunds a reservation after the operator determines settlement cannot complete.
    function cancelRound(bytes32 actionKey, bytes32 roundKey) external nonReentrant onlyOperator {
        if (actionKey == bytes32(0) || roundKey == bytes32(0)) {
            revert ZeroKey();
        }
        if (actionUsed[actionKey]) revert DuplicateAction(actionKey);

        RoundData storage round = _rounds[roundKey];
        if (round.status != RoundStatus.Reserved) {
            revert InvalidRoundStatus(roundKey, round.status);
        }

        actionUsed[actionKey] = true;
        round.status = RoundStatus.Cancelled;
        round.closedAt = uint64(block.timestamp);
        round.actualWager = 0;
        round.grossPlayerReturn = round.reservation;

        IERC20(round.token).safeTransfer(round.player, round.reservation);
        uint256 reservedAmount = roundBankrollReservationAmount[roundKey];
        if (reservedAmount != 0) {
            IBankLP(round.bankroll).releaseFunds(round.token, reservedAmount);
        }

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
        RoundData storage round = _rounds[roundKey];
        return Round({
            status: round.status,
            gameId: round.gameId,
            player: round.player,
            token: round.token,
            bankroll: round.bankroll,
            reservedAt: round.reservedAt,
            closedAt: round.closedAt,
            refundAt: round.status == RoundStatus.None ? 0 : uint256(round.reservedAt) + refundDelay,
            reservation: round.reservation,
            bankrollReservation: round.bankrollReservation,
            actualWager: round.actualWager,
            grossPlayerReturn: round.grossPlayerReturn,
            settlementLockActionKey: bytes32(0),
            lockedSettlementActionKey: bytes32(0),
            settlementLockExpiresAt: 0
        });
    }

    function getRoundStatus(bytes32 roundKey) external view returns (RoundStatus) {
        return _rounds[roundKey].status;
    }

    /// @dev Returns legacy metadata only; cancellation always requires an operator.
    function refundAvailableAt(bytes32 roundKey) external view returns (uint256) {
        RoundData storage round = _rounds[roundKey];
        if (round.status == RoundStatus.None) return 0;
        return uint256(round.reservedAt) + refundDelay;
    }

}
