# BankLP and Games Security Review

**Review date:** 2026-08-11  
**Scope:** `BankLP`, bankroll registry/migration/LP infrastructure, `Common`, and all contracts under `contracts/games` that custody wagers or interact with BankLP  
**Method:** Manual source review, call-site tracing, trust-boundary analysis, payout/liability analysis, and execution of the existing Forge suite  
**Code changes:** None

## Executive summary

The current system does not enforce a global solvency invariant. BankLP treats every approved game as fully trusted, records reserves only as a token-wide total, and permits any approved game to transfer any amount to any recipient without consuming a matching liability. Most games do not reserve their maximum payout at all.

The most urgent confirmed issues are:

1. The deployed legacy Blackjack resolves dealer play synchronously with timestamp-derived randomness, enabling selective-revert transactions that commit wins and roll back losses.
2. The documented bankroll migration script can strand migrated assets and permanently leave both BankLP instances owned by the migrator.
3. Slots could deterministically overpay unplayed bets by `rowsPerSpin`; this issue is remediated in the current worktree.
4. Any compromised or malicious approved game can drain BankLP directly.
5. Accepted game liabilities can exceed BankLP assets, notably Keno jackpots, Slots batches/bonuses, Crash escrows, and OCG settlements.
6. Open wagers are not pinned to the BankLP that accepted them, so a registry switch can make settlement or refund impossible.

The system should not be considered safely solvent under concurrent play until liabilities are tracked by game, token, and wager/request ID and every game reserves its strict worst-case gross payout.

## Severity summary

| ID | Severity | Finding |
|---|---|---|
| C-01 | Critical | Migration workflow can strand assets and permanently lock BankLP ownership |
| C-02 | Critical | Deployed legacy Blackjack permits selective-revert guaranteed wins |
| H-01 | High | Approved games have unrestricted payout authority over BankLP assets |
| H-02 | High | Global reserves do not isolate liabilities and most games reserve nothing |
| H-03 | High | Slots refunds unprocessed rows rather than unprocessed bets (remediated) |
| H-04 | High | Open wagers resolve against a mutable BankLP address |
| H-05 | High | Crash can accept liabilities exceeding the bankroll |
| H-06 | High | OCG settlements are cumulatively uncapped and deferred liabilities are unreserved |
| M-01 | Medium | Zero stop limits create deterministic fee leakage across batch games |
| M-02 | Medium | CoinFlip reserves profit target instead of maximum gross payout |
| M-03 | Medium | EuropeanRoulette implements an American 38-slot wheel |
| M-04 | Medium | OCG bet signatures do not bind the bet arrays or action identifiers |
| M-05 | Medium | OCG cancellation refunds gross stake after BankLP fees have left |
| M-06 | Medium | Lottery rounds are permissionlessly configurable and can be griefed |
| M-07 | Medium | BankLP accounting assumes standard ERC-20 transfer behavior |
| M-08 | Medium | Deployment activation does not approve games on BankLP |
| L-01 | Low | Deactivated current bankroll remains returned by the registry |
| L-02 | Low | Mutable game configuration can change accepted-wager economics |
| L-03 | Low | VideoPoker paytable disagrees with the repository audit tests |
| L-04 | Low | Fee telemetry does not represent funds retained by BankLP |

## Architecture and trust boundaries

### Asset flow

Most VRF games follow this lifecycle:

1. `Common._transferWager` validates the game/token against the currently registered BankLP and holds the wager in the game contract.
2. The game requests VRF and stores player/request state.
3. On fulfillment, the game deposits the gross wager into whichever BankLP is current at that moment.
4. BankLP sends creator and treasury fees from the deposit.
5. The game requests a gross payout from that BankLP.
6. On timeout, the game refunds the wager directly from its own balance.

Relevant shared code:

- Dynamic BankLP lookup: `contracts/Common.sol:72-75`
- Reserve helpers: `contracts/Common.sol:143-152`
- Wager transfer: `contracts/Common.sol:156-169`
- BankLP deposit and payout helpers: `contracts/Common.sol:172-188`
- VRF fee collection: `contracts/Common.sol:235-272`

### Privileged actors

| Actor | Effective authority |
|---|---|
| BankLP owner | Approve games/tokens, change registry/treasury/LP/factory/reward token, withdraw liquidity, and execute arbitrary calls |
| Bankroll registry | BankLP `execute` authority and selection of the active BankLP |
| Liquidity pool | Withdraw all funds not represented by `reservedFunds` |
| Approved game | Reserve/release the global reserve total, transfer arbitrary BankLP payouts, and grant arbitrary play rewards |
| Game owner | Change registry, VRF parameters, fee manager, and game-specific configuration |
| VRF coordinator | Deliver randomness callbacks |
| Crash signer | Authorize Crash payouts within the current on-chain config |
| OCG operator | Place signed bet authorizations and submit unlimited settlement actions |

