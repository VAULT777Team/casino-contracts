// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import "@chainlink/contracts/src/v0.8/data-feeds/interfaces/IDecimalAggregator.sol";
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "hardhat/console.sol";
import "./ChainSpecificUtil.sol";

interface IBankRoll {
    function addPlayerReward(
        address player,
        uint256 amount
    ) external;
    function minRewardPayout()      external view returns (uint256);
    function getPlayerReward()      external view returns (uint256);
    function claimRewards()         external;
    function playRewards(address)   external view returns (uint256);
    function getPlayerRewards()     external view returns (uint256);

    function setGame(address, bool) external;
    function getIsGame(address game) external view returns (bool);

    function deposit(address token, uint256 amount) external;
    function setTokenAddress(address, bool) external;
    function setWrappedAddress(address)     external;

    function getIsValidWager(
        address game,
        address tokenAddress
    ) external view returns (bool);

    function transferPayout(
        address player,
        uint256 payout,
        address token
    ) external;

    function getOwner() external view returns (address);

    function isPlayerSuspended(
        address player
    ) external view returns (bool, uint256);
}

abstract contract Common is ReentrancyGuard, VRFConsumerBaseV2Plus {
    using SafeERC20 for IERC20;

    uint256 public VRFFees;
    address internal ChainLinkVRF;
    address public _trustedForwarder;

    IDecimalAggregator      public LINK_ETH_FEED;
    IBankRoll               public Bankroll;
    IVRFCoordinatorV2Plus   internal s_Coordinator;
    
    uint256 subscriptionId  = uint256(77667707628007624636163514136218109527264531590891917311719822980101224786380);
    bytes32 keyHash         = 0x1770bdc7eec7771f7ba4ffd640f34260d7f095b79c92d34a5b2551d6f6cfd2be;
    uint16 reqConfirmations = 3;
    uint32 callbackGasLimit = 2500000;

    error NotApprovedBankroll();
    error InvalidValue(uint256 required, uint256 sent);
    error TransferFailed();
    error RefundFailed();
    error NotOwner(address want, address have);
    error ZeroWager();
    error PlayerSuspended(uint256 suspensionTime);

    event WagerTransferred(address game, address token, address player, uint256 amount);
    event FeeTransferred(address game, address player, uint256 amount);

    function setBankroll(address _bankRoll) external onlyOwner {
        Bankroll = IBankRoll(_bankRoll);
    }

    /**
     * @dev function to transfer the player wager to bankroll, and charge for VRF fee
     * , reverts if bankroll doesn't approve game or token
     * @param tokenAddress address of the token the wager is made on
     * @param wager total amount wagered
     */

    function _transferWager(
        address tokenAddress,
        uint256 wager,
        uint256 gasAmount,
        uint256 l1Multiplier,
        address msgSender
    ) internal returns (uint256 VRFfee) {
        if (wager == 0) revert ZeroWager();
        if (!Bankroll.getIsValidWager(address(this), tokenAddress)) revert NotApprovedBankroll();
        
        (bool suspended, uint256 suspendedTime) = Bankroll.isPlayerSuspended(
            msgSender
        );

        if (suspended) {
            revert PlayerSuspended(suspendedTime);
        }
        
        VRFfee = getVRFFee(gasAmount, l1Multiplier);

        if (tokenAddress == address(0)) {
            if (msg.value < wager + VRFfee) {
                revert InvalidValue(wager + VRFfee, msg.value);
            }
            _refundExcessValue(msg.value - (VRFfee + wager));
        } else {
            if (msg.value < VRFfee) {
                revert InvalidValue(VRFfee, msg.value);
            }

            IERC20(tokenAddress).safeTransferFrom(
                msgSender,
                address(this),
                wager
            );

            _refundExcessValue(msg.value - VRFfee);
        }

        // play2earn
        uint256 playReward = Bankroll.getPlayerReward();
        if(playReward > 0){
            uint256 reward = (wager * playReward) / 1000;
            Bankroll.addPlayerReward(msgSender, reward);
        }

        VRFFees += VRFfee;

        emit WagerTransferred(
            address(this),
            tokenAddress,
            msgSender,
            wager
        );
    }

    /**
     * @dev function to transfer the wager held by the game contract to the bankroll
     * @param tokenAddress address of the token to transfer
     * @param amount token amount to transfer
     */
    function _transferToBankroll(
        address tokenAddress,
        uint256 amount
    ) internal {

        if (tokenAddress == address(0)) {
            (bool success, ) = payable(address(Bankroll)).call{value: amount}(
                ""
            );
            if (!success) {
                revert RefundFailed();
            }
        } else {
            IERC20(tokenAddress).approve(address(Bankroll), amount);
            Bankroll.deposit(tokenAddress, amount);
        }

        emit WagerTransferred(
            address(this),
            tokenAddress,
            msg.sender,
            amount
        );
    }

    /**
     * @dev calculates in form of native token the fee charged by chainlink VRF
     * @return fee amount of fee user has to pay
     */
    function getVRFFee(
        uint256 gasAmount,
        uint256 l1Multiplier
    ) public view returns (uint256 fee) {
        (, int256 answer, , , ) = LINK_ETH_FEED.latestRoundData();

        uint256 l1CostWei = (ChainSpecificUtil.getCurrentTxL1GasFees() *
            l1Multiplier) / 10;


        fee =
            tx.gasprice *
            (gasAmount) +
            l1CostWei +
            ((1e12 *
                uint256(answer)) / 1e18);
    }

    /**
     * @dev returns to user the excess fee sent to pay for the VRF
     * @param refund amount to send back to user
     */
    function _refundExcessValue(uint256 refund) internal {
        if (refund == 0) {
            return;
        }
        (bool success, ) = payable(msg.sender).call{value: refund}("");
        if (!success) {
            revert RefundFailed();
        }
    }

    /**
     * @dev function to charge user for VRF
     */
    function _payVRFFee(
        uint256 gasAmount,
        uint256 l1Multiplier
    ) internal returns (uint256 VRFfee) {
        VRFfee = getVRFFee(gasAmount, l1Multiplier);
        if (msg.value < VRFfee) {
            revert InvalidValue(VRFfee, msg.value);
        }
        _refundExcessValue(msg.value - VRFfee);
        VRFFees += VRFfee;
    }

    /**
     * @dev function to transfer VRF fees acumulated in the contract to the Bankroll
     * Can only be called by owner
     */
    function transferFees(address to) external nonReentrant {
        if (msg.sender != Bankroll.getOwner()) {
            revert NotOwner(Bankroll.getOwner(), msg.sender);
        }
        uint256 fee = VRFFees;
        VRFFees = 0;
        (bool success, ) = payable(address(to)).call{value: fee}("");
        if (!success) {
            revert TransferFailed();
        }

        emit FeeTransferred(
            address(this),
            to,
            fee
        );
    }

    /**
     * @dev function to transfer wager to game contract, without charging for VRF
     * @param tokenAddress tokenAddress the wager is made on
     * @param wager wager amount
     */
    function _transferWagerPvPNoVRF(
        address tokenAddress,
        uint256 wager
    ) internal {
        if (!Bankroll.getIsValidWager(address(this), tokenAddress)) {
            revert NotApprovedBankroll();
        }
        if (tokenAddress == address(0)) {
            if (!(msg.value == wager)) {
                revert InvalidValue(wager, msg.value);
            }
        } else {
            IERC20(tokenAddress).safeTransferFrom(
                msg.sender,
                address(this),
                wager
            );
        }
    }

    /**
     * @dev function to transfer wager to game contract, including charge for VRF
     * @param tokenAddress tokenAddress the wager is made on
     * @param wager wager amount
     */
    function _transferWagerPvP(
        address tokenAddress,
        uint256 wager,
        uint256 gasAmount
    ) internal {
        if (!Bankroll.getIsValidWager(address(this), tokenAddress)) {
            revert NotApprovedBankroll();
        }

        uint256 VRFfee = getVRFFee(gasAmount, 20);
        if (tokenAddress == address(0)) {
            if (msg.value < wager + VRFfee) {
                revert InvalidValue(wager, msg.value);
            }

            _refundExcessValue(msg.value - (VRFfee + wager));
        } else {
            if (msg.value < VRFfee) {
                revert InvalidValue(VRFfee, msg.value);
            }

            IERC20(tokenAddress).safeTransferFrom(
                msg.sender,
                address(this),
                wager
            );
            _refundExcessValue(msg.value - VRFfee);
        }
        VRFFees += VRFfee;
    }

    /**
     * @dev transfers payout from the game contract to the players
     * @param player address of the player to transfer the payout to
     * @param payout amount of payout to transfer
     * @param tokenAddress address of the token that payout will be transfered
     */
    function _transferPayoutPvP(
        address player,
        uint256 payout,
        address tokenAddress
    ) internal {
        if (tokenAddress == address(0)) {
            (bool success, ) = payable(player).call{value: payout}("");
            if (!success) {
                revert TransferFailed();
            }
        } else {
            IERC20(tokenAddress).safeTransfer(player, payout);
        }
    }

    /**
     * @dev transfers house edge from game contract to bankroll
     * @param amount amount to transfer
     * @param tokenAddress address of token to transfer
     */
    function _transferHouseEdgePvP(
        uint256 amount,
        address tokenAddress
    ) internal {
        if (tokenAddress == address(0)) {
            (bool success, ) = payable(address(Bankroll)).call{value: amount}(
                ""
            );
            if (!success) {
                revert TransferFailed();
            }
        } else {
            IERC20(tokenAddress).approve(address(Bankroll), amount);
            Bankroll.deposit(tokenAddress, amount);
        }
    }

    /**
     * @dev function to request bankroll to give payout to player
     * @param player address of the player
     * @param payout amount of payout to give
     * @param tokenAddress address of the token in which to give the payout
     */
    function _transferPayout(
        address player,
        uint256 payout,
        address tokenAddress
    ) internal {
        Bankroll.transferPayout(player, payout, tokenAddress);
    }

    /**
     * @dev function to send the request for randomness to chainlink
     * @param numWords number of random numbers required
     */
    function _requestRandomWords(
        uint32 numWords
    ) internal returns (uint256 s_requestId) {
        s_requestId = s_Coordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: reqConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: true})
                ) // new parameter
            })
        );
    }

    function isTrustedForwarder(address forwarder) public view returns (bool) {
        return forwarder == _trustedForwarder;
    }

    function _msgSender() internal view returns (address ret) {
        if (msg.data.length >= 20 && isTrustedForwarder(msg.sender)) {
            // At this point we know that the sender is a trusted forwarder,
            // so we trust that the last bytes of msg.data are the verified sender address.
            // extract sender address from the end of msg.data
            assembly {
                ret := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            ret = msg.sender;
        }
    }
}
