// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

/// @notice Distributes native currency from any caller to multiple recipients.
/// @dev Batches are atomic and the contract never retains ordinary funding deposits.
contract BatchNativeFunder {
    uint256 public constant MAX_RECIPIENTS = 100;

    uint256 private unlocked = 1;

    error EmptyRecipients();
    error TooManyRecipients(uint256 count);
    error ZeroRecipient(uint256 index);
    error DuplicateRecipient(address recipient);
    error InsufficientValue(uint256 value, uint256 recipientCount);
    error LengthMismatch();
    error InvalidAmount(uint256 index);
    error IncorrectValue(uint256 expected, uint256 actual);
    error NativeTransferFailed(uint256 index, address recipient, uint256 amount);
    error Reentrancy();

    event NativeFunded(
        address indexed funder,
        address indexed recipient,
        uint256 indexed index,
        uint256 amount
    );
    event NativeBatchFunded(address indexed funder, uint256 recipientCount, uint256 totalAmount);

    modifier nonReentrant() {
        if (unlocked != 1) revert Reentrancy();
        unlocked = 2;
        _;
        unlocked = 1;
    }

    /// @notice Splits msg.value as evenly as possible across recipients.
    /// @dev The first `msg.value % recipients.length` recipients receive one extra wei.
    function splitNative(address payable[] calldata recipients) external payable nonReentrant {
        uint256 length = _validateRecipients(recipients);
        if (msg.value < length) revert InsufficientValue(msg.value, length);

        uint256 amountEach = msg.value / length;
        uint256 remainder = msg.value % length;
        for (uint256 i; i < length; ++i) {
            uint256 amount = amountEach + (i < remainder ? 1 : 0);
            _send(recipients[i], amount, i);
        }

        emit NativeBatchFunded(msg.sender, length, msg.value);
    }

    /// @notice Sends explicit native-currency amounts to each recipient.
    function fundNative(
        address payable[] calldata recipients,
        uint256[] calldata amounts
    ) external payable nonReentrant {
        uint256 length = _validateRecipients(recipients);
        if (length != amounts.length) revert LengthMismatch();

        uint256 total;
        for (uint256 i; i < length; ++i) {
            uint256 amount = amounts[i];
            if (amount == 0) revert InvalidAmount(i);
            total += amount;
        }
        if (msg.value != total) revert IncorrectValue(total, msg.value);

        for (uint256 i; i < length; ++i) {
            _send(recipients[i], amounts[i], i);
        }

        emit NativeBatchFunded(msg.sender, length, total);
    }

    function _validateRecipients(address payable[] calldata recipients) private pure returns (uint256 length) {
        length = recipients.length;
        if (length == 0) revert EmptyRecipients();
        if (length > MAX_RECIPIENTS) revert TooManyRecipients(length);

        for (uint256 i; i < length; ++i) {
            address recipient = recipients[i];
            if (recipient == address(0)) revert ZeroRecipient(i);
            for (uint256 j; j < i; ++j) {
                if (recipients[j] == recipient) revert DuplicateRecipient(recipient);
            }
        }
    }

    function _send(address payable recipient, uint256 amount, uint256 index) private {
        (bool sent,) = recipient.call{value: amount}("");
        if (!sent) revert NativeTransferFailed(index, recipient, amount);
        emit NativeFunded(msg.sender, recipient, index, amount);
    }
}