BankLP owner and registry powers are intentionally administrative, but approved games should not be treated as equivalent to unrestricted asset custodians. A defect or compromise in one game currently exposes every asset held by BankLP.

## Detailed findings

## C-02: Deployed legacy Blackjack permits selective-revert guaranteed wins

**Severity:** Critical  
**Confidence:** High  
**Status:** Fixed in the current source, but the reviewed deployed legacy contract remains exposed until disabled or replaced  
**Affected deployment:** Arbitrum Blackjack `0x39fd417F6f1c5B22Cc8950CACBa9f23B1e092e19`  
**Affected historical source:**

- Historical `contracts/Blackjack.sol:178-194`
- Historical `contracts/Blackjack.sol:277-309`
- Historical `contracts/Blackjack.sol:312-337`

### Root cause

The deployed legacy implementation resolves `Blackjack_Stand()` synchronously and derives dealer cards from:

```solidity
keccak256(abi.encodePacked(block.timestamp, player, game.playerScore))
```

Settlement and payout occur in the same player-controlled transaction. A calling contract can inspect whether its balance increased and revert the complete transaction when the result is a loss or push. Reverting restores the active game, allowing another attempt in a later block. Winning transactions are committed.

This is not ordinary predictable-randomness risk. Transaction atomicity converts the game into a one-sided option: losses can be rolled back while wins remain final.

### Impact

An unprivileged attacker can repeatedly:

1. Start a native Blackjack game at the maximum allowed wager.
2. Wait for the initial VRF deal.
3. Attempt `Blackjack_Stand()` through a contract.
4. Revert unless the call produced a profitable payout.
5. Retry until a win commits.
6. Start another game against the reduced bankroll.

Each committed regular win returns 2x gross and removes approximately one wager of principal from BankLP. Repeating with the recalculated maximum wager can geometrically deplete the native LP balance. Future native LP deposits remain exposed while the legacy deployment is approved and callable.

### Current-source status

The current `contracts/games/Blackjack.sol:210-236,382-435` requests fresh VRF randomness on stand and settles only in the coordinator callback. That structure prevents the player from synchronously reverting only losing outcomes.

The source fix does not protect an already deployed immutable contract. The deployed address must be disabled at BankLP and removed from supported frontends/routers, then replaced with the VRF-based implementation.

### Recommended immediate response

- Disable the deployed Blackjack address with `BankLP.setGame(game, false)`.
- Remove it from frontend and account-abstraction allowlists.
- Preserve logs and review historical payouts for repeated selective-revert patterns.
- Deploy and activate the current asynchronous VRF implementation.
- Confirm the old game cannot call BankLP payout functions after deactivation.
- Do not publish a fork PoC until the deployed address is contained.

## C-01: Migration workflow can strand assets and permanently lock BankLP ownership

**Severity:** Critical  
**Confidence:** High  
**Affected code:**

- `script/DeployBankrollRegistry.s.sol:92-153`
- `contracts/bankroll/BankrollMigrator.sol:59-83`
- `contracts/bankroll/BankrollMigrator.sol:118-239`
- `contracts/bankroll/interfaces/IBankrollRegistry.sol:18-30`
- `contracts/bankroll/BankrollRegistry.sol:25-29`
- `contracts/bankroll/BankrollRegistry.sol:240-280`

### Root cause

The scripted migration transfers ownership of both old and new BankLP contracts to `BankrollMigrator`, but the migrator has no function that can return ownership. The script later calls `setOwner` from the deployer, which can no longer satisfy `BankLP.onlyOwner`.

The workflow also contains several independent blockers:

- `IBankrollRegistry.MigrationStats` has four fields, while `BankrollRegistry.MigrationStats` has three. This changes the ABI tuple and therefore the `recordMigration` selector.
- `finalizeMigration` calls `registry.recordMigration` from the migrator, but the registry expects its governance address.
- `migrateToken` already transfers the old BankLP balance to the new BankLP, while `BankrollRegistry.recordMigration` attempts to transfer the reported amount again.
- `migrateTokensBatch` calls `this.migrateToken(...)`; the resulting caller is the migrator itself, which fails `onlyGovernance` when governance is the deployer.

### Impact

