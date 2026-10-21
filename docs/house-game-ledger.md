# House game ledger

`HouseGameLedger` is the bankroll-facing settlement boundary for house games
whose results are produced by background operators. It does not validate game
outcomes; it limits trusted operators with immutable round bindings, explicit
maximum payouts, and final settlement.

## Flow

1. The backend validates whether a game is enabled, applies wager limits, and
   computes the theoretical maximum gross payout for every round.
2. Reservations use
   `reserveBatchFor(address token,address[] players,Reservation[] reservations)`.
   An authorized operator submits the batch without a signature or deadline,
   but each explicit player funds their aligned reservation through an ERC-20
   allowance to the ledger. Native token reservations are rejected, so the
   operator pays gas only and never supplies wager principal.
3. Player funds remain escrowed in the ledger until settlement or cancellation.
   By default, the declared maximum payout is also reserved in the current
   registry bankroll. An owner-authorized admin can call
   `setBankrollReservationsEnabled(false)` to disable BankLP liquidity locking
   for future rounds. The immutable maximum payout remains enforced even when
   no BankLP funds are reserved.
4. The operator calls `settleBatch` directly with the deterministic settlement
   action key derived from each round key. Protocol V3 has no settlement
   initiation transaction. One-shot games may instead call
   `reserveAndSettleBatch` to reserve and close aligned rounds atomically.
   Every settlement item must explicitly set
   `finalClose`, `actualWager <= reservation`, and `grossPlayerReturn` must
   include all unused reservation:

   `grossPlayerReturn >= reservation - actualWager`

   Settlement batches aggregate actual-wager deposits, player refunds, payouts,
   and bankroll reserve releases by compatible account. The return remains
   bounded by the immutable maximum payout recorded during reservation.
   Closed/cancelled rounds cannot be changed.
5. Failed bankroll payouts become player-claimable pending payouts. Any
   liquidity reserved for that round remains reserved until `claimPending`
   succeeds. Unreserved rounds remain claimable without attempting to release
   funds that were never locked.

Reservation and cancellation actions use globally replay-protected action
keys. Settlement keys are deterministic from their round keys, and closed
round state prevents replay. `getRound` and `getRoundStatus` expose explicit
round state.
Backend game-policy changes affect only future reservations because each
accepted round retains its signed maximum payout and bankroll binding.

Authorized operators can cancel a round and return the full escrow when
settlement cannot complete. Each round snapshots `reservedAt + refundDelay` as its immutable `refundAt`.
Settlement is permitted only before that timestamp. At or after the exact
deadline, settlement reverts and the round player can call `refundRound`; the
deterministic refund action returns the escrow and releases any bankroll
reservation. Later admin changes affect only new rounds. Pausing
blocks new reservations but deliberately leaves settlement, cancellation,
player refunds, and pending claims available.

Bankroll reservation mode is snapshotted per round. Changing
`bankrollReservationsEnabled` affects only future reservations. Disabling it
removes BankLP withdrawal protection for outstanding maximum payouts, so an
otherwise valid settlement can become a pending payout when current liquidity
is insufficient.

## Deployment

The repository includes `script/DeployHouseGameLedger.s.sol`. It reads:

- `PRIVATE_KEY`
- `HOUSE_LEDGER_OWNER`
- `HOUSE_LEDGER_OPERATOR`
- `BANKLP_REGISTRY_ADDRESS`
- optional `HOUSE_LEDGER_REFUND_DELAY` (default: 10 minutes)

Example simulation:

```sh
forge script script/DeployHouseGameLedger.s.sol:DeployHouseGameLedger
```

Example Arbitrum deployment:

```sh
export HOUSE_LEDGER_OWNER=0x7C8986119c760C76312F6E23278ab9cA9a1c5b78
export HOUSE_LEDGER_OPERATOR=0xae40ab01fc898c92b9d27c19d92138cbc815c366
export BANKLP_REGISTRY_ADDRESS=0x54134cE9E35F44be3508462134Be41fA995709eb
export HOUSE_LEDGER_REFUND_DELAY=600

forge script script/DeployHouseGameLedger.s.sol:DeployHouseGameLedger \
  --via-ir \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --verify
```

The constructor installs one initial operator, but the ledger supports multiple
simultaneous operators. The owner or an address enabled with
`setAdmin(address,bool)` can update operators after deployment:

```sh
cast send "$HOUSE_GAME_LEDGER_ADDRESS" \
  "setOperator(address,bool)" "$ADDITIONAL_OPERATOR" true \
  --rpc-url "$RPC_URL" \
  --private-key "$OWNER_OR_ADMIN_PRIVATE_KEY"
```

Atomic mixed-state updates use `setOperators(address[],bool[])`. Owner-managed
admin updates use `setAdmin(address,bool)` and `setAdmins(address[],bool[])`.
Bankroll exposure locking for future rounds can be changed through:

```sh
cast send "$HOUSE_GAME_LEDGER_ADDRESS" \
  "setBankrollReservationsEnabled(bool)" false \
  --rpc-url "$RPC_URL" \
  --private-key "$OWNER_OR_ADMIN_PRIVATE_KEY"
```

Vault777 registry-backed reservation and settlement operator addresses must be
enabled with `setOperator`. Multiple authorized addresses provide independent
nonce domains, rotation capacity, and worker concurrency; operators must not
share private keys.

Broadcast only after separately registering the deployed ledger as an approved
game in the target bankroll. Individual house games do not require on-chain
configuration; their enablement and risk rules are backend-owned. The script
does not alter existing deployments or addresses.
