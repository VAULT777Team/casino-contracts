// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BatchNativeFunder} from "../contracts/BatchNativeFunder.sol";

contract RejectNativeFunding {
    receive() external payable {
        revert("REJECTED");
    }
}

contract BatchNativeFunderTest is Test {
    BatchNativeFunder internal funder;

    address payable internal first = payable(address(0x1001));
    address payable internal second = payable(address(0x1002));
    address payable internal third = payable(address(0x1003));

    function setUp() public {
        funder = new BatchNativeFunder();
        vm.deal(address(this), 100 ether);
    }

    function testSplitsNativeValueAndDistributesRemainder() public {
        address payable[] memory recipients = _threeRecipients();

        funder.splitNative{value: 10 wei}(recipients);

        assertEq(first.balance, 4 wei);
        assertEq(second.balance, 3 wei);
        assertEq(third.balance, 3 wei);
        assertEq(address(funder).balance, 0);
    }

    function testFundsExplicitAmounts() public {
        address payable[] memory recipients = _threeRecipients();
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;
        amounts[2] = 3 ether;

        funder.fundNative{value: 6 ether}(recipients, amounts);

        assertEq(first.balance, 1 ether);
        assertEq(second.balance, 2 ether);
        assertEq(third.balance, 3 ether);
        assertEq(address(funder).balance, 0);
    }

    function testRejectsInvalidRecipientsAndAmounts() public {
        address payable[] memory recipients = new address payable[](2);
        recipients[0] = first;
        recipients[1] = first;

        vm.expectRevert(abi.encodeWithSelector(BatchNativeFunder.DuplicateRecipient.selector, first));
        funder.splitNative{value: 2 wei}(recipients);

        recipients[1] = second;
        uint256[] memory amounts = new uint256[](1);
        vm.expectRevert(BatchNativeFunder.LengthMismatch.selector);
        funder.fundNative{value: 1 wei}(recipients, amounts);

        amounts = new uint256[](2);
        amounts[0] = 1 wei;
        amounts[1] = 2 wei;
        vm.expectRevert(abi.encodeWithSelector(BatchNativeFunder.IncorrectValue.selector, 3 wei, 2 wei));
        funder.fundNative{value: 2 wei}(recipients, amounts);
    }

    function testRevertsEntireBatchWhenRecipientRejectsNative() public {
        RejectNativeFunding rejecting = new RejectNativeFunding();
        address payable[] memory recipients = new address payable[](3);
        recipients[0] = first;
        recipients[1] = payable(address(rejecting));
        recipients[2] = third;

        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNativeFunder.NativeTransferFailed.selector,
                1,
                address(rejecting),
                1 ether
            )
        );
        funder.splitNative{value: 3 ether}(recipients);

        assertEq(first.balance, 0);
        assertEq(third.balance, 0);
        assertEq(address(funder).balance, 0);
    }

    function _threeRecipients() private view returns (address payable[] memory recipients) {
        recipients = new address payable[](3);
        recipients[0] = first;
        recipients[1] = second;
        recipients[2] = third;
    }
}
