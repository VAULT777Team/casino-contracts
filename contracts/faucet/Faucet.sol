// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Faucet
 * @dev A faucet contract that dispenses ETH and 777 tokens
 */
contract Faucet is Ownable {
    IERC20 public token;
    
    uint256 public ethAmount = 0.01 ether;
    uint256 public tokenAmount = 10000 * 10**18; // 10000 777 with 18 decimals
    
    uint256 public cooldownPeriod = 24 hours;
    
    mapping(address => uint256) public lastRequestTime;
    
    event FundsDispensed(address indexed recipient, uint256 ethAmount, uint256 tokenAmount);
    event TokenUpdated(address indexed oldToken, address indexed newToken);

    bool public ercEnabled;
    bool public ethEnabled;
    
    /**
     * @dev Constructor sets the token address and owner
     * @param _tokenAddress The address of the 777 token contract
     */
    constructor(address _tokenAddress, bool _ercEnabled, bool _ethEnabled) {
        token = IERC20(_tokenAddress);
        ercEnabled = _ercEnabled;
        ethEnabled = _ethEnabled;
    }

    function setEnabledERC(bool _ercEnabled) external onlyOwner {
        ercEnabled = _ercEnabled;
    }
    function setEnabledEth(bool _ethEnabled) external onlyOwner {
        ethEnabled = _ethEnabled;
    }
        
    /**
     * @dev Request ETH and tokens from the faucet
     */
    function requestFunds() external {
        _requestFunds(msg.sender);
    }

    /**
     * @dev Request funds for a specific address (can only be called by authorized relayers)
     * @param recipient The address to receive the funds
     */
    function requestFundsFor(address recipient) external {
        require(authorizedRelayers[msg.sender], "Not an authorized relayer");
        _requestFunds(recipient);
    }

    /**
     * @dev Internal function to handle fund requests
     * @param recipient The address to receive the funds
     */
    function _requestFunds(address recipient) internal {
        require(
            block.timestamp >= lastRequestTime[recipient] + cooldownPeriod || lastRequestTime[recipient] == 0,
            "Cooldown period not over"
        );
        
        require(address(this).balance >= ethAmount, "Insufficient ETH in faucet");

        lastRequestTime[recipient] = block.timestamp;
        
        (bool sent, ) = recipient.call{value: ethAmount}("");
        require(sent, "Failed to send ETH");

        if(ercEnabled){
            require(token.balanceOf(address(this)) >= tokenAmount, "Insufficient tokens in faucet");
            require(token.transfer(recipient, tokenAmount), "Failed to transfer tokens");
        }
        
        // Emit event
        emit FundsDispensed(recipient, ethAmount, tokenAmount);
    }
    
    /**
     * @dev Allow the owner to fund the contract with ETH
     */
    function fundWithEth() external payable {
        // No additional logic needed, just accept the ETH
    }
    
    /**
     * @dev Allow the owner to withdraw ETH in case of emergency
     * @param amount The amount of ETH to withdraw
     */
    function withdrawEth(uint256 amount) external onlyOwner {
        require(address(this).balance >= amount, "Insufficient ETH in contract");
        (bool sent, ) = owner().call{value: amount}("");
        require(sent, "Failed to send ETH");
    }
    
    mapping(address => bool) public authorizedRelayers;
    event RelayerStatusChanged(address indexed relayer, bool isAuthorized);

    /**
     * @dev Add or remove an authorized relayer
     * @param relayer The address of the relayer
     * @param isAuthorized Whether the relayer is authorized
     */
    function setRelayerStatus(address relayer, bool isAuthorized) external onlyOwner {
        authorizedRelayers[relayer] = isAuthorized;
        emit RelayerStatusChanged(relayer, isAuthorized);
    }
    
    /**
     * @dev Update the token amount to be dispensed
     * @param _tokenAmount The new token amount
     */
    function setTokenAmount(uint256 _tokenAmount) external onlyOwner {
        tokenAmount = _tokenAmount;
    }
    
    /**
     * @dev Allow the owner to deposit tokens to the faucet
     * @param amount The amount of tokens to deposit
     */
    function depositTokens(uint256 amount) external {
        require(token.transferFrom(msg.sender, address(this), amount), "Token transfer failed");
    }
    
    /**
     * @dev Update the cooldown period
     * @param _cooldownPeriod The new cooldown period in seconds
     */
    function setCooldownPeriod(uint256 _cooldownPeriod) external onlyOwner {
        cooldownPeriod = _cooldownPeriod;
    }
    
    /**
     * @dev Update the token address (allows changing to a different ERC20 token)
     * @param _tokenAddress The new token contract address
     */
    function setTokenAddress(address _tokenAddress) external onlyOwner {
        require(_tokenAddress != address(0), "Token address cannot be zero");
        address oldToken = address(token);
        token = IERC20(_tokenAddress);
        emit TokenUpdated(oldToken, _tokenAddress);
    }
    
    /**
     * @dev Get the current token address
     * @return The address of the current token contract
     */
    function getTokenAddress() external view returns (address) {
        return address(token);
    }
    
    /**
     * @dev Fallback function to accept ETH
     */
    receive() external payable {}
}