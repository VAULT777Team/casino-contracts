# Vault777 Bonus Game Ledger

`BonusGameLedger` preserves the deployed ledger's immediate wager and
settlement entrypoints while adding reservation accounting. The bonus token can
authorize only one ledger, so rollout must:

1. deploy the replacement ledger and configure Vault777 bet/settlement operator wallets;
2. pause submissions to V1 and drain open V1 rounds;
3. call `Bonus1155.setBonusGameLedger(newLedger)`;
4. set `BONUS_GAME_LEDGER_V2_ADDRESS` (and, after migration,
   `BONUS_GAME_LEDGER_ADDRESS`) in the Vault777 game services.

The replacement reports protocol version 3. Services must keep existing
protocol-v2 ledgers on the legacy reserve/consume/release/settle flow and use
`reserveAndSettleBatch` only after the configured on-chain ledger reports
version 3.

Interactive rounds reserve by burning the maximum exposure with zero wagering
contribution. Each base/split/double/side-bet consume action temporarily credits
then re-debits its slice, leaving the lock unchanged while recording only actual
wager contribution. Release credits unused reserve. Settlement is final and is
allowed only when the full reserve is consumed or released.

A settlement operator can cancel a round for operational recovery. Once
the round's snapshotted `refundAt` is reached, the round player can also call
`cancel`. Changing `cancelTimeframe` affects only later rounds. Cancellation
refunds the unreleased reservation and subtracts the exact wagering
contribution recorded for that round. Consume, release, and settlement all
revert at or after that deadline, so a result cannot be applied after the
player refund window opens. The ERC-1155 rollback remains available
after bonus expiry and while normal bonus activity is paused so a confirmed
permanent settlement failure cannot strand the player's balance or wagering
progress. `cancelTimeframe` cannot be configured below five minutes.

Each round snapshots the configured bonus contract when it is first opened.
Rotating `bonusContract` affects only new rounds; consume, release, settlement,
and cancellation always call the snapshotted contract. The contract and refund
deadline snapshots are appended directly to `BonusRound` and exposed by
`rounds(bytes32)`.

Casino-backend never receives an operator role or submits ledger transactions.
The OCG worker submits atomic plays from the bonus bet pool, and every wallet
eligible for atomic execution must also be authorized as a settlement operator.
The worker verifies both on-chain roles before broadcasting.

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

## Complete deployment

`script/DeployBonusSystem.s.sol` deploys a matched `Bonus1155` and
`BonusGameLedger`, configures the ledger payout cap, authorizes the ledger
inside the ERC-1155, installs the initial combined bet/settlement operator, and
transfers both contracts to the final owner.

Required environment:

- `PRIVATE_KEY`: temporary deployment/configuration signer.
- `BONUS_OWNER`: final owner, normally the production Safe.
- `BONUS_LEDGER_OPERATOR`: initial registry-managed bonus operator.
- `BANKLP_REGISTRY_ADDRESS`: active bankroll registry.
- `BONUS_BACKEND_SIGNER`: signer used for purchase and redemption
  authorizations.
- `BONUS_1155_URI`: ERC-1155 metadata URI.
- optional `BONUS_LEDGER_MAX_PAYOUT_MULTIPLIER_X`, default `100000` and never
  lower than `100000`.

Simulation:

```sh
forge script script/DeployBonusSystem.s.sol:DeployBonusSystem \
  --via-ir \
  --rpc-url "$RPC_URL"
```

Arbitrum deployment:

```sh
export PRIVATE_KEY=...
export BONUS_OWNER=0x...
export BONUS_LEDGER_OPERATOR=0x...
export BANKLP_REGISTRY_ADDRESS=0x...
export BONUS_BACKEND_SIGNER=0x...
export BONUS_1155_URI='https://hub.vault777.com/api/metadata/bonus/{id}.json'
export BONUS_LEDGER_MAX_PAYOUT_MULTIPLIER_X=100000

forge script script/DeployBonusSystem.s.sol:DeployBonusSystem \
  --via-ir \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --verify
```

After deployment, verify:

```sh
cast call "$BONUS_1155_ADDRESS" "owner()(address)" --rpc-url "$RPC_URL"
cast call "$BONUS_1155_ADDRESS" "bonusGameLedger()(address)" --rpc-url "$RPC_URL"
cast call "$BONUS_LEDGER_V2_ADDRESS" "owner()(address)" --rpc-url "$RPC_URL"
cast call "$BONUS_LEDGER_V2_ADDRESS" \
  "isBetOperator(address)(bool)" "$BONUS_LEDGER_OPERATOR" \
  --rpc-url "$RPC_URL"
cast call "$BONUS_LEDGER_V2_ADDRESS" \
  "isSettleOperator(address)(bool)" "$BONUS_LEDGER_OPERATOR" \
  --rpc-url "$RPC_URL"
cast call "$BONUS_LEDGER_V2_ADDRESS" \
  "maxPayoutMultiplierX()(uint256)" \
  --rpc-url "$RPC_URL"
```

The bonus ERC-1155 deposits purchase funds into the active bankroll, so
authorize `Bonus1155` with `BankLP.setGame(bonusAddress,true)` before
enabling purchases or redemptions. The ledger itself moves ERC-1155 balances
and does not need BankLP game authorization.

For replacement deployments, pause new V1/V2 admissions, drain or operator-
cancel open rounds on the old ledger, deploy the matched pair, update Vault777
service addresses, apply the game-service schema migration, and restart the bonus API and worker
together. Do not point an old ERC-1155 at the new ledger until the old ledger
has no rounds requiring settlement or cancellation.
