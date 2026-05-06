// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {IDecimalAggregator} from "@chainlink/contracts/src/v0.8/data-feeds/interfaces/IDecimalAggregator.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ChainSpecificUtil} from "./ChainSpecificUtil.sol";

import {IBankrollRegistry} from "./bankroll/interfaces/IBankrollRegistry.sol";
import {IBankLP} from "./bankroll/interfaces/IBankLP.sol";

/// @title IRandomnessCoordinator
/// @notice Interface for the randomness coordinator precompile
interface IRandomnessCoordinator {
    function requestRandomWords(
        bytes32 keyHash,
        uint64 subId,
        uint16 requestConfirmations,
        uint32 callbackGasLimit,
        uint32 numWords
    ) external returns (uint256 requestId);
}

/// @title RandomnessConsumer
/// @notice Base contract for randomness consumers using low-level calls
abstract contract RandomnessConsumer {
    error OnlyCoordinator(address sender);
    error RandomnessRequestFailed(bytes data);
    error InvalidRandomnessResponse(bytes data);

    event   RandomnessRequested(uint256 requestId);
    event RandomnessFullfilling(uint256 requestId, uint256[] randomWords);
    event RandomnessFulfilled(uint256 requestId, uint256[] randomWords);

    address internal constant RANDOMNESS_COORDINATOR = 0x0000000000000000000000000000000000000800;
    bytes4 internal constant REQUEST_RANDOM_WORDS_SELECTOR =
        bytes4(keccak256("requestRandomWords(bytes32,uint64,uint16,uint32,uint32)"));

    bytes32 internal s_keyHash;
    uint64 internal s_subscriptionId;
    uint16 internal s_requestConfirmations;
    uint32 internal s_callbackGasLimit;

    constructor(
        bytes32 keyHash_,
        uint64 subscriptionId_,
        uint16 requestConfirmations_,
        uint32 callbackGasLimit_
    ) {
        s_keyHash = keyHash_;
        s_subscriptionId = subscriptionId_;
        s_requestConfirmations = requestConfirmations_;
        s_callbackGasLimit = callbackGasLimit_;
    }

    /// @dev Request randomness via low-level call to precompile
    function _requestRandomWords(uint32 numWords) internal virtual returns (uint256 requestId) {
        if (numWords == 0) revert RandomnessRequestFailed("No words requested");

        // IMPORTANT: use low-level call for precompile addresses.
        // High-level interface calls may revert with "call to non-contract address"
        // because precompiles do not have deployed bytecode.
        (bool ok, bytes memory ret) = RANDOMNESS_COORDINATOR.call(
            abi.encodeWithSelector(
                REQUEST_RANDOM_WORDS_SELECTOR,
                s_keyHash,
                s_subscriptionId,
                s_requestConfirmations,
                s_callbackGasLimit,
                numWords
            )
        );

        if (!ok) revert RandomnessRequestFailed(ret);
        if (ret.length != 32) revert InvalidRandomnessResponse(ret);

        requestId = abi.decode(ret, (uint256));

        emit RandomnessRequested(requestId);
    }

    /// @notice Called by coordinator precompile; dispatches to consumer implementation
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        emit RandomnessFullfilling(requestId, randomWords);
        if (msg.sender != RANDOMNESS_COORDINATOR) revert OnlyCoordinator(msg.sender);
        _fulfillRandomWords(requestId, randomWords);
        emit RandomnessFulfilled(requestId, randomWords);
    }

    function _fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal virtual;
}

