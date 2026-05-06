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
        uint256 depositedAmountNormalized; // Principal deposited (normalized to 18 decimals)
    }

    struct ClaimRequest {
        uint256 shares; // Shares requested for withdrawal
        uint256 windowStart; // Earliest timestamp request can be executed
        uint256 windowEnd; // Last timestamp request can be executed
    }

    // token => pool info
    mapping(address => StakingPool) public pools;

    // token => user => user info
    mapping(address => mapping(address => UserInfo)) public userInfo;

    // token => user => claim request
    mapping(address => mapping(address => ClaimRequest)) public claimRequests;

    // Supported tokens
    address[] public supportedTokens;
    mapping(address => bool) public isSupportedToken;

    // Configuration
    uint256 public initialEpoch;
    uint256 public epochRate = 7 days; // Duration of each epoch
    uint256 public claimRate = 14 days; // Time until withdrawal window opens
    uint256 public claimWindow = 2 days; // Duration of withdrawal window
    uint256 public performanceFee = 200; // 2% performance fee (basis points)
    uint256 public missedClaimRequestFeeBps = 200; // 2% slash on missed claim request (basis points)
    address public feeRecipient;
    address public operator;

    // Events
    event Deposited(address indexed user, address indexed token, uint256 amount, uint256 shares);
    event Withdrawn(address indexed user, address indexed token, uint256 amount, uint256 shares);
    event RewardsClaimed(address indexed user, address indexed token, uint256 amount);
    event RewardsDistributed(address indexed token, uint256 amount);
    event PoolAdded(address indexed token);
    event PoolUpdated(address indexed token, uint256 rewardRate);
    event ClaimRequested(address indexed user, address indexed token, uint256 shares, uint256 windowStart, uint256 windowEnd);
    event ClaimRequestSlashed(address indexed user, address indexed token, uint256 requestShares, uint256 feeShares, uint256 feeAmount);
    event OperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event MissedClaimRequestFeeUpdated(uint256 previousFeeBps, uint256 newFeeBps);

    error VaultInsolvent(address token);

    constructor(address _lpToken, address _bankrollRegistry) {
        lpToken = HouseLPToken(_lpToken);
        bankrollRegistry = IBankrollRegistry(_bankrollRegistry);
        (, address treasuryAddress,, ) = bankrollRegistry.getCurrentBankroll();
        feeRecipient = treasuryAddress;
        operator = msg.sender;
        initialEpoch = block.timestamp;
    }

    modifier onlyOperatorOrOwner() {
        require(msg.sender == owner() || msg.sender == operator, "Not operator");
        _;
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

    function setOperator(address newOperator) external onlyOwner {
        require(newOperator != address(0), "Invalid address");
        emit OperatorUpdated(operator, newOperator);
        operator = newOperator;
    }

    function setMissedClaimRequestFeeBps(uint256 newFeeBps) external onlyOperatorOrOwner {
        require(newFeeBps <= 1000, "Fee too high"); // Max 10%
        emit MissedClaimRequestFeeUpdated(missedClaimRequestFeeBps, newFeeBps);
        missedClaimRequestFeeBps = newFeeBps;
    }

    /**
     * @notice Fund the bankroll without impacting existing stakers' PNL by minting shares to a recipient.
     *         Use this for treasury/top-up funding instead of direct bankroll deposits.
     */
    function fundBankroll(address token, uint256 amount, address recipient) external payable onlyOwner nonReentrant {
        require(isSupportedToken[token], "Token not supported");
        require(amount > 0, "Amount must be > 0");
        require(recipient != address(0), "Invalid recipient");

        (address bankroll, , , uint256 activatedAt) = bankrollRegistry.getCurrentBankroll();
        require(bankroll != address(0), "Bankroll not set");
        require(activatedAt > 0, "Bankroll not active");

        StakingPool storage pool = pools[token];
        require(pool.isActive, "Pool not active");

        UserInfo storage user = userInfo[token][recipient];

        updatePool(token);

        if (user.shares > 0) {
            uint256 pending = (user.shares * pool.accRewardPerShare) / 1e18 - user.rewardDebt;
            if (pending > 0) user.pendingRewards += pending;
        }

        uint256 shares = calculateShares(token, amount);

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
        user.depositedAmountNormalized += _normalizeAmount(token, amount);

        pool.totalShares += shares;

        lpToken.mint(recipient, shares);
        emit Deposited(recipient, token, amount, shares);
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

        uint256 totalAssetsNormalized = _totalAssetsNormalized(token);
        if (pool.totalShares == 0 && totalAssetsNormalized > 0) {
            pool.totalShares = totalAssetsNormalized;
            UserInfo storage seedUser = userInfo[token][feeRecipient];
            seedUser.shares += totalAssetsNormalized;
            seedUser.rewardDebt = (seedUser.shares * pool.accRewardPerShare) / 1e18;
            lpToken.mint(feeRecipient, totalAssetsNormalized);
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
        user.depositedAmountNormalized += _normalizeAmount(token, amount);

        pool.totalShares += shares;

        lpToken.mint(msg.sender, shares);
        emit Deposited(msg.sender, token, amount, shares);
    }

    function createClaimRequest(address token, uint256 shares) external nonReentrant {
        require(isSupportedToken[token], "Token not supported");
        require(shares > 0, "Shares must be > 0");
        require(!isInWithdrawWindow(), "Cannot request during claim window");

        _processMissedClaimRequest(token, msg.sender);

        ClaimRequest storage request = claimRequests[token][msg.sender];
        require(request.shares == 0, "Claim request exists");

        UserInfo storage user = userInfo[token][msg.sender];
        require(user.shares >= shares, "Insufficient shares");

        (uint256 windowStart, uint256 windowEnd,) = getNextWithdrawWindow();

        claimRequests[token][msg.sender] = ClaimRequest({shares: shares, windowStart: windowStart, windowEnd: windowEnd});

        emit ClaimRequested(msg.sender, token, shares, windowStart, windowEnd);
    }

    function slashMissedClaimRequest(address token, address user) external nonReentrant {
        bool slashed = _processMissedClaimRequest(token, user);
        require(slashed, "No missed claim request");
    }

    function withdraw(address token, uint256 shares) external nonReentrant {
        require(isSupportedToken[token], "Token not supported");
        require(shares > 0, "Shares must be > 0");

        _processMissedClaimRequest(token, msg.sender);

        ClaimRequest storage request = claimRequests[token][msg.sender];
        require(request.shares >= shares, "Invalid claim request");
        require(block.timestamp >= request.windowStart && block.timestamp <= request.windowEnd, "Claim request not in window");

        UserInfo storage user = userInfo[token][msg.sender];
        require(user.shares >= shares, "Insufficient shares");
        require(block.timestamp >= user.lastDepositTime + claimRate, "Lock period not met");

        (address bankrollAddr, , , uint256 activatedAt) = bankrollRegistry.getCurrentBankroll();
        require(bankrollAddr != address(0), "Bankroll not set");
        require(activatedAt > 0, "Bankroll not active");

        // Update pool
        StakingPool storage pool = pools[token];
        updatePool(token);

        // Claim rewards before withdrawing principal, but only when claimable.
        // This avoids reverting withdrawals when no rewards are available.
        uint256 totalRewards = user.pendingRewards + ((user.shares * pool.accRewardPerShare) / 1e18 - user.rewardDebt);
        if (totalRewards > 0) {
            _claimRewards(token);
        }

        // Redeem pro-rata against current bankroll assets
        uint256 normalizedAmount = calculateTokenAmount(token, shares);
        uint256 tokenAmount = _denormalizeAmount(token, normalizedAmount);

        IBankLP bankroll = IBankLP(bankrollAddr);
        require(bankroll.getAvailableBalance(token) >= tokenAmount, "Bankroll has insufficient balance");

        uint256 userSharesBefore = user.shares;
        user.shares -= shares;
        user.rewardDebt = (user.shares * pool.accRewardPerShare) / 1e18;
        if (userSharesBefore > 0) {
            uint256 principalReduction = (user.depositedAmountNormalized * shares) / userSharesBefore;
            user.depositedAmountNormalized -= principalReduction;
        }

        pool.totalShares -= shares;

        bool transferred = bankroll.withdrawBankroll(msg.sender, token, tokenAmount);
        require(transferred, "Withdrawal from bankroll failed");

        request.shares -= shares;
        if (request.shares == 0) {
            delete claimRequests[token][msg.sender];
        }

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
        uint256 timeUntilNextWindow,
        int256 pnl
    ) {
        UserInfo memory userInf = userInfo[token][user];
        shares = userInf.shares;
        stakedAmount = calculateTokenAmount(token, shares);
        pending = this.pendingRewards(token, user);
        (timeUntilNextWindow, , , ) = getRemainingLockup();
        pnl = int256(stakedAmount) - int256(userInf.depositedAmountNormalized);
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

    function getNextWithdrawWindow() public view returns (uint256 windowStart, uint256 windowEnd, uint256 windowEpoch) {
        uint256 currentEpoch = epoch();
        uint256 maxEpochsToCheck = (claimRate + claimWindow) / epochRate + 4;

        uint256 earliestStart = type(uint256).max;
        uint256 earliestEnd = 0;
        uint256 earliestEpoch = 0;

        for (uint256 i = 0; i < maxEpochsToCheck; i++) {
            uint256 checkEpoch = currentEpoch + i;
            uint256 epochTime = initialEpoch + (checkEpoch * epochRate);
            uint256 start = epochTime + claimRate;
            uint256 end = start + claimWindow;

            if (start > block.timestamp && start < earliestStart) {
                earliestStart = start;
                earliestEnd = end;
                earliestEpoch = checkEpoch;
            }
        }

        require(earliestStart != type(uint256).max, "No upcoming window");
        return (earliestStart, earliestEnd, earliestEpoch);
    }

    function getClaimRequest(address token, address user)
        external
        view
        returns (uint256 shares, uint256 windowStart, uint256 windowEnd, bool isActive, bool isExpired, bool canExecute)
    {
        ClaimRequest memory request = claimRequests[token][user];
        shares = request.shares;
        windowStart = request.windowStart;
        windowEnd = request.windowEnd;
        isActive = shares > 0;
        isExpired = isActive && block.timestamp > windowEnd;
        canExecute = isActive && block.timestamp >= windowStart && block.timestamp <= windowEnd;
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

    function _processMissedClaimRequest(address token, address userAddr) internal returns (bool) {
        ClaimRequest storage request = claimRequests[token][userAddr];
        if (request.shares == 0) return false;
        if (block.timestamp <= request.windowEnd) return false;

        UserInfo storage user = userInfo[token][userAddr];
        StakingPool storage pool = pools[token];

        updatePool(token);

        if (user.shares > 0) {
            uint256 pending = (user.shares * pool.accRewardPerShare) / 1e18 - user.rewardDebt;
            if (pending > 0) {
                user.pendingRewards += pending;
            }
        }

        uint256 requestShares = request.shares;
        uint256 feeShares = (requestShares * missedClaimRequestFeeBps) / 10000;
        uint256 feeAmount = 0;

        if (feeShares > 0) {
            require(user.shares >= feeShares, "Insufficient shares for slash");

            uint256 normalizedFeeAmount = calculateTokenAmount(token, feeShares);
            feeAmount = _denormalizeAmount(token, normalizedFeeAmount);

            (address bankrollAddr, , , uint256 activatedAt) = bankrollRegistry.getCurrentBankroll();
            require(bankrollAddr != address(0), "Bankroll not set");
            require(activatedAt > 0, "Bankroll not active");

            IBankLP bankroll = IBankLP(bankrollAddr);
            require(bankroll.getAvailableBalance(token) >= feeAmount, "Bankroll has insufficient balance");

            bool feeTransferred = bankroll.withdrawBankroll(feeRecipient, token, feeAmount);
            require(feeTransferred, "Slash fee transfer failed");

            uint256 userSharesBefore = user.shares;
            user.shares -= feeShares;
            pool.totalShares -= feeShares;

            if (userSharesBefore > 0) {
                uint256 principalReduction = (user.depositedAmountNormalized * feeShares) / userSharesBefore;
                user.depositedAmountNormalized -= principalReduction;
            }

            lpToken.burn(userAddr, feeShares);
        }

        user.rewardDebt = (user.shares * pool.accRewardPerShare) / 1e18;

        delete claimRequests[token][userAddr];

        emit ClaimRequestSlashed(userAddr, token, requestShares, feeShares, feeAmount);
        return true;
    }

    // ========== RECEIVE ETH ==========

    receive() external payable {}
}
