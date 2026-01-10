// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

/**
 * @dev ERC-4337 v0.7-style packed UserOperation struct.
 * Matches https://github.com/eth-infinitism/account-abstraction/blob/v0.7.0/contracts/interfaces/PackedUserOperation.sol
 */
struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    bytes32 gasFees;
    bytes paymasterAndData;
    bytes signature;
}
