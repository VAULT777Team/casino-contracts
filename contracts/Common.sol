// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {IVRFCoordinatorV2Plus, VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import {IDecimalAggregator} from "@chainlink/contracts/src/v0.8/data-feeds/interfaces/IDecimalAggregator.sol";
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ChainSpecificUtil} from "./ChainSpecificUtil.sol";

import {IBankrollRegistry} from "./bankroll/interfaces/IBankrollRegistry.sol";
import {IBankLP} from "./bankroll/interfaces/IBankLP.sol";

/// @dev VRF 2.5 configuration. Pass this struct to every game constructor so
///      no values are hardcoded in the base contract.
struct VRFConfig {
    address coordinator;
    bytes32 keyHash;
    uint256 subId;
    uint16  reqConfirmations;
    uint32  callbackGasLimit;
    address linkEthFeed;
}

abstract contract Common is ReentrancyGuard, VRFConsumerBaseV2Plus {
    using SafeERC20 for IERC20;

    IVRFCoordinatorV2Plus internal s_Coordinator;
    IDecimalAggregator    public  LINK_ETH_FEED;

    bytes32 internal keyHash;
    uint256 internal subscriptionId;
    uint16  internal reqConfirmations;
    uint32  internal callbackGasLimit;

    uint256 internal _L1Multiplier = 20; // Multiplier applied to L1 gas cost estimation for VRF fee calculation.

    // ── Meta-tx ──────────────────────────────────────────────────────────────
    address public _trustedForwarder;

    // ── Registry ─────────────────────────────────────────────────────────────
    IBankrollRegistry internal b_registry;

    // ── Constructor ──────────────────────────────────────────────────────────
    constructor(VRFConfig memory vrf) VRFConsumerBaseV2Plus(vrf.coordinator) {
        s_Coordinator    = IVRFCoordinatorV2Plus(vrf.coordinator);
        LINK_ETH_FEED    = IDecimalAggregator(vrf.linkEthFeed);
        keyHash          = vrf.keyHash;
        subscriptionId   = vrf.subId;
        reqConfirmations = vrf.reqConfirmations;
        callbackGasLimit = vrf.callbackGasLimit;
    }

    // ── Errors ───────────────────────────────────────────────────────────────
    error NotApprovedBankroll();
    error InvalidValue(uint256 required, uint256 sent);
    error TransferFailed();
    error RefundFailed();
    error NotOwner(address want, address have);
    error ZeroWager();
    error PlayerSuspended(uint256 suspensionTime);

    // ── Events ───────────────────────────────────────────────────────────────
    event WagerTransferred(address game, address token, address player, uint256 amount);
    event FeeTransferred(address game, address player, uint256 amount);

    // ── Bankroll accessor ────────────────────────────────────────────────────
    function Bankroll() internal view returns (IBankLP) {
        (address bankroll,,,) = b_registry.getCurrentBankroll();
        return IBankLP(bankroll);
    }

    function setRegistry(address _registry) external onlyOwner {
        b_registry = IBankrollRegistry(_registry);
    }

    function setCallbackGasLimit(uint32 newLimit) external onlyOwner {
        callbackGasLimit = newLimit;
    }

    function setReqConfirmations(uint16 newReq) external onlyOwner {
        reqConfirmations = newReq;
    }

    function setL1Multiplier(uint256 newMultiplier) external onlyOwner {
        // No need for fixed-point math here since multiplier is only used as a percentage (e.g. 120 for 1.2x).
        if (newMultiplier < 10) revert InvalidValue(10, newMultiplier); // Minimum 1.0x
        _L1Multiplier = newMultiplier;
    }

    function getRequestConfig() external view returns (VRFConfig memory) {
        return VRFConfig({
            coordinator: address(s_Coordinator),
            keyHash: keyHash,
            subId: subscriptionId,
            reqConfirmations: reqConfirmations,
            callbackGasLimit: callbackGasLimit,
            linkEthFeed: address(LINK_ETH_FEED)
        });
    }

    function getL1Multiplier() external view returns (uint256) {
        return _L1Multiplier;
    }

    // ── Reserve helpers 
    /// @dev Backward-compatible overload for legacy ERC20/native callers.
    function _reserveMaxPayout(address tokenAddress, uint256 maxPayout) internal {
        Bankroll().reserveFunds(tokenAddress, maxPayout);
    }

    /// @dev Backward-compatible overload for legacy ERC20/native callers.
    function _releaseReserve(address tokenAddress, uint256 amount) internal {
        Bankroll().releaseFunds(tokenAddress, amount);
    }

    // ── Wager transfer helpers ───────────────────────────────────────────────
    /// @dev Backward-compatible overload for legacy callers.
    function _transferWager(
        address tokenAddress,
        uint256 wager,
        address msgSender
    ) internal {
        if (wager == 0) revert ZeroWager();
        if (!Bankroll().getIsValidWager(address(this), tokenAddress)) revert NotApprovedBankroll();
        (, uint256 suspendedUntil) = Bankroll().isPlayerSuspended(msgSender);
        if (suspendedUntil > block.timestamp) revert PlayerSuspended(suspendedUntil);

        if (tokenAddress != address(0)) {
            IERC20(tokenAddress).safeTransferFrom(msgSender, address(this), wager);
        }

        emit WagerTransferred(address(this), tokenAddress, msgSender, wager);
    }

    /// @dev Push funds held in this contract into the bankroll after game resolution.
    /// @dev Backward-compatible overload for legacy ERC20/native callers.
    function _transferToBankroll(address tokenAddress, uint256 amount) internal {
        if (tokenAddress == address(0)) {
            bool success = Bankroll().depositEther{value: amount}();
            if (!success) revert TransferFailed();
        } else {
            IERC20(tokenAddress).forceApprove(address(Bankroll()), amount);
            Bankroll().deposit(tokenAddress, amount);
        }
    }

    /// @dev Backward-compatible overload for legacy ERC20/native callers.
    function _transferPayout(address player, uint256 payout, address tokenAddress) internal {
        Bankroll().transferPayout(player, payout, tokenAddress);
    }

    /// @dev Refund a player directly from this contract (used in timeout/cancel flows).
    function _refundPlayer(address player, address tokenAddress, uint256 amount) internal {
        if (tokenAddress == address(0)) {
            (bool success, ) = payable(player).call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(tokenAddress).safeTransfer(player, amount);
        }
    }

    // ── PvP helpers (ERC20-only) ─────────────────────────────────────────────
    function _transferWagerPvPNoVRF(address tokenAddress, uint256 wager) internal {
        if (!Bankroll().getIsValidWager(address(this), tokenAddress)) revert NotApprovedBankroll();
        if (tokenAddress != address(0)) {
            IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), wager);
        }
    }

    function _transferWagerPvP(address tokenAddress, uint256 wager) internal {
        if (!Bankroll().getIsValidWager(address(this), tokenAddress)) revert NotApprovedBankroll();
        if (tokenAddress != address(0)) {
            IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), wager);
        }
    }

    function _transferPayoutPvP(address player, uint256 payout, address tokenAddress) internal {
        if (tokenAddress == address(0)) {
            (bool success, ) = payable(player).call{value: payout}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(tokenAddress).safeTransfer(player, payout);
        }
    }

    function _transferHouseEdgePvP(uint256 amount, address tokenAddress) internal {
        if (tokenAddress == address(0)) {
            bool success = Bankroll().depositEther{value: amount}();
            if (!success) revert TransferFailed();
        } else {
            IERC20(tokenAddress).approve(address(Bankroll()), amount);
            Bankroll().deposit(tokenAddress, amount);
        }
    }

    // ── VRF request ──────────────────────────────────────────────────────────
    function _requestRandomWords(uint32 numWords) internal returns (uint256 s_requestId) {
        s_requestId = s_Coordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash:            keyHash,
                subId:              subscriptionId,
                requestConfirmations: reqConfirmations,
                callbackGasLimit:   callbackGasLimit,
                numWords:           numWords,
                extraArgs:          VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: true})
                )
            })
        );
    }

    /// @dev Override called by VRFConsumerBaseV2Plus.rawFulfillRandomWords.
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal virtual override;

    function _refundExcessValue(uint256 refund) internal {
        if (refund == 0) return;
        (bool success, ) = payable(msg.sender).call{value: refund}("");
        if (!success) revert RefundFailed();
    }

    // ── Meta-tx ──────────────────────────────────────────────────────────────
    function isTrustedForwarder(address forwarder) public view returns (bool) {
        return forwarder == _trustedForwarder;
    }

    function _msgSender() internal view returns (address ret) {
        if (msg.data.length >= 20 && isTrustedForwarder(msg.sender)) {
            assembly {
                ret := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            ret = msg.sender;
        }
    }
}
