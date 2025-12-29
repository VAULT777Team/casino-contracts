// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { BankrollRegistry } from "../bankroll/BankrollRegistry.sol";
import { BankLP } from "../bankroll/facets/BankLP.sol";

contract GameRegistry {
    struct GameInfo {
        address owner;
        address gameContract;
        uint256 nftId;
        string configURI;
    }

    GameInfo[] public games;
    mapping(address => uint256[]) public ownerGames;

    BankrollRegistry public bankrollRegistry;

    event GameRegistered(address indexed owner, address indexed gameContract, uint256 nftId, string configURI);

    function registerGame(address owner, address gameContract, uint256 nftId, string memory configURI) external {
        ( address currentBankroll,,, ) = bankrollRegistry.getCurrentBankroll();
        require(currentBankroll != address(0), "Bankroll not set");
        
        games.push(GameInfo({
            owner: owner,
            gameContract: gameContract,
            nftId: nftId,
            configURI: configURI
        }));
        ownerGames[owner].push(games.length - 1);
        
        BankLP(payable(currentBankroll)).setGameCreator(gameContract, owner, 100); // Example fee percentage
        
        emit GameRegistered(owner, gameContract, nftId, configURI);
    }

    function getGamesByOwner(address owner) external view returns (uint256[] memory) {
        return ownerGames[owner];
    }

    function getGameInfo(uint256 gameId) external view returns (GameInfo memory) {
        return games[gameId];
    }
}
