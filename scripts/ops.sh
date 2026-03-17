#!/usr/bin/env bash
set -euo pipefail

# ─── Load deployment config ───────────────────────────────────────
NETWORK="${NETWORK:-sepolia}"
DEPLOY_FILE="deployments/${NETWORK}.json"

if [ ! -f "$DEPLOY_FILE" ]; then
    echo "Error: No deployment found at $DEPLOY_FILE"
    echo "Run scripts/deploy.sh first."
    exit 1
fi

POOL_ADDRESS=$(jq -r '.reward_pool' "$DEPLOY_FILE")
WBTC_ADDRESS=$(jq -r '.wbtc_token' "$DEPLOY_FILE")

# ─── Helpers ───────────────────────────────────────────────────────
# Convert a decimal amount (in satoshis) to u256 calldata (low, high)
to_u256_calldata() {
    local amount=$1
    printf "0x%X 0x0" "$amount"
}

# ─── Commands ──────────────────────────────────────────────────────

case "${1:-help}" in

    stats)
        echo "Fetching RewardPool stats..."
        sncast --profile "$NETWORK" \
            call \
            --contract-address "$POOL_ADDRESS" \
            --function get_stats
        ;;

    remaining)
        echo "Fetching remaining budget..."
        sncast --profile "$NETWORK" \
            call \
            --contract-address "$POOL_ADDRESS" \
            --function get_remaining
        ;;

    approve)
        # Usage: ./ops.sh approve <amount_satoshis>
        AMOUNT=${2:?'Usage: ops.sh approve <amount_in_satoshis>'}
        CALLDATA=$(to_u256_calldata "$AMOUNT")
        echo "Approving $AMOUNT satoshis for RewardPool..."
        sncast --profile "$NETWORK" \
            invoke \
            --contract-address "$WBTC_ADDRESS" \
            --function approve \
            --calldata "$POOL_ADDRESS" $CALLDATA \
            --fee-token eth
        ;;

    fund-week)
        # Usage: ./ops.sh fund-week <amount_satoshis>
        AMOUNT=${2:?'Usage: ops.sh fund-week <amount_in_satoshis>'}
        CALLDATA=$(to_u256_calldata "$AMOUNT")
        echo "Funding new week with $AMOUNT satoshis..."
        echo "Step 1: Approve..."
        sncast --profile "$NETWORK" \
            invoke \
            --contract-address "$WBTC_ADDRESS" \
            --function approve \
            --calldata "$POOL_ADDRESS" $CALLDATA \
            --fee-token eth
        echo "Step 2: Fund week..."
        sncast --profile "$NETWORK" \
            invoke \
            --contract-address "$POOL_ADDRESS" \
            --function fund_week \
            --calldata $CALLDATA \
            --fee-token eth
        ;;

    top-up)
        # Usage: ./ops.sh top-up <amount_satoshis>
        AMOUNT=${2:?'Usage: ops.sh top-up <amount_in_satoshis>'}
        CALLDATA=$(to_u256_calldata "$AMOUNT")
        echo "Topping up current week with $AMOUNT satoshis..."
        echo "Step 1: Approve..."
        sncast --profile "$NETWORK" \
            invoke \
            --contract-address "$WBTC_ADDRESS" \
            --function approve \
            --calldata "$POOL_ADDRESS" $CALLDATA \
            --fee-token eth
        echo "Step 2: Top up..."
        sncast --profile "$NETWORK" \
            invoke \
            --contract-address "$POOL_ADDRESS" \
            --function top_up \
            --calldata $CALLDATA \
            --fee-token eth
        ;;

    is-distributed)
        # Usage: ./ops.sh is-distributed <distribution_id_felt>
        DIST_ID=${2:?'Usage: ops.sh is-distributed <distribution_id_felt>'}
        sncast --profile "$NETWORK" \
            call \
            --contract-address "$POOL_ADDRESS" \
            --function is_distributed \
            --calldata "$DIST_ID"
        ;;

    help|*)
        echo "RewardPool Operations — Network: $NETWORK"
        echo ""
        echo "Usage: NETWORK=sepolia|mainnet ./scripts/ops.sh <command> [args]"
        echo ""
        echo "Commands:"
        echo "  stats                          Get current week stats"
        echo "  remaining                      Get remaining budget"
        echo "  approve <satoshis>             Approve WBTC for pool"
        echo "  fund-week <satoshis>           Start new week (approve + fund)"
        echo "  top-up <satoshis>              Add bonus to current week"
        echo "  is-distributed <felt>          Check if distribution ID was processed"
        echo ""
        echo "Examples:"
        echo "  ./scripts/ops.sh stats"
        echo "  ./scripts/ops.sh fund-week 50000000          # 0.5 WBTC"
        echo "  ./scripts/ops.sh top-up 10000000             # 0.1 WBTC bonus"
        echo "  NETWORK=mainnet ./scripts/ops.sh stats"
        ;;
esac
