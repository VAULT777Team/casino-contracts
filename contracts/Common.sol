// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {IVRFCoordinatorV2Plus, VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import {IDecimalAggregator} from "@chainlink/contracts/src/v0.8/data-feeds/interfaces/IDecimalAggregator.sol";
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
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

abstract contract Common is ReentrancyGuard, VRFConsumerBaseV2Plus, ERC1155Holder {
    using SafeERC20 for IERC20;

    // ── VRF ─────────────────────────────────────────────────────────────────
    uint256 public VRFFees;
    IVRFCoordinatorV2Plus internal s_Coordinator;
    IDecimalAggregator    public  LINK_ETH_FEED;

    bytes32 internal keyHash;
    uint256 internal subscriptionId;
    uint16  internal reqConfirmations;
    uint32  internal callbackGasLimit;

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
    event WagerTransferredERC1155(address game, address token, uint256 tokenId, address player, uint256 amount);
    event FeeTransferred(address game, address player, uint256 amount);

    // ── Bankroll accessor ────────────────────────────────────────────────────
    function Bankroll() internal view returns (IBankLP) {
        (address bankroll,,,) = b_registry.getCurrentBankroll();
        return IBankLP(bankroll);
    }

    function setRegistry(address _registry) external onlyOwner {
        b_registry = IBankrollRegistry(_registry);
    }

    // ── VRF fee helpers ──────────────────────────────────────────────────────
    /// @notice Calculate the native-token VRF fee for a callback with `gasAmount` gas.
    function getVRFFee(uint256 gasAmount, uint256 l1Multiplier) public view returns (uint256 fee) {
        (, int256 answer, , , ) = LINK_ETH_FEED.latestRoundData();
        uint256 l1CostWei = (ChainSpecificUtil.getCurrentTxL1GasFees() * l1Multiplier) / 10;
        fee = tx.gasprice * gasAmount + l1CostWei + ((1e12 * uint256(answer)) / 1e18);
    }

    function _payVRFFee(uint256 gasAmount, uint256 l1Multiplier) internal returns (uint256 VRFfee) {
        VRFfee = getVRFFee(gasAmount, l1Multiplier);
        if (msg.value < VRFfee) revert InvalidValue(VRFfee, msg.value);
        _refundExcessValue(msg.value - VRFfee);
        VRFFees += VRFfee;
    }

    /// @notice Drain accumulated VRF fees to `to`. Callable only by bankroll owner.
    function transferFees(address to) external nonReentrant {
        if (msg.sender != Bankroll().getOwner()) {
            revert NotOwner(Bankroll().getOwner(), msg.sender);
        }
        uint256 fee = VRFFees;
        VRFFees = 0;
        (bool success, ) = payable(to).call{value: fee}("");
        if (!success) revert TransferFailed();
        emit FeeTransferred(address(this), to, fee);
    }

    // ── Reserve helpers ──────────────────────────────────────────────────────
    /// @dev Dynamically routes reserve call based on whether token is ERC1155.
    ///      Pass tokenId = 0 for ERC20 / native tokens.
    function _reserveMaxPayout(address tokenAddress, uint256 tokenId, uint256 maxPayout) internal {
        IBankLP bank = Bankroll();
        if (bank.isERC1155Token(tokenAddress)) {
            uint256 available = bank.getAvailableBalance(tokenAddress, tokenId);
            require(available >= maxPayout, "Insufficient bankroll for max payout");
            bank.reserveFunds(tokenAddress, tokenId, maxPayout);
        } else {
            uint256 available = bank.getAvailableBalance(tokenAddress);
            require(available >= maxPayout, "Insufficient bankroll for max payout");
            bank.reserveFunds(tokenAddress, maxPayout);
        }
    }

    /// @dev Backward-compatible overload for legacy ERC20/native callers.
    function _reserveMaxPayout(address tokenAddress, uint256 maxPayout) internal {
        _reserveMaxPayout(tokenAddress, 0, maxPayout);
    }

    function _releaseReserve(address tokenAddress, uint256 tokenId, uint256 amount) internal {
        IBankLP bank = Bankroll();
        if (bank.isERC1155Token(tokenAddress)) {
            bank.releaseFunds(tokenAddress, tokenId, amount);
        } else {
            bank.releaseFunds(tokenAddress, amount);
        }
    }

    /// @dev Backward-compatible overload for legacy ERC20/native callers.
    function _releaseReserve(address tokenAddress, uint256 amount) internal {
        _releaseReserve(tokenAddress, 0, amount);
    }

    // ── Wager transfer helpers ───────────────────────────────────────────────
    /// @dev Transfer player wager into this contract and collect the VRF fee.
    ///      For ERC20/native tokens pass tokenId = 0 — the ERC1155 path is
    ///      selected automatically based on the bankroll's token registry.
    function _transferWager(
        address tokenAddress,
        uint256 tokenId,
        uint256 wager,
        uint256 gasAmount,
        uint256 l1Multiplier,
        address msgSender
    ) internal returns (uint256 VRFfee) {
        if (wager == 0) revert ZeroWager();

        IBankLP bank = Bankroll();
        bool is1155 = bank.isERC1155Token(tokenAddress);
        if (is1155) {
            if (!bank.getIsValidWager(address(this), tokenAddress, tokenId)) revert NotApprovedBankroll();
        } else {
            if (!bank.getIsValidWager(address(this), tokenAddress)) revert NotApprovedBankroll();
        }

        (bool suspended, uint256 suspendedTime) = bank.isPlayerSuspended(msgSender);
        if (suspended) revert PlayerSuspended(suspendedTime);

        VRFfee = getVRFFee(gasAmount, l1Multiplier);

        if (tokenAddress == address(0)) {
            if (msg.value < wager + VRFfee) revert InvalidValue(wager + VRFfee, msg.value);
            _refundExcessValue(msg.value - (VRFfee + wager));
        } else if (is1155) {
            if (msg.value < VRFfee) revert InvalidValue(VRFfee, msg.value);
            IERC1155(tokenAddress).safeTransferFrom(msgSender, address(this), tokenId, wager, "");
            _refundExcessValue(msg.value - VRFfee);
        } else {
            if (msg.value < VRFfee) revert InvalidValue(VRFfee, msg.value);
            IERC20(tokenAddress).safeTransferFrom(msgSender, address(this), wager);
            _refundExcessValue(msg.value - VRFfee);
        }

        // play2earn
        uint256 playReward = bank.getPlayerReward();
        if (playReward > 0) {
            uint256 reward = bank.calculatePlayReward(tokenAddress, wager);
            if (reward > 0) bank.addPlayerReward(msgSender, reward);
        }

        VRFFees += VRFfee;

        if (is1155) {
            emit WagerTransferredERC1155(address(this), tokenAddress, tokenId, msgSender, wager);
        } else {
            emit WagerTransferred(address(this), tokenAddress, msgSender, wager);
        }
    }

    /// @dev Backward-compatible overload for legacy callers.
    function _transferWager(
        address tokenAddress,
        uint256 wager,
        uint256 gasAmount,
        address msgSender
    ) internal returns (uint256 VRFfee) {
        return _transferWager(tokenAddress, 0, wager, gasAmount, 20, msgSender);
    }

    /// @dev Push funds held in this contract into the bankroll after game resolution.
    ///      Routing (ERC20 vs ERC1155) is automatic; pass tokenId = 0 for ERC20.
    function _transferToBankroll(address tokenAddress, uint256 tokenId, uint256 amount) internal {
        IBankLP bank = Bankroll();
        bool is1155  = bank.isERC1155Token(tokenAddress);

        if (tokenAddress == address(0)) {
            bool success = bank.depositEther{value: amount}();
            if (!success) revert TransferFailed();
        } else if (is1155) {
            IERC1155(tokenAddress).setApprovalForAll(address(bank), true);
            bank.deposit(tokenAddress, tokenId, amount);
        } else {
            IERC20(tokenAddress).approve(address(bank), amount);
            bank.deposit(tokenAddress, amount);
        }

        if (is1155) {
            emit WagerTransferredERC1155(address(this), tokenAddress, tokenId, msg.sender, amount);
        } else {
            emit WagerTransferred(address(this), tokenAddress, msg.sender, amount);
        }
    }

    /// @dev Backward-compatible overload for legacy ERC20/native callers.
    function _transferToBankroll(address tokenAddress, uint256 amount) internal {
        _transferToBankroll(tokenAddress, 0, amount);
    }

    /// @dev Request the bankroll to pay out `payout` to `player`.
    ///      Pass tokenId = 0 for ERC20 / native tokens.
    function _transferPayout(address player, uint256 payout, address tokenAddress, uint256 tokenId) internal {
        if (Bankroll().isERC1155Token(tokenAddress)) {
            Bankroll().transferPayout(player, payout, tokenAddress, tokenId);
        } else {
            Bankroll().transferPayout(player, payout, tokenAddress);
        }
    }

    /// @dev Backward-compatible overload for legacy ERC20/native callers.
    function _transferPayout(address player, uint256 payout, address tokenAddress) internal {
        _transferPayout(player, payout, tokenAddress, 0);
    }

    /// @dev Refund a player directly from this contract (used in timeout/cancel flows).
    ///      Pass tokenId = 0 for ERC20 / native tokens.
    function _refundPlayer(address player, address tokenAddress, uint256 tokenId, uint256 amount) internal {
        if (tokenAddress == address(0)) {
            (bool success, ) = payable(player).call{value: amount}("");
            if (!success) revert TransferFailed();
        } else if (Bankroll().isERC1155Token(tokenAddress)) {
            IERC1155(tokenAddress).safeTransferFrom(address(this), player, tokenId, amount, "");
        } else {
            IERC20(tokenAddress).safeTransfer(player, amount);
        }
    }

    // ── PvP helpers (ERC20-only) ─────────────────────────────────────────────
    function _transferWagerPvPNoVRF(address tokenAddress, uint256 wager) internal {
        if (!Bankroll().getIsValidWager(address(this), tokenAddress)) revert NotApprovedBankroll();
        if (tokenAddress == address(0)) {
            if (msg.value != wager) revert InvalidValue(wager, msg.value);
        } else {
            IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), wager);
        }
    }

    function _transferWagerPvP(address tokenAddress, uint256 wager, uint256 gasAmount) internal {
        if (!Bankroll().getIsValidWager(address(this), tokenAddress)) revert NotApprovedBankroll();
        uint256 VRFfee = getVRFFee(gasAmount, 20);
        if (tokenAddress == address(0)) {
            if (msg.value < wager + VRFfee) revert InvalidValue(wager + VRFfee, msg.value);
            _refundExcessValue(msg.value - (VRFfee + wager));
        } else {
            if (msg.value < VRFfee) revert InvalidValue(VRFfee, msg.value);
            IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), wager);
            _refundExcessValue(msg.value - VRFfee);
        }
        VRFFees += VRFfee;
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
