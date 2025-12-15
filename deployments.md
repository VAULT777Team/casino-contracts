# Casino Contracts Documentation

## Overview
This documentation covers the deployed casino smart contracts on the blockchain, including core infrastructure contracts and game implementations.

## Deployed Contract Addresses

### Core Infrastructure

#### mainnet
treasury: 0xa640068Ad560a72E1058f6B5c3ABc0AEFD04758e
BankLP: 0xdD16142ecE5d21F0141c9a6D5BdF39aFc7632ac2
USD/ETH feed (pyth aggregatorV3): 0xb6eD8B232EC1766D65748BeD4d2714089cbb54D9

VRF: 0x3C0Ca683b403E37668AE3DC4FB62F4B29B6f7a3e
forwarder: 0xd1217489b92d4D9179b31FEDCf459C6cC9Ba528a

  Core Infrastructure:
    BankLP:           0xdD16142ecE5d21F0141c9a6D5BdF39aFc7632ac2
    VRF:              0x3C0Ca683b403E37668AE3DC4FB62F4B29B6f7a3e
    LINK/ETH Feed:    0xb6eD8B232EC1766D65748BeD4d2714089cbb54D9
    Forwarder:        0xd1217489b92d4D9179b31FEDCf459C6cC9Ba528a
  
  Game Contracts:
    CoinFlip:         0x4898c4C044d06A49881aB40A74d6c9e88d613C7E
    Dice:             0x65D65E4e3f16617852DAe3B115eaF1eEdeD24500
    VideoPoker:       0x2d669Af48D406c4917f8f78A06EAEa0a450D113e
    Blackjack:        0x39fd417F6f1c5B22Cc8950CACBa9f23B1e092e19
    Plinko:           0x4c938b9041A4270b88362Aab7FaC5ad791e05D78
    Slots:            0x11683055212A41f94e34D3E7F397E4eb9Bd3213b
    Mines:            0xa69eAdc916b40B80cd6ad4dAf9a841FCda53eA6c
    Keno:             0xE25e16fCB636dCB7b7DF29Cb31D363622E0744C5
    RockPaperScissors: 0x70e6D4ce7CF0a6835F51F6D5043E4BB5C8aC2d05
    AmericanRoulette: 0xf0a1266a1c5b1a3B6DbDAEE6d37F5F21C5cB4a13
    EuropeanRoulette: 0x5366960FfC8D5f77E1C1C0B9185bf85Db0BF63CA

#### sepolia

| Contract | Address | Description |
|----------|---------|-------------|
| VRF (Chainlink VRF Coordinator) | `0x5CE8D5A2BC84beb22a398CCA51996F7930313D61` | Chainlink VRF V2+ coordinator for generating verifiable random numbers |
| LINK/ETH Price Feed | `0x5BBd5163c48c4bc9ec808Be651c2DBBe9B1E0e99` | Chainlink price feed for LINK/ETH conversion (used for VRF fee calculation) |
| Forwarder | `0x5e13E5216E3531EF1a1652d1a13CAa889D02eA91` | Trusted forwarder for meta-transactions (gasless transactions) |
| BankLP | `0x2340C509f65e28D031a9a9207bDEE919a31B5A99` | Bankroll contract managing funds, payouts, and play-to-earn rewards |

### Game Contracts

| Game | Address | Description |
|------|---------|-------------|
| American Roulette | `0x47702495254a0867a662Ad0c6AB7Db543A250c7A` | American Roulette (00 wheel) with various bet types |
| Coin Flip | `0x73baB7199a218Dca595a83F9d0847b1Cc3ccc2Ea` | Simple heads or tails prediction game |
| Dice | `0xd16D10D3003c1C1E2d2c8544262ea425b4e191be` | Over/under dice game with configurable multipliers |
| Plinko | `0x2a51fEb6666ed236cb91D5AbaC364F86926C18c0` | Plinko board game with adjustable rows and risk levels |
| Video Poker | `0xCF15bd5a5FBfd2505ed54D20e26F55C5D43475A9` | 5-card draw poker with card replacement |

---

## Contract Specifications

## 1. BankLP (Bankroll)

**Address:** `0x2340C509f65e28D031a9a9207bDEE919a31B5A99`

### Purpose
The BankLP contract is the core bankroll management system that:
- Holds all wagers and distributes payouts to players
- Manages play-to-earn reward system
- Controls game and token whitelisting
- Handles player self-suspension features
- Collects 2% deposit fees for the treasury

