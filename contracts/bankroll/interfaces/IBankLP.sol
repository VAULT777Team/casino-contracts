// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

/**
 * @dev Interface for the Bankroll Liquidity Provider (BankLP) contract.
 * This interface defines the functions required for managing the bankroll,
 * handling deposits and withdrawals, and distributing payouts to participants.
 * It is intended to be used by the BankrollFacet contract, which is responsible
 * for maintaining the bankroll and ensuring fair and secure payout distribution.
 */
interface IBankLP {

    function fundBankroll(address token, uint256 amount) external returns (bool);
    function withdrawBankroll(address to, address token, uint256 amount) external returns (bool);

    function getOwner() external view returns (address);
    function execute(address to, uint256 value, bytes calldata data) external returns (bool, bytes memory);

    function addPlayerReward(
        address player,
        uint256 amount
    ) external;

    function minRewardPayout()      external view returns (uint256);
    function getPlayerReward()      external view returns (uint256);
    function claimRewards()         external;
    function playRewards(address)   external view returns (uint256);
    function getPlayerRewards()     external view returns (uint256);

    function setGame(address, bool) external;
    function getIsGame(address game) external view returns (bool);

    function depositEther() external payable returns (bool);
    function deposit(address token, uint256 amount) external;
    
    function setTokenAddress(address, bool) external;
    function setWrappedAddress(address)     external;

    function getIsValidWager(
        address game,
        address tokenAddress
    ) external view returns (bool);

    function transferPayout(
        address player,
        uint256 payout,
        address token
    ) external;

    function isPlayerSuspended(
        address player
    ) external view returns (bool, uint256);

    // reserves
    function getAvailableBalance(address token) external view returns (uint256);
    function reservedFunds(address token) external view returns (uint256);

    function reserveFunds(
        address token, 
        uint256 amount
    ) external;

    function releaseFunds(
        address token,
        uint256 amount
    ) external;

}
