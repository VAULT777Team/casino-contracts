// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Vault777 Game Ledger
/// @custom:security-contact security@vault777.com
/// @dev Supports batched bets and settlements with replay protected action keys.
///      The contract does not validate game logic, results are trusted from the operator.
///      Failed payouts are credited to pending withdrawals to prevent blocking execution.
///      Supports ETH and ERC20 tokens. address(0) is used for ETH.
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
    function getCurrentBankroll()
        external
        view
        returns (
            address bankroll,
            address treasury,
            string memory version,
            uint256 activatedAt
        );
}

interface IBankLP {
    function depositEther() external payable;

    function deposit(address token, uint256 amount) external;

    function transferPayout(
        address player,
        uint256 amount,
        address token
    ) external;
}

contract GameLedgerV3 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public owner;
    address public registry;
    address public bankroll;

    bool public paused;

    uint256 public maxPayoutMultiplierX = 100;
    uint256 public cancelTimeframe = 600;

    /// @notice Total amount owed to players via pending withdrawals, by token
    /// @dev address(0) means ETH
    mapping(address => uint256) public totalPendingWithdrawalsByToken;

    /// @notice Round state
    /// @dev token = address(0) means ETH
    struct Round {
        address player;
        address token;
        uint256 totalStake;
        uint256 openedAt;
        uint256 closedAt;
    }

    mapping(bytes32 => Round) public rounds;
    mapping(bytes32 => bool) public actionUsed;

    mapping(address => bool) public isOperator;
    mapping(address => bool) public isAdmin;

    mapping(address => uint256) public selfExcludedUntil;

    /// @notice player => token => amount
    /// @dev token = address(0) means ETH
    mapping(address => mapping(address => uint256)) public pendingWithdrawals;

    mapping(bytes32 => uint256) public roundPaidOut;
    mapping(bytes32 => bool) public roundCanceled;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event BetPlaced(
        bytes32 indexed actionKey,
        bytes32 indexed roundKey,
        address indexed player,
        address token,
        uint256 stake
    );

    event BetSettled(
        bytes32 indexed actionKey,
        bytes32 indexed roundKey,
        address indexed player,
        address token,
        uint256 payout
    );

    event RoundCanceled(
        bytes32 indexed roundKey,
        address indexed player,
        address token,
        uint256 refund
    );

    event PendingPayoutRecorded(
        address indexed player,
        address indexed token,
        uint256 amount
    );

    event PendingWithdrawalClaimed(
        address indexed player,
        address indexed token,
        uint256 amount
    );

    event OperatorUpdated(address indexed operator, bool allowed);
    event AdminUpdated(address indexed admin, bool allowed);
    event RegistryUpdated(address indexed registry);
    event BankrollUpdated(address indexed bankroll);

    event BankrollDeposited(
        address indexed from,
        address indexed token,
        uint256 amount
    );

    event EmergencyWithdraw(address indexed token, uint256 amount);

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
        emit RegistryUpdated(_registry);

        (address _bankroll, , , ) = IRegistry(_registry).getCurrentBankroll();
        require(_bankroll != address(0), "ZERO_BANKROLL");

        bankroll = _bankroll;
        emit BankrollUpdated(_bankroll);

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

    function setOperators(address[] calldata operators) external onlyOwner {
        uint256 n = operators.length;

        for (uint256 i; i < n; ) {
            address operator = operators[i];

            require(operator != address(0), "ZERO_OPERATOR");

            isOperator[operator] = true;
            emit OperatorUpdated(operator, true);

            unchecked {
                ++i;
            }
        }
    }

    function removeOperator(address operator) external onlyOwner {
        isOperator[operator] = false;
        emit OperatorUpdated(operator, false);
    }

    function removeOperators(address[] calldata operators) external onlyOwner {
        uint256 n = operators.length;

        for (uint256 i; i < n; ) {
            address operator = operators[i];

            isOperator[operator] = false;
            emit OperatorUpdated(operator, false);

            unchecked {
                ++i;
            }
        }
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

    function updateBankroll() external onlyOwnerOrAdmin {
        (address _bankroll, , , ) = IRegistry(registry).getCurrentBankroll();
        require(_bankroll != address(0), "ZERO_BANKROLL");

        bankroll = _bankroll;
        emit BankrollUpdated(_bankroll);
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

    function selfExclude(uint256 durationSeconds) external {
        require(durationSeconds > 0, "INVALID_DURATION");

        uint256 until = block.timestamp + durationSeconds;

        require(until > selfExcludedUntil[msg.sender], "EXCLUSION_SHORTER");

        selfExcludedUntil[msg.sender] = until;
        emit SelfExcluded(msg.sender, until);
    }

    /// @notice Places one or more bets directly from the player/session wallet.
    /// @dev token = address(0) means ETH.
    ///      For ERC20, msg.sender must approve this ledger first.
    function betBatch(
        address token,
        bytes32[] calldata actionKeys,
        bytes32[] calldata roundKeys,
        uint256[] calldata stakes,
        uint256 validUntil,
        bytes calldata signature
    ) external payable nonReentrant whenNotPaused notSelfExcluded {
        require(block.timestamp <= validUntil, "SIG_EXPIRED");

        uint256 totalValue = _recordBetBatch(
            token,
            actionKeys,
            roundKeys,
            stakes
        );

        _validateBetPaymentAndSignature(
            token,
            totalValue,
            validUntil,
            signature
        );

        _depositToBankroll(token, totalValue);
    }

    /// @notice Places one or more bets on behalf of one or many players.
    /// @dev Only an authorized operator can call this.
    ///      For ERC20, each player must approve this ledger first.
    ///      For ETH, the operator sends msg.value equal to totalValue.
    function betBatchFor(
        address token,
        address[] calldata players,
        bytes32[] calldata actionKeys,
        bytes32[] calldata roundKeys,
        uint256[] calldata stakes
    ) external payable onlyOperator nonReentrant whenNotPaused {
        uint256 totalValue = _recordBetBatchFor(
            token,
            players,
            actionKeys,
            roundKeys,
            stakes
        );

        _depositBatchToBankroll(token, players, stakes, totalValue);
    }

    /// @notice Settles multiple bet actions across one or more rounds.
    /// @dev token = address(0) means ETH.
    ///      One settlement batch should contain only one token.
    function settleBatch(
        address token,
        bytes32[] calldata actionKeys,
        bytes32[] calldata roundKeys,
        uint256[] calldata payouts
    ) external onlyOperator nonReentrant whenNotPaused {
        address[] memory players = _recordSettlementBatch(
            token,
            actionKeys,
            roundKeys,
            payouts
        );

        _processBatchPayouts(token, players, payouts);
    }

    /// @notice Cancels a round and refunds the player stake.
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
        address token = r.token;

        roundCanceled[roundKey] = true;
        r.closedAt = block.timestamp;

        try IBankLP(bankroll).transferPayout(player, refund, token) {
            // success
        } catch {
            _recordPendingPayout(player, token, refund);
        }

        emit RoundCanceled(roundKey, player, token, refund);
    }

    /// @notice Withdraws pending payouts that previously failed.
    /// @dev token = address(0) means ETH.
    function withdrawPending(address token) external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender][token];

        require(amount > 0, "NO_PENDING");

        pendingWithdrawals[msg.sender][token] = 0;
        totalPendingWithdrawalsByToken[token] -= amount;

        IBankLP(bankroll).transferPayout(msg.sender, amount, token);

        emit PendingWithdrawalClaimed(msg.sender, token, amount);
    }

    // -------------------------------------------------------------------------
    // Internal bet helpers - direct player flow
    // -------------------------------------------------------------------------

    function _recordBetBatch(
        address token,
        bytes32[] calldata actionKeys,
        bytes32[] calldata roundKeys,
        uint256[] calldata stakes
    ) internal returns (uint256 totalValue) {
        uint256 n = actionKeys.length;

        require(n > 0, "EMPTY");
        require(roundKeys.length == n && stakes.length == n, "LEN");

        uint256 ts = block.timestamp;

        for (uint256 i; i < n; ) {
            totalValue += _recordSingleBetFor(
                token,
                msg.sender,
                actionKeys[i],
                roundKeys[i],
                stakes[i],
                ts
            );

            unchecked {
                ++i;
            }
        }
    }

    function _validateBetPaymentAndSignature(
        address token,
        uint256 totalValue,
        uint256 validUntil,
        bytes calldata signature
    ) internal view {
        if (token == address(0)) {
            require(msg.value == totalValue, "BAD_VALUE");
        } else {
            require(msg.value == 0, "NO_ETH_ALLOWED");
        }

        bytes32 digest = keccak256(
            abi.encode(msg.sender, token, totalValue, address(this), validUntil)
        );

        address signer = ECDSA.recover(
            ECDSA.toEthSignedMessageHash(digest),
            signature
        );

        require(isOperator[signer], "INVALID_SIGNATURE");
    }

    function _depositToBankroll(address token, uint256 amount) internal {
        if (amount == 0) return;

        address _bankroll = bankroll;

        if (token == address(0)) {
            IBankLP(_bankroll).depositEther{value: amount}();
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

            IERC20(token).safeApprove(_bankroll, 0);
            IERC20(token).safeApprove(_bankroll, amount);

            IBankLP(_bankroll).deposit(token, amount);
        }

        emit BankrollDeposited(msg.sender, token, amount);
    }

    // -------------------------------------------------------------------------
    // Internal bet helpers - operator flow
    // -------------------------------------------------------------------------

    function _recordBetBatchFor(
        address token,
        address[] calldata players,
        bytes32[] calldata actionKeys,
        bytes32[] calldata roundKeys,
        uint256[] calldata stakes
    ) internal returns (uint256 totalValue) {
        uint256 n = actionKeys.length;

        require(n > 0, "EMPTY");
        require(
            players.length == n &&
                roundKeys.length == n &&
                stakes.length == n,
            "LEN"
        );

        uint256 ts = block.timestamp;

        for (uint256 i; i < n; ) {
            address player = players[i];

            require(player != address(0), "ZERO_PLAYER");
            require(ts >= selfExcludedUntil[player], "SELF_EXCLUDED");

            totalValue += _recordSingleBetFor(
                token,
                player,
                actionKeys[i],
                roundKeys[i],
                stakes[i],
                ts
            );

            unchecked {
                ++i;
            }
        }
    }

    function _recordSingleBetFor(
        address token,
        address player,
        bytes32 actionKey,
        bytes32 roundKey,
        uint256 stake,
        uint256 ts
    ) internal returns (uint256) {
        require(stake > 0, "ZERO_STAKE");
        require(!actionUsed[actionKey], "DUP_ACTION");

        actionUsed[actionKey] = true;

        Round storage r = rounds[roundKey];

        if (r.player == address(0)) {
            r.player = player;
            r.token = token;
            r.openedAt = ts;
        } else {
            require(r.closedAt == 0, "ROUND_CLOSED");
            require(r.player == player, "PLAYER_MISMATCH");
            require(r.token == token, "TOKEN_MISMATCH");
        }

        r.totalStake += stake;

        emit BetPlaced(actionKey, roundKey, player, token, stake);

        return stake;
    }

    function _depositBatchToBankroll(
        address token,
        address[] calldata players,
        uint256[] calldata stakes,
        uint256 totalValue
    ) internal {
        if (totalValue == 0) return;

        address _bankroll = bankroll;

        if (token == address(0)) {
            require(msg.value == totalValue, "BAD_VALUE");

            IBankLP(_bankroll).depositEther{value: totalValue}();

            emit BankrollDeposited(msg.sender, token, totalValue);
        } else {
            require(msg.value == 0, "NO_ETH_ALLOWED");

            uint256 n = players.length;

            for (uint256 i; i < n; ) {
                IERC20(token).safeTransferFrom(
                    players[i],
                    address(this),
                    stakes[i]
                );

                unchecked {
                    ++i;
                }
            }

            IERC20(token).safeApprove(_bankroll, 0);
            IERC20(token).safeApprove(_bankroll, totalValue);

            IBankLP(_bankroll).deposit(token, totalValue);

            emit BankrollDeposited(msg.sender, token, totalValue);
        }
    }

    // -------------------------------------------------------------------------
    // Internal settlement helpers
    // -------------------------------------------------------------------------

    function _recordSettlementBatch(
        address token,
        bytes32[] calldata actionKeys,
        bytes32[] calldata roundKeys,
        uint256[] calldata payouts
    ) internal returns (address[] memory players) {
        uint256 n = actionKeys.length;

        require(n > 0, "EMPTY");
        require(roundKeys.length == n && payouts.length == n, "LEN");

        players = new address[](n);

        for (uint256 i; i < n; ) {
            players[i] = _recordSingleSettlement(
                token,
                actionKeys[i],
                roundKeys[i],
                payouts[i]
            );

            unchecked {
                ++i;
            }
        }
    }

    function _recordSingleSettlement(
        address token,
        bytes32 actionKey,
        bytes32 roundKey,
        uint256 payout
    ) internal returns (address player) {
        require(!actionUsed[actionKey], "DUP_ACTION");

        actionUsed[actionKey] = true;

        Round storage r = rounds[roundKey];

        require(r.player != address(0), "ROUND_NOT_FOUND");
        require(!roundCanceled[roundKey], "ROUND_CANCELED");
        require(r.token == token, "TOKEN_MISMATCH");

        uint256 cumulativePayout = roundPaidOut[roundKey] + payout;
        require(
            cumulativePayout <= r.totalStake * maxPayoutMultiplierX,
            "PAYOUT_LIMIT"
        );

        roundPaidOut[roundKey] = cumulativePayout;

        if (r.closedAt == 0) {
            r.closedAt = block.timestamp;
        }

        player = r.player;

        emit BetSettled(actionKey, roundKey, player, token, payout);
    }

    function _processBatchPayouts(
        address token,
        address[] memory players,
        uint256[] calldata payouts
    ) internal {
        address _bankroll = bankroll;
        uint256 n = payouts.length;

        for (uint256 i; i < n; ) {
            uint256 payout = payouts[i];

            if (payout > 0) {
                try
                    IBankLP(_bankroll).transferPayout(
                        players[i],
                        payout,
                        token
                    )
                {
                    // success
                } catch {
                    _recordPendingPayout(players[i], token, payout);
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    function _recordPendingPayout(
        address player,
        address token,
        uint256 amount
    ) internal {
        pendingWithdrawals[player][token] += amount;
        totalPendingWithdrawalsByToken[token] += amount;

        emit PendingPayoutRecorded(player, token, amount);
    }

    // -------------------------------------------------------------------------
    // Emergency
    // -------------------------------------------------------------------------

    /// @notice Recovers any ETH accidentally sent directly to this contract.
    /// @dev Normal game funds should live in BankLP; this ledger should hold zero ETH.
    function emergencyWithdraw(address token) external nonReentrant onlyOwner {
        if (token != address(0)) {
            uint256 tokenBalance = IERC20(token).balanceOf(address(this));
            require(tokenBalance > 0, "ZERO");

            IERC20(token).safeTransfer(owner, tokenBalance);

            emit EmergencyWithdraw(token, tokenBalance);
            return;
        }

        uint256 amount = address(this).balance;
        require(amount > 0, "ZERO");

        (bool ok, ) = owner.call{value: amount}("");
        require(ok, "WITHDRAW_FAIL");

        emit EmergencyWithdraw(address(0), amount);
    }

    receive() external payable {}
}