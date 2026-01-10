// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {PackedUserOperation} from "./PackedUserOperation.sol";

/**
 * @dev Minimal ERC-4337 paymaster interface (EntryPoint v0.7-style).
 */
interface IPaymaster {
    enum PostOpMode {
        opSucceeded,
        opReverted,
        postOpReverted
    }

    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external returns (bytes memory context, uint256 validationData);

    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external;
}
