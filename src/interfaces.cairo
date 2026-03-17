use starknet::ContractAddress;

#[derive(Drop, Serde)]
pub struct WeekStats {
    pub current_week: u64,
    pub weekly_budget: u256,
    pub week_distributed: u256,
    pub total_distributed: u256,
    pub remaining: u256,
}

#[starknet::interface]
pub trait IRewardPool<TContractState> {
    // ── Admin writes ──────────────────────────────────────────────
    /// Start a new week: transfers `amount` WBTC from caller, resets weekly counters.
    fn fund_week(ref self: TContractState, amount: u256);

    /// Add bonus budget to the current week (no reset).
    fn top_up(ref self: TContractState, amount: u256);

    /// Batch-distribute rewards to winners. `distribution_id` must be unique (idempotency key).
    fn distribute(
        ref self: TContractState,
        distribution_id: felt252,
        recipients: Array<ContractAddress>,
        amounts: Array<u256>,
    );

    /// Update the safety cap (basis points of weekly_budget per single distribute call).
    fn set_max_distribution_bps(ref self: TContractState, bps: u16);

    // ── Public views ──────────────────────────────────────────────
    fn get_stats(self: @TContractState) -> WeekStats;
    fn get_remaining(self: @TContractState) -> u256;
    fn get_token(self: @TContractState) -> ContractAddress;
    fn is_distributed(self: @TContractState, distribution_id: felt252) -> bool;
}
