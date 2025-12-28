// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {BankrollRegistry} from "../contracts/bankroll/BankrollRegistry.sol";
import {BankrollMigrator} from "../contracts/bankroll/BankrollMigrator.sol";
import {BankLP} from "../contracts/bankroll/facets/BankLP.sol";
import {Treasury} from "../contracts/treasury/Treasury.sol";

/**
 * @title DeployBankrollRegistry
 * @notice Script to deploy the initial bankroll registry system
 * @dev Run with: forge script script/DeployBankrollRegistry.s.sol --rpc-url <RPC> --broadcast
 */
contract DeployBankrollRegistry is Script {
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying BankrollRegistry system...");
        console.log("Deployer:", deployer);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // 1. Deploy Treasury
        Treasury treasury = new Treasury();
        console.log("Treasury deployed:", address(treasury));
        
        // 2. Deploy initial BankLP (will set registry after registry deployment)
        BankLP bankroll = new BankLP(address(treasury), address(0));
        console.log("Initial BankLP deployed:", address(bankroll));
        
        // 3. Deploy BankrollRegistry with initial bankroll
        BankrollRegistry registry = new BankrollRegistry(
            address(bankroll),
            address(treasury),
            "v1.0.0"
        );
        console.log("BankrollRegistry deployed:", address(registry));
        
        // 4. Update bankroll with registry address (if needed in v2)
        // Note: This requires adding a setRegistry function or redeploying
        
        vm.stopBroadcast();
        
        // Log deployment info for verification
        console.log("\n=== Deployment Summary ===");
        console.log("Treasury:", address(treasury));
        console.log("BankLP v1:", address(bankroll));
        console.log("Registry:", address(registry));
        console.log("=========================\n");
        
        // Verify current state
        (
            address currentBankroll,
            address currentTreasury,
            string memory version,
            uint256 activatedAt
        ) = registry.getCurrentBankroll();
        
        console.log("Current Active Bankroll:", currentBankroll);
        console.log("Current Treasury:", currentTreasury);
        console.log("Version:", version);
        console.log("Activated At:", activatedAt);
    }
}

/**
 * @title MigrateBankroll
 * @notice Script to migrate from one bankroll to another
 * @dev Run with: forge script script/DeployBankrollRegistry.s.sol:MigrateBankroll --rpc-url <RPC> --broadcast
 */
contract MigrateBankroll is Script {
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        // Load existing addresses from environment
        address oldBankrollAddress = vm.envAddress("OLD_BANKROLL");
        address registryAddress = vm.envAddress("REGISTRY");
        address[] memory games = vm.envAddress("GAMES", ",");
        address[] memory tokens = vm.envAddress("TOKENS", ",");
        
        console.log("Starting bankroll migration...");
        console.log("Old Bankroll:", oldBankrollAddress);
        console.log("Registry:", registryAddress);
        
        vm.startBroadcast(deployerPrivateKey);
        
        BankrollRegistry registry = BankrollRegistry(registryAddress);
        BankLP oldBankroll = BankLP(oldBankrollAddress);
        
        // 1. Deploy new treasury (or reuse existing)
        Treasury newTreasury = new Treasury();
        console.log("New Treasury deployed:", address(newTreasury));
        
        // 2. Deploy new bankroll
        BankLP newBankroll = new BankLP(
            address(newTreasury),
            registryAddress
        );
        console.log("New BankLP deployed:", address(newBankroll));
        
        // 3. Register new bankroll
        uint256 newIndex = registry.registerBankroll(
            address(newBankroll),
            address(newTreasury),
            "v2.0.0",
            "Performance improvements and bug fixes"
        );
        console.log("New bankroll registered at index:", newIndex);
        
        // 4. Deploy migrator
        BankrollMigrator migrator = new BankrollMigrator(
            address(oldBankroll),
            address(newBankroll),
            registryAddress,
            msg.sender
        );
        console.log("Migrator deployed:", address(migrator));
        
        // 5. Transfer ownership to migrator
        oldBankroll.setOwner(address(migrator));
        newBankroll.setOwner(address(migrator));
        console.log("Ownership transferred to migrator");
        
        // 6. Configure migration
        migrator.setGamesToMigrate(games);
        migrator.setTokensToEnable(tokens);
        console.log("Migration configured");
        
        // 7. Start migration
        migrator.startMigration();
        console.log("Migration started - games and tokens enabled");
        
        // 8. Migrate tokens
        console.log("\nMigrating tokens...");
        for (uint256 i = 0; i < tokens.length; i++) {
            console.log("  Migrating token:", tokens[i]);
            migrator.migrateToken(tokens[i]);
        }
        
        // 9. Finalize migration
        migrator.finalizeMigration();
        console.log("Migration finalized");
        
        // 10. Activate new bankroll
        registry.activateBankroll(newIndex);
        console.log("New bankroll activated");
        
        // 11. Transfer ownership back
        oldBankroll.setOwner(msg.sender);
        newBankroll.setOwner(msg.sender);
        console.log("Ownership transferred back to deployer");
        
        vm.stopBroadcast();
        
        // Verify migration
        (
            address currentBankroll,
            address currentTreasury,
            string memory version,
            uint256 activatedAt
        ) = registry.getCurrentBankroll();
        
        console.log("\n=== Migration Complete ===");
        console.log("Old Bankroll:", oldBankrollAddress);
        console.log("New Bankroll:", address(newBankroll));
        console.log("Current Active:", currentBankroll);
        console.log("Version:", version);
        console.log("Activated At:", activatedAt);
        console.log("========================\n");
        
        require(currentBankroll == address(newBankroll), "Migration failed: new bankroll not active");
        console.log("SUCCESS: New bankroll is now active!");
    }
}

/**
 * @title VerifyRegistry
 * @notice Script to verify registry state and history
 * @dev Run with: forge script script/DeployBankrollRegistry.s.sol:VerifyRegistry --rpc-url <RPC>
 */
contract VerifyRegistry is Script {
    
    function run() external view {
        address registryAddress = vm.envAddress("REGISTRY");
        BankrollRegistry registry = BankrollRegistry(registryAddress);
        
        console.log("=== Bankroll Registry Status ===\n");
        
        // Get total bankrolls
        uint256 totalBankrolls = registry.getBankrollCount();
        console.log("Total Bankrolls Registered:", totalBankrolls);
        
        // Get current active
        (
            address currentBankroll,
            address currentTreasury,
            string memory currentVersion,
            uint256 currentActivatedAt
        ) = registry.getCurrentBankroll();
        
        console.log("\nCurrent Active Bankroll:");
        console.log("  Address:", currentBankroll);
        console.log("  Treasury:", currentTreasury);
        console.log("  Version:", currentVersion);
        console.log("  Activated:", currentActivatedAt);
        
        // List all bankrolls
        console.log("\n=== All Bankrolls (Historical) ===");
        for (uint256 i = 0; i < totalBankrolls; i++) {
            (
                address bankroll,
                address treasury,
                bool isActive,
                string memory version,
                uint256 activatedAt,
                uint256 deactivatedAt
            ) = registry.getBankrollByIndex(i);
            
            console.log("\nBankroll Index:", i);
            console.log("  Address:", bankroll);
            console.log("  Treasury:", treasury);
            console.log("  Version:", version);
            console.log("  Active:", isActive);
            console.log("  Activated At:", activatedAt);
            if (!isActive && deactivatedAt > 0) {
                console.log("  Deactivated At:", deactivatedAt);
            }
        }
        
        console.log("\n================================\n");
    }
}
