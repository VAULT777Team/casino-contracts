// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Vault777Lottery} from "../contracts/games/lottery/Vault777Lottery.sol";

contract LotteryTestUSDC is ERC20 {
    constructor() ERC20("Lottery Test USDC", "tUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract Vault777LotteryTest is Test {
    Vault777Lottery internal lottery;
    LotteryTestUSDC internal token;

    address internal constant ADMIN = address(0xA11CE);
    address internal constant OPERATOR = address(0xB0B);
    address internal constant BUYER = address(0xCAFE);
    address internal constant SEEDER = address(0xD00D);
    address internal constant HOUSE = address(0xFEE);
    address internal constant WINNER = address(0x1234);

    function setUp() public {
        token = new LotteryTestUSDC();
        lottery = new Vault777Lottery(token, ADMIN, OPERATOR, HOUSE);
        token.mint(BUYER, 1_000_000e6);
        token.mint(SEEDER, 1_000_000e6);
    }

    function testHappyPathPurchasesSeedsPaysAndRollsOver() public {
        _createRound(1, uint16(1_000));
        vm.prank(OPERATOR);
        lottery.createRound(2, uint64(block.timestamp + 2 days), 10e6, 20e6, 2, 1_000);

        Vault777Lottery.Ticket[] memory tickets = new Vault777Lottery.Ticket[](2);
        tickets[0] = _ticket(_mainMask(1, 2, 3, 4, 5), uint32(1) << 1);
        tickets[1] = _ticket(_mainMask(6, 7, 8, 9, 10), (uint32(1) << 2) | (uint32(1) << 3));
        vm.startPrank(BUYER);
        token.approve(address(lottery), type(uint256).max);
        lottery.buyTickets(1, tickets);
        vm.stopPrank();

        vm.startPrank(SEEDER);
        token.approve(address(lottery), type(uint256).max);
        lottery.seedRound(1, 20e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        address[] memory recipients = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        recipients[0] = WINNER;
        amounts[0] = 15e6;
        vm.prank(OPERATOR);
        lottery.payWinners(1, recipients, amounts);

        vm.prank(OPERATOR);
        lottery.finalizeRound(1, 3e6, 2);

        (,,,,,,, uint256 roundBalance, uint256 ticketCount) = lottery.rounds(1);
        (,,,,,,, uint256 nextBalance,) = lottery.rounds(2);
        assertEq(roundBalance, 0);
        assertEq(ticketCount, 2);
        assertEq(nextBalance, 32e6);
        assertEq(token.balanceOf(WINNER), 15e6);
        assertEq(token.balanceOf(HOUSE), 3e6);
        assertTrue(lottery.paid(1, WINNER));
        (,,, bool finalized,,,,,) = lottery.rounds(1);
        assertTrue(finalized);
    }

    function testTicketIndexIsSequentialAcrossPurchases() public {
        _createRound(1, 0);
        Vault777Lottery.Ticket[] memory tickets = new Vault777Lottery.Ticket[](1);
        tickets[0] = _ticket(_mainMask(1, 2, 3, 4, 5), uint32(1) << 1);

        vm.startPrank(BUYER);
        token.approve(address(lottery), type(uint256).max);
        vm.expectEmit(true, true, true, true, address(lottery));
        emit Vault777Lottery.TicketPurchased(1, BUYER, 0, tickets[0].mainMask, tickets[0].pbMask, 10e6);
        lottery.buyTickets(1, tickets);
        vm.expectEmit(true, true, true, true, address(lottery));
        emit Vault777Lottery.TicketPurchased(1, BUYER, 1, tickets[0].mainMask, tickets[0].pbMask, 10e6);
        lottery.buyTickets(1, tickets);
        vm.stopPrank();

        (,,,,,,, uint256 sales, uint256 ticketCount) = lottery.rounds(1);
        assertEq(sales, 20e6);
        assertEq(ticketCount, 2);
    }

    function testRejectsWrongMainPopcount() public {
        uint128 mask = (uint128(1) << 1) | (uint128(1) << 2) | (uint128(1) << 3) | (uint128(1) << 4);
        _expectInvalidTicket(_ticket(mask, uint32(1) << 1), abi.encodeWithSelector(Vault777Lottery.InvalidMainNumberCount.selector, 4));
    }

    function testRejectsMainBitZero() public {
        uint128 mask = (uint128(1) << 0) | _mainMask(1, 2, 3, 4, 5);
        _expectInvalidTicket(_ticket(mask, uint32(1) << 1), abi.encodeWithSelector(Vault777Lottery.InvalidMainMask.selector, mask));
    }

    function testRejectsMainBit75() public {
        uint128 mask = (uint128(1) << 75) | _mainMask(1, 2, 3, 4, 5);
        _expectInvalidTicket(_ticket(mask, uint32(1) << 1), abi.encodeWithSelector(Vault777Lottery.InvalidMainMask.selector, mask));
    }

    function testRejectsPowerballBit19() public {
        uint32 mask = uint32(1) << 19;
        _expectInvalidTicket(_ticket(_mainMask(1, 2, 3, 4, 5), mask), abi.encodeWithSelector(Vault777Lottery.InvalidPowerballMask.selector, mask));
    }

    function testRejectsPowerballCountMismatch() public {
        uint32 threePowerballs = (uint32(1) << 1) | (uint32(1) << 2) | (uint32(1) << 3);
        _expectInvalidTicket(_ticket(_mainMask(1, 2, 3, 4, 5), threePowerballs), abi.encodeWithSelector(Vault777Lottery.InvalidPowerballCount.selector, 3));
    }

    function testCannotBuyAfterClose() public {
        _createRound(1, 0);
        vm.warp(block.timestamp + 1 days);
        Vault777Lottery.Ticket[] memory tickets = _oneStandardTicket();
        vm.prank(BUYER);
        vm.expectRevert(abi.encodeWithSelector(Vault777Lottery.RoundClosed.selector, 1));
        lottery.buyTickets(1, tickets);
    }

    function testRejectsTooManyTickets() public {
        _createRound(1, 0);
        Vault777Lottery.Ticket[] memory tickets = new Vault777Lottery.Ticket[](101);
        for (uint256 i; i < tickets.length; ++i) {
            tickets[i] = _ticket(_mainMask(1, 2, 3, 4, 5), uint32(1) << 1);
        }
        vm.prank(BUYER);
        vm.expectRevert(abi.encodeWithSelector(Vault777Lottery.InvalidTicketCount.selector, 101));
        lottery.buyTickets(1, tickets);
    }

    function testDoublePayReverts() public {
        _createRound(1, 0);
        vm.prank(SEEDER);
        token.approve(address(lottery), 10e6);
        vm.prank(SEEDER);
        lottery.seedRound(1, 10e6);
        vm.warp(block.timestamp + 1 days);

        address[] memory recipients = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        recipients[0] = WINNER;
        amounts[0] = 5e6;
        vm.prank(OPERATOR);
        lottery.payWinners(1, recipients, amounts);

        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(Vault777Lottery.AlreadyPaid.selector, WINNER));
        lottery.payWinners(1, recipients, amounts);
    }

    function testFeeCapIsEnforced() public {
        _createRound(1, 1_000);
        _createRound(2, 1_000);
        _buyOneStandardTicket(1);
        vm.warp(block.timestamp + 1 days);

        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(Vault777Lottery.FeeExceedsCap.selector, 2e6, 1e6));
        lottery.finalizeRound(1, 2e6, 2);
    }

    function testFinalizeRequiresOpenNextRound() public {
        _createRound(1, 0);
        _createRound(2, 0);
        vm.warp(block.timestamp + 2 days);

        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(Vault777Lottery.InvalidNextRound.selector, 2));
        lottery.finalizeRound(1, 0, 2);
    }

    function testNonOperatorCannotCreateRound() public {
        vm.prank(BUYER);
        vm.expectRevert();
        lottery.createRound(1, uint64(block.timestamp + 1 days), 10e6, 20e6, 2, 1_000);
    }

    function testPauseBlocksTicketPurchases() public {
        _createRound(1, 0);
        vm.prank(ADMIN);
        lottery.pause();
        vm.prank(BUYER);
        vm.expectRevert("Pausable: paused");
        lottery.buyTickets(1, _oneStandardTicket());
    }

    function testAdminCanCloseOutRound() public {
        _createRound(1, 0);
        vm.prank(SEEDER);
        token.approve(address(lottery), 12e6);
        vm.prank(SEEDER);
        lottery.seedRound(1, 12e6);
        vm.warp(block.timestamp + 1 days);

        vm.prank(ADMIN);
        lottery.closeOutRound(1);
        assertEq(token.balanceOf(HOUSE), 12e6);
        (,,, bool finalized,,,, uint256 balance,) = lottery.rounds(1);
        assertTrue(finalized);
        assertEq(balance, 0);
    }

    function _expectInvalidTicket(Vault777Lottery.Ticket memory ticket, bytes memory expectedError) internal {
        _createRound(1, 0);
        Vault777Lottery.Ticket[] memory tickets = new Vault777Lottery.Ticket[](1);
        tickets[0] = ticket;
        vm.prank(BUYER);
        vm.expectRevert(expectedError);
        lottery.buyTickets(1, tickets);
    }

    function _createRound(uint256 roundId, uint16 houseBps) internal {
        vm.prank(OPERATOR);
        lottery.createRound(roundId, uint64(block.timestamp + 1 days), 10e6, 20e6, 2, houseBps);
    }

    function _buyOneStandardTicket(uint256 roundId) internal {
        Vault777Lottery.Ticket[] memory tickets = _oneStandardTicket();
        vm.startPrank(BUYER);
        token.approve(address(lottery), type(uint256).max);
        lottery.buyTickets(roundId, tickets);
        vm.stopPrank();
    }

    function _oneStandardTicket() internal pure returns (Vault777Lottery.Ticket[] memory tickets) {
        tickets = new Vault777Lottery.Ticket[](1);
        tickets[0] = _ticket(_mainMask(1, 2, 3, 4, 5), uint32(1) << 1);
    }

    function _ticket(uint128 mainMask, uint32 pbMask) internal pure returns (Vault777Lottery.Ticket memory) {
        return Vault777Lottery.Ticket({mainMask: mainMask, pbMask: pbMask});
    }

    function _mainMask(uint8 a, uint8 b, uint8 c, uint8 d, uint8 e) internal pure returns (uint128) {
        return (uint128(1) << a) | (uint128(1) << b) | (uint128(1) << c) | (uint128(1) << d) | (uint128(1) << e);
    }
}
