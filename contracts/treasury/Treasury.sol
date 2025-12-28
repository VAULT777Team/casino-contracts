pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Treasury {
    address public owner;

    event TreasuryDeposit(address sender, address token, uint256 amount);
    event TreasuryWithdrawal(address sender, address recipient, address token, uint256 amount);

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function _onlyOwner() internal view {
        require(msg.sender == owner, "Not an owner");
    }

    // receive ether
    receive() external payable {
        emit TreasuryDeposit(msg.sender, address(0), msg.value);
    }
    fallback() external payable {
        emit TreasuryDeposit(msg.sender, address(0), msg.value);
    }

    function setOwner(address _owner) external onlyOwner {
        require(_owner != address(0), "Can not set to zero address");
        owner = _owner;
    }

    function deposit(address token, uint256 amount) external {
        bool transferred = IERC20(token).transferFrom(msg.sender, address(this), amount);
        require(transferred, "IERC20: Transfer failed.");

        emit TreasuryDeposit(msg.sender, token, amount);

    }

    function withdraw(address recipient, address token) external onlyOwner {
        uint256 balance = 0;
        if(token == address(0)){
            balance = address(this).balance;
            require(balance > 0.0001 ether, 'Not enough native tokens');
            (bool success, ) = payable(recipient).call{value: balance}("");
            require(success, "Failed to transfer ETH");
        } else {
            balance = IERC20(token).balanceOf(address(this));
            require(balance > 0, 'Not enough fees acrued');

            (bool success) = IERC20(token).transfer(recipient, balance);
            require(success, "Failed to transfer ERC20 tokens");
        }

        emit TreasuryWithdrawal(msg.sender, recipient, token, balance);
    }

    /// @notice Execute a single function call.
    /// @param to Address of the contract to execute.
    /// @param value Value to send to the contract.
    /// @param data Data to send to the contract.
    /// @return success_ Boolean indicating if the execution was successful.
    /// @return result_ Bytes containing the result of the execution.
    function execute(address to, uint256 value, bytes calldata data)
        external
        onlyOwner
        returns (bool, bytes memory)
    {
        (bool success, bytes memory result) = to.call{value: value}(data);
        return (success, result);
    }
}