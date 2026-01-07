# Casino Contracts

Decentralized casino smart contracts built with Solidity, featuring provably fair games using Chainlink VRF for verifiable randomness.

## 🎮 Games

This repository contains the following casino games:

- **CoinFlip** - Heads or tails prediction with batch betting
- **Dice** - Over/under dice rolls with adjustable multipliers  
- **American Roulette** - Classic roulette with 00 wheel (38 positions)
- **European Roulette** - Single-zero roulette (37 positions)
- **Plinko** - Ball drop game with configurable rows and risk levels
- **Video Poker** - 5-card draw poker with card replacement
- **Blackjack** - Classic blackjack with dealer play
- **Slots** - Slot machine with configurable multipliers and outcomes
- **Mines** - Mine sweeper style game with multiplier progression
- **Keno** - Number selection lottery-style game
- **Rock Paper Scissors** - Classic RPS with provably fair outcomes
- **Lottery** - Round-based lottery with prize pool accumulation

## 🏗️ Architecture

### Core Contracts

- **BankLP** - Bankroll management, handles deposits, payouts, and play-to-earn rewards
- **Common** - Base contract inherited by all games, provides VRF integration and shared functionality
- **Treasury** - Collects protocol fees

### Key Features

- ✅ **Provably Fair** - All games use Chainlink VRF V2+ for verifiable randomness
- ✅ **Play-to-Earn** - 3% reward multiplier on all wagers
- ✅ **Multi-Token** - Support for native ETH and whitelisted ERC20 tokens
- ✅ **Batch Betting** - Multiple bets in single transaction with stop-gain/stop-loss
- ✅ **Meta-Transactions** - Gasless transactions via trusted forwarder
- ✅ **Self-Suspension** - Responsible gambling features built-in
- ✅ **L2 Optimized** - Gas-efficient design for Arbitrum and other L2s

## 🚀 Getting Started

### Prerequisites

- Node.js v18+
- pnpm (or npm)
- Foundry

### Installation

```bash
# Clone the repository
git clone https://github.com/VAULT777Team/casino-contracts.git
cd casino-contracts

# Install dependencies
pnpm install

# Install Foundry dependencies
forge install
```

### Environment Setup

Copy the example environment file and configure:

```bash
cp .env.example .env
```

Required environment variables:

```env
# Foundry
PRIVATE_KEY=your_private_key
RPC_URL=your_rpc_url
CHAIN_ID=421614
GAS_LIMIT=500000000
VERIFIER_API_KEY=your_etherscan_api_key

# Core Infrastructure
BANKLP_ADDRESS=deployed_banklp_address
VRF_ADDRESS=chainlink_vrf_coordinator
LINK_ETH_FEED_ADDRESS=chainlink_link_eth_feed
FORWARDER_ADDRESS=trusted_forwarder_address
```

## 🛠️ Development

### Compile Contracts

```bash
# Using Hardhat
pnpm compile

# Using Foundry
forge build
```

### Run Tests

```bash
# Foundry tests
forge test

# With verbosity
forge test -vvv
```

### Deploy Games

Deploy all games using the Foundry script:

```bash
forge script ./script/DeployAllGames.s.sol --rpc-url <RPC_URL> --private-key <PRIVATE_KEY> --code-size-limit 35000 --verifier sourcify --verifier-api-key <VERIFIER_API_KEY> --verify --broadcast --via-ir --optimizer-runs 100
```

### Configure Games

After deployment, configure game-specific settings:

```bash
# Configure all games
./script/configure_all.sh
```

## 📁 Project Structure

```
casino-contracts/
├── contracts/
│   ├── bankroll/          # Bankroll management contracts
│   ├── games/             # Game-specific subdirectories
│   │   └── Roulette/      # Roulette variants
│   ├── VRF/               # VRF-related contracts
│   ├── treasury/          # Treasury contracts
│   ├── faucet/            # Testnet faucet
│   ├── Common.sol         # Base game contract
│   ├── CoinFlip.sol
│   ├── Dice.sol
│   ├── Plinko.sol
│   ├── VideoPoker.sol
│   ├── Blackjack.sol
│   ├── Slots.sol
│   ├── Mines.sol
│   ├── Keno.sol
│   ├── RockPaperScissors.sol
│   └── Lottery.sol
├── script/                # Foundry deployment scripts
├── artifacts/             # Compiled contracts
├── broadcast/             # Deployment artifacts
├── deployments.md         # Deployed contract addresses & docs
└── foundry.toml           # Foundry configuration
```

## 🎲 Game Mechanics

### Common Game Flow

1. Player initiates game with wager and parameters
2. Contract validates wager against bankroll limits (Kelly criterion)
3. VRF request sent to Chainlink
4. Random numbers generated (3 block confirmations)
5. Game logic processes results
6. Payouts automatically transferred to player
7. Play-to-earn rewards allocated

### House Edge

Most games operate with a ~2% house edge, with payouts adjusted accordingly:
- CoinFlip: 1.98x payout (98% of 2x)
- Dice: Variable based on multiplier selection
- Roulette: Standard roulette house edge
- Others: Game-specific configurations

### Stop-Gain/Stop-Loss

Games support automatic bet termination:
- **Stop Gain**: Stops when profit reaches threshold
- **Stop Loss**: Stops when loss reaches threshold
- Unused bets automatically refunded

## 🔐 Security Features

- **Reentrancy Guards** - All external functions protected
- **Access Control** - Role-based permissions for critical functions
- **VRF Security** - Chainlink VRF ensures unpredictable randomness
- **Kelly Criterion** - Bankroll protection via wager limits
- **Refund Mechanism** - Players can claim refunds if VRF fails (200+ blocks)
- **Emergency Controls** - Owner functions for emergency situations

## 📜 License

GPL-3.0

## 🔗 Links

- [Documentation](./deployments.md)
- [Deployed Contracts](./deployments.md#deployed-contract-addresses)
- [Example Environment](./.env.example)
- [Arbitrum Sepolia Environment](./.env.arb-sepolia)

## 🤝 Contributing

Contributions are welcome! Please ensure:
- Code follows existing patterns
- All tests pass
- Gas optimizations considered
- Security best practices followed

## ⚠️ Disclaimer

These contracts are provided as-is. Use at your own risk. Gambling involves financial risk. Please gamble responsibly.

## 📞 Support

For issues and questions:
- Open an issue on GitHub
- Review existing documentation
- Check deployment examples

---

Built with ❤️ by VAULT777Team
