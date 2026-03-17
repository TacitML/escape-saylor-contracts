#[starknet::contract]
pub mod RewardPool {
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use starknet::storage::{
        StoragePointerReadAccess, StoragePointerWriteAccess, StoragePathEntry, Map,
    };
    use openzeppelin_interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin_access::ownable::OwnableComponent;
    use crate::interfaces::{IRewardPool, WeekStats};

    // ── Components ────────────────────────────────────────────────

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableMixinImpl = OwnableComponent::OwnableMixinImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    // ── Constants ─────────────────────────────────────────────────

    const BPS_DENOMINATOR: u256 = 10_000;
    const DEFAULT_MAX_BPS: u16 = 1_500; // 15% of weekly budget per single distribute

    // ── Storage ───────────────────────────────────────────────────

    #[storage]
    struct Storage {
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        /// WBTC token address on Starknet
        token: ContractAddress,
        /// Current week number (incremented on each fund_week)
        current_week: u64,
        /// Total budget allocated for the current week
        weekly_budget: u256,
        /// Amount already distributed this week
        week_distributed: u256,
        /// All-time total distributed
        total_distributed: u256,
        /// Max % of weekly_budget allowed per single distribute call (in bps)
        max_distribution_bps: u16,
        /// Idempotency: tracks processed distribution IDs
        processed_distributions: Map<felt252, bool>,
    }

