// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title OCG Game Ledger
/// @author @FuegoLabz
/// @notice On-chain round based betting ledger used by OCG games
/// @custom:security-contact security@fuegolabz.io
/// @dev Supports batched bets and settlements with replay protected action keys.
///      The contract does not validate game logic, results are trusted from the operator.
///      Failed payouts are credited to pending withdrawals to prevent blocking execution.
///
/// @dev Trust model:
///      The contract is a last barrier. The backend (operator) is the primary trust
///      anchor and validates game logic before submitting. Transactions are initiated
///      via session keys on behalf of users; a user intercepting and modifying a tx
///      breaks the session signer authorization at the transport level. The contract
///      confirms only that an operator signed off on the sender + total value.

abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;

    modifier nonReentrant() {
        require(_status != _ENTERED, "REENTRANCY");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

interface IRegistry {
    function getCurrentBankroll() external view returns (
        address bankroll,
        address treasury,
        string memory version,
        uint256 activatedAt
    );
}

interface IBankLP {
    function depositEther() external payable;
    function transferPayout(address player, uint256 amount, address token) external;
}

contract OCGgameLedgerV2 is ReentrancyGuard {
    /// @notice Contract owner
    address public owner;

    /// @notice Registry address used for withdrawals of excess bankroll
    address public registry;

    // @notice Baankroll address for liquidity management and treasury sweeps
    address public bankroll;

    /// @notice Global pause flag
    bool public paused;

    /// @notice Maximum payout multiplier relative to stake (e.g. 100x)
    uint256 public maxPayoutMultiplierX = 100;

    /// @notice Time window (seconds) during which a round can be canceled
    uint256 public cancelTimeframe = 600;

    /// @notice Total amount owed to players via pending withdrawals
    /// @dev Prevents sweeping funds reserved for pending player payouts
    uint256 public totalPendingWithdrawals;

    /// @notice Minimal round state.
    /// @dev player:     non-zero means round exists; payout recipient
    /// @dev totalStake: sum of all bets; used for cancel refund and payout cap
    /// @dev openedAt:   locked at first bet; used for cancel timeframe check
    /// @dev closedAt:   non-zero means at least one settlement has occurred;
    ///                  used by cancel() to block refund after any payout
    struct Round {
        address player;
        uint256 totalStake;
        uint256 openedAt;
        uint256 closedAt;
    }

    /// @notice Round storage indexed by round key
    mapping(bytes32 => Round) public rounds;

    /// @notice Prevents replay of bet and settlement action keys
    mapping(bytes32 => bool) public actionUsed;

    /// @notice Authorized operators to settle / bet signers
    mapping(address => bool) public isOperator;

    /// @notice Admin addresses with limited governance permissions
    mapping(address => bool) public isAdmin;

    /// @notice Self-exclusion expiration timestamps
    mapping(address => uint256) public selfExcludedUntil;

    /// @notice Failed player payouts claimable via withdrawPending()
    mapping(address => uint256) public pendingWithdrawals;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event BetPlaced(
        bytes32 indexed actionKey,
        bytes32 indexed roundKey,
        address indexed player,
        uint256 stake
    );
    event BetSettled(
        bytes32 indexed actionKey,
        bytes32 indexed roundKey,
        address indexed player,
        uint256 payout
    );
    event RoundCanceled(
        bytes32 indexed roundKey,
        address indexed player,
        uint256 refund
    );
    event PendingPayoutRecorded(address indexed player, uint256 amount);
    event PendingWithdrawalClaimed(address indexed player, uint256 amount);
    event OperatorUpdated(address indexed operator, bool allowed);
    event AdminUpdated(address indexed admin, bool allowed);
    event RegistryUpdated(address indexed registry);
    event BankrollDeposited(address indexed from, uint256 amount);
    event TreasurySwept(uint256 amount);
    event EmergencyWithdraw(uint256 amount);
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );
    event MaxPayoutMultiplierUpdated(uint256 newMultiplierX);
    event CancelTimeframeUpdated(uint256 newTimeframe);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event SelfExcluded(address indexed player, uint256 until);

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    modifier onlyOperator() {
        require(isOperator[msg.sender], "NOT_OPERATOR");
        _;
    }

    modifier onlyOwnerOrAdmin() {
        require(msg.sender == owner || isAdmin[msg.sender], "NOT_AUTHORIZED");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "PAUSED");
        _;
    }

    modifier notSelfExcluded() {
        require(
            block.timestamp >= selfExcludedUntil[msg.sender],
            "SELF_EXCLUDED"
        );
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address _operator, address _registry) {
        require(_registry != address(0), "ZERO_REGISTRY");
    
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);

        registry = _registry;
        (address _bankroll, , , ) = IRegistry(_registry).getCurrentBankroll();
        require(_bankroll != address(0), "ZERO_BANKROLL");
        bankroll = _bankroll;

        emit RegistryUpdated(_registry);

        if (_operator != address(0)) {
            isOperator[_operator] = true;
            emit OperatorUpdated(_operator, true);
        }
    }

    // -------------------------------------------------------------------------
    // Ownership & Access Control
    // -------------------------------------------------------------------------

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "ZERO_OWNER");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setOperator(address operator) external onlyOwner {
        require(operator != address(0), "ZERO_OPERATOR");
        isOperator[operator] = true;
        emit OperatorUpdated(operator, true);
    }

    function removeOperator(address operator) external onlyOwner {
        isOperator[operator] = false;
        emit OperatorUpdated(operator, false);
    }

    function setAdmin(address admin) external onlyOwner {
        require(admin != address(0), "ZERO_ADMIN");
        isAdmin[admin] = true;
        emit AdminUpdated(admin, true);
    }

    function removeAdmin(address admin) external onlyOwner {
        isAdmin[admin] = false;
        emit AdminUpdated(admin, false);
    }

    function setRegistry(address _registry) external onlyOwnerOrAdmin {
        require(_registry != address(0), "ZERO_REGISTRY");
        registry = _registry;
        emit RegistryUpdated(_registry);
    }

    /// @notice Re-syncs bankroll address from the registry (call after a bankroll migration)
    function updateBankroll() external onlyOwnerOrAdmin {
        (address _bankroll, , , ) = IRegistry(registry).getCurrentBankroll();
        require(_bankroll != address(0), "ZERO_BANKROLL");
        bankroll = _bankroll;
    }

    function setMaxPayoutMultiplierX(
        uint256 newMultiplier
    ) external onlyOwnerOrAdmin {
        require(newMultiplier >= 1, "TOO_LOW");
        maxPayoutMultiplierX = newMultiplier;
        emit MaxPayoutMultiplierUpdated(newMultiplier);
    }

    function setCancelTimeframe(
        uint256 newTimeframe
    ) external onlyOwnerOrAdmin {
        cancelTimeframe = newTimeframe;
        emit CancelTimeframeUpdated(newTimeframe);
    }

    // -------------------------------------------------------------------------
    // Pause
    // -------------------------------------------------------------------------

    function pause() external {
        require(
            msg.sender == owner ||
                isOperator[msg.sender] ||
                isAdmin[msg.sender],
            "NOT_AUTHORIZED"
        );
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwnerOrAdmin {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // -------------------------------------------------------------------------
    // Player Actions
    // -------------------------------------------------------------------------

    /// @notice Self-exclude from betting for a duration, or permanently
    /// @param durationSeconds Duration in seconds.
    function selfExclude(uint256 durationSeconds) external {
        require(durationSeconds > 0, "INVALID_DURATION");

        uint256 until = block.timestamp + durationSeconds;

        require(until > selfExcludedUntil[msg.sender], "EXCLUSION_SHORTER");
        selfExcludedUntil[msg.sender] = until;
        emit SelfExcluded(msg.sender, until);
    }

    /// @notice Places one or more bets across one or multiple rounds
    /// @dev Signature scope is intentionally limited to (sender, totalValue, contract, validUntil)
    ///      Arrays are NOT included in signature to save ~30-50k gas per batch
    ///      Session-layer provides parameter integrity protection
    /// @param actionKeys  Unique identifiers for each betting action (replay protection)
    /// @param roundKeys   Identifiers of the rounds the bets belong to
    /// @param stakes      Stake amounts corresponding to each action
    /// @param validUntil  Timestamp after which the signature is rejected
    /// @param signature   Operator signature over (sender, totalValue, contract, validUntil)
    function betBatch(
        bytes32[] calldata actionKeys,
        bytes32[] calldata roundKeys,
        uint256[] calldata stakes,
        uint256 validUntil,
        bytes calldata signature
    ) external payable nonReentrant whenNotPaused notSelfExcluded {
        uint256 n = actionKeys.length;
        require(n > 0, "EMPTY");
        require(roundKeys.length == n && stakes.length == n, "LEN");

        uint256 totalValue;
        uint256 ts = block.timestamp;

        require(ts <= validUntil, "SIG_EXPIRED");

        for (uint256 i; i < n; ) {
            bytes32 actionKey = actionKeys[i];
            bytes32 roundKey = roundKeys[i];
            uint256 stake = stakes[i];

            require(stake > 0, "ZERO_STAKE");
            require(!actionUsed[actionKey], "DUP_ACTION");
            actionUsed[actionKey] = true;

            Round storage r = rounds[roundKey];

            if (r.player == address(0)) {
                r.player = msg.sender;
                r.openedAt = ts;
            } else {
                require(r.player == msg.sender, "PLAYER_MISMATCH");
            }

            r.totalStake += stake;
            totalValue += stake;

            emit BetPlaced(actionKey, roundKey, msg.sender, stake);


            unchecked {
                ++i;
            }
        }

        require(msg.value == totalValue, "BAD_VALUE");

        bytes32 digest = keccak256(
            abi.encode(msg.sender, totalValue, address(this), validUntil)
        );
        address signer = ECDSA.recover(
            ECDSA.toEthSignedMessageHash(digest),
            signature
        );
        require(isOperator[signer], "INVALID_SIGNATURE");

        // Forward stakes to BankLP liquidity pool
        IBankLP(bankroll).depositEther{value: totalValue}();
        emit BankrollDeposited(msg.sender, totalValue);
    }

    /// @notice Settles multiple bet actions across one or more rounds
    /// @dev A round may be settled more than once (multiple payouts per round are valid).
    ///      closedAt is set on first settlement and updated on subsequent ones — it signals
    ///      to cancel() that at least one payout has occurred, not that the round is sealed.
    ///      Payout cap is checked per-settlement against current global multiplier.
    /// @param actionKeys Unique identifiers for each settlement action
    /// @param roundKeys  Identifiers of the rounds being settled
    /// @param payouts    Payout amounts for each settlement
    function settleBatch(
        bytes32[] calldata actionKeys,
        bytes32[] calldata roundKeys,
        uint256[] calldata payouts
    ) external onlyOperator nonReentrant whenNotPaused {
        uint256 n = actionKeys.length;
        require(n > 0, "EMPTY");
        require(roundKeys.length == n && payouts.length == n, "LEN");

        uint256 totalBatchPayout;
        uint256 multiplierX = maxPayoutMultiplierX;
        uint256 ts = block.timestamp;
        address[] memory players = new address[](n);

        for (uint256 i; i < n; ) {
            bytes32 actionKey = actionKeys[i];
            bytes32 roundKey = roundKeys[i];
            uint256 payout = payouts[i];

            require(!actionUsed[actionKey], "DUP_ACTION");
            actionUsed[actionKey] = true;

            Round storage r = rounds[roundKey];
            require(r.player != address(0), "ROUND_NOT_FOUND");
            require(payout <= r.totalStake * multiplierX, "PAYOUT_LIMIT");

            r.closedAt = ts; // marks that at least one settlement occurred
            players[i] = r.player;
            totalBatchPayout += payout;

            emit BetSettled(actionKey, roundKey, r.player, payout);

            unchecked {
                ++i;
            }
        }

        if (totalBatchPayout > 0) {
            address _bankroll = bankroll;
            for (uint256 i; i < n; ) {
                uint256 payout = payouts[i];
                if (payout > 0) {
                    address player = players[i];
                    try IBankLP(_bankroll).transferPayout(player, payout, address(0)) {
                        // success
                    } catch {
                        pendingWithdrawals[player] += payout;
                        totalPendingWithdrawals += payout;
                        emit PendingPayoutRecorded(player, payout);
                    }
                }
                unchecked {
                    ++i;
                }
            }
        }
    }

    /// @notice Cancels a round and refunds the player stake
    /// @dev Blocked if any settlement has already occurred (closedAt != 0)
    ///      or if the cancel timeframe has elapsed.
    /// @param roundKey Identifier of the round to cancel
    function cancel(
        bytes32 roundKey
    ) external onlyOperator nonReentrant whenNotPaused {
        Round storage r = rounds[roundKey];

        require(r.player != address(0), "ROUND_NOT_FOUND");
        require(r.closedAt == 0, "ALREADY_SETTLED");
        require(
            block.timestamp <= r.openedAt + cancelTimeframe,
            "TIMEFRAME_EXCEEDED"
        );

        uint256 refund = r.totalStake;
        address player = r.player;

        r.closedAt = block.timestamp;

        try IBankLP(bankroll).transferPayout(player, refund, address(0)) {
            // success
        } catch {
            pendingWithdrawals[player] += refund;
            totalPendingWithdrawals += refund;
            emit PendingPayoutRecorded(player, refund);
        }

        emit RoundCanceled(roundKey, player, refund);
    }

    /// @notice Withdraws pending payouts that previously failed to transfer via BankLP
    function withdrawPending() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "NO_PENDING");

        pendingWithdrawals[msg.sender] = 0;
        totalPendingWithdrawals -= amount;

        IBankLP(bankroll).transferPayout(msg.sender, amount, address(0));

        emit PendingWithdrawalClaimed(msg.sender, amount);
    }

    /// @notice Recovers any ETH accidentally sent directly to this contract (not via betBatch)
    /// @dev All normal game funds live in BankLP; this ledger should hold zero balance
    function emergencyWithdraw() external nonReentrant onlyOwner {
        uint256 amount = address(this).balance;
        require(amount > 0, "ZERO");

        (bool ok, ) = owner.call{value: amount}("");
        require(ok, "WITHDRAW_FAIL");

        emit EmergencyWithdraw(amount);
    }

    /// @notice Accepts direct ETH transfers to the contract
    receive() external payable {}
}
