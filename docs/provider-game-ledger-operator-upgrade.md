# Provider GameLedger operator revocation

`GameLedgerV3` now exposes the authoritative operator-management methods:

```solidity
setOperator(address operator, bool enabled)
setOperators(address[] operators, bool[] enabled)
```

Passing `true` authorizes an operator and passing `false` revokes it. Batch
calls provide one boolean for each operator. Both forms emit
`OperatorUpdated(operator, enabled)`. New deployments do not expose separate
add or remove methods; all operator changes use the boolean setters.

Administrative access follows the same convention through
`setAdmin(address,bool)` and `setAdmins(address[],bool[])`.

## New deployments

Deploy `GameLedgerV3` with the required initial operator and current
`BankrollRegistry`, authorize the ledger in the active `BankLP`, then manage
every operator through the boolean method. The repository does not perform a
deployment automatically.

The owner can update operators with:

```bash
GAME_LEDGER_V3_ADDRESS=0x... \
RPC_URL=https://... \
PRIVATE_KEY=... \
./script/set_game_ledger_v3_operators.sh --enable 0xOperator

GAME_LEDGER_V3_ADDRESS=0x... \
RPC_URL=https://... \
PRIVATE_KEY=... \
./script/set_game_ledger_v3_operators.sh --disable 0xOperator
```

For production, the owner should be the configured Safe and the same
`setOperator(address,bool)` calldata should be proposed through the Safe
instead of supplying a private key to this helper.

## Existing deployment upgrade path

`GameLedgerV3` is not a proxy, so an existing deployment cannot gain the new
function in place. Do not submit boolean-method Safe proposals to an old
deployment and do not revoke an operator that still owns queued or submitted
work.

1. Disable new provider jobs and drain all jobs assigned to the old ledger.
2. Settle or cancel its open rounds. Keep the old ledger reachable for any
   outstanding pending-withdrawal claims.
3. Deploy the updated `GameLedgerV3` with the same active
   `BankrollRegistry`. No deployment is performed by this repository change.
4. Authorize the replacement ledger in `BankLP` with `setGame(newLedger,
   true)` and configure its operators with `setOperator(operator, true)`.
5. Update each worker/network ledger address, restart workers, and verify
   `isOperator` plus a controlled provider transaction against the replacement.
6. Only after all old-ledger work is drained, revoke old operators with the
   legacy `removeOperator(address)` method. Deauthorize the old ledger in
   `BankLP` only when no remaining claim or operational path requires it.
7. Enable destructive operator deletion in the control plane only after the
   target ledger supports the boolean method and on-chain `isOperator` is
   confirmed `false`.

This replacement cutover preserves the old contract for historical state and
claims while all new work uses the revocable operator interface.
