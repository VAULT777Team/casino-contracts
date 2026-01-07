if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
else
    echo "Warning: .env file not found"
fi

# Default values (will be overridden by .env if present)
PRIVATE_KEY="${PRIVATE_KEY:-}"
RPC_URL="${RPC_URL:-https://arb-sepolia.g.alchemy.com/v2/}"
CHAIN_ID="${CHAIN_ID:-421614}"
GAS_LIMIT="${GAS_LIMIT:-500000000}"

# CONTRACT ADDRESSES
PLINKO_ADDRESS="${PLINKO_ADDRESS:-}"
SLOTS_ADDRESS="${SLOTS_ADDRESS:-}"

#CONFIGS
#SLOTS
#"[5,3,3,3,3,3,3,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,10,10,12,12,20,20,45,100]" "[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,114,117,171,173,228,229,285,342]" 343
#MINE_CONFIG="[24, 21, 17, 14, 12, 10, 9, 8, 7, 6, 5, 5, 4, 4, 3, 3, 3, 2, 2, 2, 2, 1, 1, 1]"

# Set Plinko multipliers for different risk levels

# ---------- LOW RISK (0) ----------
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[2050, 400, 90, 60, 40, 60, 90, 400, 2050]' 8 0 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[4500, 800, 90, 60, 40, 40, 60, 90, 800, 4500]' 9 0 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[4700, 800, 200, 90, 60, 40, 60, 90, 200, 800, 4700]' 10 0 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[6500, 1700, 400, 90, 60, 40, 40, 60, 90, 400, 1700, 6500]' 11 0 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[7000, 1600, 300, 200, 90, 60, 40, 60, 90, 200, 300, 1600, 7000]' 12 0 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[8000, 1700, 600, 400, 90, 60, 40, 40, 60, 90, 400, 600, 1700, 8000]' 13 0 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[10000, 4500, 900, 300, 110, 90, 60, 40, 60, 90, 110, 300, 900, 4500, 10000]' 14 0 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[11000, 4500, 1300, 900, 110, 90, 60, 40, 40, 60, 90, 110, 900, 1300, 4500, 11000]' 15 0 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[12000, 2800, 2400, 800, 200, 90, 90, 60, 40, 60, 90, 90, 200, 800, 2400, 2800, 12000]' 16 0 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv

# ---------- MEDIUM RISK (1) ----------
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[5000, 400, 50, 40, 20, 40, 50, 400, 5000]' 8 1 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[6600, 1200, 50, 40, 20, 20, 40, 50, 1200, 6600]' 9 1 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[9500, 1000, 200, 90, 40, 20, 40, 90, 200, 1000, 9500]' 10 1 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[15000, 2000, 500, 60, 50, 20, 20, 50, 60, 500, 2000, 15000]' 11 1 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[17500, 3500, 400, 200, 60, 40, 20, 40, 60, 200, 400, 3500, 17500]' 12 1 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[25000, 4400, 700, 400, 90, 40, 20, 20, 40, 90, 400, 700, 4400, 25000]' 13 1 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[39000, 5500, 1500, 400, 90, 80, 40, 20, 40, 80, 90, 400, 1500, 5500, 39000]' 14 1 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[50000, 6000, 2200, 800, 200, 90, 40, 20, 20, 40, 90, 200, 800, 2200, 6000, 50000]' 15 1 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[52000, 8000, 1500, 1000, 300, 200, 50, 30, 20, 30, 50, 200, 300, 1000, 1500, 8000, 52000]' 16 1 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv

# ---------- HIGH RISK (2) ----------
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[10000, 60, 20, 20, 10, 20, 20, 60, 10000]' 8 2 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[14300, 500, 70, 30, 10, 10, 30, 70, 500, 14300]' 9 2 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[17000, 1500, 200, 30, 20, 10, 20, 30, 200, 1500, 17000]' 10 2 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[29000, 1500, 200, 80, 50, 30, 30, 50, 80, 200, 1500, 29000]' 11 2 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[38000, 2000, 400, 200, 80, 30, 10, 30, 80, 200, 400, 2000, 38000]' 12 2 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[50000, 6800, 700, 200, 90, 40, 20, 20, 40, 90, 200, 700, 6800, 50000]' 13 2 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[77000, 6500, 1300, 300, 200, 50, 30, 10, 30, 50, 200, 300, 1300, 6500, 77000]' 14 2 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[80000, 20000, 5000, 500, 80, 50, 30, 10, 10, 30, 50, 80, 500, 5000, 20000, 80000]' 15 2 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv
cast send $PLINKO_ADDRESS "setPlinkoMultipliers(uint256[], uint8, uint8)" '[100000, 28000, 3000, 1500, 150, 60, 50, 40, 10, 40, 50, 60, 150, 1500, 3000, 28000, 100000]' 16 2 --chain $CHAIN_ID --private-key $PRIVATE_KEY --rpc-url $RPC_URL --gas-limit $GAS_LIMIT -vv