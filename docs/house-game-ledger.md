# House game ledger

`HouseGameLedger` is the bankroll-facing settlement boundary for house games
whose results are produced by background operators. It does not validate game
outcomes; it limits trusted operators with signed reservations, immutable round
bindings, signed maximum payouts, and final settlement.

## Flow

1. The backend validates whether a game is enabled, applies wager limits, and
   computes the theoretical maximum gross payout for every round.
2. Direct-funded play uses `reserveBatch`: the player submits one reservation
   per `roundKey` with an operator signature. The signature binds the player,
   token, game ID, wager, maximum payout, full ordered batch, deadline, chain
   ID, and ledger address.
3. Instant play grants a short-lived, tightly scoped session signer permission
   to call `reserveBatch` through the player's smart account. Native and ERC-20
   wager principal therefore always comes from the smart account, while the
   operator covers transaction gas and no wallet prompt is required
   for each play.
4. ERC-20-only managed play can instead use
   `reserveBatchFor(address token,address[] players,Reservation[] reservations)`.
   An authorized operator submits the batch without a signature or deadline,
   but each explicit player funds their aligned reservation through an ERC-20
   allowance to the ledger. Native token reservations are rejected, so the
   operator pays gas only and never supplies wager principal.
5. Funds are deposited into the current registry bankroll. The declared
   maximum payout is reserved in that bankroll.
6. Before outcomes are put in calldata, the operator calls
   `initiateSettlementBatch` with the round keys, their already-derived
   settlement action keys, and an expiry. This outcome-free transaction blocks
   player cancellation for 1–30 minutes. A round can only be initiated once,
   so an operator cannot keep renewing a stale lock.
7. After initiation confirms, the operator calls `settleBatch`. Every item must explicitly set
   `finalClose`, `actualWager <= reservation`, and `grossPlayerReturn` must
   include all unused reservation:

   `grossPlayerReturn >= reservation - actualWager`

   The return is also bounded by the immutable maximum payout signed during
   reservation. Closed/cancelled rounds cannot be changed.
8. Failed bankroll payouts become player-claimable pending payouts. Their
   funds remain reserved at the original bankroll until `claimPending`
   succeeds.

Every reserve, settle, and cancel action uses a globally replay-protected
`actionKey`. `getRound` and `getRoundStatus` expose explicit round state.
Backend game-policy changes affect only future reservations because each
accepted round retains its signed maximum payout and bankroll binding.

Players can force-cancel after `refundDelay`, except while a confirmed
settlement lock is active. Once a lock expires, it cannot be renewed and the
player can recover normally. The refund delay has an on-chain minimum of five
minutes. Operators/admins can cancel earlier for recovery. Pausing blocks new
reservations but deliberately leaves initiation, settlement, cancellation,
and pending claims available.

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
export HOUSE_LEDGER_OPERATOR=0xca03484cD1b8E7a0144de88d8C34970B19bAf294
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

Each active backend deployment currently uses one
`HOUSE_GAME_OPERATOR_PRIVATE_KEY`. Its derived address must be enabled with
`setOperator`. Multiple authorized addresses are useful for key rotation,
separate environments, or independent worker deployments; operators must not
share private keys.

Broadcast only after separately registering the deployed ledger as an approved
game in the target bankroll. Individual house games do not require on-chain
configuration; their enablement and risk rules are backend-owned. The script
does not alter existing deployments or addresses.
