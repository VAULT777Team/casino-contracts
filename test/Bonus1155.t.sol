// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Bonus1155} from "../contracts/games/bonus/Bonus1155.sol";

contract BonusBankrollMock {
    function depositEther() external payable {}
    function deposit(address, uint256) external {}

    function transferPayout(address player, uint256 amount, address token) external {
        require(token == address(0), "TOKEN_UNSUPPORTED");
        (bool success,) = payable(player).call{value: amount}("");
        require(success, "PAYOUT_FAILED");
    }
}

contract BonusRegistryMock {
    address internal immutable bankroll;

    constructor(address bankroll_) {
        bankroll = bankroll_;
    }

    function getCurrentBankroll() external view returns (address, address, string memory, uint256) {
        return (bankroll, address(0), "test", block.timestamp);
    }
}

contract Bonus1155Test is Test {
    uint256 internal constant SIGNER_KEY = 0xA11CE;
    address internal constant PLAYER = address(0xBEEF);
    address internal constant ATTACKER = address(0xBAD);

    Bonus1155 internal bonus;

    function setUp() public {
        BonusBankrollMock bankroll = new BonusBankrollMock();
        BonusRegistryMock registry = new BonusRegistryMock(address(bankroll));
        bonus = new Bonus1155("ipfs://bonus/{id}.json", address(registry), vm.addr(SIGNER_KEY));
        bonus.setBonusGameLedger(address(this));
        vm.deal(PLAYER, 10 ether);
        vm.deal(ATTACKER, 10 ether);
    }

    function testPurchaseAuthorizationIsBoundToCaller() public {
        bytes memory signature = _purchaseSignature(PLAYER, 1);

        vm.prank(ATTACKER);
        vm.expectRevert("INVALID_SIGNATURE");
        bonus.purchaseBonus{value: 1 ether}(
            address(0),
            1 ether,
            100 ether,
            50 ether,
            block.timestamp + 1 days,
            false,
            block.timestamp + 1 hours,
            1,
            signature
        );

        vm.prank(PLAYER);
        uint256 bonusId = bonus.purchaseBonus{value: 1 ether}(
            address(0),
            1 ether,
            100 ether,
            50 ether,
            block.timestamp + 1 days,
            false,
            block.timestamp + 1 hours,
            1,
            signature
        );
        assertEq(bonusId, 1);
        assertEq(bonus.balanceOf(PLAYER, bonusId), 100 ether);
    }

    function testLedgerCancellationRestoresStakeAndWagerProgress() public {
        bytes memory signature = _purchaseSignature(PLAYER, 2);
        vm.prank(PLAYER);
        uint256 bonusId = bonus.purchaseBonus{value: 1 ether}(
            address(0),
            1 ether,
            100 ether,
            50 ether,
            block.timestamp + 1 days,
            false,
            block.timestamp + 1 hours,
            2,
            signature
        );

        bonus.debitStakeAndRecordWager(PLAYER, address(0), bonusId, 40 ether, 25 ether);
        assertEq(bonus.balanceOf(PLAYER, bonusId), 60 ether);
        assertEq(bonus.getBonus(bonusId).wageredAmount, 25 ether);

        bonus.cancelStakeAndWager(PLAYER, address(0), bonusId, 40 ether, 25 ether);
        assertEq(bonus.balanceOf(PLAYER, bonusId), 100 ether);
        assertEq(bonus.getBonus(bonusId).wageredAmount, 0);
    }

    function testLedgerCancellationStillWorksAfterExpiryWhilePaused() public {
        bytes memory signature = _purchaseSignature(PLAYER, 3);
        vm.prank(PLAYER);
        uint256 bonusId = bonus.purchaseBonus{value: 1 ether}(
            address(0),
            1 ether,
            100 ether,
            50 ether,
            block.timestamp + 1 days,
            false,
            block.timestamp + 1 hours,
            3,
            signature
        );
        bonus.debitStakeAndRecordWager(PLAYER, address(0), bonusId, 40 ether, 25 ether);

        vm.warp(block.timestamp + 2 days);
        bonus.pause();
        bonus.cancelStakeAndWager(PLAYER, address(0), bonusId, 40 ether, 25 ether);

        assertEq(bonus.balanceOf(PLAYER, bonusId), 100 ether);
        assertEq(bonus.getBonus(bonusId).wageredAmount, 0);
    }

    function _purchaseSignature(address buyer, uint256 nonce) private view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encode(
                bonus.PURCHASE_TYPEHASH(),
                buyer,
                address(0),
                1 ether,
                100 ether,
                50 ether,
                block.timestamp + 1 days,
                false,
                nonce,
                address(bonus),
                block.chainid,
                block.timestamp + 1 hours
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(SIGNER_KEY, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest)));
        return abi.encodePacked(r, s, v);
    }
}
