// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {HouseGameFeeAggregator} from "../contracts/HouseGameFeeAggregator.sol";

contract FeeGameMock {
    mapping(address => uint256) public VRFFees;

    function setFees(address token, uint256 fees) external {
        VRFFees[token] = fees;
    }
}

contract RevertingFeeGameMock {
    function VRFFees(address) external pure returns (uint256) {
        revert("unavailable");
    }
}

contract HouseGameFeeAggregatorTest is Test {
    address internal constant USDC = address(0x1234);
    FeeGameMock internal coinFlip;
    FeeGameMock internal dice;
    RevertingFeeGameMock internal unavailable;
    HouseGameFeeAggregator internal aggregator;

    function setUp() public {
        coinFlip = new FeeGameMock();
        dice = new FeeGameMock();
        unavailable = new RevertingFeeGameMock();

        HouseGameFeeAggregator.Game[] memory games = new HouseGameFeeAggregator.Game[](3);
        games[0] = HouseGameFeeAggregator.Game("Coin Flip", address(coinFlip));
        games[1] = HouseGameFeeAggregator.Game("Dice", address(dice));
        games[2] = HouseGameFeeAggregator.Game("Unavailable", address(unavailable));
        aggregator = new HouseGameFeeAggregator(games);
    }

    function testReturnsAllGamesAndCombinedFeesInOneCall() public {
        coinFlip.setFees(USDC, 12e6);
        dice.setFees(USDC, 7e6);

        (uint256 totalFees, HouseGameFeeAggregator.GameFee[] memory fees) =
            aggregator.getHouseGameFees(USDC);

        assertEq(totalFees, 19e6);
        assertEq(fees.length, 3);
        assertEq(fees[0].name, "Coin Flip");
        assertEq(fees[0].game, address(coinFlip));
        assertEq(fees[0].fees, 12e6);
        assertTrue(fees[0].readable);
        assertEq(fees[1].fees, 7e6);
        assertTrue(fees[1].readable);
        assertEq(fees[2].fees, 0);
        assertFalse(fees[2].readable);
    }

    function testOwnerCanReplaceGames() public {
        HouseGameFeeAggregator.Game[] memory games = new HouseGameFeeAggregator.Game[](1);
        games[0] = HouseGameFeeAggregator.Game("Dice", address(dice));

        aggregator.replaceGames(games);

        assertEq(aggregator.gameCount(), 1);
        HouseGameFeeAggregator.Game memory game = aggregator.getGame(0);
        assertEq(game.name, "Dice");
        assertEq(game.game, address(dice));
    }

    function testNonOwnerCannotReplaceGames() public {
        HouseGameFeeAggregator.Game[] memory games = new HouseGameFeeAggregator.Game[](1);
        games[0] = HouseGameFeeAggregator.Game("Dice", address(dice));

        vm.prank(address(0xBEEF));
        vm.expectRevert("Ownable: caller is not the owner");
        aggregator.replaceGames(games);
    }

    function testRejectsDuplicateGames() public {
        HouseGameFeeAggregator.Game[] memory games = new HouseGameFeeAggregator.Game[](2);
        games[0] = HouseGameFeeAggregator.Game("Dice", address(dice));
        games[1] = HouseGameFeeAggregator.Game("Dice Copy", address(dice));

        vm.expectRevert(
            abi.encodeWithSelector(HouseGameFeeAggregator.DuplicateGame.selector, address(dice))
        );
        aggregator.replaceGames(games);
    }
}