    // ── Events ────────────────────────────────────────────────────

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        WeekFunded: WeekFunded,
        ToppedUp: ToppedUp,
        RewardsDistributed: RewardsDistributed,
        MaxDistributionBpsUpdated: MaxDistributionBpsUpdated,
    }

    #[derive(Drop, starknet::Event)]
    pub struct WeekFunded {
        #[key]
        pub week: u64,
        pub amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ToppedUp {
        #[key]
        pub week: u64,
        pub amount: u256,
        pub new_budget: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct RewardsDistributed {
        #[key]
        pub distribution_id: felt252,
        #[key]
        pub week: u64,
        pub total_amount: u256,
        pub recipient_count: u32,
    }

    #[derive(Drop, starknet::Event)]
    pub struct MaxDistributionBpsUpdated {
        pub old_bps: u16,
        pub new_bps: u16,
    }

    // ── Errors ────────────────────────────────────────────────────

    pub mod Errors {
        pub const ZERO_AMOUNT: felt252 = 'RP: amount is zero';
        pub const BUDGET_EXCEEDED: felt252 = 'RP: exceeds weekly budget';
        pub const SINGLE_TX_CAP: felt252 = 'RP: exceeds single tx cap';
        pub const ALREADY_DISTRIBUTED: felt252 = 'RP: already distributed';
        pub const LENGTH_MISMATCH: felt252 = 'RP: arrays length mismatch';
        pub const EMPTY_RECIPIENTS: felt252 = 'RP: empty recipients';
        pub const INVALID_BPS: felt252 = 'RP: bps exceeds 10000';
        pub const TRANSFER_FAILED: felt252 = 'RP: transfer failed';
    }

    // ── Constructor ───────────────────────────────────────────────

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, token: ContractAddress) {
        self.ownable.initializer(owner);
        self.token.write(token);
        self.max_distribution_bps.write(DEFAULT_MAX_BPS);
    }

    // ── External ──────────────────────────────────────────────────

    #[abi(embed_v0)]
    impl RewardPoolImpl of IRewardPool<ContractState> {
        fn fund_week(ref self: ContractState, amount: u256) {
            self.ownable.assert_only_owner();
            assert(amount > 0, Errors::ZERO_AMOUNT);

            // Pull WBTC from the caller (server account)
            let token = self._token_dispatcher();
            let success = token.transfer_from(get_caller_address(), get_contract_address(), amount);
            assert(success, Errors::TRANSFER_FAILED);

            // Advance week, reset counters
            let new_week = self.current_week.read() + 1;
            self.current_week.write(new_week);
            self.weekly_budget.write(amount);
            self.week_distributed.write(0);

            self.emit(WeekFunded { week: new_week, amount });
        }

        fn top_up(ref self: ContractState, amount: u256) {
            self.ownable.assert_only_owner();
            assert(amount > 0, Errors::ZERO_AMOUNT);

            let token = self._token_dispatcher();
            let success = token.transfer_from(get_caller_address(), get_contract_address(), amount);
            assert(success, Errors::TRANSFER_FAILED);

            let new_budget = self.weekly_budget.read() + amount;
            self.weekly_budget.write(new_budget);

            self
                .emit(
                    ToppedUp {
                        week: self.current_week.read(), amount, new_budget,
                    },
                );
        }

        fn distribute(
            ref self: ContractState,
            distribution_id: felt252,
            recipients: Array<ContractAddress>,
            amounts: Array<u256>,
        ) {
            self.ownable.assert_only_owner();

            // Idempotency check
            assert(
                !self.processed_distributions.entry(distribution_id).read(),
                Errors::ALREADY_DISTRIBUTED,
            );

            let len = recipients.len();
            assert(len > 0, Errors::EMPTY_RECIPIENTS);
            assert(len == amounts.len(), Errors::LENGTH_MISMATCH);

            // Sum all amounts
            let mut total: u256 = 0;
            let mut i: u32 = 0;
            while i < len {
                total += *amounts.at(i);
                i += 1;
            };

            assert(total > 0, Errors::ZERO_AMOUNT);

            // Safety cap: single tx can't exceed max_distribution_bps of weekly budget
            let budget = self.weekly_budget.read();
            let max_bps: u256 = self.max_distribution_bps.read().into();
            let cap = (budget * max_bps) / BPS_DENOMINATOR;
            assert(total <= cap, Errors::SINGLE_TX_CAP);

            // Budget check
            let new_week_distributed = self.week_distributed.read() + total;
            assert(new_week_distributed <= budget, Errors::BUDGET_EXCEEDED);

            // Mark as processed before transfers (CEI pattern)
            self.processed_distributions.entry(distribution_id).write(true);
            self.week_distributed.write(new_week_distributed);
            self.total_distributed.write(self.total_distributed.read() + total);

            // Execute transfers
            let token = self._token_dispatcher();
            let mut j: u32 = 0;
            while j < len {
                let amt = *amounts.at(j);
                if amt > 0 {
                    let success = token.transfer(*recipients.at(j), amt);
                    assert(success, Errors::TRANSFER_FAILED);
                }
                j += 1;
            };

            self
                .emit(
                    RewardsDistributed {
                        distribution_id,
                        week: self.current_week.read(),
                        total_amount: total,
                        recipient_count: len,
                    },
                );
        }

        fn set_max_distribution_bps(ref self: ContractState, bps: u16) {
            self.ownable.assert_only_owner();
            assert(bps <= 10_000, Errors::INVALID_BPS);

            let old = self.max_distribution_bps.read();
            self.max_distribution_bps.write(bps);

            self.emit(MaxDistributionBpsUpdated { old_bps: old, new_bps: bps });
        }

        // ── Views ─────────────────────────────────────────────────

        fn get_stats(self: @ContractState) -> WeekStats {
            let budget = self.weekly_budget.read();
            let distributed = self.week_distributed.read();
            WeekStats {
                current_week: self.current_week.read(),
                weekly_budget: budget,
                week_distributed: distributed,
                total_distributed: self.total_distributed.read(),
                remaining: budget - distributed,
            }
        }

        fn get_remaining(self: @ContractState) -> u256 {
            self.weekly_budget.read() - self.week_distributed.read()
        }

        fn get_token(self: @ContractState) -> ContractAddress {
            self.token.read()
        }

        fn is_distributed(self: @ContractState, distribution_id: felt252) -> bool {
            self.processed_distributions.entry(distribution_id).read()
        }
    }

    // ── Internals ─────────────────────────────────────────────────

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _token_dispatcher(self: @ContractState) -> IERC20Dispatcher {
            IERC20Dispatcher { contract_address: self.token.read() }
        }
    }
}
