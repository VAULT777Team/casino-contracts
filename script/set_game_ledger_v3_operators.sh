#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GAME_LEDGER_V3_ADDRESS="${GAME_LEDGER_V3_ADDRESS:-${GAME_LEDGER_ADDRESS:-}}"
RPC_URL="${RPC_URL:-}"
PRIVATE_KEY="${PRIVATE_KEY:-}"

if [[ -z "${GAME_LEDGER_V3_ADDRESS}" ]]; then
    echo "GAME_LEDGER_V3_ADDRESS is required" >&2
    exit 1
fi

if [[ -z "${RPC_URL}" ]]; then
    echo "RPC_URL is required" >&2
    exit 1
fi

if [[ -z "${PRIVATE_KEY}" ]]; then
    echo "PRIVATE_KEY is required" >&2
    exit 1
fi

if (( $# == 0 )); then
    echo "Usage: $0 <operator-address> [operator-address ...]" >&2
    exit 1
fi

OPERATORS=("$@")
ADDRESS_PATTERN='^0x[0-9a-fA-F]{40}$'

if [[ ! "${GAME_LEDGER_V3_ADDRESS}" =~ ${ADDRESS_PATTERN} ]]; then
    echo "Invalid GameLedgerV3 address: ${GAME_LEDGER_V3_ADDRESS}" >&2
    exit 1
fi

for operator in "${OPERATORS[@]}"; do
    if [[ ! "${operator}" =~ ${ADDRESS_PATTERN} ]]; then
        echo "Invalid operator address: ${operator}" >&2
        exit 1
    fi
done

SENDER="$(cast wallet address --private-key "${PRIVATE_KEY}")"
OWNER="$(cast call \
    "${GAME_LEDGER_V3_ADDRESS}" \
    "owner()(address)" \
    --rpc-url "${RPC_URL}")"

if [[ "${SENDER,,}" != "${OWNER,,}" ]]; then
    echo "Signer ${SENDER} is not the GameLedgerV3 owner ${OWNER}" >&2
    exit 1
fi

OPERATORS_ARGUMENT="[$(IFS=,; echo "${OPERATORS[*]}")]"

echo "Adding ${#OPERATORS[@]} operator(s) to GameLedgerV3 ${GAME_LEDGER_V3_ADDRESS}"

CAST_ARGS=(
    "${GAME_LEDGER_V3_ADDRESS}"
    "setOperators(address[])"
    "${OPERATORS_ARGUMENT}"
    --private-key "${PRIVATE_KEY}"
    --rpc-url "${RPC_URL}"
)

if [[ -n "${CHAIN_ID:-}" ]]; then
    CAST_ARGS+=(--chain "${CHAIN_ID}")
fi

cast send "${CAST_ARGS[@]}"

for operator in "${OPERATORS[@]}"; do
    enabled="$(cast call \
        "${GAME_LEDGER_V3_ADDRESS}" \
        "isOperator(address)(bool)" \
        "${operator}" \
        --rpc-url "${RPC_URL}")"

    if [[ "${enabled}" != "true" ]]; then
        echo "Operator verification failed: ${operator}" >&2
        exit 1
    fi
done

echo "All operators are enabled."
