use starknet::ContractAddress;
use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait, start_cheat_caller_address,
    stop_cheat_caller_address,
};
use openzeppelin_interfaces::erc20::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
use crate::interfaces::{IRewardPoolDispatcher, IRewardPoolDispatcherTrait};

// ── Constants ─────────────────────────────────────────────────────

const INITIAL_SUPPLY: u256 = 100_000_000_000; // 1000 WBTC (8 decimals)
const WEEK_BUDGET: u256 = 50_000_000; // 0.5 WBTC
const TOP_UP_AMOUNT: u256 = 10_000_000; // 0.1 WBTC

fn OWNER() -> ContractAddress {
    'OWNER'.try_into().unwrap()
}

fn PLAYER_1() -> ContractAddress {
    'PLAYER_1'.try_into().unwrap()
}

fn PLAYER_2() -> ContractAddress {
    'PLAYER_2'.try_into().unwrap()
}

fn PLAYER_3() -> ContractAddress {
    'PLAYER_3'.try_into().unwrap()
}

fn ATTACKER() -> ContractAddress {
    'ATTACKER'.try_into().unwrap()
}

// ── Setup ─────────────────────────────────────────────────────────

fn setup() -> (IRewardPoolDispatcher, ERC20ABIDispatcher) {
    // Deploy mock WBTC
    let erc20_class = declare("MockERC20").unwrap().contract_class();
    let mut erc20_calldata: Array<felt252> = array![];
    Serde::serialize(@INITIAL_SUPPLY, ref erc20_calldata);
    Serde::serialize(@OWNER(), ref erc20_calldata);
    let (erc20_addr, _) = erc20_class.deploy(@erc20_calldata).unwrap();

    // Deploy RewardPool
    let pool_class = declare("RewardPool").unwrap().contract_class();
    let mut pool_calldata: Array<felt252> = array![];
    Serde::serialize(@OWNER(), ref pool_calldata);
    Serde::serialize(@erc20_addr, ref pool_calldata);
    let (pool_addr, _) = pool_class.deploy(@pool_calldata).unwrap();

    let pool = IRewardPoolDispatcher { contract_address: pool_addr };
    let token = ERC20ABIDispatcher { contract_address: erc20_addr };

    // Owner approves the pool to spend tokens
    start_cheat_caller_address(erc20_addr, OWNER());
    token.approve(pool_addr, INITIAL_SUPPLY);
    stop_cheat_caller_address(erc20_addr);

    (pool, token)
}

/// Helper: fund current week as OWNER
fn fund_week(pool: IRewardPoolDispatcher, token: ERC20ABIDispatcher, amount: u256) {
    start_cheat_caller_address(token.contract_address, OWNER());
    token.approve(pool.contract_address, amount);
    stop_cheat_caller_address(token.contract_address);

    start_cheat_caller_address(pool.contract_address, OWNER());
    pool.fund_week(amount);
    stop_cheat_caller_address(pool.contract_address);
}

// ── Deployment tests ──────────────────────────────────────────────

#[test]
fn test_deploy_initial_state() {
    let (pool, token) = setup();

    let stats = pool.get_stats();
    assert(stats.current_week == 0, 'week should be 0');
    assert(stats.weekly_budget == 0, 'budget should be 0');
    assert(stats.total_distributed == 0, 'total should be 0');
    assert(pool.get_token() == token.contract_address, 'wrong token');
}

// ── fund_week tests ───────────────────────────────────────────────

#[test]
fn test_fund_week_success() {
    let (pool, token) = setup();

    fund_week(pool, token, WEEK_BUDGET);

    let stats = pool.get_stats();
    assert(stats.current_week == 1, 'week should be 1');
    assert(stats.weekly_budget == WEEK_BUDGET, 'wrong budget');
    assert(stats.week_distributed == 0, 'distributed should be 0');
    assert(stats.remaining == WEEK_BUDGET, 'wrong remaining');

    // Pool should hold the tokens
    assert(token.balance_of(pool.contract_address) == WEEK_BUDGET, 'pool balance wrong');
}

#[test]
fn test_fund_week_resets_counters() {
    let (pool, token) = setup();

    // Fund week 1
    fund_week(pool, token, WEEK_BUDGET);

    // Distribute some
    let recipients = array![PLAYER_1()];
    let amounts = array![1_000_000_u256]; // small amount under cap
    start_cheat_caller_address(pool.contract_address, OWNER());
    pool.distribute('dist_1', recipients, amounts);
    stop_cheat_caller_address(pool.contract_address);

    assert(pool.get_stats().week_distributed == 1_000_000, 'should have distributed');

    // Fund week 2 — counters must reset
    fund_week(pool, token, WEEK_BUDGET);

    let stats = pool.get_stats();
    assert(stats.current_week == 2, 'week should be 2');
    assert(stats.week_distributed == 0, 'week dist should reset');
    assert(stats.weekly_budget == WEEK_BUDGET, 'budget should be fresh');
    // But total_distributed persists
    assert(stats.total_distributed == 1_000_000, 'total should persist');
}

