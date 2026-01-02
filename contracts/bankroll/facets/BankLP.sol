// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {WithStorage} from "../libraries/LibStorage.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Treasury } from '../../treasury/Treasury.sol';
import {GameFactory} from "../../sdk/GameFactory.sol";

import {IBankrollRegistry} from "../interfaces/IBankrollRegistry.sol";

interface IToken is IERC20 {
    function mint(uint256 amount) external;
    function setGovernor(address _governor, bool _value) external;
    function canMint(address sender) external view returns (bool);
    function mintDaily() external;
}


contract BankLP is WithStorage {
    using SafeERC20 for IERC20;

    address public owner;
    address public registry; // Immutable registry for historical tracking

    mapping(address => bool) internal suspended;
    mapping(address => uint256) internal suspendedAt;

    mapping(address => uint256) public playRewards;
    mapping(address => uint256) public fees;

    mapping(address => uint256) public reservedFunds;

    // Game creator fee share (basis points, e.g. 500 = 5%)
    mapping(address => uint256) public creatorFeeBps;
    mapping(address => address) public gameCreator;

    // Core contracts
    Treasury public treasury;
    GameFactory public factory;
    address public liquidityPool;

    // play2earn
    address public playRewardToken;
    uint256 public minRewardPayout = 10 * 10**18; // 10 min playback payout
    uint256 public playReward = 300; // 3% playback earnings

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

    modifier onlyGameFactoryOrOwner() {
        _onlyGameFactoryOrOwner();
        _;
    }

    function _onlyGameFactoryOrOwner() internal view {
        require(
            msg.sender == address(factory) || msg.sender == owner,
            "Not game factory or owner"
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
        address _registry, 
        address _factory
    ) {
        owner = msg.sender;
        treasury = Treasury(payable(_treasury));
        registry = _registry;
        factory = GameFactory(_factory);
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
        treasury = Treasury(payable(_treasury));
    }

    function setLiquidityPool(address _liquidityPool) external onlyOwner {
        liquidityPool = _liquidityPool;
    }

    function setPlayRewardToken(address _token) external onlyOwner {
        playRewardToken = _token;
    }

    function setRewardMultiplier(uint256 _reward) external onlyOwner {
        playReward = _reward;
        emit Bankroll_Player_Rewards_Multiplier_Updated(_reward);
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
        require(available >= amount, "Insufficien available balance to reserve");
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

    // playRewards
    function getPlayerReward() external view returns (uint256) {
        return playReward;
    }

    function getPlayerRewards() external view returns (uint256) {
        return playRewards[msg.sender];
    }

    function claimRewards() external {
        uint256 rewards = playRewards[msg.sender];
        require(rewards > minRewardPayout, 'not enough rewards acquired');
        require(playRewardToken != address(0), 'no reward token set');

        // update token rewards prior to transfer, against re-entrancy
        playRewards[msg.sender] = 0;

        IToken(playRewardToken).mint(rewards);
        bool transferred = IToken(playRewardToken).transfer(msg.sender, rewards);
        require(transferred, "IERC20: Transfer failed");


        emit Bankroll_Player_Rewards_Claimed(msg.sender, rewards);
    }

    function addPlayerReward(address player, uint256 amount) external onlyGame {
        playRewards[player] += amount;
        emit Bankroll_Player_Rewards_Earned(player, amount);
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
            (bool success, ) = payable(player).call{value: payout, gas: 2400}(
                ""
            );
            if (!success) {
                (bool _success, ) = gs().wrappedToken.call{value: payout}(
                    abi.encodeWithSignature("deposit()")
                );
                if (!_success) {
                    revert();
                }

                bool transferred = IERC20(gs().wrappedToken).transfer(player, payout);
                require(transferred, "IERC20: Transfer failed");

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
     * Deposit ETH from game contract to subtract fee
    */
    function depositEther() external payable returns (bool) {
        bool success;
        uint256 amount = msg.value;
        uint256 amountAfterFee = amount * 98 / 100;
        uint256 fee = amount - amountAfterFee;

        fees[address(0)] += fee;

        // Fee sharing logic
        address game = msg.sender;
        uint256 creatorShare = 0;
        address creator = gameCreator[game];
        uint256 creatorBps = creatorFeeBps[game];
        if (creator != address(0) && creatorBps > 0) {
            creatorShare = (fee * creatorBps) / 10000;
            if (creatorShare > 0) {
                (success, ) = payable(creator).call{ value: creatorShare }("");
                require(success, "Creator ETH transfer failed");
            }
        }
        
        // 2nd half of fee to treasury, rest into liquidity pool
        uint256 treasuryFee = (fee - creatorShare) / 2;
        
        (success, ) = payable(address(treasury)).call{ value: treasuryFee }("");
        require(success, "Treasury transfer failed");

        emit Bankroll_Received_Player_Deposit(address(0), amountAfterFee);
        emit Bankroll_Treasury_Deposit(address(0), treasuryFee);

        if (creatorShare > 0) {
            emit CreatorFeePaid(game, creator, creatorShare, address(0));
        }

        return success;
    }

    event CreatorFeePaid(address indexed game, address indexed creator, uint256 amount, address token);
    
    /*
     * Deposit ERC20 from game contract to subtract fee
    */
    function deposit(address token, uint256 amount) external {
        uint256 amountAfterFee = amount * 98 / 100;
        uint256 fee = amount - amountAfterFee;

        fees[token] += fee;
        bool transferred = IERC20(token).transferFrom(msg.sender, address(this), amount);
        require(transferred, "IERC20: Transfer failed");

        // Fee sharing logic
        address game = msg.sender;
        uint256 creatorShare = 0;
        address creator = gameCreator[game];
        uint256 creatorBps = creatorFeeBps[game];
        if (creator != address(0) && creatorBps > 0) {
            creatorShare = (fee * creatorBps) / 10000;
            if (creatorShare > 0) {
                (bool success) = IERC20(token).transfer(creator, creatorShare);
                require(success, "Creator token transfer failed");
            }
        }
        
        // 2nd half of fee to treasury, rest back into LP
        uint256 treasuryFee = (fee - creatorShare) / 2;

        IERC20(token).approve(address(treasury), treasuryFee);
        treasury.deposit(token, treasuryFee);

        emit Bankroll_Received_Player_Deposit(token, amountAfterFee);
        emit Bankroll_Treasury_Deposit(token, treasuryFee);

        if (creatorShare > 0) {
            emit CreatorFeePaid(game, creator, creatorShare, token);
        }
    }

    // Called by factory/owner to set creator and fee share for a game
    function setGameCreator(address game, address creator, uint256 feeBps) external onlyGameFactoryOrOwner {
        require(feeBps <= 2000, "Fee too high"); // Max 20%
        gameCreator[game] = creator;
        creatorFeeBps[game] = feeBps;
    }
}
