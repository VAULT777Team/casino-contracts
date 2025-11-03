pragma solidity ^0.8.0;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Treasury {
    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not an owner");
        _;
    }

    event TreasuryDeposit(address sender, address token, uint256 amount);
    event TreasuryWithdrawal(address sender, address recipient, address token, uint256 amount);

    constructor() {
        owner = msg.sender;
    }

    // receive ether
    receive() external payable {}
    fallback() external payable {}


    function deposit(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        emit TreasuryDeposit(msg.sender, token, amount);

    }

    function withdraw(address recipient, address token) external onlyOwner {
        uint256 balance = 0;
        if(token == address(0)){
            balance = address(this).balance;
            require(balance > 0.0001 ether, 'Not enough native tokens');
            payable(recipient).call{value: balance};
        } else {
            balance = IERC20(token).balanceOf(address(this));
            require(balance > 0, 'Not enough fees acrued');

            IERC20(token).transfer(recipient, balance);
        }

        emit TreasuryWithdrawal(msg.sender, recipient, token, balance);
    }
}