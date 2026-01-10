#!/usr/bin/env bash
set -euo pipefail

# Play CoinFlip through ERC-4337 v0.7 EntryPoint (Arbitrum Sepolia) using:
# CasinoAccount(sender) -> EntryPoint.handleOps(userOp)
#
# Requirements:
# - foundry (cast)
# - python3
# - funded bundler EOA (pays the L2 tx for handleOps)
# - session key enabled + CoinFlip allowedTarget on CasinoAccount
# - CasinoAccount has enough ETH balance for VALUE_WEI (forwarded value)
# - CasinoAccount has EntryPoint deposit for gas (DEPOSIT_WEI)
#
# Notes:
# - This script signs the userOpHash with the session key using EIP-191 (cast default)
#   because CasinoAccount does `toEthSignedMessageHash(userOpHash)`.

RPC_URL=${RPC_URL:-"https://sepolia-rollup.arbitrum.io/rpc"}
ENTRYPOINT=${ENTRYPOINT:-"0x0000000071727De22E5E9d8BAf0edAc6f37da032"}
ACCOUNT=${ACCOUNT:-"0x31dE08D2460484F5900C454fBEf7D5d7Caa34b32"}
COINFLIP=${COINFLIP:-"0xdaC233DACB0454560A2f314E766a3E61FD4353F0"}
SESSION_KEY=${SESSION_KEY:-"0x726230F9E1f3cbE6c45062bd3A41F5de63fEf0B1"}

# coinflip args (defaults copied from your earlier example)
WAGER_WEI=${WAGER_WEI:-"1000000000000000"}              # 0.001 ETH
REFERRAL=${REFERRAL:-"0x0000000000000000000000000000000000000000"}
IS_HEADS=${IS_HEADS:-"true"}
NUM_BETS=${NUM_BETS:-"1"}
STOP_GAIN=${STOP_GAIN:-"0"}
STOP_LOSS=${STOP_LOSS:-"0"}

# ETH value forwarded by CasinoAccount.execute
VALUE_WEI=${VALUE_WEI:-"1200000000000000"}              # 0.0012 ETH

# UserOp gas params (increase if you see AA23 reverted)
CALL_GAS=${CALL_GAS:-"2500000"}
VERIF_GAS=${VERIF_GAS:-"1500000"}
PREVERIF_GAS=${PREVERIF_GAS:-"200000"}
MAX_PRIORITY_FEE=${MAX_PRIORITY_FEE:-"100000000"}        # 0.1 gwei
MAX_FEE=${MAX_FEE:-"1000000000"}                         # 1 gwei

# EntryPoint deposit to add for ACCOUNT (gas payment). Set to 0 to skip.
DEPOSIT_WEI=${DEPOSIT_WEI:-"2000000000000000"}           # 0.002 ETH

# TX gas limit for the bundler EOA sending handleOps
HANDLEOPS_TX_GAS_LIMIT=${HANDLEOPS_TX_GAS_LIMIT:-"4000000"}

# Private keys (required)
: "${SESSION_PK:?Set SESSION_PK env var (private key for SESSION_KEY)}"
: "${BUNDLER_PK:?Set BUNDLER_PK env var (private key for funded EOA to send handleOps)}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }
}

need_cmd cast
need_cmd python3

banner() {
  echo "== $*" >&2
}

banner "Checking CasinoAccount config"
ALLOWED=$(cast call "$ACCOUNT" "allowedTargets(address)(bool)" "$COINFLIP" --rpc-url "$RPC_URL")
SESSION_ENABLED_AND_UNTIL=$(cast call "$ACCOUNT" "sessionKeys(address)(bool,uint48)" "$SESSION_KEY" --rpc-url "$RPC_URL")
BAL=$(cast balance "$ACCOUNT" --rpc-url "$RPC_URL")
echo "ACCOUNT=$ACCOUNT" >&2
echo "COINFLIP allowedTargets? $ALLOWED" >&2
echo "SESSION_KEY cfg: $SESSION_ENABLED_AND_UNTIL" >&2
echo "ACCOUNT balance: $BAL wei" >&2

