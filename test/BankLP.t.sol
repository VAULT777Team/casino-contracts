// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {BankLP} from "../contracts/bankroll/facets/BankLP.sol";
import {Treasury} from "../contracts/treasury/Treasury.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal IToken-compatible reward token.
contract MockRewardToken is ERC20 {
    constructor() ERC20("Play Reward", "PLAY") {}

    function mint(uint256 amount) external {
        _mint(msg.sender, amount);
    }

    // Unused by BankLP.claimRewards, but present in BankLP's IToken interface.
    function setGovernor(address, bool) external {}
    function canMint(address) external pure returns (bool) { return true; }
    function mintDaily() external {}
}

contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "ETH transfer failed");
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

// A contract that rejects any incoming ETH transfers.
// Used to test vulnerability where BankLP tries to send ETH to a player
// that cannot accept ETH
contract RejectETH {
    receive() external payable {
        revert("no thanks");
    }
}

contract BankLPTest is Test {
    BankLP public bankroll;
    Treasury public treasury;

    MockERC20 public token;
    MockRewardToken public rewardToken;
    MockWETH public weth;

    address public owner;
    address public lp;
    address public game;
    address public creator;
    address public player;

    function setUp() public {
        owner = address(this);
        lp = makeAddr("lp");
        game = makeAddr("game");
        creator = makeAddr("creator");
        player = makeAddr("player");

        treasury = new Treasury();
        bankroll = new BankLP(address(treasury), address(0), address(0));

        token = new MockERC20("Mock Token", "MOCK");
        rewardToken = new MockRewardToken();
        weth = new MockWETH();

        bankroll.setLiquidityPool(lp);
        bankroll.setWrappedAddress(address(weth));

        // Mark game as trusted for onlyGame-gated methods.
        bankroll.setGame(game, true);

        // Pre-fund some accounts.
        vm.deal(game, 100 ether);
        vm.deal(player, 1 ether);
    }

    function testOnlyOwnerGuards() public {
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert("Not an owner");
        bankroll.setGame(attacker, true);

        vm.prank(attacker);
        vm.expectRevert("Not an owner");
        bankroll.setTokenAddress(address(token), true);

        vm.prank(attacker);
        vm.expectRevert("Not an owner");
        bankroll.setWrappedAddress(address(0xBEEF));
    }

    function testTransferPayoutRevertsIfCallerNotGame() public {
        vm.expectRevert(BankLP.InvalidGameAddress.selector);
        bankroll.transferPayout(player, 1, address(token));
    }

    function testTransferPayoutERC20() public {
        uint256 payout = 123e18;
        token.mint(address(bankroll), payout);

        vm.prank(game);
        bankroll.transferPayout(player, payout, address(token));

        assertEq(token.balanceOf(player), payout);
    }

    function testTransferPayoutETHWrapsWhenPlayerRejectsETH() public {
        RejectETH rejector = new RejectETH();

        vm.deal(address(bankroll), 10 ether);

        vm.prank(game);
        bankroll.transferPayout(address(rejector), 1 ether, address(0));

        // Player rejected ETH, so they should receive WETH.
        assertEq(weth.balanceOf(address(rejector)), 1 ether);
    }

    function testReserveReleaseAndWithdrawRespectsReservedFunds() public {
        uint256 total = 1000e18;
        uint256 reserveAmt = 400e18;

        token.mint(address(bankroll), total);

        vm.prank(game);
        bankroll.reserveFunds(address(token), reserveAmt);

        assertEq(bankroll.reservedFunds(address(token)), reserveAmt);
        assertEq(bankroll.getAvailableBalance(address(token)), total - reserveAmt);

        // LP cannot withdraw into reserved funds.
        vm.prank(lp);
        vm.expectRevert("Insufficient available token balance");
        bankroll.withdrawBankroll(lp, address(token), total - reserveAmt + 1);

        // LP can withdraw exactly the available amount.
        vm.prank(lp);
        bankroll.withdrawBankroll(lp, address(token), total - reserveAmt);

        assertEq(token.balanceOf(lp), total - reserveAmt);
        assertEq(token.balanceOf(address(bankroll)), reserveAmt);

        // Release the reserve and withdraw the rest.
        vm.prank(game);
        bankroll.releaseFunds(address(token), reserveAmt);

        vm.prank(lp);
        bankroll.withdrawBankroll(lp, address(token), reserveAmt);

        assertEq(token.balanceOf(lp), total);
        assertEq(token.balanceOf(address(bankroll)), 0);
    }

    function testDepositERC20CollectsFeesAndPaysTreasury() public {
        uint256 amount = 10_000e18; // divisible by 100 for clean fee math
        uint256 fee = (amount * 2) / 100; // 2%
        uint256 treasuryFee = fee / 2; // 1% (since creatorShare == 0)

        token.mint(game, amount);

        vm.startPrank(game);
        token.approve(address(bankroll), amount);
        bankroll.deposit(address(token), amount);
        vm.stopPrank();

        assertEq(bankroll.fees(address(token)), fee);
        assertEq(token.balanceOf(address(treasury)), treasuryFee);
        assertEq(token.balanceOf(address(bankroll)), amount - treasuryFee);
    }

    function testDepositERC20WithCreatorShare() public {
        uint256 amount = 10_000e18;
        uint256 fee = (amount * 2) / 100; // 2%
        uint256 creatorBps = 1000; // 10% of fee
        uint256 creatorShare = (fee * creatorBps) / 10_000;
        uint256 treasuryFee = (fee - creatorShare) / 2;

        bankroll.setGameCreator(game, creator, creatorBps);

        token.mint(game, amount);
        vm.startPrank(game);
        token.approve(address(bankroll), amount);
        bankroll.deposit(address(token), amount);
        vm.stopPrank();

        assertEq(bankroll.fees(address(token)), fee);
        assertEq(token.balanceOf(creator), creatorShare);
        assertEq(token.balanceOf(address(treasury)), treasuryFee);
        assertEq(token.balanceOf(address(bankroll)), amount - creatorShare - treasuryFee);
    }

    function testSetGameCreatorRevertsIfTooHigh() public {
        vm.expectRevert("Fee too high");
        bankroll.setGameCreator(game, creator, 2001);
    }

    function testClaimRewardsHappyPath() public {
        bankroll.setPlayRewardToken(address(rewardToken));

        uint256 reward = bankroll.minRewardPayout() + 1;

        vm.prank(game);
        bankroll.addPlayerReward(player, reward);

        assertEq(bankroll.playRewards(player), reward);

        vm.prank(player);
        bankroll.claimRewards();

        assertEq(bankroll.playRewards(player), 0);
        assertEq(rewardToken.balanceOf(player), reward);
    }

    function testClaimRewardsRevertsIfBelowOrEqualThreshold() public {
        bankroll.setPlayRewardToken(address(rewardToken));

        uint256 reward = bankroll.minRewardPayout(); // equal should fail (strict >)

        vm.prank(game);
        bankroll.addPlayerReward(player, reward);

        vm.prank(player);
        vm.expectRevert("not enough rewards acquired");
        bankroll.claimRewards();
    }

    function testSuspensionLifecycle() public {
        uint256 duration = 100;

        vm.prank(player);
        bankroll.suspend(duration);

        (bool isSuspended, uint256 until) = bankroll.isPlayerSuspended(player);
        assertTrue(isSuspended);
        assertGt(until, block.timestamp);

        // Can't suspend again while suspended.
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(BankLP.AlreadySuspended.selector, until));
        bankroll.suspend(duration);

        // Can't lift early.
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(BankLP.TimeRemaingOnSuspension.selector, until));
        bankroll.liftSuspension();

        // Can lift after time passes.
        skip(duration + 1);

        vm.prank(player);
        bankroll.liftSuspension();

        (isSuspended, ) = bankroll.isPlayerSuspended(player);
        assertFalse(isSuspended);
    }

    function testExecuteOnlyRegistryOrOwner() public {
        address recipient = makeAddr("recipient");
        vm.deal(address(bankroll), 2 ether);

        (bool success, ) = bankroll.execute(recipient, 1 ether, "");
        assertTrue(success);
        assertEq(recipient.balance, 1 ether);

        vm.prank(makeAddr("notOwnerOrRegistry"));
        vm.expectRevert("Not bankroll registry or owner");
        bankroll.execute(recipient, 0, abi.encodeWithSignature("doesNotMatter()"));
    }

    receive() external payable {}
}
