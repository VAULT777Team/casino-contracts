// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ReloadClaimVault, SharedVipRewardVault, WeeklyRakebackVault} from "../contracts/bankroll/VipRewardVaults.sol";

contract MockVipRewardToken is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract VipRewardVaultsTest is Test {
    using ECDSA for bytes32;

    bytes4 internal constant NONCE_ALREADY_USED_SELECTOR = bytes4(keccak256("NonceAlreadyUsed(uint256)"));
    bytes4 internal constant INVALID_SIGNATURE_SELECTOR = bytes4(keccak256("InvalidSignature()"));
    bytes4 internal constant UNSUPPORTED_ACTION_SELECTOR = bytes4(keccak256("UnsupportedClaimAction(bytes32)"));
    bytes32 internal constant WEEKLY_ACTION = keccak256(bytes("VIP_WEEKLY_CLAIM"));
    bytes32 internal constant RELOAD_ACTION = keccak256(bytes("VIP_RELOAD_CLAIM"));

    SharedVipRewardVault public sharedVault;
    WeeklyRakebackVault public weeklyVault;
    ReloadClaimVault public reloadVault;
    MockVipRewardToken public usdc;

    uint256 internal backendPk;
    address internal backendSigner;
    address internal player;

    function setUp() public {
        backendPk = 0xA11CE;
        backendSigner = vm.addr(backendPk);
        player = makeAddr("player");

        sharedVault = new SharedVipRewardVault(backendSigner);
        weeklyVault = new WeeklyRakebackVault(backendSigner);
        reloadVault = new ReloadClaimVault(backendSigner);
        usdc = new MockVipRewardToken("Mock USDC", "USDC", 6);

        usdc.mint(address(this), 10_000e6);
        usdc.approve(address(sharedVault), type(uint256).max);
        usdc.approve(address(weeklyVault), type(uint256).max);
        usdc.approve(address(reloadVault), type(uint256).max);
    }

    function testSharedVaultWeeklyClaimTransfersERC20Payout() public {
        uint256 amount = 250e6;
        uint256 periodStart = 1_717_372_800;
        uint256 periodEnd = periodStart + 1 weeks;
        uint256 nonce = 7;
        uint256 deadline = block.timestamp + 1 hours;

        sharedVault.fundRewards(address(usdc), 1_000e6);

        bytes memory signature = _signClaim(
            address(sharedVault),
            WEEKLY_ACTION,
            player,
            address(usdc),
            amount,
            periodStart,
            periodEnd,
            nonce,
            deadline
        );

        vm.prank(player);
        sharedVault.claim(WEEKLY_ACTION, player, address(usdc), amount, periodStart, periodEnd, nonce, deadline, signature);

        assertEq(usdc.balanceOf(player), amount);
        assertTrue(sharedVault.usedNonces(player, nonce));
    }

    function testSharedVaultAllowsReloadAction() public {
        uint256 amount = 80e6;
        uint256 periodStart = 1_717_372_800;
        uint256 periodEnd = periodStart + 1 weeks;
        uint256 nonce = 12;
        uint256 deadline = block.timestamp + 1 hours;

        sharedVault.fundRewards(address(usdc), 1_000e6);

        bytes memory signature = _signClaim(
            address(sharedVault),
            RELOAD_ACTION,
            player,
            address(usdc),
            amount,
            periodStart,
            periodEnd,
            nonce,
            deadline
        );

        vm.prank(player);
        sharedVault.claim(RELOAD_ACTION, player, address(usdc), amount, periodStart, periodEnd, nonce, deadline, signature);

        assertEq(usdc.balanceOf(player), amount);
    }

    function testSharedVaultRejectsUnsupportedAction() public {
        uint256 amount = 80e6;
        uint256 periodStart = 1_717_372_800;
        uint256 periodEnd = periodStart + 1 weeks;
        uint256 nonce = 12;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 unsupportedAction = keccak256(bytes("VIP_UNKNOWN_CLAIM"));

        sharedVault.fundRewards(address(usdc), 1_000e6);

        bytes memory signature = _signClaim(
            address(sharedVault),
            unsupportedAction,
            player,
            address(usdc),
            amount,
            periodStart,
            periodEnd,
            nonce,
            deadline
        );

        vm.expectRevert(abi.encodeWithSelector(UNSUPPORTED_ACTION_SELECTOR, unsupportedAction));
        vm.prank(player);
        sharedVault.claim(unsupportedAction, player, address(usdc), amount, periodStart, periodEnd, nonce, deadline, signature);
    }

    function testRejectsNonceReuse() public {
        uint256 amount = 100e6;
        uint256 periodStart = 1_717_372_800;
        uint256 periodEnd = periodStart + 1 weeks;
        uint256 nonce = 9;
        uint256 deadline = block.timestamp + 1 hours;

        weeklyVault.fundRewards(address(usdc), 1_000e6);

        bytes memory signature = _signClaim(
            address(weeklyVault),
            keccak256(bytes("VIP_WEEKLY_CLAIM")),
            player,
            address(usdc),
            amount,
            periodStart,
            periodEnd,
            nonce,
            deadline
        );

        vm.prank(player);
        weeklyVault.claim(WEEKLY_ACTION, player, address(usdc), amount, periodStart, periodEnd, nonce, deadline, signature);

        vm.expectRevert(abi.encodeWithSelector(NONCE_ALREADY_USED_SELECTOR, nonce));
        vm.prank(player);
        weeklyVault.claim(WEEKLY_ACTION, player, address(usdc), amount, periodStart, periodEnd, nonce, deadline, signature);
    }

    function testReloadVaultRejectsWeeklyAction() public {
        uint256 amount = 80e6;
        uint256 periodStart = 1_717_372_800;
        uint256 periodEnd = periodStart + 1 weeks;
        uint256 nonce = 12;
        uint256 deadline = block.timestamp + 1 hours;

        reloadVault.fundRewards(address(usdc), 1_000e6);

        bytes memory signature = _signClaim(
            address(reloadVault),
            keccak256(bytes("VIP_WEEKLY_CLAIM")),
            player,
            address(usdc),
            amount,
            periodStart,
            periodEnd,
            nonce,
            deadline
        );

        vm.expectRevert(abi.encodeWithSelector(UNSUPPORTED_ACTION_SELECTOR, WEEKLY_ACTION));
        vm.prank(player);
        reloadVault.claim(WEEKLY_ACTION, player, address(usdc), amount, periodStart, periodEnd, nonce, deadline, signature);
    }

    function testOwnerCanEmergencyWithdrawERC20() public {
        uint256 funded = 1_000e6;
        uint256 amount = 275e6;
        address recipient = makeAddr("emergencyRecipient");

        weeklyVault.fundRewards(address(usdc), funded);
        weeklyVault.emergencyWithdraw(address(usdc), amount, recipient);

        assertEq(usdc.balanceOf(recipient), amount);
        assertEq(usdc.balanceOf(address(weeklyVault)), funded - amount);
    }

    function testOwnerCanEmergencyWithdrawEth() public {
        uint256 funded = 5 ether;
        uint256 amount = 1.75 ether;
        address recipient = makeAddr("ethEmergencyRecipient");

        weeklyVault.fundRewards{value: funded}(address(0), funded);
        weeklyVault.emergencyWithdraw(address(0), amount, recipient);

        assertEq(recipient.balance, amount);
        assertEq(address(weeklyVault).balance, funded - amount);
    }

    function testNonOwnerCannotEmergencyWithdraw() public {
        uint256 amount = 100e6;

        weeklyVault.fundRewards(address(usdc), 500e6);

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(player);
        weeklyVault.emergencyWithdraw(address(usdc), amount, player);
    }

    function _signClaim(
        address vault,
        bytes32 action,
        address claimPlayer,
        address token,
        uint256 amount,
        uint256 periodStart,
        uint256 periodEnd,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                vault,
                block.chainid,
                action,
                claimPlayer,
                token,
                amount,
                periodStart,
                periodEnd,
                nonce,
                deadline
            )
        );

        bytes32 ethSignedDigest = digest.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(backendPk, ethSignedDigest);
        return abi.encodePacked(r, s, v);
    }
}
