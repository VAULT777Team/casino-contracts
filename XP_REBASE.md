# XP Rebase / Play Token Roadmap

## Goal

Introduce a **free/play token** that can be:

- granted via faucet
- granted after wallet KYC
- granted from offchain events/promotions
- converted from offchain XP
- converted back into offchain XP

while keeping:

- onchain gameplay simple
- bankroll integration minimal
- real-money leaderboards clean
- XP accounting non-duplicative

---

## Core Model

There are two representations of the same promotional value:

1. **Offchain XP**
   - stored in backend
   - non-transferable
   - earned from offchain/admin/event systems
   - may optionally be earned from selected gameplay sources

2. **Onchain Play Token**
   - ERC20
   - transferable/playable
   - usable in games through existing `BankLP -> games` path
   - burned when converting back into XP

### Canonical accounting rule

Promotional value should exist in **one place only** at a time.

- **XP -> Play Token**
  - backend debits XP
  - token is minted onchain

- **Play Token -> XP**
  - token is burned onchain
  - backend credits XP

This prevents double-counting.

---

## Important Constraint

### Play-token gameplay should NOT generate XP

If play-token wagers generate XP, users can create a loop:

1. XP -> Play Token
2. Play Token used in games
3. Gameplay generates XP
4. XP -> Play Token again

This creates a farmable reward loop.

### Therefore:

Play-token wagers should be excluded from:

- XP accrual
- referral wager totals
- total wager leaderboards
- gross profit leaderboards
- net profit leaderboards
- any combined real-money competition stats

---

## Existing Stack Compatibility

## Contracts

Current contracts already support token-agnostic gameplay via bankroll checks.

### Relevant flow

- Games call `Common._transferWager(...)`
- `Common` asks `BankLP.getIsValidWager(address(this), tokenAddress)`
- `BankLP` checks:
  - game is allowed
  - token is allowed

### Result

A new play token can already be integrated by:

- deploying ERC20 token
- enabling it in `BankLP`
- funding `BankLP` with token liquidity
- exposing token in frontend/backend config

### Existing useful pieces

- `contracts/faucet/Faucet.sol`
  - can already distribute ERC20 token
  - supports relayer-based claims

- `contracts/bankroll/facets/BankLP.sol`
  - token allowlist
  - reserve accounting per token
  - payouts per token

---

## Proposed Architecture

## 1. Play Token

Deploy a dedicated ERC20 with:

- `mint(address,uint256)`
- `burn(uint256)` and/or `burnFrom(address,uint256)`
- role-based minter permissions

### Suggested semantics

- promotional / free-play only
- not treated as cash-equivalent
- separate from real-money ecosystem metrics

---

## 2. Distribution Sources

Play token can be distributed from:

- faucet
- wallet KYC grant
- admin/manual campaigns
- offchain event rewards
- XP redemption

### Initial recommendation

Use existing `Faucet.sol` for first version.

---

## 3. XP Ledger

Keep XP offchain in backend as the canonical XP ledger.

Current system already stores XP in backend tables, so reuse that rather than forcing XP fully onchain.

### XP is good for:

- event campaigns
- social actions
- KYC completion
- quests / promotion systems
- optional reward multipliers

---

## 4. Conversion Bridge

## XP -> Play Token

Flow:

1. user requests redemption
2. backend verifies XP balance
3. backend debits XP
4. backend mints play token
5. backend stores audit record

## Play Token -> XP

Flow:

1. user initiates burn
2. backend verifies burn transaction or manages burn request
3. token is burned onchain
4. backend credits XP
5. backend stores audit record

---

## 5. Bankroll / Game Integration

### Minimal integration path

- whitelist play token in `BankLP`
- fund bankroll with play token
- allow games to accept it normally

### No major game contract changes expected

Because games already use the common bankroll-based token validation flow.

---

## 6. Backend Safety Rules

The backend currently computes money-based stats using token valuation.

This is dangerous for a free token unless explicitly excluded.

### Required backend behavior for play token

The play token must be excluded from:

- `wager_value`
- `payout_value`
- `total_won_value`
- total wager leaderboards
- gross profit leaderboards
- net profit leaderboards
- player wagered stats
- referral wagered stats
- gameplay XP accrual

