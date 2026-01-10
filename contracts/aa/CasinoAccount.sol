// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAccount} from "./interfaces/IAccount.sol";
import {IEntryPoint} from "./interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "./interfaces/PackedUserOperation.sol";

/**
 * @title CasinoAccount
 * @notice Minimal ERC-4337 smart account for calling casino game contracts.
 *
 * Flow for "sign once then backend forwards":
 * - User deploys account (or uses counterfactual initCode).
 * - User signs ONE PackedUserOperation (owner signature) to set a session key + approve USDC to paymaster.
 * - Backend holds the session key and signs subsequent PackedUserOperations, calling `execute` into game contracts.
 */
contract CasinoAccount is IAccount, Ownable {
    using ECDSA for bytes32;

    /// @dev Signature types for `PackedUserOperation.signature`.
    /// - 0x00: owner signature
    /// - 0x01: session key signature
    uint8 internal constant SIG_OWNER = 0;
    uint8 internal constant SIG_SESSION = 1;

    IEntryPoint public immutable entryPoint;

    struct SessionKeyConfig {
        bool enabled;
        uint48 validUntil; // unix seconds, 0 = no expiry
    }

    mapping(address => SessionKeyConfig) public sessionKeys;
    mapping(address => bool) public allowedTargets;

    error NotEntryPoint();
    error InvalidSignatureType(uint8 sigType);
    error InvalidSignature();
    error SessionKeyNotAllowed();
    error TargetNotAllowed(address target);
    error ExecuteFailed();

    modifier onlyEntryPoint() {
        if (msg.sender != address(entryPoint)) revert NotEntryPoint();
        _;
    }

    constructor(address _entryPoint, address _owner) {
        entryPoint = IEntryPoint(_entryPoint);
        _transferOwnership(_owner);
    }

    receive() external payable {}

    // ---------------------------
    // Admin (owner-controlled)
    // ---------------------------

    function setAllowedTarget(address target, bool allowed) external onlyOwner {
        allowedTargets[target] = allowed;
    }
    
    function setAllowedTargets(address[] calldata targets, bool allowed) external onlyOwner {
        for (uint256 i = 0; i < targets.length; i++) {
            allowedTargets[targets[i]] = allowed;
        }
    }

    function setSessionKey(address key, bool enabled, uint48 validUntil) external onlyOwner {
        sessionKeys[key] = SessionKeyConfig({enabled: enabled, validUntil: validUntil});
    }

    /// @notice Convenience: set session key and approve a token allowance in a single owner tx.
    function setupSessionAndApprove(
        address key,
        bool enabled,
        uint48 validUntil,
        address token,
        address spender,
        uint256 amount
    ) external onlyOwner {
        sessionKeys[key] = SessionKeyConfig({enabled: enabled, validUntil: validUntil});
        IERC20(token).approve(spender, amount);
    }

    // ---------------------------
    // Execution
    // ---------------------------

    function execute(address target, uint256 value, bytes calldata data) external onlyEntryPoint {
        _requireAllowedTarget(target);
        (bool ok, ) = target.call{value: value}(data);
        if (!ok) revert ExecuteFailed();
    }

    function executeBatch(address[] calldata targets, uint256[] calldata values, bytes[] calldata datas)
        external
        onlyEntryPoint
    {
        require(targets.length == datas.length && targets.length == values.length, "len");
        for (uint256 i = 0; i < targets.length; i++) {
            _requireAllowedTarget(targets[i]);
            (bool ok, ) = targets[i].call{value: values[i]}(datas[i]);
            if (!ok) revert ExecuteFailed();
        }
    }

    function _requireAllowedTarget(address target) internal view {
        if (!allowedTargets[target]) revert TargetNotAllowed(target);
    }

    // ---------------------------
    // ERC-4337 validation
    // ---------------------------

    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external override onlyEntryPoint returns (uint256 validationData) {
        _validateSig(userOp, userOpHash);

        if (missingAccountFunds != 0) {
            // top up deposit on EntryPoint if needed
            (bool success, ) = payable(msg.sender).call{value: missingAccountFunds}("");
            require(success, "funds");
        }

        // 0 means valid, no time-range
        return 0;
    }

    function _validateSig(PackedUserOperation calldata userOp, bytes32 userOpHash) internal view {
        if (userOp.signature.length < 2) revert InvalidSignature();

        uint8 sigType = uint8(userOp.signature[0]);
        bytes calldata sig = userOp.signature[1:];

        bytes32 digest = userOpHash.toEthSignedMessageHash();

        if (sigType == SIG_OWNER) {
            address recovered = ECDSA.recover(digest, sig);
            if (recovered != owner()) revert InvalidSignature();
            return;
        }

        if (sigType == SIG_SESSION) {
            address recovered = ECDSA.recover(digest, sig);
            SessionKeyConfig memory cfg = sessionKeys[recovered];
            if (!cfg.enabled) revert SessionKeyNotAllowed();
            if (cfg.validUntil != 0 && block.timestamp > cfg.validUntil) revert SessionKeyNotAllowed();

            // Restrict session key ops to only calling execute/executeBatch (and thus only allowedTargets).
            if (!_isExecuteSelector(userOp.callData)) revert SessionKeyNotAllowed();
            return;
        }

        revert InvalidSignatureType(sigType);
    }

    function _isExecuteSelector(bytes calldata callData) internal pure returns (bool) {
        if (callData.length < 4) return false;
        bytes4 sel;
        assembly {
            sel := calldataload(callData.offset)
        }
        return sel == this.execute.selector || sel == this.executeBatch.selector;
    }
}
