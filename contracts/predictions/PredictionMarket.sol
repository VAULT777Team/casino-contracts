// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PredictionMarket
 * @notice Binary prediction market using constant-product AMM (x*y=k)
 * 
 * Flow:
 * 1. Creator deposits collateral → mints equal YES/NO shares, sets oracle
 * 2. Users trade USDC ↔ YES/NO shares (AMM pricing)
 * 3. Oracle resolves market after resolution time
 * 4. Winners redeem shares 1:1 for collateral
 */
contract PredictionMarket is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    struct Market {
        string question;
        address creator;
        address collateralToken;    // e.g. USDC
        address oracle;
        uint256 resolutionTime;
        uint8 outcome;              // 0=unresolved, 1=YES, 2=NO, 3=INVALID
        uint256 yesShares;          // AMM reserves
        uint256 noShares;           // AMM reserves
        uint256 totalCollateral;    // total deposited collateral
        bool resolved;
    }

    struct Position {
        uint256 yesBalance;
        uint256 noBalance;
    }

    uint256 public marketCount;
    mapping(uint256 => Market) public markets;
    mapping(uint256 => mapping(address => Position)) public positions;

    uint256 public constant FEE_BPS = 30;  // 0.3% trading fee
    uint256 public constant BPS = 10000;

    event MarketCreated(
        uint256 indexed marketId,
        string question,
        address creator,
        address collateralToken,
        uint256 resolutionTime
    );

    event Trade(
        uint256 indexed marketId,
        address indexed trader,
        bool buyYes,
        uint256 collateralAmount,
        uint256 sharesOut
    );

    event MarketResolved(
        uint256 indexed marketId,
        uint8 outcome
    );

    event SharesRedeemed(
        uint256 indexed marketId,
        address indexed user,
        uint256 payout
    );

    error MarketAlreadyResolved();
    error MarketNotResolved();
    error NotOracle();
    error InvalidOutcome();
    error ResolutionTimePassed();
    error ResolutionTimeNotReached();
    error InsufficientLiquidity();
    error NoShares();

    /**
     * @notice Create a new binary prediction market
     * @param question The question to predict
     * @param collateralToken Address of collateral (e.g. USDC)
     * @param oracle Address allowed to resolve the market
     * @param resolutionTime Unix timestamp after which oracle can resolve
     * @param initialLiquidity Amount of collateral to seed the AMM (mints equal YES/NO)
     */
    function createMarket(
        string calldata question,
        address collateralToken,
        address oracle,
        uint256 resolutionTime,
        uint256 initialLiquidity
    ) external nonReentrant returns (uint256 marketId) {
        require(resolutionTime > block.timestamp, "Invalid resolution time");
        require(initialLiquidity > 0, "Need initial liquidity");

        marketId = marketCount++;

        IERC20(collateralToken).safeTransferFrom(
            msg.sender,
            address(this),
            initialLiquidity
        );

        markets[marketId] = Market({
            question: question,
            creator: msg.sender,
            collateralToken: collateralToken,
            oracle: oracle,
            resolutionTime: resolutionTime,
            outcome: 0,
            yesShares: initialLiquidity,
            noShares: initialLiquidity,
            totalCollateral: initialLiquidity,
            resolved: false
        });

        // Creator owns initial shares (can trade or hold)
        positions[marketId][msg.sender] = Position({
            yesBalance: initialLiquidity,
            noBalance: initialLiquidity
        });

        emit MarketCreated(
            marketId,
            question,
            msg.sender,
            collateralToken,
            resolutionTime
        );
    }

    /**
     * @notice Buy YES or NO shares using constant-product AMM
     * @param marketId Market to trade in
     * @param buyYes True to buy YES, false to buy NO
     * @param collateralIn Amount of collateral to spend
     * @param minSharesOut Minimum shares to receive (slippage protection)
     */
    function buyShares(
        uint256 marketId,
        bool buyYes,
        uint256 collateralIn,
        uint256 minSharesOut
    ) external nonReentrant returns (uint256 sharesOut) {
        Market storage market = markets[marketId];
        if (market.resolved) revert MarketAlreadyResolved();

        // Take fee
        uint256 fee = (collateralIn * FEE_BPS) / BPS;
        uint256 collateralAfterFee = collateralIn - fee;

        // Constant product: x * y = k
        // If buying YES: yesShares decreases, noShares stays same, collateral increases
        // sharesOut = yesShares - (yesShares * noShares) / (noShares + collateralAfterFee)
        
        uint256 reserveIn = buyYes ? market.noShares : market.yesShares;
        uint256 reserveOut = buyYes ? market.yesShares : market.noShares;

        uint256 k = reserveIn * reserveOut;
        uint256 newReserveIn = reserveIn + collateralAfterFee;
        uint256 newReserveOut = k / newReserveIn;

        sharesOut = reserveOut - newReserveOut;
        require(sharesOut >= minSharesOut, "Slippage");

        // Update reserves
        if (buyYes) {
            market.yesShares = newReserveOut;
            market.noShares = newReserveIn;
            positions[marketId][msg.sender].yesBalance += sharesOut;
        } else {
            market.noShares = newReserveOut;
            market.yesShares = newReserveIn;
            positions[marketId][msg.sender].noBalance += sharesOut;
        }

        market.totalCollateral += collateralAfterFee;

        IERC20(market.collateralToken).safeTransferFrom(
            msg.sender,
            address(this),
            collateralIn
        );

        emit Trade(marketId, msg.sender, buyYes, collateralIn, sharesOut);
    }

    /**
     * @notice Sell YES or NO shares back to AMM
     * @param marketId Market to trade in
     * @param sellYes True to sell YES, false to sell NO
     * @param sharesIn Amount of shares to sell
     * @param minCollateralOut Minimum collateral to receive
     */
    function sellShares(
        uint256 marketId,
        bool sellYes,
        uint256 sharesIn,
        uint256 minCollateralOut
    ) external nonReentrant returns (uint256 collateralOut) {
        Market storage market = markets[marketId];
        if (market.resolved) revert MarketAlreadyResolved();

        Position storage pos = positions[marketId][msg.sender];
        uint256 userShares = sellYes ? pos.yesBalance : pos.noBalance;
        require(userShares >= sharesIn, "Insufficient shares");

        // Calculate collateral output
        (uint256 collateralOutGross, uint256 newReserveIn, uint256 newReserveOut) 
            = _calculateSellOutput(market, sellYes, sharesIn);
        
        uint256 fee = (collateralOutGross * FEE_BPS) / BPS;
        collateralOut = collateralOutGross - fee;

        require(collateralOut >= minCollateralOut, "Slippage");
        require(collateralOut <= market.totalCollateral, "Insufficient liquidity");

        // Update reserves
        if (sellYes) {
            market.yesShares = newReserveIn;
            market.noShares = newReserveOut;
            pos.yesBalance -= sharesIn;
        } else {
            market.noShares = newReserveIn;
            market.yesShares = newReserveOut;
            pos.noBalance -= sharesIn;
        }

        market.totalCollateral -= collateralOut;

        IERC20(market.collateralToken).safeTransfer(msg.sender, collateralOut);

        emit Trade(marketId, msg.sender, !sellYes, collateralOut, sharesIn);
    }

    function _calculateSellOutput(
        Market storage market,
        bool sellYes,
        uint256 sharesIn
    ) private view returns (uint256 collateralOut, uint256 newReserveIn, uint256 newReserveOut) {
        uint256 reserveIn = sellYes ? market.yesShares : market.noShares;
        uint256 reserveOut = sellYes ? market.noShares : market.yesShares;
        uint256 k = reserveIn * reserveOut;
        newReserveIn = reserveIn + sharesIn;
        newReserveOut = k / newReserveIn;
        collateralOut = reserveOut - newReserveOut;
    }

    /**
     * @notice Oracle resolves market outcome
     * @param marketId Market to resolve
     * @param outcome 1=YES, 2=NO, 3=INVALID (refund all)
     */
    function resolveMarket(uint256 marketId, uint8 outcome) external {
        Market storage market = markets[marketId];
        if (msg.sender != market.oracle) revert NotOracle();
        if (block.timestamp < market.resolutionTime) revert ResolutionTimeNotReached();
        if (market.resolved) revert MarketAlreadyResolved();
        if (outcome == 0 || outcome > 3) revert InvalidOutcome();

        market.resolved = true;
        market.outcome = outcome;

        emit MarketResolved(marketId, outcome);
    }

    /**
     * @notice Redeem winning shares for collateral (1:1)
     * @param marketId Market to redeem from
     */
    function redeemShares(uint256 marketId) external nonReentrant {
        Market storage market = markets[marketId];
        if (!market.resolved) revert MarketNotResolved();

        Position storage pos = positions[marketId][msg.sender];
        uint256 payout;

        if (market.outcome == 1) {
            // YES won
            payout = pos.yesBalance;
            pos.yesBalance = 0;
        } else if (market.outcome == 2) {
            // NO won
            payout = pos.noBalance;
            pos.noBalance = 0;
        } else if (market.outcome == 3) {
            // INVALID - refund both
            payout = pos.yesBalance + pos.noBalance;
            pos.yesBalance = 0;
            pos.noBalance = 0;
        }

        if (payout == 0) revert NoShares();

        IERC20(market.collateralToken).safeTransfer(msg.sender, payout);

        emit SharesRedeemed(marketId, msg.sender, payout);
    }

    /**
     * @notice Get current price for YES shares (in basis points, 10000 = 1.0 = 100%)
     * Price = noShares / (yesShares + noShares)
     */
    function getYesPrice(uint256 marketId) external view returns (uint256) {
        Market storage market = markets[marketId];
        uint256 total = market.yesShares + market.noShares;
        if (total == 0) return 5000; // 50% if no liquidity
        return (market.noShares * BPS) / total;
    }

    /**
     * @notice Get user's position in a market
     */
    function getPosition(uint256 marketId, address user) external view returns (uint256 yes, uint256 no) {
        Position storage pos = positions[marketId][user];
        return (pos.yesBalance, pos.noBalance);
    }
}
