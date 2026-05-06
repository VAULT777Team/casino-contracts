// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {
    Common, IBankrollRegistry,
    IERC20, SafeERC20
} from "../../Common.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * @title Crash game with backend-signed payouts
 * Players receive a backend signature authorizing payout for a wager + multiplier
 * The multiplier is determined by the backend based on a provably fair random seed and the timing of the player's cashout
 * The contract verifies the signature and pays out accordingly
 * This design allows for a more dynamic game experience while keeping on-chain logic simple and secure
 * Configurations are used to set different multiplier limits for various game modes (e.g. conservative vs high-risk)
 * This allows for different sized wagers and multipliers while managing risk for the bankroll
 */

contract Escrow is Common, EIP712 {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    uint32 public constant COINFLIP_PF_CONFIG_ID = 3;
    uint32 public constant DICE_PF_CONFIG_ID = 4;

    struct CrashConfig {
        uint256 minMultiplier;
        uint256 maxMultiplier;
        uint256 kellyRiskMultiplier;
        uint256 expectedPayoutBp;
        bool enabled;
    }

    struct Escrow {
        uint256 escrowId;
        uint256 wager;
        address tokenAddress;
        uint64 createdAt;
        uint32 configId;
    }

    address public backendSigner;
    mapping(address => mapping(uint256 => bool)) public usedNonces;
    mapping(address => Escrow) public escrows;
    mapping(address => uint256) public nextEscrowId;

    mapping(uint32 => CrashConfig) public crashConfigs;
    uint32 public defaultConfigId;

    bytes32 private constant ACTION_CASHOUT = keccak256("CRASH_CASHOUT");
    bytes32 private constant CASHOUT_TYPEHASH = keccak256(
        "CrashCashout(bytes32 action,address player,uint256 escrowId,uint256 wager,uint256 multiplier,address tokenAddress,uint32 configId,uint256 nonce,uint256 deadline)"
    );

    event Crash_Deposit_Event(
        address indexed player,
        uint256 escrowId,
        uint256 wager,
        address tokenAddress
    );
    event Crash_Escrow_Forfeited(
        address indexed player,
        uint256 escrowId,
        uint256 wager,
        address tokenAddress
    );
    event Crash_Payout_Event(
        address indexed player,
        uint256 wager,
        uint256 payout,
        uint256 multiplier,
        address tokenAddress,
        uint32 configId
    );

    event Crash_Config_Updated(
        uint32 indexed configId,
        uint256 minMultiplier,
        uint256 maxMultiplier,
        bool enabled
    );

    event Crash_Config_RiskModel_Updated(
        uint32 indexed configId,
        uint256 kellyRiskMultiplier,
        uint256 expectedPayoutBp
    );

    error InvalidSignature();
    error SignatureExpired(uint256 deadline, uint256 nowTime);
    error NonceAlreadyUsed(uint256 nonce);
    error BackendSignerNotSet();
    error InvalidMultiplier(uint256 multiplier);
    error WagerAboveLimit(uint256 wager, uint256 maxWager);
    error NoEscrow();
    error EscrowMismatch(uint256 wager, address tokenAddress);
    error ConfigDisabled(uint32 configId);
    error InvalidExpectedPayout(uint256 expectedPayoutBp);

    constructor(
        address _registry
    ) EIP712("Crash", "1") {
        b_registry = IBankrollRegistry(_registry);

        defaultConfigId = 0;

        // crash configurations
        crashConfigs[0] = CrashConfig({
            minMultiplier: 10000, // 1x (1e4 precision)
            maxMultiplier: 10_000_000, // 1000x (1e4 precision)
            kellyRiskMultiplier: 10_000_000, // 1000x effective Kelly risk
            expectedPayoutBp: 100_000_000, // 10,000x expected payout model
            enabled: true
        });
        
        crashConfigs[1] = CrashConfig({
            minMultiplier: 10000, // 1x (1e4 precision)
            maxMultiplier: 10_000_000, // 1000x (1e4 precision)
            kellyRiskMultiplier: 10_000_000, // 1000x effective Kelly risk
            expectedPayoutBp: 100_000_000, // 10,000x expected payout model
            enabled: true
        });
        
        crashConfigs[2] = CrashConfig({
            minMultiplier: 10000, // 1x (1e4 precision)
            maxMultiplier: 20_000_000, // 2000x (1e4 precision)
            kellyRiskMultiplier: 20_000_000, // 2000x effective Kelly risk
            expectedPayoutBp: 100_000_000, // 10,000x expected payout model
            enabled: true
        });

        // coinflip
        crashConfigs[COINFLIP_PF_CONFIG_ID] = CrashConfig({
            minMultiplier: 0, // 0x allows loss settlement / escrow cleanup for PF games
            maxMultiplier: 1_980_000, // 198x max total multiplier for 100 coinflip wins at 1.98x each
            kellyRiskMultiplier: 178_182, // matches VRF CoinFlip max wager ~= 1.122448% of bankroll
            expectedPayoutBp: 178_182, // keep expected cap aligned with VRF CoinFlip wager ceiling
            enabled: true
        });

        crashConfigs[DICE_PF_CONFIG_ID] = CrashConfig({
            minMultiplier: 0, // 0x allows loss settlement / escrow cleanup for PF games
            maxMultiplier: 100_000_000, // 10,000x total multiplier hard cap supported by Crash config model
            kellyRiskMultiplier: 100_000_000, // conservative static dice cap; backend further validates requested multiplier envelope
            expectedPayoutBp: 100_000_000, // conservative static dice cap; backend further validates requested multiplier envelope
            enabled: true
        });
        

        emit Crash_Config_Updated(0, 10000, 10_000_000, true);
        emit Crash_Config_RiskModel_Updated(0, 10_000_000, 100_000_000);
        emit Crash_Config_Updated(1, 10000, 10_000_000, true);
        emit Crash_Config_RiskModel_Updated(1, 10_000_000, 100_000_000);
        emit Crash_Config_Updated(2, 10000, 20_000_000, true);
        emit Crash_Config_RiskModel_Updated(2, 20_000_000, 100_000_000);
        emit Crash_Config_Updated(COINFLIP_PF_CONFIG_ID, 0, 1_980_000, true);
        emit Crash_Config_RiskModel_Updated(COINFLIP_PF_CONFIG_ID, 178_182, 178_182);
        emit Crash_Config_Updated(DICE_PF_CONFIG_ID, 0, 100_000_000, true);
        emit Crash_Config_RiskModel_Updated(DICE_PF_CONFIG_ID, 100_000_000, 100_000_000);
    }

    function setBackendSigner(address signer) external onlyOwner {
        backendSigner = signer;
    }

    function setMultiplierLimits(uint256 minMultiplier, uint256 maxMultiplier) external onlyOwner {
        _validateMultiplierLimits(minMultiplier, maxMultiplier);
        crashConfigs[defaultConfigId].minMultiplier = minMultiplier;
        crashConfigs[defaultConfigId].maxMultiplier = maxMultiplier;
        crashConfigs[defaultConfigId].kellyRiskMultiplier = maxMultiplier;
        crashConfigs[defaultConfigId].expectedPayoutBp = maxMultiplier;
        crashConfigs[defaultConfigId].enabled = true;

        emit Crash_Config_Updated(defaultConfigId, minMultiplier, maxMultiplier, true);
        emit Crash_Config_RiskModel_Updated(defaultConfigId, maxMultiplier, maxMultiplier);
    }

    function setCrashConfig(
        uint32 configId,
        uint256 minMultiplier,
        uint256 maxMultiplier,
        bool enabled
    ) external onlyOwner {
        _validateMultiplierLimits(minMultiplier, maxMultiplier);

        crashConfigs[configId] = CrashConfig({
            minMultiplier: minMultiplier,
            maxMultiplier: maxMultiplier,
            kellyRiskMultiplier: maxMultiplier,
            expectedPayoutBp: maxMultiplier,
            enabled: enabled
        });

        emit Crash_Config_Updated(configId, minMultiplier, maxMultiplier, enabled);
        emit Crash_Config_RiskModel_Updated(configId, maxMultiplier, maxMultiplier);
    }

    function setCrashConfigRiskModel(
        uint32 configId,
        uint256 kellyRiskMultiplier,
        uint256 expectedPayoutBp
    ) external onlyOwner {
        CrashConfig storage cfg = crashConfigs[configId];
        if (!cfg.enabled) {
            revert ConfigDisabled(configId);
        }

        _validateMultiplierLimits(10_000, kellyRiskMultiplier);
        if (expectedPayoutBp < 10_000 || expectedPayoutBp > 100_000_000) {
            revert InvalidExpectedPayout(expectedPayoutBp);
        }

        cfg.kellyRiskMultiplier = kellyRiskMultiplier;
        cfg.expectedPayoutBp = expectedPayoutBp;

        emit Crash_Config_RiskModel_Updated(configId, kellyRiskMultiplier, expectedPayoutBp);
    }

    function getMultiplierLimits(uint32 configId) external view returns (uint256 minMultiplier, uint256 maxMultiplier) {
        CrashConfig memory cfg = _getConfig(configId);
        return (cfg.minMultiplier, cfg.maxMultiplier);
    }

    function getRiskModel(uint32 configId) external view returns (uint256 kellyRiskMultiplier, uint256 expectedPayoutBp) {
        CrashConfig memory cfg = _getConfig(configId);
        return (cfg.kellyRiskMultiplier, cfg.expectedPayoutBp);
    }

    function _validateMultiplierLimits(uint256 minMultiplier, uint256 maxMultiplier) internal pure {
        if (minMultiplier > 10_000_000) {
            revert InvalidMultiplier(minMultiplier);
        }
        if (maxMultiplier < 10000 || maxMultiplier > 100_000_000) {
            revert InvalidMultiplier(maxMultiplier);
        }
        if (minMultiplier > maxMultiplier) {
            revert InvalidMultiplier(minMultiplier);
        }
    }

    function _getConfig(uint32 configId) internal view returns (CrashConfig memory cfg) {
        cfg = crashConfigs[configId];
        if (!cfg.enabled) {
            revert ConfigDisabled(configId);
        }
        if (cfg.kellyRiskMultiplier == 0 || cfg.expectedPayoutBp == 0) {
            revert ConfigDisabled(configId);
        }
    }

    /**
     * @dev Deposit wager into escrow before payout
     * @param wager The wager amount
     * @param tokenAddress The wager token (address(0) for native)
     */
    function Crash_Deposit(
        uint256 wager,
        address tokenAddress,
        uint32 configId
    ) external payable nonReentrant {
        _deposit(wager, tokenAddress, configId);
    }

    function _deposit(
        uint256 wager,
        address tokenAddress,
        uint32 configId
    ) internal {
        CrashConfig memory cfg = _getConfig(configId);

        address player = _msgSender();
        Escrow memory existing = escrows[player];
        if (existing.wager != 0) {
            emit Crash_Escrow_Forfeited(player, existing.escrowId, existing.wager, existing.tokenAddress);
        }

        uint256 maxWager = _maxWagerAllowed(tokenAddress, cfg);
        if (wager > maxWager) revert WagerAboveLimit(wager, maxWager);

        _transferWagerNoVRF(tokenAddress, wager, player);
        _transferToBankroll(tokenAddress, wager);

        uint256 escrowId = ++nextEscrowId[player];
        escrows[player] = Escrow({
            escrowId: escrowId,
            wager: wager,
            tokenAddress: tokenAddress,
            createdAt: uint64(block.timestamp),
            configId: configId
        });
        emit Crash_Deposit_Event(player, escrowId, wager, tokenAddress);
    }

    /**
     * @dev Payout using a backend-signed multiplier for an explicitly provided player.
     * Any caller may submit the payout transaction as long as the signature is valid for the player escrow.
     * @param player The escrow owner receiving payout / settlement
     * @param wager The wager amount
     * @param multiplier The cashout multiplier (1e4 precision)
     * @param tokenAddress The wager token (address(0) for native)
     * @param nonce A unique nonce for replay protection
     * @param deadline Signature expiry timestamp
     * @param signature Backend signature authorizing this payout
     */
    function Crash_Payout(
        address player,
        uint256 wager,
        uint256 multiplier,
        address tokenAddress,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external payable nonReentrant {
        _payout(player, wager, multiplier, tokenAddress, nonce, deadline, signature);
    }

    function _payout(
        address player,
        uint256 wager,
        uint256 multiplier,
        address tokenAddress,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) internal {
        if (backendSigner == address(0)) revert BackendSignerNotSet();

        Escrow memory escrow = escrows[player];
        if (escrow.wager == 0) revert NoEscrow();
        if (escrow.wager != wager || escrow.tokenAddress != tokenAddress) {
            revert EscrowMismatch(wager, tokenAddress);
        }
        CrashConfig memory cfg = _getConfig(escrow.configId);
        if (multiplier < cfg.minMultiplier || multiplier > cfg.maxMultiplier) {
            revert InvalidMultiplier(multiplier);
        }

        if (block.timestamp > deadline) revert SignatureExpired(deadline, block.timestamp);
        if (usedNonces[player][nonce]) revert NonceAlreadyUsed(nonce);

        bytes32 digest = _hashCashout(
            player,
            escrow.escrowId,
            wager,
            multiplier,
            tokenAddress,
            escrow.configId,
            nonce,
            deadline
        );
        address recovered = digest.recover(signature);
        if (recovered != backendSigner) revert InvalidSignature();

        usedNonces[player][nonce] = true;

        delete escrows[player];

        uint256 payout = (wager * multiplier) / 10000;
        if (payout != 0) {
            _transferPayout(player, payout, tokenAddress);
        }

        emit Crash_Payout_Event(player, wager, payout, multiplier, tokenAddress, escrow.configId);
    }

    /**
     * @dev calculates the maximum wager allowed based on the bankroll size
     */
    // Limit max wager so that max payout (at config max multiplier) is 20% of available bankroll
    function _maxWagerAllowed(address token, CrashConfig memory cfg) internal view returns (uint256) {
        uint256 available = Bankroll().getAvailableBalance(token);
        uint256 maxPayout = (available * 20) / 100; // 20% of available balance

        uint256 maxWagerByRisk = (maxPayout * 10000) / cfg.kellyRiskMultiplier;
        uint256 maxWagerByExpected = (maxPayout * 10000) / cfg.expectedPayoutBp;

        // Use both models and allow the less restrictive cap. This prevents
        // high-ceiling configs from being overly constrained by tail max only.
        uint256 maxWager = maxWagerByRisk > maxWagerByExpected
            ? maxWagerByRisk
            : maxWagerByExpected;
        return maxWager;
    }

    function _hashCashout(
        address player,
        uint256 escrowId,
        uint256 wager,
        uint256 multiplier,
        address tokenAddress,
        uint32 configId,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                CASHOUT_TYPEHASH,
                ACTION_CASHOUT,
                player,
                escrowId,
                wager,
                multiplier,
                tokenAddress,
                configId,
                nonce,
                deadline
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function _transferWagerNoVRF(
        address tokenAddress,
        uint256 wager,
        address msgSender
    ) internal {
        if (wager == 0) revert ZeroWager();
        if (!Bankroll().getIsValidWager(address(this), tokenAddress)) revert NotApprovedBankroll();

        (bool suspended, uint256 suspendedTime) = Bankroll().isPlayerSuspended(msgSender);
        if (suspended) revert PlayerSuspended(suspendedTime);

        if (tokenAddress == address(0)) {
            if (msg.value < wager) {
                revert InvalidValue(wager, msg.value);
            }
            _refundExcessValue(msg.value - wager);
        } else {
            IERC20(tokenAddress).safeTransferFrom(msgSender, address(this), wager);
            _refundExcessValue(msg.value);
        }

        uint256 playReward = Bankroll().getPlayerReward();
        if (playReward > 0) {
            uint256 reward = Bankroll().calculatePlayReward(tokenAddress, wager);
            if (reward > 0) {
                Bankroll().addPlayerReward(msgSender, reward);
            }
        }

        emit WagerTransferred(address(this), tokenAddress, msgSender, wager);
    }

    function _fulfillRandomWords(uint256, uint256[] calldata) internal pure override {
        // Not used in Crash game
        revert("Not implemented");
    }
}
