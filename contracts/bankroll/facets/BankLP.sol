// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {WithStorage} from "../libraries/LibStorage.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import '../../treasury/Treasury.sol';

interface IToken is IERC20 {
    function mint(uint256 amount) external;
    function setGovernor(address _governor, bool _value) external;
    function canMint(address sender) external view returns (bool);
    function mintDaily() external;
}

/**
 * @title BankrollFacet, Contract responsible for keeping the bankroll and distribute payouts
 */

contract BankLP is WithStorage {
    using SafeERC20 for IERC20;

    address public owner;

    mapping(address => bool) internal suspended;
    mapping(address => uint256) internal suspendedAt;

    mapping(address => uint256) public playRewards;
    mapping(address => uint256) public fees;

    Treasury public treasury;

    address public playRewardToken = 0xD9bDD5f7FA4B52A2F583864A3934DC7233af2d09;
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

    event Bankroll_Player_Suspended(address playerAddress, uint256 suspensionTime, bool isSuspended);

    event Bankroll_Player_Rewards_Claimed(address playerAddress, uint256 claimedAmount);

    event Bankroll_Player_Rewards_Earned(address playerAddress, uint256 rewardedAmount);

    event Bankroll_Player_Rewards_Multiplier_Updated(uint256 percentage);

    error InvalidGameAddress();
    error TransferFailed();

    modifier onlyOwner() {
        require(msg.sender == owner, "Not an owner");
        _;
    }

    modifier onlyGame() {
        require(gs().isGame[msg.sender], 'Caller is not a game');
        _;
    }

    constructor(address _treasury) {
        owner = msg.sender;

        treasury = Treasury(payable(_treasury));
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

    function setPlayRewardToken(address _token) external onlyOwner {
        playRewardToken = _token;
    }

    function setRewardMultiplier(uint256 _reward) external onlyOwner {
        playReward = _reward;
        emit Bankroll_Player_Rewards_Multiplier_Updated(_reward);
    }

    function getPlayerReward() external view returns (uint256) {
        return playReward;
    }

    function getPlayerRewards() external view returns (uint256) {
        return playRewards[msg.sender];
    }

    function claimRewards() external {
        uint256 rewards = playRewards[msg.sender];
        require(rewards > minRewardPayout, 'not enough rewards acquired');

        // update token rewards prior to transfer, against re-entrancy
        playRewards[msg.sender] = 0;

        IToken(playRewardToken).mint(rewards);
        IToken(playRewardToken).transfer(msg.sender, rewards);


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
            IERC20(tokenAddress).transfer(player, payout);
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
                IERC20(gs().wrappedToken).transfer(player, payout);

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

    // receive ether
    receive() external payable {
        uint256 amountAfterFee = msg.value * 98 / 100;
        uint256 fee = msg.value - amountAfterFee;

        fees[address(0)] += fee;
        payable(address(treasury)).call{ value: fee };
    }

    fallback() external payable {}

    /// @notice Execute a single function call.
    /// @param to Address of the contract to execute.
    /// @param value Value to send to the contract.
    /// @param data Data to send to the contract.
    /// @return success_ Boolean indicating if the execution was successful.
    /// @return result_ Bytes containing the result of the execution.
    function execute(address to, uint256 value, bytes calldata data)
        external
        onlyOwner
        returns (bool, bytes memory)
    {
        (bool success, bytes memory result) = to.call{value: value}(data);
        return (success, result);
    }


    function deposit(address token, uint256 amount) external {
        uint256 amountAfterFee = amount * 98 / 100;
        uint256 fee = amount - amountAfterFee;

        fees[token] += fee;
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        IERC20(token).approve(address(treasury), fee);

        // 2% to treasury, where 50% of fee should be rebated for play2earn rewards
        treasury.deposit(token, fee);
    }
}
