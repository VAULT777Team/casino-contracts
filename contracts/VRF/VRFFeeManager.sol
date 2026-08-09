// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {IDecimalAggregator} from "@chainlink/contracts/src/v0.8/data-feeds/interfaces/IDecimalAggregator.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IVRFFeeManager} from "./IVRFFeeManager.sol";

contract VRFFeeManager is IVRFFeeManager, Ownable {
    struct FeedConfig {
        IDecimalAggregator feed;
        uint48 maxAge;
    }

    struct BillingConfig {
        uint32 coordinatorGasOverhead;
        uint16 coordinatorGasOverheadPerWord;
        uint32 gasAfterPaymentCalculation;
        uint32 fulfillmentFlatFeeNativePPM;
        uint16 nativePremiumBps;
    }

    FeedConfig public nativeUsdFeed;
    BillingConfig public billingConfig;
    mapping(address => FeedConfig) public tokenUsdFeeds;

    error InvalidAddress();
    error InvalidFeedAge();
    error InvalidPrice(address feed);
    error StalePrice(address feed, uint256 updatedAt);
    error TokenFeedNotConfigured(address token);
    error UnsupportedTokenDecimals(address token, uint8 decimals);

    event NativeUsdFeedUpdated(address indexed feed, uint48 maxAge);
    event TokenUsdFeedUpdated(address indexed token, address indexed feed, uint48 maxAge);
    event BillingConfigUpdated(
        uint32 coordinatorGasOverhead,
        uint16 coordinatorGasOverheadPerWord,
        uint32 gasAfterPaymentCalculation,
        uint32 fulfillmentFlatFeeNativePPM,
        uint16 nativePremiumBps
    );

    constructor(
        address nativeUsdFeedAddress,
        uint48 nativeFeedMaxAge,
        BillingConfig memory initialBillingConfig
    ) {
        _setNativeUsdFeed(nativeUsdFeedAddress, nativeFeedMaxAge);
        _setBillingConfig(initialBillingConfig);
    }

    function setNativeUsdFeed(address feed, uint48 maxAge) external onlyOwner {
        _setNativeUsdFeed(feed, maxAge);
    }

    function setTokenUsdFeed(address token, address feed, uint48 maxAge) external onlyOwner {
        if (token == address(0) || feed == address(0)) revert InvalidAddress();
        if (maxAge == 0) revert InvalidFeedAge();

        tokenUsdFeeds[token] = FeedConfig({
            feed: IDecimalAggregator(feed),
            maxAge: maxAge
        });
        emit TokenUsdFeedUpdated(token, feed, maxAge);
    }

    function removeTokenUsdFeed(address token) external onlyOwner {
        delete tokenUsdFeeds[token];
        emit TokenUsdFeedUpdated(token, address(0), 0);
    }

    function setBillingConfig(BillingConfig calldata newConfig) external onlyOwner {
        _setBillingConfig(newConfig);
    }

    function quoteVRFFee(
        address token,
        uint32 callbackGasLimit,
        uint32 numWords,
        uint256 gasPriceWei,
        uint256 l1CostWei
    ) external view returns (uint256) {
        BillingConfig memory config = billingConfig;
        uint256 fulfillmentGas =
            uint256(callbackGasLimit) +
            uint256(config.coordinatorGasOverhead) +
            uint256(config.gasAfterPaymentCalculation) +
            (uint256(config.coordinatorGasOverheadPerWord) * numWords);

        uint256 gasCostWei = (fulfillmentGas * gasPriceWei) + l1CostWei;
        uint256 nativeFeeWei =
            Math.mulDiv(gasCostWei, 10_000 + config.nativePremiumBps, 10_000) +
            (uint256(config.fulfillmentFlatFeeNativePPM) * 1e12);

        if (token == address(0)) return nativeFeeWei;

        FeedConfig memory tokenFeed = tokenUsdFeeds[token];
        if (address(tokenFeed.feed) == address(0)) revert TokenFeedNotConfigured(token);

        uint256 nativePrice = _price18(nativeUsdFeed);
        uint256 tokenPrice = _price18(tokenFeed);
        uint8 tokenDecimals = IERC20Metadata(token).decimals();
        if (tokenDecimals > 36) revert UnsupportedTokenDecimals(token, tokenDecimals);

        uint256 usdValue18 = Math.mulDiv(nativeFeeWei, nativePrice, 1e18);
        uint256 tokenScale = 10 ** uint256(tokenDecimals);
        uint256 tokenFee = Math.mulDiv(usdValue18, tokenScale, tokenPrice);

        if (mulmod(usdValue18, tokenScale, tokenPrice) != 0) {
            tokenFee++;
        }
        return tokenFee;
    }

    function _setNativeUsdFeed(address feed, uint48 maxAge) internal {
        if (feed == address(0)) revert InvalidAddress();
        if (maxAge == 0) revert InvalidFeedAge();

        nativeUsdFeed = FeedConfig({
            feed: IDecimalAggregator(feed),
            maxAge: maxAge
        });
        emit NativeUsdFeedUpdated(feed, maxAge);
    }

    function _setBillingConfig(BillingConfig memory newConfig) internal {
        billingConfig = newConfig;
        emit BillingConfigUpdated(
            newConfig.coordinatorGasOverhead,
            newConfig.coordinatorGasOverheadPerWord,
            newConfig.gasAfterPaymentCalculation,
            newConfig.fulfillmentFlatFeeNativePPM,
            newConfig.nativePremiumBps
        );
    }

    function _price18(FeedConfig memory config) internal view returns (uint256) {
        (, int256 answer, , uint256 updatedAt, ) = config.feed.latestRoundData();
        address feedAddress = address(config.feed);
        if (answer <= 0 || updatedAt == 0) revert InvalidPrice(feedAddress);
        if (block.timestamp > updatedAt + config.maxAge) revert StalePrice(feedAddress, updatedAt);

        uint8 feedDecimals = config.feed.decimals();
        uint256 price = uint256(answer);
        if (feedDecimals < 18) return price * (10 ** uint256(18 - feedDecimals));
        if (feedDecimals > 18) return price / (10 ** uint256(feedDecimals - 18));
        return price;
    }
}
