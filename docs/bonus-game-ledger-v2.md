# OCG Bonus Game Ledger V2

`OCGBonusGameLedgerV2` preserves the deployed ledger's immediate wager and
settlement entrypoints while adding reservation accounting. The bonus token can
authorize only one ledger, so rollout must:

1. deploy V2 and configure OCG bet/settlement operator wallets;
2. pause submissions to V1 and drain open V1 rounds;
3. call `OCGBonus1155.setBonusGameLedger(v2)`;
4. set `BONUS_GAME_LEDGER_V2_ADDRESS` (and, after migration,
   `BONUS_GAME_LEDGER_ADDRESS`) in OCG.

Interactive rounds reserve by burning the maximum exposure with zero wagering
contribution. Each base/split/double/side-bet consume action temporarily credits
then re-debits its slice, leaving the lock unchanged while recording only actual
wager contribution. Release credits unused reserve. Settlement is final and is
allowed only when the full reserve is consumed or released.

Cancellation is restricted to rounds with zero consumed wager. Once any amount
has contributed to wagering progress, the round must be completed through
release plus settlement; cancellation cannot restore the consumed amount and
leave its wagering credit behind.

Each round snapshots the configured bonus contract when it is first opened.
Rotating `bonusContract` affects only new rounds; consume, release, settlement,
and cancellation always call the snapshotted contract. V2 is not deployed or
upgradeable in this repository, so the snapshot is appended directly to the
`BonusRound` struct and exposed as the final field of `rounds(bytes32)`.

Casino-backend never receives an operator role or submits ledger transactions.

## Operator administration

Combined bet and settlement access uses:

```solidity
setOperator(address operator, bool allowed)
setOperators(address[] operators, bool[] allowed)
```

Role-specific access uses the same boolean pattern through `setBetOperator`,
`setBetOperators`, `setSettleOperator`, and `setSettleOperators`. Batch calls
require one boolean per address. The ledger exposes no separate add or remove
operator functions.

Administrative access uses `setAdmin(address,bool)` and
`setAdmins(address[],bool[])`.

## Required payout cap

Deployments must set `maxPayoutMultiplierX` to at least the largest enabled
theoretical game payout. The repository deployment script requires
`BONUS_LEDGER_MAX_PAYOUT_MULTIPLIER_X >= 100000`, covering the current
100,000x Keno table and therefore classic Crash's required 10,000x maximum.
This value uses integer **X** units (`10000` means 10,000x), not basis points.
Backend creation still validates every game configuration
against the live ledger value; the deployment setting is not the only guard.
