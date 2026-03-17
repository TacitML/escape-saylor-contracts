# RewardPool — Escape Saylor Leaderboard Rewards

Smart contract for automated weekly/daily reward distribution on Starknet.

## Architecture

```
Server Account (treasury + fee receiver + signer)
        │
        │ fund_week() / top_up()
        ▼
  RewardPool Contract
        │
        │ distribute()
        ▼
  Player Wallets (passkey)
```

## Prerequisites

```bash
# Install Scarb (Cairo package manager)
curl --proto '=https' --tlsv1.2 -sSf https://docs.swmansion.com/scarb/install.sh | sh

# Install Starknet Foundry
curl -L https://raw.githubusercontent.com/foundry-rs/starknet-foundry/master/scripts/install.sh | sh
snfoundryup
```

## Build

```bash
scarb build
```

## Test

```bash
snforge test
```

## Deploy

```bash
# Sepolia (with auto mock WBTC)
OWNER=0x<your_server_account> ./scripts/deploy.sh

# Mainnet
NETWORK=mainnet \
OWNER=0x<your_server_account> \
WBTC_ADDRESS=0x<wbtc_on_starknet> \
./scripts/deploy.sh
```

## Operations

```bash
# Check stats
./scripts/ops.sh stats

# Fund a new week (0.5 WBTC = 50_000_000 sats)
./scripts/ops.sh fund-week 50000000

# Add bonus mid-week
./scripts/ops.sh top-up 10000000

# Check if a distribution was already processed
./scripts/ops.sh is-distributed 0x<felt>
```

## Contract API

| Function | Access | Description |
|----------|--------|-------------|
| `fund_week(amount)` | Owner | Pull WBTC, start new week, reset counters |
| `top_up(amount)` | Owner | Add to current week budget (no reset) |
| `distribute(id, recipients, amounts)` | Owner | Batch transfer to winners |
| `set_max_distribution_bps(bps)` | Owner | Safety cap per single tx |
| `get_stats()` | Public | Week, budget, distributed, remaining |
| `get_remaining()` | Public | Budget minus distributed |
| `is_distributed(id)` | Public | Idempotency check |

## Safety

- **Single-tx cap**: Default 15% of weekly budget per `distribute` call. Configurable via `set_max_distribution_bps`.
- **Idempotency**: Each `distribute` call requires a unique `distribution_id`. Replays are rejected.
- **CEI pattern**: State is updated before external calls to prevent reentrancy.
- **Budget enforcement**: `distribute` reverts if cumulative distributions exceed `weekly_budget`.