The migration script submits separate transactions. Ownership transfers and token migrations can succeed before finalization reverts. The result can be:

- Assets moved into an inactive BankLP.
- Both BankLP contracts permanently owned by the migrator.
- Finalization and activation not reached.
- No callable path to restore ownership.
- Reserved amounts recorded as metadata but not recreated on the new BankLP.

### Recommended remediation

Replace the current helper with a migration coordinator that:

- Uses one canonical registry interface and ABI.
- Separates asset movement from metadata recording.
- Explicitly recreates enforceable liabilities, not only reserve statistics.
- Has a tested, callable ownership hand-back step.
- Uses pull-based governance calls or grants narrowly scoped migration roles instead of full ownership.
- Prevents activation until assets, liabilities, games, tokens, and ownership are verified.
- Is tested transaction-by-transaction against the actual deployment script.

## H-01: Approved games have unrestricted payout authority over BankLP assets

**Severity:** High  
**Confidence:** High  
**Status:** Remediated in `contracts/games/Slots.sol`, with regression coverage in `test/Slots.t.sol`  
**Affected code:**

- `contracts/bankroll/facets/BankLP.sol:260-275`
- `contracts/bankroll/facets/BankLP.sol:430-461`
- `contracts/bankroll/facets/BankLP.sol:359-362`

### Root cause

`transferPayout` checks only whether `msg.sender` is an approved game. It does not verify:

- A wager or request ID.
- The player associated with the wager.
- A maximum payout.
- A reservation owned by the caller.
- That the token is allowed.
- That the payout leaves other liabilities fully backed.

Similarly, any approved game can grant arbitrary play rewards through `addPlayerReward`.

### Exploit scenario

A compromised approved game calls:

```solidity
BankLP.transferPayout(attacker, tokenBalance, token);
```

The call succeeds for any BankLP-held ERC-20 or native balance, regardless of other games' reserves. The same game can grant unbounded mintable reward claims.

### Impact

Compromise of one game compromises the shared bankroll and potentially the play-reward token. Game approval is effectively full asset-custody authorization.

### Recommended remediation

Require payouts to consume a liability keyed by at least:

```text
game + token + wager/request ID + player
```

The payout recipient and maximum amount must be fixed when the liability is created. Remove unrestricted reward amounts from games; calculate rewards from recorded wager data or enforce per-game caps.

## H-02: Global reserves do not isolate liabilities and most games reserve nothing

**Severity:** High  
**Confidence:** High  
**Affected code:**

- `contracts/bankroll/facets/BankLP.sol:243-292`
- `contracts/bankroll/facets/BankLP.sol:430-461`
- All game payout paths listed in the per-game table below

### Root cause

`reservedFunds[token]` is one token-wide number. It has no game or wager ownership. Any approved game can increase or decrease the number, and payouts do not consume it.

Only these games call `_reserveMaxPayout`:

- `CoinFlip`: `contracts/games/CoinFlip.sol:149`
- `FortuneWheel`: `contracts/games/FortuneWheel.sol:190`
- `CoinFlipDoubleOrNothing`: `contracts/games/CoinFlipDoubleOrNothing.sol:73,103`

All other BankLP-backed games accept liabilities without creating an enforceable reserve.

### Concrete insolvency examples

**Keno**

- Maximum multiplier is 100,000x: `contracts/games/Keno.sol:321-343`
- Wager limit for 8-10 spots is 0.05% of current available balance: `contracts/games/Keno.sol:346-364`
- Up to five bets are accepted: `contracts/games/Keno.sol:104-148`

One maximum wager can owe roughly 50 times the bankroll; five jackpot results can owe roughly 250 times the bankroll.

**Slots**

- Up to 100 bets are accepted: `contracts/games/Slots.sol:368-415`
- Kelly validation applies only to the per-spin wager: `contracts/games/Slots.sol:769-780`
- Payout can sum rows, symbol-kind multipliers, bonus multipliers, and up to 25 bonus rounds per triggering outcome: `contracts/games/Slots.sol:475-637`

**Other games**

Dice, Blackjack, Mines, Plinko, VideoPoker, RockPaperScissors, Rug, both roulette contracts, Crash, and OCG similarly rely on point-in-time balance checks rather than reserving their accepted gross liability.

### Impact

- Concurrent accepted wagers can exceed assets.
- A payout can revert in a VRF callback.
- Winners can become unable to collect.
- LP withdrawals can appear safe because only the incomplete reserve total is protected.
- An honest payout by one game can consume funds expected by another game.

### Recommended remediation

