// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "@pythnetwork/entropy-sdk-solidity/IEntropy.sol";
import "@pythnetwork/entropy-sdk-solidity/IEntropyConsumer.sol";

contract VRFConsumer is IEntropyConsumer {
    event RandomnessRequested(uint64 sequenceNumber, bytes32 userRandomNumber);
    event RandomnessFulfilled(uint64 sequenceNumber, bytes32 randomNumber);
    
    struct EntropyRequest {
        address requester;
        bool fulfilled;
        bytes32 randomNumber;
        uint256 timestamp;
    }
    
    // Pyth Entropy contract address for Arbitrum
    // Note: Replace with actual deployed address when available
    IEntropy public entropy;
    
    // Default provider for entropy on Arbitrum
    address public defaultProvider;
    
    // Request tracking
    mapping(uint64 => EntropyRequest) public requests;
    uint64[] public requestIds;
    uint64 public latestRequestId;
    
    // Fee for entropy requests
    uint256 public entropyFee;
    
    constructor(address _entropyContract, address _defaultProvider) {
        entropy = IEntropy(_entropyContract);
        defaultProvider = _defaultProvider;
        
        // Get the fee for entropy requests
        //entropyFee = entropy.getFee(defaultProvider);
    }
    
    /**
     * @notice Required by IEntropyConsumer - returns the entropy contract address
     */
    function getEntropy() internal view override returns (address) {
        return address(entropy);
    }
    
    /**
     * @notice Request randomness from Pyth Network
     * @param userRandomNumber User-provided random number for additional entropy
     * @return sequenceNumber The sequence number for this request
     */
    function requestRandomness(bytes32 userRandomNumber) external payable returns (uint64) {
        // Check if enough fee is provided
        require(msg.value >= entropyFee, "Insufficient fee for entropy request");
        
        // Request random number from Pyth Entropy
        uint64 sequenceNumber = entropy.requestWithCallback{value: entropyFee}(
            defaultProvider,
            userRandomNumber
        );
        
        // Store request information
        requests[sequenceNumber] = EntropyRequest({
            requester: msg.sender,
            fulfilled: false,
            randomNumber: bytes32(0),
            timestamp: block.timestamp
        });
        
        requestIds.push(sequenceNumber);
        latestRequestId = sequenceNumber;
        
        emit RandomnessRequested(sequenceNumber, userRandomNumber);
        
        // Refund excess payment
        if (msg.value > entropyFee) {
            payable(msg.sender).transfer(msg.value - entropyFee);
        }
        
        return sequenceNumber;
    }
    
    function entropyCallback(
        uint64 sequenceNumber,
        address provider,
        bytes32 randomNumber
    ) internal override {
        // Combine user and provider randomness
        bytes32 finalRandomNumber = keccak256(abi.encodePacked(sequenceNumber, randomNumber));
        
        // Update request status
        requests[sequenceNumber].fulfilled = true;
        requests[sequenceNumber].randomNumber = finalRandomNumber;
        
        emit RandomnessFulfilled(sequenceNumber, finalRandomNumber);
        
        // Call the derived contract's callback if implemented
        _onRandomnessFulfilled(sequenceNumber, finalRandomNumber);
    }
    
    /**
     * @notice Virtual function to be overridden by derived contracts
     * @param sequenceNumber The sequence number of the fulfilled request
     * @param randomNumber The generated random number
     */
    function _onRandomnessFulfilled(uint64 sequenceNumber, bytes32 randomNumber) internal virtual {
        // Override this function in derived contracts to handle randomness
    }
    
    /**
     * @notice Get the status and result of a randomness request
     * @param sequenceNumber The sequence number of the request
     * @return fulfilled Whether the request has been fulfilled
     * @return randomNumber The generated random number (0 if not fulfilled)
     * @return requester The address that made the request
     */
    function getRequestStatus(uint64 sequenceNumber) 
        external 
        view 
        returns (bool fulfilled, bytes32 randomNumber, address requester) 
    {
        EntropyRequest memory request = requests[sequenceNumber];
        return (request.fulfilled, request.randomNumber, request.requester);
    }
    
    /**
     * @notice Get a random number in a specific range
     * @param sequenceNumber The sequence number of the fulfilled request
     * @param max The maximum value (exclusive)
     * @return randomValue Random number between 0 and max-1
     */
    function getRandomInRange(uint64 sequenceNumber, uint256 max) external view returns (uint256) {
        require(requests[sequenceNumber].fulfilled, "Request not fulfilled");
        require(max > 0, "Max must be greater than 0");
        
        bytes32 randomNumber = requests[sequenceNumber].randomNumber;
        return uint256(randomNumber) % max;
    }
    
    /**
     * @notice Get multiple random numbers from a single request
     * @param sequenceNumber The sequence number of the fulfilled request
     * @param count Number of random numbers to generate
     * @return randomNumbers Array of random numbers
     */
    function getMultipleRandom(uint64 sequenceNumber, uint256 count) 
        external 
        view 
        returns (uint256[] memory randomNumbers) 
    {
        require(requests[sequenceNumber].fulfilled, "Request not fulfilled");
        require(count > 0, "Count must be greater than 0");
        
        randomNumbers = new uint256[](count);
        bytes32 baseRandom = requests[sequenceNumber].randomNumber;
        
        for (uint256 i = 0; i < count; i++) {
            randomNumbers[i] = uint256(keccak256(abi.encodePacked(baseRandom, i)));
        }
        
        return randomNumbers;
    }
    
    /**
     * @notice Update the entropy fee (call this periodically to get current fee)
     */
    function updateEntropyFee() external {
        entropyFee = entropy.getFee(defaultProvider);
    }
    
    /**
     * @notice Get the current entropy fee
     */
    function getCurrentFee() external view returns (uint256) {
        return entropy.getFee(defaultProvider);
    }
    
    /**
     * @notice Change the default entropy provider
     * @param newProvider Address of the new provider
     */
    function setDefaultProvider(address newProvider) external {
        // Add access control as needed
        defaultProvider = newProvider;
        entropyFee = entropy.getFee(newProvider);
    }
    
    /**
     * @notice Emergency function to withdraw contract balance
     */
    function withdraw() external {
        // Add proper access control (onlyOwner, etc.)
        payable(msg.sender).transfer(address(this).balance);
    }
    
    /**
     * @notice Get the address of the entropy contract
     */
    function getEntropyContract() external view returns (address) {
        return address(entropy);
    }
    
    /**
     * @notice Get all request IDs for a specific requester
     * @param requester The address to get requests for
     * @return userRequestIds Array of request IDs made by the requester
     */
    function getRequestsForUser(address requester) external view returns (uint64[] memory userRequestIds) {
        uint256 count = 0;
        
        // Count requests by user
        for (uint256 i = 0; i < requestIds.length; i++) {
            if (requests[requestIds[i]].requester == requester) {
                count++;
            }
        }
        
        // Create array and populate
        userRequestIds = new uint64[](count);
        uint256 index = 0;
        
        for (uint256 i = 0; i < requestIds.length; i++) {
            if (requests[requestIds[i]].requester == requester) {
                userRequestIds[index] = requestIds[i];
                index++;
            }
        }
        
        return userRequestIds;
    }
    
    // Allow contract to receive ETH
    receive() external payable {}
}
