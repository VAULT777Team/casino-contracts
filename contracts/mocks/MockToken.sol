// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

contract MockToken is ERC20("Test Token", "TT") {

    address public owner;

    mapping(address => bool)        internal governors;
    mapping(address => bool)        internal whitelisted;
    mapping(address => uint256)     internal minted;

    modifier onlyWhitelisted(address _to) {
        require(whitelisted[_to], 'Not whitelisted');
        _;
    }

    modifier onlyGovernor {
        require(governors[msg.sender], 'Not a Governor');
        _;
    }

    constructor() {
        governors[msg.sender] = true;
    }

    function setWhitelisted(address _whitelisted, bool _value) external onlyGovernor {
        whitelisted[_whitelisted] = _value;
    }

    function setGovernor(address _governor, bool _value) external onlyGovernor {
        governors[_governor] = _value;
    }

    function mint(uint256 amount) external onlyGovernor {
        _mint(msg.sender, amount);
    }

    function mintDaily() external {
        uint256 amount      = 10_000 * 10**18;
        uint256 timestamp   = block.timestamp;

        require(minted[msg.sender] < timestamp, "Already minted daily");

        minted[msg.sender] = timestamp + 1 days;

        _mint(msg.sender, amount);
    }

    function canMint(address sender) public view returns (bool){
        if(minted[sender] < block.timestamp) return true;
        return false;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual override onlyWhitelisted(to) returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
        return true;
    }

    function transfer(address to, uint256 amount) public virtual override onlyWhitelisted(to) returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, amount);
        return true;
    }
}
