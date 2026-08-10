// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {CoinFlipDoubleOrNothing} from "../contracts/games/CoinFlipDoubleOrNothing.sol";
import {VRFConfig} from "../contracts/Common.sol";

contract DoubleOrNothingVRFMock {
    uint256 public nextRequestID = 1;

    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata) external returns (uint256 requestID) {
        requestID = nextRequestID++;
    }

    function fulfill(address consumer, uint256 requestID, uint256 randomWord) external {
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = randomWord;
        (bool success,) =
            consumer.call(abi.encodeWithSignature("rawFulfillRandomWords(uint256,uint256[])", requestID, randomWords));
        require(success, "fulfill failed");
    }
}

contract DoubleOrNothingFeeManagerMock {
    function quoteVRFFee(address, uint32, uint32, uint256, uint256) external pure returns (uint256) {
        return 0;
    }
}

contract DoubleOrNothingBankrollMock {
    uint256 public reserved;
    mapping(address => bool) public games;

    receive() external payable {}

    function setGame(address game, bool enabled) external {
        games[game] = enabled;
    }

    function getAvailableBalance(address) external view returns (uint256) {
        return address(this).balance - reserved;
    }

    function reserveFunds(address, uint256 amount) external {
        require(games[msg.sender], "not game");
        require(amount <= address(this).balance - reserved, "insufficient");
        reserved += amount;
    }

    function releaseFunds(address, uint256 amount) external {
        require(games[msg.sender], "not game");
        reserved -= amount;
    }

    function depositEther() external payable returns (bool) {
        return true;
    }

    function deposit(address, uint256) external {}

    function transferPayout(address player, uint256 payout, address) external {
        require(games[msg.sender], "not game");
        (bool success,) = payable(player).call{value: payout}("");
        require(success, "payout failed");
    }

    function getIsValidWager(address game, address tokenAddress) external view returns (bool) {
        return games[game] && tokenAddress == address(0);
    }

    function isPlayerSuspended(address) external pure returns (bool, uint256) {
        return (false, 0);
    }

    function getOwner() external view returns (address) {
        return address(this);
    }
}

contract DoubleOrNothingRegistryMock {
    address public immutable bankroll;

    constructor(address _bankroll) {
        bankroll = _bankroll;
    }

    function getCurrentBankroll() external view returns (address, address, string memory, uint256) {
        return (bankroll, address(0), "test", block.timestamp);
    }
}

contract CoinFlipDoubleOrNothingTest is Test {
    CoinFlipDoubleOrNothing internal game;
    DoubleOrNothingVRFMock internal coordinator;
    DoubleOrNothingBankrollMock internal bankroll;
    address internal player = address(0xBEEF);

    function setUp() public {
        coordinator = new DoubleOrNothingVRFMock();
        bankroll = new DoubleOrNothingBankrollMock();
        DoubleOrNothingRegistryMock registry = new DoubleOrNothingRegistryMock(address(bankroll));
        DoubleOrNothingFeeManagerMock feeManager = new DoubleOrNothingFeeManagerMock();

        VRFConfig memory vrf = VRFConfig({
            coordinator: address(coordinator),
            keyHash: bytes32(0),
            subId: 1,
            reqConfirmations: 1,
            callbackGasLimit: 500_000,
            feeManager: address(feeManager)
        });

        game = new CoinFlipDoubleOrNothing(address(registry), vrf, 20);
        bankroll.setGame(address(game), true);
        vm.deal(address(bankroll), 10_000 ether);
        vm.deal(player, 10 ether);
    }

    function testSuccessiveWinsDoublePayoutAndCanCashOut() public {
        _start(1 ether, true);
        _fulfill(1, true);

        CoinFlipDoubleOrNothing.DoubleOrNothingGame memory state = game.DoubleOrNothing_GetState(player);
        assertEq(state.wins, 1);
        assertEq(state.currentPayout, 1.96 ether);
        assertEq(bankroll.reserved(), 1.96 ether);

        vm.prank(player);
        game.DoubleOrNothing_Continue(false);
        assertEq(bankroll.reserved(), 3.92 ether);

        _fulfill(2, false);
        state = game.DoubleOrNothing_GetState(player);
        assertEq(state.wins, 2);
        assertEq(state.currentPayout, 3.92 ether);

        uint256 balanceBefore = player.balance;
        vm.prank(player);
        game.DoubleOrNothing_CashOut();

        assertEq(player.balance - balanceBefore, 3.92 ether);
        assertEq(bankroll.reserved(), 0);
        assertEq(game.DoubleOrNothing_GetState(player).wager, 0);
    }

    function testLossSettlesWagerAndClearsGame() public {
        uint256 bankrollBefore = address(bankroll).balance;
        _start(1 ether, true);
        _fulfill(1, false);

        assertEq(address(bankroll).balance, bankrollBefore + 1 ether);
        assertEq(bankroll.reserved(), 0);
        assertEq(game.DoubleOrNothing_GetState(player).wager, 0);
    }

    function testInitialRequestTimeoutRefundsWager() public {
        uint256 playerBefore = player.balance;
        _start(1 ether, true);
        vm.roll(block.number + 20);

        vm.prank(player);
        game.DoubleOrNothing_Refund();

        assertEq(player.balance, playerBefore);
        assertEq(bankroll.reserved(), 0);
        assertEq(game.DoubleOrNothing_GetState(player).wager, 0);
    }

    function testContinuationTimeoutRestoresCashoutState() public {
        _start(1 ether, true);
        _fulfill(1, true);

        vm.prank(player);
        game.DoubleOrNothing_Continue(false);
        assertEq(bankroll.reserved(), 3.92 ether);

        vm.roll(block.number + 20);
        vm.prank(player);
        game.DoubleOrNothing_Refund();

        CoinFlipDoubleOrNothing.DoubleOrNothingGame memory state = game.DoubleOrNothing_GetState(player);
        assertEq(state.requestID, 0);
        assertEq(state.wins, 1);
        assertEq(state.currentPayout, 1.96 ether);
        assertEq(state.reservedPayout, 1.96 ether);
        assertEq(bankroll.reserved(), 1.96 ether);
    }

    function testTwentiethWinAutomaticallyCashOuts() public {
        uint256 wager = 1_000_000;
        uint256 expectedPayout = (wager * 19_600) / 10_000;
        uint256 balanceBefore = player.balance;

        _start(wager, true);
        for (uint256 win = 1; win <= 20; win++) {
            _fulfill(win, true);
            if (win < 20) {
                vm.prank(player);
                game.DoubleOrNothing_Continue(true);
                expectedPayout *= 2;
            }
        }

        assertEq(player.balance, balanceBefore - wager + expectedPayout);
        assertEq(bankroll.reserved(), 0);
        assertEq(game.DoubleOrNothing_GetState(player).wager, 0);
    }

    function _start(uint256 wager, bool isHeads) internal {
        vm.prank(player);
        game.DoubleOrNothing_StartGame{value: wager}(wager, address(0), isHeads);
    }

    function _fulfill(uint256 requestID, bool heads) internal {
        coordinator.fulfill(address(game), requestID, heads ? 1 : 0);
    }
}
