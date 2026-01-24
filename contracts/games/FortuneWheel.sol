// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {
    Common, IBankLP, IBankrollRegistry,
    ChainSpecificUtil,
    IERC20, SafeERC20,
    VRFConsumerBaseV2Plus, IVRFCoordinatorV2Plus,
    IDecimalAggregator
} from "../Common.sol";

/**
 * @title Fortune Wheel game, players spin a wheel for a multiplier payout
 */

contract FortuneWheel is Common {
    using SafeERC20 for IERC20;

    constructor(
        address _registry,
        address _vrf,
        address link_eth_feed
    ) VRFConsumerBaseV2Plus(_vrf) {
        b_registry      = IBankrollRegistry(_registry);
        ChainLinkVRF    = _vrf;
        s_Coordinator   = IVRFCoordinatorV2Plus(_vrf);
        LINK_ETH_FEED   = IDecimalAggregator(link_eth_feed);
    }

    uint16 private constant SEGMENTS = 24;
    uint32 private constant BP = 10_000;
    uint32 private constant MAX_MULTIPLIER_BP = 100_000; // 10.0x

    function _multiplierBp(uint256 segment) internal pure returns (uint32) {
        if (segment < 18) return 0;
        if (segment < 22) return 20_000;
        if (segment == 22) return 50_000;
        return 100_000;
    }

    struct FortuneWheelGame {
        uint256 wager;
        uint256 requestID;
        address tokenAddress;
        uint64 blockNumber;
        uint256 maxPayout;
    }

    mapping(address => FortuneWheelGame) fortuneWheelGames;
    mapping(uint256 => address) fortuneWheelIDs;

    /**
     * @dev event emitted at the start of the game
     * @param playerAddress address of the player that made the bet
     * @param wager wagered amount
     * @param tokenAddress address of token the wager was made, 0 address is considered the native coin
     */
    event FortuneWheel_Play_Event(
        address indexed playerAddress,
        uint256 wager,
        address tokenAddress,
        uint256 VRFFee
    );

    /**
     * @dev event emitted by the VRF callback with the bet results
     * @param playerAddress address of the player that made the bet
     * @param wager wager amount
     * @param payout total payout transfered to the player
     * @param tokenAddress address of token the wager was made and payout, 0 address is considered the native coin
     * @param segment resulting wheel segment
     * @param multiplierBps multiplier in basis points
     */
    event FortuneWheel_Outcome_Event(
        address indexed playerAddress,
        uint256 wager,
        uint256 payout,
        address tokenAddress,
        uint8 segment,
        uint32 multiplierBps
    );

    /**
     * @dev event emitted when a refund is done in fortune wheel
     * @param player address of the player reciving the refund
     * @param wager amount of wager that was refunded
     * @param tokenAddress address of token the refund was made in
     */
    event FortuneWheel_Refund_Event(
        address indexed player,
        uint256 wager,
        address tokenAddress
    );

    error WagerAboveLimit(uint256 wager, uint256 maxWager);
    error AwaitingVRF(uint256 requestID);
    error NotAwaitingVRF();
    error BlockNumberTooLow(uint256 have, uint256 want);

    /**
     * @dev function to get current request player is await from VRF, returns 0 if none
     * @param player address of the player to get the state
     */
    function FortuneWheel_GetState(
        address player
    ) external view returns (FortuneWheelGame memory) {
        return (fortuneWheelGames[player]);
    }

    /**
     * @dev Function to play Fortune Wheel, takes the user wager saves bet parameters and makes a request to the VRF
     * @param wager wager amount
     * @param tokenAddress address of token to bet, 0 address is considered the native coin
     */
    function FortuneWheel_Play(
        uint256 wager,
        address tokenAddress
    ) external payable nonReentrant {
        address msgSender = _msgSender();
        if (fortuneWheelGames[msgSender].requestID != 0) {
            revert AwaitingVRF(fortuneWheelGames[msgSender].requestID);
        }

        uint256 maxPayout = (wager * MAX_MULTIPLIER_BP) / BP;

        _reserveMaxPayout(tokenAddress, maxPayout);

        _kellyWager(wager, tokenAddress);
        uint256 fee = _transferWager(
            tokenAddress,
            wager,
            700000,
            22,
            msgSender
        );

        uint256 id = _requestRandomWords(1);

        fortuneWheelGames[msgSender] = FortuneWheelGame({
            requestID: id,
            wager: wager,
            tokenAddress: tokenAddress,
            blockNumber: uint64(ChainSpecificUtil.getBlockNumber()),
            maxPayout: maxPayout
        });

        fortuneWheelIDs[id] = msgSender;

        emit FortuneWheel_Play_Event(
            msgSender,
            wager,
            tokenAddress,
            fee
        );
    }

    /**
     * @dev Function to refund user in case of VRF request failling
     */
    function FortuneWheel_Refund() external nonReentrant {
        address msgSender = _msgSender();
        FortuneWheelGame storage game = fortuneWheelGames[msgSender];
        if (game.requestID == 0) {
            revert NotAwaitingVRF();
        }
        if (game.blockNumber + 200 > uint64(ChainSpecificUtil.getBlockNumber())) {
            revert BlockNumberTooLow(ChainSpecificUtil.getBlockNumber(), game.blockNumber + 200);
        }

        uint256 wager = game.wager;
        address tokenAddress = game.tokenAddress;

        _releaseReserve(game.tokenAddress, game.maxPayout);

        delete (fortuneWheelIDs[game.requestID]);
        delete (fortuneWheelGames[msgSender]);

        if (tokenAddress == address(0)) {
            (bool success, ) = payable(msgSender).call{value: wager}("");
            if (!success) {
                revert TransferFailed();
            }
        } else {
            IERC20(tokenAddress).safeTransfer(msgSender, wager);
        }
        emit FortuneWheel_Refund_Event(msgSender, wager, tokenAddress);
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        address playerAddress = fortuneWheelIDs[requestId];
        if (playerAddress == address(0)) revert();
        FortuneWheelGame storage game = fortuneWheelGames[playerAddress];

        address tokenAddress = game.tokenAddress;

        uint256 segment = randomWords[0] % SEGMENTS;
        uint32 multiplierBps = _multiplierBp(segment);
        uint256 payout = (game.wager * multiplierBps) / BP;

        _releaseReserve(tokenAddress, game.maxPayout);

        emit FortuneWheel_Outcome_Event(
            playerAddress,
            game.wager,
            payout,
            tokenAddress,
            uint8(segment),
            multiplierBps
        );
        _transferToBankroll(tokenAddress, game.wager);
        delete (fortuneWheelIDs[requestId]);
        delete (fortuneWheelGames[playerAddress]);
        if (payout != 0) {
            _transferPayout(playerAddress, payout, tokenAddress);
        }
    }

    /**
     * @dev calculates the maximum wager allowed based on the bankroll size
     */
    function _kellyWager(uint256 wager, address tokenAddress) internal view {
        uint256 balance = Bankroll().getAvailableBalance(tokenAddress);
        uint256 maxWager = (balance * 1122448) / 100000000;

        if (wager > maxWager) {
            revert WagerAboveLimit(wager, maxWager);
        }
    }
}