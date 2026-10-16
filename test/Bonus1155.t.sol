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

    function testTopUpAddsBalanceAndRequirementsWithoutChangingExpiry() public {
        bytes memory purchaseSignature = _purchaseSignature(PLAYER, 4);
        vm.prank(PLAYER);
        uint256 bonusId = bonus.purchaseBonus{value: 1 ether}(
            address(0),
            1 ether,
            100 ether,
            50 ether,
            block.timestamp + 1 days,
            false,
            block.timestamp + 1 hours,
            4,
            purchaseSignature
        );
        uint256 originalExpiry = bonus.getBonus(bonusId).expiresAt;
        bonus.debitStakeAndRecordWager(PLAYER, address(0), bonusId, 10 ether, 5 ether);
        bytes memory topUpSignature = _topUpSignature(PLAYER, bonusId, 5);

        vm.prank(PLAYER);
        bonus.topUpBonus{value: 0.5 ether}(
            bonusId,
            0.5 ether,
            75 ether,
            37.5 ether,
            block.timestamp + 1 hours,
            5,
            topUpSignature
        );

        Bonus1155.Bonus memory toppedUp = bonus.getBonus(bonusId);
        assertEq(bonus.balanceOf(PLAYER, bonusId), 165 ether);
        assertEq(toppedUp.payAmount, 1.5 ether);
        assertEq(toppedUp.mintAmount, 175 ether);
        assertEq(toppedUp.wagerRequirement, 87.5 ether);
        assertEq(toppedUp.wageredAmount, 5 ether);
        assertEq(toppedUp.expiresAt, originalExpiry);
    }

    function testPolicyTopUpCanIncreaseRequirementAndResetProgress() public {
        bytes memory purchaseSignature = _purchaseSignature(PLAYER, 16);
        vm.prank(PLAYER);
        uint256 bonusId = bonus.purchaseBonus{value: 1 ether}(
            address(0), 1 ether, 100 ether, 50 ether, block.timestamp + 1 days, false, block.timestamp + 1 hours, 16, purchaseSignature
        );
        bonus.debitStakeAndRecordWager(PLAYER, address(0), bonusId, 10 ether, 5 ether);
        bytes memory topUpSignature =
            _policyTopUpSignature(PLAYER, bonusId, 37.5 ether, true, true, 17);

        vm.prank(PLAYER);
        bonus.topUpBonusWithPolicy{value: 0.5 ether}(
            bonusId, 0.5 ether, 75 ether, 37.5 ether, true, true, block.timestamp + 1 hours, 17, topUpSignature
        );

        Bonus1155.Bonus memory toppedUp = bonus.getBonus(bonusId);
        assertEq(toppedUp.wagerRequirement, 87.5 ether);
        assertEq(toppedUp.wageredAmount, 0);
    }

    function testPolicyTopUpCanPreserveRequirementAndResetProgress() public {
        bytes memory purchaseSignature = _purchaseSignature(PLAYER, 18);
        vm.prank(PLAYER);
        uint256 bonusId = bonus.purchaseBonus{value: 1 ether}(
            address(0), 1 ether, 100 ether, 50 ether, block.timestamp + 1 days, false, block.timestamp + 1 hours, 18, purchaseSignature
        );
        bonus.debitStakeAndRecordWager(PLAYER, address(0), bonusId, 10 ether, 5 ether);
        bytes memory topUpSignature =
            _policyTopUpSignature(PLAYER, bonusId, 0, false, true, 19);

        vm.prank(PLAYER);
        bonus.topUpBonusWithPolicy{value: 0.5 ether}(
            bonusId, 0.5 ether, 75 ether, 0, false, true, block.timestamp + 1 hours, 19, topUpSignature
        );

        Bonus1155.Bonus memory toppedUp = bonus.getBonus(bonusId);
        assertEq(toppedUp.wagerRequirement, 50 ether);
        assertEq(toppedUp.wageredAmount, 0);
    }

    function testPolicyTopUpSignatureBindsPolicy() public {
        bytes memory purchaseSignature = _purchaseSignature(PLAYER, 20);
        vm.prank(PLAYER);
        uint256 bonusId = bonus.purchaseBonus{value: 1 ether}(
            address(0), 1 ether, 100 ether, 50 ether, block.timestamp + 1 days, false, block.timestamp + 1 hours, 20, purchaseSignature
        );
        bytes memory topUpSignature =
            _policyTopUpSignature(PLAYER, bonusId, 37.5 ether, true, false, 21);

        vm.expectRevert("INVALID_SIGNATURE");
        vm.prank(PLAYER);
        bonus.topUpBonusWithPolicy{value: 0.5 ether}(
            bonusId, 0.5 ether, 75 ether, 37.5 ether, true, true, block.timestamp + 1 hours, 21, topUpSignature
        );
    }

    function testTopUpRejectsNonPurchaser() public {
        bytes memory purchaseSignature = _purchaseSignature(PLAYER, 6);
        vm.prank(PLAYER);
        uint256 bonusId = bonus.purchaseBonus{value: 1 ether}(
            address(0), 1 ether, 100 ether, 50 ether, block.timestamp + 1 days, false, block.timestamp + 1 hours, 6, purchaseSignature
        );

        bytes memory topUpSignature = _topUpSignature(PLAYER, bonusId, 7);
        vm.expectRevert("NOT_PURCHASER");
        vm.prank(ATTACKER);
        bonus.topUpBonus{value: 0.5 ether}(
            bonusId, 0.5 ether, 75 ether, 37.5 ether, block.timestamp + 1 hours, 7, topUpSignature
        );
    }

    function testTopUpRejectsSharedSupply() public {
        bytes memory purchaseSignature = _purchaseSignatureWithTransferable(PLAYER, 8, true);
        vm.prank(PLAYER);
        uint256 bonusId = bonus.purchaseBonus{value: 1 ether}(
            address(0), 1 ether, 100 ether, 50 ether, block.timestamp + 1 days, true, block.timestamp + 1 hours, 8, purchaseSignature
        );
        bonus.setTransfersEnabled(true);
        vm.prank(PLAYER);
        bonus.safeTransferFrom(PLAYER, ATTACKER, bonusId, 1 ether, "");

        bytes memory topUpSignature = _topUpSignature(PLAYER, bonusId, 9);
        vm.expectRevert("BONUS_SHARED");
        vm.prank(PLAYER);
        bonus.topUpBonus{value: 0.5 ether}(
            bonusId, 0.5 ether, 75 ether, 37.5 ether, block.timestamp + 1 hours, 9, topUpSignature
        );
    }

    function testTopUpRejectsExpiredBonus() public {
        bytes memory purchaseSignature = _purchaseSignature(PLAYER, 10);
        vm.prank(PLAYER);
        uint256 bonusId = bonus.purchaseBonus{value: 1 ether}(
            address(0), 1 ether, 100 ether, 50 ether, block.timestamp + 1 days, false, block.timestamp + 1 hours, 10, purchaseSignature
        );
        vm.warp(block.timestamp + 2 days);

        bytes memory topUpSignature = _topUpSignature(PLAYER, bonusId, 11);
        vm.expectRevert("BONUS_EXPIRED");
        vm.prank(PLAYER);
        bonus.topUpBonus{value: 0.5 ether}(
            bonusId, 0.5 ether, 75 ether, 37.5 ether, block.timestamp + 1 hours, 11, topUpSignature
        );
    }

    function testTopUpRejectsReusedNonce() public {
        bytes memory purchaseSignature = _purchaseSignature(PLAYER, 12);
        vm.prank(PLAYER);
        uint256 bonusId = bonus.purchaseBonus{value: 1 ether}(
            address(0), 1 ether, 100 ether, 50 ether, block.timestamp + 1 days, false, block.timestamp + 1 hours, 12, purchaseSignature
        );
        bytes memory topUpSignature = _topUpSignature(PLAYER, bonusId, 13);
        vm.prank(PLAYER);
        bonus.topUpBonus{value: 0.5 ether}(
            bonusId, 0.5 ether, 75 ether, 37.5 ether, block.timestamp + 1 hours, 13, topUpSignature
        );

        vm.prank(PLAYER);
        vm.expectRevert("NONCE_USED");
        bonus.topUpBonus{value: 0.5 ether}(
            bonusId, 0.5 ether, 75 ether, 37.5 ether, block.timestamp + 1 hours, 13, topUpSignature
        );
    }

    function testTopUpSignatureBindsAmounts() public {
        bytes memory purchaseSignature = _purchaseSignature(PLAYER, 14);
        vm.prank(PLAYER);
        uint256 bonusId = bonus.purchaseBonus{value: 1 ether}(
            address(0), 1 ether, 100 ether, 50 ether, block.timestamp + 1 days, false, block.timestamp + 1 hours, 14, purchaseSignature
        );

        bytes memory topUpSignature = _topUpSignature(PLAYER, bonusId, 15);
        vm.expectRevert("INVALID_SIGNATURE");
        vm.prank(PLAYER);
        bonus.topUpBonus{value: 0.6 ether}(
            bonusId, 0.6 ether, 75 ether, 37.5 ether, block.timestamp + 1 hours, 15, topUpSignature
        );
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
        return _purchaseSignatureWithTransferable(buyer, nonce, false);
    }

    function _purchaseSignatureWithTransferable(address buyer, uint256 nonce, bool transferable) private view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encode(
                bonus.PURCHASE_TYPEHASH(),
                buyer,
                address(0),
                1 ether,
                100 ether,
                50 ether,
                block.timestamp + 1 days,
                transferable,
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

    function _topUpSignature(address buyer, uint256 bonusId, uint256 nonce) private view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encode(
                bonus.TOP_UP_TYPEHASH(),
                buyer,
                bonusId,
                address(0),
                0.5 ether,
                75 ether,
                37.5 ether,
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

    function _policyTopUpSignature(
        address buyer,
        uint256 bonusId,
        uint256 wagerRequirement,
        bool increaseWagerRequirement,
        bool resetWagerProgress,
        uint256 nonce
    ) private view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encode(
                bonus.TOP_UP_POLICY_TYPEHASH(),
                buyer,
                bonusId,
                address(0),
                0.5 ether,
                75 ether,
                wagerRequirement,
                increaseWagerRequirement,
                resetWagerProgress,
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
