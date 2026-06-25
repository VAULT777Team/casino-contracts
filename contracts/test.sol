// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Test {
    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Only the owner can call this function");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setOwner(address newOwner) public onlyOwner() {
        owner = newOwner;
    }

    function getOwner() public view returns (address) {
        return owner;
    }

    function addPlayerReward(address player, uint256 amount) external {}
    function minRewardPayout() external view returns (uint256) {}
    function getPlayerReward() external view returns (uint256) {}
    function claimRewards() external {}
    function playRewards(address) external view returns (uint256) {}
    function getPlayerRewards() external view returns (uint256) {}

    function setGame(address, bool) external {}
    function getIsGame(address game) external view returns (bool) {}

    function deposit(address token, uint256 amount) external {}
    function setTokenAddress(address, bool) external {}
    function setWrappedAddress(address) external {}

    function getIsValidWager(address game, address tokenAddress) external view returns (bool) {}

    function transferPayout(address player, uint256 payout, address token) external {}

    function isPlayerSuspended(address player) external view returns (bool, uint256) {}
}
