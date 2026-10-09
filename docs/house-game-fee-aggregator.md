# House game fee aggregator

`HouseGameFeeAggregator` provides one contract read for all registered house games:

```solidity
function getHouseGameFees(address token)
    external
    view
    returns (uint256 totalFees, GameFee[] memory gameFees);
```

Each `GameFee` contains:

- `name`: display name
- `game`: game contract address
- `fees`: current `VRFFees(token)` balance
- `readable`: `false` when the address has no compatible contract or its read reverted

`totalFees` is the sum of readable entries. These are current, unwithdrawn VRF fees; fees already removed through `transferFees` cannot be recovered from current contract state.

Deploy with the addresses in the active environment:

```bash
set -a
source .env.mainnet.arbitrum
set +a
forge script script/DeployHouseGameFeeAggregator.s.sol:DeployHouseGameFeeAggregator \
  --rpc-url "$RPC_URL" \
  --via-ir \
  --optimize \
  --broadcast
```

Example viem read:

```ts
const [totalFees, games] = await publicClient.readContract({
  address: aggregatorAddress,
  abi: aggregatorAbi,
  functionName: "getHouseGameFees",
  args: [usdcAddress],
});
```

The owner can replace the complete registry with `replaceGames` or update one entry with `updateGame`.