Every accepted request must calculate and reserve its strict worst-case **gross payout**, including batched bets, returned unplayed stakes, bonus rounds, multi-stage growth, pending withdrawals, and cancellation refunds. Payout and release must be exact-once state transitions on the caller's own liability.

## H-03: Slots refunds unprocessed rows rather than unprocessed bets

**Severity:** High  
**Confidence:** High  
**Affected code:**

- `contracts/games/Slots.sol:473-483`
- `contracts/games/Slots.sol:639`
- `contracts/games/Slots.sol:685-691`

### Root cause

Slots computes:

```solidity
uint32 totalRows = game.numBets * rowsPerSpin;
...
payout += (totalRows - processedRows) * game.wager;
```

The player paid `game.numBets * game.wager`, not `totalRows * game.wager`. When execution stops before all rows are processed, each unprocessed row is refunded as if it were a separate paid bet.

Because the loop checks `totalValue >= stopGain` before processing the first bet, `stopGain == 0` immediately stops with `processedRows == 0`.

### Exploit scenario

With `rowsPerSpin == 5`, a player submits a request with `stopGain == 0`. On fulfillment:

- Collected wager: `numBets * wager`
- Deterministic payout: `5 * numBets * wager`

The player receives approximately five times the stake without using the VRF result, subject only to BankLP liquidity.

### Impact

Direct, repeatable BankLP drain. The per-spin Kelly check and lack of reservation increase the amount that can be extracted per request.

### Recommended remediation

The implemented correction refunds only unprocessed paid spins:

```text
(numBets - processedBets) * wager
```

Define row accounting separately from wager accounting. Reject zero stop limits or explicitly treat zero as "disabled" rather than as an already-reached threshold.

## H-04: Open wagers resolve against a mutable BankLP address

**Severity:** High  
**Confidence:** High  
**Affected code:**

- `contracts/Common.sol:72-75`
- `contracts/Common.sol:145-188`
- `contracts/bankroll/BankrollRegistry.sol:183-225`
- Game structs under `contracts/games` store token/request data but not the accepting BankLP

### Root cause

Every reserve, release, deposit, payout, fee transfer, and validation dynamically calls `Bankroll()`, which reads the registry's current address. Wager state does not record which BankLP accepted the request.

### Failure scenario

1. CoinFlip, FortuneWheel, or DoubleOrNothing reserves funds on BankLP A.
2. Governance activates BankLP B while VRF is pending.
3. Settlement or refund calls `releaseFunds` on B.
4. B has no corresponding reserve, so the call reverts.
5. The reserve remains orphaned on A and the player's wager remains stuck in the game contract.

Non-reserving games can silently deposit the old wager into and pay from B, shifting economic results between LP cohorts.

### Recommended remediation

Store the accepting BankLP address in every wager, round, escrow, and pending withdrawal. Use that address for the complete lifecycle. Block migration while liabilities are open, or migrate each identified liability atomically before changing the active address.

## H-05: Crash can accept liabilities exceeding the bankroll

**Severity:** High  
**Confidence:** High  
**Affected code:**

- `contracts/games/crash/Escrow.sol:113-160`
- `contracts/games/crash/Escrow.sol:267-295`
- `contracts/games/crash/Escrow.sol:329-365`
- `contracts/games/crash/Escrow.sol:369-386`

### Root cause

Crash deposits the stake immediately but does not reserve the signed payout. `_maxWagerAllowed` uses the less restrictive of the risk-model and expected-payout caps:

```solidity
max(maxWagerByRisk, maxWagerByExpected)
```

This does not ensure that `wager * maxMultiplier` is payable.

For the coin-flip provably-fair config:

- Maximum payout multiplier: 198x.
- Kelly/expected multiplier used for wager cap: approximately 17.8182x.
- Allowed wager: approximately 1.1224% of available bankroll.
- Maximum signed payout: approximately 222% of the bankroll.

Multiple escrows can be opened because none reserve their liability.

### Impact

A valid backend-signed payout can be larger than BankLP's entire balance. Concurrent valid escrows can overcommit the bankroll even under configs whose individual cap is below 100%.

### Recommended remediation

Calculate the wager cap from the strict configured maximum payout, reserve that amount at deposit, bind it to `player + escrowId`, and consume it on cashout/loss cleanup. If a separate expected-loss model is desired, it must not replace the hard solvency bound.

## H-06: OCG settlements are cumulatively uncapped and deferred liabilities are unreserved

**Severity:** High  
**Confidence:** High  
**Affected code:**