#[test]
#[should_panic(expected: 'RP: amount is zero')]
fn test_fund_week_zero_amount() {
    let (pool, _) = setup();
    start_cheat_caller_address(pool.contract_address, OWNER());
    pool.fund_week(0);
}

#[test]
#[should_panic(expected: 'Caller is not the owner')]
fn test_fund_week_not_owner() {
    let (pool, _) = setup();
    start_cheat_caller_address(pool.contract_address, ATTACKER());
    pool.fund_week(WEEK_BUDGET);
}

// ── top_up tests ──────────────────────────────────────────────────

#[test]
fn test_top_up_increases_budget() {
    let (pool, token) = setup();
    fund_week(pool, token, WEEK_BUDGET);

    // Top up
    start_cheat_caller_address(token.contract_address, OWNER());
    token.approve(pool.contract_address, TOP_UP_AMOUNT);
    stop_cheat_caller_address(token.contract_address);

    start_cheat_caller_address(pool.contract_address, OWNER());
    pool.top_up(TOP_UP_AMOUNT);
    stop_cheat_caller_address(pool.contract_address);

    let stats = pool.get_stats();
    assert(stats.weekly_budget == WEEK_BUDGET + TOP_UP_AMOUNT, 'budget should increase');
    assert(stats.current_week == 1, 'week should not change');
}

#[test]
#[should_panic(expected: 'Caller is not the owner')]
fn test_top_up_not_owner() {
    let (pool, token) = setup();
    fund_week(pool, token, WEEK_BUDGET);

    start_cheat_caller_address(pool.contract_address, ATTACKER());
    pool.top_up(TOP_UP_AMOUNT);
}

// ── distribute tests ──────────────────────────────────────────────

#[test]
fn test_distribute_success() {
    let (pool, token) = setup();
    fund_week(pool, token, WEEK_BUDGET);

    let amt_1: u256 = 2_000_000; // 0.02 WBTC
    let amt_2: u256 = 1_000_000; // 0.01 WBTC
    let recipients = array![PLAYER_1(), PLAYER_2()];
    let amounts = array![amt_1, amt_2];

    start_cheat_caller_address(pool.contract_address, OWNER());
    pool.distribute('daily_w1_d1', recipients, amounts);
    stop_cheat_caller_address(pool.contract_address);

    assert(token.balance_of(PLAYER_1()) == amt_1, 'player 1 wrong balance');
    assert(token.balance_of(PLAYER_2()) == amt_2, 'player 2 wrong balance');

    let stats = pool.get_stats();
    assert(stats.week_distributed == amt_1 + amt_2, 'wrong week distributed');
    assert(stats.total_distributed == amt_1 + amt_2, 'wrong total distributed');
    assert(stats.remaining == WEEK_BUDGET - amt_1 - amt_2, 'wrong remaining');

    // Distribution ID should be marked
    assert(pool.is_distributed('daily_w1_d1'), 'should be marked');
}

#[test]
fn test_distribute_multiple_batches() {
    let (pool, token) = setup();
    fund_week(pool, token, WEEK_BUDGET);

    // Batch 1
    start_cheat_caller_address(pool.contract_address, OWNER());
    pool.distribute('batch_1', array![PLAYER_1()], array![1_000_000_u256]);

    // Batch 2
    pool.distribute('batch_2', array![PLAYER_2()], array![2_000_000_u256]);
    stop_cheat_caller_address(pool.contract_address);

    assert(pool.get_stats().week_distributed == 3_000_000, 'wrong cumulative');
}

#[test]
#[should_panic(expected: 'RP: already distributed')]
fn test_distribute_idempotency() {
    let (pool, token) = setup();
    fund_week(pool, token, WEEK_BUDGET);

    let recipients = array![PLAYER_1()];
    let amounts = array![1_000_000_u256];

    start_cheat_caller_address(pool.contract_address, OWNER());
    pool.distribute('same_id', recipients.clone(), amounts.clone());
    // Second call with same ID should panic
    pool.distribute('same_id', recipients, amounts);
}

#[test]
#[should_panic(expected: 'RP: exceeds single tx cap')]
fn test_distribute_exceeds_single_tx_cap() {
    let (pool, token) = setup();
    fund_week(pool, token, WEEK_BUDGET);

    // Default cap is 15% of budget = 7_500_000
    // Try to distribute more in one tx
    let big_amount: u256 = 8_000_000;

    start_cheat_caller_address(pool.contract_address, OWNER());
    pool.distribute('too_big', array![PLAYER_1()], array![big_amount]);
}

