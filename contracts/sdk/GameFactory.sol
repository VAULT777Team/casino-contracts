// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./GameOwnershipNFT.sol";
import "./GameRegistry.sol";
import "./GameConfigLib.sol";

contract GameFactory {
    GameOwnershipNFT public nft;
    GameRegistry public registry;

    enum Preset { ROULETTE, BLACKJACK, DICE, SLOTS }

    event GameCreated(address indexed owner, address indexed gameContract, uint256 nftId, string configURI);

    constructor(address _nft, address _registry) {
        nft = GameOwnershipNFT(_nft);
        registry = GameRegistry(_registry);
    }

    // Only allow configs that match a preset
    function create(
        Preset presetId,
        uint32 version,
        bytes memory gameBytecode
    ) external returns (address gameContract, uint256 nftId) {
        GameConfigLib.GameConfig memory preset;
        if (presetId == Preset.ROULETTE) {
            preset = GameConfigLib.getRouletteConfig(version);
        } else if (presetId == Preset.BLACKJACK) {
            preset = GameConfigLib.getBlackjackConfig(version);
        } else if (presetId == Preset.DICE) {
            preset = GameConfigLib.getDiceConfig(version);
        } else if (presetId == Preset.SLOTS) {
            preset = GameConfigLib.getSlotsConfig();
            (uint16[] memory multipliers, uint16[] memory outcomes) = abi.decode(preset.extraData, (uint16[], uint16[])); // Validate extraData
        } else {
            revert("Invalid preset");
        }

        // Deploy new game contract
        bytes32 salt = keccak256(abi.encodePacked(msg.sender, preset.name, block.timestamp));
        assembly {
            gameContract := create2(0, add(gameBytecode, 0x20), mload(gameBytecode), salt)
            if iszero(gameContract) { revert(0, 0) }
        }

        // Mint NFT to owner, using preset name as URI for simplicity
        nftId = nft.mint(msg.sender, gameContract, preset.name);
        
        // Register game
        registry.registerGame(msg.sender, gameContract, nftId, preset.name);
        emit GameCreated(msg.sender, gameContract, nftId, preset.name);
    }
}
