#[cfg(test)]
mod tests {
    use everydayapp::price_converter::price_converter::{
        IPriceConverterDispatcher,
    };
    use everydayapp::alarm::alarm::{IAlarmContractDispatcher, IAlarmContractDispatcherTrait};
    use everydayapp::alarm::alarm::AlarmContract;
    use everydayapp::alarm::alarm::AlarmContract::{AlarmSet, VerifiedSignerSet, MerkleRootSet};
    use snforge_std::{
        ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address, 
        stop_cheat_caller_address, start_cheat_block_timestamp, stop_cheat_block_timestamp,
        spy_events, EventSpyAssertionsTrait
    };
    use starknet::ContractAddress;
    use everydayapp::mocks::mock_erc20::{IMockERC20Dispatcher, IMockERC20DispatcherTrait};

    const OWNER: felt252 = 'owner';
    const VERIFIED_SIGNER: felt252 = 'verified_signer';
    
    const USER_1: felt252 = 'user_1';
    const USER_2: felt252 = 'user_2';

    
    fn get_owner_address() -> ContractAddress {
        OWNER.try_into().unwrap()
    }

    fn get_verified_signer_address() -> ContractAddress {
        VERIFIED_SIGNER.try_into().unwrap()
    }

    fn get_user_address() -> ContractAddress {
        USER_1.try_into().unwrap()
    }

    fn get_another_user_address() -> ContractAddress {
        USER_2.try_into().unwrap()
    }

    fn setup() -> (IPriceConverterDispatcher, IAlarmContractDispatcher, ContractAddress, ContractAddress, IMockERC20Dispatcher) {
        // Declare Contracts
        let mock_pragma_oracle_class = declare("EthMockOracle").unwrap().contract_class();
        let price_convertor_class = declare("PriceConverter").unwrap().contract_class();
        let alarm_contract_class = declare("AlarmContract").unwrap().contract_class();
        let mock_erc20_class = declare("MockERC20").unwrap().contract_class();

        // Deploy Mock Oracle Contract
        let (mock_eth_usd_pragma_oracle_address, _) = mock_pragma_oracle_class.deploy(@array![]).unwrap();

        // Construct constructor args for PriceConverter
        let token_name: felt252 = 'MockETH';
        let token_symbol: felt252 = 'METH';
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

        // Construct constructor args for PriceConverter
        let constructor_args_price_converter = array![
            mock_eth_usd_pragma_oracle_address.into(), owner.into(),
        ];

        // Deploy PriceConverter Contract
        let (price_converter_address, _) = price_convertor_class
            .deploy(@constructor_args_price_converter)
            .unwrap();

        // Construct constructor args for AlarmContract
        let verified_signer: ContractAddress = get_verified_signer_address();
        let constructor_args_alarm_contract = array![
            owner.into(), 
            verified_signer.into(), 
            token_address.into(), // Use mock ERC20 token
            price_converter_address.into()
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
        let expected_signer = get_verified_signer_address();
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
        let stake_amount: u256 = 5000000000000000000; // 5 ETH (should be > 1 USD)
        
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
        let stake_amount: u256 = 1000; // Very small amount - should be < 1 USD
        
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
        let new_signer = get_another_user_address();
        
        // Verify initial signer
        let initial_signer = alarm_dispatcher.get_verified_signer();
        assert(initial_signer == get_verified_signer_address(), 'Wrong initial signer');
        
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
        
        let new_signer = get_another_user_address();
        let non_owner = get_user_address();
        
        // Set caller as non-owner
        start_cheat_caller_address(alarm_contract_address, non_owner);
        
        // This should panic with "Caller is not the owner"
        alarm_dispatcher.set_verified_signer(new_signer);
    }

    #[test]
    #[should_panic(expected: ('Zero_Address',))]
    fn test_set_verified_signer_zero_address() {
        let (_price_converter_dispatcher, alarm_dispatcher, _price_converter_address, alarm_contract_address, _token_dispatcher) = setup();
        
        let zero_address: ContractAddress = 0.try_into().unwrap();
        
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
        let (initial_root, initial_finalized) = alarm_dispatcher.get_pool_info(day, period);
        assert(initial_root == 0, 'Initial root should be 0');
        assert(!initial_finalized, 'Pool not finalized initially');
        
        // Set caller as owner
        start_cheat_caller_address(alarm_contract_address, get_owner_address());
        
        // Set merkle root
        alarm_dispatcher.set_reward_merkle_root(day, period, merkle_root);
        
        // Verify the merkle root was set and pool finalized
        let (updated_root, updated_finalized) = alarm_dispatcher.get_pool_info(day, period);
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
        let (updated_root, updated_finalized) = alarm_dispatcher.get_pool_info(day, period);
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
        let (am_root, am_finalized) = alarm_dispatcher.get_pool_info(day, am_period);
        let (pm_root, pm_finalized) = alarm_dispatcher.get_pool_info(day, pm_period);
        
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
        let (initial_root, initial_finalized) = alarm_dispatcher.get_pool_info(day, period);
        assert(initial_root == initial_merkle_root, 'Initial root not set');
        assert(initial_finalized, 'Pool should be finalized');
        
        // Update merkle root
        alarm_dispatcher.set_reward_merkle_root(day, period, updated_merkle_root);
        
        // Verify update
        let (final_root, final_finalized) = alarm_dispatcher.get_pool_info(day, period);
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
        assert(verified_signer == get_verified_signer_address(), 'Wrong verified signer');
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
    
}
