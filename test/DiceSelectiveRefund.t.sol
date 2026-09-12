// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BankLP} from "../contracts/bankroll/facets/BankLP.sol";
import {Treasury} from "../contracts/treasury/Treasury.sol";
import {Dice} from "../contracts/games/Dice.sol";
import {VRFConfig} from "../contracts/Common.sol";

contract SelectiveRefundVRFMock {
    uint256 public nextRequestID = 1;

    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata) external returns (uint256 requestID) {
        requestID = nextRequestID++;
    }

    function fulfillWithGas(address consumer, uint256 requestID, uint256[] calldata randomWords, uint256 callbackGas)
        external
        returns (bool success)
    {
        (success,) = consumer.call{gas: callbackGas}(
            abi.encodeWithSignature("rawFulfillRandomWords(uint256,uint256[])", requestID, randomWords)
        );
    }
}

contract SelectiveRefundFeeManagerMock {
    function quoteVRFFee(address, uint32, uint32, uint256, uint256) external pure returns (uint256) {
        return 0;
    }
}

contract SelectiveRefundRegistryMock {
    address public immutable bankroll;

    constructor(address _bankroll) {
        bankroll = _bankroll;
    }

    function getCurrentBankroll() external view returns (address, address, string memory, uint256) {
        return (bankroll, address(0), "test", block.timestamp);
    }
}

contract SelectiveRefundWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}

contract SelectiveRefundPlayer {
    Dice internal immutable dice;
    address internal immutable bankroll;
    uint256 internal rejectBelow;

    constructor(address dice_, address bankroll_) {
        dice = Dice(dice_);
        bankroll = bankroll_;
    }

    function play(uint256 wager, uint32 count) external {
        uint256 totalWager = wager * count;
        rejectBelow = totalWager;
        dice.Dice_Play{value: totalWager}(
            wager, 10_421, address(0), false, count, uint256(type(int256).max), uint256(type(int256).max)
        );
    }

    function refund() external {
        dice.Dice_Refund();
    }

    receive() external payable {
        if (msg.sender == bankroll && msg.value < rejectBelow) {
            assembly {
                for {} 1 {} {}
            }
        }
    }
}

contract DiceSelectiveRefundTest is Test {
    uint256 internal constant WAGER = 1e12;
    uint32 internal constant BETS = 100;
    uint256 internal constant TOTAL_WAGER = WAGER * BETS;

    Dice internal dice;
    BankLP internal bankroll;
    SelectiveRefundVRFMock internal coordinator;
    SelectiveRefundWETH internal weth;

    function setUp() public {
        Treasury treasury = new Treasury();
        bankroll = new BankLP(address(treasury), address(0), address(0));
        weth = new SelectiveRefundWETH();
        bankroll.setWrappedAddress(address(weth));
        bankroll.setTokenAddress(address(0), true);

        coordinator = new SelectiveRefundVRFMock();
        SelectiveRefundFeeManagerMock feeManager = new SelectiveRefundFeeManagerMock();
        SelectiveRefundRegistryMock registry = new SelectiveRefundRegistryMock(address(bankroll));

        VRFConfig memory vrf = VRFConfig({
            coordinator: address(coordinator),
            keyHash: bytes32(0),
            subId: 1,
            reqConfirmations: 1,
            callbackGasLimit: 1_000_000,
            feeManager: address(feeManager)
        });

        dice = new Dice(address(registry), vrf, 20);
        bankroll.setGame(address(dice), true);
        vm.deal(address(bankroll), 10 ether);
    }

    function testGasBombCannotRevertLosingFulfillmentAndClaimRefund() public {
        SelectiveRefundPlayer player = new SelectiveRefundPlayer(address(dice), address(bankroll));
        vm.deal(address(player), 1 ether);

        uint256 playerNativeBefore = address(player).balance;
        player.play(WAGER, BETS);
        uint256 requestID = dice.Dice_GetState(address(player)).requestID;

        uint256[] memory randomWords = _wordsWithWins(95);
        bool fulfilled = coordinator.fulfillWithGas(address(dice), requestID, randomWords, 1_000_000);

        assertTrue(fulfilled, "gas-bomb recipient must not revert settlement");
        assertEq(dice.Dice_GetState(address(player)).requestID, 0, "settled request must be cleared");

        uint256 expectedPayout = ((WAGER * 10_421) / 10_000) * 95;
        assertEq(address(player).balance, playerNativeBefore - TOTAL_WAGER);
        assertEq(weth.balanceOf(address(player)), expectedPayout);

        vm.roll(block.number + 20);
        vm.expectRevert(Dice.NotAwaitingVRF.selector);
        player.refund();
    }

    function _wordsWithWins(uint256 wins) internal pure returns (uint256[] memory randomWords) {
        randomWords = new uint256[](BETS);
        for (uint256 i = wins; i < BETS; ++i) {
            randomWords[i] = 9_700_000;
        }
    }
}