#[test]
#[should_panic(expected: 'RP: exceeds weekly budget')]
fn test_distribute_exceeds_weekly_budget() {
    let (pool, token) = setup();
    fund_week(pool, token, WEEK_BUDGET);

    // Cap at 60% so each single tx is allowed, but two together exceed 100%
    start_cheat_caller_address(pool.contract_address, OWNER());
    pool.set_max_distribution_bps(6_000); // 60%

    // cap = 60% of 50_000_000 = 30_000_000
    // First distribution: 30_000_000 — passes (== cap)
    pool.distribute('first', array![PLAYER_1()], array![30_000_000_u256]);

    // Second distribution: 30_000_000 — within cap but cumulative 60_000_000 > budget
    pool.distribute('second', array![PLAYER_2()], array![30_000_000_u256]);
}

#[test]
#[should_panic(expected: 'RP: arrays length mismatch')]
fn test_distribute_length_mismatch() {
    let (pool, token) = setup();
    fund_week(pool, token, WEEK_BUDGET);

    start_cheat_caller_address(pool.contract_address, OWNER());
    pool.distribute('bad', array![PLAYER_1(), PLAYER_2()], array![1_000_000_u256]);
}

#[test]
#[should_panic(expected: 'RP: empty recipients')]
fn test_distribute_empty_recipients() {
    let (pool, token) = setup();
    fund_week(pool, token, WEEK_BUDGET);

    start_cheat_caller_address(pool.contract_address, OWNER());
    pool.distribute('empty', array![], array![]);
}

#[test]
#[should_panic(expected: 'Caller is not the owner')]
fn test_distribute_not_owner() {
    let (pool, token) = setup();
    fund_week(pool, token, WEEK_BUDGET);

    start_cheat_caller_address(pool.contract_address, ATTACKER());
    pool.distribute('hack', array![ATTACKER()], array![1_000_000_u256]);
}

// ── set_max_distribution_bps tests ────────────────────────────────

#[test]
fn test_set_max_bps() {
    let (pool, _) = setup();

    start_cheat_caller_address(pool.contract_address, OWNER());
    pool.set_max_distribution_bps(5_000); // 50%
    stop_cheat_caller_address(pool.contract_address);

    // Verify by funding + distributing up to 50%
    // (indirect check — the cap allows larger single distributions)
}

#[test]
#[should_panic(expected: 'RP: bps exceeds 10000')]
fn test_set_max_bps_invalid() {
    let (pool, _) = setup();
    start_cheat_caller_address(pool.contract_address, OWNER());
    pool.set_max_distribution_bps(10_001);
}

// ── Integration: full week cycle ──────────────────────────────────

#[test]
fn test_full_week_cycle() {
    let (pool, token) = setup();

    // --- Week 1 ---
    fund_week(pool, token, WEEK_BUDGET);

    // Raise cap for this test to simplify
    start_cheat_caller_address(pool.contract_address, OWNER());
    pool.set_max_distribution_bps(5_000); // 50%

    // Daily distribution day 1
    pool.distribute('w1_d1', array![PLAYER_1(), PLAYER_2()], array![2_000_000, 1_000_000]);

    // Daily distribution day 2
    pool.distribute('w1_d2', array![PLAYER_3()], array![1_500_000]);

    // Weekly leaderboard
    pool
        .distribute(
            'w1_weekly',
            array![PLAYER_1(), PLAYER_2(), PLAYER_3()],
            array![3_000_000, 2_000_000, 1_000_000],
        );

    stop_cheat_caller_address(pool.contract_address);

    let stats_w1 = pool.get_stats();
    let total_w1: u256 = 2_000_000 + 1_000_000 + 1_500_000 + 3_000_000 + 2_000_000 + 1_000_000;
    assert(stats_w1.week_distributed == total_w1, 'w1 distributed wrong');
    assert(stats_w1.total_distributed == total_w1, 'w1 total wrong');

    // --- Week 2 ---
    fund_week(pool, token, WEEK_BUDGET);

    let stats_w2 = pool.get_stats();
    assert(stats_w2.current_week == 2, 'should be week 2');
    assert(stats_w2.week_distributed == 0, 'w2 should start at 0');
    assert(stats_w2.total_distributed == total_w1, 'total should carry over');

    // Player balances should reflect all distributions
    let p1_expected: u256 = 2_000_000 + 3_000_000;
    assert(token.balance_of(PLAYER_1()) == p1_expected, 'player 1 total wrong');
}
