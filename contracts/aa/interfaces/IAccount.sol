// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {PackedUserOperation} from "./PackedUserOperation.sol";

/**
 * @dev Minimal ERC-4337 account interface (EntryPoint v0.7-style).
 */
interface IAccount {
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external returns (uint256 validationData);
}
