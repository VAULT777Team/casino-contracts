// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IBankrollRegistry} from "../interfaces/IBankrollRegistry.sol";
import {IBankLP} from "../interfaces/IBankLP.sol";

import {HouseLPToken} from "./VaultLP.sol";

/**
 * @title Vault Liquidity Pool (v2)
 * @notice Share-based vault: deposits mint shares, withdrawals redeem pro-rata against current BankLP balances.
 *         This means profits/losses in BankLP are reflected in share redemption value.
 */
contract VaultLP2 is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // Core contracts
    HouseLPToken public lpToken;
    IBankrollRegistry public bankrollRegistry;

    struct StakingPool {
        uint256 totalShares; // Total LP shares for this token
        uint256 accRewardPerShare; // Accumulated rewards per share (scaled by 1e18)
        uint256 lastUpdateTime; // Last time rewards were calculated
        uint256 rewardRate; // Rewards per second (in token)
        bool isActive; // Whether this pool is active
        uint8 decimals; // IERC20 decimals of the pool
    }

    struct UserInfo {
        uint256 shares; // LP shares owned
        uint256 rewardDebt; // Reward debt for accurate calculations
        uint256 pendingRewards; // Pending rewards to claim
        uint256 lastDepositTime; // For lock period enforcement
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
    uint256 public epochRate = 7 days; // Duration of each epoch
    uint256 public claimRate = 14 days; // Time until withdrawal window opens
    uint256 public claimWindow = 2 days; // Duration of withdrawal window
    uint256 public performanceFee = 200; // 2% performance fee (basis points)
    address public feeRecipient;

    // Events
    event Deposited(address indexed user, address indexed token, uint256 amount, uint256 shares);
    event Withdrawn(address indexed user, address indexed token, uint256 amount, uint256 shares);
    event RewardsClaimed(address indexed user, address indexed token, uint256 amount);
    event RewardsDistributed(address indexed token, uint256 amount);
    event PoolAdded(address indexed token);
    event PoolUpdated(address indexed token, uint256 rewardRate);

    error VaultInsolvent(address token);

    constructor(address _lpToken, address _bankrollRegistry, address _feeRecipient) {
        lpToken = HouseLPToken(_lpToken);
        bankrollRegistry = IBankrollRegistry(_bankrollRegistry);
        feeRecipient = _feeRecipient;
        initialEpoch = block.timestamp;
    }

    // ========== ADMIN FUNCTIONS ==========

    function addPool(address token, uint256 rewardRate) external onlyOwner {
        require(!isSupportedToken[token], "Pool already exists");

        uint8 decimals = token == address(0) ? 18 : IERC20Metadata(token).decimals();
        pools[token] = StakingPool({
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

    function updatePoolActive(address token, bool isActive) external onlyOwner {
        require(isSupportedToken[token], "Pool doesn't exist");
        pools[token].isActive = isActive;
    }

    function updateRewardRate(address token, uint256 newRate) external onlyOwner {
        require(isSupportedToken[token], "Pool doesn't exist");

        updatePool(token);
        pools[token].rewardRate = newRate;

        emit PoolUpdated(token, newRate);
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Invalid address");
        feeRecipient = newRecipient;
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

    function deposit(address token, uint256 amount) external payable nonReentrant {
        require(isSupportedToken[token], "Token not supported");
        require(amount > 0, "Amount must be > 0");

        (address bankroll, , , uint256 activatedAt) = bankrollRegistry.getCurrentBankroll();
        require(bankroll != address(0), "Bankroll not set");
        require(activatedAt > 0, "Bankroll not active");

        StakingPool storage pool = pools[token];
        require(pool.isActive, "Pool not active");

        UserInfo storage user = userInfo[token][msg.sender];

        // Update pool rewards
        updatePool(token);

        // Accrue pending rewards (based on shares)
        if (user.shares > 0) {
            uint256 pending = (user.shares * pool.accRewardPerShare) / 1e18 - user.rewardDebt;
            if (pending > 0) user.pendingRewards += pending;
        }

        // Compute shares against current BankLP assets (pro-rata)
        uint256 shares = calculateShares(token, amount);

        // Transfer tokens from user and forward to bankroll
        if (token == address(0)) {
            require(msg.value == amount, "Incorrect ETH amount");
            (bool success, ) = payable(bankroll).call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            IERC20(token).safeApprove(bankroll, 0);
            IERC20(token).safeApprove(bankroll, amount);
            bool funded = IBankLP(bankroll).fundBankroll(token, amount);
            require(funded, "Funding bankroll failed");
        }

        user.shares += shares;
        user.rewardDebt = (user.shares * pool.accRewardPerShare) / 1e18;
        user.lastDepositTime = block.timestamp;

        pool.totalShares += shares;

        lpToken.mint(msg.sender, shares);
        emit Deposited(msg.sender, token, amount, shares);
    }

    function withdraw(address token, uint256 shares) external nonReentrant {
        require(isSupportedToken[token], "Token not supported");
        require(shares > 0, "Shares must be > 0");

        UserInfo storage user = userInfo[token][msg.sender];
        require(user.shares >= shares, "Insufficient shares");

        require(isInWithdrawWindow(), "Not in valid withdrawal window");
        require(block.timestamp >= user.lastDepositTime + claimRate, "Lock period not met");

        (address bankrollAddr, , , uint256 activatedAt) = bankrollRegistry.getCurrentBankroll();
        require(bankrollAddr != address(0), "Bankroll not set");
        require(activatedAt > 0, "Bankroll not active");

        // Update pool
        StakingPool storage pool = pools[token];
        updatePool(token);

        // Accrue pending rewards
        uint256 pending = (user.shares * pool.accRewardPerShare) / 1e18 - user.rewardDebt;
        if (pending > 0) user.pendingRewards += pending;

        // Claim rewards before withdrawing principal
        _claimRewards(token);

        // Redeem pro-rata against current bankroll assets
        uint256 normalizedAmount = calculateTokenAmount(token, shares);
        uint256 tokenAmount = _denormalizeAmount(token, normalizedAmount);

        IBankLP bankroll = IBankLP(bankrollAddr);
        require(bankroll.getAvailableBalance(token) >= tokenAmount, "Bankroll has insufficient balance");

        user.shares -= shares;
        user.rewardDebt = (user.shares * pool.accRewardPerShare) / 1e18;

        pool.totalShares -= shares;

        bool transferred = bankroll.withdrawBankroll(msg.sender, token, tokenAmount);
        require(transferred, "Withdrawal from bankroll failed");

        lpToken.burn(msg.sender, shares);
        emit Withdrawn(msg.sender, token, tokenAmount, shares);
    }

    function claimRewards(address token) external nonReentrant {
        _claimRewards(token);
    }

    function _claimRewards(address token) internal {
        require(isSupportedToken[token], "Token not supported");

        UserInfo storage user = userInfo[token][msg.sender];
        StakingPool storage pool = pools[token];

        updatePool(token);

        (address bankrollAddr, , , uint256 activatedAt) = bankrollRegistry.getCurrentBankroll();
        require(bankrollAddr != address(0), "Bankroll not set");
        require(activatedAt > 0, "Bankroll not active");

        IBankLP bankroll = IBankLP(bankrollAddr);

        uint256 pending = (user.shares * pool.accRewardPerShare) / 1e18 - user.rewardDebt;
        uint256 totalRewards = user.pendingRewards + pending;

        require(totalRewards > 0, "No rewards to claim");
        require(bankroll.getAvailableBalance(token) >= totalRewards, "Bankroll has insufficient balance");

        uint256 fee = (totalRewards * performanceFee) / 10000;
        uint256 netRewards = totalRewards - fee;

        user.pendingRewards = 0;
        user.rewardDebt = (user.shares * pool.accRewardPerShare) / 1e18;

        bool success = bankroll.withdrawBankroll(msg.sender, token, netRewards);
        require(success, "Withdraw bankroll transfer failed");

        if (fee > 0) {
            bool feeSuccess = bankroll.withdrawBankroll(feeRecipient, token, fee);
            require(feeSuccess, "Fee transfer failed");
        }

        emit RewardsClaimed(msg.sender, token, netRewards);
    }

    /**
     * @notice Update reward variables for a pool
     */
    function updatePool(address token) public {
        StakingPool storage pool = pools[token];

        if (block.timestamp <= pool.lastUpdateTime) return;
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
     * @notice Optional: distribute profits/rewards into the vault accounting (not required for pro-rata bankroll PnL)
     */
    function distributeRewards(address token, uint256 amount) external payable onlyOwner {
        require(isSupportedToken[token], "Token not supported");
        require(amount > 0, "Amount must be > 0");

        StakingPool storage pool = pools[token];
        require(pool.totalShares > 0, "No stakers");

        if (token == address(0)) {
            require(msg.value == amount, "Incorrect ETH amount");
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }

        updatePool(token);

        uint256 normalizedAmount = _normalizeAmount(token, amount);
        pool.accRewardPerShare += (normalizedAmount * 1e18) / pool.totalShares;

        emit RewardsDistributed(token, amount);
    }

    // ========== VIEW FUNCTIONS ==========

    function calculateShares(address token, uint256 amount) public view returns (uint256 shares) {
        StakingPool memory pool = pools[token];

        uint256 normalizedAmount = _normalizeAmount(token, amount);

        if (pool.totalShares == 0) {
            return normalizedAmount;
        }

        uint256 totalAssets = _totalAssetsNormalized(token);
        if (totalAssets == 0) {
            revert VaultInsolvent(token);
        }

        shares = (normalizedAmount * pool.totalShares) / totalAssets;
    }

    function calculateTokenAmount(address token, uint256 shares) public view returns (uint256 amount) {
        StakingPool memory pool = pools[token];
        if (pool.totalShares == 0) return 0;

        uint256 totalAssets = _totalAssetsNormalized(token);
        amount = (shares * totalAssets) / pool.totalShares;
    }

    function pendingRewards(address token, address user) external view returns (uint256 pending) {
        StakingPool memory pool = pools[token];
        UserInfo memory userInf = userInfo[token][user];

        uint256 accRewardPerShare = pool.accRewardPerShare;

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

        pending = userInf.pendingRewards + (userInf.shares * accRewardPerShare) / 1e18 - userInf.rewardDebt;
    }

    function getTVL(address token) external view returns (uint256 tvl) {
        return _totalAssetsNormalized(token);
    }

    function getUserPosition(address token, address user) external view returns (
        uint256 stakedAmount,
        uint256 shares,
        uint256 pending,
        uint256 timeUntilNextWindow
    ) {
        UserInfo memory userInf = userInfo[token][user];
        shares = userInf.shares;
        stakedAmount = calculateTokenAmount(token, shares);
        pending = this.pendingRewards(token, user);
        (timeUntilNextWindow, , , ) = getRemainingLockup();
    }

    function getAPY(address token) external view returns (uint256 apy) {
        StakingPool memory pool = pools[token];
        uint256 tvl = _totalAssetsNormalized(token);
        if (tvl == 0) return 0;

        uint256 annualRewards = pool.rewardRate * 365 days;
        uint256 normalizedAnnualRewards = _normalizeAmount(token, annualRewards);

        apy = (normalizedAnnualRewards * 1e18 * 100) / tvl;
    }

    // ========== EPOCH & WITHDRAWAL WINDOW FUNCTIONS ==========

    function epoch() public view returns (uint256) {
        unchecked {
            uint256 timeDiff = block.timestamp - initialEpoch;
            return timeDiff / epochRate;
        }
    }

    function isInWithdrawWindow() public view returns (bool) {
        uint256 currentEpoch = epoch();
        uint256 maxEpochsToCheck = (claimRate + claimWindow) / epochRate + 2;

        for (uint256 i = 0; i < maxEpochsToCheck && i <= currentEpoch; i++) {
            uint256 checkEpoch = currentEpoch - i;
            uint256 epochTime = initialEpoch + (checkEpoch * epochRate);
            uint256 windowStart = epochTime + claimRate;
            uint256 windowEnd = windowStart + claimWindow;

            if (block.timestamp >= windowStart && block.timestamp <= windowEnd) {
                return true;
            }
        }

        return false;
    }

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
        uint256 maxEpochsToCheck = (claimRate + claimWindow) / epochRate + 2;

        for (uint256 i = 0; i < maxEpochsToCheck && i <= currentEpoch; i++) {
            uint256 checkEpoch = currentEpoch - i;
            uint256 epochTime = initialEpoch + (checkEpoch * epochRate);
            uint256 windowStart = epochTime + claimRate;
            uint256 windowEnd = windowStart + claimWindow;

            if (block.timestamp >= windowStart && block.timestamp <= windowEnd) {
                timeUntilNextWindow = 0;
                canWithdraw = true;
                currentEpochEnd = windowEnd;
                return (timeUntilNextWindow, currentEpochEnd, canWithdraw, currentEpoch);
            }
        }

        for (uint256 i = maxEpochsToCheck; i > 0; i--) {
            if (i > currentEpoch) continue;

            uint256 checkEpoch = currentEpoch - i + 1;
            uint256 epochTime = initialEpoch + (checkEpoch * epochRate);
            uint256 windowStart = epochTime + claimRate;
            uint256 windowEnd = windowStart + claimWindow;

            if (block.timestamp < windowStart) {
                timeUntilNextWindow = windowStart - block.timestamp;
                canWithdraw = false;
                currentEpochEnd = windowEnd;
                return (timeUntilNextWindow, currentEpochEnd, canWithdraw, currentEpoch);
            }
        }

        uint256 nextEpoch = currentEpoch + 1;
        uint256 nextEpochTime = initialEpoch + (nextEpoch * epochRate);
        uint256 nextWindowStart = nextEpochTime + claimRate;
        uint256 nextWindowEnd = nextWindowStart + claimWindow;

        timeUntilNextWindow = nextWindowStart - block.timestamp;
        canWithdraw = false;
        currentEpochEnd = nextWindowEnd;

        return (timeUntilNextWindow, currentEpochEnd, canWithdraw, currentEpoch);
    }

    // ========== INTERNAL HELPERS ==========

    function _totalAssetsNormalized(address token) internal view returns (uint256) {
        (address bankrollAddr, , , ) = bankrollRegistry.getCurrentBankroll();
        if (bankrollAddr == address(0)) return 0;

        IBankLP bankroll = IBankLP(bankrollAddr);
        uint256 raw = bankroll.getAvailableBalance(token) + bankroll.reservedFunds(token);
        return _normalizeAmount(token, raw);
    }

    function _normalizeAmount(address token, uint256 amount) internal view returns (uint256) {
        if (token == address(0)) return amount;

        StakingPool memory pool = pools[token];
        uint8 decimals = pool.decimals;

        if (decimals == 18) return amount;
        if (decimals < 18) return amount * (10 ** (18 - decimals));
        return amount / (10 ** (decimals - 18));
    }

    function _denormalizeAmount(address token, uint256 normalizedAmount) internal view returns (uint256) {
        if (token == address(0)) return normalizedAmount;

        StakingPool memory pool = pools[token];
        uint8 decimals = pool.decimals;

        if (decimals == 18) return normalizedAmount;
        if (decimals < 18) return normalizedAmount / (10 ** (18 - decimals));
        return normalizedAmount * (10 ** (decimals - 18));
    }

    // ========== RECEIVE ETH ==========

    receive() external payable {}
}
