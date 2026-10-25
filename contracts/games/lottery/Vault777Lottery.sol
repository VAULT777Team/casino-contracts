// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract Vault777Lottery is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint16 public constant MAX_HOUSE_BPS = 2000;
    uint256 public constant MAX_TICKETS_PER_TX = 100;

    uint128 private constant MAIN_VALID_MASK = (uint128(1) << 75) - 2;
    uint32 private constant PB_VALID_MASK = (uint32(1) << 19) - 2;

    IERC20 public immutable token;
    address public houseRecipient;

    struct Ticket {
        uint128 mainMask;
        uint32 pbMask;
    }

    struct Round {
        uint64 closesAt;
        uint16 houseBps;
        uint8 powerPbCount;
        bool finalized;
        uint128 standardPrice;
        uint128 powerPrice;
        uint256 sales;
        uint256 balance;
        uint256 ticketCount;
    }

    mapping(uint256 => Round) public rounds;
    mapping(uint256 => mapping(address => bool)) public paid;

    error ZeroAddress();
    error InvalidRoundId();
    error RoundAlreadyExists(uint256 roundId);
    error RoundDoesNotExist(uint256 roundId);
    error InvalidCloseTime();
    error InvalidPrice();
    error InvalidPowerPbCount(uint8 count);
    error HouseBpsTooHigh(uint16 houseBps);
    error RoundClosed(uint256 roundId);
    error RoundAlreadyFinalized(uint256 roundId);
    error InvalidTicketCount(uint256 count);
    error InvalidMainMask(uint128 mainMask);
    error InvalidMainNumberCount(uint256 count);
    error InvalidPowerballMask(uint32 pbMask);
    error InvalidPowerballCount(uint256 count);
    error InvalidRecipientsAndAmountsLength();
    error AlreadyPaid(address recipient);
    error InsufficientRoundBalance(uint256 available, uint256 requested);
    error FeeExceedsCap(uint256 fee, uint256 cap);
    error InvalidNextRound(uint256 nextRoundId);
    error RoundNotClosed(uint256 roundId);
    error RoundIsFinalized(uint256 roundId);

    event RoundCreated(
        uint256 indexed roundId,
        uint64 closesAt,
        uint128 standardPrice,
        uint128 powerPrice,
        uint8 powerPbCount,
        uint16 houseBps
    );
    event TicketPurchased(
        uint256 indexed roundId,
        address indexed buyer,
        uint256 indexed ticketIndex,
        uint128 mainMask,
        uint32 pbMask,
        uint256 price
    );
    event RoundSeeded(uint256 indexed roundId, address indexed from, uint256 amount);
    event WinnerPaid(uint256 indexed roundId, address indexed recipient, uint256 amount);
    event RoundFinalized(uint256 indexed roundId, uint256 houseFee, uint256 indexed nextRoundId, uint256 rollover);
    event RoundClosedOut(uint256 indexed roundId, uint256 amount);
    event HouseRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);

    constructor(IERC20 token_, address admin, address operator, address houseRecipient_) {
        if (address(token_) == address(0) || admin == address(0) || operator == address(0) || houseRecipient_ == address(0)) {
            revert ZeroAddress();
        }

        token = token_;
        houseRecipient = houseRecipient_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, operator);
    }

    function createRound(
        uint256 roundId,
        uint64 closesAt,
        uint128 standardPrice,
        uint128 powerPrice,
        uint8 powerPbCount,
        uint16 houseBps
    ) external onlyRole(OPERATOR_ROLE) {
        if (roundId == 0) revert InvalidRoundId();
        if (rounds[roundId].closesAt != 0) revert RoundAlreadyExists(roundId);
        if (closesAt <= block.timestamp) revert InvalidCloseTime();
        if (standardPrice == 0 || powerPrice == 0) revert InvalidPrice();
        if (powerPbCount < 2 || powerPbCount > 18) revert InvalidPowerPbCount(powerPbCount);
        if (houseBps > MAX_HOUSE_BPS) revert HouseBpsTooHigh(houseBps);

        rounds[roundId] = Round({
            closesAt: closesAt,
            houseBps: houseBps,
            powerPbCount: powerPbCount,
            finalized: false,
            standardPrice: standardPrice,
            powerPrice: powerPrice,
            sales: 0,
            balance: 0,
            ticketCount: 0
        });

        emit RoundCreated(roundId, closesAt, standardPrice, powerPrice, powerPbCount, houseBps);
    }

    function buyTickets(uint256 roundId, Ticket[] calldata tickets) external whenNotPaused nonReentrant {
        Round storage round = rounds[roundId];
        _requireRoundExists(roundId, round);
        if (block.timestamp >= round.closesAt) revert RoundClosed(roundId);
        if (tickets.length == 0 || tickets.length > MAX_TICKETS_PER_TX) {
            revert InvalidTicketCount(tickets.length);
        }

        uint256 totalPrice;
        uint256 firstTicketIndex = round.ticketCount;
        for (uint256 i; i < tickets.length; ++i) {
            uint256 price = _ticketPrice(tickets[i], round);
            totalPrice += price;
        }

        token.safeTransferFrom(msg.sender, address(this), totalPrice);
        round.sales += totalPrice;
        round.balance += totalPrice;

        for (uint256 i; i < tickets.length; ++i) {
            Ticket calldata ticket = tickets[i];
            uint256 price = _ticketPrice(tickets[i], round);
            emit TicketPurchased(roundId, msg.sender, firstTicketIndex + i, ticket.mainMask, ticket.pbMask, price);
        }
        round.ticketCount += tickets.length;
    }

    function seedRound(uint256 roundId, uint256 amount) external nonReentrant {
        Round storage round = rounds[roundId];
        _requireRoundExists(roundId, round);
        if (round.finalized) revert RoundAlreadyFinalized(roundId);
        if (amount == 0) revert InvalidPrice();

        token.safeTransferFrom(msg.sender, address(this), amount);
        round.balance += amount;
        emit RoundSeeded(roundId, msg.sender, amount);
    }

    function payWinners(uint256 roundId, address[] calldata recipients, uint256[] calldata amounts)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
    {
        Round storage round = rounds[roundId];
        _requireRoundExists(roundId, round);
        if (block.timestamp < round.closesAt) revert RoundNotClosed(roundId);
        if (round.finalized) revert RoundAlreadyFinalized(roundId);
        if (recipients.length != amounts.length) revert InvalidRecipientsAndAmountsLength();

        for (uint256 i; i < recipients.length; ++i) {
            address recipient = recipients[i];
            uint256 amount = amounts[i];
            if (recipient == address(0)) revert ZeroAddress();
            if (amount == 0) revert InvalidPrice();
            if (paid[roundId][recipient]) revert AlreadyPaid(recipient);
            if (amount > round.balance) revert InsufficientRoundBalance(round.balance, amount);

            paid[roundId][recipient] = true;
            round.balance -= amount;
            token.safeTransfer(recipient, amount);
            emit WinnerPaid(roundId, recipient, amount);
        }
    }

    function finalizeRound(uint256 roundId, uint256 houseFee, uint256 nextRoundId)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
    {
        Round storage round = rounds[roundId];
        _requireRoundExists(roundId, round);
        if (block.timestamp < round.closesAt) revert RoundNotClosed(roundId);
        if (round.finalized) revert RoundAlreadyFinalized(roundId);

        uint256 feeCap = Math.mulDiv(round.sales, round.houseBps, 10_000);
        if (houseFee > feeCap) revert FeeExceedsCap(houseFee, feeCap);
        if (houseFee > round.balance) revert InsufficientRoundBalance(round.balance, houseFee);

        Round storage nextRound = rounds[nextRoundId];
        _requireRoundExists(nextRoundId, nextRound);
        if (nextRoundId == roundId || nextRound.finalized || nextRound.closesAt <= block.timestamp) {
            revert InvalidNextRound(nextRoundId);
        }

        uint256 rollover = round.balance - houseFee;
        round.balance = 0;
        round.finalized = true;
        nextRound.balance += rollover;

        if (houseFee != 0) token.safeTransfer(houseRecipient, houseFee);
        emit RoundFinalized(roundId, houseFee, nextRoundId, rollover);
    }

    function closeOutRound(uint256 roundId) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        Round storage round = rounds[roundId];
        _requireRoundExists(roundId, round);
        if (block.timestamp < round.closesAt) revert RoundNotClosed(roundId);
        if (round.finalized) revert RoundAlreadyFinalized(roundId);

        uint256 amount = round.balance;
        round.balance = 0;
        round.finalized = true;
        if (amount != 0) token.safeTransfer(houseRecipient, amount);
        emit RoundClosedOut(roundId, amount);
    }

    function setHouseRecipient(address newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRecipient == address(0)) revert ZeroAddress();
        address previousRecipient = houseRecipient;
        houseRecipient = newRecipient;
        emit HouseRecipientUpdated(previousRecipient, newRecipient);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _ticketPrice(Ticket calldata ticket, Round storage round) private view returns (uint256) {
        if (ticket.mainMask & ~MAIN_VALID_MASK != 0) revert InvalidMainMask(ticket.mainMask);
        uint256 mainCount = _popcount(ticket.mainMask);
        if (mainCount != 5) revert InvalidMainNumberCount(mainCount);

        if (ticket.pbMask & ~PB_VALID_MASK != 0) revert InvalidPowerballMask(ticket.pbMask);
        uint256 powerballCount = _popcount32(ticket.pbMask);
        if (powerballCount == 1) return round.standardPrice;
        if (powerballCount == round.powerPbCount) return round.powerPrice;
        revert InvalidPowerballCount(powerballCount);
    }

    function _popcount(uint128 value) private pure returns (uint256 count) {
        while (value != 0) {
            value &= value - 1;
            ++count;
        }
    }

    function _popcount32(uint32 value) private pure returns (uint256 count) {
        while (value != 0) {
            value &= value - 1;
            ++count;
        }
    }

    function _requireRoundExists(uint256 roundId, Round storage round) private view {
        if (round.closesAt == 0) revert RoundDoesNotExist(roundId);
    }
}
