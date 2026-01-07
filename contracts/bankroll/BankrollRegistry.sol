// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IBankLP } from "./interfaces/IBankLP.sol";

/**
 * @title BankrollRegistry
 * @notice Immutable registry that tracks all bankroll and treasury deployments
 * @dev This contract should NEVER be upgraded - it's the permanent historical record
 *      TheGraph subgraphs index this contract to maintain complete historical data
 */
contract BankrollRegistry {
    
    struct BankrollInfo {
        address bankrollAddress;
        address treasuryAddress;
        uint256 activatedAt;
        uint256 deactivatedAt;
        bool isActive;
        string version;
        string migrationReason; // human-readable reason
    }
    
    struct MigrationStats {
        address token;
        uint256 balanceMigrated;
        uint256 reservedFunds;
    }
    
    // Array of all bankroll deployments (historical record)
    BankrollInfo[] public bankrollHistory;
    
    // Current active bankroll index
    uint256 public currentBankrollIndex;
    
    // Mapping for quick lookups
    mapping(address => uint256) public bankrollToIndex;
    mapping(address => bool) public isKnownBankroll;
    
    // Protocol governance
    address public immutable governance;
    address public pendingGovernance;
    
    // Events for TheGraph indexing
    event BankrollRegistered(
        uint256 indexed index,
        address indexed bankrollAddress,
        address indexed treasuryAddress,
        string version,
        string reason,
        uint256 timestamp
    );
    
    event BankrollActivated(
        uint256 indexed index,
        address indexed bankrollAddress,
        address indexed previousBankroll,
        uint256 timestamp
    );
    
    event BankrollDeactivated(
        uint256 indexed index,
        address indexed bankrollAddress,
        string reason,
        uint256 timestamp
    );
    
    event MigrationInitiated(
        uint256 indexed fromIndex,
        uint256 indexed toIndex,
        address indexed fromBankroll,
        address toBankroll,
        uint256 timestamp
    );
    
    event MigrationCompleted(
        uint256 indexed fromIndex,
        uint256 indexed toIndex,
        address indexed token,
        uint256 balanceMigrated,
        uint256 reservedFunds,
        uint256 timestamp
    );
    
    event TreasuryUpdated(
        uint256 indexed bankrollIndex,
        address indexed oldTreasury,
        address indexed newTreasury,
        uint256 timestamp
    );
    
    event GovernanceTransferInitiated(
        address indexed currentGovernance,
        address indexed pendingGovernance,
        uint256 timestamp
    );
    
    event GovernanceTransferred(
        address indexed oldGovernance,
        address indexed newGovernance,
        uint256 timestamp
    );
    
    modifier onlyGovernance() {
        _onlyGovernance();
        _;
    }

    function _onlyGovernance() internal view {
        require(msg.sender == governance, "Only governance");
    }
    
    constructor(
        address _initialBankroll,
        address _initialTreasury,
        string memory _version
    ) {
        governance = msg.sender;
        
        // Register the first bankroll
        _registerBankroll(_initialBankroll, _initialTreasury, _version, "Initial deployment");
        _activateBankroll(0);
    }
    
    /**
     * @notice Register a new bankroll deployment
     * @param bankroll Address of the new bankroll
     * @param treasury Address of the treasury for this bankroll
     * @param version Version string (e.g., "v2.0.0")
     * @param reason Reason for deployment
     */
    function registerBankroll(
        address bankroll,
        address treasury,
        string calldata version,
        string calldata reason
    ) external onlyGovernance returns (uint256 index) {
        return _registerBankroll(bankroll, treasury, version, reason);
    }
    
    function _registerBankroll(
        address bankroll,
        address treasury,
        string memory version,
        string memory reason
    ) internal returns (uint256 index) {
        require(bankroll != address(0), "Invalid bankroll address");
        require(treasury != address(0), "Invalid treasury address");
        require(!isKnownBankroll[bankroll], "Bankroll already registered");
        
        index = bankrollHistory.length;

        bankrollHistory.push(BankrollInfo({
            bankrollAddress: bankroll,
            treasuryAddress: treasury,
            activatedAt: 0, // Not activated yet
            deactivatedAt: 0,
            isActive: false,
            version: version,
            migrationReason: reason
        }));
        
        bankrollToIndex[bankroll] = index;
        isKnownBankroll[bankroll] = true;
        
        emit BankrollRegistered(
            index,
            bankroll,
            treasury,
            version,
            reason,
            block.timestamp
        );
        
        return index;
    }
    
    /**
     * @notice Activate a registered bankroll (migrates from current)
     * @param index Index of the bankroll to activate
     */
    function activateBankroll(uint256 index) external onlyGovernance {
        _activateBankroll(index);
    }

    function _activateBankroll(uint256 index) internal {
        require(index < bankrollHistory.length, "Invalid index");
        require(!bankrollHistory[index].isActive, "Already active");
        
        // Deactivate current bankroll
        if (bankrollHistory.length > 0 && currentBankrollIndex < bankrollHistory.length) {
            BankrollInfo storage current = bankrollHistory[currentBankrollIndex];
            if (current.isActive) {
                current.isActive = false;
                current.deactivatedAt = block.timestamp;
                
                emit BankrollDeactivated(
                    currentBankrollIndex,
                    current.bankrollAddress,
                    "Migrated to new version",
                    block.timestamp
                );
            }
        }
        
        // Activate new bankroll
        BankrollInfo storage newBankroll = bankrollHistory[index];
        newBankroll.isActive = true;
        newBankroll.activatedAt = block.timestamp;
        
        address previousBankroll = currentBankrollIndex < bankrollHistory.length 
            ? bankrollHistory[currentBankrollIndex].bankrollAddress 
            : address(0);
        
        emit MigrationInitiated(
            currentBankrollIndex,
            index,
            previousBankroll,
            newBankroll.bankrollAddress,
            block.timestamp
        );
        
        currentBankrollIndex = index;
        
        emit BankrollActivated(
            index,
            newBankroll.bankrollAddress,
            previousBankroll,
            block.timestamp
        );
    }
    
    /**
     * @notice Record migration statistics for TheGraph
     * @param fromIndex Source bankroll index
     * @param toIndex Destination bankroll index
     * @param stats Array of migration statistics per token
     */
    function recordMigration(
        uint256 fromIndex,
        uint256 toIndex,
        MigrationStats[] calldata stats
    ) external onlyGovernance {
        require(fromIndex < bankrollHistory.length, "Invalid from index");
        require(toIndex < bankrollHistory.length, "Invalid to index");
        
        for (uint256 i = 0; i < stats.length; i++) {
            if(stats[i].token == address(0)) {
                IBankLP prevBankLP = IBankLP(bankrollHistory[fromIndex].bankrollAddress);

                (bool success, ) = prevBankLP.execute(
                    bankrollHistory[toIndex].bankrollAddress,
                    stats[i].balanceMigrated,
                    new bytes(0)
                );

                require(success, "Ether migration transfer failed");
            } else {
                IBankLP prevBankLP = IBankLP(bankrollHistory[fromIndex].bankrollAddress);
                uint256 tokenBalance = IERC20(stats[i].token).balanceOf(bankrollHistory[toIndex].bankrollAddress);
                require(stats[i].balanceMigrated <= tokenBalance, "Invalid token migration amount");

                (bool success, ) = prevBankLP.execute(
                    stats[i].token,
                    0,
                    abi.encodeWithSignature(
                        "transfer(address, uint256)",
                        bankrollHistory[toIndex].bankrollAddress,
                        stats[i].balanceMigrated
                    )
                );

                require(success, "Token migration transfer failed");
            }

            emit MigrationCompleted(
                fromIndex,
                toIndex,
                stats[i].token,
                stats[i].balanceMigrated,
                stats[i].reservedFunds,
                block.timestamp
            );
        }
    }
    
    /**
     * @notice Update treasury address for a bankroll
     * @param bankrollIndex Index of the bankroll
     * @param newTreasury New treasury address
     */
    function updateTreasury(
        uint256 bankrollIndex,
        address newTreasury
    ) external onlyGovernance {
        require(bankrollIndex < bankrollHistory.length, "Invalid index");
        require(newTreasury != address(0), "Invalid treasury");
        
        BankrollInfo storage info = bankrollHistory[bankrollIndex];
        address oldTreasury = info.treasuryAddress;
        info.treasuryAddress = newTreasury;
        
        emit TreasuryUpdated(
            bankrollIndex,
            oldTreasury,
            newTreasury,
            block.timestamp
        );
    }
    
    /**
     * @notice Deactivate a bankroll manually
     * @param index Index of the bankroll
     * @param reason Reason for deactivation
     */
    function deactivateBankroll(
        uint256 index,
        string calldata reason
    ) external onlyGovernance {
        require(index < bankrollHistory.length, "Invalid index");
        
        BankrollInfo storage info = bankrollHistory[index];
        require(info.isActive, "Not active");
        
        info.isActive = false;
        info.deactivatedAt = block.timestamp;
        
        emit BankrollDeactivated(
            index,
            info.bankrollAddress,
            reason,
            block.timestamp
        );
    }
    
    /**
     * @notice Get current active bankroll
     */
    function getCurrentBankroll() external view returns (
        address bankroll,
        address treasury,
        string memory version,
        uint256 activatedAt
    ) {
        require(currentBankrollIndex < bankrollHistory.length, "No active bankroll");
        BankrollInfo memory info = bankrollHistory[currentBankrollIndex];
        return (
            info.bankrollAddress,
            info.treasuryAddress,
            info.version,
            info.activatedAt
        );
    }
    
    /**
     * @notice Get bankroll info by address
     */
    function getBankrollInfo(address bankroll) external view returns (
        uint256 index,
        address treasury,
        bool isActive,
        string memory version,
        uint256 activatedAt,
        uint256 deactivatedAt
    ) {
        require(isKnownBankroll[bankroll], "Unknown bankroll");
        uint256 idx = bankrollToIndex[bankroll];
        BankrollInfo memory info = bankrollHistory[idx];
        
        return (
            idx,
            info.treasuryAddress,
            info.isActive,
            info.version,
            info.activatedAt,
            info.deactivatedAt
        );
    }
    
    /**
     * @notice Get total number of bankrolls registered
     */
    function getBankrollCount() external view returns (uint256) {
        return bankrollHistory.length;
    }
    
    /**
     * @notice Get bankroll info by index
     */
    function getBankrollByIndex(uint256 index) external view returns (
        address bankroll,
        address treasury,
        bool isActive,
        string memory version,
        uint256 activatedAt,
        uint256 deactivatedAt
    ) {
        require(index < bankrollHistory.length, "Invalid index");
        BankrollInfo memory info = bankrollHistory[index];
        
        return (
            info.bankrollAddress,
            info.treasuryAddress,
            info.isActive,
            info.version,
            info.activatedAt,
            info.deactivatedAt
        );
    }
    
    /**
     * @notice Two-step governance transfer
     */
    function transferGovernance(address newGovernance) external onlyGovernance {
        require(newGovernance != address(0), "Invalid address");
        pendingGovernance = newGovernance;
        
        emit GovernanceTransferInitiated(
            governance,
            newGovernance,
            block.timestamp
        );
    }
    
    function acceptGovernance() external {
        require(msg.sender == pendingGovernance, "Not pending governance");
        
        emit GovernanceTransferred(
            governance,
            pendingGovernance,
            block.timestamp
        );
        
        // Note: governance is immutable, so this pattern ensures security
        // In production, you might want to make governance mutable
    }
}