- `contracts/games/ocg/GameLedger.sol:363-424`
- `contracts/games/ocg/GameLedger.sol:429-470`

### Root cause

`settleBatch` checks each settlement independently:

```solidity
payout <= round.totalStake * maxPayoutMultiplierX
```

The round remains settleable, and fresh action keys can repeat the maximum payout indefinitely. The contract does not track cumulative paid value.

When BankLP payout fails, the amount is recorded in `pendingWithdrawals`, but no BankLP reserve is created. `totalPendingWithdrawals` protects no BankLP balance and is not consulted by BankLP or VaultLP.

### Impact

- An operator can drain BankLP with repeated settlements for one round.
- Honest retry or partial-settlement logic can exceed the intended cap.
- Pending player claims compete with LP withdrawals and other games.
- Updating the stored bankroll address moves claims to a BankLP that never received the stakes.

### Recommended remediation

Track `totalSettled` and a terminal/remaining-liability state per round. Reserve the round's maximum liability when accepting the bet. Convert failed transfers into claims against the same pinned BankLP and liability rather than creating an unbacked ledger entry.

## M-01: Zero stop limits create deterministic fee leakage across batch games

**Severity:** Medium  
**Confidence:** High  
**Affected code:**

- CoinFlip: `contracts/games/CoinFlip.sol:232-260`
- Dice: `contracts/games/Dice.sol:225-251`
- Keno: `contracts/games/Keno.sol:208-231`
- Plinko: `contracts/games/Plinko.sol:319-338`
- RockPaperScissors: `contracts/games/RockPaperScissors.sol:216-244`
- Rug: `contracts/games/Rug.sol:218-244`
- EuropeanRoulette: `contracts/games/Roulette/EuropeanRoulette.sol:292-311`
- Slots: separately escalated in H-03
- BankLP fee transfers: `contracts/bankroll/facets/BankLP.sol:607-682`

### Root cause

The batch loops interpret zero as an already reached stop:

```solidity
if (totalValue >= stopGain) break;      // 0 >= 0
if (totalValue <= -int256(stopLoss)) break;
```

They then return all unplayed stakes, but first deposit the full wager into BankLP. BankLP has already sent treasury and optional creator fees.

### Impact

The player receives the gross stake back while BankLP absorbs the external fee outflow. With no creator, BankLP loses approximately 1% of the wager per cycle to treasury; configured creator sharing increases the loss. The attacker pays gas and VRF fees, making this primarily an economic griefing vector unless the attacker also receives creator fees.

### Recommended remediation

Use explicit booleans or apply a threshold only when it is nonzero:

```text
stopGain != 0 && totalValue >= stopGain
stopLoss != 0 && totalValue <= -stopLoss
```

Charge fees only on played stakes, or refund unplayed stakes before depositing the played portion.

## M-02: CoinFlip reserves profit target instead of maximum gross payout

**Severity:** Medium  
**Confidence:** High  
**Affected code:**

- `contracts/games/CoinFlip.sol:136-149`
- `contracts/games/CoinFlip.sol:232-282`

### Root cause

When `stopGain > 0`, `maxPayout` is set to `stopGain`. `stopGain` represents profit, while the actual payout includes winning gross returns and refunds of all unplayed stakes.

Example: after one winning bet, the payout may include `1.98 * wager` plus every unplayed wager, while the reserve can be only `0.98 * wager`.

### Impact

CoinFlip appears reserve-aware but can release a reserve substantially below the amount it pays. This weakens LP withdrawal protection and contributes to cross-game insolvency.

### Recommended remediation

Compute the maximum gross payout at every possible stopping index:

```text
gross winnings so far + all refundable unplayed stakes
```

Reserve the maximum of those values.

## M-03: EuropeanRoulette implements an American 38-slot wheel

**Severity:** Medium  
**Confidence:** High  
**Affected code:**

- `contracts/games/Roulette/EuropeanRoulette.sol:10-16`
- `contracts/games/Roulette/EuropeanRoulette.sol:28-38`
- `contracts/games/Roulette/EuropeanRoulette.sol:296`

### Root cause

The contract is named `EuropeanRoulette` but:

- Its comments describe an American `00` wheel.
- Straight bets include value `37`.
- Random outcomes use `randomWords[i] % 38`.

European roulette has 37 outcomes, `0-36`, and no `00`.

### Impact

Players receive American-wheel odds while interacting with a contract presented as European roulette. This materially increases house edge and is a fairness/integrity issue.

### Recommended remediation

Use `% 37`, reject straight value 37, update comments/events, and add statistical/paytable tests for every bet type.

