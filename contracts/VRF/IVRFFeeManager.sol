// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

interface IVRFFeeManager {
    function quoteVRFFee(
        address token,
        uint32 callbackGasLimit,
        uint32 numWords,
        uint256 gasPriceWei,
        uint256 l1CostWei
    ) external view returns (uint256);
}
