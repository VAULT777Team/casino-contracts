// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @notice Chainlink CCIP chain selectors.
/// @dev Values sourced from Chainlink CCIP documentation.
library ChainSelectors {
    // Mainnets
    uint64 internal constant ETHEREUM_MAINNET = 5009297550715157269;
    uint64 internal constant ARBITRUM_MAINNET = 4949039107694359620;

    // Testnets
    uint64 internal constant ETHEREUM_SEPOLIA = 16015286601757825753;
    uint64 internal constant ARBITRUN_SEPOLIA = 3478487238524512106;
}