#[cfg(test)]
mod tests {
    use everydayapp::price_converter::price_converter::{
        IPriceConverterDispatcher,
    };
    use everydayapp::alarm::alarm::{IAlarmContractDispatcher, IAlarmContractDispatcherTrait};
    use everydayapp::alarm::alarm::AlarmContract;
    use everydayapp::alarm::alarm::AlarmContract::{AlarmSet, VerifiedSignerSet, MerkleRootSet, WinningsClaimed};
    use everydayapp::mocks::mock_erc20::{IMockERC20Dispatcher, IMockERC20DispatcherTrait};
    use snforge_std::{
        ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address, 
        stop_cheat_caller_address, start_cheat_block_timestamp, stop_cheat_block_timestamp,
        spy_events, EventSpyAssertionsTrait
    };
    use starknet::ContractAddress;
    use core::poseidon;

    const OWNER: felt252 = 'owner';
    const NON_OWNER : felt252 = 'non_owner';
    const VERIFIED_SIGNER: felt252 = 0x42f53a290543042b07333f31cf9cc4ad7d3ef0ac2996c2d1af302fdf7ae2fbf;
    const VERIFIED_SIGNER_PRIVATE_KEY: felt252 = 0x02a49cbb553b2b8d8ba20b3c9981ece2f4148f987f0665344e06e641a88f3cf5;
    const NEW_VERIFIED_SIGNER: felt252 = 0x18e48c23b081873ca2a794891caa08bcd57ac10ea53781c3a51e2bdbf222406;

    const USER_1: felt252 = 0x068e5011bbef90f8227382ea517277b631339205af237d5e853573248fc726a4; // Backend user1 (winner)
    const USER_2: felt252 = 0x04b30350238863e574f135c84b48f860be87c90afc37843709b4613aab32f018; // Backend user2 (loser)
    
    fn get_owner_address() -> ContractAddress {
        OWNER.try_into().unwrap()
    }

    fn get_verified_signer() -> felt252 {
        VERIFIED_SIGNER
    }

    fn get_verified_signer_private_key() -> felt252{
        VERIFIED_SIGNER_PRIVATE_KEY
    }

    fn get_user_address() -> ContractAddress {
        USER_1.try_into().unwrap()
    }

    fn get_another_user_address() -> ContractAddress {
        USER_2.try_into().unwrap()
    }
    fn get_non_owner() -> ContractAddress {
        NON_OWNER.try_into().unwrap()
    }

    fn get_new_signer() -> felt252 {
        NEW_VERIFIED_SIGNER
    }
    fn setup() -> (IPriceConverterDispatcher, IAlarmContractDispatcher, ContractAddress, ContractAddress, IMockERC20Dispatcher) {
        // Declare Contracts
        let mock_pragma_oracle_class = declare("StrkMockOracle").unwrap().contract_class();
        let price_convertor_class = declare("PriceConverter").unwrap().contract_class();
        let alarm_contract_class = declare("AlarmContract").unwrap().contract_class();
        let mock_erc20_class = declare("MockERC20").unwrap().contract_class();

        // Deploy Mock STRK Oracle Contract
        let (mock_strk_usd_pragma_oracle_address, _) = mock_pragma_oracle_class.deploy(@array![]).unwrap();

        // Construct constructor args for PriceConverter
        let token_name: felt252 = 'MockSTRK';
        let token_symbol: felt252 = 'MSTRK';
        let decimals: u8 = 18;
        let initial_supply: u256 = 1000000000000000000000; // 1000 tokens with 18 decimals
        let owner: ContractAddress = get_owner_address();
        
        let token_constructor_args = array![
            token_name,
            token_symbol, 
            decimals.into(),
            initial_supply.low.into(),
            initial_supply.high.into(),
            owner.into()
        ];
        
        // Deploy Mock ERC20 Token
        let (token_address, _) = mock_erc20_class.deploy(@token_constructor_args).unwrap();

        // Construct constructor args for PriceConverter (use STRK oracle)
        let constructor_args_price_converter = array![
            mock_strk_usd_pragma_oracle_address.into(), owner.into(),
        ];

        // Deploy PriceConverter Contract
        let (price_converter_address, _) = price_convertor_class
            .deploy(@constructor_args_price_converter)
            .unwrap();

        // Construct constructor args for AlarmContract
        let verified_signer: felt252 = get_verified_signer();
        let constructor_args_alarm_contract = array![
            owner.into(), 
            verified_signer.into(), 
            token_address.into(), // Use mock ERC20 token
            price_converter_address.into(),
            owner.into(), // protocol_fees_address -> route fees to owner in tests
        ];
        
        // Deploy Alarm Contract
        let (alarm_contract_address, _) = alarm_contract_class.deploy(@constructor_args_alarm_contract).unwrap();
        
        // Create dispatchers
        let price_converter_dispatcher = IPriceConverterDispatcher { contract_address: price_converter_address };
        let alarm_dispatcher = IAlarmContractDispatcher { contract_address: alarm_contract_address };
        let token_dispatcher = IMockERC20Dispatcher { contract_address: token_address };

        // Return dispatchers and addresses
        (price_converter_dispatcher, alarm_dispatcher, price_converter_address, alarm_contract_address, token_dispatcher)
    }

    fn setup_two_users() -> (IPriceConverterDispatcher, IAlarmContractDispatcher, ContractAddress, ContractAddress, IMockERC20Dispatcher, ContractAddress, ContractAddress) {
        // Setup initial contracts
        let (_price_converter_dispatcher, alarm_dispatcher, price_converter_address, alarm_contract_address, token_dispatcher) = setup();
        
        // Define 2 user addresses
        // let winner: ContractAddress = 'winner_user'.try_into().unwrap();
        // let loser: ContractAddress = 'loser_user'.try_into().unwrap();
        
        let winner: ContractAddress = get_user_address();
        let loser: ContractAddress = get_another_user_address();
        
        
        // Define stake amounts
        let winner_stake: u256 = 50000000000000000000; // 50 STRK
        let loser_stake: u256 = 50000000000000000000; // 50 STRK
        
        // Use the same pool settings as backend data (day=20320, period=1)
        let base_time: u64 = 1755709200 - 3600; // Backend wakeup time - 1 hour
        let _pool_day: u64 = 20320; // Day from backend
        let _pool_period: u8 = 1; // PM period from backend
        
        // Set current timestamp
        start_cheat_block_timestamp(alarm_contract_address, base_time);
        
        // Setup winner user - use backend wakeup time (PM period)
        let wakeup_time_winner = 1755709200; // Backend user1 wakeup time (winner)
        let owner = get_owner_address();
        
        // Give winner tokens (using token contract context)
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.transfer(winner, winner_stake * 2); // Give 2x stake amount
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        // Winner approves alarm contract and sets alarm
        start_cheat_caller_address(token_dispatcher.contract_address, winner);
        token_dispatcher.approve(alarm_contract_address, winner_stake);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_caller_address(alarm_contract_address, winner);
        alarm_dispatcher.set_alarm(wakeup_time_winner, winner_stake);
        stop_cheat_caller_address(alarm_contract_address);
        
        // Setup loser user - use backend wakeup time (PM period)
        let wakeup_time_loser = 1755712800; // Backend user2 wakeup time (loser)
        
        // Give loser tokens (using token contract context)
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.transfer(loser, loser_stake * 2); // Give 2x stake amount
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        // Loser approves alarm contract and sets alarm
        start_cheat_caller_address(token_dispatcher.contract_address, loser);
        token_dispatcher.approve(alarm_contract_address, loser_stake);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_caller_address(alarm_contract_address, loser);
        alarm_dispatcher.set_alarm(wakeup_time_loser, loser_stake);
        stop_cheat_caller_address(alarm_contract_address);
        
        stop_cheat_block_timestamp(alarm_contract_address);
        
        // Return everything including user addresses
        (_price_converter_dispatcher, alarm_dispatcher, price_converter_address, alarm_contract_address, token_dispatcher, winner, loser)
    }

    // Helper function to get winner signature from test_outputs.json
    fn get_winner_signature() -> (felt252, felt252) {
        // Winner signature from test_outputs.json (snooze_count = 0)
        // let r = 0x651ecaaa73ccba428304a532c8fc67f717e9aead2aa8c27acb9c3f6e82d105a;
        // let s = 0x4c47257537c26ca84e4912d06d99f433121b6da14a3ae13cb84529158c9e126;
        
        let r = 0x7b28daddd155d216a641ba8b934d7a4f67ed69b8602e19779f4ffa0a54b5201;
        let s = 0x248f956b99a28192d801979b0b52596353b1753ba819ba706ada926b51affc9;
        

        (r, s)
    }

    // Helper function to get loser signature from test_outputs.json  
    fn get_loser_signature() -> (felt252, felt252) {
        // Loser signature from test_outputs.json (snooze_count = 1)
        // let r = 0x4bc3d2d98d68108e94966d90447df5e0879db8ffe855b3cd4b32fa498f1eca7;
        // let s = 0x7b4a49b8685ab5ca77e6f24e4727dd7dd72be6104ea4b3a4efb12ddf1d10e6f;
        
        let r = 0x3beac28859e0d2e448386aec669252a6e9c8c69f697c16d04fc7780af58fab8;
        let s = 0x3e65d6f1773078655df4c3c6030c76720fc9713c8045bd7e8ab6c5e0153fb3f;
        

        (r, s)
    }

    // Helper function to get merkle root from test_outputs.json
    fn get_test_merkle_root() -> felt252 {
        0x2e6cb2847142da7d17991d0496834001aa726bf7c145c80426fd4c28eff796a
    }

    // Helper function to get winner reward amount from test_outputs.json
    fn get_winner_reward_amount() -> u256 {
        42500000000000000000 // 42.5 STRK
    }

    // Helper function to create a simple merkle tree and proof for testing
    fn create_test_merkle_tree_and_proof(winner: ContractAddress, reward_amount: u256) -> (felt252, Array<felt252>) {
        // For testing, we'll create a simple merkle tree with winner as a leaf
        // In real implementation, this would be a proper merkle tree with all winners
        
        // Create leaf hash: hash(winner_address, reward_amount)
        let leaf_data = array![winner.into(), reward_amount.low.into(), reward_amount.high.into()];
        let leaf_hash = poseidon::poseidon_hash_span(leaf_data.span());
        
        // For simplicity, create a tree with just one leaf (winner)
        // The merkle root is just the leaf hash
        let merkle_root = leaf_hash;
        
        // Empty proof since we have only one leaf
        let merkle_proof = array![];
        
        (merkle_root, merkle_proof)
    }

    #[test]
    fn test_verify_outcome_signature() {
        let (_price_converter_dispatcher, _alarm_dispatcher, _price_converter_address, _alarm_contract_address, _token_dispatcher) = setup();
        
        // Test the helper functions work
        let (winner_r, winner_s) = get_winner_signature();
        let (loser_r, loser_s) = get_loser_signature();
        let merkle_root = get_test_merkle_root();
        let reward_amount = get_winner_reward_amount();
        
        // Verify signatures are not zero
        assert(winner_r != 0, 'Winner signature r != 0');
        assert(winner_s != 0, 'Winner signature s != 0');
        assert(loser_r != 0, 'Loser signature r != 0');
        assert(loser_s != 0, 'Loser signature s != 0');
        
        // Verify other test data
        assert(merkle_root != 0, 'Merkle root != 0');
        assert(reward_amount > 0, 'Reward amount should be > 0');
    }

    #[test]
    fn test_constructor_initialization() {
        // Setup event spy
        let mut spy = spy_events();

        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher) = setup();

        // Test basic functionality
        let owner = alarm_dispatcher.get_owner();
        let expected_owner = get_owner_address();
        assert(owner == expected_owner, 'Wrong owner');

        let verified_signer = alarm_dispatcher.get_verified_signer();
        let expected_signer = get_verified_signer();
        assert(verified_signer == expected_signer, 'Wrong verified signer');