## M-04: OCG bet signatures do not bind bet arrays or action identifiers

**Severity:** Medium  
**Confidence:** High  
**Affected code:** `contracts/games/ocg/GameLedger.sol:292-359`

### Root cause

The operator signs only:

```text
sender + totalValue + contract + validUntil
```

The signature excludes `actionKeys`, `roundKeys`, `stakes`, chain ID, and a signer-controlled nonce.

### Impact

A player can reuse one authorization until expiry with fresh action keys and can redistribute the authorized total across arbitrary rounds and stakes. The user still supplies the ETH, so this is primarily an authorization-integrity failure rather than direct theft, but it can bypass off-chain round, limit, or game rules.

### Recommended remediation

Use EIP-712 and bind the complete batch hash, chain ID/domain, player, nonce, expiry, and action type. Make the nonce operator-issued or otherwise single-use.

## M-05: OCG cancellation refunds gross stake after BankLP fees have left

**Severity:** Medium  
**Confidence:** High  
**Affected code:**

- `contracts/games/ocg/GameLedger.sol:356-359`
- `contracts/games/ocg/GameLedger.sol:429-457`
- `contracts/bankroll/facets/BankLP.sol:607-682`

### Root cause

`betBatch` deposits the full stake into BankLP, which immediately transfers creator/treasury fees. `cancel` later requests a refund of the full gross stake.

### Impact

Every cancellation socializes the fee loss to BankLP. A compromised or colluding operator can repeatedly authorize and cancel rounds to move BankLP value to treasury/creator recipients.

### Recommended remediation

Hold cancellable wagers in escrow until the cancellation window closes, or define cancellation as a refund of the net amount remaining after nonrefundable fees. Make the economic rule explicit and test it.

## M-06: Lottery rounds are permissionlessly configurable and can be griefed

**Severity:** Medium  
**Confidence:** High  
**Affected code:** `contracts/games/Lottery.sol:90-169`

### Root cause

Anyone can start the single active round for a token and choose its ticket price. A round remains active for the configured epoch even if no tickets are sold.

### Impact

An attacker can repeatedly create an impractically priced native or supported-token round, preventing the intended operator/community from starting a usable round until the epoch ends and the empty round is closed.

### Recommended remediation

Restrict round creation to an authorized role or use bounded, governance-defined ticket-price configurations. Alternatively, allow permissionless creation only when multiple concurrent rounds are supported.

## M-07: BankLP accounting assumes standard ERC-20 transfer behavior

**Severity:** Medium  
**Confidence:** High  
**Affected code:**

- `contracts/Common.sol:165-169`
- `contracts/bankroll/facets/BankLP.sol:568-575`
- `contracts/bankroll/facets/BankLP.sol:590-599`
- `contracts/bankroll/facets/BankLP.sol:646-682`

### Root cause

Wagers, deposits, LP funding, fees, and payouts account using requested amounts, not observed balance deltas. BankLP also uses raw `IERC20.transfer/transferFrom` in several places instead of `SafeERC20`.

### Impact

Fee-on-transfer or rebasing tokens can make recorded stakes and liabilities differ from actual assets. Nonstandard tokens that return no boolean can make payouts or withdrawals unusable. Callback-capable tokens expand reentrancy exposure.

### Recommended remediation

Explicitly allow only standard, non-rebasing ERC-20s or use pre/post balance deltas everywhere solvency depends on received value. Use `SafeERC20` consistently and document token requirements in deployment checks.

## M-08: Deployment activation does not approve games on BankLP

**Severity:** Medium  
**Confidence:** High  
**Affected code:** `script/ActivateGames.s.sol:67-124`

### Root cause

VRF consumer registration is active for several games, while every corresponding `BankLP.setGame` call is commented out.

### Impact

Deployed games can request VRF but fail wager validation, reserve operations, or payouts. Configuration can be partially active and operationally unsafe.

### Recommended remediation

Make activation idempotent and assert all required conditions in one script:

- Current BankLP address.
- BankLP game approval.
- VRF consumer registration.
- Token approval.
- Wrapped native token.
- Treasury, LP, fee manager, and feeds.

Revert deployment if any postcondition is false.

## L-01: Deactivated current bankroll remains returned by the registry

**Severity:** Low  
**Confidence:** High  
**Affected code:**

- `contracts/bankroll/BankrollRegistry.sol:313-334`
- `contracts/bankroll/BankrollRegistry.sol:340-354`

