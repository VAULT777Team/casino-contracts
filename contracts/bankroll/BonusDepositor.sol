// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

import {BankLP} from "./facets/BankLP.sol";   // your existing BankLP
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract BonusClaimToken is ERC1155, Ownable {
    using Strings for uint256;

    string public name;
    string public symbol;
    address public minter;
    bool public transfersRestricted = true;
    mapping(address => bool) public allowedTransferTarget;

    uint256 public nextTokenId = 1;
    mapping(address => uint256) public tokenToId;
    mapping(uint256 => address) public idToToken;
    mapping(address => uint256) public totalBalance;
    string private _baseMetadataURI;
    string private _metadataSuffix = ".json";

    event TransfersRestrictedUpdated(bool restricted);
    event AllowedTransferTargetUpdated(address indexed target, bool allowed);
    event ClaimTokenIdAssigned(address indexed underlyingToken, uint256 indexed tokenId);
    event MetadataConfigUpdated(string baseUri, string suffix);

    constructor(string memory _name, string memory _symbol, address _minter) ERC1155("") {
        name = _name;
        symbol = _symbol;
        minter = _minter;
    }

    function setURI(string calldata newUri) external onlyOwner {
        _baseMetadataURI = newUri;
        emit MetadataConfigUpdated(_baseMetadataURI, _metadataSuffix);
    }

    function setMetadataConfig(string calldata newBaseUri, string calldata newSuffix) external onlyOwner {
        _baseMetadataURI = newBaseUri;
        _metadataSuffix = newSuffix;
        emit MetadataConfigUpdated(_baseMetadataURI, _metadataSuffix);
    }

    function metadataBaseURI() external view returns (string memory) {
        return _baseMetadataURI;
    }

    function metadataSuffix() external view returns (string memory) {
        return _metadataSuffix;
    }

    function uri(uint256 id) public view override returns (string memory) {
        if (bytes(_baseMetadataURI).length == 0) {
            return string(abi.encodePacked("ipfs://bonus-claim/", id.toString(), ".json"));
        }

        return string(
            abi.encodePacked(
                _normalizedBaseUri(_baseMetadataURI),
                block.chainid.toString(),
                "/",
                Strings.toHexString(uint160(address(this)), 20),
                "/",
                id.toString(),
                _metadataSuffix
            )
        );
    }

    function tokenIdFor(address underlyingToken) external view returns (uint256) {
        return tokenToId[underlyingToken];
    }

    function tokenAddressForId(uint256 id) external view returns (address) {
        return idToToken[id];
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    // Compatibility helper for existing integrations that query claim balance as a single scalar.
    function balanceOf(address account) external view returns (uint256) {
        return totalBalance[account];
    }

    function balanceOfToken(address account, address underlyingToken) external view returns (uint256) {
        uint256 id = tokenToId[underlyingToken];
        if (id == 0) return 0;
        return super.balanceOf(account, id);
    }

    function mint(address to, address underlyingToken, uint256 amount) external {
        require(msg.sender == minter, "Only minter");
        require(to != address(0), "Invalid recipient");
        uint256 id = _ensureTokenId(underlyingToken);
        _mint(to, id, amount, "");
    }

    function burnFrom(address account, address underlyingToken, uint256 amount) external {
        require(msg.sender == minter, "Only minter");
        uint256 id = tokenToId[underlyingToken];
        require(id != 0, "Token ID not found");
        _burn(account, id, amount);
    }

    function setMinter(address newMinter) external onlyOwner {
        minter = newMinter;
    }

    function setTransfersRestricted(bool restricted) external onlyOwner {
        transfersRestricted = restricted;
        emit TransfersRestrictedUpdated(restricted);
    }

    function setAllowedTransferTarget(address target, bool allowed) external onlyOwner {
        require(target != address(0), "Invalid target");
        allowedTransferTarget[target] = allowed;
        emit AllowedTransferTargetUpdated(target, allowed);
    }

    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal override {
        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);

        uint256 sumAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            sumAmount += amounts[i];
        }

        if (!transfersRestricted || sumAmount == 0) {
            return;
        }

        bool isMintOrBurn = from == address(0) || to == address(0);
        bool involvesMinter = operator == minter || from == minter || to == minter;
        bool toAllowed = allowedTransferTarget[to];
        bool fromAllowed = allowedTransferTarget[from];

        require(isMintOrBurn || involvesMinter || toAllowed || fromAllowed, "Transfers restricted");
    }

    function _afterTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal override {
        super._afterTokenTransfer(operator, from, to, ids, amounts, data);

        uint256 sumAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            sumAmount += amounts[i];
        }

        if (from != address(0)) {
            totalBalance[from] -= sumAmount;
        }
        if (to != address(0)) {
            totalBalance[to] += sumAmount;
        }
    }

    function _ensureTokenId(address underlyingToken) internal returns (uint256 id) {
        id = tokenToId[underlyingToken];
        if (id != 0) return id;

        id = nextTokenId;
        nextTokenId += 1;

        tokenToId[underlyingToken] = id;
        idToToken[id] = underlyingToken;

        emit ClaimTokenIdAssigned(underlyingToken, id);
    }

    function _normalizedBaseUri(string memory baseUri) internal pure returns (string memory) {
        bytes memory b = bytes(baseUri);
        if (b.length == 0) return "";
        if (b[b.length - 1] == bytes1("/")) {
            return baseUri;
        }
        return string(abi.encodePacked(baseUri, "/"));
    }

}