### Key Features

#### Play-to-Earn Rewards
- **Reward Token:** `0xD9bDD5f7FA4B52A2F583864A3934DC7233af2d09`
- **Reward Multiplier:** 3% (300 basis points) of wagered amount
- **Minimum Payout:** 10 tokens
- Players accumulate rewards with each wager and can claim when threshold is met

#### Deposit System
- Accepts both native tokens (ETH) and ERC20 tokens
- 2% fee on all deposits → sent to treasury
- Deposits can be made via `receive()` for native tokens or `deposit()` for ERC20s

#### Self-Suspension System
Players can voluntarily suspend themselves from playing:
- `suspend(uint256 time)` - Set suspension period
- `increaseSuspensionTime(uint256 time)` - Extend existing suspension
- `permantlyBan()` - Permanent self-exclusion
- `liftSuspension()` - Remove suspension after time expires

### Main Functions

```solidity
function deposit(address token, uint256 amount) external
function claimRewards() external
function transferPayout(address player, uint256 payout, address tokenAddress) external
function suspend(uint256 suspensionTime) external
function isPlayerSuspended(address player) external view returns (bool, uint256)
```

### Events
- `Bankroll_Payout_Transferred` - Emitted when payout sent to player
- `Bankroll_Player_Rewards_Claimed` - Emitted when rewards claimed
- `Bankroll_Player_Rewards_Earned` - Emitted when rewards accrued
- `Bankroll_Player_Suspended` - Emitted when suspension status changes

---

## 2. Common Base Contract

All game contracts inherit from the `Common` abstract contract, which provides:

### VRF Integration
- **VRF Subscription ID:** `77667707628007624636163514136218109527264531590891917311719822980101224786380`
- **Key Hash:** `0x1770bdc7eec7771f7ba4ffd640f34260d7f095b79c92d34a5b2551d6f6cfd2be`
- **Request Confirmations:** 3 blocks
- **Callback Gas Limit:** 2,500,000 gas

### Core Functionality
- Wager validation and transfer
- VRF fee calculation using LINK/ETH price feed
- Play-to-earn reward allocation (3% of wager)
- Excess value refund mechanism
- Player suspension checks

### Fee Calculation
VRF fees are dynamically calculated based on:
- Current gas price
- L1 gas costs (for L2 chains like Arbitrum)
- LINK/ETH exchange rate
- Game-specific gas requirements

---

## 3. Coin Flip

**Address:** `0x73baB7199a218Dca595a83F9d0847b1Cc3ccc2Ea`

### Game Description
Players predict whether a coin will land on heads or tails.

### Betting Parameters
- **Payout:** 1.98x (98% of 2x due to house edge)
- **Max Bets per Round:** 100
- **Predictions:** Heads (true) or Tails (false)

### Game Flow
1. Player calls `CoinFlip_Play()` with wager, prediction, and batch settings
2. VRF request initiated
3. Random numbers generated for each bet in batch
4. Results processed with stop-gain/stop-loss logic
5. Payout automatically sent to player

### Stop-Gain/Stop-Loss
- **Stop Gain:** Betting stops if cumulative profit reaches this amount
- **Stop Loss:** Betting stops if cumulative loss reaches this amount
- Unused bets are refunded automatically

### Functions

```solidity
function CoinFlip_Play(
    uint256 wager,
    address tokenAddress,
    bool isHeads,
    uint32 numBets,
    uint256 stopGain,
    uint256 stopLoss
) external payable nonReentrant

function CoinFlip_Refund() external nonReentrant
function CoinFlip_GetState(address player) external view returns (CoinFlipGame memory)
```

### Events
- `CoinFlip_Play_Event` - Game started
- `CoinFlip_Outcome_Event` - Results and payouts
- `CoinFlip_Refund_Event` - Refund processed

---

## 4. Dice

**Address:** `0xd16D10D3003c1C1E2d2c8544262ea425b4e191be`

### Game Description
Players bet whether a dice roll (0-9999) will be over or under a selected number, with adjustable multipliers.

### Betting Parameters
- **Multiplier Range:** 1.0421x to 990x (10,421 to 9,900,000 in basis points)
- **Roll Range:** 0-9999
- **Max Bets per Round:** 100
- **Bet Types:** Over or Under

