// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

/// @title IBankrollRegistry
/// @notice Interface for the Bankroll Registry contract
interface IBankrollRegistry {
    
    function getCurrentBankroll() external view returns (
        address bankroll,
        address treasury,
        string memory version,
        uint256 activatedAt
    );

    function bankrollToIndex(address bankroll) external view returns (uint256);
    function totalBankrolls() external view returns (uint256);

    struct MigrationStats {
        address token;
        uint256 balanceMigrated;
        uint256 reservedFunds;
        uint256 totalUsers;
    }
    
    function recordMigration(
        uint256 fromIndex,
        uint256 toIndex,
        MigrationStats[] calldata stats
    ) external;
    function registerBankroll(address bankroll) external returns (uint256);
}