contract BonusVault is Ownable {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    BankLP public bankroll;
    BonusClaimToken public claimToken;

    uint256 public bonusMatchBps = 10000;           // 100% = 2× total
    uint256 public wagerMultiplier = 20;            // 20× deposit volume
    bool public oneTimeBonusPerUser = true;
    address public backendSigner;

    mapping(address => mapping(uint256 => bool)) public usedNonces;

    bytes32 private constant ACTION_CONVERT = keccak256("BONUS_CONVERT");
    bytes32 private constant ACTION_CONVERT_TO = keccak256("BONUS_CONVERT_TO");


    mapping(address => mapping(address => uint256)) public deposited;     // player => token => amount
    mapping(address => mapping(address => uint256)) public wageredVolume; // player => token => volume
    mapping(address => mapping(address => uint256)) public requiredVolume;
    mapping(address => mapping(address => uint256)) public bonusDepositCount; // player => token => number of bonus deposits
    mapping(address => mapping(address => uint256)) public totalClaimIssued; // player => token => total claim minted
    mapping(address => mapping(address => uint256)) public totalClaimConverted; // player => token => total claim converted

    event DepositedBonus(address indexed player, address indexed token, uint256 deposit, uint256 bonus, uint256 totalClaim);
    event BonusConverted(address indexed player, address indexed token, uint256 amount);
    event WagerRecorded(address indexed player, address indexed token, uint256 amount);
    event BackendSignerUpdated(address indexed oldSigner, address indexed newSigner);
    event BankrollUpdated(address indexed oldBankroll, address indexed newBankroll);
    event ClaimTokenUpdated(address indexed oldClaimToken, address indexed newClaimToken);
    event OneTimeBonusModeUpdated(bool enabled);
    event BonusConvertedTo(address indexed player, address indexed recipient, address indexed token, uint256 amount);

    error BackendSignerNotSet();
    error InvalidSignature();
    error SignatureExpired(uint256 deadline, uint256 nowTime);
    error NonceAlreadyUsed(uint256 nonce);

    constructor(address _bankroll, address _claimToken, address _backendSigner) {
        require(_bankroll != address(0), "Invalid bankroll");
        require(_claimToken != address(0), "Invalid claim token");

        bankroll = BankLP(payable(_bankroll));
        claimToken = BonusClaimToken(_claimToken);

        if (_backendSigner != address(0)) {
            backendSigner = _backendSigner;
            emit BackendSignerUpdated(address(0), _backendSigner);
        }
    }

    function setBankroll(address newBankroll) external onlyOwner {
        require(newBankroll != address(0), "Invalid bankroll");
        address oldBankroll = address(bankroll);
        bankroll = BankLP(payable(newBankroll));
        emit BankrollUpdated(oldBankroll, newBankroll);
    }

    function setClaimToken(address newClaimToken) external onlyOwner {
        require(newClaimToken != address(0), "Invalid claim token");
        address oldClaimToken = address(claimToken);
        claimToken = BonusClaimToken(newClaimToken);
        emit ClaimTokenUpdated(oldClaimToken, newClaimToken);
    }

    function setBackendSigner(address signer) external onlyOwner {
        require(signer != address(0), "Invalid signer");
        address oldSigner = backendSigner;
        backendSigner = signer;
        emit BackendSignerUpdated(oldSigner, signer);
    }

    function setOneTimeBonusPerUser(bool enabled) external onlyOwner {
        oneTimeBonusPerUser = enabled;
        emit OneTimeBonusModeUpdated(enabled);
    }


    /**
     * @notice Player deposits → gets 2× claim token (deposit + bonus)
     */
    function depositForBonus(address token, uint256 depositAmount) external payable {
        _depositForBonus(token, depositAmount, msg.sender);
    }

    /**
     * @notice Player deposits from one wallet and mints claim to another wallet (e.g. OCG embedded wallet)
     */
    function depositForBonusTo(address token, uint256 depositAmount, address claimRecipient) external payable {
        _depositForBonus(token, depositAmount, claimRecipient);
    }

    function _depositForBonus(address token, uint256 depositAmount, address claimRecipient) internal {
        require(claimRecipient != address(0), "Invalid recipient");
        require(depositAmount > 0, "Zero deposit");

        if (oneTimeBonusPerUser) {
            require(bonusDepositCount[claimRecipient][token] == 0, "Bonus already claimed");
        }

        // If previous bonus cycle was fully converted, reset claim counters for a clean new cycle.
        if (totalClaimConverted[claimRecipient][token] >= totalClaimIssued[claimRecipient][token]) {
            totalClaimIssued[claimRecipient][token] = 0;
            totalClaimConverted[claimRecipient][token] = 0;
        }

        if (token == address(0)) {
            require(msg.value == depositAmount, "ETH mismatch");
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), depositAmount);
        }

        // Send deposit straight into the main liquidity pool
        if (token == address(0)) {
            (bool success, ) = address(bankroll).call{value: depositAmount}(""); // BankLP handles receive()
            require(success, "ETH transfer failed");
        } else {
            IERC20(token).safeApprove(address(bankroll), depositAmount);
            bankroll.fundBankroll(token, depositAmount);
        }

        uint256 bonus = (depositAmount * bonusMatchBps) / 10000;
        uint256 totalClaim = depositAmount + bonus;

        deposited[claimRecipient][token] += depositAmount;
        requiredVolume[claimRecipient][token] += depositAmount * wagerMultiplier;
        bonusDepositCount[claimRecipient][token] += 1;
        totalClaimIssued[claimRecipient][token] += totalClaim;

        claimToken.mint(claimRecipient, token, totalClaim);

        emit DepositedBonus(claimRecipient, token, depositAmount, bonus, totalClaim);
    }


    /**
     * @notice House/treasury funds the bonus liquidity into this vault
     *         Call this after (or in batch) to cover the matched bonuses.
     */
    receive () external payable {
        // Allow receiving ETH directly (e.g. from BankLP refunds)
    }
    

    /**
     * @notice House/treasury funds the bonus liquidity into this vault
     *         Call this after (or in batch) to cover the matched bonuses.
     */
    function fundBonusPool(address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        // No event needed — just tops up the vault balance for future claims
    }

    /**
     * @notice Player converts claim tokens back to real funds once requirement met
     */
    function convert(
        address token,
        uint256 claimAmount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _convertTo(msg.sender, token, claimAmount, msg.sender, nonce, deadline, signature, false);
    }

    /**
     * @notice Convert player's claim and pay out to a chosen recipient wallet (relayer-friendly).
     */
    function convertTo(
        address player,
        address token,
        uint256 claimAmount,
        address recipient,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _convertTo(player, token, claimAmount, recipient, nonce, deadline, signature, true);
    }

    function _convertTo(
        address player,
        address token,
        uint256 claimAmount,
        address recipient,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature,
        bool includeRecipientInSig
    ) internal {
        require(player != address(0), "Invalid player");
        require(recipient != address(0), "Invalid recipient");
        require(claimAmount > 0, "Zero claim");
        if (backendSigner == address(0)) revert BackendSignerNotSet();
        if (block.timestamp > deadline) revert SignatureExpired(deadline, block.timestamp);
        if (usedNonces[player][nonce]) revert NonceAlreadyUsed(nonce);

        bytes32 digest;
        if (includeRecipientInSig) {
            digest = _hashConvertTo(player, token, claimAmount, recipient, nonce, deadline);
        } else {
            digest = _hashConvert(player, token, claimAmount, nonce, deadline);
        }

        address recovered = digest.toEthSignedMessageHash().recover(signature);
        if (recovered != backendSigner) revert InvalidSignature();

        usedNonces[player][nonce] = true;
        totalClaimConverted[player][token] += claimAmount;

        // Burn the claim token first (re-entrancy safe)
        claimToken.burnFrom(player, token, claimAmount);

        // Send real funds (deposit + bonus) from the vault
        uint256 totalToSend = claimAmount; // 1:1 because we minted deposit + bonus

        if (token == address(0)) {
            (bool success, ) = payable(recipient).call{value: totalToSend}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(token).safeTransfer(recipient, totalToSend);
        }

        // If full issued amount was converted, clear per-cycle progress state.
        if (totalClaimConverted[player][token] >= totalClaimIssued[player][token]) {
            deposited[player][token] = 0;
            requiredVolume[player][token] = 0;
            wageredVolume[player][token] = 0;
        }

        if (includeRecipientInSig) {
            emit BonusConvertedTo(player, recipient, token, totalToSend);
        }

        emit BonusConverted(player, token, totalToSend);
    }

    function _hashConvert(
        address player,
        address token,
        uint256 claimAmount,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                address(this),
                block.chainid,
                ACTION_CONVERT,
                player,
                token,
                claimAmount,
                nonce,
                deadline
            )
        );
    }

    function _hashConvertTo(
        address player,
        address token,
        uint256 claimAmount,
        address recipient,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                address(this),
                block.chainid,
                ACTION_CONVERT_TO,
                player,
                token,
                claimAmount,
                recipient,
                nonce,
                deadline
            )
        );
    }

    // View helpers
    function getPlayerStatus(address player, address token) external view returns (
        uint256 depositedAmount,
        uint256 wagered,
        uint256 required,
        bool canConvert
    ) {
        depositedAmount = deposited[player][token];
        wagered = wageredVolume[player][token];
        required = requiredVolume[player][token];
        canConvert = wagered >= required && required > 0;
    }

    function getDepositInfo(address player, address token) external view returns (
        address depositToken,
        address outputToken,
        uint256 depositedAmount,
        uint256 totalClaimMinted,
        uint256 totalClaimAlreadyConverted,
        uint256 wagered,
        uint256 required,
        bool converted,
        bool canConvert
    ) {
        depositToken = token;
        outputToken = token;
        depositedAmount = deposited[player][token];
        totalClaimMinted = totalClaimIssued[player][token];
        totalClaimAlreadyConverted = totalClaimConverted[player][token];
        wagered = wageredVolume[player][token];
        required = requiredVolume[player][token];
        converted = totalClaimMinted > 0 && totalClaimAlreadyConverted >= totalClaimMinted;
        canConvert = !converted && wagered >= required && required > 0;
    }
}