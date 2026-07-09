// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

function _singleActionArray(bytes32 action) pure returns (bytes32[] memory actions) {
    actions = new bytes32[](1);
    actions[0] = action;
}

function _sharedVipClaimActions() pure returns (bytes32[] memory actions) {
    actions = new bytes32[](7);
    actions[0] = keccak256(bytes("VIP_DAILY_CLAIM"));
    actions[1] = keccak256(bytes("VIP_WEEKLY_CLAIM"));
    actions[2] = keccak256(bytes("VIP_MONTHLY_CLAIM"));
    actions[3] = keccak256(bytes("VIP_RELOAD_CLAIM"));
    actions[4] = keccak256(bytes("VIP_RAKEBACK_CLAIM"));
    actions[5] = keccak256(bytes("VIP_RANK_UP_BONUS_CLAIM"));
    actions[6] = keccak256(bytes("REFERRAL_REWARD_CLAIM"));
}

contract VipRewardVault is Ownable {
    using ECDSA for bytes32;
    using SafeERC20 for IERC20;

    address public backendSigner;
    mapping(address => mapping(uint256 => bool)) public usedNonces;
    mapping(bytes32 => bool) public allowedClaimActions;

    event BackendSignerUpdated(address indexed oldSigner, address indexed newSigner);
    event ClaimActionUpdated(bytes32 indexed action, bool enabled);
    event RewardFunded(address indexed token, uint256 amount);
    event RewardWithdrawn(address indexed token, address indexed recipient, uint256 amount);
    event EmergencyWithdrawal(address indexed token, address indexed recipient, uint256 amount);
    event RewardClaimed(
        address indexed player,
        address indexed token,
        uint256 amount,
        uint256 periodStart,
        uint256 periodEnd
    );

    error BackendSignerNotSet();
    error InvalidSignature();
    error SignatureExpired(uint256 deadline, uint256 nowTime);
    error NonceAlreadyUsed(uint256 nonce);
    error UnsupportedClaimAction(bytes32 action);

    constructor(address _backendSigner, bytes32[] memory initialActions) {
        require(_backendSigner != address(0), "Invalid signer");
        backendSigner = _backendSigner;
        emit BackendSignerUpdated(address(0), _backendSigner);

        for (uint256 i = 0; i < initialActions.length; i++) {
            _setClaimAction(initialActions[i], true);
        }
    }

    receive() external payable {}

    function setBackendSigner(address signer) external onlyOwner {
        require(signer != address(0), "Invalid signer");
        address oldSigner = backendSigner;
        backendSigner = signer;
        emit BackendSignerUpdated(oldSigner, signer);
    }

    function setClaimAction(bytes32 action, bool enabled) external onlyOwner {
        _setClaimAction(action, enabled);
    }

    function fundRewards(address token, uint256 amount) external payable onlyOwner {
        require(amount > 0, "Zero amount");

        if (token == address(0)) {
            require(msg.value == amount, "ETH mismatch");
        } else {
            require(msg.value == 0, "Unexpected ETH");
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }

        emit RewardFunded(token, amount);
    }

    function withdrawRewards(address token, uint256 amount, address recipient) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Zero amount");

        _transferOut(token, recipient, amount);
        emit RewardWithdrawn(token, recipient, amount);
    }

    function emergencyWithdraw(address token, uint256 amount, address recipient) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Zero amount");

        _transferOut(token, recipient, amount);
        emit EmergencyWithdrawal(token, recipient, amount);
    }

    function claim(
        bytes32 action,
        address player,
        address token,
        uint256 amount,
        uint256 periodStart,
        uint256 periodEnd,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        require(amount > 0, "Zero amount");
        if (backendSigner == address(0)) revert BackendSignerNotSet();
        if (block.timestamp > deadline) revert SignatureExpired(deadline, block.timestamp);
        if (usedNonces[player][nonce]) revert NonceAlreadyUsed(nonce);
        if (!allowedClaimActions[action]) revert UnsupportedClaimAction(action);

        bytes32 digest = _hashClaim(
            action,
            player,
            token,
            amount,
            periodStart,
            periodEnd,
            nonce,
            deadline
        );

        address recovered = digest.toEthSignedMessageHash().recover(signature);
        if (recovered != backendSigner) revert InvalidSignature();

        usedNonces[player][nonce] = true;
        _transferOut(token, player, amount);

        emit RewardClaimed(player, token, amount, periodStart, periodEnd);
    }

    function _hashClaim(
        bytes32 action,
        address player,
        address token,
        uint256 amount,
        uint256 periodStart,
        uint256 periodEnd,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                address(this),
                block.chainid,
                action,
                player,
                token,
                amount,
                periodStart,
                periodEnd,
                nonce,
                deadline
            )
        );
    }

    function _setClaimAction(bytes32 action, bool enabled) internal {
        require(action != bytes32(0), "Invalid action");
        allowedClaimActions[action] = enabled;
        emit ClaimActionUpdated(action, enabled);
    }

    function _transferOut(address token, address recipient, uint256 amount) internal {
        if (token == address(0)) {
            (bool success, ) = payable(recipient).call{value: amount}("");
            require(success, "ETH transfer failed");
            return;
        }

        IERC20(token).safeTransfer(recipient, amount);
    }
}

contract WeeklyRakebackVault is VipRewardVault {
    constructor(address backendSigner_)
        VipRewardVault(backendSigner_, _singleActionArray(keccak256(bytes("VIP_WEEKLY_CLAIM"))))
    {}
}

contract ReloadClaimVault is VipRewardVault {
    constructor(address backendSigner_)
        VipRewardVault(backendSigner_, _singleActionArray(keccak256(bytes("VIP_RELOAD_CLAIM"))))
    {}
}

contract SharedVipRewardVault is VipRewardVault {
    constructor(address backendSigner_)
        VipRewardVault(backendSigner_, _sharedVipClaimActions())
    {}
}