### Multiplier Mechanics
Higher multipliers = lower win probability:
- `1.0421x` ≈ 95% win chance
- `2x` = 49.5% win chance  
- `990x` ≈ 0.1% win chance

### Functions

```solidity
function Dice_Play(
    uint256 wager,
    uint32 multiplier,
    address tokenAddress,
    bool isOver,
    uint32 numBets,
    uint256 stopGain,
    uint256 stopLoss
) external payable nonReentrant

function Dice_Refund() external nonReentrant
function Dice_GetState(address player) external view returns (DiceGame memory)
```

### Events
- `Dice_Play_Event` - Game started with multiplier
- `Dice_Outcome_Event` - Roll results and payouts
- `Dice_Refund_Event` - Refund processed

---

## 5. Plinko

**Address:** `0x2a51fEb6666ed236cb91D5AbaC364F86926C18c0`

### Game Description
A Plinko board where a ball drops through pegs, with payouts based on final position. Players select rows and risk level.

### Game Configuration
- **Rows:** 8-16 rows selectable
- **Risk Levels:** Low (0), Medium (1), High (2)
- **Max Bets per Round:** 100
- **Multipliers:** Vary by configuration (set per row/risk combination)

### Risk Levels
- **Low:** More consistent, moderate payouts
- **Medium:** Balanced risk/reward
- **High:** Extreme variance, highest max multiplier

### Functions

```solidity
function Plinko_Play(
    uint256 wager,
    address tokenAddress,
    uint8 numRows,
    uint8 risk,
    uint32 numBets,
    uint256 stopGain,
    uint256 stopLoss
) external payable nonReentrant

function Plinko_Refund() external nonReentrant
function Plinko_GetState(address player) external view returns (PlinkoGame memory)
```

### Events
- `Plinko_Play_Event` - Game started with rows/risk
- `Plinko_Outcome_Event` - Ball paths and payouts
- `Plinko_Refund_Event` - Refund processed

---

## 6. Video Poker

**Address:** `0xCF15bd5a5FBfd2505ed54D20e26F55C5D43475A9`

### Game Description
Classic 5-card draw poker. Players receive 5 cards, select which to keep, and draw replacements.

### Game Flow
1. `VideoPoker_Start()` - Receive initial 5-card hand
2. Player decides which cards to replace
3. `VideoPoker_Draw()` - Replace selected cards
4. Winning hands automatically paid based on poker rankings

### Payout Table
Standard video poker payouts (multipliers vary by hand):
- Royal Flush
- Straight Flush
- Four of a Kind
- Full House
- Flush
- Straight
- Three of a Kind
- Two Pair
- Jacks or Better

### Functions

```solidity
function VideoPoker_Start(
    uint256 wager,
    address tokenAddress
) external payable nonReentrant

function VideoPoker_Draw(bool[5] calldata toReplace) external payable nonReentrant
function VideoPoker_Refund() external nonReentrant
function VideoPoker_GetState(address player) external view returns (VideoPokerGame memory)
```

### Events
- `VideoPoker_Play_Event` - Game started
- `VideoPoker_Start_Event` - Initial hand dealt
- `VideoPoker_Outcome_Event` - Final hand and payout
- `VideoPoker_Refund_Event` - Refund processed

---

## 7. American Roulette

**Address:** `0x47702495254a0867a662Ad0c6AB7Db543A250c7A`

### Game Description
American Roulette featuring the 00 wheel (38 positions: 0, 00, 1-36).

### Bet Types

| Bet Type | Description | Payout | Example |
|----------|-------------|--------|---------|
| STRAIGHT | Single number (0-36, or 37 for 00) | 35:1 | Bet on "17" |
| RED | Red numbers | 1:1 | 18 red numbers |
| BLACK | Black numbers | 1:1 | 18 black numbers |
| ODD | Odd numbers | 1:1 | 1,3,5...35 |
| EVEN | Even numbers | 1:1 | 2,4,6...36 |
| LOW | Numbers 1-18 | 1:1 | First half |
| HIGH | Numbers 19-36 | 1:1 | Second half |
| DOZEN | 12-number group | 2:1 | 1st/2nd/3rd dozen |
| COLUMN | Column bet | 2:1 | Column 1/2/3 |

### Betting Parameters
- **Max Bets per Round:** 200
- **betValue:** Used for STRAIGHT, DOZEN, and COLUMN bets
  - STRAIGHT: 0-37 (37 = 00)
  - DOZEN/COLUMN: 1, 2, or 3

### Functions

