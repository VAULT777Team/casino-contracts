// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {WithStorage} from "../libraries/LibStorage.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {Treasury } from '../../treasury/Treasury.sol';
import {IBankrollRegistry} from "../interfaces/IBankrollRegistry.sol";

interface IToken is IERC20 {
    function mint(uint256 amount) external;
    function setGovernor(address _governor, bool _value) external;
    function canMint(address sender) external view returns (bool);
    function mintDaily() external;
}


contract BankLP is WithStorage {
    using SafeERC20 for IERC20;

    uint256 public constant NATIVE_PAYOUT_GAS = 30_000;

    address public owner;
    address public registry; // Immutable registry for historical tracking

    mapping(address => bool) internal suspended;
    mapping(address => uint256) internal suspendedAt;

    mapping(address => uint256) public reservedFunds;

    // Core contracts
    address payable public treasury;
    address public liquidityPool;

    /**
     * @dev event emitted when game is Added or Removed
     * @param gameAddress address of game state that changed
     * @param isValid new state of game address
     */
    event BankRoll_Game_State_Changed(address gameAddress, bool isValid);
 
    /**
     * @dev event emitted when token state is changed
     * @param tokenAddress address of token that changed state
     * @param isValid new state of token address
     */
    event Bankroll_Token_State_Changed(address tokenAddress, bool isValid);

    event Bankroll_Player_Suspended(address playerAddress, uint256 suspensionTime, bool isSuspended);

    event Bankroll_Player_Rewards_Claimed(address playerAddress, uint256 claimedAmount);

    event Bankroll_Player_Rewards_Earned(address playerAddress, uint256 rewardedAmount);

    event Bankroll_Player_Rewards_Multiplier_Updated(uint256 percentage);

    /**
     * funding events 
    */

    /**
     * @dev event emitted when max payout percentage is changed
     * @param payout new payout percentage
     */
    event BankRoll_Max_Payout_Changed(uint256 payout);

    /**
     * @dev event emitted when payout is transferred
     * @param gameAddress address of game contract
     * @param playerAddress address of player to transfer to
     * @param payout amount of payout transferred
     */
    event Bankroll_Payout_Transferred(address gameAddress, address playerAddress, uint256 payout);

    event Bankroll_Reserved_Funds_Force_Released(
        address indexed tokenAddress,
        uint256 amount,
        uint256 remainingReservedFunds
    );

    /**
     * @dev event emitted when bankroll receives liquidity
     * @param tokenAddress Address of the funded token
     * @param amount amount of funding
     */
    event Bankroll_Received_Liquidity(address indexed tokenAddress, uint256 amount);
    
    /**
     * @dev event emitted when a player deposit into the bankroll is made
     * @param tokenAddress Address of the deposited token
     * @param amount amount of funding
     */
    event Bankroll_Received_Player_Deposit(address indexed tokenAddress, uint256 amount);
    
    /**
     * @dev event emitted when fees are deposited into treasury
     * @param tokenAddress Address of the token deposited into treasury
     * @param amount Fee deposited in to treasury
     */
    event Bankroll_Treasury_Deposit(address indexed tokenAddress, uint256 amount);

    error InvalidGameAddress();
    error TransferFailed();
    error InvalidTokenStandard(address tokenAddress);

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }
    
    function _onlyOwner() internal view {
        require(msg.sender == owner, "Not an owner");
    }

    modifier onlyRegistryOrOwner() {
        _onlyRegistryOrOwner();
        _;
    }

    function _onlyRegistryOrOwner() internal view {
        require(
            msg.sender == registry || msg.sender == owner,
            "Not bankroll registry or owner"
        );
    }

    modifier onlyLPOrOwner() {
        _onlyLPOrOwner();
        _;
    }

    function _onlyLPOrOwner() internal view {
        require(
            msg.sender == address(liquidityPool) || msg.sender == owner,
            "Not LP or owner"
        );
    }

    modifier onlyGame() {
        _onlyGame();
        _;
    }

    function _onlyGame() internal view {
        require(gs().isGame[msg.sender], 'Caller is not a game');
    }

    constructor(
        address _treasury, 
        address _registry
    ) {
        owner = msg.sender;
        treasury = payable(_treasury);
        registry = _registry;
    }
    
    /**
     * @notice Get the registry address
     */
    function getRegistry() external view returns (address) {
        return registry;
    }
    
    /**
     * @notice Check if this bankroll is the current active one
     */
    function isActiveBankroll() external view returns (bool) {
        if (registry == address(0)) return true; // Legacy bankroll
        
        try IBankrollRegistry(registry).getCurrentBankroll() returns (
            address currentBankroll,
            address,
            string memory,
            uint256
        ) {
            return currentBankroll == address(this);
        } catch {
            return false;
        }
    }

    function setRegistry(address _registry) external onlyOwner {
        registry = _registry;
    }

    function setOwner(address _owner) external onlyOwner {
        owner = _owner;
    }

    function getOwner() external view returns (address) {
        return owner;
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = payable(_treasury);
    }

    function setLiquidityPool(address _liquidityPool) external onlyOwner {
        liquidityPool = _liquidityPool;
    }

    // reserveFunds
    
    /**
     * @dev Get available balance of bankroll
     * @param token Token to get balance of
    */
    function getAvailableBalance(address token) public view returns (uint256) {
        uint256 totalBalance;
        if(token == address(0)){
            totalBalance = address(this).balance;
        } else {
            totalBalance = IERC20(token).balanceOf(address(this));
        }

        uint256 reserved = reservedFunds[token];
        return totalBalance > reserved ? totalBalance - reserved : 0;
    }
    
    /**
     * @dev Reserve funds for a game (called by game contracts)
     * @param token Token to reserve
     * @param amount Amount to reserve
    */
    function reserveFunds(address token, uint256 amount) external onlyGame {
        uint256 available = getAvailableBalance(token);
        require(available >= amount, "Insufficient available balance to reserve");
        reservedFunds[token] += amount;
    }

    /**
     * @dev Release reserved funds after game completes
     * @param token Token to reserve
     * @param amount Amount to reserve
    */
    function releaseFunds(address token, uint256 amount) external onlyGame {
        require(reservedFunds[token] >= amount, "Insufficient reserved funds");
        reservedFunds[token] -= amount;
    }

    /**
     * @dev Emergency accounting repair for orphaned reservations that can no
     * longer be released by the game contract that created them.
     */
    function forceReleaseReservedFunds(address token, uint256 amount) external onlyOwner {
        require(amount > 0, "Invalid release amount");
        require(reservedFunds[token] >= amount, "Insufficient reserved funds");
        reservedFunds[token] -= amount;
        emit Bankroll_Reserved_Funds_Force_Released(token, amount, reservedFunds[token]);
    }

    /**
    * @dev Check if wager is valid considering reserved funds
    * @param game Game Address to check wager against reserve
    * @param tokenAddress ERC20 token to check wager reserves for
    * @param maxPayout Payout to check if enough reserved funds are in place for it
    */
    function getIsValidWagerWithReserve(
        address game,
        address tokenAddress,
        uint256 maxPayout
    ) external view returns (bool) {
        if(!gs().isGame[game]) return false;
        if(!gs().isTokenAllowed[tokenAddress]) return false;
        
        uint256 available = getAvailableBalance(tokenAddress);
        return available >= maxPayout;
    }

    function _decimalsOr18(address token) internal view returns (uint8) {
        if (token == address(0)) return 18;

        // Attempt IERC20Metadata.decimals(); fallback to 18 on non-standard tokens.
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSelector(IERC20Metadata.decimals.selector));
        if (!ok || data.length < 32) return 18;
        return uint8(uint256(bytes32(data)));
    }

    function _scaleDecimals(uint256 amount, uint8 fromDecimals, uint8 toDecimals) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) return amount;
        if (fromDecimals < toDecimals) {
            return amount * (10 ** uint256(toDecimals - fromDecimals));
        }
        return amount / (10 ** uint256(fromDecimals - toDecimals));
    }

    /**
     * @dev Function to enable or disable games to distribute bankroll payouts
     * @param game contract address of game to change state
     * @param isValid state to set the address to
     */
    function setGame(address game, bool isValid) external onlyOwner {
        gs().isGame[game] = isValid;
        emit BankRoll_Game_State_Changed(game, isValid);
    }

    /**
     * @dev function to get if game is allowed to access the bankroll
     * @param game address of the game contract
     */
    function getIsGame(address game) external view returns (bool) {
        return (gs().isGame[game]);
    }

    /**
     * @dev function to check if a token is valid for given game
     * @param game address of the game
     * @param tokenAddress address of the wagered token to validate
     */
    function getIsValidWager(
        address game,
        address tokenAddress
    ) external view returns (bool) {
        if(!gs().isGame[game]) return false;
        if(!gs().isTokenAllowed[tokenAddress]) return false;
        return true;
    }

    /**
     * @dev function to set if a given token can be wagered
     * @param tokenAddress address of the token to set address
     * @param isValid state to set the address to
     */
    function setTokenAddress(
        address tokenAddress,
        bool isValid
    ) external onlyOwner {
        _setTokenAddress(tokenAddress, isValid);
    }

    function _setTokenAddress(
        address tokenAddress,
        bool isValid
    ) internal {
        gs().isTokenAllowed[tokenAddress] = isValid;
        emit Bankroll_Token_State_Changed(tokenAddress, isValid);
    }

    /**
     * @dev function to set the wrapped token contract of the native asset
     * @param wrapped address of the wrapped token contract
     */
    function setWrappedAddress(address wrapped) external onlyOwner {
        gs().wrappedToken = wrapped;
    }

        /**
     * @dev function that games call to transfer payout
     * @param player address of the player to transfer payout to
     * @param payout amount of payout to transfer
     * @param tokenAddress address of the token to transfer, 0 address is the native token
     */
    function transferPayout(
        address player,
        uint256 payout,
        address tokenAddress
    ) external {
        if (!gs().isGame[msg.sender]) {
            revert InvalidGameAddress();
        }
        if (tokenAddress != address(0)) {
            bool transferred = IERC20(tokenAddress).transfer(player, payout);
            require(transferred, "ERC20: Transfer failed");
        } else {
            (bool success, ) = payable(player).call{value: payout, gas: NATIVE_PAYOUT_GAS}("");
            if (!success) {
                address wrappedToken = gs().wrappedToken;
                if (wrappedToken == address(0)) {
                    revert InvalidTokenStandard(wrappedToken);
                }

                (bool _success, ) = wrappedToken.call{value: payout}(abi.encodeWithSignature("deposit()"));
                if (!_success) {
                    revert TransferFailed();
                }

                IERC20(wrappedToken).safeTransfer(player, payout);
            }
        }

        emit Bankroll_Payout_Transferred(msg.sender, player, payout);
    }

    error AlreadySuspended(uint256 suspensionTime);
    error TimeRemaingOnSuspension(uint256 suspensionTime);

    /**
     * @dev Suspend player by a certain amount time. This function can only be used if the player is not suspended since it could be used to lower suspension time.
     * @param suspensionTime Time to be suspended for in seconds.
     */
    function suspend(uint256 suspensionTime) external {
        if (gs().suspendedTime[msg.sender] > block.timestamp) {
            revert AlreadySuspended(gs().suspendedTime[msg.sender]);
        }
        gs().suspendedTime[msg.sender] = block.timestamp + suspensionTime;
        gs().isPlayerSuspended[msg.sender] = true;

        emit Bankroll_Player_Suspended(
            msg.sender,
            gs().suspendedTime[msg.sender],
            true
        );
    }

    /**
     * @dev Increse suspension time of a player by a certain amount of time. This function is intended to only be used as a complement to the suspend() function to increase suspension time.
     * @param suspensionTime Time to increase suspension time for in seconds.
     */
    function increaseSuspensionTime(uint256 suspensionTime) external {
        gs().suspendedTime[msg.sender] += suspensionTime;
        gs().isPlayerSuspended[msg.sender] = true;
        
        emit Bankroll_Player_Suspended(
            msg.sender,
            gs().suspendedTime[msg.sender],
            true
        );
    }

    /**
     * @dev Permantly suspend player. This function sets suspension time to the maximum allowed time.
     */
    function permantlyBan() external {
        gs().suspendedTime[msg.sender] = 2 ** 256 - 1;
        gs().isPlayerSuspended[msg.sender] = true;

        emit Bankroll_Player_Suspended(
            msg.sender,
            gs().suspendedTime[msg.sender],
            true
        );
    }

    /**
     * @dev Lift suspension after the required amount of time has passed
     */
    function liftSuspension() external {
        if (gs().suspendedTime[msg.sender] > block.timestamp) {
            revert TimeRemaingOnSuspension(gs().suspendedTime[msg.sender]);
        }
        gs().isPlayerSuspended[msg.sender] = false;

        emit Bankroll_Player_Suspended(
            msg.sender,
            gs().suspendedTime[msg.sender],
            false
        );
    }

    /**
     * @dev Function to view player suspension status.
     * @param player Address of the
     * @return bool is player suspended
     * @return uint256 time that unlock period ends
     */
    function isPlayerSuspended(
        address player
    ) external view returns (bool, uint256) {
        return (gs().isPlayerSuspended[player], gs().suspendedTime[player]);
    }

    event Executed(address indexed to, uint256 value, bytes data);

    /// @notice Execute a single function call.
    /// @param to Address of the contract to execute.
    /// @param value Value to send to the contract.
    /// @param data Data to send to the contract.
    /// @return success_ Boolean indicating if the execution was successful.
    /// @return result_ Bytes containing the result of the execution.
    function execute(address to, uint256 value, bytes calldata data)
        external
        onlyRegistryOrOwner
        returns (bool, bytes memory)
    {
        (bool success, bytes memory result) = to.call{value: value}(data);
        emit Executed(to, value, data);
        return (success, result);
    }

    // receive ether direct funding no fee
    receive() external payable {
        emit Bankroll_Received_Liquidity(address(0), msg.value);
    }

    /**
    * @dev Fund bankroll with ERC20 tokens directly (no fee)
    * @param token Address of the ERC20 token
    * @param amount Amount to fund
    */
    function fundBankroll(address token, uint256 amount) external returns (bool) {
        require(token != address(0), "Use receive() for ETH funding");
        
        bool transferred = IERC20(token).transferFrom(msg.sender, address(this), amount);
        require(transferred, "ERC20: transfer failed");

        emit Bankroll_Received_Liquidity(token, amount);
        return transferred;
    }

    event Bankroll_Withdrew_Liquidity(address indexed tokenAddress, uint256 amount);

    /**
    * @dev Withdraw liquidity from bankroll (only LP or owner)
    * @param recipient Address to send withdrawn funds to
    * @param token Address of the token to withdraw (address(0) for ETH)
    * @param amount Amount to withdraw
    */
    function withdrawBankroll(address recipient, address token, uint256 amount) external onlyLPOrOwner returns (bool) {
        bool transferred;
        if (token == address(0)) {
            require(reservedFunds[address(0)] + amount <= address(this).balance, "Insufficient available ETH balance");
            (transferred, ) = payable(recipient).call{value: amount}("");
            require(transferred, "ETH transfer failed");

            emit Bankroll_Withdrew_Liquidity(address(0), amount);
        } else {
            require(reservedFunds[token] + amount <= IERC20(token).balanceOf(address(this)), "Insufficient available token balance");
            transferred = IERC20(token).transfer(recipient, amount);
            require(transferred, "ERC20: transfer failed");
            emit Bankroll_Withdrew_Liquidity(token, amount);
        }

        return transferred;
    }

    /*
     * @dev Deposit ETH from game contract
    */
    function depositEther() external payable returns (bool) {
        emit Bankroll_Received_Player_Deposit(address(0), msg.value);
        return true;
    }
    
    /**
     * @dev Deposit ERC20 from game contract
     * @param token Address of the ERC20 token
     * @param amount Amount to deposit
    */
    function deposit(address token, uint256 amount) external {
        bool transferred = IERC20(token).transferFrom(msg.sender, address(this), amount);
        require(transferred, "IERC20: Transfer failed");

        emit Bankroll_Received_Player_Deposit(token, amount);
    }
}
