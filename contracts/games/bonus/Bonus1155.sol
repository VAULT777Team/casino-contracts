// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IBonusBankLP {
    function depositEther() external payable;
    function deposit(address token, uint256 amount) external;
    function transferPayout(address player, uint256 amount, address token) external;
}

interface IBonusBankrollRegistry {
    function getCurrentBankroll()
        external
        view
        returns (address bankroll, address previousBankroll, string memory version, uint256 activatedAt);
}

/// @title Vault777 ERC-1155 Bonus Contract
/// @notice Mints bonus balances, tracks wagering requirements, and redeems completed bonuses through BankLP.
contract Bonus1155 is ERC1155Supply, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant PURCHASE_TYPEHASH = keccak256("VAULT_BONUS_PURCHASE");
    bytes32 public constant REDEEM_TYPEHASH = keccak256("VAULT_BONUS_REDEEM");

    struct Bonus {
        address token;
        address purchaser;
        uint256 payAmount;
        uint256 mintAmount;
        uint256 wagerRequirement;
        uint256 wageredAmount;
        uint256 createdAt;
        uint256 expiresAt;
        bool transferable;
        bool closed;
    }

    address public owner;
    address public backendSigner;
    address public bankrollRegistry;
    address public bonusGameLedger;
    bool public paused;
    bool public transfersEnabled = true;
    uint256 public nextBonusId = 1;

    mapping(uint256 => Bonus) public bonuses;
    mapping(address => mapping(uint256 => bool)) public usedNonces;
    mapping(address => uint256[]) private _ownedBonusIds;
    mapping(address => mapping(uint256 => bool)) private _hasSeenBonusId;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event BackendSignerUpdated(address indexed oldSigner, address indexed newSigner);
    event BankrollRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event BonusGameLedgerUpdated(address indexed oldLedger, address indexed newLedger);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event TransfersEnabledUpdated(bool enabled);
    event BonusPurchased(
        uint256 indexed bonusId,
        address indexed purchaser,
        address indexed token,
        uint256 payAmount,
        uint256 mintAmount,
        uint256 wagerRequirement,
        uint256 expiresAt,
        bool transferable
    );
    event BonusStakeDebited(
        uint256 indexed bonusId,
        address indexed player,
        address indexed token,
        uint256 stake,
        uint256 wagerContribution,
        uint256 totalWagered
    );
    event BonusStakeCancelled(
        uint256 indexed bonusId,
        address indexed player,
        address indexed token,
        uint256 refund,
        uint256 wagerContribution,
        uint256 totalWagered
    );
    event BonusPayoutCredited(uint256 indexed bonusId, address indexed player, address indexed token, uint256 payout);
    event BonusRedeemed(
        uint256 indexed bonusId, address indexed player, address indexed token, uint256 amount, uint256 remainingSupply
    );
    event BonusClosed(uint256 indexed bonusId, uint256 closedAt);

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    modifier onlyLedger() {
        require(msg.sender == bonusGameLedger, "NOT_BONUS_LEDGER");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "PAUSED");
        _;
    }

    constructor(string memory uri_, address registry, address signer) ERC1155(uri_) {
        require(registry != address(0), "ZERO_REGISTRY");
        require(signer != address(0), "ZERO_SIGNER");
        owner = msg.sender;
        bankrollRegistry = registry;
        backendSigner = signer;
        emit OwnershipTransferred(address(0), msg.sender);
        emit BankrollRegistryUpdated(address(0), registry);
        emit BackendSignerUpdated(address(0), signer);
        _getBankroll();
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "ZERO_OWNER");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setBackendSigner(address newSigner) external onlyOwner {
        require(newSigner != address(0), "ZERO_SIGNER");
        emit BackendSignerUpdated(backendSigner, newSigner);
        backendSigner = newSigner;
    }

    function setBankrollRegistry(address newRegistry) external onlyOwner {
        require(newRegistry != address(0), "ZERO_REGISTRY");
        address oldRegistry = bankrollRegistry;
        bankrollRegistry = newRegistry;
        _getBankroll();
        emit BankrollRegistryUpdated(oldRegistry, newRegistry);
    }

    function setBonusGameLedger(address newLedger) external onlyOwner {
        require(newLedger != address(0), "ZERO_LEDGER");
        emit BonusGameLedgerUpdated(bonusGameLedger, newLedger);
        bonusGameLedger = newLedger;
    }

    function setTransfersEnabled(bool enabled) external onlyOwner {
        transfersEnabled = enabled;
        emit TransfersEnabledUpdated(enabled);
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function purchaseBonus(
        address token,
        uint256 payAmount,
        uint256 mintAmount,
        uint256 wagerRequirement,
        uint256 expiresAt,
        bool transferable,
        uint256 validUntil,
        uint256 nonce,
        bytes calldata signature
    ) external payable nonReentrant whenNotPaused returns (uint256 bonusId) {
        require(payAmount > 0, "ZERO_PAY");
        require(mintAmount > 0, "ZERO_MINT");
        require(wagerRequirement > 0, "ZERO_WR");
        require(expiresAt > block.timestamp, "BAD_EXPIRY");
        require(block.timestamp <= validUntil, "SIG_EXPIRED");
        require(!usedNonces[msg.sender][nonce], "NONCE_USED");

        bytes32 digest = keccak256(
            abi.encode(
                PURCHASE_TYPEHASH,
                msg.sender,
                token,
                payAmount,
                mintAmount,
                wagerRequirement,
                expiresAt,
                transferable,
                nonce,
                address(this),
                block.chainid,
                validUntil
            )
        );
        require(_recover(digest, signature) == backendSigner, "INVALID_SIGNATURE");
        usedNonces[msg.sender][nonce] = true;
        _collectAndDepositToBankroll(token, payAmount);

        bonusId = nextBonusId++;
        bonuses[bonusId] = Bonus({
            token: token,
            purchaser: msg.sender,
            payAmount: payAmount,
            mintAmount: mintAmount,
            wagerRequirement: wagerRequirement,
            wageredAmount: 0,
            createdAt: block.timestamp,
            expiresAt: expiresAt,
            transferable: transferable,
            closed: false
        });
        _mint(msg.sender, bonusId, mintAmount, "");
        emit BonusPurchased(
            bonusId, msg.sender, token, payAmount, mintAmount, wagerRequirement, expiresAt, transferable
        );
    }

    function debitStakeAndRecordWager(
        address player,
        address token,
        uint256 bonusId,
        uint256 stake,
        uint256 wagerContribution
    ) external onlyLedger whenNotPaused {
        Bonus storage bonus = _openBonus(bonusId, token);
        require(stake > 0, "ZERO_STAKE");
        _burn(player, bonusId, stake);
        bonus.wageredAmount += wagerContribution;
        emit BonusStakeDebited(bonusId, player, token, stake, wagerContribution, bonus.wageredAmount);
    }

    /// @notice Reverses a failed round after the settlement operator permanently abandons settlement.
    /// @dev Recovery remains available while paused and after expiry so delayed permanent failures can be unwound.
    function cancelStakeAndWager(
        address player,
        address token,
        uint256 bonusId,
        uint256 refund,
        uint256 wagerContribution
    ) external onlyLedger {
        Bonus storage bonus = bonuses[bonusId];
        require(bonus.purchaser != address(0), "BONUS_NOT_FOUND");
        require(bonus.token == token, "TOKEN_MISMATCH");
        require(bonus.wageredAmount >= wagerContribution, "CONTRIBUTION_UNDERFLOW");
        bonus.wageredAmount -= wagerContribution;
        if (refund > 0) _mint(player, bonusId, refund, "");
        emit BonusStakeCancelled(bonusId, player, token, refund, wagerContribution, bonus.wageredAmount);
    }

    function creditPayout(address player, address token, uint256 bonusId, uint256 payout)
        external
        onlyLedger
        whenNotPaused
    {
        if (payout == 0) return;
        _openBonus(bonusId, token);
        _mint(player, bonusId, payout, "");
        emit BonusPayoutCredited(bonusId, player, token, payout);
    }

    function redeem(uint256 bonusId, uint256 validUntil, uint256 nonce, bytes calldata signature)
        external
        nonReentrant
        whenNotPaused
    {
        require(block.timestamp <= validUntil, "SIG_EXPIRED");
        require(!usedNonces[msg.sender][nonce], "NONCE_USED");
        Bonus storage bonus = _openBonus(bonusId, bonuses[bonusId].token);
        require(bonus.wageredAmount >= bonus.wagerRequirement, "WR_NOT_MET");
        uint256 amount = balanceOf(msg.sender, bonusId);
        require(amount > 0, "ZERO_BALANCE");

        bytes32 digest = keccak256(
            abi.encode(
                REDEEM_TYPEHASH,
                msg.sender,
                bonusId,
                bonus.token,
                amount,
                bonus.wageredAmount,
                bonus.wagerRequirement,
                nonce,
                address(this),
                block.chainid,
                validUntil
            )
        );
        require(_recover(digest, signature) == backendSigner, "INVALID_SIGNATURE");
        usedNonces[msg.sender][nonce] = true;
        _burn(msg.sender, bonusId, amount);

        uint256 remainingSupply = totalSupply(bonusId);
        if (remainingSupply == 0) bonus.closed = true;
        IBonusBankLP(_getBankroll()).transferPayout(msg.sender, amount, bonus.token);
        emit BonusRedeemed(bonusId, msg.sender, bonus.token, amount, remainingSupply);
        if (remainingSupply == 0) emit BonusClosed(bonusId, block.timestamp);
    }

    function getBonus(uint256 bonusId) external view returns (Bonus memory) {
        return bonuses[bonusId];
    }

    function getOwnedBonusIds(address account) external view returns (uint256[] memory) {
        return _ownedBonusIds[account];
    }

    function bankroll() external view returns (address) {
        return _getBankroll();
    }

    function isRedeemable(uint256 bonusId) external view returns (bool) {
        Bonus memory bonus = bonuses[bonusId];
        return !bonus.closed && block.timestamp <= bonus.expiresAt && bonus.wageredAmount >= bonus.wagerRequirement;
    }

    function canTransfer(uint256 bonusId) external view returns (bool) {
        Bonus memory bonus = bonuses[bonusId];
        return transfersEnabled && bonus.transferable && !bonus.closed && block.timestamp <= bonus.expiresAt;
    }

    function _openBonus(uint256 bonusId, address token) private view returns (Bonus storage bonus) {
        bonus = bonuses[bonusId];
        require(bonus.purchaser != address(0), "BONUS_NOT_FOUND");
        require(!bonus.closed, "BONUS_CLOSED");
        require(bonus.token == token, "TOKEN_MISMATCH");
        require(block.timestamp <= bonus.expiresAt, "BONUS_EXPIRED");
    }

    function _collectAndDepositToBankroll(address token, uint256 amount) private {
        address currentBankroll = _getBankroll();
        if (token == address(0)) {
            require(msg.value == amount, "BAD_VALUE");
            IBonusBankLP(currentBankroll).depositEther{value: amount}();
        } else {
            require(msg.value == 0, "NO_ETH_ALLOWED");
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            IERC20(token).safeApprove(currentBankroll, 0);
            IERC20(token).safeApprove(currentBankroll, amount);
            IBonusBankLP(currentBankroll).deposit(token, amount);
        }
    }

    function _getBankroll() private view returns (address currentBankroll) {
        (currentBankroll,,,) = IBonusBankrollRegistry(bankrollRegistry).getCurrentBankroll();
        require(currentBankroll != address(0), "ZERO_BANKROLL");
    }

    function _recover(bytes32 digest, bytes calldata signature) private pure returns (address) {
        return ECDSA.recover(keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest)), signature);
    }

    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    ) internal override {
        super._beforeTokenTransfer(operator, from, to, ids, values, data);
        if (from != address(0) && to != address(0)) {
            require(transfersEnabled, "TRANSFERS_DISABLED");
            for (uint256 i; i < ids.length; ++i) {
                Bonus storage bonus = bonuses[ids[i]];
                require(bonus.purchaser != address(0), "BONUS_NOT_FOUND");
                require(bonus.transferable, "BONUS_NON_TRANSFERABLE");
                require(!bonus.closed, "BONUS_CLOSED");
                require(block.timestamp <= bonus.expiresAt, "BONUS_EXPIRED");
            }
        }
        if (to == address(0)) return;
        for (uint256 i; i < ids.length; ++i) {
            if (values[i] > 0 && !_hasSeenBonusId[to][ids[i]]) {
                _hasSeenBonusId[to][ids[i]] = true;
                _ownedBonusIds[to].push(ids[i]);
            }
        }
    }
}
