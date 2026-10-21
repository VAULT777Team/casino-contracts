// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IBonus1155V2 {
    function debitStakeAndRecordWager(
        address player,
        address token,
        uint256 bonusId,
        uint256 stake,
        uint256 wagerContribution
    ) external;

    function creditPayout(address player, address token, uint256 bonusId, uint256 payout) external;

    function cancelStakeAndWager(
        address player,
        address token,
        uint256 bonusId,
        uint256 refund,
        uint256 wagerContribution
    ) external;
}

/// @title Vault777 Bonus Game Ledger
/// @notice Bonus ledger with reservation semantics for interactive house games.
contract BonusGameLedger {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 public constant PROTOCOL_VERSION = 3;
    uint256 public constant MIN_REFUND_DELAY = 5 minutes;

    struct AtomicSettlement {
        address player;
        bytes32 reservationActionKey;
        bytes32 settlementActionKey;
        bytes32 roundKey;
        uint256 stake;
        uint16 wagerContributionBps;
        uint256 payout;
    }

    struct BonusRound {
        address player;
        address token;
        uint256 bonusId;
        uint256 reserved;
        uint256 consumed;
        uint256 released;
        uint256 openedAt;
        uint256 closedAt;
        address bonusContract;
        uint256 refundAt;
    }

    address public owner;
    address public bonusContract;
    bool public paused;
    uint256 public maxPayoutMultiplierX = 100;
    uint256 public cancelTimeframe = 600;
    uint256 private _status = _NOT_ENTERED;

    mapping(bytes32 => BonusRound) public rounds;
    mapping(bytes32 => uint256) public roundWagerContribution;
    mapping(bytes32 => bool) public actionUsed;
    mapping(address => bool) public isBetOperator;
    mapping(address => bool) public isSettleOperator;
    mapping(address => bool) public isAdmin;
    mapping(address => uint256) public selfExcludedUntil;

    event BonusReserved(
        bytes32 indexed actionKey,
        bytes32 indexed roundKey,
        address indexed player,
        address token,
        uint256 bonusId,
        uint256 amount
    );
    event BonusConsumed(
        bytes32 indexed actionKey,
        bytes32 indexed roundKey,
        address indexed player,
        uint256 amount,
        uint16 wagerContributionBps,
        uint256 wagerContribution
    );
    event BonusReleased(bytes32 indexed actionKey, bytes32 indexed roundKey, address indexed player, uint256 amount);
    event BetPlaced(
        bytes32 indexed actionKey,
        bytes32 indexed roundKey,
        address indexed player,
        address token,
        uint256 bonusId,
        uint256 stake,
        uint16 wagerContributionBps,
        uint256 wagerContribution
    );
    event BetSettled(
        bytes32 indexed actionKey,
        bytes32 indexed roundKey,
        address indexed player,
        address token,
        uint256 bonusId,
        uint256 payout
    );
    event RoundCanceled(
        bytes32 indexed roundKey, address indexed player, address token, uint256 indexed bonusId, uint256 refund
    );
    event BetOperatorUpdated(address indexed operator, bool allowed);
    event SettleOperatorUpdated(address indexed operator, bool allowed);
    event AdminUpdated(address indexed admin, bool allowed);
    event BonusContractUpdated(address indexed oldBonusContract, address indexed newBonusContract);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    modifier onlyOwnerOrAdmin() {
        require(msg.sender == owner || isAdmin[msg.sender], "NOT_AUTHORIZED");
        _;
    }

    modifier onlyBetOperator() {
        require(isBetOperator[msg.sender], "NOT_BET_OPERATOR");
        _;
    }

    modifier onlySettleOperator() {
        require(isSettleOperator[msg.sender], "NOT_SETTLE_OPERATOR");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "PAUSED");
        _;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "REENTRANCY");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    constructor(address initialOwner, address operator, address bonus) {
        require(initialOwner != address(0), "ZERO_OWNER");
        _validateBonusContract(bonus);
        owner = initialOwner;
        bonusContract = bonus;
        emit OwnershipTransferred(address(0), initialOwner);
        emit BonusContractUpdated(address(0), bonus);
        if (operator != address(0)) {
            isBetOperator[operator] = true;
            isSettleOperator[operator] = true;
            emit BetOperatorUpdated(operator, true);
            emit SettleOperatorUpdated(operator, true);
        }
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "ZERO_OWNER");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setBonusContract(address bonus) external onlyOwner {
        _validateBonusContract(bonus);
        emit BonusContractUpdated(bonusContract, bonus);
        bonusContract = bonus;
    }

    function setOperator(address operator, bool allowed) external onlyOwner {
        require(operator != address(0), "ZERO_OPERATOR");
        _setBetOperator(operator, allowed);
        _setSettleOperator(operator, allowed);
    }

    function setOperators(address[] calldata operators, bool[] calldata allowed) external onlyOwner {
        _validateOperatorBatch(operators, allowed);
        for (uint256 i; i < operators.length; ++i) {
            _setBetOperator(operators[i], allowed[i]);
            _setSettleOperator(operators[i], allowed[i]);
        }
    }

    function setBetOperator(address operator, bool allowed) external onlyOwnerOrAdmin {
        require(operator != address(0), "ZERO_OPERATOR");
        _setBetOperator(operator, allowed);
    }

    function setBetOperators(address[] calldata operators, bool[] calldata allowed) external onlyOwnerOrAdmin {
        _validateOperatorBatch(operators, allowed);
        for (uint256 i; i < operators.length; ++i) {
            _setBetOperator(operators[i], allowed[i]);
        }
    }

    function setSettleOperator(address operator, bool allowed) external onlyOwner {
        require(operator != address(0), "ZERO_OPERATOR");
        _setSettleOperator(operator, allowed);
    }

    function setSettleOperators(address[] calldata operators, bool[] calldata allowed) external onlyOwner {
        _validateOperatorBatch(operators, allowed);
        for (uint256 i; i < operators.length; ++i) {
            _setSettleOperator(operators[i], allowed[i]);
        }
    }

    function setAdmin(address admin, bool allowed) external onlyOwner {
        require(admin != address(0), "ZERO_ADMIN");
        isAdmin[admin] = allowed;
        emit AdminUpdated(admin, allowed);
    }

    function setAdmins(address[] calldata admins, bool[] calldata allowed) external onlyOwner {
        uint256 length = admins.length;
        require(length != 0, "EMPTY_ADMINS");
        require(length == allowed.length, "LENGTH_MISMATCH");
        for (uint256 i; i < length; ++i) {
            address admin = admins[i];
            require(admin != address(0), "ZERO_ADMIN");
            isAdmin[admin] = allowed[i];
            emit AdminUpdated(admin, allowed[i]);
        }
    }

    function setPaused(bool value) external onlyOwnerOrAdmin {
        paused = value;
    }

    function setMaxPayoutMultiplierX(uint256 value) external onlyOwnerOrAdmin {
        require(value > 0, "TOO_LOW");
        maxPayoutMultiplierX = value;
    }

    function setCancelTimeframe(uint256 value) external onlyOwnerOrAdmin {
        require(value >= MIN_REFUND_DELAY, "REFUND_DELAY_TOO_SHORT");
        cancelTimeframe = value;
    }

    function selfExclude(uint256 durationSeconds) external {
        require(durationSeconds > 0, "INVALID_DURATION");
        uint256 until = block.timestamp + durationSeconds;
        require(until > selfExcludedUntil[msg.sender], "EXCLUSION_SHORTER");
        selfExcludedUntil[msg.sender] = until;
    }

    /// @notice Locks maximum exposure without advancing wagering progress.
    function reserveBonusBatchFor(
        address token,
        uint256 bonusId,
        address[] calldata players,
        bytes32[] calldata actionKeys,
        bytes32[] calldata roundKeys,
        uint256[] calldata amounts
    ) external onlyBetOperator nonReentrant whenNotPaused {
        uint256 n = actionKeys.length;
        require(n > 0 && players.length == n && roundKeys.length == n && amounts.length == n, "LEN");
        for (uint256 i; i < n; ++i) {
            address player = players[i];
            require(player != address(0), "ZERO_PLAYER");
            require(block.timestamp >= selfExcludedUntil[player], "SELF_EXCLUDED");
            require(amounts[i] > 0, "ZERO_AMOUNT");
            _useAction(actionKeys[i]);
            BonusRound storage round = rounds[roundKeys[i]];
            require(round.player == address(0), "ROUND_EXISTS");
            round.player = player;
            round.token = token;
            round.bonusId = bonusId;
            round.reserved = amounts[i];
            round.openedAt = block.timestamp;
            round.bonusContract = bonusContract;
            round.refundAt = block.timestamp + cancelTimeframe;
            IBonus1155V2(round.bonusContract).debitStakeAndRecordWager(player, token, bonusId, amounts[i], 0);
            emit BonusReserved(actionKeys[i], roundKeys[i], player, token, bonusId, amounts[i]);
        }
    }

    /// @notice Atomically places and settles one-shot bonus rounds.
    function reserveAndSettleBatch(address token, uint256 bonusId, AtomicSettlement[] calldata settlements)
        external
        onlyBetOperator
        nonReentrant
        whenNotPaused
        returns (uint256 totalStake, uint256 totalContribution)
    {
        require(isSettleOperator[msg.sender], "NOT_SETTLE_OPERATOR");
        uint256 n = settlements.length;
        require(n > 0, "LEN");
        for (uint256 i; i < n; ++i) {
            AtomicSettlement calldata settlement = settlements[i];
            uint256 contribution = _placeImmediateBet(
                token,
                bonusId,
                settlement.player,
                settlement.reservationActionKey,
                settlement.roundKey,
                settlement.stake,
                settlement.wagerContributionBps
            );
            _settleBonusRound(
                token,
                bonusId,
                settlement.settlementActionKey,
                settlement.roundKey,
                settlement.payout
            );
            totalStake += settlement.stake;
            totalContribution += contribution;
        }
    }

    /// @notice Converts locked exposure into actual wager exactly once per action key.
    function consumeBonusBatch(
        address token,
        uint256 bonusId,
        bytes32[] calldata actionKeys,
        bytes32[] calldata roundKeys,
        uint256[] calldata amounts,
        uint16[] calldata wagerContributionBps
    ) external onlyBetOperator nonReentrant whenNotPaused {
        uint256 n = actionKeys.length;
        require(n > 0 && roundKeys.length == n && amounts.length == n && wagerContributionBps.length == n, "LEN");
        for (uint256 i; i < n; ++i) {
            require(amounts[i] > 0, "ZERO_AMOUNT");
            require(wagerContributionBps[i] <= 10_000, "BAD_CONTRIBUTION");
            _useAction(actionKeys[i]);
            BonusRound storage round = _openRound(roundKeys[i], token, bonusId);
            _requireSettlementWindow(round);
            require(round.consumed + round.released + amounts[i] <= round.reserved, "RESERVE_EXCEEDED");
            round.consumed += amounts[i];
            uint256 contribution = (amounts[i] * wagerContributionBps[i]) / 10_000;
            roundWagerContribution[roundKeys[i]] += contribution;

            // The deployed bonus token exposes debit+progress and credit primitives.
            // Minting then burning the consumed slice leaves the reservation locked
            // while advancing wagering progress only for actual play.
            _consumeReservedBonus(round, amounts[i], contribution);
            emit BonusConsumed(
                actionKeys[i], roundKeys[i], round.player, amounts[i], wagerContributionBps[i], contribution
            );
        }
    }

    function releaseBonusBatch(
        address token,
        uint256 bonusId,
        bytes32[] calldata actionKeys,
        bytes32[] calldata roundKeys,
        uint256[] calldata amounts
    ) external onlySettleOperator nonReentrant whenNotPaused {
        uint256 n = actionKeys.length;
        require(n > 0 && roundKeys.length == n && amounts.length == n, "LEN");
        for (uint256 i; i < n; ++i) {
            require(amounts[i] > 0, "ZERO_AMOUNT");
            _useAction(actionKeys[i]);
            BonusRound storage round = _openRound(roundKeys[i], token, bonusId);
            _requireSettlementWindow(round);
            require(round.consumed + round.released + amounts[i] <= round.reserved, "RESERVE_EXCEEDED");
            round.released += amounts[i];
            IBonus1155V2(round.bonusContract).creditPayout(round.player, token, bonusId, amounts[i]);
            emit BonusReleased(actionKeys[i], roundKeys[i], round.player, amounts[i]);
        }
    }

    /// @notice Final payout closes the round once all reserved exposure is consumed or released.
    function settleBonusBatch(
        address token,
        uint256 bonusId,
        bytes32[] calldata actionKeys,
        bytes32[] calldata roundKeys,
        uint256[] calldata payouts
    ) external onlySettleOperator nonReentrant whenNotPaused {
        uint256 n = actionKeys.length;
        require(n > 0 && roundKeys.length == n && payouts.length == n, "LEN");
        for (uint256 i; i < n; ++i) {
            _settleBonusRound(token, bonusId, actionKeys[i], roundKeys[i], payouts[i]);
        }
    }

    /// @notice V1-compatible immediate wager entrypoint.
    function betBonusBatchFor(
        address token,
        uint256 bonusId,
        address[] calldata players,
        bytes32[] calldata actionKeys,
        bytes32[] calldata roundKeys,
        uint256[] calldata stakes,
        uint16[] calldata wagerContributionBps
    ) external onlyBetOperator nonReentrant whenNotPaused returns (uint256 totalStake, uint256 totalContribution) {
        uint256 n = actionKeys.length;
        require(
            n > 0 && players.length == n && roundKeys.length == n && stakes.length == n
                && wagerContributionBps.length == n,
            "LEN"
        );
        for (uint256 i; i < n; ++i) {
            uint256 contribution = _placeImmediateBet(
                token, bonusId, players[i], actionKeys[i], roundKeys[i], stakes[i], wagerContributionBps[i]
            );
            totalStake += stakes[i];
            totalContribution += contribution;
        }
    }

    function cancel(bytes32 roundKey) external nonReentrant whenNotPaused {
        BonusRound storage round = rounds[roundKey];
        require(round.player != address(0), "ROUND_NOT_FOUND");
        require(round.closedAt == 0, "ALREADY_SETTLED");
        if (msg.sender == round.player) {
            require(block.timestamp >= round.refundAt, "REFUND_NOT_AVAILABLE");
        } else {
            require(isSettleOperator[msg.sender], "NOT_SETTLE_OPERATOR");
        }
        uint256 refund = round.reserved - round.released;
        uint256 contribution = roundWagerContribution[roundKey];
        roundWagerContribution[roundKey] = 0;
        round.released = round.reserved;
        round.closedAt = block.timestamp;
        IBonus1155V2(round.bonusContract)
            .cancelStakeAndWager(round.player, round.token, round.bonusId, refund, contribution);
        emit RoundCanceled(roundKey, round.player, round.token, round.bonusId, refund);
    }

    function _useAction(bytes32 actionKey) private {
        require(actionKey != bytes32(0), "ZERO_ACTION");
        require(!actionUsed[actionKey], "DUP_ACTION");
        actionUsed[actionKey] = true;
    }

    function _settleBonusRound(
        address token,
        uint256 bonusId,
        bytes32 actionKey,
        bytes32 roundKey,
        uint256 payout
    ) private {
        _useAction(actionKey);
        BonusRound storage round = _openRound(roundKey, token, bonusId);
        _requireSettlementWindow(round);
        require(round.consumed + round.released == round.reserved, "RESERVE_OPEN");
        require(payout <= round.consumed * maxPayoutMultiplierX, "PAYOUT_LIMIT");
        round.closedAt = block.timestamp;
        IBonus1155V2(round.bonusContract).creditPayout(round.player, token, bonusId, payout);
        emit BetSettled(actionKey, roundKey, round.player, token, bonusId, payout);
    }

    function _requireSettlementWindow(BonusRound storage round) private view {
        require(block.timestamp < round.refundAt, "SETTLEMENT_WINDOW_EXPIRED");
    }

    function _setBetOperator(address operator, bool allowed) private {
        if (isBetOperator[operator] == allowed) return;
        isBetOperator[operator] = allowed;
        emit BetOperatorUpdated(operator, allowed);
    }

    function _setSettleOperator(address operator, bool allowed) private {
        if (isSettleOperator[operator] == allowed) return;
        isSettleOperator[operator] = allowed;
        emit SettleOperatorUpdated(operator, allowed);
    }

    function _validateOperatorBatch(address[] calldata operators, bool[] calldata allowed) private pure {
        uint256 length = operators.length;
        require(length != 0, "EMPTY_OPERATORS");
        require(length == allowed.length, "LENGTH_MISMATCH");
        for (uint256 i; i < length; ++i) {
            require(operators[i] != address(0), "ZERO_OPERATOR");
        }
    }

    function _validateBonusContract(address bonus) private view {
        require(bonus != address(0), "ZERO_BONUS");
        require(bonus.code.length > 0, "BONUS_NOT_CONTRACT");
    }

    function _consumeReservedBonus(BonusRound storage round, uint256 amount, uint256 contribution) private {
        IBonus1155V2 bonus = IBonus1155V2(round.bonusContract);
        bonus.creditPayout(round.player, round.token, round.bonusId, amount);
        bonus.debitStakeAndRecordWager(round.player, round.token, round.bonusId, amount, contribution);
    }

    function _placeImmediateBet(
        address token,
        uint256 bonusId,
        address player,
        bytes32 actionKey,
        bytes32 roundKey,
        uint256 stake,
        uint16 wagerContributionBps
    ) private returns (uint256 contribution) {
        require(player != address(0) && stake > 0, "BAD_BET");
        require(block.timestamp >= selfExcludedUntil[player], "SELF_EXCLUDED");
        require(wagerContributionBps <= 10_000, "BAD_CONTRIBUTION");
        _useAction(actionKey);
        BonusRound storage round = rounds[roundKey];
        if (round.player == address(0)) {
            round.player = player;
            round.token = token;
            round.bonusId = bonusId;
            round.openedAt = block.timestamp;
            round.bonusContract = bonusContract;
            round.refundAt = block.timestamp + cancelTimeframe;
        } else {
            require(
                round.player == player && round.token == token && round.bonusId == bonusId && round.closedAt == 0,
                "ROUND_MISMATCH"
            );
        }
        contribution = (stake * wagerContributionBps) / 10_000;
        round.reserved += stake;
        round.consumed += stake;
        roundWagerContribution[roundKey] += contribution;
        IBonus1155V2(round.bonusContract).debitStakeAndRecordWager(player, token, bonusId, stake, contribution);
        emit BetPlaced(actionKey, roundKey, player, token, bonusId, stake, wagerContributionBps, contribution);
    }

    function _openRound(bytes32 roundKey, address token, uint256 bonusId)
        private
        view
        returns (BonusRound storage round)
    {
        round = rounds[roundKey];
        require(round.player != address(0), "ROUND_NOT_FOUND");
        require(round.closedAt == 0, "ROUND_CLOSED");
        require(round.token == token, "TOKEN_MISMATCH");
        require(round.bonusId == bonusId, "BONUS_MISMATCH");
    }
}