if [[ "$ALLOWED" != "true" ]]; then
  echo "ERROR: CoinFlip is not an allowed target on CasinoAccount" >&2
  exit 1
fi

if [[ "$VALUE_WEI" -gt "$BAL" ]]; then
  echo "ERROR: CasinoAccount ETH balance ($BAL) < VALUE_WEI ($VALUE_WEI)" >&2
  exit 1
fi

banner "Optionally topping up EntryPoint deposit for account"
if [[ "$DEPOSIT_WEI" != "0" ]]; then
  # depositTo(account) payable
  cast send "$ENTRYPOINT" "depositTo(address)" "$ACCOUNT" \
    --rpc-url "$RPC_URL" --private-key "$BUNDLER_PK" --value "$DEPOSIT_WEI" >/dev/null
  echo "Deposited $DEPOSIT_WEI wei to EntryPoint for $ACCOUNT" >&2
else
  echo "Skipping depositTo (DEPOSIT_WEI=0)" >&2
fi

banner "Building CoinFlip calldata"
COINFLIP_DATA=$(cast calldata \
  "CoinFlip_Play(uint256,address,bool,uint32,uint256,uint256)" \
  "$WAGER_WEI" "$REFERRAL" "$IS_HEADS" "$NUM_BETS" "$STOP_GAIN" "$STOP_LOSS")

CALLDATA=$(cast calldata "execute(address,uint256,bytes)" "$COINFLIP" "$VALUE_WEI" "$COINFLIP_DATA")

banner "Fetching nonce"
NONCE=$(cast call "$ENTRYPOINT" "getNonce(address,uint192)(uint256)" "$ACCOUNT" 0 --rpc-url "$RPC_URL")
echo "nonce=$NONCE" >&2

banner "Packing gas fields"
ACCOUNT_GAS_LIMITS=$(python3 - <<PY
call_gas=int("$CALL_GAS")
verif_gas=int("$VERIF_GAS")
print("0x%064x" % ((verif_gas<<128) | call_gas))
PY
)

GAS_FEES=$(python3 - <<PY
max_priority=int("$MAX_PRIORITY_FEE")
max_fee=int("$MAX_FEE")
print("0x%064x" % ((max_priority<<128) | max_fee))
PY
)

echo "accountGasLimits=$ACCOUNT_GAS_LIMITS" >&2
echo "gasFees=$GAS_FEES" >&2

banner "Computing userOpHash"
USEROPHASH=$(cast call "$ENTRYPOINT" \
  "getUserOpHash((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes))(bytes32)" \
  "($ACCOUNT,$NONCE,0x,$CALLDATA,$ACCOUNT_GAS_LIMITS,$PREVERIF_GAS,$GAS_FEES,0x,0x)" \
  --rpc-url "$RPC_URL")

echo "userOpHash=$USEROPHASH" >&2

banner "Signing userOpHash with session key"
SIG=$(cast wallet sign --private-key "$SESSION_PK" "$USEROPHASH")
FULLSIG="0x01${SIG#0x}"

banner "Encoding handleOps"
BENEFICIARY=$(cast wallet address --private-key "$BUNDLER_PK")

echo "beneficiary=$BENEFICIARY" >&2

OPS="[($ACCOUNT,$NONCE,0x,$CALLDATA,$ACCOUNT_GAS_LIMITS,$PREVERIF_GAS,$GAS_FEES,0x,$FULLSIG)]"
HANDLEOPS_DATA=$(cast calldata \
  "handleOps((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes)[],address)" \
  "$OPS" "$BENEFICIARY")

banner "Sending handleOps tx"
cast send "$ENTRYPOINT" --rpc-url "$RPC_URL" --private-key "$BUNDLER_PK" \
"$HANDLEOPS_DATA" --gas-limit "$HANDLEOPS_TX_GAS_LIMIT"