        let minimum_stake = alarm_dispatcher.get_minimum_stake_amount();
        assert(minimum_stake > 0, 'Minimum stake should be > 0');

         // Verify event was emitted
        let expected_event = AlarmContract::Event::VerifiedSignerSet(VerifiedSignerSet{ 
            verified_signer: verified_signer 
        });
        
        let expected_events = array![(alarm_contract_address, expected_event)];
        spy.assert_emitted(@expected_events);
        
    }

    #[test]
    fn test_alarm_contract_constants() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, _alarm_contract_address, _token_dispatcher) = setup();

        // Test minimum stake amount constant
        let minimum_stake_amount = alarm_dispatcher.get_minimum_stake_amount();
        
        // Expected: 1 USD with 18 decimals = 1_000_000_000_000_000_000
        let expected_minimum_stake: u256 = 1_000_000_000_000_000_000;
        assert(minimum_stake_amount == expected_minimum_stake, 'Wrong minimum stake amount');

        // Additional validation - ensure it's exactly 1 USD with 18 decimals
        let one_usd_18_decimals: u256 = 1000000000000000000; // 1e18
        assert(minimum_stake_amount == one_usd_18_decimals, 'Minimum stake not 1 USD');

        // Test that minimum stake is greater than zero
        assert(minimum_stake_amount > 0, 'Minimum stake should be > 0');
    }

    #[test]
    fn test_set_alarm_successful() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, alarm_contract_address, token_dispatcher) = setup();
        
        // Setup test parameters
        let user = get_user_address();
        let current_time: u64 = 1000000; // Mock current timestamp
        let wakeup_time: u64 = current_time + 86400; // 24 hours in the future
        let stake_amount: u256 = 50000000000000000000; // 50 STRK (>$0.2 USD min)
        
        // Setup block timestamp
        start_cheat_block_timestamp(alarm_contract_address, current_time);
        
        // Give user tokens and approve the alarm contract
        let owner = get_owner_address();
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.mint(user, stake_amount);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        // User approves alarm contract to spend tokens
        start_cheat_caller_address(token_dispatcher.contract_address, user);
        let approve_success = token_dispatcher.approve(alarm_contract_address, stake_amount);
        assert(approve_success, 'Token approval failed');
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        // Verify balances before setting alarm
        let user_balance_before = token_dispatcher.balance_of(user);
        let contract_balance_before = token_dispatcher.balance_of(alarm_contract_address);
        
        // Setup event spy
        let mut spy = spy_events();
        
        // Set alarm as user
        start_cheat_caller_address(alarm_contract_address, user);
        alarm_dispatcher.set_alarm(wakeup_time, stake_amount);
        stop_cheat_caller_address(alarm_contract_address);
        
        // Verify balances after setting alarm
        let user_balance_after = token_dispatcher.balance_of(user);
        let contract_balance_after = token_dispatcher.balance_of(alarm_contract_address);
        
        // Verify token transfer occurred
        assert(user_balance_after == user_balance_before - stake_amount, 'User balance incorrect');
        assert(contract_balance_after == contract_balance_before + stake_amount, 'Contract balance incorrect');
        
        // Calculate expected day and period
        let day = wakeup_time / 86400; // ONE_DAY_IN_SECONDS
        let period_u64 = (wakeup_time % 86400) / 43200; // TWELVE_HOURS_IN_SECONDS
        let period: u8 = period_u64.try_into().unwrap();
        
        // Verify alarm was created with correct data
        let (stored_stake, stored_wakeup, status) = alarm_dispatcher.get_user_alarm(user, day, period);
        assert(stored_stake == stake_amount, 'Wrong stored stake amount');
        assert(stored_wakeup == wakeup_time, 'Wrong stored wakeup time');
        assert(status == 'Active', 'Wrong alarm status');
        
        // Verify event was emitted
        let expected_event = AlarmContract::Event::AlarmSet(
            AlarmSet {
                user: user,
                    wakeup_time: wakeup_time,
                stake_amount: stake_amount,
            }
        );
        let expected_events = array![(alarm_contract_address, expected_event)];
        spy.assert_emitted(@expected_events);
        
        stop_cheat_block_timestamp(alarm_contract_address);
    }

    #[test]
    #[should_panic(expected: ('Invalid_Stake_Amount',))]
    fn test_set_alarm_zero_stake_amount() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher) = setup();
        
        let user = get_user_address();
        let current_time: u64 = 1000000;
        let wakeup_time: u64 = current_time + 86400;
        let stake_amount: u256 = 0; // Zero stake amount - should fail
        
        start_cheat_block_timestamp(alarm_contract_address, current_time);
        start_cheat_caller_address(alarm_contract_address, user);
        
        // This should panic with INVALID_STAKE_AMOUNT
        alarm_dispatcher.set_alarm(wakeup_time, stake_amount);
    }

    #[test]
    #[should_panic(expected: ('Invalid_WakeUp_Time',))]
    fn test_set_alarm_past_wakeup_time() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher) = setup();
        
        let user = get_user_address();
        let current_time: u64 = 1000000;
        let wakeup_time: u64 = current_time - 1; // Past time - should fail
        let stake_amount: u256 = 5000000000000000000;
        
        start_cheat_block_timestamp(alarm_contract_address, current_time);
        start_cheat_caller_address(alarm_contract_address, user);
        
        // This should panic with INVALID_WAKEUP_TIME
        alarm_dispatcher.set_alarm(wakeup_time, stake_amount);
    }

    #[test]
    #[should_panic(expected: ('Invalid_Stake_Amount',))]
    fn test_set_alarm_insufficient_usd_value() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, alarm_contract_address, token_dispatcher) = setup();
        
        let user = get_user_address();
        let current_time: u64 = 1000000;
        let wakeup_time: u64 = current_time + 86400;
        let stake_amount: u256 = 1000; // Very small amount - should be < $0.2 USD
        
        // Give user the small amount of tokens
        let owner = get_owner_address();
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.mint(user, stake_amount);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_block_timestamp(alarm_contract_address, current_time);
        start_cheat_caller_address(alarm_contract_address, user);
        
        // This should panic with INVALID_STAKE_AMOUNT (insufficient USD value)
        alarm_dispatcher.set_alarm(wakeup_time, stake_amount);
    }

    #[test]
    #[should_panic(expected: ('Alarm_Already_Exists_In_Pool',))]
    fn test_set_alarm_already_exists() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, alarm_contract_address, token_dispatcher) = setup();
        
        let user = get_user_address();
        let current_time: u64 = 1000000;
        let wakeup_time: u64 = current_time + 86400;
        let stake_amount: u256 = 5000000000000000000;
        
        // Setup tokens and approvals
        let owner = get_owner_address();
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.mint(user, stake_amount * 2); // Give enough for two alarms
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_caller_address(token_dispatcher.contract_address, user);
        token_dispatcher.approve(alarm_contract_address, stake_amount * 2);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_block_timestamp(alarm_contract_address, current_time);
        start_cheat_caller_address(alarm_contract_address, user);
        
        // Set first alarm successfully
        alarm_dispatcher.set_alarm(wakeup_time, stake_amount);
        
        // Try to set second alarm for same day/period - should fail
        alarm_dispatcher.set_alarm(wakeup_time + 1, stake_amount); // Same day/period
    }

    #[test]
    #[should_panic(expected: ('Insufficient allowance',))]
    fn test_set_alarm_transfer_failed() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher) = setup();
        
        let user = get_user_address();
        let current_time: u64 = 1000000;
        let wakeup_time: u64 = current_time + 86400;
        let stake_amount: u256 = 5000000000000000000;
        
        start_cheat_block_timestamp(alarm_contract_address, current_time);
        start_cheat_caller_address(alarm_contract_address, user);
        
        // Don't give user any tokens or approval - should fail on transfer_from with insufficient allowance
        alarm_dispatcher.set_alarm(wakeup_time, stake_amount);
    }

    #[test]
    fn test_set_verified_signer_as_owner() {
        // Setup event spy
        let mut spy = spy_events();
        
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher) = setup();
        
        // Test parameters
        let new_signer = get_new_signer();
        
        // Verify initial signer
        let initial_signer = alarm_dispatcher.get_verified_signer();
        assert(initial_signer == get_verified_signer(), 'Wrong initial signer');
        
        // Set caller as owner
        start_cheat_caller_address(alarm_contract_address, get_owner_address());
        
        // Set new verified signer
        alarm_dispatcher.set_verified_signer(new_signer);
        
        // Verify the signer was updated
        let updated_signer = alarm_dispatcher.get_verified_signer();
        assert(updated_signer == new_signer, 'Signer not updated');
        
        // Verify event was emitted
        let expected_event = AlarmContract::Event::VerifiedSignerSet(
            VerifiedSignerSet { verified_signer: new_signer }
        );
        let expected_events = array![(alarm_contract_address, expected_event)];
        spy.assert_emitted(@expected_events);
        
        stop_cheat_caller_address(alarm_contract_address);
    }

    #[test]
    #[should_panic(expected: ('Caller is not the owner',))]
    fn test_set_verified_signer_as_non_owner() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher) = setup();
        
        let new_signer = get_new_signer();
        let non_owner = get_user_address();
        
        // Set caller as non-owner
        start_cheat_caller_address(alarm_contract_address, non_owner);
        
        // This should panic with "Caller is not the owner"
        alarm_dispatcher.set_verified_signer(new_signer);
    }

    #[test]
    #[should_panic(expected: ('Invalid_Public_Key',))]
    fn test_set_verified_signer_zero_address() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher) = setup();
        
        let zero_address: felt252 = 0;
        
        // Set caller as owner
        start_cheat_caller_address(alarm_contract_address, get_owner_address());
        
        // This should panic with "Zero_Address"
        alarm_dispatcher.set_verified_signer(zero_address);
    }

    #[test]
    fn test_set_reward_merkle_root_as_owner() {
        // Setup event spy
        let mut spy = spy_events();
        
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher) = setup();
        
        // Test parameters
        let day: u64 = 100;
        let period: u8 = 0; // AM period
        let merkle_root: felt252 = 'test_merkle_root_123';
        
        // Verify initial pool state
        let (initial_root, initial_finalized, _initial_total_staked, _initial_user_count) = alarm_dispatcher.get_pool_info(day, period);
        assert(initial_root == 0, 'Initial root should be 0');
        assert(!initial_finalized, 'Pool not finalized initially');
        
        // Set caller as owner
        start_cheat_caller_address(alarm_contract_address, get_owner_address());
        
        // Set merkle root
        alarm_dispatcher.set_reward_merkle_root(day, period, merkle_root);
        
        // Verify the merkle root was set and pool finalized
        let (updated_root, updated_finalized, _updated_total_staked, _updated_user_count) = alarm_dispatcher.get_pool_info(day, period);
        assert(updated_root == merkle_root, 'Merkle root not set');
        assert(updated_finalized, 'Pool should be finalized');
        
        // Also test get_merkle_root function
        let stored_root = alarm_dispatcher.get_merkle_root(day, period);
        assert(stored_root == merkle_root, 'Wrong stored merkle root');
        
        // Verify event was emitted
        let expected_event = AlarmContract::Event::MerkleRootSet(
            MerkleRootSet { merkle_root: merkle_root, day: day, period: period }
        );
        let expected_events = array![(alarm_contract_address, expected_event)];
        spy.assert_emitted(@expected_events);
        
        stop_cheat_caller_address(alarm_contract_address);
    }

    #[test]
    fn test_set_reward_merkle_root_pm_period() {
        // Setup event spy
        let mut spy = spy_events();
        
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher) = setup();
        
        // Test parameters for PM period
        let day: u64 = 200;
        let period: u8 = 1; // PM period
        let merkle_root: felt252 = 'test_merkle_root_pm';
        
        // Set caller as owner
        start_cheat_caller_address(alarm_contract_address, get_owner_address());
        
        // Set merkle root for PM period
        alarm_dispatcher.set_reward_merkle_root(day, period, merkle_root);
        
        // Verify the merkle root was set
        let (updated_root, updated_finalized, _updated_total_staked, _updated_user_count) = alarm_dispatcher.get_pool_info(day, period);
        assert(updated_root == merkle_root, 'PM merkle root not set');
        assert(updated_finalized, 'PM pool finalized');
        
        // Verify event was emitted
        let expected_event = AlarmContract::Event::MerkleRootSet(
            MerkleRootSet { merkle_root: merkle_root, day: day, period: period }
        );
        let expected_events = array![(alarm_contract_address, expected_event)];
        spy.assert_emitted(@expected_events);
        
        stop_cheat_caller_address(alarm_contract_address);
    }

    #[test]
    #[should_panic(expected: ('Caller is not the owner',))]
    fn test_set_reward_merkle_root_as_non_owner() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher) = setup();
        
        let day: u64 = 100;
        let period: u8 = 0;
        let merkle_root: felt252 = 'test_merkle_root';
        let non_owner = get_user_address();
        
        // Set caller as non-owner
        start_cheat_caller_address(alarm_contract_address, non_owner);
        
        // This should panic with "Caller is not the owner"
        alarm_dispatcher.set_reward_merkle_root(day, period, merkle_root);
    }

    #[test]
    #[should_panic(expected: ('Invalid_Pool',))]
    fn test_set_reward_merkle_root_invalid_period() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher) = setup();
        
        let day: u64 = 100;
        let period: u8 = 2; // Invalid period (should be 0 or 1)
        let merkle_root: felt252 = 'test_merkle_root';
        
        // Set caller as owner
        start_cheat_caller_address(alarm_contract_address, get_owner_address());
        
        // This should panic with "Invalid_Pool"
        alarm_dispatcher.set_reward_merkle_root(day, period, merkle_root);
    }

    #[test]
    #[should_panic(expected: ('Invalid_Merkle_Root',))]
    fn test_set_reward_merkle_root_zero_root() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher) = setup();
        
        let day: u64 = 100;
        let period: u8 = 0;
        let merkle_root: felt252 = 0; // Zero merkle root should fail
        
        // Set caller as owner
        start_cheat_caller_address(alarm_contract_address, get_owner_address());
        
        // This should panic with "Invalid_Merkle_Root"
        alarm_dispatcher.set_reward_merkle_root(day, period, merkle_root);
    }

    #[test]
    fn test_multiple_merkle_roots_different_periods() {
        // Setup event spy
        let mut spy = spy_events();
        
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher) = setup();
        
        let day: u64 = 300;
        let am_period: u8 = 0;
        let pm_period: u8 = 1;
        let am_merkle_root: felt252 = 'am_merkle_root';
        let pm_merkle_root: felt252 = 'pm_merkle_root';
        
        // Set caller as owner
        start_cheat_caller_address(alarm_contract_address, get_owner_address());
        
        // Set AM merkle root
        alarm_dispatcher.set_reward_merkle_root(day, am_period, am_merkle_root);
        
        // Set PM merkle root
        alarm_dispatcher.set_reward_merkle_root(day, pm_period, pm_merkle_root);
        
        // Verify both merkle roots are set correctly
        let (am_root, am_finalized, _am_total_staked, _am_user_count) = alarm_dispatcher.get_pool_info(day, am_period);
        let (pm_root, pm_finalized, _pm_total_staked, _pm_user_count) = alarm_dispatcher.get_pool_info(day, pm_period);
        
        assert(am_root == am_merkle_root, 'AM root not set');
        assert(am_finalized, 'AM pool finalized');
        assert(pm_root == pm_merkle_root, 'PM root not set');
        assert(pm_finalized, 'PM pool finalized');
        
        // Verify both events were emitted
        let expected_am_event = AlarmContract::Event::MerkleRootSet(
            MerkleRootSet { merkle_root: am_merkle_root, day: day, period: am_period }
        );
        let expected_pm_event = AlarmContract::Event::MerkleRootSet(
            MerkleRootSet { merkle_root: pm_merkle_root, day: day, period: pm_period }
        );
        let expected_events = array![
            (alarm_contract_address, expected_am_event),
            (alarm_contract_address, expected_pm_event)
        ];
        spy.assert_emitted(@expected_events);
        
        stop_cheat_caller_address(alarm_contract_address);
    }

    #[test]
    fn test_owner_can_update_existing_merkle_root() {
        // Setup event spy
        let mut spy = spy_events();
        
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher) = setup();
        
        let day: u64 = 400;
        let period: u8 = 0;
        let initial_merkle_root: felt252 = 'initial_root';
        let updated_merkle_root: felt252 = 'updated_root';
        
        // Set caller as owner
        start_cheat_caller_address(alarm_contract_address, get_owner_address());
        
        // Set initial merkle root
        alarm_dispatcher.set_reward_merkle_root(day, period, initial_merkle_root);
        
        // Verify initial state
        let (initial_root, initial_finalized, _initial_total_staked, _initial_user_count) = alarm_dispatcher.get_pool_info(day, period);
        assert(initial_root == initial_merkle_root, 'Initial root not set');
        assert(initial_finalized, 'Pool should be finalized');
        
        // Update merkle root
        alarm_dispatcher.set_reward_merkle_root(day, period, updated_merkle_root);
        
        // Verify update
        let (final_root, final_finalized, _final_total_staked, _final_user_count) = alarm_dispatcher.get_pool_info(day, period);
        assert(final_root == updated_merkle_root, 'Root not updated');
        assert(final_finalized, 'Pool remains not finalized');
        
        // Verify both events were emitted (initial set and update)
        let expected_initial_event = AlarmContract::Event::MerkleRootSet(
            MerkleRootSet { merkle_root: initial_merkle_root, day: day, period: period }
        );
        let expected_updated_event = AlarmContract::Event::MerkleRootSet(
            MerkleRootSet { merkle_root: updated_merkle_root, day: day, period: period }
        );
        let expected_events = array![
            (alarm_contract_address, expected_initial_event),
            (alarm_contract_address, expected_updated_event)
        ];
        spy.assert_emitted(@expected_events);
        
        stop_cheat_caller_address(alarm_contract_address);
    }

    #[test]
    fn test_get_owner() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, _alarm_contract_address, _token_dispatcher) = setup();
        
        let owner = alarm_dispatcher.get_owner();
        assert(owner == get_owner_address(), 'Wrong owner returned');
    }

    #[test]
    fn test_get_verified_signer() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, _alarm_contract_address, _token_dispatcher) = setup();
        
        let verified_signer = alarm_dispatcher.get_verified_signer();
        assert(verified_signer == get_verified_signer(), 'Wrong verified signer');
    }

    #[test]
    #[should_panic(expected: ('Invalid_Pool',))]
    fn test_get_pool_info_invalid_period() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, _alarm_contract_address, _token_dispatcher) = setup();
        
        let day: u64 = 100;
        let invalid_period: u8 = 5; // Invalid period
        
        // This should panic with "Invalid_Pool"
        alarm_dispatcher.get_pool_info(day, invalid_period);
    }

    #[test]
    #[should_panic(expected: ('Invalid_Pool',))]
    fn test_get_merkle_root_invalid_period() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, _alarm_contract_address, _token_dispatcher) = setup();
        
        let day: u64 = 100;
        let invalid_period: u8 = 3; // Invalid period
        
        // This should panic with "Invalid_Pool"
        alarm_dispatcher.get_merkle_root(day, invalid_period);
    }

    #[test]
    fn test_get_pool_info() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, _alarm_contract_address, _token_dispatcher) = setup();
        
        let day: u64 = 100;
        let period: u8 = 0; // AM period
        
        // Test initial pool info (should be empty)
        let (_initial_root, _initial_finalized, initial_total_staked, initial_user_count) = alarm_dispatcher.get_pool_info(day, period);
        assert(initial_total_staked == 0, 'Initial total == 0');
        assert(initial_user_count == 0, 'Initial user count == 0');
    }

    #[test]
    fn test_pool_info_update_single_user() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, alarm_contract_address, token_dispatcher) = setup();
        
        // Setup test parameters
        let user = get_user_address();
        let current_time: u64 = 1000000;
        let wakeup_time: u64 = current_time + 86400; // 24 hours in the future
        let stake_amount: u256 = 5000000000000000000; // 5 ETH
        
        // Calculate day and period
        let day = wakeup_time / 86400;
        let period_u64 = (wakeup_time % 86400) / 43200;
        let period: u8 = period_u64.try_into().unwrap();
        
        // Check initial pool info
        let (_initial_root, _initial_finalized, initial_total_staked, initial_user_count) = alarm_dispatcher.get_pool_info(day, period);
        assert(initial_total_staked == 0, 'Initial total staked != 0');
        assert(initial_user_count == 0, 'Initial user count != 0');
        
        // Setup tokens and set alarm
        start_cheat_block_timestamp(alarm_contract_address, current_time);
        let owner = get_owner_address();
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.mint(user, stake_amount);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_caller_address(token_dispatcher.contract_address, user);
        token_dispatcher.approve(alarm_contract_address, stake_amount);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_caller_address(alarm_contract_address, user);
        alarm_dispatcher.set_alarm(wakeup_time, stake_amount);
        stop_cheat_caller_address(alarm_contract_address);
        
        // Check pool info after setting alarm
        let (_updated_root, _updated_finalized, updated_total_staked, updated_user_count) = alarm_dispatcher.get_pool_info(day, period);
        assert(updated_total_staked == stake_amount, 'Total staked not updated');
        assert(updated_user_count == 1, 'User count not updated');
        
        stop_cheat_block_timestamp(alarm_contract_address);
    }

    #[test]
    fn test_pool_info_update_multiple_users() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, alarm_contract_address, token_dispatcher) = setup();
        
        let current_time: u64 = 1000000;
        let base_wakeup_time: u64 = current_time + 86400;
        
        // User 1 setup
        let user1 = get_user_address();
        let wakeup_time1 = base_wakeup_time + 3600; // Same day/period
        let stake1: u256 = 50000000000000000000; // 50 STRK
        
        // User 2 setup
        let user2 = get_another_user_address();
        let wakeup_time2 = base_wakeup_time + 7200; // Same day/period
        let stake2: u256 = 50000000000000000000; // 50 STRK
        
        // Calculate day and period (should be same for both users)
        let day = wakeup_time1 / 86400;
        let period_u64 = (wakeup_time1 % 86400) / 43200;
        let period: u8 = period_u64.try_into().unwrap();
        
        start_cheat_block_timestamp(alarm_contract_address, current_time);
        let owner = get_owner_address();
        
        // Setup User 1
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.mint(user1, stake1);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_caller_address(token_dispatcher.contract_address, user1);
        token_dispatcher.approve(alarm_contract_address, stake1);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_caller_address(alarm_contract_address, user1);
        alarm_dispatcher.set_alarm(wakeup_time1, stake1);
        stop_cheat_caller_address(alarm_contract_address);
        
        // Check pool info after first user
        let (_root_after_user1, _finalized_after_user1, total_after_user1, count_after_user1) = alarm_dispatcher.get_pool_info(day, period);
        assert(total_after_user1 == stake1, 'Wrong total after user1');
        assert(count_after_user1 == 1, 'Wrong count after user1');
        
        // Setup User 2
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.mint(user2, stake2);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_caller_address(token_dispatcher.contract_address, user2);
        token_dispatcher.approve(alarm_contract_address, stake2);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_caller_address(alarm_contract_address, user2);
        alarm_dispatcher.set_alarm(wakeup_time2, stake2);
        stop_cheat_caller_address(alarm_contract_address);
        
        // Check pool info after second user
        let (_final_root, _final_finalized, final_total, final_count) = alarm_dispatcher.get_pool_info(day, period);
        let expected_total = stake1 + stake2; // 100 STRK total
        assert(final_total == expected_total, 'Wrong final total');
        assert(final_count == 2, 'Wrong final count');
        
        stop_cheat_block_timestamp(alarm_contract_address);
    }

    #[test]
    fn test_pool_info_different_periods() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, alarm_contract_address, token_dispatcher) = setup();
        
        let current_time: u64 = 1000000;
        let base_time: u64 = current_time + 86400; // This gives us day 12
        
        // User 1 - AM period (0-12 hours)
        let user1 = get_user_address();
        let wakeup_am = base_time - 10000; // 10000 seconds before = AM period
        let stake_am: u256 = 50000000000000000000; // 50 STRK
        
        // User 2 - PM period (12-24 hours)  
        let user2 = get_another_user_address();
        let wakeup_pm = base_time + 43200 - 10000; // 12 hours - 10000 seconds = PM period, same day
        let stake_pm: u256 = 50000000000000000000; // 50 STRK
        
        let day = base_time / 86400;
        let am_period: u8 = 0;
        let pm_period: u8 = 1;
        
        start_cheat_block_timestamp(alarm_contract_address, current_time);
        let owner = get_owner_address();
        
        // Setup AM user
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.mint(user1, stake_am);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_caller_address(token_dispatcher.contract_address, user1);
        token_dispatcher.approve(alarm_contract_address, stake_am);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_caller_address(alarm_contract_address, user1);
        alarm_dispatcher.set_alarm(wakeup_am, stake_am);
        stop_cheat_caller_address(alarm_contract_address);
        
        // Setup PM user
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.mint(user2, stake_pm);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_caller_address(token_dispatcher.contract_address, user2);
        token_dispatcher.approve(alarm_contract_address, stake_pm);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_caller_address(alarm_contract_address, user2);
        alarm_dispatcher.set_alarm(wakeup_pm, stake_pm);
        stop_cheat_caller_address(alarm_contract_address);
        
        // Check AM pool info (should have user1)
        let (_am_root, _am_finalized, am_total, am_count) = alarm_dispatcher.get_pool_info(day, am_period);
        assert(am_total == stake_am, 'Wrong AM total');
        assert(am_count == 1, 'Wrong AM count');
        
        // Check PM pool info (should have user2)
        let (_pm_root, _pm_finalized, pm_total, pm_count) = alarm_dispatcher.get_pool_info(day, pm_period);
        assert(pm_total == stake_pm, 'Wrong PM total');
        assert(pm_count == 1, 'Wrong PM count');
        
        stop_cheat_block_timestamp(alarm_contract_address);
    }

    #[test]
    fn test_get_pool_info_before_and_after_set_alarm() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, alarm_contract_address, token_dispatcher) = setup();
        
        let day: u64 = 200;
        let period: u8 = 0;
        let user = get_user_address();
        let stake_amount: u256 = 50000000000000000000; // 50 STRK
        let current_time: u64 = day * 86400 + 1000; // Within the day
        let wakeup_time: u64 = current_time + 3600; // 1 hour later
        let merkle_root: felt252 = 'test_root';
        
        // Initial state - pool should be empty and not finalized
        let (initial_root, initial_finalized, initial_total, initial_count) = alarm_dispatcher.get_pool_info(day, period);
        assert(initial_root == 0, 'Initial root should be 0');
        assert(!initial_finalized, 'Should not be finalized');
        assert(initial_total == 0, 'Initial total should be 0');
        assert(initial_count == 0, 'Initial count should be 0');
        
        // Add a user to the pool
        start_cheat_block_timestamp(alarm_contract_address, current_time);
        let owner = get_owner_address();
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.mint(user, stake_amount);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_caller_address(token_dispatcher.contract_address, user);
        token_dispatcher.approve(alarm_contract_address, stake_amount);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_caller_address(alarm_contract_address, user);
        alarm_dispatcher.set_alarm(wakeup_time, stake_amount);
        stop_cheat_caller_address(alarm_contract_address);
        
        // Check pool state after adding user - should have info but no merkle root
        let (mid_root, mid_finalized, mid_total, mid_count) = alarm_dispatcher.get_pool_info(day, period);
        assert(mid_root == 0, 'Root should still be 0');
        assert(!mid_finalized, 'Should not be finalized yet');
        assert(mid_total == stake_amount, 'Total should match stake');
        assert(mid_count == 1, 'Count should be 1');
        
        // Finalize the pool by setting merkle root
        start_cheat_caller_address(alarm_contract_address, owner);
        alarm_dispatcher.set_reward_merkle_root(day, period, merkle_root);
        stop_cheat_caller_address(alarm_contract_address);
        
        // Check final state - should preserve info and be finalized
        let (final_root, final_finalized, final_total, final_count) = alarm_dispatcher.get_pool_info(day, period);
        assert(final_root == merkle_root, 'Root should be set');
        assert(final_finalized, 'Should be finalized');
        assert(final_total == stake_amount, 'Total should be preserved');
        assert(final_count == 1, 'Count should be preserved');
        
        stop_cheat_block_timestamp(alarm_contract_address);
    }

    // ==================== GETTER FUNCTION TESTS ====================

    #[test]
    fn test_get_user_alarm_all_states() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, alarm_contract_address, token_dispatcher) = setup();
        
        let day: u64 = 300;
        let period: u8 = 0;
        let current_time: u64 = day * 86400;
        let wakeup_time: u64 = current_time + 5400; // 1.5 hours into AM period
        let user = get_user_address();
        let stake_amount: u256 = 50000000000000000000; // 50 STRK
        
        // Check initial alarm state (should be inactive)
        let (initial_stake, initial_wakeup, initial_status) = alarm_dispatcher.get_user_alarm(user, day, period);
        assert(initial_stake == 0, 'Initial stake should be 0');
        assert(initial_wakeup == 0, 'Initial wakeup should be 0');
        assert(initial_status == 'Inactive', 'Initial status Inactive');
        
        // Setup and set alarm
        start_cheat_block_timestamp(alarm_contract_address, current_time);
        let owner = get_owner_address();
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.mint(user, stake_amount);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_caller_address(token_dispatcher.contract_address, user);
        token_dispatcher.approve(alarm_contract_address, stake_amount);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_caller_address(alarm_contract_address, user);
        alarm_dispatcher.set_alarm(wakeup_time, stake_amount);
        stop_cheat_caller_address(alarm_contract_address);
        
        // Check alarm state after setting (should be active)
        let (active_stake, active_wakeup, active_status) = alarm_dispatcher.get_user_alarm(user, day, period);
        assert(active_stake == stake_amount, 'Active stake amount wrong');
        assert(active_wakeup == wakeup_time, 'Active wakeup time wrong');
        assert(active_status == 'Active', 'Status is Active');
        
        stop_cheat_block_timestamp(alarm_contract_address);
    }

    #[test]
    #[should_panic(expected: ('Zero_Address',))]
    fn test_get_user_alarm_zero_address() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, _alarm_contract_address, _token_dispatcher) = setup();
        
        let zero_address: ContractAddress = 0.try_into().unwrap();
        let day: u64 = 100;
        let period: u8 = 0;
        
        // This should panic with "Zero_Address"
        alarm_dispatcher.get_user_alarm(zero_address, day, period);
    }

    #[test]
    #[should_panic(expected: ('Invalid_Pool',))]
    fn test_get_user_alarm_invalid_period() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, _alarm_contract_address, _token_dispatcher) = setup();
        
        let user = get_user_address();
        let day: u64 = 100;
        let invalid_period: u8 = 5;
        
        // This should panic with "Invalid_Pool"
        alarm_dispatcher.get_user_alarm(user, day, invalid_period);
    }

    #[test]
    fn test_get_has_claimed_winnings_before_and_after() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, _alarm_contract_address, _token_dispatcher) = setup();
        
        let user = get_user_address();
        let day: u64 = 400;
        let period: u8 = 1; // PM period
        
        // Initial state should be false (not claimed)
        let initial_claimed = alarm_dispatcher.get_has_claimed_winnings(user, day, period);
        assert(!initial_claimed, 'Not claimed initially');
        
        // Test different users and periods
        let another_user = get_another_user_address();
        let another_day: u64 = 401;
        let another_period: u8 = 0;
        
        let another_claimed = alarm_dispatcher.get_has_claimed_winnings(another_user, another_day, another_period);
        assert(!another_claimed, 'Another user not claimed');
    }

    #[test]
    #[should_panic(expected: ('Invalid_Pool',))]
    fn test_get_has_claimed_winnings_invalid_period() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, _alarm_contract_address, _token_dispatcher) = setup();
        
        let user = get_user_address();
        let day: u64 = 100;
        let invalid_period: u8 = 3;
        
        // This should panic with "Invalid_Pool"
        alarm_dispatcher.get_has_claimed_winnings(user, day, invalid_period);
    }

    #[test]
    fn test_pool_info_across_multiple_days() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, alarm_contract_address, token_dispatcher) = setup();
        
        let user1 = get_user_address();
        let user2 = get_another_user_address();
        let stake1: u256 = 50000000000000000000; // 50 STRK
        let stake2: u256 = 50000000000000000000; // 50 STRK
        
        // Day 100, AM period
        let day1: u64 = 100;
        let period1: u8 = 0;
        let time1: u64 = day1 * 86400 + 3600; // 1 hour into day 100
        
        // Day 101, PM period  
        let day2: u64 = 101;
        let period2: u8 = 1;
        let time2: u64 = day2 * 86400 + 50400; // 14 hours into day 101 (PM)
        
        let owner = get_owner_address();
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.mint(user1, stake1);
        token_dispatcher.mint(user2, stake2);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        // Set alarm for day 100 AM
        start_cheat_block_timestamp(alarm_contract_address, time1 - 1000);
        start_cheat_caller_address(token_dispatcher.contract_address, user1);
        token_dispatcher.approve(alarm_contract_address, stake1);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_caller_address(alarm_contract_address, user1);
        alarm_dispatcher.set_alarm(time1, stake1);
        stop_cheat_caller_address(alarm_contract_address);
        
        // Set alarm for day 101 PM
        start_cheat_block_timestamp(alarm_contract_address, time2 - 1000);
        start_cheat_caller_address(token_dispatcher.contract_address, user2);
        token_dispatcher.approve(alarm_contract_address, stake2);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_caller_address(alarm_contract_address, user2);
        alarm_dispatcher.set_alarm(time2, stake2);
        stop_cheat_caller_address(alarm_contract_address);
        
        // Check day 100 AM info
        let (_root1, _finalized1, total1, count1) = alarm_dispatcher.get_pool_info(day1, period1);
        assert(total1 == stake1, 'Day 100 total wrong');
        assert(count1 == 1, 'Day 100 count wrong');
        
        // Check day 101 PM info
        let (_root2, _finalized2, total2, count2) = alarm_dispatcher.get_pool_info(day2, period2);
        assert(total2 == stake2, 'Day 101 total wrong');
        assert(count2 == 1, 'Day 101 count wrong');
        
        // Check other combinations are empty
        let (_empty_root, _empty_finalized, empty_total, empty_count) = alarm_dispatcher.get_pool_info(day1, period2); // Day 100 PM
        assert(empty_total == 0, 'Day 100 PM should be empty');
        assert(empty_count == 0, 'Day 100 PM count should be 0');
        
        stop_cheat_block_timestamp(alarm_contract_address);
    }

    // ==================== CLAIM WINNINGS PANIC TESTS ====================

    #[test]
    #[should_panic(expected: ('WakeUp_Time_Not_Reached',))]
    fn test_claim_winnings_wakeup_time_not_reached() {
        let (_price_converter, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher, winner, _loser) = setup_two_users();
        
        let wakeup_time = 1755709200; // Backend user1 wakeup time (winner)
        let snooze_count: u8 = 0;
        let signature = get_winner_signature(); // Use real signature for winner
        let reward_amount = get_winner_reward_amount(); // Use real reward amount
        let merkle_root = get_test_merkle_root(); // Use real merkle root
        let merkle_proof = array![0x2a34fe87655481f4d6e4abb7d28e9bdb97378f0ad955b0e4792622477bad0da]; // Backend user1 proof
        
        // Set merkle root to finalize pool (day=20320, period=1)
        let owner = get_owner_address();
        start_cheat_caller_address(alarm_contract_address, owner);
        alarm_dispatcher.set_reward_merkle_root(20320, 1, merkle_root);
        stop_cheat_caller_address(alarm_contract_address);
        
        // Set current time BEFORE wakeup time
        start_cheat_block_timestamp(alarm_contract_address, wakeup_time - 1);
        start_cheat_caller_address(alarm_contract_address, winner);
        
        // This should panic with "WakeUp_Time_Not_Reached"
        alarm_dispatcher.claim_winnings(wakeup_time, snooze_count, signature, reward_amount, merkle_proof);
    }

    #[test]
    #[should_panic(expected: ('Invalid_Signature',))]
    fn test_claim_winnings_not_alarm_owner() {
        let (_price_converter, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher, _winner, loser) = setup_two_users();
        
        let wakeup_time = 1755709200; // Backend user1 wakeup time (winner)
        let snooze_count: u8 = 0;
        let (r,s) = get_winner_signature(); // Winner's signature but we'll call as loser
        let reward_amount = get_winner_reward_amount();
        let merkle_root = get_test_merkle_root();
        let merkle_proof = array![];
        
        // Set merkle root to finalize pool
        let owner = get_owner_address();
        start_cheat_caller_address(alarm_contract_address, owner);
        alarm_dispatcher.set_reward_merkle_root(20320, 1, merkle_root);
        stop_cheat_caller_address(alarm_contract_address);
        
        // Set current time AFTER wakeup time
        start_cheat_block_timestamp(alarm_contract_address, wakeup_time + 1);
        start_cheat_caller_address(alarm_contract_address, loser); // Wrong user (loser) trying to claim winner's alarm
        
        // This should panic with "Invalid_Signature" because signature was created for winner, not loser
        alarm_dispatcher.claim_winnings(wakeup_time, snooze_count, (r,s), reward_amount, merkle_proof);
    }

    #[test]
    #[should_panic(expected: ('Not_Alarm_Owner',))]
    fn test_claim_winnings_not_alarm_owner_correct_signature() {
        let (_price_converter, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher, _winner, _loser) = setup_two_users();
        
        let wakeup_time = 1755712800; // Backend user2 wakeup time (loser)
        let snooze_count: u8 = 1;
        let (r,s) = get_loser_signature(); // Loser's own signature
        let reward_amount: u256 = 0; // No reward for snooze
        let merkle_root = get_test_merkle_root();
        let merkle_proof = array![];
        
        // Set merkle root to finalize pool
        let owner = get_owner_address();
        let non_owner = get_non_owner();
        start_cheat_caller_address(alarm_contract_address, owner);
        alarm_dispatcher.set_reward_merkle_root(20320, 1, merkle_root);
        stop_cheat_caller_address(alarm_contract_address);
        
        // Set current time AFTER wakeup time
        start_cheat_block_timestamp(alarm_contract_address, wakeup_time + 1);
        start_cheat_caller_address(alarm_contract_address, non_owner); // non_owner trying to claim loser's alarm

        // This should panic with "Not_Alarm_Owner" because non_owner is trying to claim loser's alarm
        alarm_dispatcher.claim_winnings(wakeup_time, snooze_count, (r,s), reward_amount, merkle_proof);

        // NOTE: WINNER AND LOSER CAN CALL EACH OTHER'S CLAIM FUNCTION 
        // BUT THE CLAIM WILL EVENTUALLY BE UNSUCCESSFULL 
        // THIS IS BECAUSE THE SIGNATURE CONTAINS THE ACTUAL USER'S ADDRESS 
        // WHICH WILL BE COMPARED AND CHECKED TO THE PERSON WHO HAS CALLED THE CLAIM FUNCTION
    }

    #[test]
    #[should_panic(expected: ('Pool_Not_Finalized',))]
    fn test_claim_winnings_pool_not_finalized() {
        let (_price_converter, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher, winner, _loser) = setup_two_users();
        
        let wakeup_time = 1755709200; // Backend user1 wakeup time (winner)
        let snooze_count: u8 = 0;
        let (r,s) = get_winner_signature(); // Winner's signature 
        let reward_amount = get_winner_reward_amount();
        let merkle_proof = array![];
        
        // Don't set merkle root - pool remains unfinalized
        start_cheat_block_timestamp(alarm_contract_address, wakeup_time + 1);
        start_cheat_caller_address(alarm_contract_address, winner);
        
        // This should panic with "Pool_Not_Finalized"
        alarm_dispatcher.claim_winnings(wakeup_time, snooze_count, (r,s), reward_amount, merkle_proof);
    }

    #[test]
    #[should_panic(expected: ('Alarm_Not_Active',))]
    fn test_claim_winnings_alarm_status_changes() {
        let (_price_converter, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher, winner, _loser) = setup_two_users();
        
        let wakeup_time = 1755709200; // Backend user1 wakeup time (winner)
        let snooze_count: u8 = 0;
        let (r,s) = get_winner_signature(); // Winner's signature 
        let reward_amount = get_winner_reward_amount();
        let merkle_root = get_test_merkle_root();
        let merkle_proof = array![0x2a34fe87655481f4d6e4abb7d28e9bdb97378f0ad955b0e4792622477bad0da]; // Backend user1 proof
        let total_payout: u256 = 92500000000000000000; 
        
        // Set merkle root to finalize pool
        let owner = get_owner_address();
        start_cheat_caller_address(alarm_contract_address, owner);
        alarm_dispatcher.set_reward_merkle_root(20320, 1, merkle_root);
        stop_cheat_caller_address(alarm_contract_address);
        
        start_cheat_block_timestamp(alarm_contract_address, wakeup_time + 1);
        start_cheat_caller_address(alarm_contract_address, winner);
        
        // Setup event spy
        let mut spy = spy_events();
        
        // First claim (should work)
        alarm_dispatcher.claim_winnings(wakeup_time, snooze_count, (r,s), reward_amount, merkle_proof.clone());
        
        // Check that WinningsClaimed event was emitted for the successful claim
        let expected_event = AlarmContract::Event::WinningsClaimed(
            WinningsClaimed {
                user: winner,
                wakeup_time: wakeup_time,
                snooze_count: snooze_count,
                winnings_amount: total_payout,
            }
        );
        spy.assert_emitted(@array![(alarm_contract_address, expected_event)]);
        
        // Second claim attempt - should panic with "Alarm_Not_Active" because the status of alarm will change to `Completed` 
        alarm_dispatcher.claim_winnings(wakeup_time, snooze_count, (r,s), reward_amount, merkle_proof);
    }

    #[test]
    fn test_claim_winnings_winner() {
        let (_price_converter, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher, winner, _loser) = setup_two_users();
        
        let wakeup_time = 1755709200; // Backend user1 wakeup time (winner)
        let snooze_count: u8 = 0;
        let (r,s) = get_winner_signature(); // Winner's signature 
        let reward_amount = get_winner_reward_amount();
        let merkle_root = get_test_merkle_root();
        let merkle_proof = array![0x2a34fe87655481f4d6e4abb7d28e9bdb97378f0ad955b0e4792622477bad0da]; // Backend user1 proof
        let total_payout: u256 = 92500000000000000000; 
        
        // Set merkle root to finalize pool
        let owner = get_owner_address();
        start_cheat_caller_address(alarm_contract_address, owner);
        alarm_dispatcher.set_reward_merkle_root(20320, 1, merkle_root);
        stop_cheat_caller_address(alarm_contract_address);
        
        start_cheat_block_timestamp(alarm_contract_address, wakeup_time + 1);
        start_cheat_caller_address(alarm_contract_address, winner);
        
        // Setup event spy
        let mut spy = spy_events();
        
        // First claim (should work)
        alarm_dispatcher.claim_winnings(wakeup_time, snooze_count, (r,s), reward_amount, merkle_proof);
        
        // Check that WinningsClaimed event was emitted
        let expected_event = AlarmContract::Event::WinningsClaimed(
            WinningsClaimed {
                user: winner,
                wakeup_time: wakeup_time,
                snooze_count: snooze_count,
                winnings_amount: total_payout,   
            }
        );
        spy.assert_emitted(@array![(alarm_contract_address, expected_event)]);
        
        stop_cheat_caller_address(alarm_contract_address);
    }

    #[test]
    fn test_claim_winnings_loser() {
        let (_price_converter, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher, _winner, loser) = setup_two_users();
        
        let wakeup_time = 1755712800; // Backend user2 wakeup time (loser)
        let snooze_count: u8 = 1;
        let (r,s) = get_loser_signature(); // Loser's own signature
        let reward_amount: u256 = 0; // No reward for snooze
        let merkle_root = get_test_merkle_root();
        let merkle_proof = array![];
        
        // Set merkle root to finalize pool
        let owner = get_owner_address();
        start_cheat_caller_address(alarm_contract_address, owner);
        alarm_dispatcher.set_reward_merkle_root(20320, 1, merkle_root);
        stop_cheat_caller_address(alarm_contract_address);
        
        start_cheat_block_timestamp(alarm_contract_address, wakeup_time + 1);
        start_cheat_caller_address(alarm_contract_address, loser);
        
        // Setup event spy
        let mut spy = spy_events();
        
        // First claim (should work)
        alarm_dispatcher.claim_winnings(wakeup_time, snooze_count, (r,s), reward_amount, merkle_proof);
        
        // Check that WinningsClaimed event was emitted
        let expected_winnings = 40000000000000000000;
        let expected_event = AlarmContract::Event::WinningsClaimed(
            WinningsClaimed {
                user: loser,
                wakeup_time: wakeup_time,
                snooze_count: snooze_count,
                winnings_amount: expected_winnings,
            }
        );
        spy.assert_emitted(@array![(alarm_contract_address, expected_event)]);
        
        stop_cheat_caller_address(alarm_contract_address);
    }

    #[test]
    #[should_panic(expected: ('Invalid_Signature',))]
    fn test_claim_winnings_invalid_signature_zero_r() {
        let (_price_converter, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher, winner, _loser) = setup_two_users();
        
        let wakeup_time = 1755709200; // Backend user1 wakeup time (winner)
        let snooze_count: u8 = 0;
        let (_,s) = get_winner_signature(); // Invalid signature - r is zero 
        let reward_amount = get_winner_reward_amount();
        let merkle_root = get_test_merkle_root();
        let merkle_proof = array![];
        
        // Set merkle root to finalize pool
        let owner = get_owner_address();
        start_cheat_caller_address(alarm_contract_address, owner);
        alarm_dispatcher.set_reward_merkle_root(20320, 1, merkle_root);
        stop_cheat_caller_address(alarm_contract_address);
        
        start_cheat_block_timestamp(alarm_contract_address, wakeup_time + 1);
        start_cheat_caller_address(alarm_contract_address, winner);
        
        // This should panic with "Invalid_Signature"
        alarm_dispatcher.claim_winnings(wakeup_time, snooze_count, (0,s), reward_amount, merkle_proof);
    }

    #[test]
    #[should_panic(expected: ('Invalid_Signature',))]
    fn test_claim_winnings_invalid_signature_zero_s() {
        let (_price_converter, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher, winner, _loser) = setup_two_users();
        
        let wakeup_time = 1755709200; // Backend user1 wakeup time (winner)
        let snooze_count: u8 = 0;
        let (r,_) = get_winner_signature(); // Invalid signature - s is zero
        let reward_amount = get_winner_reward_amount();
        let merkle_root = get_test_merkle_root();
        let merkle_proof = array![];
        
        // Set merkle root to finalize pool
        let owner = get_owner_address();
        start_cheat_caller_address(alarm_contract_address, owner);
        alarm_dispatcher.set_reward_merkle_root(20320, 1, merkle_root);
        stop_cheat_caller_address(alarm_contract_address);
        
        start_cheat_block_timestamp(alarm_contract_address, wakeup_time + 1);
        start_cheat_caller_address(alarm_contract_address, winner);
        
        // This should panic with "Invalid_Signature"
        alarm_dispatcher.claim_winnings(wakeup_time, snooze_count, (r,0), reward_amount, merkle_proof);
    }

    // // ==================== INTERNAL FUNCTIONS LOGIC TESTS ====================

    #[test]
    fn test_calculate_stake_return_no_snooze() {
        let (_price_converter, alarm_dispatcher, _price_converter_address, alarm_contract_address, token_dispatcher, winner, _loser) = setup_two_users();
        
        // Test stake return calculation for no snooze (snooze_count = 0)
        let wakeup_time = 1755709200; // Backend user1 wakeup time (winner)
        let snooze_count: u8 = 0; // No snooze
        let (r,s) = get_winner_signature();
        let reward_amount = get_winner_reward_amount();
        let merkle_root = get_test_merkle_root();
        let merkle_proof = array![0x2a34fe87655481f4d6e4abb7d28e9bdb97378f0ad955b0e4792622477bad0da]; // Backend user1 proof
        
        // Set merkle root to finalize pool
        let owner = get_owner_address();
        start_cheat_caller_address(alarm_contract_address, owner);
        alarm_dispatcher.set_reward_merkle_root(20320, 1, merkle_root);
        stop_cheat_caller_address(alarm_contract_address);
        
        start_cheat_block_timestamp(alarm_contract_address, wakeup_time + 1);
        start_cheat_caller_address(alarm_contract_address, winner);
        
        // Get initial token balance
        let initial_balance = token_dispatcher.balance_of(winner);
        
        // Claim winnings
        alarm_dispatcher.claim_winnings(wakeup_time, snooze_count, (r,s), reward_amount, merkle_proof);
        
        // Check final balance - should get full stake back (50 STRK) + reward (42.5 STRK)
        let final_balance = token_dispatcher.balance_of(winner);
        let expected_stake_return: u256 = 50000000000000000000; // Full 50 STRK stake
        let expected_total = expected_stake_return + reward_amount; // 92.5 STRK total
        assert(final_balance == initial_balance + expected_total, 'Wrong stake return no snooze');
    }

    #[test]
    fn test_calculate_stake_return_one_snooze() {
        let (_price_converter, alarm_dispatcher, _price_converter_address, alarm_contract_address, token_dispatcher, users) = setup_five_users();
        
        // Test stake return calculation for 1 snooze (20% slash)
        let wakeup_times = get_five_users_wakeup_times();
        let wakeup_time = *wakeup_times.at(1); // User2's wakeup time
        let snooze_count: u8 = 1; // 1 snooze = 20% slash = 80% return
        let signatures = get_five_users_signatures();
        let (r, s) = *signatures.at(1); // User2's signature
        let reward_amount: u256 = 0; // No reward for snooze
        let merkle_proof = array![]; // User2's merkle proof (empty for losers)
        
        // Set merkle root to finalize pool
        let owner = get_owner_address();
        start_cheat_caller_address(alarm_contract_address, owner);
        alarm_dispatcher.set_reward_merkle_root(get_five_users_pool_day(), get_five_users_pool_period(), get_five_users_merkle_root());
        stop_cheat_caller_address(alarm_contract_address);
        
        start_cheat_block_timestamp(alarm_contract_address, wakeup_time + 1);
        start_cheat_caller_address(alarm_contract_address, *users.at(1)); // Use user2 (index 1)
        
        let initial_balance = token_dispatcher.balance_of(*users.at(1));
        
        alarm_dispatcher.claim_winnings(wakeup_time, snooze_count, (r, s), reward_amount, merkle_proof);
        
        let final_balance = token_dispatcher.balance_of(*users.at(1));
        let expected_return = 40000000000000000000_u256; // 80% of 50 STRK = 40 STRK
        assert(final_balance == initial_balance + expected_return, 'Wrong stake return 1 snooze');
    }

    #[test]
    fn test_calculate_stake_return_two_snoozes() {
        let (_price_converter, alarm_dispatcher, _price_converter_address, alarm_contract_address, token_dispatcher, users) = setup_five_users();
        
        // Test stake return calculation for 2 snoozes (50% slash)
        let wakeup_times = get_five_users_wakeup_times();
        let wakeup_time = *wakeup_times.at(2); // User3's wakeup time
        let snooze_count: u8 = 2; // 2 snoozes = 50% slash = 50% return
        let signatures = get_five_users_signatures();
        let (r, s) = *signatures.at(2); // User3's signature
        let reward_amount: u256 = 0; // No reward for snooze
        let merkle_proof = array![]; // User3's merkle proof (empty for losers)
        
        // Set merkle root to finalize pool
        let owner = get_owner_address();
        start_cheat_caller_address(alarm_contract_address, owner);
        alarm_dispatcher.set_reward_merkle_root(get_five_users_pool_day(), get_five_users_pool_period(), get_five_users_merkle_root());
        stop_cheat_caller_address(alarm_contract_address);
        
        start_cheat_block_timestamp(alarm_contract_address, wakeup_time + 1);
        start_cheat_caller_address(alarm_contract_address, *users.at(2)); // Use user3 (index 2)
        
        let initial_balance = token_dispatcher.balance_of(*users.at(2));
        
        alarm_dispatcher.claim_winnings(wakeup_time, snooze_count, (r, s), reward_amount, merkle_proof);
        
        let final_balance = token_dispatcher.balance_of(*users.at(2));
        let expected_return = 25000000000000000000_u256; // 50% of 50 STRK = 25 STRK
        assert(final_balance == initial_balance + expected_return, 'Wrong stake return 2 snoozes');
    }

    #[test]
    fn test_calculate_stake_return_three_plus_snoozes() {
        let (_price_converter, alarm_dispatcher, _price_converter_address, alarm_contract_address, token_dispatcher, users) = setup_five_users();
        
        // Test stake return calculation for 3+ snoozes (100% slash)
        let wakeup_times = get_five_users_wakeup_times();
        let wakeup_time = *wakeup_times.at(3); // User4's wakeup time
        let snooze_count: u8 = 3; // 3+ snoozes = 100% slash = 0% return
        let signatures = get_five_users_signatures();
        let (r, s) = *signatures.at(3); // User4's signature
        let reward_amount: u256 = 0; // No reward for snooze
        let merkle_proof = array![]; // User4's merkle proof (empty for losers)
        
        // Set merkle root to finalize pool
        let owner = get_owner_address();
        start_cheat_caller_address(alarm_contract_address, owner);
        alarm_dispatcher.set_reward_merkle_root(get_five_users_pool_day(), get_five_users_pool_period(), get_five_users_merkle_root());
        stop_cheat_caller_address(alarm_contract_address);
        
        start_cheat_block_timestamp(alarm_contract_address, wakeup_time + 1);
        start_cheat_caller_address(alarm_contract_address, *users.at(3)); // Use user4 (index 3)
        
        let initial_balance = token_dispatcher.balance_of(*users.at(3));
        
        alarm_dispatcher.claim_winnings(wakeup_time, snooze_count, (r, s), reward_amount, merkle_proof);
        
        let final_balance = token_dispatcher.balance_of(*users.at(3));
        // Should get 0 back due to 100% slash
        assert(final_balance == initial_balance, 'Wrong stake return 3+ snoozes');
    }

    #[test]
    fn test_alarm_status_update_after_claim() {
        let (_price_converter, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher, winner, _loser) = setup_two_users();
        
        let wakeup_time = 1755709200; // Backend user1 wakeup time (winner)
        let snooze_count: u8 = 0; // No snooze
        let (r,s) = get_winner_signature();
        let reward_amount = get_winner_reward_amount();
        let merkle_root = get_test_merkle_root();
        let merkle_proof = array![0x2a34fe87655481f4d6e4abb7d28e9bdb97378f0ad955b0e4792622477bad0da]; // Backend user1 proof
        
        // Set merkle root to finalize pool
        let owner = get_owner_address();
        start_cheat_caller_address(alarm_contract_address, owner);
        alarm_dispatcher.set_reward_merkle_root(20320, 1, merkle_root);
        stop_cheat_caller_address(alarm_contract_address);
        
        // Check initial alarm status (day=20320, period=1 for winner)
        let (_stake_amount, _wakeup_time_stored, status) = alarm_dispatcher.get_user_alarm(winner, 20320, 1);
        assert(status == 'Active', 'Status is Active');
        
        start_cheat_block_timestamp(alarm_contract_address, wakeup_time + 1);
        start_cheat_caller_address(alarm_contract_address, winner);
        
        alarm_dispatcher.claim_winnings(wakeup_time, snooze_count, (r,s), reward_amount, merkle_proof);
        
        // Check alarm status after claim
        let (_stake_amount_after, _wakeup_time_after, status_after) = alarm_dispatcher.get_user_alarm(winner, 20320, 1);
        assert(status_after == 'Completed', 'Status Completed');
        
        // Check claimed status
        let has_claimed = alarm_dispatcher.get_has_claimed_winnings(winner, 20320, 1);
        assert(has_claimed == true, 'Should be marked as claimed');
    }

    #[test]
    fn test_event_emission_winnings_claimed() {
        let (_price_converter, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher, winner, _loser) = setup_two_users();
        
        let wakeup_time = 1755709200; // Backend user1 wakeup time (winner)
        let snooze_count: u8 = 0; // No snooze
        let (r,s) = get_winner_signature();
        let reward_amount = get_winner_reward_amount();
        let merkle_root = get_test_merkle_root();
        let merkle_proof = array![0x2a34fe87655481f4d6e4abb7d28e9bdb97378f0ad955b0e4792622477bad0da]; // Backend user1 proof
        let total_payout: u256 = 92500000000000000000; 
        
        // Set merkle root to finalize pool
        let owner = get_owner_address();
        start_cheat_caller_address(alarm_contract_address, owner);
        alarm_dispatcher.set_reward_merkle_root(20320, 1, merkle_root);
        stop_cheat_caller_address(alarm_contract_address);
        
        // Set up event spy
        let mut spy = spy_events();
        
        start_cheat_block_timestamp(alarm_contract_address, wakeup_time + 1);
        start_cheat_caller_address(alarm_contract_address, winner);

        alarm_dispatcher.claim_winnings(wakeup_time, snooze_count, (r,s), reward_amount, merkle_proof);

        // Check that WinningsClaimed event was emitted
        let expected_event = AlarmContract::Event::WinningsClaimed(
            WinningsClaimed {
                user: winner,
                wakeup_time: wakeup_time,
                snooze_count: snooze_count,
                winnings_amount: total_payout
            }
        );
        spy.assert_emitted(@array![(alarm_contract_address, expected_event)]);
    }
    

    // // ==================== 5 USERS TEST ====================

    #[test]
    fn test_five_users_end_to_end_claim_winnings() {
        let (_price_converter, alarm_dispatcher, _price_converter_address, alarm_contract_address, token_dispatcher, users) = setup_five_users();
        
        // Get all the test data
        let wakeup_times = get_five_users_wakeup_times();
        let snooze_counts = get_five_users_snooze_counts();
        let signatures = get_five_users_signatures();
        let merkle_root = get_five_users_merkle_root();
        let reward_amounts = get_five_users_reward_amounts();
        let total_payouts = get_five_users_total_payouts();
        let pool_day = get_five_users_pool_day();
        let pool_period = get_five_users_pool_period();
        
        // Set merkle root to finalize pool
        let owner = get_owner_address();
        start_cheat_caller_address(alarm_contract_address, owner);
        alarm_dispatcher.set_reward_merkle_root(pool_day, pool_period, merkle_root);
        stop_cheat_caller_address(alarm_contract_address);
        
        // Set current time AFTER all wakeup times
        let latest_wakeup_time = 1755723600; // 4:20 PM (user5's time)
        start_cheat_block_timestamp(alarm_contract_address, latest_wakeup_time + 1);
        
        // Setup event spy
        let mut spy = spy_events();
        
        // Process all 5 users
        let mut i = 0;
        loop {
            if i >= users.len() {
                break;
            }
            
            let user = *users.at(i);
            let wakeup_time = *wakeup_times.at(i);
            let snooze_count = *snooze_counts.at(i);
            let (r, s) = *signatures.at(i);
            let reward_amount = *reward_amounts.at(i);
            let total_payout = *total_payouts.at(i);
            
            // Get merkle proof for current user from backend data
            let merkle_proof = if i == 0 {
                array![0x2a34fe87655481f4d6e4abb7d28e9bdb97378f0ad955b0e4792622477bad0da] // user1
            } else if i == 4 {
                array![0x10b640f3e92e0c2b2ba27277e41e003e32928bc5b22a5dfa5a93a2334501524] // user5
            } else {
                array![] // users 2, 3, 4 have no proof (not winners)
            };
            
            // Set caller to current user
            start_cheat_caller_address(alarm_contract_address, user);
            
            // Get initial balance
            let initial_balance = token_dispatcher.balance_of(user);
            
            // Claim winnings
            alarm_dispatcher.claim_winnings(wakeup_time, snooze_count, (r, s), reward_amount, merkle_proof);
            
            // Check final balance
            let final_balance = token_dispatcher.balance_of(user);
            assert(final_balance == initial_balance + total_payout, 'Wrong payout amount');
            
            // Check that WinningsClaimed event was emitted
            let expected_event = AlarmContract::Event::WinningsClaimed(
                WinningsClaimed {
                    user: user,
                    wakeup_time: wakeup_time,
                    snooze_count: snooze_count,
                    winnings_amount: total_payout,
                }
            );
            spy.assert_emitted(@array![(alarm_contract_address, expected_event)]);
            
            // Check alarm status is now Completed
            let (_, _, status) = alarm_dispatcher.get_user_alarm(user, pool_day, pool_period);
            assert(status == 'Completed', 'Status not Completed');
            
            // Check claim status
            let has_claimed = alarm_dispatcher.get_has_claimed_winnings(user, pool_day, pool_period);
            assert(has_claimed == true, 'Should be marked claimed');
            
            stop_cheat_caller_address(alarm_contract_address);
            
            i += 1;
        };
        
        stop_cheat_block_timestamp(alarm_contract_address);
    }

    fn setup_five_users() -> (IPriceConverterDispatcher, IAlarmContractDispatcher, ContractAddress, ContractAddress, IMockERC20Dispatcher, Array<ContractAddress>) {
        // Setup initial contracts
        let (_price_converter_dispatcher, alarm_dispatcher, price_converter_address, alarm_contract_address, token_dispatcher) = setup();
        
        // Define 5 user addresses from alarm_inputs.json
        let user1: ContractAddress = 0x068e5011bbef90f8227382ea517277b631339205af237d5e853573248fc726a4.try_into().unwrap();  // snooze = 0, stake = 10 ETH
        let user2: ContractAddress = 0x04b30350238863e574f135c84b48f860be87c90afc37843709b4613aab32f018.try_into().unwrap();  // snooze = 1, stake = 5 ETH
        let user3: ContractAddress = 0x043abd6f2049a4de67a533068dd90336887eab3786864c50e2b2ca8be17de564.try_into().unwrap();  // snooze = 2, stake = 8 ETH
        let user4: ContractAddress = 0x04e1cd2b21092ceb6999a2480bcc12a8b206867885d14a28aa7a1eb2169b015a.try_into().unwrap();  // snooze = 3, stake = 12 ETH
        let user5: ContractAddress = 0x07bd8a637e29d94961f31c9561b952069057a5a9cad3179303b9c37710eb2cdd.try_into().unwrap();  // snooze = 0, stake = 15 ETH
        
        // Define stake amounts from alarm_inputs.json
        let user1_stake: u256 = 50000000000000000000; // 50 STRK
        let user2_stake: u256 = 50000000000000000000; // 50 STRK
        let user3_stake: u256 = 50000000000000000000; // 50 STRK
        let user4_stake: u256 = 50000000000000000000; // 50 STRK
        let user5_stake: u256 = 50000000000000000000; // 50 STRK

        // Pool settings from alarm_inputs.json
        let _pool_day: u64 = 20320; // Day from JSON
        let _pool_period: u8 = 1; // PM period from JSON
        
        // Individual wakeup times from alarm_inputs.json (all PM times)
        let wakeup_times = get_five_users_wakeup_times();
        
        // Set current timestamp to before earliest wakeup time for alarm setting
        let earliest_wakeup = 1755709200; // 12:20 PM
        start_cheat_block_timestamp(alarm_contract_address, earliest_wakeup - 86400); // 1 day before
        
        let owner = get_owner_address();
        let users = array![user1, user2, user3, user4, user5];
        let stakes = array![user1_stake, user2_stake, user3_stake, user4_stake, user5_stake];
        
        // Setup all 5 users
        let mut i = 0;
        loop {
            if i >= users.len() {
                break;
            }
            
            let user = *users.at(i);
            let stake = *stakes.at(i);
            let wakeup_time = *wakeup_times.at(i);
            
            // Give user tokens (using token contract context)
            start_cheat_caller_address(token_dispatcher.contract_address, owner);
            token_dispatcher.transfer(user, stake * 2); // Give 2x stake amount
            stop_cheat_caller_address(token_dispatcher.contract_address);
            
            // User approves alarm contract and sets alarm
            start_cheat_caller_address(token_dispatcher.contract_address, user);
            token_dispatcher.approve(alarm_contract_address, stake);
            stop_cheat_caller_address(token_dispatcher.contract_address);
            
            start_cheat_caller_address(alarm_contract_address, user);
            alarm_dispatcher.set_alarm(wakeup_time, stake);
            stop_cheat_caller_address(alarm_contract_address);
            
            i += 1;
        };
        
        stop_cheat_block_timestamp(alarm_contract_address);
        
        // Return everything including users array
        (_price_converter_dispatcher, alarm_dispatcher, price_converter_address, alarm_contract_address, token_dispatcher, users)
    }

    // Helper functions for 5 users test data based on alarm_inputs.json
    fn get_five_users_addresses() -> Array<ContractAddress> {
        array![
            0x068e5011bbef90f8227382ea517277b631339205af237d5e853573248fc726a4.try_into().unwrap(), // user1
            0x04b30350238863e574f135c84b48f860be87c90afc37843709b4613aab32f018.try_into().unwrap(), // user2  
            0x043abd6f2049a4de67a533068dd90336887eab3786864c50e2b2ca8be17de564.try_into().unwrap(), // user3
            0x04e1cd2b21092ceb6999a2480bcc12a8b206867885d14a28aa7a1eb2169b015a.try_into().unwrap(), // user4
            0x07bd8a637e29d94961f31c9561b952069057a5a9cad3179303b9c37710eb2cdd.try_into().unwrap()  // user5
        ]
    }

    fn get_five_users_stakes() -> Array<u256> {
        array![
            10000000000000000000, // 10 ETH - user1
            5000000000000000000,  // 5 ETH - user2
            8000000000000000000,  // 8 ETH - user3
            12000000000000000000, // 12 ETH - user4
            15000000000000000000  // 15 ETH - user5
        ]
    }

    fn get_five_users_snooze_counts() -> Array<u8> {
        array![
            0, // user1 - no snooze
            1, // user2 - 1 snooze  
            2, // user3 - 2 snoozes
            3, // user4 - 3 snoozes
            0  // user5 - no snooze
        ]
    }

    fn get_five_users_wakeup_times() -> Array<u64> {
        array![
            1755709200, // user1 - 12:20 PM
            1755712800, // user2 - 1:20 PM
            1755716400, // user3 - 2:20 PM
            1755720000, // user4 - 3:20 PM
            1755723600  // user5 - 4:20 PM
        ]
    }

    fn get_common_wakeup_time() -> u64 {
        1755709200 // Earliest time - 12:20 PM (from alarm_inputs.json)
    }

    fn get_five_users_pool_day() -> u64 {
        20320 // From alarm_inputs.json
    }

    fn get_five_users_pool_period() -> u8 {
        1 // PM period from alarm_inputs.json
    }

    // Helper functions for 5 users test data from alarm_outputs.json
    fn get_five_users_signatures() -> Array<(felt252, felt252)> {
        array![
            (0x7b28daddd155d216a641ba8b934d7a4f67ed69b8602e19779f4ffa0a54b5201, 0x248f956b99a28192d801979b0b52596353b1753ba819ba706ada926b51affc9), // user1
            (0x3beac28859e0d2e448386aec669252a6e9c8c69f697c16d04fc7780af58fab8, 0x3e65d6f1773078655df4c3c6030c76720fc9713c8045bd7e8ab6c5e0153fb3f), // user2
            (0x21a2ff270bb63f1c771424e99a85489df339e81fb3ed9c75fa46e4ab96b360b, 0x209ee827328d8bdf0e7f1602e59b82bd2dcd1b2713b409f04b2d0862c60fd3a), // user3
            (0x14613f172d41da38932d5b8842901f63d8746d4902e14d488b9a0fe3d7e5fa1, 0x171d3afda495c3f9c4a74a167dc09f95401ee306f678955b8358e7445cf9100), // user4
            (0x13707ce1bf1724e59b39fdd777b8aad2d98398af0a6affabd476f888fdff4c6, 0x5a59841847b196209b9f99e2f45f602a65d43bd714699f835a4361f70774d5d)  // user5
        ]
    }

    fn get_five_users_merkle_root() -> felt252 {
        0x2e6cb2847142da7d17991d0496834001aa726bf7c145c80426fd4c28eff796a // From updated alarm_outputs.json
    }

    fn get_five_users_merkle_proofs() -> Array<Array<felt252>> {
        array![
            array![0x2a34fe87655481f4d6e4abb7d28e9bdb97378f0ad955b0e4792622477bad0da], // user1 merkle proof
            array![], // user2 - no proof (not winner)
            array![], // user3 - no proof (not winner)
            array![], // user4 - no proof (not winner)
            array![0x10b640f3e92e0c2b2ba27277e41e003e32928bc5b22a5dfa5a93a2334501524]  // user5 merkle proof
        ]
    }

    fn get_five_users_reward_amounts() -> Array<u256> {
        array![
            42500000000000000000,  // user1 - 42.5 STRK reward
            0,                      // user2 - no reward (snoozed)
            0,                      // user3 - no reward (snoozed)
            0,                      // user4 - no reward (snoozed)
            42500000000000000000   // user5 - 42.5 STRK reward
        ]
    }

    fn get_five_users_total_payouts() -> Array<u256> {
        array![
            92500000000000000000, // user1 - 92.5 STRK total (50 stake + 42.5 reward)
            40000000000000000000, // user2 - 40 STRK total (80% of 50)
            25000000000000000000, // user3 - 25 STRK total (50% of 50)
            0,                    // user4 - 0 STRK total (100% slashed)
            92500000000000000000  // user5 - 92.5 STRK total (50 + 42.5)
        ]
    }

    fn get_five_users_is_winner() -> Array<bool> {
        array![
            true,  // user1 - winner (no snooze)
            false, // user2 - not winner (1 snooze)
            false, // user3 - not winner (2 snoozes)
            false, // user4 - not winner (3 snoozes)
            true   // user5 - winner (no snooze)
        ]
    }

    // ==================== EDIT/DELETE ALARM TESTS ====================

    #[test]
    fn test_edit_alarm_updates_balances_and_state() {
        let (_price_converter, alarm_dispatcher, _pc_addr, alarm_addr, token_dispatcher) = setup();

        // Setup: user sets an alarm
        let owner = get_owner_address();
        let user = get_user_address();
        let stake_initial: u256 = 50000000000000000000; // 50 STRK
        let current_time: u64 = 1_000_000;
        let wakeup_old: u64 = current_time + 86_400; // +1 day
        start_cheat_block_timestamp(alarm_addr, current_time);
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.mint(user, stake_initial * 3); // enough for operations
        stop_cheat_caller_address(token_dispatcher.contract_address);
        start_cheat_caller_address(token_dispatcher.contract_address, user);
        token_dispatcher.approve(alarm_addr, stake_initial);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        start_cheat_caller_address(alarm_addr, user);
        alarm_dispatcher.set_alarm(wakeup_old, stake_initial);
        stop_cheat_caller_address(alarm_addr);

        // Edit to a new future time with a new stake
        let new_stake: u256 = 30000000000000000000; // 30 STRK
        let wakeup_new: u64 = wakeup_old + 3600; // +1h

        // Track balances: contract and owner (protocol fees)
        let fees_addr = owner; // in tests, we passed owner as fees address
        let fees_before = token_dispatcher.balance_of(fees_addr);
        let user_before = token_dispatcher.balance_of(user);
        let contract_before = token_dispatcher.balance_of(alarm_addr);

        // Approve for new stake
        start_cheat_caller_address(token_dispatcher.contract_address, user);
        token_dispatcher.approve(alarm_addr, new_stake);
        stop_cheat_caller_address(token_dispatcher.contract_address);

        // Call edit_alarm
        start_cheat_caller_address(alarm_addr, user);
        alarm_dispatcher.edit_alarm(wakeup_old, wakeup_new, new_stake);
        stop_cheat_caller_address(alarm_addr);

        // 20% of old stake slashed to fees, 80% returned; new_stake pulled to contract
        let fees_after = token_dispatcher.balance_of(fees_addr);
        let user_after = token_dispatcher.balance_of(user);
        let contract_after = token_dispatcher.balance_of(alarm_addr);

        let expected_fees_increase: u256 = (stake_initial * 20) / 100; // 10 STRK
        let expected_user_net_change: u256 = ((stake_initial * 80) / 100) - new_stake; // +40 -30 = +10 STRK
        assert(fees_after == fees_before + expected_fees_increase, 'Fees not 20%');
        assert(user_after == user_before + expected_user_net_change, 'User refund wrong');
        // Avoid underflow by balancing both sides: after + old_stake == before + new_stake
        let lhs: u256 = contract_after + stake_initial;
        let rhs: u256 = contract_before + new_stake;
        assert(lhs == rhs, 'Contract balance wrong');

        // Check alarm moved to new wakeup and stake updated
        let day_new = wakeup_new / 86400;
        let period_new_u64 = (wakeup_new % 86400) / 43200;
        let period_new: u8 = period_new_u64.try_into().unwrap();
        let (stored_stake, stored_wakeup, status) = alarm_dispatcher.get_user_alarm(user, day_new, period_new);
        assert(stored_stake == new_stake, 'Edited stake mismatch');
        assert(stored_wakeup == wakeup_new, 'Edited wakeup mismatch');
        assert(status == 'Active', 'Edited alarm not Active');

        stop_cheat_block_timestamp(alarm_addr);
    }

    #[test]
    #[should_panic(expected: ('Invalid_WakeUp_Time',))]
    fn test_edit_alarm_rejected_when_time_passed() {
        let (_pc, alarm_dispatcher, _pc_addr, alarm_addr, token_dispatcher) = setup();
        let owner = get_owner_address();
        let user = get_user_address();
        let stake: u256 = 50000000000000000000;
        let t0: u64 = 1_000_000;
        let wakeup: u64 = t0 + 100;

        start_cheat_block_timestamp(alarm_addr, t0);
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.mint(user, stake * 2);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        start_cheat_caller_address(token_dispatcher.contract_address, user);
        token_dispatcher.approve(alarm_addr, stake);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        start_cheat_caller_address(alarm_addr, user);
        alarm_dispatcher.set_alarm(wakeup, stake);
        stop_cheat_caller_address(alarm_addr);

        // Advance to wakeup time (blocked)
        start_cheat_block_timestamp(alarm_addr, wakeup);
        start_cheat_caller_address(alarm_addr, user);
        alarm_dispatcher.edit_alarm(wakeup, wakeup + 3600, stake);
    }

    #[test]
    #[should_panic(expected: ('Pool_Not_Finalized',))]
    fn test_edit_alarm_rejected_when_pool_finalized() {
        let (_pc, alarm_dispatcher, _pc_addr, alarm_addr, token_dispatcher) = setup();
        let owner = get_owner_address();
        let user = get_user_address();
        let stake: u256 = 50000000000000000000;
        let now: u64 = 2_000_000;
        let wakeup: u64 = now + 10_000;
        start_cheat_block_timestamp(alarm_addr, now);
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.mint(user, stake * 2);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        start_cheat_caller_address(token_dispatcher.contract_address, user);
        token_dispatcher.approve(alarm_addr, stake);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        start_cheat_caller_address(alarm_addr, user);
        alarm_dispatcher.set_alarm(wakeup, stake);
        stop_cheat_caller_address(alarm_addr);

        let day = wakeup / 86400; let period = ((wakeup % 86400) / 43200).try_into().unwrap();
        start_cheat_caller_address(alarm_addr, owner);
        alarm_dispatcher.set_reward_merkle_root(day, period, 'root');
        stop_cheat_caller_address(alarm_addr);

        start_cheat_caller_address(alarm_addr, user);
        alarm_dispatcher.edit_alarm(wakeup, wakeup + 3600, stake);
    }

    #[test]
    fn test_delete_alarm_slashes_and_marks_deleted() {
        let (_pc, alarm_dispatcher, _pc_addr, alarm_addr, token_dispatcher) = setup();
        let owner = get_owner_address();
        let user = get_user_address();
        let stake: u256 = 50000000000000000000;
        let now: u64 = 3_000_000;
        let wakeup: u64 = now + 20_000;
        start_cheat_block_timestamp(alarm_addr, now);
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.mint(user, stake);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        start_cheat_caller_address(token_dispatcher.contract_address, user);
        token_dispatcher.approve(alarm_addr, stake);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        start_cheat_caller_address(alarm_addr, user);
        alarm_dispatcher.set_alarm(wakeup, stake);
        stop_cheat_caller_address(alarm_addr);

        let fees_before = token_dispatcher.balance_of(owner);
        let user_before = token_dispatcher.balance_of(user);
        let contract_before = token_dispatcher.balance_of(alarm_addr);

        start_cheat_caller_address(alarm_addr, user);
        alarm_dispatcher.delete_alarm(wakeup);
        stop_cheat_caller_address(alarm_addr);

        let fees_after = token_dispatcher.balance_of(owner);
        let user_after = token_dispatcher.balance_of(user);
        let contract_after = token_dispatcher.balance_of(alarm_addr);

        assert(fees_after == fees_before + (stake / 2), 'Fees not 50%');
        assert(user_after == user_before + (stake / 2), 'User refund not 50%');
        assert(contract_after == contract_before - stake, 'Contract not reduced by stake');

        let day = wakeup / 86400; let period = ((wakeup % 86400) / 43200).try_into().unwrap();
        let (_s, _w, status) = alarm_dispatcher.get_user_alarm(user, day, period);
        assert(status == 'Deleted', 'Alarm status not Deleted');

        stop_cheat_block_timestamp(alarm_addr);
    }

    #[test]
    #[should_panic(expected: ('Invalid_WakeUp_Time',))]
    fn test_delete_alarm_rejected_when_time_passed() {
        let (_pc, alarm_dispatcher, _pc_addr, alarm_addr, token_dispatcher) = setup();
        let owner = get_owner_address();
        let user = get_user_address();
        let stake: u256 = 50000000000000000000;
        let now: u64 = 4_000_000;
        let wakeup: u64 = now + 100;
        start_cheat_block_timestamp(alarm_addr, now);
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.mint(user, stake);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        start_cheat_caller_address(token_dispatcher.contract_address, user);
        token_dispatcher.approve(alarm_addr, stake);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        start_cheat_caller_address(alarm_addr, user);
        alarm_dispatcher.set_alarm(wakeup, stake);
        stop_cheat_caller_address(alarm_addr);

        start_cheat_block_timestamp(alarm_addr, wakeup);
        start_cheat_caller_address(alarm_addr, user);
        alarm_dispatcher.delete_alarm(wakeup);
    }

    #[test]
    #[should_panic(expected: ('Pool_Not_Finalized',))]
    fn test_delete_alarm_rejected_when_pool_finalized() {
        let (_pc, alarm_dispatcher, _pc_addr, alarm_addr, token_dispatcher) = setup();
        let owner = get_owner_address();
        let user = get_user_address();
        let stake: u256 = 50000000000000000000;
        let now: u64 = 5_000_000;
        let wakeup: u64 = now + 1_000;
        start_cheat_block_timestamp(alarm_addr, now);
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.mint(user, stake);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        start_cheat_caller_address(token_dispatcher.contract_address, user);
        token_dispatcher.approve(alarm_addr, stake);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        start_cheat_caller_address(alarm_addr, user);
        alarm_dispatcher.set_alarm(wakeup, stake);
        stop_cheat_caller_address(alarm_addr);

        let day = wakeup / 86400; let period = ((wakeup % 86400) / 43200).try_into().unwrap();
        start_cheat_caller_address(alarm_addr, owner);
        alarm_dispatcher.set_reward_merkle_root(day, period, 'root');
        stop_cheat_caller_address(alarm_addr);

        start_cheat_caller_address(alarm_addr, user);
        alarm_dispatcher.delete_alarm(wakeup);
    }

    #[test]
    fn test_multi_users_edit_delete_finalize_and_claim_subset() {
        let (_pc, alarm_dispatcher, _pc_addr, alarm_addr, token_dispatcher, users) = setup_five_users();

        // Users array: [u1,u2,u3,u4,u5]
        let wakeups = get_five_users_wakeup_times();
        let rewards = get_five_users_reward_amounts();
        let pool_day = get_five_users_pool_day();
        let pool_period = get_five_users_pool_period();

        // u1 edits alarm (no claim later in this test)
        let u1 = *users.at(0);
        let u1_wakeup_old = *wakeups.at(0);
        let u1_new_stake: u256 = 30000000000000000000;
        let u1_wakeup_new = u1_wakeup_old + 600; // +10 min

        // approve for new stake and edit
        start_cheat_caller_address(token_dispatcher.contract_address, u1);
        token_dispatcher.approve(alarm_addr, u1_new_stake);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        start_cheat_caller_address(alarm_addr, u1);
        alarm_dispatcher.edit_alarm(u1_wakeup_old, u1_wakeup_new, u1_new_stake);
        stop_cheat_caller_address(alarm_addr);

        // u4 deletes alarm
        let u4 = *users.at(3);
        let u4_wakeup = *wakeups.at(3);
        start_cheat_caller_address(alarm_addr, u4);
        alarm_dispatcher.delete_alarm(u4_wakeup);
        stop_cheat_caller_address(alarm_addr);

        // Finalize pool (for original pool)
        let merkle_root = get_five_users_merkle_root();
        start_cheat_caller_address(alarm_addr, get_owner_address());
        alarm_dispatcher.set_reward_merkle_root(pool_day, pool_period, merkle_root);
        stop_cheat_caller_address(alarm_addr);

        // Advance time past last wakeup and claim for u5 only (winner)
        let latest = 1755723600_u64; // from helpers
        start_cheat_block_timestamp(alarm_addr, latest + 1);
        let u5 = *users.at(4);
        let (r5, s5) = *get_five_users_signatures().at(4);
        let proof5 = array![0x10b640f3e92e0c2b2ba27277e41e003e32928bc5b22a5dfa5a93a2334501524];
        start_cheat_caller_address(alarm_addr, u5);
        let reward5 = *rewards.at(4);
        alarm_dispatcher.claim_winnings(*wakeups.at(4), 0, (r5,s5), reward5, proof5);
        stop_cheat_caller_address(alarm_addr);

        stop_cheat_block_timestamp(alarm_addr);
    }}