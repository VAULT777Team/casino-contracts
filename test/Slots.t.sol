// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {Slots} from "../contracts/games/Slots.sol";
import {VRFConfig} from "../contracts/Common.sol";

contract SlotsVRFMock {
    uint256 public nextRequestID = 1;

    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata) external returns (uint256 requestID) {
        requestID = nextRequestID++;
    }

    function fulfill(address consumer, uint256 requestID, uint32 numWords) external {
        uint256[] memory randomWords = new uint256[](numWords);
        (bool success,) =
            consumer.call(abi.encodeWithSignature("rawFulfillRandomWords(uint256,uint256[])", requestID, randomWords));
        require(success, "fulfill failed");
    }
}

contract SlotsFeeManagerMock {
    function quoteVRFFee(address, uint32, uint32, uint256, uint256) external pure returns (uint256) {
        return 0;
    }
}

contract SlotsBankrollMock {
    mapping(address => bool) public games;

    receive() external payable {}

    function setGame(address game, bool enabled) external {
        games[game] = enabled;
    }

    function getAvailableBalance(address) external view returns (uint256) {
        return address(this).balance;
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

contract SlotsRegistryMock {
    address public immutable bankroll;

    constructor(address _bankroll) {
        bankroll = _bankroll;
    }

    function getCurrentBankroll() external view returns (address, address, string memory, uint256) {
        return (bankroll, address(0), "test", block.timestamp);
    }
}

contract SlotsTest is Test {
    Slots internal game;
    SlotsVRFMock internal coordinator;
    SlotsBankrollMock internal bankroll;
    address internal player = address(0xBEEF);

    function setUp() public {
        coordinator = new SlotsVRFMock();
        bankroll = new SlotsBankrollMock();
        SlotsRegistryMock registry = new SlotsRegistryMock(address(bankroll));
        SlotsFeeManagerMock feeManager = new SlotsFeeManagerMock();

        VRFConfig memory vrf = VRFConfig({
            coordinator: address(coordinator),
            keyHash: bytes32(0),
            subId: 1,
            reqConfirmations: 1,
            callbackGasLimit: 1_000_000,
            feeManager: address(feeManager)
        });

        uint16[] memory multipliers = new uint16[](0);
        uint16[] memory outcomeNumbers = new uint16[](0);
        uint16[] memory bonusMultipliers = new uint16[](0);
        uint8[] memory bonusRounds = new uint8[](0);
        uint16[] memory bonusOutcomeNumbers = new uint16[](0);

        game = new Slots(
            address(registry),
            vrf,
            20,
            multipliers,
            outcomeNumbers,
            1,
            bonusMultipliers,
            bonusRounds,
            bonusOutcomeNumbers,
            5,
            1
        );

        bankroll.setGame(address(game), true);
        vm.deal(address(bankroll), 10_000 ether);
        vm.deal(player, 10 ether);
    }

    function testRefundsUnprocessedBetsNotRows() public {
        uint256 wager = 1 ether;
        uint32 numBets = 2;
        uint256 playerBalanceBefore = player.balance;
        uint256 bankrollBalanceBefore = address(bankroll).balance;

        vm.prank(player);
        game.Slots_Play{value: wager * numBets}(wager, address(0), numBets, 0, type(uint256).max);

        coordinator.fulfill(address(game), 1, numBets);

        assertEq(player.balance, playerBalanceBefore);
        assertEq(address(bankroll).balance, bankrollBalanceBefore);
    }
}