`deactivateBankroll` marks the current entry inactive but does not update `currentBankrollIndex`. `getCurrentBankroll` does not check `isActive`, so consumers continue receiving the deactivated address.

Require an active entry or make deactivation atomically select a replacement.

## L-02: Mutable game configuration can change accepted-wager economics

**Severity:** Low  
**Confidence:** High  
**Affected examples:**

- FortuneWheel stores `configId` but reads mutable config at fulfillment: `contracts/games/FortuneWheel.sol:259-290,315-423`
- Crash stores `configId` but validates against mutable config at cashout: `contracts/games/crash/Escrow.sol:329-365`
- OCG uses the current global payout multiplier for each settlement: `contracts/games/ocg/GameLedger.sol:376-399`

Privileged configuration changes can alter payouts or caps after a wager has been accepted. Snapshot immutable economic parameters per wager or version configs so accepted requests always settle under their original terms.

## L-03: VideoPoker paytable disagrees with repository audit tests

**Severity:** Low  
**Confidence:** Medium pending product specification  
**Affected code/tests:**

- Contract paytable: `contracts/games/VideoPoker.sol:351-467`
- Expected paytable: `test/VideoPokerAudit.t.sol:33-108,183-213`

The contract returns lower multipliers than the audit tests expect:

| Hand | Contract | Test expectation |
|---|---:|---:|
| Royal flush | 50x | 100x |
| Straight flush | 25x | 50x |
| Four of a kind | 15x | 30x |
| Full house | 5x | 8x |
| Two pair | 1x | 2x |

Resolve the authoritative paytable, update either code or tests, and publish the gross/net multiplier convention.

## L-04: Fee telemetry does not represent funds retained by BankLP

**Severity:** Low  
**Confidence:** High  
**Affected code:** `contracts/bankroll/facets/BankLP.sol:607-682`

`fees[token]` increases by the full 2% nominal fee, but creator and treasury portions are immediately transferred and the mapping is never reduced or used for settlement. It is cumulative nominal telemetry, not a claim backed by BankLP funds.

Rename/document it as cumulative fees assessed or maintain separate accrued, paid, and retained values.

## Per-game assessment

| Game | Liability reserved | Main security observations |
|---|---|---|
| CoinFlip | Partial | Reserve undercounts gross payout with stop gain; zero-stop fee leakage; mutable BankLP |
| CoinFlipDoubleOrNothing | Yes, global | Reserve can be consumed by other games; migration can orphan reserve; maximum growth requires strict request-scoped accounting |
| FortuneWheel | Yes, global | Mutable config read at fulfillment; release occurs before deposit/payout; migration can orphan reserve |
| Dice | No | Up to 100 bets; zero-stop fee leakage; no concurrent liability backing |
| Keno | No | Up to 100,000x and five bets; one accepted jackpot can exceed bankroll many times |
| Slots | No | Unprocessed-row overpayment remediated; 100 bets, rows, bonus rounds, and worst-case liability remain unreserved |
| Blackjack | No | Current source uses asynchronous VRF dealer play; deployed legacy version remains critically vulnerable to selective reverts; no payout reserve |
| Mines | No | Multi-step growing cashout; no reserve; later reveals use current BankLP |
| Plinko | No | Owner-supplied one-time multipliers; zero-stop fee leakage; no reserve |
| VideoPoker | No | Up to 50x in code; paytable/test mismatch; multi-step request; no reserve |
| RockPaperScissors | No | Up to 100 bets; zero-stop fee leakage; no reserve |
| Rug | No | Effectively duplicate batch coin flip despite misleading contract description; zero-stop leakage |
| AmericanRoulette | No | Worst-case payout is calculated but not reserved |
| EuropeanRoulette | No | Implements 38-slot American wheel; zero-stop leakage |
| Crash Escrow | No | Signed liabilities can exceed bankroll; concurrent escrows overcommit; replacement forfeits prior escrow state |
| OCG GameLedger | No | Cumulative settlement uncapped; weak bet signature scope; cancellation fee loss; pending claims unreserved |
| Lottery | Local prize pool | BankLP receives only house cut; permissionless round creation can block usable rounds |

## Additional observations

### Reserve-aware games release before payout

CoinFlip, FortuneWheel, and DoubleOrNothing release their reserve before completing the deposit/payout sequence. Reverts roll back the transaction, but callbacks during fee transfers or token operations can observe the temporarily unreserved state. Request-scoped liability consumption should replace release-then-pay.

### LP accounting depends on incomplete liabilities

