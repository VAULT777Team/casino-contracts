// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {VaultLP2} from "../contracts/bankroll/facets/VaultLP2.sol";
import {HouseLPToken} from "../contracts/bankroll/facets/VaultLP.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockBankrollRegistryV2 {
    address public bankroll;
    address public treasury;
    string public version;
    uint256 public activatedAt;

    constructor(address _bankroll, address _treasury, string memory _version, uint256 _activatedAt) {
        bankroll = _bankroll;
        treasury = _treasury;
        version = _version;
        activatedAt = _activatedAt;
    }

    function getCurrentBankroll() external view returns (address, address, string memory, uint256) {
        return (bankroll, treasury, version, activatedAt);
    }
}

contract MockBankLPV2 {
    mapping(address => uint256) public balances;

    function fundBankroll(address token, uint256 amount) external returns (bool) {
        if (token == address(0)) {
            return true;
        }

        IERC20(token).transferFrom(msg.sender, address(this), amount);
        balances[token] += amount;
        return true;
    }

    function withdrawBankroll(address to, address token, uint256 amount) external returns (bool) {
        if (token == address(0)) {
            (bool ok, ) = payable(to).call{value: amount}("");
            return ok;
        }

        IERC20(token).transfer(to, amount);
        return true;
    }

    function getAvailableBalance(address token) external view returns (uint256) {
        if (token == address(0)) {
            return address(this).balance;
        }
        return IERC20(token).balanceOf(address(this));
    }

    function reservedFunds(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {
        balances[address(0)] += msg.value;
    }
}

contract MockERC20V2 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract VaultLP2Test is Test {
    VaultLP2 public vault;
    HouseLPToken public lpToken;
    MockBankLPV2 public bankroll;
    MockBankrollRegistryV2 public registry;

    MockERC20V2 public usdc;

    address public owner;
    address public treasury;
    address public operator;
    address public alice;

    uint256 constant INITIAL_BALANCE = 1000 ether;

    function setUp() public {
        owner = address(this);
        treasury = makeAddr("treasury");
        operator = makeAddr("operator");
        alice = makeAddr("alice");

        bankroll = new MockBankLPV2();
        registry = new MockBankrollRegistryV2(address(bankroll), treasury, "test-v2", block.timestamp);
        lpToken = new HouseLPToken();
        vault = new VaultLP2(address(lpToken), address(registry));
        lpToken.setVault(address(vault));

        vault.addPool(address(0), 0);

        usdc = new MockERC20V2("USD Coin", "USDC", 6);

        vm.deal(alice, INITIAL_BALANCE);
    }

    function _depositEthAsAlice(uint256 amount) internal {
        vm.startPrank(alice);
        vault.deposit{value: amount}(address(0), amount);
        vm.stopPrank();
    }

    function testCreateClaimRequestOnlyOutsideClaimWindow() public {
        _depositEthAsAlice(10 ether);

        (uint256 timeUntilNextWindow,,,) = vault.getRemainingLockup();
        skip(timeUntilNextWindow);

        assertTrue(vault.isInWithdrawWindow(), "should be in withdraw window");

        vm.prank(alice);
        vm.expectRevert("Cannot request during claim window");
        vault.createClaimRequest(address(0), 5 ether);
    }

    function testClaimRequestValidForFirstUpcomingWindowAndWithdraw() public {
        _depositEthAsAlice(10 ether);

        vm.prank(alice);
        vault.createClaimRequest(address(0), 6 ether);

        (uint256 reqShares, uint256 windowStart, uint256 windowEnd) = vault.claimRequests(address(0), alice);
        assertEq(reqShares, 6 ether);
        assertGt(windowStart, block.timestamp);
        assertGt(windowEnd, windowStart);

        vm.warp(windowStart + 1);

        vm.prank(alice);
        vault.withdraw(address(0), 6 ether);

        (uint256 remainingShares, , ) = vault.claimRequests(address(0), alice);
        assertEq(remainingShares, 0, "request should be consumed");
    }

    function testMissedClaimWindowGetsSlashedAndFeeSentToTreasury() public {
        _depositEthAsAlice(10 ether);

        vm.prank(alice);
        vault.createClaimRequest(address(0), 10 ether);

        (, , uint256 windowEnd) = vault.claimRequests(address(0), alice);
        vm.warp(windowEnd + 1);

        uint256 treasuryBalanceBefore = treasury.balance;

        vault.slashMissedClaimRequest(address(0), alice);

        // 2% slash of 10e = 0.2e by default
        assertEq(treasury.balance - treasuryBalanceBefore, 0.2 ether);

        (uint256 remainingShares, , ) = vault.claimRequests(address(0), alice);
        assertEq(remainingShares, 0, "request should be cleared");

        (uint256 userShares, , , , ) = vault.userInfo(address(0), alice);
        assertEq(userShares, 9.8 ether, "user shares should be reduced by slash fee");
        assertEq(lpToken.balanceOf(alice), 9.8 ether, "LP balance should be burned by fee shares");
    }

    function testOperatorCanUpdateMissedClaimFee() public {
        vault.setOperator(operator);

        vm.prank(operator);
        vault.setMissedClaimRequestFeeBps(300);

        assertEq(vault.missedClaimRequestFeeBps(), 300);
    }

    function testNonOperatorCannotUpdateMissedClaimFee() public {
        vm.prank(alice);
        vm.expectRevert("Not operator");
        vault.setMissedClaimRequestFeeBps(300);
    }
}
