// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {Common, VRFConfig, IBankrollRegistry, ChainSpecificUtil} from "../Common.sol";

/**
 * @title Coin flip double-or-nothing game
 * @notice A winning first flip pays 1.96x. Each successive win doubles the
 *         available payout, and the player may cash out between flips.
 */
contract CoinFlipDoubleOrNothing is Common {
    uint256 public constant FIRST_WIN_MULTIPLIER = 19_600;
    uint256 public constant MULTIPLIER_PRECISION = 10_000;
    uint8 public constant MAX_WINS = 20;

    uint64 public immutable refundCooldownBlocks;

    struct DoubleOrNothingGame {
        uint256 wager;
        uint256 currentPayout;
        uint256 reservedPayout;
        uint256 requestID;
        address tokenAddress;
        uint64 blockNumber;
        uint8 wins;
        bool isHeads;
    }

    mapping(address => DoubleOrNothingGame) private games;
    mapping(uint256 => address) private requestPlayers;

    event DoubleOrNothing_Start_Event(
        address indexed player, uint256 wager, address tokenAddress, bool isHeads, uint256 vrfFee
    );
    event DoubleOrNothing_Continue_Event(
        address indexed player, uint8 nextWin, bool isHeads, uint256 potentialPayout, uint256 vrfFee
    );
    event DoubleOrNothing_Result_Event(
        address indexed player, uint8 wins, bool outcomeHeads, bool won, uint256 availablePayout
    );
    event DoubleOrNothing_Cashout_Event(
        address indexed player, uint256 wager, uint256 payout, address tokenAddress, uint8 wins
    );
    event DoubleOrNothing_Refund_Event(address indexed player, uint256 wager, address tokenAddress, bool gameContinues);

    error AlreadyInGame();
    error NotInGame();
    error AwaitingVRF(uint256 requestID);
    error NotAwaitingVRF();
    error NoWinToCashOut();
    error MaximumWinsReached();
    error WagerAboveLimit(uint256 wager, uint256 maxWager);
    error BlockNumberTooLow(uint256 have, uint256 want);

    constructor(address _registry, VRFConfig memory vrf, uint64 _refundCooldownBlocks) Common(vrf) {
        b_registry = IBankrollRegistry(_registry);
        refundCooldownBlocks = _refundCooldownBlocks;
    }

    function DoubleOrNothing_GetState(address player) external view returns (DoubleOrNothingGame memory) {
        return games[player];
    }

    function DoubleOrNothing_StartGame(uint256 wager, address tokenAddress, bool isHeads)
        external
        payable
        nonReentrant
    {
        address player = _msgSender();
        if (games[player].wager != 0) revert AlreadyInGame();

        uint256 firstPayout = (wager * FIRST_WIN_MULTIPLIER) / MULTIPLIER_PRECISION;
        _reserveMaxPayout(tokenAddress, firstPayout);
        _kellyWager(wager, tokenAddress);
        _transferWager(tokenAddress, wager, player);

        (uint256 requestID, uint256 vrfFee) = _requestRandomWords(1, tokenAddress, player, wager);

        games[player] = DoubleOrNothingGame({
            wager: wager,
            currentPayout: 0,
            reservedPayout: firstPayout,
            requestID: requestID,
            tokenAddress: tokenAddress,
            blockNumber: uint64(ChainSpecificUtil.getBlockNumber()),
            wins: 0,
            isHeads: isHeads
        });
        requestPlayers[requestID] = player;

        emit DoubleOrNothing_Start_Event(player, wager, tokenAddress, isHeads, vrfFee);
    }

    function DoubleOrNothing_Continue(bool isHeads) external payable nonReentrant {
        address player = _msgSender();
        DoubleOrNothingGame storage game = games[player];
        if (game.wager == 0) revert NotInGame();
        if (game.requestID != 0) revert AwaitingVRF(game.requestID);
        if (game.currentPayout == 0) revert NoWinToCashOut();
        if (game.wins >= MAX_WINS) revert MaximumWinsReached();

        uint256 nextPayout = game.currentPayout * 2;
        _reserveMaxPayout(game.tokenAddress, nextPayout - game.reservedPayout);

        (uint256 requestID, uint256 vrfFee) = _requestRandomWords(1, game.tokenAddress, player, 0);

        game.reservedPayout = nextPayout;
        game.requestID = requestID;
        game.blockNumber = uint64(ChainSpecificUtil.getBlockNumber());
        game.isHeads = isHeads;
        requestPlayers[requestID] = player;

        emit DoubleOrNothing_Continue_Event(player, game.wins + 1, isHeads, nextPayout, vrfFee);
    }

    function DoubleOrNothing_CashOut() external nonReentrant {
        address player = _msgSender();
        DoubleOrNothingGame storage game = games[player];
        if (game.wager == 0) revert NotInGame();
        if (game.requestID != 0) revert AwaitingVRF(game.requestID);
        if (game.currentPayout == 0) revert NoWinToCashOut();

        _cashOut(player, game);
    }

    function DoubleOrNothing_Refund() external nonReentrant {
        address player = _msgSender();
        DoubleOrNothingGame storage game = games[player];
        if (game.wager == 0) revert NotInGame();
        if (game.requestID == 0) revert NotAwaitingVRF();

        uint256 currentBlock = ChainSpecificUtil.getBlockNumber();
        uint256 refundBlock = game.blockNumber + refundCooldownBlocks;
        if (refundBlock > currentBlock) {
            revert BlockNumberTooLow(currentBlock, refundBlock);
        }

        delete requestPlayers[game.requestID];

        if (game.wins == 0) {
            uint256 wager = game.wager;
            address tokenAddress = game.tokenAddress;
            _releaseReserve(tokenAddress, game.reservedPayout);
            delete games[player];
            _refundPlayer(player, tokenAddress, wager);
            emit DoubleOrNothing_Refund_Event(player, wager, tokenAddress, false);
            return;
        }

        _releaseReserve(game.tokenAddress, game.reservedPayout - game.currentPayout);
        game.reservedPayout = game.currentPayout;
        game.requestID = 0;

        emit DoubleOrNothing_Refund_Event(player, 0, game.tokenAddress, true);
    }

    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        address player = requestPlayers[requestId];
        if (player == address(0)) revert();

        DoubleOrNothingGame storage game = games[player];
        bool outcomeHeads = randomWords[0] % 2 == 1;
        bool won = outcomeHeads == game.isHeads;

        delete requestPlayers[requestId];

        if (!won) {
            uint256 wager = game.wager;
            uint256 reservedPayout = game.reservedPayout;
            address tokenAddress = game.tokenAddress;
            uint8 wins = game.wins;

            _releaseReserve(tokenAddress, reservedPayout);
            delete games[player];
            _transferToBankroll(tokenAddress, wager);

            emit DoubleOrNothing_Result_Event(player, wins, outcomeHeads, false, 0);
            return;
        }

        game.wins += 1;
        game.currentPayout = game.reservedPayout;
        game.requestID = 0;

        emit DoubleOrNothing_Result_Event(player, game.wins, outcomeHeads, true, game.currentPayout);

        if (game.wins == MAX_WINS) {
            _cashOut(player, game);
        }
    }

    function _cashOut(address player, DoubleOrNothingGame storage game) internal {
        uint256 wager = game.wager;
        uint256 payout = game.currentPayout;
        address tokenAddress = game.tokenAddress;
        uint8 wins = game.wins;

        _releaseReserve(tokenAddress, game.reservedPayout);
        delete games[player];
        _transferToBankroll(tokenAddress, wager);
        _transferPayout(player, payout, tokenAddress);

        emit DoubleOrNothing_Cashout_Event(player, wager, payout, tokenAddress, wins);
    }

    function _kellyWager(uint256 wager, address tokenAddress) internal view {
        uint256 balance = Bankroll().getAvailableBalance(tokenAddress);
        uint256 maxWager = (balance * 51) / 10_000;
        if (wager > maxWager) revert WagerAboveLimit(wager, maxWager);
    }
}