VaultLP and VaultLP2 use BankLP's current balance/reserve state for shares and withdrawals. Because most game liabilities and OCG pending withdrawals are absent from `reservedFunds`, reported available assets can be overstated. VaultLP2 also values current assets as:

```text
getAvailableBalance(token) + reservedFunds(token)
```

at `contracts/bankroll/facets/VaultLP2.sol:657-665`, which treats recorded reserves as LP assets without identifying the claims against them.

### Administrative centralization

BankLP owner and registry can execute arbitrary asset calls, and game owners can immediately redirect registries or change risk configuration. Production deployment should use multisig/timelock controls, explicit emergency procedures, and monitored role-change events.

## Test and build assessment

### Compiler baseline

The default Forge configuration cannot compile the suite because:

```text
contracts/bankroll/facets/VaultLP2.sol:721: stack too deep
```

`forge test --via-ir` compiles successfully.

### Existing suite result

Command:

```bash
forge test --via-ir
```

Result:

```text
107 tests total
94 passed
13 failed
```

Relevant failures:

- 11 `VideoPokerAudit` paytable expectation failures.
- `VideoPokerReplacementUniqueness` cannot call the VRF callback because its harness is not the configured coordinator.
- One unrelated `PredictionMarket` assertion failure.

### Material coverage gaps

No existing tests cover:

- A malicious approved game draining BankLP.
- One game paying from another game's reserve.
- Concurrent cross-game solvency.
- Registry activation while a wager is open.
- Migration of outstanding reserves or pending withdrawals.
- BankrollMigrator end-to-end ownership restoration.
- Keno maximum jackpot liability.
- Slots rows, bonus rounds, and zero-stop overpayment.
- OCG cumulative settlement, cancellation fees, or pending claims.
- Crash maximum signed liability and concurrent escrows.
- Fee-on-transfer/rebasing/nonstandard tokens.
- Deployment postcondition checks.

## Required security invariants

The remediation should be considered incomplete until stateful tests prove:

1. For every token, BankLP assets are at least the sum of all enforceable liabilities.
2. A game can consume or release only its own identified liability.
3. A payout cannot exceed the remaining liability for its wager/request.
4. LP and administrative withdrawals cannot reduce backing below liabilities.
5. Every accepted wager is pinned to one BankLP for its entire lifecycle.
6. Every terminal path consumes, releases, refunds, or converts a liability exactly once.
7. Configuration changes cannot alter already accepted wager economics.
8. Failed transfers preserve a claim backed by the same liability.
9. Batch stop logic never refunds more unplayed stake than was collected.
10. Migration cannot activate the new BankLP until ownership, assets, liabilities, games, and tokens are verified.

## Prioritized remediation roadmap

### Immediate containment

1. Disable the deployed legacy Blackjack address immediately and migrate users to the asynchronous VRF implementation.
2. Deploy the H-03 Slots correction before re-enabling multi-row configurations.
3. Do not run `DeployBankrollRegistry.s.sol` migration flow.
4. Pause or cap Keno, Crash coin-flip config, and OCG until liabilities are enforceably reserved.
5. Reject zero stop limits at the API boundary until all batch games implement disabled-threshold semantics.
6. Confirm current BankLP game approvals and remove unused or legacy game approvals.

### Core redesign

1. Introduce request-scoped liability records in BankLP.
2. Make payout consume the matching liability.
3. Pin every wager/round/escrow to its accepting BankLP.
4. Require every game to reserve strict worst-case gross payout before accepting the wager.
5. Include pending withdrawals and cancellation refunds in the same liability system.

### Game corrections

1. Fix Slots unprocessed-bet accounting.
2. Correct CoinFlip gross reserve calculation.
3. Correct European roulette to 37 outcomes.
4. Add cumulative OCG settlement state and complete EIP-712 authorization.
5. Correct Crash hard payout caps.
6. Restrict Lottery round creation.
7. Resolve the VideoPoker paytable specification.

### Deployment and operations

1. Replace the migration helper and test it against deployed ownership/governance roles.
2. Add machine-verifiable deployment assertions.
3. Enable `via_ir` or refactor VaultLP2 so the canonical build works without an undocumented flag.
4. Add monitoring for liabilities, available assets, failed payouts, role changes, and migrations.

## Final assessment

The primary risk is architectural rather than isolated to one game: BankLP does not know which obligations it has accepted or which game owns them. Point-in-time Kelly checks are not a substitute for enforceable liabilities, especially with asynchronous VRF settlement, concurrent games, LP withdrawals, and mutable bankroll routing.

Fixing individual payout formulas without redesigning liability ownership would leave the shared-bankroll failure mode intact.
