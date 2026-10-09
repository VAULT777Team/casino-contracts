// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IHouseGameFees {
    function VRFFees(address token) external view returns (uint256);
}

/// @notice Aggregates current, unwithdrawn VRF fees across registered house games.
/// @dev Historical fees already withdrawn through transferFees are not available from game state.
contract HouseGameFeeAggregator is Ownable {
    struct Game {
        string name;
        address game;
    }

    struct GameFee {
        string name;
        address game;
        uint256 fees;
        bool readable;
    }

    error EmptyName();
    error InvalidGame(address game);
    error DuplicateGame(address game);
    error InvalidIndex(uint256 index);

    event GamesReplaced(uint256 count);
    event GameUpdated(uint256 indexed index, string name, address indexed game);

    Game[] private games;

    constructor(Game[] memory initialGames) {
        _replaceGames(initialGames);
    }

    function replaceGames(Game[] calldata newGames) external onlyOwner {
        _replaceGames(newGames);
    }

    function updateGame(uint256 index, Game calldata newGame) external onlyOwner {
        if (index >= games.length) revert InvalidIndex(index);
        _validateGame(newGame, index);
        games[index] = newGame;
        emit GameUpdated(index, newGame.name, newGame.game);
    }

    function gameCount() external view returns (uint256) {
        return games.length;
    }

    function getGame(uint256 index) external view returns (Game memory) {
        if (index >= games.length) revert InvalidIndex(index);
        return games[index];
    }

    /// @notice Returns every registered game and the combined current fee balance for `token`.
    /// @dev An unreadable game is returned with `readable == false` and contributes zero to the total.
    function getHouseGameFees(address token)
        external
        view
        returns (uint256 totalFees, GameFee[] memory gameFees)
    {
        uint256 length = games.length;
        gameFees = new GameFee[](length);

        for (uint256 i; i < length; ++i) {
            Game storage registeredGame = games[i];
            try IHouseGameFees(registeredGame.game).VRFFees(token) returns (uint256 fees) {
                totalFees += fees;
                gameFees[i] = GameFee({
                    name: registeredGame.name,
                    game: registeredGame.game,
                    fees: fees,
                    readable: true
                });
            } catch {
                gameFees[i] = GameFee({
                    name: registeredGame.name,
                    game: registeredGame.game,
                    fees: 0,
                    readable: false
                });
            }
        }
    }

    function _replaceGames(Game[] memory newGames) internal {
        delete games;
        uint256 length = newGames.length;
        for (uint256 i; i < length; ++i) {
            _validateGame(newGames[i], type(uint256).max);
            games.push(newGames[i]);
        }
        emit GamesReplaced(length);
    }

    function _validateGame(Game memory newGame, uint256 excludedIndex) internal view {
        if (bytes(newGame.name).length == 0) revert EmptyName();
        if (newGame.game == address(0)) revert InvalidGame(newGame.game);

        uint256 length = games.length;
        for (uint256 i; i < length; ++i) {
            if (i != excludedIndex && games[i].game == newGame.game) {
                revert DuplicateGame(newGame.game);
            }
        }
    }
}