```solidity
function Roulette_Play(
    uint256 wager,
    address tokenAddress,
    BetType betType,
    uint32 betValue,
    uint32 numBets,
    uint256 stopGain,
    uint256 stopLoss
) external payable nonReentrant

function Roulette_Refund() external nonReentrant
function Roulette_GetState(address player) external view returns (RouletteGame memory)
```

### Events
- `Roulette_Play_Event` - Bet placed with type/value
- `Roulette_Outcome_Event` - Spin results and payouts
- `Roulette_Refund_Event` - Refund processed

---

## Security Features

### Player Protection
1. **Self-Suspension:** Players can voluntarily suspend their accounts
2. **Refund Mechanism:** If VRF fails to respond within 200 blocks, players can claim refunds
3. **Reentrancy Guards:** All external functions protected against reentrancy attacks
4. **Stop-Gain/Stop-Loss:** Automatic bet termination to manage risk

### Access Control
- Game contracts must be whitelisted by BankLP owner
- Token addresses must be approved for wagering
- Only approved games can trigger bankroll payouts

### VRF Security
- Uses Chainlink VRF V2+ for provably fair random numbers
- 3 block confirmations required
- Unique request IDs prevent replay attacks
- On-chain verification of randomness

---

## Integration Guide

### For Players

#### Playing a Game
1. Approve token spending (for ERC20 tokens) or send native ETH
2. Call game's play function with parameters
3. Pay VRF fee (calculated dynamically)
4. Wait for VRF callback (~3 blocks)
5. Receive automatic payout to wallet

#### Claiming Rewards
```solidity
// Check accumulated rewards
uint256 rewards = BankLP.getPlayerRewards();

// Claim rewards (must have > 10 tokens)
BankLP.claimRewards();
```

#### Self-Suspension
```solidity
// Suspend for 30 days
BankLP.suspend(30 days);

// Check suspension status
(bool suspended, uint256 suspendedUntil) = BankLP.isPlayerSuspended(playerAddress);
```

### For Developers

#### Supported Tokens
Games support:
- Native token (address(0))
- Approved ERC20 tokens (must be whitelisted in BankLP)

#### VRF Fee Estimation
```solidity
uint256 fee = game.getVRFFee(gasAmount, l1Multiplier);
```

#### State Queries
Each game provides a `GetState()` function:
```solidity
CoinFlipGame memory gameState = CoinFlip.CoinFlip_GetState(playerAddress);
```

---

## Important Notes

### Gas Considerations
- L1 gas fees included in VRF fee calculation (optimized for L2s like Arbitrum)
- Excess ETH automatically refunded to player
- Batch betting reduces per-bet gas costs

### House Edge
- Most games: ~2% house edge
- Payout multipliers account for house edge
- Example: Coin flip pays 1.98x instead of 2x

### Limitations
- Maximum bets per round vary by game (100-200)
- Cannot start new game while awaiting VRF response
- Suspended players cannot place bets

### Best Practices
1. Always check game state before playing
2. Set reasonable stop-gain/stop-loss limits
3. Ensure sufficient balance for wager + VRF fee
4. Use refund function if VRF times out (>200 blocks)

---

## Technical Architecture

### Contract Inheritance
```
VRFConsumerBaseV2Plus
        ↓
    Common (abstract)
        ↓
┌───────┴───────┬─────────┬──────────┬─────────┐
│               │         │          │         │
CoinFlip    Dice    Plinko   VideoPoker   Roulette
```

### Key Dependencies
- **OpenZeppelin:** SafeERC20, ReentrancyGuard
- **Chainlink:** VRFCoordinatorV2Plus, Price Feeds
- **Custom:** ChainSpecificUtil (L2 gas calculations)

---

## Changelog & Versions

### Current Version
- All contracts use Solidity ^0.8.0
- Chainlink VRF V2+ implementation
- Meta-transaction support via Forwarder
- Play-to-earn rewards system active

---

## Support & Resources

### Contract Verification
All contracts should be verified on block explorer for transparency.

### Audits
Ensure contracts are audited before mainnet deployment. Key areas:
- VRF randomness implementation
- Fund management in BankLP
- Payout calculation logic
- Access control mechanisms

---

## License
All contracts are licensed under GPL-3.0

---

*Documentation generated for casino-contracts deployment*  
*Network: [Specify Network - likely Arbitrum based on gas handling]*  
*Last Updated: December 8, 2025*
