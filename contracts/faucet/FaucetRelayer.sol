// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./Faucet.sol";

/**
 * @title FaucetRelayer
 * @dev A contract that relays meta-transactions to the Faucet contract
 * This allows users without ETH to request funds by signing messages off-chain
 */
contract FaucetRelayer is Ownable {
    using ECDSA for bytes32;

    Faucet public faucet;
    
    mapping(address => mapping(uint256 => bool)) public usedNonces;
    
    event MetaTransactionExecuted(address indexed user, address indexed relayer, uint256 nonce);
    
    /**
     * @dev Constructor sets the faucet address and owner
     * @param _faucetAddress The address of the Faucet contract
     */
    constructor(address payable _faucetAddress) {
        faucet = Faucet(_faucetAddress);
    }
    
    /**
     * @dev Execute a meta-transaction to request funds from the faucet
     * @param userAddress The address of the user requesting funds
     * @param nonce A unique nonce to prevent replay attacks
     * @param signature The signature of the user
     */
    function executeMetaTransaction(
        address userAddress,
        uint256 nonce,
        bytes memory signature
    ) external {
        require(!usedNonces[userAddress][nonce], "Nonce already used");
        
        // Verify the signature
        bytes32 messageHash = getMessageHash(userAddress, nonce);
        bytes32 ethSignedMessageHash = getEthSignedMessageHash(messageHash);
        require(recover(ethSignedMessageHash, signature) == userAddress, "Invalid signature");
        
        // Mark the nonce as used
        usedNonces[userAddress][nonce] = true;
        
        // Call the faucet contract on behalf of the user
        // The relayer (msg.sender) pays for the gas
        faucet.requestFundsFor(userAddress);
        
        // Emit event
        emit MetaTransactionExecuted(userAddress, msg.sender, nonce);
    }
    
    /**
     * @dev Get the message hash for signing
     * @param userAddress The address of the user
     * @param nonce The nonce
     * @return The message hash
     */
    function getMessageHash(
        address userAddress,
        uint256 nonce
    ) public view returns (bytes32) {
        return keccak256(abi.encodePacked(userAddress, nonce, address(this)));
    }
    
    /**
     * @dev Get the Ethereum signed message hash
     * @param messageHash The message hash
     * @return The Ethereum signed message hash
     */
    function getEthSignedMessageHash(bytes32 messageHash) public pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
    }
    
    /**
     * @dev Recover the signer address from a signature
     * @param ethSignedMessageHash The Ethereum signed message hash
     * @param signature The signature
     * @return The signer address
     */
    function recover(bytes32 ethSignedMessageHash, bytes memory signature) public pure returns (address) {
        return ethSignedMessageHash.recover(signature);
    }
    
    /**
     * @dev Fund the relayer with ETH
     */
    receive() external payable {}
}