// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {PackedUserOperation} from "./PackedUserOperation.sol";

/**
 * @dev Minimal ERC-4337 EntryPoint interface (EntryPoint v0.7-style).
 */
interface IEntryPoint {
    function handleOps(PackedUserOperation[] calldata ops, address payable beneficiary) external;

    function depositTo(address account) external payable;

    function withdrawTo(address payable withdrawAddress, uint256 withdrawAmount) external;

    function balanceOf(address account) external view returns (uint256);

    function getNonce(address sender, uint192 key) external view returns (uint256);
}
