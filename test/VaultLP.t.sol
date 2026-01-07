// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {VaultLP, HouseLPToken} from "../contracts/bankroll/facets/VaultLP.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockBankLP
 * @notice Mock bankroll for testing
 */
contract MockBankLP {
    mapping(address => uint256) public balances;

    function fundBankroll(address token, uint256 amount) external payable {
        if (token == address(0)) {
            balances[address(0)] += msg.value;
        } else {
            IERC20(token).transferFrom(msg.sender, address(this), amount);
            balances[token] += amount;
        }
    }

    function getAvailableBalance(address token) external view returns (uint256) {
        if (token == address(0)) {
            return address(this).balance;
        }
        return IERC20(token).balanceOf(address(this));
    }

    function execute(address to, uint256 value, bytes calldata data) external returns (bool success, bytes memory result) {
        if (value > 0) {
            (success, ) = to.call{value: value}("");
            return (success, "");
        }
        
        (success, result) = to.call(data);
        return (success, result);
    }

    receive() external payable {
        balances[address(0)] += msg.value;
    }
}

/**
 * @title MockERC20
 * @notice Mock ERC20 token for testing
 */
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title VaultLPTest
 * @notice Comprehensive test suite for VaultLP staking contract
 */
contract VaultLPTest is Test {
    VaultLP public vault;
    HouseLPToken public lpToken;
    MockBankLP public bankroll;

    MockERC20 public wbtc;
    MockERC20 public usdc;
    MockERC20 public dai;

    address public owner;
    address public feeRecipient;
    address public alice;
    address public bob;
    address public carol;

    uint256 constant INITIAL_BALANCE = 1000 ether;
    uint256 constant EPOCH_RATE = 7 days;
    uint256 constant CLAIM_RATE = 14 days;
    uint256 constant CLAIM_WINDOW = 2 days;

    event Deposited(address indexed user, address indexed token, uint256 amount, uint256 shares);
    event Withdrawn(address indexed user, address indexed token, uint256 amount, uint256 shares);
    event RewardsClaimed(address indexed user, address indexed token, uint256 amount);
    event RewardsDistributed(address indexed token, uint256 amount);

    function setUp() public {
        // Setup accounts
        owner = address(this);
        feeRecipient = makeAddr("feeRecipient");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");

        // Deploy contracts
        bankroll = new MockBankLP();
        lpToken = new HouseLPToken();
        vault = new VaultLP(address(lpToken), address(bankroll), feeRecipient);
        
        // Set vault in LP token
        lpToken.setVault(address(vault));

        // Deploy mock tokens
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai Stablecoin", "DAI", 18);

        // Add pools
        vault.addPool(address(0), 0.01 ether); // ETH pool with 0.01 ETH/second rewards
        vault.addPool(address(usdc), 10e6); // USDC pool with 10 USDC/second rewards
        vault.addPool(address(dai), 5 ether); // DAI pool with 5 DAI/second rewards

        // Fund test accounts
        vm.deal(alice, INITIAL_BALANCE);
        vm.deal(bob, INITIAL_BALANCE);
        vm.deal(carol, INITIAL_BALANCE);

        usdc.mint(alice, 100000e6);
        usdc.mint(bob, 100000e6);
        usdc.mint(carol, 100000e6);

        dai.mint(alice, 100000 ether);
        dai.mint(bob, 100000 ether);
        dai.mint(carol, 100000 ether);
    }

    // ========== DEPOSIT TESTS ==========

    function testDepositETH() public {
        uint256 depositAmount = 10 ether;
        
        vm.startPrank(alice);
        
        vm.expectEmit(true, true, false, true);
        emit Deposited(alice, address(0), depositAmount, depositAmount);
        
        vault.deposit{value: depositAmount}(address(0), depositAmount);
        
        // Check balances
        assertEq(lpToken.balanceOf(alice), depositAmount);
        assertEq(address(alice).balance, INITIAL_BALANCE - depositAmount);
        
        // Check pool state
        (
            uint256 totalStaked, 
            uint256 totalShares,
            ,,,
            bool isActive,
            
        ) = vault.pools(address(0));
        assertEq(totalStaked, depositAmount);
        assertEq(totalShares, depositAmount);
        assertTrue(isActive);
        
        // Check user info
        (uint256 amount, uint256 shares,,,) = vault.userInfo(address(0), alice);
        assertEq(amount, depositAmount);
        assertEq(shares, depositAmount);
        
        vm.stopPrank();
    }

    function testDepositUSDC() public {
        uint256 depositAmount = 1000e6; // 1000 USDC
        
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        
        vault.deposit(address(usdc), depositAmount);
        
        // USDC has 6 decimals, shares should be normalized to 18 decimals
        uint256 expectedShares = depositAmount * 1e12; // 1000e6 * 1e12 = 1000e18
        
        assertEq(lpToken.balanceOf(alice), expectedShares);
        assertEq(usdc.balanceOf(alice), 100000e6 - depositAmount);
        
        vm.stopPrank();
    }

    function testDepositMultipleUsers() public {
        uint256 aliceDeposit = 50 ether;
        uint256 bobDeposit = 30 ether;
        uint256 carolDeposit = 20 ether;
        
        // Alice deposits first
        vm.prank(alice);
        vault.deposit{value: aliceDeposit}(address(0), aliceDeposit);
        
        // Bob deposits
        vm.prank(bob);
        vault.deposit{value: bobDeposit}(address(0), bobDeposit);
        
        // Carol deposits
        vm.prank(carol);
        vault.deposit{value: carolDeposit}(address(0), carolDeposit);
        
        // Check total pool state
        (uint256 totalStaked, uint256 totalShares,,,, bool isActive,) = vault.pools(address(0));
        assertEq(totalStaked, aliceDeposit + bobDeposit + carolDeposit);
        assertEq(totalShares, aliceDeposit + bobDeposit + carolDeposit);
        assertTrue(isActive);
        
        // Check individual LP balances
        assertEq(lpToken.balanceOf(alice), aliceDeposit);
        assertEq(lpToken.balanceOf(bob), bobDeposit);
        assertEq(lpToken.balanceOf(carol), carolDeposit);
    }

    function testDepositRevertsOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert("Amount must be > 0");
        vault.deposit(address(0), 0);
    }

    function testDepositRevertsOnUnsupportedToken() public {
        address randomToken = makeAddr("randomToken");
        
        vm.prank(alice);
        vm.expectRevert("Token not supported");
        vault.deposit(randomToken, 100 ether);
    }

    function testDepositRevertsOnInactivePool() public {
        address token = address(wbtc);

        // Add and immediately deactivate pool
        vault.addPool(token, 1 ether);
        vault.updatePool(token, false);

        // For now, we'll skip this test as the contract doesn't have a deactivate function
        vm.expectRevert('Pool not active');
        vault.deposit(token, 100 ether);

    }

    // ========== WITHDRAWAL TESTS ==========

    function testWithdrawDuringWithdrawalWindow() public {
        uint256 depositAmount = 10 ether;
        
        // Alice deposits
        vm.startPrank(alice);
        vault.deposit{value: depositAmount}(address(0), depositAmount);
        
        // Calculate when withdrawal window opens
        uint256 epochTime = vault.epoch() * vault.epochRate();
        uint256 nextClaimWindow = epochTime + vault.claimRate();
        
        // Skip to withdrawal window
        skip(nextClaimWindow);
        
        // Check we're in window
        assertTrue(vault.isInWithdrawWindow(), "Should be in withdrawal window");
        
        // Withdraw
        vm.expectEmit(true, true, false, true);
        emit Withdrawn(alice, address(0), depositAmount, depositAmount);
        
        vault.withdraw(address(0), depositAmount);
        
        // Check balances
        assertEq(lpToken.balanceOf(alice), 0);
        assertEq(address(alice).balance, INITIAL_BALANCE); // Should get back original amount
        
        // Check pool state
        (uint256 totalStaked, uint256 totalShares,,,,, ) = vault.pools(address(0));
        assertEq(totalStaked, 0);
        assertEq(totalShares, 0);
        
        vm.stopPrank();
    }

    function testWithdrawPartialShares() public {
        uint256 depositAmount = 100 ether;
        uint256 withdrawShares = 30 ether;
        
        vm.startPrank(alice);
        vault.deposit{value: depositAmount}(address(0), depositAmount);
        
        // Fast forward to withdrawal window
        vm.warp(block.timestamp + CLAIM_RATE + 1);
        
        vault.withdraw(address(0), withdrawShares);
        
        // Check remaining LP tokens
        assertEq(lpToken.balanceOf(alice), depositAmount - withdrawShares);
        
        // Check user info
        (, uint256 shares,,,) = vault.userInfo(address(0), alice);
        assertEq(shares, depositAmount - withdrawShares);
        
        vm.stopPrank();
    }

    function testWithdrawRevertsOutsideWindow() public {
        uint256 depositAmount = 10 ether;
        
        vm.startPrank(alice);
        vault.deposit{value: depositAmount}(address(0), depositAmount);
        
        // Try to withdraw immediately (before window)
        vm.expectRevert("Not in valid withdrawal window");
        vault.withdraw(address(0), depositAmount);
        
        // Try 1 day later (still before window)
        skip(1 days);
        vm.expectRevert("Not in valid withdrawal window");
        vault.withdraw(address(0), depositAmount);
        
        // Skip past the withdrawal window
        skip(CLAIM_RATE + CLAIM_WINDOW);
        vm.expectRevert("Not in valid withdrawal window");
        vault.withdraw(address(0), depositAmount);
        
        vm.stopPrank();
    }

    function testWithdrawRevertsOnInsufficientShares() public {
        uint256 depositAmount = 10 ether;
        
        vm.startPrank(alice);
        vault.deposit{value: depositAmount}(address(0), depositAmount);
        
        // Skip to withdrawal window
        skip(CLAIM_RATE);
        
        vm.expectRevert("Insufficient shares");
        vault.withdraw(address(0), depositAmount + 1 ether);
        
        vm.stopPrank();
    }

    function testWithdrawRevertsOnZeroShares() public {
        vm.prank(alice);
        vm.expectRevert("Shares must be > 0");
        vault.withdraw(address(0), 0);
    }

    // ========== REWARD TESTS ==========

    function testRewardAccumulation() public {
        uint256 depositAmount = 100 ether;
        
        // Alice deposits
        vm.prank(alice);
        vault.deposit{value: depositAmount}(address(0), depositAmount);
        
        // Skip 1 hour
        skip(1 hours);
        
        // Check pending rewards (0.01 ETH/second * 3600 seconds = 36 ETH)
        uint256 pending = vault.pendingRewards(address(0), alice);
        assertEq(pending, 0.01 ether * 3600);
    }

    function testRewardDistribution() public {
        uint256 depositAmount = 100 ether;
        uint256 rewardAmount = 50 ether;
        
        // Alice deposits
        vm.prank(alice);
        vault.deposit{value: depositAmount}(address(0), depositAmount);
        
        // Owner distributes rewards
        vm.expectEmit(true, false, false, true);
        emit RewardsDistributed(address(0), rewardAmount);
        
        vault.distributeRewards{value: rewardAmount}(address(0), rewardAmount);
        
        // Check pending rewards
        uint256 pending = vault.pendingRewards(address(0), alice);
        assertEq(pending, rewardAmount);
    }

    function testClaimRewards() public {
        uint256 depositAmount = 100 ether;
        uint256 rewardAmount = 50 ether;
        
        // Alice deposits
        vm.startPrank(alice);
        vault.deposit{value: depositAmount}(address(0), depositAmount);
        vm.stopPrank();
        
        // Distribute rewards
        vault.distributeRewards{value: rewardAmount}(address(0), rewardAmount);
        
        // Alice claims rewards
        uint256 balanceBefore = address(alice).balance;
        
        vm.prank(alice);
        vault.claimRewards(address(0));
        
        // Calculate expected net rewards (98% after 2% fee)
        uint256 fee = (rewardAmount * 200) / 10000;
        uint256 netRewards = rewardAmount - fee;
        
        assertEq(address(alice).balance - balanceBefore, netRewards);
        assertEq(address(feeRecipient).balance, fee);
    }

    function testRewardDistributionMultipleUsers() public {
        uint256 aliceDeposit = 60 ether;
        uint256 bobDeposit = 40 ether;
        uint256 rewardAmount = 100 ether;
        
        // Alice deposits 60%
        vm.prank(alice);
        vault.deposit{value: aliceDeposit}(address(0), aliceDeposit);
        
        // Bob deposits 40%
        vm.prank(bob);
        vault.deposit{value: bobDeposit}(address(0), bobDeposit);
        
        // Distribute rewards
        vault.distributeRewards{value: rewardAmount}(address(0), rewardAmount);
        
        // Check rewards split (60/40)
        uint256 alicePending = vault.pendingRewards(address(0), alice);
        uint256 bobPending = vault.pendingRewards(address(0), bob);
        
        assertEq(alicePending, 60 ether); // 60% of 100 ETH
        assertEq(bobPending, 40 ether);   // 40% of 100 ETH
    }

    function testRewardRateUpdate() public {
        uint256 newRate = 0.05 ether;
        
        vault.updateRewardRate(address(0), newRate);
        
        (,,,, uint256 rewardRate,,) = vault.pools(address(0));
        assertEq(rewardRate, newRate);
    }

    // ========== TIME-BASED TESTS ==========

    function testWithdrawalWindowTiming() public {
        uint256 depositAmount = 50 ether;
        
        vm.startPrank(alice);
        
        // Deposit
        vault.deposit{value: depositAmount}(address(0), depositAmount);
        
        // Before window - should fail
        skip(EPOCH_RATE);
        assertFalse(vault.isInWithdrawWindow(), "Should not be in window yet");
        vm.expectRevert("Not in valid withdrawal window");
        vault.withdraw(address(0), depositAmount);
        
        // Get time until next window and skip to it
        (uint256 timeUntilNextWindow,, bool canWithdraw,) = vault.getRemainingLockup();
        skip(timeUntilNextWindow);
        
        // Now in window - should succeed
        assertTrue(vault.isInWithdrawWindow(), "Should be in window");
        (, , canWithdraw,) = vault.getRemainingLockup();
        assertTrue(canWithdraw, "Should be able to withdraw");
        
        // Skip to end of window
        skip(CLAIM_WINDOW);
        assertTrue(vault.isInWithdrawWindow(), "Should still be in window");
        
        // After window - should fail
        skip(1);
        assertFalse(vault.isInWithdrawWindow(), "Should not be in window anymore");
        vm.expectRevert("Not in valid withdrawal window");
        vault.withdraw(address(0), depositAmount);
        
        vm.stopPrank();
    }

    function testRewardsAccrueOverTime() public {
        uint256 depositAmount = 100 ether;
        
        vm.prank(alice);
        vault.deposit{value: depositAmount}(address(0), depositAmount);
        
        // Check rewards at different time intervals
        skip(1 hours);
        uint256 rewards1h = vault.pendingRewards(address(0), alice);
        
        skip(1 hours);
        uint256 rewards2h = vault.pendingRewards(address(0), alice);
        
        skip(1 hours);
        uint256 rewards3h = vault.pendingRewards(address(0), alice);
        
        // Rewards should increase linearly
        assertGt(rewards2h, rewards1h);
        assertGt(rewards3h, rewards2h);
        assertEq(rewards3h - rewards2h, rewards2h - rewards1h);
    }

    // ========== SHARE CALCULATION TESTS ==========

    function testShareCalculationWithDifferentDecimals() public {
        uint256 usdcAmount = 1000e6; // 1000 USDC (6 decimals)
        uint256 ethAmount = 1 ether;  // 1 ETH (18 decimals)
        
        // Alice deposits USDC
        vm.startPrank(alice);
        usdc.approve(address(vault), usdcAmount);
        vault.deposit(address(usdc), usdcAmount);
        vm.stopPrank();
        
        // Bob deposits ETH
        vm.prank(bob);
        vault.deposit{value: ethAmount}(address(0), ethAmount);
        
        // Both should get 1:1 shares normalized to 18 decimals
        // USDC: 1000e6 → 1000e18 shares
        // ETH: 1e18 → 1e18 shares
        assertEq(lpToken.balanceOf(alice), 1000 ether);
        assertEq(lpToken.balanceOf(bob), 1 ether);
    }

    function testCalculateTokenAmountFromShares() public {
        uint256 depositAmount = 100 ether;
        
        vm.prank(alice);
        vault.deposit{value: depositAmount}(address(0), depositAmount);
        
        // Calculate amount for half shares
        uint256 amount = vault.calculateTokenAmount(address(0), 50 ether);
        assertEq(amount, 50 ether);
    }

    // ========== ADMIN TESTS ==========

    function testSetEpochRate() public {
        uint256 newEpochRate = 14 days;
        vault.setEpochRate(newEpochRate);
        assertEq(vault.epochRate(), newEpochRate);
    }

    function testSetClaimRate() public {
        uint256 newClaimRate = 21 days;
        vault.setClaimRate(newClaimRate);
        assertEq(vault.claimRate(), newClaimRate);
    }

    function testSetClaimWindow() public {
        uint256 newClaimWindow = 3 days;
        vault.setClaimWindow(newClaimWindow);
        assertEq(vault.claimWindow(), newClaimWindow);
    }

    function testSetPerformanceFee() public {
        uint256 newFee = 500; // 5%
        vault.setPerformanceFee(newFee);
        assertEq(vault.performanceFee(), newFee);
    }

    function testSetPerformanceFeeRevertsOnTooHigh() public {
        vm.expectRevert("Fee too high");
        vault.setPerformanceFee(1001); // Over 10%
    }

    function testAddPoolRevertsOnDuplicate() public {
        vm.expectRevert("Pool already exists");
        vault.addPool(address(0), 0.01 ether);
    }

    // ========== VIEW FUNCTION TESTS ==========

    function testGetTVL() public {
        uint256 aliceDeposit = 50 ether;
        uint256 bobDeposit = 30 ether;
        
        vm.prank(alice);
        vault.deposit{value: aliceDeposit}(address(0), aliceDeposit);
        
        vm.prank(bob);
        vault.deposit{value: bobDeposit}(address(0), bobDeposit);
        
        uint256 tvl = vault.getTVL(address(0));
        assertEq(tvl, aliceDeposit + bobDeposit);
    }

    function testGetUserPosition() public {
        uint256 depositAmount = 100 ether;
        
        vm.prank(alice);
        vault.deposit{value: depositAmount}(address(0), depositAmount);
        
        (uint256 amount, uint256 shares, uint256 pending, uint256 timeUntilWindow) = 
            vault.getUserPosition(address(0), alice);
        
        assertEq(amount, depositAmount);
        assertEq(shares, depositAmount);
        assertEq(pending, 0); // No rewards yet
        assertGt(timeUntilWindow, 0); // Should have time until next window
    }

    function testGetAPY() public {
        uint256 depositAmount = 100 ether;
        
        vm.prank(alice);
        vault.deposit{value: depositAmount}(address(0), depositAmount);
        
        uint256 apy = vault.getAPY(address(0));
        
        // APY = (rewardRate * 365 days / totalStaked) * 100
        // APY = (0.01 ether * 31536000 / 100 ether) * 100 = 3153.6%
        uint256 expectedAPY = (0.01 ether * 365 days * 100 * 1e18) / depositAmount;
        assertEq(apy, expectedAPY);
    }

    // ========== INTEGRATION TESTS ==========

    function testFullUserJourney() public {
        uint256 depositAmount = 50 ether;
        uint256 rewardAmount = 25 ether;
        
        // 1. Alice deposits
        vm.startPrank(alice);
        vault.deposit{value: depositAmount}(address(0), depositAmount);
        assertEq(lpToken.balanceOf(alice), depositAmount);
        vm.stopPrank();
        
        // 2. Time passes and rewards accrue
        skip(1 days);
        
        // 3. Owner distributes additional rewards
        vault.distributeRewards{value: rewardAmount}(address(0), rewardAmount);
        
        // 4. Alice checks pending rewards
        uint256 pending = vault.pendingRewards(address(0), alice);
        assertGt(pending, 0);
        
        // Fund the vault with enough ETH to cover all rewards (time-based + distributed)
        vm.deal(address(vault), pending);
        
        // 5. Alice claims rewards
        vm.prank(alice);
        vault.claimRewards(address(0));
        
        // 6. Alice waits for withdrawal window
        (uint256 timeUntilNextWindow,,,) = vault.getRemainingLockup();
        skip(timeUntilNextWindow);
        
        // 7. Alice withdraws during window
        vm.prank(alice);
        vault.withdraw(address(0), depositAmount);
        
        assertEq(lpToken.balanceOf(alice), 0);
    }

    function testMultipleUsersOverTime() public {
        // Alice deposits at T=0
        vm.prank(alice);
        vault.deposit{value: 60 ether}(address(0), 60 ether);
        
        // Skip 1 day
        skip(1 days);
        
        // Bob deposits at T=1day
        vm.prank(bob);
        vault.deposit{value: 40 ether}(address(0), 40 ether);
        
        // Skip another day
        skip(1 days);
        
        // Distribute rewards
        vault.distributeRewards{value: 100 ether}(address(0), 100 ether);
        
        // Alice should have more rewards (was there longer)
        uint256 aliceRewards = vault.pendingRewards(address(0), alice);
        uint256 bobRewards = vault.pendingRewards(address(0), bob);
        
        assertGt(aliceRewards, bobRewards);
    }

    // ========== EDGE CASE TESTS ==========

    function testFirstDepositorGetsOneToOneShares() public {
        uint256 amount = 123.456789 ether;
        
        vm.prank(alice);
        vault.deposit{value: amount}(address(0), amount);
        
        assertEq(lpToken.balanceOf(alice), amount);
    }

    function testZeroRewardsDoNotRevert() public {
        uint256 depositAmount = 10 ether;
        
        vm.prank(alice);
        vault.deposit{value: depositAmount}(address(0), depositAmount);
        
        // Try to claim when no rewards
        vm.prank(alice);
        vm.expectRevert("No rewards to claim");
        vault.claimRewards(address(0));
    }

    // ========== EPOCH TESTS ==========

    function testEpochProgression() public {
        uint256 startEpoch = vault.epoch();
        assertEq(startEpoch, 0, "Should start at epoch 0");
        
        // Skip 7 days (1 epoch)
        skip(EPOCH_RATE);
        assertEq(vault.epoch(), 1, "Should be epoch 1");
        
        // Skip another 7 days
        skip(EPOCH_RATE);
        assertEq(vault.epoch(), 2, "Should be epoch 2");
        
        // Skip 3.5 days (mid-epoch)
        skip(EPOCH_RATE / 2);
        assertEq(vault.epoch(), 2, "Should still be epoch 2");
    }

    function testGetRemainingLockup() public {
        uint256 depositAmount = 10 ether;
        
        vm.prank(alice);
        vault.deposit{value: depositAmount}(address(0), depositAmount);
        
        (uint256 timeUntilWindow, uint256 epochEnd, bool canWithdraw, uint256 currentEpoch) = 
            vault.getRemainingLockup();
        
        assertGt(timeUntilWindow, 0, "Should have time until window");
        assertGt(epochEnd, block.timestamp, "Epoch end should be in future");
        assertFalse(canWithdraw, "Should not be able to withdraw yet");
        assertEq(currentEpoch, 0, "Should be in epoch 0");
    }

    function testGetRemainingLockupDuringWindow() public {
        uint256 depositAmount = 10 ether;
        
        vm.prank(alice);
        vault.deposit{value: depositAmount}(address(0), depositAmount);
        
        // Skip to withdrawal window
        skip(CLAIM_RATE);
        
        (uint256 timeUntilWindow, , bool canWithdraw, ) = 
            vault.getRemainingLockup();
        
        assertEq(timeUntilWindow, 0, "Should be 0 when in window");
        assertTrue(canWithdraw, "Should be able to withdraw");
    }

    function testMultipleWithdrawalWindows() public {
        uint256 depositAmount = 50 ether;
        
        vm.prank(alice);
        vault.deposit{value: depositAmount}(address(0), depositAmount);
        
        // First window at CLAIM_RATE (14 days)
        skip(CLAIM_RATE);
        assertTrue(vault.isInWithdrawWindow(), "Should be in first window");
        
        // After first window closes
        skip(CLAIM_WINDOW + 1);
        assertFalse(vault.isInWithdrawWindow(), "Should not be in window");
        
        // Second window at next epoch
        skip(EPOCH_RATE - CLAIM_WINDOW - 1);
        assertTrue(vault.isInWithdrawWindow(), "Should be in second window");
    }

    function testWithdrawInDifferentEpochWindows() public {
        uint256 depositAmount = 100 ether;
        uint256 firstWithdraw = 30 ether;
        uint256 secondWithdraw = 70 ether;
        
        vm.startPrank(alice);
        vault.deposit{value: depositAmount}(address(0), depositAmount);
        
        // First withdrawal in first window
        skip(CLAIM_RATE);
        vault.withdraw(address(0), firstWithdraw);
        assertEq(lpToken.balanceOf(alice), depositAmount - firstWithdraw);
        
        // Try to withdraw outside window (should fail)
        skip(CLAIM_WINDOW + 1);
        vm.expectRevert("Not in valid withdrawal window");
        vault.withdraw(address(0), secondWithdraw);
        
        // Second withdrawal in next epoch's window
        (uint256 timeUntilNextWindow,,,) = vault.getRemainingLockup();
        skip(timeUntilNextWindow);
        vault.withdraw(address(0), secondWithdraw);
        assertEq(lpToken.balanceOf(alice), 0);
        
        vm.stopPrank();
    }

    function testEpochRateUpdate() public {
        uint256 newEpochRate = 10 days;
        vault.setEpochRate(newEpochRate);
        
        assertEq(vault.epochRate(), newEpochRate);
        
        // Verify epoch calculation with new rate
        skip(newEpochRate);
        assertEq(vault.epoch(), 1, "Should be epoch 1 with new rate");
    }

    function testCannotSetZeroEpochRate() public {
        vm.expectRevert("Invalid epoch rate");
        vault.setEpochRate(0);
    }

    function testRemainingLockupDetailed() public {
        uint256 amount = 500 ether;

        // Simulate time pass with skip
        skip(1000000);  // Skip about 11.57 days

        vm.startPrank(alice);
        
        // Deposit tokens
        vault.deposit{value: amount}(address(0), amount);

        // First check, time until next withdrawal window
        (
            uint256 timeUntilNextWindow,
            uint256 currentEpochEnd,
            bool canWithdraw,
            uint256 currentEpoch
        ) = vault.getRemainingLockup();

        // Log values for debugging
        console.log("First Check:");
        console.log("timeUntilNextWindow:", timeUntilNextWindow);
        console.log("currentEpochEnd:", currentEpochEnd);
        console.log("canWithdraw:", canWithdraw);
        console.log("currentEpoch:", currentEpoch);

        // Should not be able to withdraw yet
        assertFalse(canWithdraw, "Should not be able to withdraw yet");
        assertGt(timeUntilNextWindow, 0, "Should have time until next window");

        // Skip until the withdrawal window is open
        skip(timeUntilNextWindow);

        // Second check, after skipping time until next withdrawal window
        (
            timeUntilNextWindow,
            currentEpochEnd,
            canWithdraw,
            currentEpoch
        ) = vault.getRemainingLockup();

        console.log("Second Check (After Skipping):");
        console.log("timeUntilNextWindow:", timeUntilNextWindow);
        console.log("currentEpochEnd:", currentEpochEnd);
        console.log("canWithdraw:", canWithdraw);
        console.log("currentEpoch:", currentEpoch);

        // Should be able to withdraw now
        assertTrue(canWithdraw, "Should be able to withdraw in window");
        assertEq(timeUntilNextWindow, 0, "Time should be 0 in window");
        
        // Actually withdraw to confirm
        vault.withdraw(address(0), amount);
        assertEq(lpToken.balanceOf(alice), 0, "Should have withdrawn all LP tokens");

        vm.stopPrank();
    }

    function testWithdrawalWindowWithCustomTiming() public {
        // Set custom timing: 3 day epochs, 5 day claim rate, 1 day window
        vault.setEpochRate(3 days);
        vault.setClaimRate(5 days);
        vault.setClaimWindow(1 days);
        
        uint256 depositAmount = 50 ether;
        
        vm.prank(alice);
        vault.deposit{value: depositAmount}(address(0), depositAmount);
        
        // Should not be in window before 5 days
        skip(4 days);
        assertFalse(vault.isInWithdrawWindow());
        
        // Should be in window at 5 days
        skip(1 days);
        assertTrue(vault.isInWithdrawWindow());
        
        // Should still be in window at 5.5 days
        skip(12 hours);
        assertTrue(vault.isInWithdrawWindow());
        
        // Should not be in window after 6 days (5 + 1 day window)
        skip(12 hours + 1);
        assertFalse(vault.isInWithdrawWindow());
    }

    receive() external payable {}
}