### Recommended config

Add explicit config such as:

- `FREE_PLAY_TOKENS`
- `EXCLUDED_LEADERBOARD_TOKENS`
- `EXCLUDED_XP_TOKENS`

Per chain if necessary.

---

## 7. Frontend Behavior

Frontend should clearly distinguish:

- XP balance
- Play Token balance
- Real-money tokens

### Recommended UI

- "Redeem XP to Play Token"
- "Burn Play Token to XP"
- "Play Token" clearly labeled as promotional/free-play
- no misleading cash/value presentation

---

## 8. Admin / Audit Requirements

Every conversion should be auditable.

### Recommended records

For each conversion:

- player address
- direction (`xp_to_token` / `token_to_xp`)
- xp amount
- token amount
- tx hash (if applicable)
- status
- created at
- processed by / source
- nonce or idempotency key

### Why

Needed for:

- replay prevention
- support/debugging
- fraud review
- accounting sanity

---

## Recommended Rules

## Allowed

- Faucet -> Play Token
- KYC -> Play Token
- Promo event -> XP
- Promo event -> Play Token
- XP -> Play Token
- Play Token -> XP

## Disallowed / Excluded

- Play Token wagers contributing to:
  - XP
  - total wager leaderboard
  - gross profit leaderboard
  - net profit leaderboard
  - referral wagered
  - real-money competition stats

---

## Rollout Plan

## Phase 1 — Foundation

### Goal

Get the play token live and usable safely.

### Tasks

- deploy mintable/burnable play token
- configure faucet to distribute it
- whitelist token in `BankLP`
- fund bankroll with token liquidity
- add token metadata to dapp
- add token config to backend
- exclude token from money leaderboards and gameplay XP

### Estimate

**3–5 working days**

---

## Phase 2 — XP -> Token

### Goal

Allow users to convert XP into play token.

### Tasks

- define redemption ratio
- add backend redemption endpoint/service
- debit XP in backend
- mint play token onchain
- add audit table / records
- add frontend redeem flow

### Estimate

**2–4 working days**

---

## Phase 3 — Token -> XP

### Goal

Allow users to burn play token back into XP.

### Tasks

- define reverse conversion ratio
- implement burn flow
- verify burn on backend
- credit XP
- add audit / replay protections
- add frontend reverse conversion flow

### Estimate

**3–5 working days**

---

## Phase 4 — Hardening / UX / Admin

### Goal

Make the system production-safe and supportable.

### Tasks

- add admin tools for grants and audits
- add fraud/rate-limit controls
- add cooldowns / claim limits if needed
- add analytics dashboards
- optionally add separate play-token leaderboard
- add support tooling for failed conversions

### Estimate

**3–5 working days**

---

## Total Timeline

## MVP

Includes:

- token
- faucet
- bankroll support
- exclusions
- XP -> token

### Estimated time

**~1 week**

## Full 2-way system

Includes:

- token -> XP
- audit trail
- abuse protections
- UI polish
- admin tools

### Estimated time

**~2 weeks**

## Polished / robust version

Includes:

- signed claim architecture
- dedicated bridge contract
- richer analytics and admin tooling

### Estimated time

**~2–3 weeks**

---

## Recommended First Version

Start simple:

1. deploy play token
2. distribute via faucet/KYC/admin
3. whitelist in bankroll
4. exclude from real-money stats and XP accrual
5. add one-way XP -> token redemption
6. later add reverse burn -> XP

This minimizes risk while delivering value quickly.

---

## Risks / Things to Watch

### 1. Value duplication
If XP is not debited when minting token, users get double value.

### 2. Reward farming
If play-token wagers generate XP, users can loop rewards.

### 3. Leaderboard contamination
If backend assigns token any USD-like valuation, free play will pollute leaderboards.

### 4. Replay / duplicate redemption
Need idempotency and audit trail.

### 5. Bankroll underfunding
Token may be accepted by games but bankroll may not have enough for payouts.

---

## Recommendation Summary

Use:

- **offchain XP** as the promotion ledger
- **onchain play token** as the spendable free-play asset
- **burn/debit semantics both directions**
- **strict exclusion from real-money stats**
- **no XP accrual from play-token gameplay**

This is the cleanest and safest path with the current stack.