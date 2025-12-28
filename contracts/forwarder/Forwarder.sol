//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IDecimalAggregator} from "@chainlink/contracts/src/v0.8/data-feeds/interfaces/IDecimalAggregator.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

contract Forwarder is EIP712, Ownable {
    using SafeERC20 for ERC20;

    struct ForwardRequest {
        address from;
        address to;
        address feeToken;
        uint256 value;
        uint256 gas;
        uint256 nonce;
        uint256 validUntilTime;
        bytes data;
    }

    struct FeeTokenEntry {
        bool isAllowed;
        bool isStable;
        IDecimalAggregator chainlinkFeed;
    }

    struct SignerEntry {
        address allowedAddress;
        uint256 validUntilTime;
    }

    event Request_Executed(
        address indexed from,
        address indexed to,
        address feeToken,
        uint256 nonce
    );
    event Fees_Collected(
        address indexed token,
        address indexed from,
        address indexed to,
        uint256 amount
    );

    event Signer_Set(
        address user,
        address signer,
        address target,
        uint256 validUntilTime
    );

    event Fee_Token_Updated(
        address indexed tokenAddress,
        address chainLinkFeed,
        bool isAllowed,
        bool isStable
    );
    event Payment_Address_Updated(
        address oldPaymentAddress,
        address newPaymentAddress
    );
    event Fee_Updated(uint256 feeNumerator, uint256 feeDenominator);

    address private paymentAddress;
    address private immutable WETH_ADDRESS;

    uint256 private feeNumerator = 25;
    uint256 private feeDenominator = 1000;
    uint256 private gasBufferForTransfer = 200_000;

    bytes32 private constant _EIP712_TYPEHASH =
        keccak256(
            "ForwardRequest(address from,address to,address feeToken,uint256 value,uint256 gas,uint256 nonce,uint256 validUntilTime,bytes data)"
        );

    mapping(address => uint256) private nonces;

    mapping(address => mapping(address => SignerEntry)) private signerData;

    mapping(address => FeeTokenEntry) private feeTokenData;

    receive() external payable {}

    constructor(
        string memory name,
        string memory version,
        address chainlink_ETH_USDC,
        address _wethAddress,
        address _paymentAddress
    ) EIP712(name, version) {
        feeTokenData[address(0)] = FeeTokenEntry({
            isAllowed: false,
            isStable: false,
            chainlinkFeed: IDecimalAggregator(chainlink_ETH_USDC)
        });

        WETH_ADDRESS = _wethAddress;
        paymentAddress = _paymentAddress;
    }

    // _view functions_

    function getNonce(address from) public view returns (uint256) {
        return nonces[from];
    }

    function verify(
        ForwardRequest calldata req,
        bytes calldata sig
    ) public view returns (bool) {
        _verifyNonce(req);
        _verifySignature(req, sig);
        require(
            ERC20(req.feeToken).allowance(req.from, address(this)) > 0,
            "not enought feeToken allowance"
        );

        return true;
    }

    function getSignerData(
        address user,
        address target
    ) public view returns (SignerEntry memory) {
        return signerData[user][target];
    }

    function getFeeSetting() public view returns (uint256, uint256) {
        return (feeNumerator, feeDenominator);
    }

    function estimateFeeRequest(
        ForwardRequest calldata req
    ) public view returns (uint256) {
        return estimateFee(req.feeToken, req.value, req.gas);
    }

    function estimateFee(
        address tokenAddress,
        uint256 value,
        uint256 gas
    ) public view returns (uint256) {
        return _getTokenAmount(tokenAddress, value + gas * block.basefee);
    }

    function isFeeToken(address tokenAddress) public view returns (bool) {
        return
            feeTokenData[tokenAddress].isAllowed || tokenAddress == WETH_ADDRESS;
    }

    // _state functions_

    function execute(
        ForwardRequest calldata req,
        bytes calldata sig
    ) public payable returns (bool success, bytes memory ret) {
        require(
            (gasleft() * 63) / 64 >= req.gas + gasBufferForTransfer,
            "Forwarder: insufficient gas"
        );

        _verifySignature(req, sig);
        _verifyAndUpdateNonce(req);

        uint256 gasBefore = gasleft();
        uint256 valueBefore = address(this).balance;
        require(valueBefore >= req.value, "Forwarder: insufficient msg value");

        (success, ret) = req.to.call{gas: req.gas, value: req.value}(
            abi.encodePacked(req.data, req.from)
        );
        require(success, "Forwarder: contract call failed");

        uint256 valueAfter = address(this).balance;
        uint256 gasUsed = gasBefore - gasleft();
        uint256 valueUsed = valueBefore - valueAfter;
        require(gasUsed <= req.gas, "Forwarder: used too much gas");
        require(valueUsed <= req.value, "Forwarder: used too much value");

        // _collectFees(req.from, req.feeToken, gasUsed, valueUsed);
        if (valueAfter > 0) payable(msg.sender).transfer(valueAfter);

        emit Request_Executed(req.from, req.to, req.feeToken, req.nonce);
    }

    function executeBatch(
        ForwardRequest[] calldata reqs,
        bytes[] calldata sigs
    ) public payable returns (bool[] memory success, bytes[] memory ret) {
        require(
            reqs.length == sigs.length,
            "Forwarder: number of requests does not match number of signatures"
        );

        uint256 n = reqs.length;
        for (uint i = 0; i < n; i++) {
            (success[i], ret[i]) = execute(reqs[i], sigs[i]);
        }
    }

    function setSigner(
        address signer,
        address target,
        uint256 validUntilTime
    ) public {
        require(signer != address(0), "Can not set signer to 0");
        require(target != address(0), "Can not set target to 0");
        require(
            validUntilTime == 0 || validUntilTime > block.timestamp,
            "validUntilTime must be 0 or greater then now"
        );
        signerData[msg.sender][target] = SignerEntry({
            allowedAddress: signer, 
            validUntilTime: validUntilTime
        });

        emit Signer_Set(msg.sender, signer, target, validUntilTime);
    }

    // _onlyOwner function_

    function updateFeeToken(
        address tokenAddress,
        address chainLinkFeed,
        bool isAllowed,
        bool isStable
    ) public onlyOwner {
        require(tokenAddress != address(0), "Can not set address zero");
        chainLinkFeed = isStable ? address(0) : chainLinkFeed;
        
        feeTokenData[tokenAddress] = FeeTokenEntry({
            isAllowed: isAllowed,
            isStable: isStable,
            chainlinkFeed: IDecimalAggregator(chainLinkFeed)
        });

        emit Fee_Token_Updated(
            tokenAddress,
            chainLinkFeed,
            isAllowed,
            isStable
        );
    }

    function updatePaymentAddress(address _paymentAddress) public onlyOwner {
        require(_paymentAddress != address(0), "Can not set to address zero");
        address oldPaymentAddress = paymentAddress;
        paymentAddress = _paymentAddress;
        emit Payment_Address_Updated(oldPaymentAddress, paymentAddress);
    }

    function updateFee(
        uint256 _feeNumerator,
        uint256 _feeDenominator
    ) public onlyOwner {
        require(_feeDenominator > 0, "Fee denominator can not be zero");
        feeNumerator = _feeNumerator;
        feeDenominator = _feeDenominator;
        emit Fee_Updated(feeNumerator, feeDenominator);
    }

    // _internal functions_

    function _verifyNonce(ForwardRequest calldata req) internal view {
        require(nonces[req.from] == req.nonce, "Forwarder: nonce mismatch");
    }

    function _verifyAndUpdateNonce(ForwardRequest calldata req) internal {
        require(nonces[req.from]++ == req.nonce, "Forwarder: nonce mismatch");
    }

    function _verifySignature(
        ForwardRequest calldata req,
        bytes calldata signature
    ) internal view {
        require(
            feeTokenData[req.feeToken].isAllowed || req.feeToken == WETH_ADDRESS,
            "Forwarder: wrong fee token"
        );
        require(
            req.validUntilTime == 0 || req.validUntilTime > block.timestamp,
            "Forwarder: request expired"
        );

        // https://eips.ethereum.org/EIPS/eip-712#definition-of-hashstruct
        bytes32 hash = keccak256(
            abi.encode(
                _EIP712_TYPEHASH,
                req.from,
                req.to,
                req.feeToken,
                req.value,
                req.gas,
                req.nonce,
                req.validUntilTime,
                keccak256(req.data)
            )
        );
        bytes32 digest = _hashTypedDataV4(hash);

        // if user signed himself => short circut - valid
        if (SignatureChecker.isValidSignatureNow(req.from, digest, signature))
            return;

        SignerEntry memory signer = signerData[req.from][req.to];
        // signer is not set if true:
        require(
            signer.allowedAddress != address(0),
            "Forwarder: signature mismatch"
        );
        require(
            signer.validUntilTime != 0 &&
                signer.validUntilTime > block.timestamp,
            "Forwarder: signer is no longer approved"
        );
        require(
            SignatureChecker.isValidSignatureNow(
                signer.allowedAddress,
                digest,
                signature
            ),
            "Forwarder: signer signature mismatch"
        );
    }

    function _collectFees(
        address from,
        address feeToken,
        uint256 gasUsed,
        uint256 valueUsed
    ) internal {
        uint256 ethUsedByTx = (gasUsed * tx.gasprice * 11) / 10 + valueUsed;
        uint256 ethUsedWithFee = (ethUsedByTx *
            (feeNumerator + feeDenominator)) / feeDenominator;
        uint256 tokenAmount = _getTokenAmount(feeToken, ethUsedWithFee);

        ERC20(feeToken).safeTransferFrom(from, paymentAddress, tokenAmount);
        emit Fees_Collected(feeToken, from, paymentAddress, tokenAmount);
    }

    function _getTokenAmount(
        address tokenAddress,
        uint256 weiConsumed
    ) internal view returns (uint256) {
        if (tokenAddress == WETH_ADDRESS) return weiConsumed;

        uint8 decimals = ERC20(tokenAddress).decimals();
        uint256 nativeToken = _getTokenPrice(address(0));
        if (feeTokenData[tokenAddress].isStable) {
            return (weiConsumed * nativeToken) / 10 ** (36 - decimals);
        } else {
            uint256 quotePrice = _getTokenPrice(tokenAddress);
            return
                ((weiConsumed * nativeToken) / quotePrice) /
                10 ** uint256(18 - decimals);
        }
    }

    function _getTokenPrice(
        address tokenAddress
    ) internal view returns (uint256) {
        (, int256 price, , , ) = feeTokenData[tokenAddress]
            .chainlinkFeed
            .latestRoundData();
        uint8 priceFeedDecimals = feeTokenData[tokenAddress]
            .chainlinkFeed
            .decimals();
        return uint256(price) * 10 ** uint256(18 - priceFeedDecimals);
    }
}