// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {BankrollRegistry} from "../bankroll/BankrollRegistry.sol";
import { Client } from "@chainlink-ccip/libraries/Client.sol";
import { IRouterClient } from "@chainlink-ccip/interfaces/IRouterClient.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title CrossChainBankForwarder
 * @notice Immutable forwarder that forwards cross chain messages and tokens to bankrolls
 * @dev 
    NOT IN A STATE FOR PRODUCTION USE

    The forwarder is designed to be used with Chainlink CCIP to send messages across chains.
    It uses an immutable BankrollRegistry to resolve bankroll addresses on different chains.
    It supports paying fees in either native currency or LINK tokens.
    This contract should NEVER be upgraded - it's the permanent historical record of cross-chain calls
 */
contract CrossChainBankForwarder {
    using SafeERC20 for IERC20;
    
    enum PayFeesIn {
        Native,
        LINK
    }
    
    BankrollRegistry registry;

    address immutable I_ROUTER;
    address immutable I_LINK;

    event MessageSent(bytes32 messageId);
    
    constructor(BankrollRegistry _registry, address _router, address _link) {
        registry = _registry;
        I_ROUTER = _router;
        I_LINK = _link;
    }

    receive() external payable {}


    function send(uint64 destinationChainSelector, string memory messageText, PayFeesIn payFeesIn)
        external
        returns (bytes32 messageId)
    {
        Client.EVM2AnyMessage memory message = _buildCCIPMessage(
            registry.getBankrollReceiverOnChain(destinationChainSelector),
            bytes(messageText),
            _transferToken(address(0), 0)
        );
        
        uint256 fee = IRouterClient(I_ROUTER).getFee(destinationChainSelector, message);

        if (payFeesIn == PayFeesIn.LINK) {
            IERC20(I_LINK).approve(I_ROUTER, fee);
            messageId = IRouterClient(I_ROUTER).ccipSend(destinationChainSelector, message);
        } else {
            messageId = IRouterClient(I_ROUTER).ccipSend{value: fee}(destinationChainSelector, message);
        }

        emit MessageSent(messageId);
    }

    function sendWithToken(
        uint64 destinationChainSelector,
        string memory messageText,
        address token,
        uint256 amount,
        PayFeesIn payFeesIn
    ) external returns (bytes32 messageId) {
        require(token != address(0), "Invalid token");
        require(amount > 0, "Invalid amount");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        Client.EVM2AnyMessage memory message = _buildCCIPMessage(
            registry.getBankrollReceiverOnChain(destinationChainSelector),
            bytes(messageText),
            _transferToken(token, amount)
        );

        uint256 fee = IRouterClient(I_ROUTER).getFee(destinationChainSelector, message);

        if (token == I_LINK && payFeesIn == PayFeesIn.LINK) {
            IERC20(I_LINK).safeApprove(I_ROUTER, 0);
            IERC20(I_LINK).safeApprove(I_ROUTER, fee + amount);
        } else if (payFeesIn == PayFeesIn.LINK) {
            IERC20(I_LINK).safeApprove(I_ROUTER, 0);
            IERC20(I_LINK).safeApprove(I_ROUTER, fee);
            IERC20(token).safeApprove(I_ROUTER, 0);
            IERC20(token).safeApprove(I_ROUTER, amount);
        } else {
            IERC20(token).safeApprove(I_ROUTER, 0);
            IERC20(token).safeApprove(I_ROUTER, amount);
        }

        if (payFeesIn == PayFeesIn.LINK) {
            messageId = IRouterClient(I_ROUTER).ccipSend(destinationChainSelector, message);
        } else {
            messageId = IRouterClient(I_ROUTER).ccipSend{value: fee}(destinationChainSelector, message);
        }

        emit MessageSent(messageId);
    }

    function _transferToken(address _token, uint256 _amount) internal pure returns (Client.EVMTokenAmount[] memory tokenAmounts) {
        if (_token == address(0) || _amount == 0) {
            return new Client.EVMTokenAmount[](0);
        }

        tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: _token, amount: _amount});
    }

    function _buildCCIPMessage(
        bytes memory _receiver, 
        bytes memory _data, 
        Client.EVMTokenAmount[] memory _tokenAmounts
    ) internal pure returns (Client.EVM2AnyMessage memory message) {
        message = Client.EVM2AnyMessage({
            receiver: _receiver,
            data: _data,
            tokenAmounts: _tokenAmounts,
            extraArgs: Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: 200_000, allowOutOfOrderExecution: true})),
            feeToken: address(0)
        });
    }
}