// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {
    Common, IBankrollRegistry,
    ChainSpecificUtil,
    IERC20, SafeERC20,
    VRFConsumerBaseV2Plus, IVRFCoordinatorV2Plus,
    IDecimalAggregator
} from "./Common.sol";

/**
 * @title keno game, players select numbers and get paid based on how many match the drawn numbers
 */
contract Keno is Common {
    using SafeERC20 for IERC20;

    constructor(
        address _registry,
        address _vrf,
        address link_eth_feed,
        address _forwarder
    ) VRFConsumerBaseV2Plus(_vrf) {
        b_registry      = IBankrollRegistry(_registry);
        ChainLinkVRF    = _vrf;
        s_Coordinator   = IVRFCoordinatorV2Plus(_vrf);
        LINK_ETH_FEED   = IDecimalAggregator(link_eth_feed);
        _trustedForwarder = _forwarder;
        
        // set multipliers for different spot counts and hits
        _setKenoMultipliers();
    }

    struct KenoGame {
        uint256 wager;
        uint256 stopGain;
        uint256 stopLoss;
        uint256 requestID;
        address tokenAddress;
        uint64 blockNumber;
        uint32 numBets;
        uint8 spotsSelected;
        uint8[10] selectedNumbers; // max 10 spots
    }

    mapping(address => KenoGame) kenoGames;
    mapping(uint256 => address) kenoIDs;
    mapping(uint8 => mapping(uint8 => uint256)) kenoMultipliers; // [spots][hits] = multiplier

    event Keno_Play_Event(
        address indexed playerAddress,
        uint256 wager,
        address tokenAddress,
        uint8 spotsSelected,
        uint8[10] selectedNumbers,
        uint32 numBets,
        uint256 stopGain,
        uint256 stopLoss,
        uint256 VRFFee
    );

    event Keno_Outcome_Event(
        address indexed playerAddress,
        uint256 wager,
        uint256 payout,
        address tokenAddress,
        uint8[] drawnNumbers,
        uint8[] hits,
        uint256[] payouts,
        uint32 numGames
    );

    event Keno_Refund_Event(
        address indexed player,
        uint256 wager,
        address tokenAddress
    );

    error AwaitingVRF(uint256 requestID);
    error InvalidSpotsSelected(uint8 spots);
    error InvalidNumberSelected(uint8 number);
    error DuplicateNumber(uint8 number);
    error InvalidNumBets(uint256 maxNumBets);
    error WagerAboveLimit(uint256 wager, uint256 maxWager);
    error NotAwaitingVRF();
    error BlockNumberTooLow(uint256 have, uint256 want);

    function Keno_GetState(
        address player
    ) external view returns (KenoGame memory) {
        return kenoGames[player];
    }

    function Keno_GetMultipliers() external view returns (uint256[11][11] memory multipliers) {
        for (uint8 spots = 1; spots <= 10; spots++) {
            for (uint8 hits = 0; hits <= spots; hits++) {
                multipliers[spots][hits] = kenoMultipliers[spots][hits];
            }
        }
        return multipliers;
    }

    function Keno_Play(
        uint256 wager,
        address tokenAddress,
        uint8 spotsSelected,
        uint8[10] calldata selectedNumbers,
        uint32 numBets,
        uint256 stopGain,
        uint256 stopLoss
    ) external payable nonReentrant {
        address msgSender = _msgSender();
        
        if (spotsSelected < 1 || spotsSelected > 10) {
            revert InvalidSpotsSelected(spotsSelected);
        }
        if (kenoGames[msgSender].requestID != 0) {
            revert AwaitingVRF(kenoGames[msgSender].requestID);
        }
        if (!(numBets > 0 && numBets <= 100)) {
            revert InvalidNumBets(100);
        }

        // validate selected numbers
        for (uint8 i = 0; i < spotsSelected; i++) {
            if (selectedNumbers[i] < 1 || selectedNumbers[i] > 80) {
                revert InvalidNumberSelected(selectedNumbers[i]);
            }
            // check for duplicates
            for (uint8 j = i + 1; j < spotsSelected; j++) {
                if (selectedNumbers[i] == selectedNumbers[j]) {
                    revert DuplicateNumber(selectedNumbers[i]);
                }
            }
        }

        _kellyWager(wager, tokenAddress, spotsSelected);
        uint256 fee = _transferWager(
            tokenAddress,
            wager * numBets,
            1000000,
            25,
            msgSender
        );

        uint256 id = _requestRandomWords(numBets);

        KenoGame storage game = kenoGames[msgSender];
        game.wager = wager;
        game.stopGain = stopGain;
        game.stopLoss = stopLoss;
        game.requestID = id;
        game.tokenAddress = tokenAddress;
        game.blockNumber = uint64(ChainSpecificUtil.getBlockNumber());
        game.numBets = numBets;
        game.spotsSelected = spotsSelected;
        
        for (uint8 i = 0; i < spotsSelected; i++) {
            game.selectedNumbers[i] = selectedNumbers[i];
        }

        kenoIDs[id] = msgSender;

        emit Keno_Play_Event(
            msgSender,
            wager,
            tokenAddress,
            spotsSelected,
            selectedNumbers,
            numBets,
            stopGain,
            stopLoss,
            fee
        );
    }

    function Keno_Refund() external nonReentrant {
        address msgSender = _msgSender();
        KenoGame storage game = kenoGames[msgSender];
        
        if (game.requestID == 0) {
            revert NotAwaitingVRF();
        }
        if (game.blockNumber + 200 > uint64(ChainSpecificUtil.getBlockNumber())) {
            revert BlockNumberTooLow(uint64(ChainSpecificUtil.getBlockNumber()), game.blockNumber + 200);
        }

        uint256 wager = game.wager * game.numBets;
        address tokenAddress = game.tokenAddress;

        delete kenoIDs[game.requestID];
        delete kenoGames[msgSender];

        if (tokenAddress == address(0)) {
            (bool success, ) = payable(msgSender).call{value: wager}("");
            if (!success) {
                revert TransferFailed();
            }
        } else {
            IERC20(tokenAddress).safeTransfer(msgSender, wager);
        }
        
        emit Keno_Refund_Event(msgSender, wager, tokenAddress);
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        address playerAddress = kenoIDs[requestId];
        if (playerAddress == address(0)) revert();
        
        KenoGame storage game = kenoGames[playerAddress];

        uint8[] memory allHits = new uint8[](game.numBets);
        uint256[] memory payouts = new uint256[](game.numBets);
        uint8[] memory drawnNumbers = new uint8[](20 * game.numBets); // 20 numbers per game

        int256 totalValue;
        uint256 payout;
        uint32 i;

        address tokenAddress = game.tokenAddress;

        for (i = 0; i < game.numBets; i++) {
            if (totalValue >= int256(game.stopGain)) {
                break;
            }
            if (totalValue <= -int256(game.stopLoss)) {
                break;
            }

            uint8[20] memory gameDrawn = _drawKenoNumbers(randomWords[i]);
            uint8 hits = _countHits(game.selectedNumbers, game.spotsSelected, gameDrawn);
            
            // store drawn numbers for this game
            for (uint8 j = 0; j < 20; j++) {
                drawnNumbers[i * 20 + j] = gameDrawn[j];
            }
            
            allHits[i] = hits;
            uint256 multiplier = kenoMultipliers[game.spotsSelected][hits];
            payouts[i] = (game.wager * multiplier) / 100;
            payout += payouts[i];
            totalValue += int256(payouts[i]) - int256(game.wager);
        }

        payout += (game.numBets - i) * game.wager;

        emit Keno_Outcome_Event(
            playerAddress,
            game.wager,
            payout,
            tokenAddress,
            drawnNumbers,
            allHits,
            payouts,
            i
        );
        
        _transferToBankroll(tokenAddress, game.wager * game.numBets);
        delete kenoIDs[requestId];
        delete kenoGames[playerAddress];
        
        if (payout != 0) {
            _transferPayout(playerAddress, payout, tokenAddress);
        }
    }

    function _drawKenoNumbers(uint256 seed) internal pure returns (uint8[20] memory drawn) {
        uint8[80] memory pool;
        uint8 poolSize = 80;
        
        // initialize pool
        for (uint8 i = 0; i < 80; i++) {
            pool[i] = i + 1;
        }
        
        // draw 20 numbers
        for (uint8 i = 0; i < 20; i++) {
            seed = uint256(keccak256(abi.encodePacked(seed, i)));
            uint8 index = uint8(seed % poolSize);
            drawn[i] = pool[index];
            
            // remove drawn number from pool
            pool[index] = pool[poolSize - 1];
            poolSize--;
        }
        
        return drawn;
    }

    function _countHits(
        uint8[10] memory selected,
        uint8 spotsSelected,
        uint8[20] memory drawn
    ) internal pure returns (uint8 hits) {
        for (uint8 i = 0; i < spotsSelected; i++) {
            for (uint8 j = 0; j < 20; j++) {
                if (selected[i] == drawn[j]) {
                    hits++;
                    break;
                }
            }
        }
        return hits;
    }

    function _setKenoMultipliers() internal {
        // 1 spot
        kenoMultipliers[1][1] = 400; // 4x
        
        // 2 spots
        kenoMultipliers[2][2] = 1600; // 16x
        
        // 3 spots
        kenoMultipliers[3][2] = 200; // 2x
        kenoMultipliers[3][3] = 4700; // 47x
        
        // 4 spots
        kenoMultipliers[4][2] = 100; // 1x
        kenoMultipliers[4][3] = 400; // 4x
        kenoMultipliers[4][4] = 12000; // 120x
        
        // 5 spots
        kenoMultipliers[5][3] = 200; // 2x
        kenoMultipliers[5][4] = 1800; // 18x
        kenoMultipliers[5][5] = 40000; // 400x
        
        // 6 spots
        kenoMultipliers[6][3] = 100; // 1x
        kenoMultipliers[6][4] = 400; // 4x
        kenoMultipliers[6][5] = 9000; // 90x
        kenoMultipliers[6][6] = 160000; // 1600x
        
        // 7 spots
        kenoMultipliers[7][4] = 200; // 2x
        kenoMultipliers[7][5] = 2000; // 20x
        kenoMultipliers[7][6] = 40000; // 400x
        kenoMultipliers[7][7] = 500000; // 5000x
        
        // 8 spots
        kenoMultipliers[8][4] = 100; // 1x
        kenoMultipliers[8][5] = 1000; // 10x
        kenoMultipliers[8][6] = 9500; // 95x
        kenoMultipliers[8][7] = 150000; // 1500x
        kenoMultipliers[8][8] = 2500000; // 25000x
        
        // 9 spots
        kenoMultipliers[9][5] = 500; // 5x
        kenoMultipliers[9][6] = 2500; // 25x
        kenoMultipliers[9][7] = 20000; // 200x
        kenoMultipliers[9][8] = 400000; // 4000x
        kenoMultipliers[9][9] = 10000000; // 100000x
        
        // 10 spots
        kenoMultipliers[10][5] = 200; // 2x
        kenoMultipliers[10][6] = 1800; // 18x
        kenoMultipliers[10][7] = 18000; // 180x
        kenoMultipliers[10][8] = 50000; // 500x
        kenoMultipliers[10][9] = 1000000; // 10000x
        kenoMultipliers[10][10] = 10000000; // 100000x
    }

    function _kellyWager(uint256 wager, address tokenAddress, uint8 spots) internal view {
        uint256 balance;
        if (tokenAddress == address(0)) {
            balance = address(Bankroll()).balance;
        } else {
            balance = IERC20(tokenAddress).balanceOf(address(Bankroll()));
        }
        
        // conservative kelly for keno (high variance game)
        uint256 kellyFraction;
        if (spots <= 4) {
            kellyFraction = 200000; // 0.2%
        } else if (spots <= 7) {
            kellyFraction = 100000; // 0.1%
        } else {
            kellyFraction = 50000; // 0.05%
        }
        
        uint256 maxWager = (balance * kellyFraction) / 100000000;
        if (wager > maxWager) {
            revert WagerAboveLimit(wager, maxWager);
        }
    }
}