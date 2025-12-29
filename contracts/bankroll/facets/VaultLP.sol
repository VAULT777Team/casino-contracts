// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IBankLP {
    function fundBankroll(address token, uint256 amount) external returns (bool);
    function withdrawBankroll(address to, address token, uint256 amount) external returns (bool);

    function getAvailableBalance(address token) external view returns (uint256);
    function execute(address to, uint256 value, bytes calldata data) external returns (bool, bytes memory);
}

/**
 * @title BankrollLP Token
 * @notice LP token representing shares in the casino bankroll
 */
contract HouseLPToken is ERC20, Ownable {
    address public stakingVault;

    modifier onlyVault() {
        _onlyVault();
        _;
    }

    constructor() ERC20("House Edge LP", "HELP") {}
    
    function _onlyVault() internal view {
        require(msg.sender == stakingVault, "Only vault can mint/burn");
    }

    function setVault(address _vault) external onlyOwner {
        stakingVault = _vault;
    }

    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
    }
}

/**
 * @title Vault Liquidity Pool, Contract responsible for the liquidity and distribute staking rewards
 */
contract VaultLP is ReentrancyGuard, Ownable {
   using SafeERC20 for IERC20;

    // Core contracts
    HouseLPToken    public lpToken;
    IBankLP         public bankroll;

    // Staking state per token
    struct StakingPool {
        uint256 totalStaked;        // Total amount staked in this token
        uint256 totalShares;        // Total LP shares for this token
        uint256 accRewardPerShare;  // Accumulated rewards per share (scaled by 1e18)
        uint256 lastUpdateTime;     // Last time rewards were calculated
        uint256 rewardRate;         // Rewards per second (in token)
        bool isActive;              // Whether this pool is active
        uint8 decimals;             // IERC20 decimals of the pool
    }


    struct UserInfo {
        uint256 amount;             // Amount staked
        uint256 shares;             // LP shares owned
        uint256 rewardDebt;         // Reward debt for accurate calculations
        uint256 pendingRewards;     // Pending rewards to claim
        uint256 lastDepositTime;    // For lock period enforcement
    }

    // token => pool info
    mapping(address => StakingPool) public pools;
    
    // token => user => user info
    mapping(address => mapping(address => UserInfo)) public userInfo;

    // Supported tokens
    address[] public supportedTokens;
    mapping(address => bool) public isSupportedToken;

    // Configuration
    uint256 public initialEpoch;
    uint256 public epochRate = 7 days;          // Duration of each epoch
    uint256 public claimRate = 14 days;         // Time until withdrawal window opens
    uint256 public claimWindow = 2 days;        // Duration of withdrawal window
    uint256 public performanceFee = 200;        // 2% performance fee (basis points)
    address public feeRecipient;

    // Events
    event Deposited(address indexed user, address indexed token, uint256 amount, uint256 shares);
    event Withdrawn(address indexed user, address indexed token, uint256 amount, uint256 shares);
    event RewardsClaimed(address indexed user, address indexed token, uint256 amount);
    event RewardsDistributed(address indexed token, uint256 amount);
    event PoolAdded(address indexed token);
    event PoolUpdated(address indexed token, uint256 rewardRate);

    constructor(
        address _lpToken,
        address _bankroll,
        address _feeRecipient
    ) {
        lpToken = HouseLPToken(_lpToken);
        bankroll = IBankLP(_bankroll);
        feeRecipient = _feeRecipient;
        initialEpoch = block.timestamp;
    }


    // ========== ADMIN FUNCTIONS ==========

    function addPool(address token, uint256 rewardRate) external onlyOwner {
        require(!isSupportedToken[token], "Pool already exists");
        
        uint8 decimals = address(token) == address(0) ? 18 : IERC20Metadata(token).decimals();
        pools[token] = StakingPool({
            totalStaked: 0,
            totalShares: 0,
            accRewardPerShare: 0,
            lastUpdateTime: block.timestamp,
            rewardRate: rewardRate,
            isActive: true,
            decimals: decimals
        });

        supportedTokens.push(token);
        isSupportedToken[token] = true;

        emit PoolAdded(token);
    }

    function updatePool(address token, bool isActive) external onlyOwner {
        require(isSupportedToken[token], "Pool already exists");

        StakingPool storage pool = pools[token];
        pool.isActive = isActive;
    }

    function updateRewardRate(address token, uint256 newRate) external onlyOwner {
        require(isSupportedToken[token], "Pool doesn't exist");

        updatePool(token);
        pools[token].rewardRate = newRate;
        
        emit PoolUpdated(token, newRate);
    }

    function setEpochRate(uint256 newEpochRate) external onlyOwner {
        require(newEpochRate > 0, "Invalid epoch rate");
        epochRate = newEpochRate;
    }

    function setClaimRate(uint256 newClaimRate) external onlyOwner {
        claimRate = newClaimRate;
    }

    function setClaimWindow(uint256 newClaimWindow) external onlyOwner {
        claimWindow = newClaimWindow;
    }

    function setPerformanceFee(uint256 fee) external onlyOwner {
        require(fee <= 1000, "Fee too high"); // Max 10%
        performanceFee = fee;
    }


    // ========== PUBLIC FUNCTIONS ==========

    /**
     * @notice Deposit tokens into bankroll and receive LP tokens
     * @param token Address of token to deposit
     * @param amount Amount to deposit
     */
    function deposit(address token, uint256 amount) external payable nonReentrant {
        require(isSupportedToken[token], "Token not supported");
        require(amount > 0, "Amount must be > 0");

        StakingPool storage pool = pools[token];
        require(pool.isActive, "Pool not active");

        UserInfo storage user = userInfo[token][msg.sender];

        // Update pool rewards
        updatePool(token);

        // If user has existing stake, calculate pending rewards
        if (user.shares > 0) {
            uint256 pending = (user.shares * pool.accRewardPerShare / 1e18) - user.rewardDebt;
            if (pending > 0) {
                user.pendingRewards += pending;
            }
        }

        // Calculate shares to mint (shares are in normalized 18 decimal format)
        uint256 shares = calculateShares(token, amount);

        // Transfer tokens from user
        if (token == address(0)) {
            require(msg.value == amount, "Incorrect ETH amount");
            // Forward to bankroll
            (bool success, ) = address(bankroll).call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            // Approve and deposit to bankroll
            // Reset allowance to 0 first to avoid SafeERC20 non-zero to non-zero error
            IERC20(token).safeApprove(address(bankroll), 0);
            IERC20(token).safeApprove(address(bankroll), amount);
            bool funded = bankroll.fundBankroll(token, amount);
            require(funded, "Funding bankroll failed");
        }

        // Store normalized amounts internally for consistent accounting
        uint256 normalizedAmount = normalizeAmount(token, amount);
        
        // Update user info
        user.amount += normalizedAmount;
        user.shares += shares;
        user.rewardDebt = user.shares * pool.accRewardPerShare / 1e18;
        user.lastDepositTime = block.timestamp;

        // Update pool
        pool.totalStaked += normalizedAmount;
        pool.totalShares += shares;

        // Mint LP tokens to user
        lpToken.mint(msg.sender, shares);

        emit Deposited(msg.sender, token, amount, shares);
    }

    /**
     * @notice Withdraw staked tokens and burn LP tokens
     * @param token Address of token to withdraw
     * @param shares Amount of shares to burn
     */
    function withdraw(address token, uint256 shares) external nonReentrant {
        require(isSupportedToken[token], "Token not supported");
        require(shares > 0, "Shares must be > 0");

        UserInfo storage user = userInfo[token][msg.sender];
        require(user.shares >= shares, "Insufficient shares");
        
        // Calculate normalized amount to withdraw based on shares
        uint256 normalizedAmount = calculateTokenAmount(token, shares);
        uint256 tokenAmount = denormalizeAmount(token, normalizedAmount);

        // Check if we're in a valid withdrawal window
        require(isInWithdrawWindow(), "Not in valid withdrawal window");
        require(block.timestamp >= user.lastDepositTime + claimRate, "Lock period not met");
        require(bankroll.getAvailableBalance(token) > tokenAmount, "Bankroll has insufficient balance");

        // Update pool
        StakingPool storage pool = pools[token];
        updatePool(token);

        // Calculate pending rewards
        uint256 pending = (user.shares * pool.accRewardPerShare / 1e18) - user.rewardDebt;
        if (pending > 0) {
            user.pendingRewards += pending;
        }

        // Update user info
        user.amount -= normalizedAmount;
        user.shares -= shares;
        user.rewardDebt = user.shares * pool.accRewardPerShare / 1e18;

        // Update pool
        pool.totalStaked -= normalizedAmount;
        pool.totalShares -= shares;

        // Withdraw from bankroll using withdraw function
        bool transferred = bankroll.withdrawBankroll(msg.sender, token, tokenAmount);
        require(transferred, "Withdrawal from bankroll failed");

        // Burn LP tokens
        lpToken.burn(msg.sender, shares);

        emit Withdrawn(msg.sender, token, tokenAmount, shares);
    }

    /**
     * @notice Claim accumulated rewards
     * @param token Address of token pool
     */
    function claimRewards(address token) external nonReentrant {
        require(isSupportedToken[token], "Token not supported");

        UserInfo storage user = userInfo[token][msg.sender];
        StakingPool storage pool = pools[token];

        // Update pool
        updatePool(token);

        // Calculate total rewards
        uint256 pending = (user.shares * pool.accRewardPerShare / 1e18) - user.rewardDebt;
        uint256 totalRewards = user.pendingRewards + pending;

        require(totalRewards > 0, "No rewards to claim");

        // Apply performance fee
        uint256 fee = (totalRewards * performanceFee) / 10000;
        uint256 netRewards = totalRewards - fee;

        // Reset pending rewards
        user.pendingRewards = 0;
        user.rewardDebt = user.shares * pool.accRewardPerShare / 1e18;

        // Transfer rewards
        if (token == address(0)) {
            (bool success, ) = msg.sender.call{value: netRewards}("");
            require(success, "ETH transfer failed");
            if (fee > 0) {
                (bool feeSuccess, ) = feeRecipient.call{value: fee}("");
                require(feeSuccess, "Fee transfer failed");
            }
        } else {
            IERC20(token).safeTransfer(msg.sender, netRewards);
            if (fee > 0) {
                IERC20(token).safeTransfer(feeRecipient, fee);
            }
        }

        emit RewardsClaimed(msg.sender, token, netRewards);
    }

    /**
     * @notice Update reward variables for a pool
     * @param token Address of the token pool
     */
    function updatePool(address token) public {
        StakingPool storage pool = pools[token];
        
        if (block.timestamp <= pool.lastUpdateTime) {
            return;
        }

        if (pool.totalShares == 0) {
            pool.lastUpdateTime = block.timestamp;
            return;
        }

        uint256 timeElapsed = block.timestamp - pool.lastUpdateTime;
        // Normalize rewardRate to 18 decimals for accurate per-share accounting
        uint256 normalizedRewardRate = pool.rewardRate;
        if (pool.decimals < 18) {
            normalizedRewardRate = pool.rewardRate * (10 ** (18 - pool.decimals));
        } else if (pool.decimals > 18) {
            normalizedRewardRate = pool.rewardRate / (10 ** (pool.decimals - 18));
        }
        uint256 reward = timeElapsed * normalizedRewardRate;

        pool.accRewardPerShare += (reward * 1e18) / pool.totalShares;
        pool.lastUpdateTime = block.timestamp;
    }

    /**
     * @notice Distribute profits from bankroll to stakers
     * @param token Address of token to distribute
     * @param amount Amount of profit to distribute
     */
    function distributeRewards(address token, uint256 amount) external payable onlyOwner {
        require(isSupportedToken[token], "Token not supported");
        require(amount > 0, "Amount must be > 0");

        StakingPool storage pool = pools[token];
        require(pool.totalShares > 0, "No stakers");

        // Transfer rewards to vault
        if (token == address(0)) {
            require(msg.value == amount, "Incorrect ETH amount");
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }

        // Update pool
        updatePool(token);

        // Add to accumulated rewards
        pool.accRewardPerShare += (amount * 1e18) / pool.totalShares;

        emit RewardsDistributed(token, amount);
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Calculate shares for a given token amount
     * @param token Token address
     * @param amount Token amount
     * @return shares Amount of shares
     */
    function calculateShares(address token, uint256 amount) public view returns (uint256 shares) {
        StakingPool memory pool = pools[token];
        
        // Normalize amount to 18 decimals for share calculation
        uint256 normalizedAmount = normalizeAmount(token, amount);
        
        if (pool.totalShares == 0 || pool.totalStaked == 0) {
            return normalizedAmount; // 1:1 for first depositor (in normalized terms)
        }
        
        shares = (normalizedAmount * pool.totalShares) / pool.totalStaked;
    }
    
    /**
     * @notice Normalize token amount to 18 decimals
     * @param token Token address (address(0) for ETH)
     * @param amount Amount in token's native decimals
     * @return Normalized amount in 18 decimals
     */
    function normalizeAmount(address token, uint256 amount) internal view returns (uint256) {
        if (token == address(0)) {
            return amount; // ETH is already 18 decimals
        }
        
        StakingPool memory pool = pools[token];
        uint8 decimals = pool.decimals;
        
        if (decimals == 18) {
            return amount;
        } else if (decimals < 18) {
            return amount * (10 ** (18 - decimals));
        } else {
            return amount / (10 ** (decimals - 18));
        }
    }
    
    /**
     * @notice Denormalize amount from 18 decimals to token's native decimals
     * @param token Token address (address(0) for ETH)
     * @param normalizedAmount Amount in 18 decimals
     * @return Amount in token's native decimals
     */
    function denormalizeAmount(address token, uint256 normalizedAmount) internal view returns (uint256) {
        if (token == address(0)) {
            return normalizedAmount; // ETH is already 18 decimals
        }
        
        StakingPool memory pool = pools[token];
        uint8 decimals = pool.decimals;
        
        if (decimals == 18) {
            return normalizedAmount;
        } else if (decimals < 18) {
            return normalizedAmount / (10 ** (18 - decimals));
        } else {
            return normalizedAmount * (10 ** (decimals - 18));
        }
    }

    /**
     * @notice Calculate token amount for given shares
     * @param token Token address
     * @param shares Share amount
     * @return amount Token amount
     */
    function calculateTokenAmount(address token, uint256 shares) public view returns (uint256 amount) {
        StakingPool memory pool = pools[token];
        
        if (pool.totalShares == 0) {
            return 0;
        }
        
        amount = (shares * pool.totalStaked) / pool.totalShares;
    }

    /**
     * @notice Get pending rewards for a user
     * @param token Token address
     * @param user User address
     * @return pending Pending reward amount
     */
    function pendingRewards(address token, address user) external view returns (uint256 pending) {
        StakingPool memory pool = pools[token];
        UserInfo memory userInf = userInfo[token][user];

        uint256 accRewardPerShare = pool.accRewardPerShare;

        // Normalize rewardRate to 18 decimals for calculation
        uint256 normalizedRewardRate = pool.rewardRate;
        if (pool.decimals < 18) {
            normalizedRewardRate = pool.rewardRate * (10 ** (18 - pool.decimals));
        } else if (pool.decimals > 18) {
            normalizedRewardRate = pool.rewardRate / (10 ** (pool.decimals - 18));
        }

        if (block.timestamp > pool.lastUpdateTime && pool.totalShares > 0) {
            uint256 timeElapsed = block.timestamp - pool.lastUpdateTime;
            uint256 reward = timeElapsed * normalizedRewardRate;
            accRewardPerShare += (reward * 1e18) / pool.totalShares;
        }

        pending = userInf.pendingRewards + (userInf.shares * accRewardPerShare / 1e18) - userInf.rewardDebt;
    }

    /**
     * @notice Get total value locked
     * @param token Token address
     * @return tvl Total value locked
     */
    function getTVL(address token) external view returns (uint256 tvl) {
        return pools[token].totalStaked;
    }

    /**
     * @notice Get user position
     * @param token Token address
     * @param user User address
     */
    function getUserPosition(address token, address user) external view returns (
        uint256 stakedAmount,
        uint256 shares,
        uint256 pending,
        uint256 timeUntilNextWindow
    ) {
        UserInfo memory userInf = userInfo[token][user];
        stakedAmount = userInf.amount;
        shares = userInf.shares;
        pending = this.pendingRewards(token, user);
        (timeUntilNextWindow,,,) = getRemainingLockup();
    }

    /**
     * @notice Get APY for a pool
     * @param token Token address
     * @return apy Annual percentage yield (scaled by 1e18)
     */
    function getAPY(address token) external view returns (uint256 apy) {
        StakingPool memory pool = pools[token];
        
        if (pool.totalStaked == 0) {
            return 0;
        }

        // Annual rewards = rewardRate * seconds in year
        uint256 annualRewards = pool.rewardRate * 365 days;
        
        // APY = (annual rewards / total staked) * 100
        apy = (annualRewards * 1e18 * 100) / pool.totalStaked;
    }

    // ========== EPOCH & WITHDRAWAL WINDOW FUNCTIONS ==========

    /**
     * @notice Get current epoch number
     * @return Current epoch
     */
    function epoch() public view returns (uint256) {
        unchecked {
            uint256 timeDiff = block.timestamp - initialEpoch;
            return timeDiff / epochRate;
        }
    }

    /**
     * @notice Check if currently in a valid withdrawal window
     * @return Whether withdrawals are allowed
     */
    function isInWithdrawWindow() public view returns (bool) {
        uint256 currentEpoch = epoch();
        
        // Since claimRate can be longer than epochRate, windows can span multiple epochs
        // Check backwards to find any active window
        uint256 maxEpochsToCheck = (claimRate + claimWindow) / epochRate + 2;
        
        for (uint256 i = 0; i < maxEpochsToCheck && i <= currentEpoch; i++) {
            uint256 checkEpoch = currentEpoch - i;
            uint256 epochTime = initialEpoch + (checkEpoch * epochRate);
            uint256 windowStart = epochTime + claimRate;
            uint256 windowEnd = windowStart + claimWindow;
            
            // If we're in this window, return true
            if (block.timestamp >= windowStart && block.timestamp <= windowEnd) {
                return true;
            }
        }
        
        return false;
    }

    /**
     * @notice Get remaining time until next withdrawal window
     * @return timeUntilNextWindow Time in seconds until next window opens
     * @return currentEpochEnd Time when current epoch ends
     * @return canWithdraw Whether user can withdraw now
     * @return currentEpoch Current epoch number
     */
    function getRemainingLockup()
        public
        view
        returns (
            uint256 timeUntilNextWindow,
            uint256 currentEpochEnd,
            bool canWithdraw,
            uint256 currentEpoch
        )
    {
        currentEpoch = epoch();
        
        // Since claimRate can be longer than epochRate, windows can span multiple epochs
        // First pass: check backwards for any active window
        uint256 maxEpochsToCheck = (claimRate + claimWindow) / epochRate + 2;
        
        for (uint256 i = 0; i < maxEpochsToCheck && i <= currentEpoch; i++) {
            uint256 checkEpoch = currentEpoch - i;
            uint256 epochTime = initialEpoch + (checkEpoch * epochRate);
            uint256 windowStart = epochTime + claimRate;
            uint256 windowEnd = windowStart + claimWindow;
            
            // If we're in this window, return immediately
            if (block.timestamp >= windowStart && block.timestamp <= windowEnd) {
                timeUntilNextWindow = 0;
                canWithdraw = true;
                currentEpochEnd = windowEnd;
                return (timeUntilNextWindow, currentEpochEnd, canWithdraw, currentEpoch);
            }
        }
        
        // Second pass: find the next future window (checking from earliest epoch forward)
        for (uint256 i = maxEpochsToCheck; i > 0; i--) {
            if (i > currentEpoch) continue;
            
            uint256 checkEpoch = currentEpoch - i + 1;
            uint256 epochTime = initialEpoch + (checkEpoch * epochRate);
            uint256 windowStart = epochTime + claimRate;
            uint256 windowEnd = windowStart + claimWindow;
            
            // If this window is in the future, this is the next one
            if (block.timestamp < windowStart) {
                timeUntilNextWindow = windowStart - block.timestamp;
                canWithdraw = false;
                currentEpochEnd = windowEnd;
                return (timeUntilNextWindow, currentEpochEnd, canWithdraw, currentEpoch);
            }
        }
        
        // If we got here, calculate next epoch after current
        uint256 nextEpoch = currentEpoch + 1;
        uint256 nextEpochTime = initialEpoch + (nextEpoch * epochRate);
        uint256 nextWindowStart = nextEpochTime + claimRate;
        uint256 nextWindowEnd = nextWindowStart + claimWindow;
        
        timeUntilNextWindow = nextWindowStart - block.timestamp;
        canWithdraw = false;
        currentEpochEnd = nextWindowEnd;
        
        return (timeUntilNextWindow, currentEpochEnd, canWithdraw, currentEpoch);
    }

    // ========== RECEIVE ETH ==========

    receive() external payable {}

    
    /// @notice Execute a single function call.
    /// @param to Address of the contract to execute.
    /// @param value Value to send to the contract.
    /// @param data Data to send to the contract.
    /// @return success_ Boolean indicating if the execution was successful.
    /// @return result_ Bytes containing the result of the execution.
    function execute(address to, uint256 value, bytes calldata data)
        external
        onlyOwner
        returns (bool, bytes memory)
    {
        (bool success, bytes memory result) = to.call{value: value}(data);
        return (success, result);
    }
}