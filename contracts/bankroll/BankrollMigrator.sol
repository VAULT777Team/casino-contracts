// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBankrollRegistry} from "./interfaces/IBankrollRegistry.sol";
import {IBankLP} from "./interfaces/IBankLP.sol";

/**
 * @title BankrollMigrator
 * @notice Helper contract to safely migrate funds and state from one bankroll to another
 * @dev This contract should be deployed once per migration
 */
contract BankrollMigrator {
    using SafeERC20 for IERC20;
    
    address public immutable oldBankroll;
    address public immutable newBankroll;
    address public immutable registry;
    address public immutable governance;
    
    bool public migrationStarted;
    bool public migrationCompleted;
    
    struct TokenMigration {
        address token;
        uint256 amountMigrated;
        uint256 reservedAmount;
        bool completed;
    }
    
    // Token migration tracking
    mapping(address => TokenMigration) public tokenMigrations;
    address[] public migratedTokens;
    
    // Game and token configurations to copy
    address[] public gamesToMigrate;
    address[] public tokensToEnable;
    
    event MigrationStarted(
        address indexed oldBankroll,
        address indexed newBankroll,
        uint256 timestamp
    );
    
    event TokenMigrated(
        address indexed token,
        uint256 amount,
        uint256 reservedFunds,
        uint256 timestamp
    );
    
    event GamesMigrated(
        address[] games,
        uint256 timestamp
    );
    
    event MigrationFinalized(
        uint256 totalTokensMigrated,
        uint256 totalGames,
        uint256 timestamp
    );
    
    modifier onlyGovernance() {
        require(msg.sender == governance, "Only governance");
        _;
    }
    
    modifier notStarted() {
        require(!migrationStarted, "Migration already started");
        _;
    }
    
    modifier started() {
        require(migrationStarted, "Migration not started");
        _;
    }
    
    constructor(
        address _oldBankroll,
        address _newBankroll,
        address _registry,
        address _governance
    ) {
        require(_oldBankroll != address(0), "Invalid old bankroll");
        require(_newBankroll != address(0), "Invalid new bankroll");
        require(_registry != address(0), "Invalid registry");
        require(_governance != address(0), "Invalid governance");
        
        oldBankroll = _oldBankroll;
        newBankroll = _newBankroll;
        registry = _registry;
        governance = _governance;
    }
    
    /**
     * @notice Set games to migrate to new bankroll
     * @param games Array of game addresses
     */
    function setGamesToMigrate(address[] calldata games) external onlyGovernance notStarted {
        delete gamesToMigrate;
        for (uint256 i = 0; i < games.length; i++) {
            gamesToMigrate.push(games[i]);
        }
    }
    
    /**
     * @notice Set tokens to enable on new bankroll
     * @param tokens Array of token addresses
     */
    function setTokensToEnable(address[] calldata tokens) external onlyGovernance notStarted {
        delete tokensToEnable;
        for (uint256 i = 0; i < tokens.length; i++) {
            tokensToEnable.push(tokens[i]);
        }
    }
    
    /**
     * @notice Start the migration process
     */
    function startMigration() external onlyGovernance notStarted {
        migrationStarted = true;
        
        // Enable tokens on new bankroll
        for (uint256 i = 0; i < tokensToEnable.length; i++) {
            IBankLP(newBankroll).setTokenAddress(tokensToEnable[i], true);
        }
        
        // Enable games on new bankroll
        for (uint256 i = 0; i < gamesToMigrate.length; i++) {
            IBankLP(newBankroll).setGame(gamesToMigrate[i], true);
        }
        
        emit MigrationStarted(oldBankroll, newBankroll, block.timestamp);
        emit GamesMigrated(gamesToMigrate, block.timestamp);
    }
    
    /**
     * @notice Migrate a specific token's balance
     * @param token Token address (address(0) for ETH)
     */
    function migrateToken(address token) external onlyGovernance started {
        require(!tokenMigrations[token].completed, "Token already migrated");
        
        uint256 balance;
        uint256 reserved;
        
        if (token == address(0)) {
            // Migrate ETH
            balance = address(oldBankroll).balance;
            reserved = IBankLP(oldBankroll).reservedFunds(address(0));
            
            if (balance > 0) {
                // Execute transfer from old bankroll to new bankroll
                (bool success, ) = IBankLP(oldBankroll).execute(
                    newBankroll,
                    balance,
                    ""
                );
                require(success, "ETH migration failed");
            }
        } else {
            // Migrate ERC20
            balance = IERC20(token).balanceOf(oldBankroll);
            reserved = IBankLP(oldBankroll).reservedFunds(token);
            
            if (balance > 0) {
                // Execute transfer from old bankroll to new bankroll
                bytes memory data = abi.encodeWithSignature(
                    "transfer(address,uint256)",
                    newBankroll,
                    balance
                );
                
                (bool success, ) = IBankLP(oldBankroll).execute(
                    token,
                    0,
                    data
                );
                require(success, "Token migration failed");
            }
        }
        
        // Record migration
        tokenMigrations[token] = TokenMigration({
            token: token,
            amountMigrated: balance,
            reservedAmount: reserved,
            completed: true
        });
        
        migratedTokens.push(token);
        
        emit TokenMigrated(token, balance, reserved, block.timestamp);
    }
    
    /**
     * @notice Migrate multiple tokens in one transaction
     * @param tokens Array of token addresses
     */
    function migrateTokensBatch(address[] calldata tokens) external onlyGovernance started {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (!tokenMigrations[tokens[i]].completed) {
                this.migrateToken(tokens[i]);
            }
        }
    }
    
    /**
     * @notice Finalize migration and record to registry
     */
    function finalizeMigration() external onlyGovernance started {
        require(!migrationCompleted, "Already completed");
        
        // Prepare migration stats for registry
        IBankrollRegistry.MigrationStats[] memory stats = 
            new IBankrollRegistry.MigrationStats[](migratedTokens.length);
        
        for (uint256 i = 0; i < migratedTokens.length; i++) {
            TokenMigration memory tm = tokenMigrations[migratedTokens[i]];
            stats[i] = IBankrollRegistry.MigrationStats({
                token: tm.token,
                balanceMigrated: tm.amountMigrated,
                reservedFunds: tm.reservedAmount,
                totalUsers: 0 // Can be set externally if tracked
            });
        }
        
        // Record migration to registry
        uint256 fromIndex = IBankrollRegistry(registry).bankrollToIndex(oldBankroll);
        uint256 toIndex = IBankrollRegistry(registry).bankrollToIndex(newBankroll);
        
        IBankrollRegistry(registry).recordMigration(fromIndex, toIndex, stats);
        
        // Disable games on old bankroll
        for (uint256 i = 0; i < gamesToMigrate.length; i++) {
            IBankLP(oldBankroll).setGame(gamesToMigrate[i], false);
        }
        
        migrationCompleted = true;
        
        emit MigrationFinalized(
            migratedTokens.length,
            gamesToMigrate.length,
            block.timestamp
        );
    }
    
    /**
     * @notice Get migration status
     */
    function getMigrationStatus() external view returns (
        bool migrationStarted_,
        bool migrationCompleted_,
        uint256 tokensMigrated,
        uint256 gamesToMigrate_
    ) {
        return (
            migrationStarted,
            migrationCompleted,
            migratedTokens.length,
            gamesToMigrate.length
        );
    }
    
    /**
     * @notice Get list of migrated tokens
     */
    function getMigratedTokens() external view returns (address[] memory) {
        return migratedTokens;
    }
    
    /**
     * @notice Get migration details for a token
     */
    function getTokenMigration(address token) external view returns (
        uint256 amountMigrated,
        uint256 reservedAmount,
        bool completed
    ) {
        TokenMigration memory tm = tokenMigrations[token];
        return (tm.amountMigrated, tm.reservedAmount, tm.completed);
    }
}