abstract contract Common is ReentrancyGuard, RandomnessConsumer, ERC1155Holder {
    using SafeERC20 for IERC20;

    address internal constant CHAINLINK_VRF_COORDINATOR = 0x0000000000000000000000000000000000000800;
    address internal ChainLinkVRF = CHAINLINK_VRF_COORDINATOR;

    IBankrollRegistry internal b_registry;
    
    uint256 subscriptionId  = 1;
    bytes32 keyHash         = 0xe9f223d7d83ec85c4f78042a4845af3a1c8df7757b4997b815ce4b8d07aca68c;
    uint16 reqConfirmations = 2;
    uint32 callbackGasLimit = 2500000;

    address public owner;

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwner(owner, msg.sender);
        }
        _;
    }

    constructor() RandomnessConsumer(
        0xe9f223d7d83ec85c4f78042a4845af3a1c8df7757b4997b815ce4b8d07aca68c,
        1,
        2,
        2500000
    ) {
        owner = msg.sender;
    }

    error NotApprovedBankroll();
    error InvalidValue(uint256 required, uint256 sent);
    error TransferFailed();
    error RefundFailed();
    error NotOwner(address want, address have);
    error ZeroWager();
    error PlayerSuspended(uint256 suspensionTime);

    event WagerTransferred(address game, address token, address player, uint256 amount);
    event WagerTransferredERC1155(address game, address token, uint256 tokenId, address player, uint256 amount);
    event FeeTransferred(address game, address player, uint256 amount);

    function Bankroll() internal view returns (IBankLP) {
        (address bankroll,,,) = b_registry.getCurrentBankroll();
        return IBankLP(bankroll);
    }

    function setRegistry(address _registry) external onlyOwner {
        b_registry = IBankrollRegistry(_registry);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    /**
     * @dev helper function to reserve max possible payout from bankroll
     * @param tokenAddress Address of the token to reserve
     * @param maxPayout Total amount to release from reserve
    */
    function _reserveMaxPayout(address tokenAddress, uint256 maxPayout) internal {
        uint256 available = Bankroll().getAvailableBalance(tokenAddress);
        require(available >= maxPayout, "Insufficient bankroll for max payout");

        Bankroll().reserveFunds(tokenAddress, maxPayout);
    }

    function _reserveMaxPayout(address tokenAddress, uint256 tokenId, uint256 maxPayout) internal {
        uint256 available = Bankroll().getAvailableBalance(tokenAddress, tokenId);
        require(available >= maxPayout, "Insufficient bankroll for max payout");

        Bankroll().reserveFunds(tokenAddress, tokenId, maxPayout);
    }

    /**
     * @dev helper function to release reserved funds from bankroll
     * @param tokenAddress address of the token to release
     * @param amount total amount to release from reserves
     */
    function _releaseReserve(address tokenAddress, uint256 amount) internal {
        Bankroll().releaseFunds(tokenAddress, amount);
    }

    function _releaseReserve(address tokenAddress, uint256 tokenId, uint256 amount) internal {
        Bankroll().releaseFunds(tokenAddress, tokenId, amount);
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
        uint256,
        address msgSender
    ) internal {
        if (wager == 0) revert ZeroWager();
        if (!Bankroll().getIsValidWager(address(this), tokenAddress)) revert NotApprovedBankroll();
        
        (bool suspended, uint256 suspendedTime) = Bankroll().isPlayerSuspended(
            msgSender
        );

        if (suspended) {
            revert PlayerSuspended(suspendedTime);
        }
        
        if (tokenAddress == address(0)) {
            if (msg.value < wager) {
                revert InvalidValue(wager, msg.value);
            }
            _refundExcessValue(msg.value - wager);
        } else {
            IERC20(tokenAddress).safeTransferFrom(
                msgSender,
                address(this),
                wager
            );
        }

        // play2earn
        uint256 playReward = Bankroll().getPlayerReward();
        if(playReward > 0){
            uint256 reward = Bankroll().calculatePlayReward(tokenAddress, wager);
            if (reward > 0) {
                Bankroll().addPlayerReward(msgSender, reward);
            }
        }

        emit WagerTransferred(
            address(this),
            tokenAddress,
            msgSender,
            wager
        );
    }

    function _transferWager(
        address tokenAddress,
        uint256 tokenId,
        uint256 wager,
        uint256,
        address msgSender
    ) internal {
        if (wager == 0) revert ZeroWager();
        if (!Bankroll().getIsValidWager(address(this), tokenAddress, tokenId)) revert NotApprovedBankroll();

        (bool suspended, uint256 suspendedTime) = Bankroll().isPlayerSuspended(
            msgSender
        );

        if (suspended) {
            revert PlayerSuspended(suspendedTime);
        }

        IERC1155(tokenAddress).safeTransferFrom(
            msgSender,
            address(this),
            tokenId,
            wager,
            ""
        );

        // play2earn
        uint256 playReward = Bankroll().getPlayerReward();
        if (playReward > 0) {
            uint256 reward = Bankroll().calculatePlayReward(tokenAddress, wager);
            if (reward > 0) {
                Bankroll().addPlayerReward(msgSender, reward);
            }
        }

        emit WagerTransferredERC1155(
            address(this),
            tokenAddress,
            tokenId,
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
            (bool success) = Bankroll().depositEther{value: amount}();
            if (!success) {
                revert TransferFailed();
            }
        } else {
            IERC20(tokenAddress).approve(address(Bankroll()), amount);
            Bankroll().deposit(tokenAddress, amount);
        }

        emit WagerTransferred(
            address(this),
            tokenAddress,
            msg.sender,
            amount
        );
    }

    function _transferToBankroll(
        address tokenAddress,
        uint256 tokenId,
        uint256 amount
    ) internal {
        IERC1155(tokenAddress).setApprovalForAll(address(Bankroll()), true);
        Bankroll().deposit(tokenAddress, tokenId, amount);

        emit WagerTransferredERC1155(
            address(this),
            tokenAddress,
            tokenId,
            msg.sender,
            amount
        );
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
     * @dev function to transfer wager to game contract, without charging for VRF
     * @param tokenAddress tokenAddress the wager is made on
     * @param wager wager amount
     */
    function _transferWagerPvPNoVRF(
        address tokenAddress,
        uint256 wager
    ) internal {
        if (!Bankroll().getIsValidWager(address(this), tokenAddress)) {
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
        uint256 wager
    ) internal {
        if (!Bankroll().getIsValidWager(address(this), tokenAddress)) {
            revert NotApprovedBankroll();
        }

        if (tokenAddress == address(0)) {
            if (msg.value < wager) {
                revert InvalidValue(wager, msg.value);
            }

            _refundExcessValue(msg.value - wager);
        } else {

            IERC20(tokenAddress).safeTransferFrom(
                msg.sender,
                address(this),
                wager
            );
        }
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
            (bool success) = Bankroll().depositEther{value: amount}();
            if (!success) {
                revert TransferFailed();
            }
        } else {
            IERC20(tokenAddress).approve(address(Bankroll()), amount);
            Bankroll().deposit(tokenAddress, amount);
        }
    }

    function _transferHouseEdgePvP(
        uint256 amount,
        address tokenAddress,
        uint256 tokenId
    ) internal {
        IERC1155(tokenAddress).setApprovalForAll(address(Bankroll()), true);
        Bankroll().deposit(tokenAddress, tokenId, amount);
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
        Bankroll().transferPayout(player, payout, tokenAddress);
    }

    function _transferPayout(
        address player,
        uint256 payout,
        address tokenAddress,
        uint256 tokenId
    ) internal {
        Bankroll().transferPayout(player, payout, tokenAddress, tokenId);
    }

    function _msgSender() internal view returns (address ret) {
        ret = msg.sender;
    }
}
