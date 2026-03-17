#[starknet::contract]
pub mod MockERC20 {
    use starknet::{ContractAddress, get_caller_address};
    use starknet::storage::{
        StoragePointerReadAccess, StoragePointerWriteAccess, StoragePathEntry, Map,
    };
    use openzeppelin_interfaces::erc20::IERC20;

    #[storage]
    struct Storage {
        name: ByteArray,
        symbol: ByteArray,
        total_supply: u256,
        balances: Map<ContractAddress, u256>,
        allowances: Map<(ContractAddress, ContractAddress), u256>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, initial_supply: u256, recipient: ContractAddress) {
        self.name.write("Wrapped BTC");
        self.symbol.write("WBTC");
        self.total_supply.write(initial_supply);
        self.balances.entry(recipient).write(initial_supply);
    }

    #[abi(embed_v0)]
    impl ERC20Impl of IERC20<ContractState> {
        fn total_supply(self: @ContractState) -> u256 {
            self.total_supply.read()
        }

        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            self.balances.entry(account).read()
        }

        fn allowance(
            self: @ContractState, owner: ContractAddress, spender: ContractAddress,
        ) -> u256 {
            self.allowances.entry((owner, spender)).read()
        }

        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            let sender = get_caller_address();
            let sender_bal = self.balances.entry(sender).read();
            assert(sender_bal >= amount, 'ERC20: insufficient balance');
            self.balances.entry(sender).write(sender_bal - amount);
            self
                .balances
                .entry(recipient)
                .write(self.balances.entry(recipient).read() + amount);
            true
        }

        fn transfer_from(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) -> bool {
            let caller = get_caller_address();
            let current_allowance = self.allowances.entry((sender, caller)).read();
            assert(current_allowance >= amount, 'ERC20: insufficient allowance');
            self.allowances.entry((sender, caller)).write(current_allowance - amount);

            let sender_bal = self.balances.entry(sender).read();
            assert(sender_bal >= amount, 'ERC20: insufficient balance');
            self.balances.entry(sender).write(sender_bal - amount);
            self
                .balances
                .entry(recipient)
                .write(self.balances.entry(recipient).read() + amount);
            true
        }

        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            let caller = get_caller_address();
            self.allowances.entry((caller, spender)).write(amount);
            true
        }
    }
}
