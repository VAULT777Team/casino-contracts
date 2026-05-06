## Deployments (v2)

### Constructor parameters (notes)

#### BankLP
- `_treasury`: `address`
- `_registry`: `address`
- `_factory`: `address`

#### BankrollMigrator
- `_oldBankroll`: `address`
- `_newBankroll`: `address`
- `_registry`: `address`
- `_governance`: `address`

#### BankrollRegistry
- `_initialBankroll`: `address`
- `_initialTreasury`: `address`
- `_version`: `string`

#### GameFactory
```solidity
nft = GameOwnershipNFT(_nft);
registry = GameRegistry(_registry);
```

### Game SDK

| Component | Address |
| --- | --- |
| NFT | `0x188FE36a3D8FE49DE0eBF5DCb09D4E5d32cf6e33` |
| GameRegistry | `0xA45c845600B31a7bc225C90Df71FA3b3D9AEBfe0` |
| GameFactory | `0x34772b76C54B372C57A7A079104e9b316da11479` |

### Core contracts

| Contract | Address |
| --- | --- |
| Treasury | `0x685631C73d0294dFE9A3862613B9Eb60bD757F98` |
| BankrollRegistry | `0x8736D858874715eA8e78C01884e337D1EDeC7643` |
| BankLP | `0xC7138c752E0606C0f5Ee58b6471EA3fb0F91E2Ec` |
| VaultLP | `0xFCF16FC477599f1D58671D3Fcb05C14B175BB663` |
| VaultLP2 (active testnet liquidity pool) | `0xe12fd15B3891ac2815F53Fb7Bc7C14310c861D9d` |

| BankLPV2 | `0x54FdD0Cb7131a53c492c611676C9A0166E23EeD1` |

  Core Infrastructure:
    BankLP:           0x54FdD0Cb7131a53c492c611676C9A0166E23EeD1
    BankLP Registry:  0x8736D858874715eA8e78C01884e337D1EDeC7643
    VRF:              0x5CE8D5A2BC84beb22a398CCA51996F7930313D61
    LINK/ETH Feed:    0x5BBd5163c48c4bc9ec808Be651c2DBBe9B1E0e99
    Forwarder:        0x0000000000000000000000000000000000000000
  
  Game Contracts:
    CoinFlip:           0x7aEDc67293AcbabB5b3d258a286eAeFEC164754f
    Dice:               0x77C58dCaCbA3721C5D5f03Fd4cD03961CbCfAcCC
    VideoPoker:         0xD5023Aaa3C77E78E1A88B9cc5E667B40FaC57405
    Blackjack:          0xCf4717ed46aB824497Dc65450fF10461Fe27C1b2
    Plinko:             0xAb25c4279EeFb7cfFEbB0A922e2d6F432CCf792f
    Slots:              0x16b9D0790Fa69751074534e43538fEcDE3418805
    Mines:              0x44D1BAF47c71D07122ccfFF915C94863CA5A471a
    Keno:               0xB682E97E8177a3e90096def21cC8D27a9d402079
    FortuneWheel:       0xc3A1B6cFE97000Def1bbB7FF27BeE1f4c58c959F
    Lottery:            0xaf73c0421a109825287B0f7c737Ab9B85D0Da02E
    RockPaperScissors:  0x3c674AB551e8dCfFaa2199B28E660f84dD34F7cf
    AmericanRoulette:   0x982334cFFb9f7cb20A95D7eC1b7b95e6Eadfe7E0
    EuropeanRoulette:   0x9b0EfF0eBABBE31A5498712a4d27f97937b2e0aF

    
### Games

sepolia VP:
0x2A4E80c5C8A5ECC2486f19a1E8Ad920c1509ce7F

#### Core infrastructure

| Component | Address |
| --- | --- |
| BankLP | `0xC7138c752E0606C0f5Ee58b6471EA3fb0F91E2Ec` |
| BankLP Registry | `0x8736D858874715eA8e78C01884e337D1EDeC7643` |
| VRF | `0x5CE8D5A2BC84beb22a398CCA51996F7930313D61` |
| LINK/ETH Feed | `0x5BBd5163c48c4bc9ec808Be651c2DBBe9B1E0e99` |


#### Account Abstraction (AA)
| Component | Address |
| --- | --- |
| IEntryPoint | `0x0000000071727De22E5E9d8BAf0edAc6f37da032`


### debug: 
casino account: 0x31dE08D2460484F5900C454fBEf7D5d7Caa34b32

#### Game contracts

| Game | Address |
| --- | --- |
| CoinFlip | `0xdaC233DACB0454560A2f314E766a3E61FD4353F0` |
| Dice | `0xea541dc8aCe4fA00C33c17EB9579B7Ef3b257885` |
| VideoPoker | `0xC25b25592F3FaC5d47d053e8998fD76170876C16` |
| Blackjack | `0xE18Eb3A2cfb03E7B7e7f0eaE501A061D264b6a9F` |
| Plinko | `0x0da6F92880126F8Caed4Ce92e95F0C8DC72dE123` |
| Slots | `0x727051447248E688311a2530dF647096ca2B1F62` |
| Mines | `0xC7fB514C2fa380dAbfBeee9Ffc41c0F4099C7612` |
| Keno | `0xAD40d0Ace91601bf8dB66e4Dc7659d4Ca65e62F2` |
| RockPaperScissors | `0x69aEC3FB6469B1eF80642bDaa3C9B32F13eb8Ae5` |
| AmericanRoulette | `0x5A6973a65167c946b459D6841c67a512BF48fBEb` |
| EuropeanRoulette | `0x3F28413133500ea3A9541E2e79B813BF9065f3d4` |