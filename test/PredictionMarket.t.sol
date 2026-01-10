// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../contracts/PredictionMarket.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 1000000 * 1e6);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract PredictionMarketTest is Test {
    PredictionMarket public market;
    MockUSDC public usdc;

    address public creator = address(0x1);
    address public trader1 = address(0x2);
    address public trader2 = address(0x3);
    address public oracle = address(0x4);

    function setUp() public {
        market = new PredictionMarket();
        usdc = new MockUSDC();

        // Distribute USDC
        usdc.mint(creator, 10000 * 1e6);
        usdc.mint(trader1, 10000 * 1e6);
        usdc.mint(trader2, 10000 * 1e6);
    }

    function testCreateMarket() public {
        vm.startPrank(creator);
        usdc.approve(address(market), 1000 * 1e6);

        uint256 marketId = market.createMarket(
            "Will ETH be above $5000 by Jan 2025?",
            address(usdc),
            oracle,
            block.timestamp + 30 days,
            1000 * 1e6
        );

        (
            string memory question,
            address marketCreator,
            ,
            ,
            ,
            ,
            uint256 yesShares,
            uint256 noShares,
            ,
            bool resolved
        ) = market.markets(marketId);

        assertEq(question, "Will ETH be above $5000 by Jan 2025?");
        assertEq(marketCreator, creator);
        assertEq(yesShares, 1000 * 1e6);
        assertEq(noShares, 1000 * 1e6);
        assertFalse(resolved);

        vm.stopPrank();
    }

    function testBuyYesShares() public {
        // Create market
        vm.startPrank(creator);
        usdc.approve(address(market), 1000 * 1e6);
        uint256 marketId = market.createMarket(
            "Test market",
            address(usdc),
            oracle,
            block.timestamp + 30 days,
            1000 * 1e6
        );
        vm.stopPrank();

        // Trader1 buys YES shares
        vm.startPrank(trader1);
        usdc.approve(address(market), 100 * 1e6);
        uint256 sharesOut = market.buyShares(marketId, true, 100 * 1e6, 0);
        vm.stopPrank();

        assertGt(sharesOut, 0);

        // Check price moved (YES should be more expensive now)
        uint256 yesPrice = market.getYesPrice(marketId);
        assertLt(yesPrice, 5000); // YES price went up, so YES shares (noShares / total) went down
    }

    function testSellShares() public {
        // Create market
        vm.startPrank(creator);
        usdc.approve(address(market), 1000 * 1e6);
        uint256 marketId = market.createMarket(
            "Test market",
            address(usdc),
            oracle,
            block.timestamp + 30 days,
            1000 * 1e6
        );
        vm.stopPrank();

        // Trader buys then sells
        vm.startPrank(trader1);
        usdc.approve(address(market), 200 * 1e6);
        uint256 bought = market.buyShares(marketId, true, 100 * 1e6, 0);
        
        uint256 collateralOut = market.sellShares(marketId, true, bought, 0);
        vm.stopPrank();

        // Should get back less than 100 due to fees + slippage
        assertLt(collateralOut, 100 * 1e6);
        assertGt(collateralOut, 90 * 1e6);
    }

    function testResolveAndRedeem() public {
        // Create market
        vm.startPrank(creator);
        usdc.approve(address(market), 1000 * 1e6);
        uint256 marketId = market.createMarket(
            "Test market",
            address(usdc),
            oracle,
            block.timestamp + 1 days,
            1000 * 1e6
        );
        vm.stopPrank();

        // Trader buys YES
        vm.startPrank(trader1);
        usdc.approve(address(market), 500 * 1e6);
        market.buyShares(marketId, true, 500 * 1e6, 0);
        vm.stopPrank();

        // Time passes
        vm.warp(block.timestamp + 2 days);

        // Oracle resolves YES
        vm.prank(oracle);
        market.resolveMarket(marketId, 1);

        // Trader redeems
        uint256 balanceBefore = usdc.balanceOf(trader1);
        vm.prank(trader1);
        market.redeemShares(marketId);
        uint256 balanceAfter = usdc.balanceOf(trader1);

        assertGt(balanceAfter, balanceBefore);
    }

    function testCannotResolveBeforeTime() public {
        vm.startPrank(creator);
        usdc.approve(address(market), 1000 * 1e6);
        uint256 marketId = market.createMarket(
            "Test market",
            address(usdc),
            oracle,
            block.timestamp + 30 days,
            1000 * 1e6
        );
        vm.stopPrank();

        vm.prank(oracle);
        vm.expectRevert(PredictionMarket.ResolutionTimeNotReached.selector);
        market.resolveMarket(marketId, 1);
    }

    function testOnlyOracleCanResolve() public {
        vm.startPrank(creator);
        usdc.approve(address(market), 1000 * 1e6);
        uint256 marketId = market.createMarket(
            "Test market",
            address(usdc),
            oracle,
            block.timestamp + 1 days,
            1000 * 1e6
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);

        vm.prank(trader1);
        vm.expectRevert(PredictionMarket.NotOracle.selector);
        market.resolveMarket(marketId, 1);
    }

    function testInvalidResolution() public {
        vm.startPrank(creator);
        usdc.approve(address(market), 1000 * 1e6);
        uint256 marketId = market.createMarket(
            "Test market",
            address(usdc),
            oracle,
            block.timestamp + 1 days,
            1000 * 1e6
        );
        vm.stopPrank();

        // Trader1 buys YES
        vm.startPrank(trader1);
        usdc.approve(address(market), 100 * 1e6);
        market.buyShares(marketId, true, 100 * 1e6, 0);
        vm.stopPrank();

        // Trader2 buys NO
        vm.startPrank(trader2);
        usdc.approve(address(market), 100 * 1e6);
        market.buyShares(marketId, false, 100 * 1e6, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);

        // Oracle marks INVALID (outcome 3)
        vm.prank(oracle);
        market.resolveMarket(marketId, 3);

        // Both traders should get refunds
        uint256 trader1Before = usdc.balanceOf(trader1);
        vm.prank(trader1);
        market.redeemShares(marketId);
        uint256 trader1After = usdc.balanceOf(trader1);

        uint256 trader2Before = usdc.balanceOf(trader2);
        vm.prank(trader2);
        market.redeemShares(marketId);
        uint256 trader2After = usdc.balanceOf(trader2);

        assertGt(trader1After, trader1Before);
        assertGt(trader2After, trader2Before);
    }
}
