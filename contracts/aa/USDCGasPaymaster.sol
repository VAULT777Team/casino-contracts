// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IDecimalAggregator} from "@chainlink/contracts/src/v0.8/data-feeds/interfaces/IDecimalAggregator.sol";

import {IEntryPoint} from "./interfaces/IEntryPoint.sol";
import {IPaymaster} from "./interfaces/IPaymaster.sol";
import {PackedUserOperation} from "./interfaces/PackedUserOperation.sol";

/**
 * @title USDCGasPaymaster
 * @notice Minimal ERC-4337 token paymaster that sponsors gas in native ETH and charges the account in USDC,
 *         using the EntryPoint deposit for native gas sponsorship.
 *
 * Assumptions:
 * - The account (`userOp.sender`) holds USDC and has approved this paymaster to spend USDC.
 * - Pricing uses a Chainlink ETH/USD feed and assumes USDC ~= 1 USD.
 * - For native payments, the paymaster must have sufficient EntryPoint deposit.
 *
 * paymasterAndData format (optional):
 * - [20 bytes paymaster address][1 byte paymentMode]
 *   paymentMode: 0x00 = USDC (default), 0x01 = NATIVE
 *
 * NOTE: This is a minimal v0.7-style paymaster for compilation + starting point.
 */
contract USDCGasPaymaster is IPaymaster, Ownable {
    IEntryPoint public immutable entryPoint;
    IERC20 public immutable usdc;
    uint8 public immutable usdcDecimals;

    /// @dev Chainlink ETH/USD (or native/USD) feed.
    IDecimalAggregator public immutable ethUsdFeed;

    /// @dev Extra basis points charged on top of oracle cost (e.g. 500 = +5%).
    uint256 public markupBps = 500;

    /// @dev CasinoAccount codehash for allowlisting senders.
    bytes32 public casinoAccountCodeHash;

    bytes4 internal constant EXECUTE_SELECTOR = bytes4(keccak256("execute(address,uint256,bytes)"));
    bytes4 internal constant EXECUTE_BATCH_SELECTOR = bytes4(keccak256("executeBatch(address[],uint256[],bytes[])"));
    bytes4 internal constant SETUP_SESSION_AND_APPROVE_SELECTOR =
        bytes4(keccak256("setupSessionAndApprove(address,bool,uint48,address,address,uint256)"));

    error NotEntryPoint();
    error NotCasinoAccount();
    error InvalidAccountCall();
    error InsufficientAllowance(uint256 have, uint256 need);
    error InsufficientBalance(uint256 have, uint256 need);
    error InvalidOraclePrice();

    modifier onlyEntryPoint() {
        if (msg.sender != address(entryPoint)) revert NotEntryPoint();
        _;
    }

    constructor(address _entryPoint, address _usdc, address _ethUsdFeed, bytes32 _casinoAccountCodeHash) {
        entryPoint = IEntryPoint(_entryPoint);
        usdc = IERC20(_usdc);
        usdcDecimals = IERC20Metadata(_usdc).decimals();
        ethUsdFeed = IDecimalAggregator(_ethUsdFeed);
        casinoAccountCodeHash = _casinoAccountCodeHash;
    }

    function setMarkupBps(uint256 newMarkupBps) external onlyOwner {
        require(newMarkupBps <= 5_000, "markup too high");
        markupBps = newMarkupBps;
    }

    function setCasinoAccountCodeHash(bytes32 newCodeHash) external onlyOwner {
        require(newCodeHash != bytes32(0), "codehash zero");
        casinoAccountCodeHash = newCodeHash;
    }

    /// @notice Deposit ETH to EntryPoint for sponsoring gas.
    function deposit() external payable {
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    function withdrawTo(address payable to, uint256 amount) external onlyOwner {
        entryPoint.withdrawTo(to, amount);
    }

    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32, /* userOpHash */
        uint256 maxCost
    ) external override onlyEntryPoint returns (bytes memory context, uint256 validationData) {
        bool payInNative = _payInNative(userOp.paymasterAndData);

        if (!_isCasinoAccount(userOp.sender)) revert NotCasinoAccount();
        if (!_isAllowedAccountCall(userOp.callData)) revert InvalidAccountCall();

        if (payInNative) {
            uint256 maxNative = (maxCost * (10_000 + markupBps)) / 10_000;
            uint256 available = entryPoint.balanceOf(address(this));
            if (available < maxNative) revert InsufficientBalance(available, maxNative);
        } else {
            // Estimate max token charge using maxCost (in wei) and add markup.
            uint256 maxUsdc = _weiToUsdc(maxCost);
            maxUsdc = (maxUsdc * (10_000 + markupBps)) / 10_000;

            uint256 allowance = usdc.allowance(userOp.sender, address(this));
            if (allowance < maxUsdc) revert InsufficientAllowance(allowance, maxUsdc);

            uint256 bal = usdc.balanceOf(userOp.sender);
            if (bal < maxUsdc) revert InsufficientBalance(bal, maxUsdc);
        }

        // context passed to postOp
        context = abi.encode(userOp.sender, payInNative);
        validationData = 0;
    }

    function postOp(PostOpMode, bytes calldata context, uint256 actualGasCost, uint256)
        external
        override
        onlyEntryPoint
    {
        (address sender, bool payInNative) = abi.decode(context, (address, bool));

        if (payInNative) {
            // Native sponsorship is fully covered by the EntryPoint deposit.
            // No additional accounting needed here.
        } else {
            uint256 usdcCost = _weiToUsdc(actualGasCost);
            usdcCost = (usdcCost * (10_000 + markupBps)) / 10_000;

            // Charge USDC from the account.
            // If this fails, EntryPoint will treat it as postOpReverted and may penalize paymaster.
            require(usdc.transferFrom(sender, owner(), usdcCost), "usdc transferFrom failed");
        }
    }

    function _payInNative(bytes calldata paymasterAndData) internal pure returns (bool) {
        if (paymasterAndData.length < 53) return false;
        // 20 + 32 bytes
        // First 20 bytes are paymaster address; 53rd byte is mode.
        uint8 mode = uint8(paymasterAndData[52]);
        return mode == 1;
    }

    function _isCasinoAccount(address sender) internal view returns (bool) {
        bytes32 codehash;
        assembly {
            codehash := extcodehash(sender)
        }
        return codehash == casinoAccountCodeHash && codehash != bytes32(0);
    }

    function _isAllowedAccountCall(bytes calldata callData) internal pure returns (bool) {
        if (callData.length < 4) return false;
        bytes4 sel;
        assembly {
            sel := calldataload(callData.offset)
        }
        return
            sel == EXECUTE_SELECTOR ||
            sel == EXECUTE_BATCH_SELECTOR ||
            sel == SETUP_SESSION_AND_APPROVE_SELECTOR;
    }

    function _weiToUsdc(uint256 weiAmount) internal view returns (uint256) {
        (, int256 answer, , , ) = ethUsdFeed.latestRoundData();
        if (answer <= 0) revert InvalidOraclePrice();

        uint256 price = uint256(answer);
        uint8 priceDecimals = ethUsdFeed.decimals();

        // USD = (weiAmount / 1e18) * (price / 10**priceDecimals)
        // USDC units = USD * 10**usdcDecimals
        // => usdc = weiAmount * price * 10**usdcDecimals / (1e18 * 10**priceDecimals)
        uint256 num = weiAmount * price * (10 ** usdcDecimals);
        uint256 den = (1e18) * (10 ** priceDecimals);
        return num / den;
    }
}
