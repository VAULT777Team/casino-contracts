// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {CasinoAccount} from "./CasinoAccount.sol";

/**
 * @title AccountFactory
 * @dev Factory contract for deploying new account contracts.
 */
interface IAccountFactory {
    function createAccount(address owner, uint256 salt) external returns (address);
}

contract AccountFactory is IAccountFactory {
    address immutable public entryPoint;
    event AccountCreated(address indexed owner, address account, uint256 salt);

    mapping(address => address) internal accounts;

    constructor(address _entryPoint) {
        entryPoint = _entryPoint;
    }

    function createAccount(address owner, uint256 salt) external override returns (address) {
        address accountAddress = address(
            new CasinoAccount{salt: bytes32(salt)}(entryPoint, owner)
        );

        accounts[owner] = accountAddress;

        emit AccountCreated(owner, accountAddress, salt);
        return accountAddress;
    }

    function getAccount(address owner) external view returns (address) {
        return accounts[owner];
    }

}