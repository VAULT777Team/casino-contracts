// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {BankrollRegistry} from "../bankroll/BankrollRegistry.sol";
import { Client } from "@chainlink-ccip/libraries/Client.sol";
import { IRouterClient } from "@chainlink-ccip/interfaces/IRouterClient.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title CrossChainBankForwarder
 * @notice Immutable forwarder that forwards cross chain messages and tokens to bankrolls
 * @dev This contract should NEVER be upgraded - it's the permanent historical record of cross-chain calls
 */
contract CrossChainBankForwarder {
    
    enum PayFeesIn {
        Native,
        LINK
    }
    
    BankrollRegistry registry;

    address immutable i_router;
    address immutable i_link;

    event MessageSent(bytes32 messageId);
    
    constructor(BankrollRegistry _registry, address _router, address _link) {
        registry = _registry;
        i_router = _router;
        i_link = _link;
    }

    receive() external payable {}


    function send(uint64 destinationChainSelector, string memory messageText, PayFeesIn payFeesIn)
        external
        returns (bytes32 messageId)
    {
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: address(registry).code,
            data: abi.encode(messageText),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: 200_000, allowOutOfOrderExecution: true})),
            feeToken: payFeesIn == PayFeesIn.LINK ? i_link : address(0)
        });

        uint256 fee = IRouterClient(i_router).getFee(destinationChainSelector, message);

        if (payFeesIn == PayFeesIn.LINK) {
            IERC20(i_link).approve(i_router, fee);
            messageId = IRouterClient(i_router).ccipSend(destinationChainSelector, message);
        } else {
            messageId = IRouterClient(i_router).ccipSend{value: fee}(destinationChainSelector, message);
        }

        emit MessageSent(messageId);
    }
}