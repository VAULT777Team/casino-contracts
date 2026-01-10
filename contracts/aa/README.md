# ERC-4337 (Account Abstraction)

This folder contains a minimal ERC-4337 setup to support:
- **Users sign once** to set up a session key + USDC approval.
- **Backend forwards** future requests by signing `PackedUserOperation`s using the session key.
- **Pay gas in USDC** via a token paymaster that sponsors gas in ETH and charges the account in USDC.

## Contracts

- `CasinoAccount.sol`
  - Smart account with:
    - `execute()` / `executeBatch()` (restricted to `allowedTargets`)
    - `sessionKeys` (server-controlled key) that can sign UserOps after initial setup
    - Signature format: first byte = signature type
      - `0x00` owner signature
      - `0x01` session key signature (only allowed for `execute/executeBatch`)

- `USDCGasPaymaster.sol`
  - Minimal token paymaster (EntryPoint v0.6-style interface) that:
    - sponsors gas from its EntryPoint deposit
    - charges `userOp.sender` in USDC during `postOp`
    - uses Chainlink `ETH/USD` feed and assumes `USDC ~= $1`

## Suggested flow ("sign once")

1) Deploy `CasinoAccount(entryPoint, owner)`.
2) Owner performs one setup action (either a normal tx or a single UserOp signed by owner):
   - `CasinoAccount.setAllowedTarget(game, true)` for each game.
   - `CasinoAccount.setupSessionAndApprove(sessionKey, true, validUntil, USDC, paymaster, allowance)`
3) Backend holds `sessionKey` and for each API request:
  - builds a `PackedUserOperation` calling `CasinoAccount.execute(game, 0, calldata)`
   - sets `paymasterAndData` to use `USDCGasPaymaster`
   - signs the UserOp hash with the **session key** (signature type `0x01`)

## Notes

- The paymaster requires the account to have USDC balance and allowance.
- Pricing/markup in `USDCGasPaymaster` is intentionally minimal; production deployments typically:
  - add safety buffers,
  - enforce per-user limits,
  - validate allowed callData targets,
  - use robust oracle handling and replay protection,
  - support EntryPoint v0.7 (PackedUserOperation) if needed.
