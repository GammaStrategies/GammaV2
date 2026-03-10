#!/bin/bash

# Script to verify already-deployed libraries
# Usage: ./script/VerifyLibraries.sh <CHAIN_ID> <RPC_URL> [ETHERSCAN_API_KEY]
# Or set ETHERSCAN_API_KEY in the environment.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

CHAIN_ID=${1:-130}
RPC_URL=${2:-"https://0xrpc.io/uni"}
ETHERSCAN_API_KEY=${3:-${ETHERSCAN_API_KEY:-}}
VERIFIER_URL="https://api.etherscan.io/v2/api?chainId=${CHAIN_ID}"

if [ -z "$ETHERSCAN_API_KEY" ]; then
    echo -e "${RED}Error: ETHERSCAN_API_KEY must be provided as arg 3 or environment variable${NC}"
    exit 1
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Library Verification Script${NC}"
echo -e "${GREEN}========================================${NC}"
echo "Chain ID: $CHAIN_ID"
echo "RPC URL: $RPC_URL"
echo ""

# Find the latest deployment file
BROADCAST_DIR="broadcast/DeployInfrastructure.s.sol/$CHAIN_ID"
if [ ! -d "$BROADCAST_DIR" ]; then
    echo -e "${RED}Error: No deployment found for chain $CHAIN_ID${NC}"
    echo "Looking for: $BROADCAST_DIR"
    exit 1
fi

LATEST_RUN=$(ls -t "$BROADCAST_DIR"/run-*.json | head -1)
echo -e "${YELLOW}Using deployment file: $LATEST_RUN${NC}"
echo ""

# Extract library addresses using grep and sed
echo -e "${GREEN}Extracting library addresses...${NC}"

# Libraries to find (in their deployment order)
declare -A LIBRARIES
LIBRARIES["SimpleLensInMin"]="src/MultiPositionManager/libraries/SimpleLens/SimpleLensInMin.sol:SimpleLensInMin"
LIBRARIES["SimpleLensRatioUtils"]="src/MultiPositionManager/libraries/SimpleLens/SimpleLensRatioUtils.sol:SimpleLensRatioUtils"
LIBRARIES["PoolManagerUtils"]="src/MultiPositionManager/libraries/PoolManagerUtils.sol:PoolManagerUtils"
LIBRARIES["DepositLogic"]="src/MultiPositionManager/libraries/DepositLogic.sol:DepositLogic"
LIBRARIES["PositionLogic"]="src/MultiPositionManager/libraries/PositionLogic.sol:PositionLogic"
LIBRARIES["RebalanceLogic"]="src/MultiPositionManager/libraries/RebalanceLogic.sol:RebalanceLogic"
LIBRARIES["WithdrawLogic"]="src/MultiPositionManager/libraries/WithdrawLogic.sol:WithdrawLogic"

# Extract addresses from JSON
declare -A ADDRESSES

for lib_name in "${!LIBRARIES[@]}"; do
    # Extract address for this library from JSON
    # contractName and contractAddress are on separate lines in the JSON
    address=$(grep -A 1 "\"contractName\": \"$lib_name\"" "$LATEST_RUN" | \
              grep "contractAddress" | \
              sed 's/.*"contractAddress": "\(0x[^"]*\)".*/\1/' | head -1)

    if [ -n "$address" ]; then
        ADDRESSES[$lib_name]=$address
        echo -e "${GREEN}✓${NC} Found $lib_name: $address"
    else
        echo -e "${YELLOW}⚠${NC} $lib_name not found in deployment"
    fi
done

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Starting Verification${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Verify each library
VERIFIED=0
FAILED=0
SKIPPED=0

for lib_name in "${!ADDRESSES[@]}"; do
    address=${ADDRESSES[$lib_name]}
    contract_path=${LIBRARIES[$lib_name]}

    echo -e "${YELLOW}Verifying $lib_name at $address...${NC}"

    # Execute verification with Etherscan v2 API
    if forge verify-contract \
        "$address" \
        "$contract_path" \
        --chain-id "$CHAIN_ID" \
        --rpc-url "$RPC_URL" \
        --verifier-url "$VERIFIER_URL" \
        --etherscan-api-key "$ETHERSCAN_API_KEY"; then
        echo -e "${GREEN}✓ Successfully verified $lib_name${NC}"
        ((VERIFIED++))
    else
        echo -e "${RED}✗ Failed to verify $lib_name${NC}"
        ((FAILED++))
    fi
    echo ""
done

# Print summary
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Verification Summary${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Verified: $VERIFIED${NC}"
echo -e "${RED}Failed: $FAILED${NC}"
echo -e "${YELLOW}Skipped: $SKIPPED${NC}"
echo -e "${GREEN}========================================${NC}"

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All libraries verified successfully!${NC}"
    exit 0
else
    echo -e "${RED}Some libraries failed verification${NC}"
    exit 1
fi
