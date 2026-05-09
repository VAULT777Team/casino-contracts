// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {
    Common, VRFConfig, IBankrollRegistry,
    ChainSpecificUtil,
    IERC20, SafeERC20
} from "../Common.sol";

/**
 * @title slots game, players put in a wager and recieve payout depending on the slots outcome
 */

contract Slots is Common {
    using SafeERC20 for IERC20;
    uint64 public immutable refundCooldownBlocks;

    bool public isConfigured;
    bool public isConfiguring;

    error AlreadyConfigured();
    error AlreadyConfiguring();
    error NotConfigured();
    error NotConfiguring();

    constructor(
        address _registry,
        VRFConfig memory vrf,
        uint64 _refundCooldownBlocks,
        uint16[] memory _multipliers,
        uint16[] memory _outcomeNum,
        uint16 _numOutcomes,
        uint16[] memory _bonusMultipliers,
        uint8[] memory _bonusRounds,
        uint16[] memory _bonusOutcomeNum,
        uint8 _rowsPerSpin,
        uint8 _columnsPerSpin
    ) Common(vrf) {
        b_registry = IBankrollRegistry(_registry);
        refundCooldownBlocks = _refundCooldownBlocks;

        if (_numOutcomes > 0) {
            _setup(
                _multipliers,
                _outcomeNum,
                _numOutcomes,
                _bonusMultipliers,
                _bonusRounds,
                _bonusOutcomeNum,
                _rowsPerSpin,
                _columnsPerSpin,
                false
            );
        }
    }

    function Slots_Setup(
        uint16[] memory _multipliers,
        uint16[] memory _outcomeNum,
        uint16 _numOutcomes,
        uint16[] memory _bonusMultipliers,
        uint8[] memory _bonusRounds,
        uint16[] memory _bonusOutcomeNum,
        uint8 _rowsPerSpin,
        uint8 _columnsPerSpin,
        bool _rowSpecific
    ) external onlyOwner {
        _setup(
            _multipliers,
            _outcomeNum,
            _numOutcomes,
            _bonusMultipliers,
            _bonusRounds,
            _bonusOutcomeNum,
            _rowsPerSpin,
            _columnsPerSpin,
            _rowSpecific
        );
    }

    function _setup(
        uint16[] memory _multipliers,
        uint16[] memory _outcomeNum,
        uint16 _numOutcomes,
        uint16[] memory _bonusMultipliers,
        uint8[] memory _bonusRounds,
        uint16[] memory _bonusOutcomeNum,
        uint8 _rowsPerSpin,
        uint8 _columnsPerSpin,
        bool _rowSpecific
    ) internal {
        if (isConfigured) {
            revert AlreadyConfigured();
        }

        if (isConfiguring) {
            revert AlreadyConfiguring();
        }

        _setGridConfig(_rowsPerSpin, _columnsPerSpin, _rowSpecific);
        _setSlotsMultipliers(_multipliers, _outcomeNum, _numOutcomes);
        _setSlotsBonuses(_bonusMultipliers, _bonusRounds, _bonusOutcomeNum);
        isConfigured = true;
    }

    function Slots_BeginSetup(
        uint16 _numOutcomes,
        uint8 _rowsPerSpin,
        uint8 _columnsPerSpin,
        bool _rowSpecific
    ) external onlyOwner {
        _beginSetup(_numOutcomes, _rowsPerSpin, _columnsPerSpin, _rowSpecific);
    }

    function _beginSetup(
        uint16 _numOutcomes,
        uint8 _rowsPerSpin,
        uint8 _columnsPerSpin,
        bool _rowSpecific
    ) internal {
        if (isConfigured) {
            revert AlreadyConfigured();
        }

        if (isConfiguring) {
            revert AlreadyConfiguring();
        }

        numOutcomes = _numOutcomes;
        _setGridConfig(_rowsPerSpin, _columnsPerSpin, _rowSpecific);
        isConfiguring = true;
    }

    function Slots_SetMultipliersBatch(
        uint16[] memory _multipliers,
        uint16[] memory _outcomeNum
    ) external onlyOwner {
        if (!isConfiguring || isConfigured) {
            revert NotConfiguring();
        }

        require(_multipliers.length == _outcomeNum.length, "Invalid multipliers config");

        for (uint16 i = 0; i < _multipliers.length; i++) {
            require(_outcomeNum[i] < numOutcomes, "Invalid outcome number");
            slotsMultipliers[_outcomeNum[i]] = _multipliers[i];
        }
    }

    function Slots_SetBonusesBatch(
        uint16[] memory _bonusMultipliers,
        uint8[] memory _bonusRounds,
        uint16[] memory _bonusOutcomeNum
    ) external onlyOwner {
        if (!isConfiguring || isConfigured) {
            revert NotConfiguring();
        }

        require(
            _bonusMultipliers.length == _bonusRounds.length &&
            _bonusRounds.length == _bonusOutcomeNum.length,
            "Invalid bonus config"
        );

        for (uint16 i = 0; i < _bonusMultipliers.length; i++) {
            require(_bonusOutcomeNum[i] < numOutcomes, "Invalid bonus outcome");
            require(_bonusRounds[i] <= MAX_BONUS_ROUNDS, "Bonus rounds too high");
            slotsBonusMultipliers[_bonusOutcomeNum[i]] = _bonusMultipliers[i];
            slotsBonusRounds[_bonusOutcomeNum[i]] = _bonusRounds[i];
        }
    }

    function Slots_FinalizeSetup() external onlyOwner {
        if (!isConfiguring || isConfigured) {
            revert NotConfiguring();
        }

        isConfiguring = false;
        isConfigured = true;
    }

    struct SlotsGame {
        uint256 wager;
        uint256 stopGain;
        uint256 stopLoss;
        uint256 requestID;
        address tokenAddress;
        uint64 blockNumber;
        uint32 numBets;
    }

    mapping(address => SlotsGame) slotsGames;
    mapping(uint256 => address) slotsIDs;

    mapping(uint16 => uint16) slotsMultipliers;
    mapping(uint16 => uint16) slotsBonusMultipliers;
    mapping(uint16 => uint8) slotsBonusRounds;
    uint16 numOutcomes;
    uint8 rowsPerSpin;
    uint8 columnsPerSpin;
    bool rowSpecific;

    // Frontend display ID offsets to distinguish visual bonus outcomes from normal outcomes.
    // - Normal outcome image ID: outcomeId
    // - Bonus-round-only image ID: outcomeId + BONUS_ROUND_OUTCOME_OFFSET
    // - Bonus-multiplier image ID: outcomeId + BONUS_MULTIPLIER_OUTCOME_OFFSET
    uint16 public constant BONUS_ROUND_OUTCOME_OFFSET = 20000;
    uint16 public constant BONUS_MULTIPLIER_OUTCOME_OFFSET = 40000;

    uint8 public constant MAX_BONUS_ROUNDS = 25;
    uint8 public constant MAX_ROWS_PER_SPIN = 5;
    uint8 public constant MAX_COLUMNS_PER_SPIN = 5;

    /**
     * @dev event emitted at the start of the game
     * @param playerAddress address of the player that made the bet
     * @param wager wagered amount
     * @param tokenAddress address of token the wager was made, 0 address is considered the native coin
     * @param numBets number of bets the player intends to make
     * @param stopGain gain value at which the betting stop if a gain is reached
     * @param stopLoss loss value at which the betting stop if a loss is reached
     */
    event Slots_Play_Event(
        address indexed playerAddress,
        uint256 wager,
        address tokenAddress,
        uint32 numBets,
        uint256 stopGain,
        uint256 stopLoss,
        uint256 VRFFee
    );

    /**
     * @dev event emitted by the VRF callback with the bet results
     * @param playerAddress address of the player that made the bet
     * @param wager wager amount
     * @param payout total payout transfered to the player
     * @param tokenAddress address of token the wager was made and payout, 0 address is considered the native coin
    * @param slotIDs slots display outcome IDs (bonus outcomes use configured offsets)
     * @param multipliers multiplier of the slots result
     * @param payouts individual payouts for each bet
     * @param bonusRoundsPerSpin number of bonus rounds triggered per spin
    * @param bonusSlotIDs flattened bonus-round display outcome IDs (bonus outcomes use configured offsets)
     * @param bonusMultipliers flattened bonus round multipliers
     * @param numGames number of games performed
     */
    event Slots_Outcome_Event(
        address indexed playerAddress,
        uint256 wager,
        uint256 payout,
        address tokenAddress,
        uint16[] slotIDs,
        uint256[] multipliers,
        uint256[] payouts,
        uint16[] bonusRoundsPerSpin,
        uint16[] bonusSlotIDs,
        uint256[] bonusMultipliers,
        uint32 numGames,
        uint8 rowsPerSpin,
        uint8 columnsPerSpin
    );

    /**
     * @dev event emitted when a refund is done in slots
     * @param player address of the player reciving the refund
     * @param wager amount of wager that was refunded
     * @param tokenAddress address of token the refund was made in
     */
    event Slots_Refund_Event(
        address indexed player,
        uint256 wager,
        address tokenAddress
    );

    error AwaitingVRF(uint256 requestId);
    error InvalidNumBets(uint256 maxNumBets);
    error NotAwaitingVRF();
    error WagerAboveLimit(uint256 wager, uint256 maxWager);
    error BlockNumberTooLow(uint256 have, uint256 want);

    /**
     * @dev function to get current request player is await from VRF, returns 0 if none
     * @param player address of the player to get the state
     */
    function Slots_GetState(
        address player
    ) external view returns (SlotsGame memory) {
        return (slotsGames[player]);
    }

    /**
     * @dev function to view the current slots multipliers
     * @return  multipliers multipliers for all slots outcomes
     */
    function Slots_GetMultipliers()
        external
        view
        returns (uint16[] memory multipliers)
    {
        multipliers = new uint16[](numOutcomes);
        for (uint16 i = 0; i < numOutcomes; i++) {
            multipliers[i] = slotsMultipliers[i];
        }
        return multipliers;
    }

    /**
     * @dev function to view the current slots bonus multipliers
     * @return bonusMultipliers bonus multipliers for all slots outcomes
     */
    function Slots_GetBonusMultipliers()
        external
        view
        returns (uint16[] memory bonusMultipliers)
    {
        bonusMultipliers = new uint16[](numOutcomes);
        for (uint16 i = 0; i < numOutcomes; i++) {
            bonusMultipliers[i] = slotsBonusMultipliers[i];
        }
        return bonusMultipliers;
    }

    /**
     * @dev function to view the current slots bonus rounds (free spins)
     * @return bonusRounds bonus rounds for all slots outcomes
     */
    function Slots_GetBonusRounds()
        external
        view
        returns (uint8[] memory bonusRounds)
    {
        bonusRounds = new uint8[](numOutcomes);
        for (uint16 i = 0; i < numOutcomes; i++) {
            bonusRounds[i] = slotsBonusRounds[i];
        }
        return bonusRounds;
    }

    /**
     * @dev function to view the rows per spin configuration
     */
    function Slots_GetRowsPerSpin() external view returns (uint8) {
        return rowsPerSpin;
    }

    /**
     * @dev function to view the columns per spin configuration
     */
    function Slots_GetColumnsPerSpin() external view returns (uint8) {
        return columnsPerSpin;
    }

    /**
     * @dev Function to play slots, takes the user wager saves bet parameters and makes a request to the VRF
     * @param wager wager amount
     * @param tokenAddress address of token to bet, 0 address is considered the native coin
     * @param numBets number of bets to make, and amount of random numbers to request
     * @param stopGain treshold value at which the bets stop if a certain profit is obtained
     * @param stopLoss treshold value at which the bets stop if a certain loss is obtained
     */

    function Slots_Play(
        uint256 wager,
        address tokenAddress,
        uint32 numBets,
        uint256 stopGain,
        uint256 stopLoss
    ) external payable nonReentrant {
        address msgSender = _msgSender();

        if (!isConfigured) {
            revert NotConfigured();
        }

        if (slotsGames[msgSender].requestID != 0) {
            revert AwaitingVRF(slotsGames[msgSender].requestID);
        }
        if (!(numBets > 0 && numBets <= 100)) {
            revert InvalidNumBets(100);
        }

        _kellyWager(wager, tokenAddress);
        _transferWager(
            tokenAddress,
            wager * numBets,
            800000,
            msgSender
        );
        uint256 id = _requestRandomWords(numBets);

        slotsGames[msgSender] = SlotsGame({
            requestID: id,
            wager: wager,
            stopGain: stopGain,
            stopLoss: stopLoss,
            tokenAddress: tokenAddress,
            blockNumber: uint64(ChainSpecificUtil.getBlockNumber()),
            numBets: numBets
        });

        slotsIDs[id] = msgSender;

        emit Slots_Play_Event(
            msgSender,
            wager,
            tokenAddress,
            numBets,
            stopGain,
            stopLoss,
            0
        );
    }

    /**
     * @dev Function to refund user in case of VRF request failling
     */
    function Slots_Refund() external nonReentrant {
        address msgSender = _msgSender();
        SlotsGame storage game = slotsGames[msgSender];
        if (game.requestID == 0) {
            revert NotAwaitingVRF();
        }

        if (game.blockNumber + refundCooldownBlocks > uint64(ChainSpecificUtil.getBlockNumber())) {
            revert BlockNumberTooLow(uint64(ChainSpecificUtil.getBlockNumber()), game.blockNumber + refundCooldownBlocks);
        }

        uint256 wager = game.wager * game.numBets;
        address tokenAddress = game.tokenAddress;

        delete (slotsIDs[game.requestID]);
        delete (slotsGames[msgSender]);

        if (tokenAddress == address(0)) {
            (bool success, ) = payable(msgSender).call{value: wager}("");
            if (!success) {
                revert TransferFailed();
            }
        } else {
            IERC20(tokenAddress).safeTransfer(msgSender, wager);
        }
        emit Slots_Refund_Event(msgSender, wager, tokenAddress);
    }


    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        address playerAddress = slotsIDs[requestId];
        if (playerAddress == address(0)) revert();
        SlotsGame storage game = slotsGames[playerAddress];

        uint256 payout;
        int256 totalValue;
        uint32 i;
        uint32 totalRows = uint32(game.numBets) * rowsPerSpin;
        uint16[] memory slotID = new uint16[](totalRows);
        uint256[] memory multipliers = new uint256[](totalRows);
        uint256[] memory payouts = new uint256[](game.numBets);
        uint16[] memory bonusRoundsPerSpin = new uint16[](game.numBets);
        uint16[] memory bonusSlotIDs;
        uint256[] memory bonusMultipliers;

        address tokenAddress = game.tokenAddress;

        uint32 processedRows;
        bool stopReached;

        uint32 totalBonusRoundsAll;
        for (i = 0; i < game.numBets && !stopReached; i++) {
            if (totalValue >= int256(game.stopGain)) {
                stopReached = true;
                break;
            }
            if (totalValue <= -int256(game.stopLoss)) {
                stopReached = true;
                break;
            }

            uint16 totalBonusRounds;

            if (rowSpecific) {
                for (uint8 row = 0; row < rowsPerSpin; row++) {
                    uint32 rowIndex = (uint32(i) * rowsPerSpin) + row;

                    uint16 outcome = rowsPerSpin == 1
                        ? uint16(randomWords[i] % numOutcomes)
                        : uint16(uint256(keccak256(abi.encode(randomWords[i], requestId, i, row))) % numOutcomes);

                    slotID[rowIndex] = _toDisplayOutcomeId(outcome);

                    uint256 baseMultiplier = uint256(slotsMultipliers[outcome]);
                    uint256 bonusMultiplier = uint256(slotsBonusMultipliers[outcome]);
                    uint256 effectiveMultiplier = baseMultiplier + bonusMultiplier;
                    multipliers[rowIndex] = effectiveMultiplier;

                    if (effectiveMultiplier != 0) {
                        totalValue +=
                            int256(game.wager * effectiveMultiplier) -
                            int256(game.wager);
                        payout += game.wager * effectiveMultiplier;
                        payouts[i] += game.wager * effectiveMultiplier;
                    } else {
                        totalValue -= int256(game.wager);
                    }

                    uint8 bonusRounds = slotsBonusRounds[outcome];
                    if (bonusRounds > 0) {
                        totalBonusRounds += bonusRounds;
                    }

                    processedRows++;
                }
            } else {
                uint256 combinedMultiplier;
                uint8 symbolBase;
                if (rowsPerSpin > 1 && columnsPerSpin == 5 && numOutcomes == 16807) {
                    symbolBase = 7;
                }
                uint8[] memory symbolCounts;
                if (symbolBase != 0) {
                    symbolCounts = new uint8[](symbolBase);
                }

                for (uint8 row = 0; row < rowsPerSpin; row++) {
                    uint32 rowIndex = (uint32(i) * rowsPerSpin) + row;

                    uint16 outcome = rowsPerSpin == 1
                        ? uint16(randomWords[i] % numOutcomes)
                        : uint16(uint256(keccak256(abi.encode(randomWords[i], requestId, i, row))) % numOutcomes);

                    slotID[rowIndex] = _toDisplayOutcomeId(outcome);

                    if (symbolBase == 0) {
                        uint256 baseMultiplier = uint256(slotsMultipliers[outcome]);
                        uint256 bonusMultiplier = uint256(slotsBonusMultipliers[outcome]);
                        combinedMultiplier += (baseMultiplier + bonusMultiplier);

                        uint8 bonusRounds = slotsBonusRounds[outcome];
                        if (bonusRounds > 0) {
                            totalBonusRounds += bonusRounds;
                        }
                    } else {
                        _accumulateSymbolCounts(symbolCounts, outcome, symbolBase);
                    }

                    processedRows++;
                }

                if (symbolBase != 0) {
                    for (uint8 symbol = 0; symbol < symbolBase; symbol++) {
                        uint8 count = symbolCounts[symbol];
                        uint8 tier = count > 5 ? 5 : count;

                        if (tier >= 3) {
                            combinedMultiplier += _symbolKindMultiplier(symbol, tier, symbolBase);
                        }

                        if (tier >= 4) {
                            combinedMultiplier += _symbolKindBonusMultiplier(symbol, tier, symbolBase);
                            totalBonusRounds += _symbolKindBonusRounds(symbol, tier, symbolBase);
                        }
                    }
                }

                uint32 firstRowIndex = uint32(i) * rowsPerSpin;
                multipliers[firstRowIndex] = combinedMultiplier;

                if (combinedMultiplier != 0) {
                    totalValue +=
                        int256(game.wager * combinedMultiplier) -
                        int256(game.wager);
                    payout += game.wager * combinedMultiplier;
                    payouts[i] += game.wager * combinedMultiplier;
                } else {
                    totalValue -= int256(game.wager);
                }
            }

            if (totalBonusRounds > 0) {
                bonusRoundsPerSpin[i] = totalBonusRounds;
                totalBonusRoundsAll += totalBonusRounds;
                uint256 bonusPayout;
                for (uint16 j = 0; j < totalBonusRounds; j++) {
                    uint16 bonusSlot = uint16(
                        uint256(keccak256(abi.encode(randomWords[i], requestId, i, j, uint8(1)))) % numOutcomes
                    );
                    uint256 bonusSpinMultiplier =
                        uint256(slotsMultipliers[bonusSlot]) +
                        uint256(slotsBonusMultipliers[bonusSlot]);

                    if (bonusSpinMultiplier != 0) {
                        totalValue += int256(game.wager * bonusSpinMultiplier);
                        bonusPayout += game.wager * bonusSpinMultiplier;
                    }
                }

                if (bonusPayout != 0) {
                    payout += bonusPayout;
                    payouts[i] += bonusPayout;
                }
            }

            if (totalValue >= int256(game.stopGain)) {
                stopReached = true;
            }
            if (totalValue <= -int256(game.stopLoss)) {
                stopReached = true;
            }
        }

        if (totalBonusRoundsAll > 0) {
            bonusSlotIDs = new uint16[](totalBonusRoundsAll);
            bonusMultipliers = new uint256[](totalBonusRoundsAll);

            uint32 bonusIndex;
            for (uint32 spin = 0; spin < i; spin++) {
                uint16 rounds = bonusRoundsPerSpin[spin];
                for (uint16 j = 0; j < rounds; j++) {
                    uint16 bonusSlot = uint16(
                        uint256(keccak256(abi.encode(randomWords[spin], requestId, spin, j, uint8(1)))) % numOutcomes
                    );
                    uint256 bonusSpinMultiplier =
                        uint256(slotsMultipliers[bonusSlot]) +
                        uint256(slotsBonusMultipliers[bonusSlot]);

                    bonusSlotIDs[bonusIndex] = _toDisplayOutcomeId(bonusSlot);
                    bonusMultipliers[bonusIndex] = bonusSpinMultiplier;
                    bonusIndex++;
                }
            }
        }

        payout += (totalRows - processedRows) * game.wager;

        emit Slots_Outcome_Event(
            playerAddress,
            game.wager,
            payout,
            tokenAddress,
            slotID,
            multipliers,
            payouts,
            bonusRoundsPerSpin,
            bonusSlotIDs,
            bonusMultipliers,
            i,
            rowsPerSpin,
            columnsPerSpin
        );
        _transferToBankroll(tokenAddress, game.wager * game.numBets);
        delete (slotsIDs[requestId]);
        delete (slotsGames[playerAddress]);
        if (payout != 0) {
            _transferPayout(playerAddress, payout, tokenAddress);
        }
    }

    /**
     * @dev function to set the slots multipliers, can only be called at deploy time
     * @param _multipliers array of all multipliers with multiplier above 0
     * @param _outcomeNum array of slot outcome that corresponds to the multiplier
     * @param _numOutcomes total number of outcomes, example with 7 possibilities for each slot and 3 slots number = 7^3
     */
    function _setSlotsMultipliers(
        uint16[] memory _multipliers,
        uint16[] memory _outcomeNum,
        uint16 _numOutcomes
    ) internal {
        for (uint16 i = 0; i < numOutcomes; i++) {
            delete (slotsMultipliers[i]);
        }

        numOutcomes = _numOutcomes;
        for (uint16 i = 0; i < _multipliers.length; i++) {
            slotsMultipliers[_outcomeNum[i]] = _multipliers[i];
        }
    }

    function _setGridConfig(uint8 _rowsPerSpin, uint8 _columnsPerSpin, bool _rowSpecific) internal {
        require(_rowsPerSpin > 0 && _rowsPerSpin <= MAX_ROWS_PER_SPIN, "Invalid rows per spin");
        require(_columnsPerSpin > 0 && _columnsPerSpin <= MAX_COLUMNS_PER_SPIN, "Invalid columns per spin");
        rowsPerSpin = _rowsPerSpin;
        columnsPerSpin = _columnsPerSpin;
        rowSpecific = _rowSpecific;
    }

    function _accumulateSymbolCounts(uint8[] memory counts, uint16 outcome, uint8 base) internal view {
        uint16 v = outcome;
        for (uint8 i = 0; i < columnsPerSpin; i++) {
            uint8 symbol = uint8(v % base);
            counts[symbol] += 1;
            v /= base;
        }
    }

    function _symbolKindMultiplier(uint8 symbol, uint8 tier, uint8 base) internal view returns (uint16) {
        uint16 canonicalOutcome = _buildCanonicalOutcome(symbol, tier, base);
        return slotsMultipliers[canonicalOutcome];
    }

    function _symbolKindBonusMultiplier(uint8 symbol, uint8 tier, uint8 base) internal view returns (uint16) {
        uint16 canonicalOutcome = _buildCanonicalOutcome(symbol, tier, base);
        return slotsBonusMultipliers[canonicalOutcome];
    }

    function _symbolKindBonusRounds(uint8 symbol, uint8 tier, uint8 base) internal view returns (uint8) {
        uint16 canonicalOutcome = _buildCanonicalOutcome(symbol, tier, base);
        return slotsBonusRounds[canonicalOutcome];
    }

    function _buildCanonicalOutcome(uint8 symbol, uint8 matchCount, uint8 base) internal view returns (uint16) {
        uint16 outcome;
        uint16 factor = 1;
        uint8 filler = 0;

        for (uint8 i = 0; i < columnsPerSpin; i++) {
            uint8 chosen;
            if (i < matchCount) {
                chosen = symbol;
            } else {
                while (filler == symbol) {
                    filler = (filler + 1) % base;
                }
                chosen = filler;
                filler = (filler + 1) % base;
            }

            outcome += uint16(chosen) * factor;
            factor *= uint16(base);
        }

        return outcome;
    }

    /**
     * @dev function to set the slots bonus multipliers and bonus rounds, can only be called at deploy time
     * @param _bonusMultipliers array of bonus multipliers
     * @param _bonusRounds array of bonus rounds (free spins)
     * @param _bonusOutcomeNum array of slot outcomes that correspond to bonus configs
     */
    function _setSlotsBonuses(
        uint16[] memory _bonusMultipliers,
        uint8[] memory _bonusRounds,
        uint16[] memory _bonusOutcomeNum
    ) internal {
        require(
            _bonusMultipliers.length == _bonusRounds.length &&
            _bonusRounds.length == _bonusOutcomeNum.length,
            "Invalid bonus config"
        );

        for (uint16 i = 0; i < _bonusMultipliers.length; i++) {
            require(_bonusOutcomeNum[i] < numOutcomes, "Invalid bonus outcome");
            require(_bonusRounds[i] <= MAX_BONUS_ROUNDS, "Bonus rounds too high");
            slotsBonusMultipliers[_bonusOutcomeNum[i]] = _bonusMultipliers[i];
            slotsBonusRounds[_bonusOutcomeNum[i]] = _bonusRounds[i];
        }
    }

    /**
     * @dev calculates the maximum wager allowed based on the bankroll size
     */
    function _kellyWager(uint256 wager, address tokenAddress) internal view {
        uint256 balance;
        if (tokenAddress == address(0)) {
            balance = address(Bankroll()).balance;
        } else {
            balance = IERC20(tokenAddress).balanceOf(address(Bankroll()));
        }
        uint256 maxWager = (balance * 55770) / 100000000;
        if (wager > maxWager) {
            revert WagerAboveLimit(wager, maxWager);
        }
    }

    function _toDisplayOutcomeId(uint16 outcome) internal view returns (uint16) {
        uint8 rounds = slotsBonusRounds[outcome];
        if (rounds == 0) {
            return outcome;
        }

        uint16 offset = slotsBonusMultipliers[outcome] > 0
            ? BONUS_MULTIPLIER_OUTCOME_OFFSET
            : BONUS_ROUND_OUTCOME_OFFSET;

        uint256 displayId = uint256(outcome) + uint256(offset);
        if (displayId > type(uint16).max) {
            return outcome;
        }

        return uint16(displayId);
    }
}
