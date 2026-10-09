# Batch native funding

`BatchNativeFunder` lets a Safe or ordinary account fund multiple operator
addresses in one atomic transaction. The contract is permissionless because it
can distribute only the native currency attached by the current caller.

## Arbitrum One deployment

- Chain ID: `42161`
- Address: `0x0e9624A7Dcb6F968C5829817707A3545A93e31F5`

Equal splitting:

```solidity
splitNative(address payable[] recipients)
```

The complete `msg.value` is distributed. If the value is not evenly divisible,
the first recipients receive one additional wei until the remainder is
exhausted.

Explicit amounts:

```solidity
fundNative(address payable[] recipients, uint256[] amounts)
```

`msg.value` must exactly equal the sum of `amounts`. Both methods reject empty
batches, zero or duplicate recipients, and batches above 100 recipients. Any
failed transfer reverts the entire batch, and ordinary funding calls leave no
balance in the contract.

Deploy with:

```sh
forge script script/DeployBatchNativeFunder.s.sol:DeployBatchNativeFunder \
  --rpc-url "$RPC_URL" \
  --broadcast
```
