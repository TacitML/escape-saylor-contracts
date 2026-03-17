#!/usr/bin/env bash
set -euo pipefail

# ─── Configuration ─────────────────────────────────────────────────
# Override these via environment variables or edit directly.

NETWORK="${NETWORK:-sepolia}"                          # sepolia | mainnet
OWNER="${OWNER:?'Set OWNER to the server account address'}"

# WBTC on Starknet addresses
# Sepolia: use a test ERC20 or deploy MockERC20
# Mainnet: actual WBTC bridge address
if [ "$NETWORK" = "mainnet" ]; then
    WBTC_ADDRESS="${WBTC_ADDRESS:?'Set WBTC_ADDRESS for mainnet'}"
else
    WBTC_ADDRESS="${WBTC_ADDRESS:-0x0}"  # Will deploy mock if 0x0
fi

echo "╔═══════════════════════════════════════════════╗"
echo "║       RewardPool Deployment — $NETWORK        "
echo "╠═══════════════════════════════════════════════╣"
echo "║  Owner:  $OWNER"
echo "║  WBTC:   $WBTC_ADDRESS"
echo "╚═══════════════════════════════════════════════╝"

# ─── Build ─────────────────────────────────────────────────────────
echo ""
echo "[1/4] Building contracts..."
scarb build

# ─── Deploy Mock ERC20 on testnet if needed ────────────────────────
if [ "$NETWORK" != "mainnet" ] && [ "$WBTC_ADDRESS" = "0x0" ]; then
    echo ""
    echo "[2/4] Deploying MockERC20 on $NETWORK..."

    MOCK_CLASS_HASH=$(sncast --profile "$NETWORK" \
        declare \
        --contract-name MockERC20 \
        --fee-token eth \
        2>&1 | grep "class_hash:" | awk '{print $2}')

    echo "  MockERC20 class hash: $MOCK_CLASS_HASH"

    # 1000 WBTC (8 decimals) = 100_000_000_000
    # u256 is serialized as two felt252: (low, high)
    INITIAL_SUPPLY_LOW="0x174876E800"  # 100_000_000_000
    INITIAL_SUPPLY_HIGH="0x0"

    MOCK_RESULT=$(sncast --profile "$NETWORK" \
        deploy \
        --class-hash "$MOCK_CLASS_HASH" \
        --constructor-calldata "$INITIAL_SUPPLY_LOW" "$INITIAL_SUPPLY_HIGH" "$OWNER" \
        --fee-token eth \
        2>&1)

    WBTC_ADDRESS=$(echo "$MOCK_RESULT" | grep "contract_address:" | awk '{print $2}')
    echo "  MockERC20 deployed at: $WBTC_ADDRESS"
else
    echo ""
    echo "[2/4] Using existing WBTC at $WBTC_ADDRESS"
fi

# ─── Declare RewardPool ───────────────────────────────────────────
echo ""
echo "[3/4] Declaring RewardPool..."

POOL_CLASS_HASH=$(sncast --profile "$NETWORK" \
    declare \
    --contract-name RewardPool \
    --fee-token eth \
    2>&1 | grep "class_hash:" | awk '{print $2}')

echo "  RewardPool class hash: $POOL_CLASS_HASH"

# ─── Deploy RewardPool ────────────────────────────────────────────
echo ""
echo "[4/4] Deploying RewardPool..."

POOL_RESULT=$(sncast --profile "$NETWORK" \
    deploy \
    --class-hash "$POOL_CLASS_HASH" \
    --constructor-calldata "$OWNER" "$WBTC_ADDRESS" \
    --fee-token eth \
    2>&1)

POOL_ADDRESS=$(echo "$POOL_RESULT" | grep "contract_address:" | awk '{print $2}')

echo ""
echo "═══════════════════════════════════════════════"
echo "  Deployment complete!"
echo "═══════════════════════════════════════════════"
echo ""
echo "  RewardPool:  $POOL_ADDRESS"
echo "  WBTC Token:  $WBTC_ADDRESS"
echo "  Owner:       $OWNER"
echo "  Network:     $NETWORK"
echo ""
echo "  Next steps:"
echo "    1. Approve the RewardPool to spend WBTC from the server account:"
echo "       sncast --profile $NETWORK invoke \\"
echo "         --contract-address $WBTC_ADDRESS \\"
echo "         --function approve \\"
echo "         --calldata $POOL_ADDRESS <AMOUNT_LOW> <AMOUNT_HIGH>"
echo ""
echo "    2. Fund the first week:"
echo "       sncast --profile $NETWORK invoke \\"
echo "         --contract-address $POOL_ADDRESS \\"
echo "         --function fund_week \\"
echo "         --calldata <AMOUNT_LOW> <AMOUNT_HIGH>"
echo ""

# ─── Save deployment info ─────────────────────────────────────────
DEPLOY_FILE="deployments/${NETWORK}.json"
mkdir -p deployments

cat > "$DEPLOY_FILE" << EOF
{
  "network": "$NETWORK",
  "reward_pool": "$POOL_ADDRESS",
  "reward_pool_class_hash": "$POOL_CLASS_HASH",
  "wbtc_token": "$WBTC_ADDRESS",
  "owner": "$OWNER",
  "deployed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "  Deployment info saved to $DEPLOY_FILE"
