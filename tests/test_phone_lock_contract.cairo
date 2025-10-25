#[cfg(test)]
mod tests {
    use everydayapp::price_converter::price_converter::{
        IPriceConverterDispatcher,
    };
    use everydayapp::phone_lock::phone_lock::{IPhoneLockContractDispatcher, IPhoneLockContractDispatcherTrait};
    use everydayapp::phone_lock::phone_lock::PhoneLockContract;
    use everydayapp::phone_lock::phone_lock::PhoneLockContract::{PhoneLockSet, VerifiedSignerSet, MerkleRootSetForPool, WinningsClaimed};
    use everydayapp::mocks::mock_erc20::{IMockERC20Dispatcher, IMockERC20DispatcherTrait};
    use snforge_std::{
        ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address, 
        stop_cheat_caller_address, start_cheat_block_timestamp, stop_cheat_block_timestamp,
        spy_events, EventSpyAssertionsTrait
    };
    use starknet::ContractAddress;

    const OWNER: felt252 = 'owner';
    const NON_OWNER : felt252 = 'non_owner';
    const VERIFIED_SIGNER: felt252 = 0x42f53a290543042b07333f31cf9cc4ad7d3ef0ac2996c2d1af302fdf7ae2fbf;
    const VERIFIED_SIGNER_PRIVATE_KEY: felt252 = 0x02a49cbb553b2b8d8ba20b3c9981ece2f4148f987f0665344e06e641a88f3cf5;
    const NEW_VERIFIED_SIGNER: felt252 = 0x18e48c23b081873ca2a794891caa08bcd57ac10ea53781c3a51e2bdbf222406;

    // Test user addresses
    const USER_1: felt252 = 0x068e5011bbef90f8227382ea517277b631339205af237d5e853573248fc726a4;
    const USER_2: felt252 = 0x04b30350238863e574f135c84b48f860be87c90afc37843709b4613aab32f018;
    const USER_3: felt252 = 0x043abd6f2049a4de67a533068dd90336887eab3786864c50e2b2ca8be17de564;
    const USER_4: felt252 = 0x04e1cd2b21092ceb6999a2480bcc12a8b206867885d14a28aa7a1eb2169b015a;
    const USER_5: felt252 = 0x07bd8a637e29d94961f31c9561b952069057a5a9cad3179303b9c37710eb2cdd;
    
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

    fn setup() -> (IPriceConverterDispatcher, IPhoneLockContractDispatcher, ContractAddress, ContractAddress, IMockERC20Dispatcher) {
        // Declare contracts
        let mock_pragma_oracle_class = declare("StrkMockOracle").unwrap().contract_class();
        let price_convertor_class = declare("PriceConverter").unwrap().contract_class();
        let phone_lock_contract_class = declare("PhoneLockContract").unwrap().contract_class();
        let mock_erc20_class = declare("MockERC20").unwrap().contract_class();

        // Deploy mock STRK oracle
        let (mock_strk_usd_pragma_oracle_address, _) = mock_pragma_oracle_class.deploy(@array![]).unwrap();

        // Deploy mock ERC20 token
        let token_name: felt252 = 'MockSTRK';
        let token_symbol: felt252 = 'MSTRK';
        let decimals: u8 = 18;
        let initial_supply: u256 = 1000000000000000000000;
        let owner: ContractAddress = get_owner_address();
        
        let token_constructor_args = array![
            token_name,
            token_symbol, 
            decimals.into(),
            initial_supply.low.into(),
            initial_supply.high.into(),
            owner.into()
        ];
        
        let (token_address, _) = mock_erc20_class.deploy(@token_constructor_args).unwrap();

        // Deploy price converter
        let constructor_args_price_converter = array![
            mock_strk_usd_pragma_oracle_address.into(), owner.into(),
        ];

        let (price_converter_address, _) = price_convertor_class
            .deploy(@constructor_args_price_converter)
            .unwrap();

        // Deploy phone lock contract
        let verified_signer: felt252 = get_verified_signer();
        let constructor_args_phone_lock_contract = array![
            owner.into(), 
            verified_signer.into(), 
            token_address.into(),
            price_converter_address.into(),
            owner.into(),
        ];
        
        let (phone_lock_contract_address, _) = phone_lock_contract_class.deploy(@constructor_args_phone_lock_contract).unwrap();
        
        // Create dispatchers
        let price_converter_dispatcher = IPriceConverterDispatcher { contract_address: price_converter_address };
        let phone_lock_dispatcher = IPhoneLockContractDispatcher { contract_address: phone_lock_contract_address };
        let token_dispatcher = IMockERC20Dispatcher { contract_address: token_address };

        (price_converter_dispatcher, phone_lock_dispatcher, price_converter_address, phone_lock_contract_address, token_dispatcher)
    }

    // Helper functions for test data
    fn get_phone_lock_merkle_root() -> felt252 {
        0x5d357098a2cb091a6f41503fb93c06bd948946226c40ea1a56f67c4b877e03c
    }

    fn get_phone_lock_pool_day() -> u64 {
        20320
    }

    fn get_phone_lock_pool_period() -> u8 {
        2
    }

    // User 1 - winner
    fn get_user1_signature() -> (felt252, felt252) {
        let r = 0x440168f810198af2e85f21e21532f64a15394eaf88fd7d32a212d601f98404f;
        let s = 0x55f4b347e066865916ff5b3097882f0eb441534e070d8da2af586d3ab49b888;
        (r, s)
    }

    fn get_user1_merkle_proof() -> Array<felt252> {
        array![0x3e1acd662d4c63ee46f5a2e573f14cccebde805d1a35892010fb9edf04be7b4]
    }

    fn get_user1_reward_amount() -> u256 {
        54000000000000000000
    }

    fn get_user1_total_payout() -> u256 {
        104000000000000000000
    }

    // User 2 - loser
    fn get_user2_signature() -> (felt252, felt252) {
        let r = 0x74821146c321c917bd93fe9c7d5ddfec86531567db3102155dc8529cc6e82e2;
        let s = 0x527ddb7b6d223e27e76c00d85062899fa328c7d875d87b69eaa5748508972bc;
        (r, s)
    }

    fn get_user2_merkle_proof() -> Array<felt252> {
        array![]
    }

    fn get_user2_reward_amount() -> u256 {
        0
    }

    fn get_user2_total_payout() -> u256 {
        0
    }

    // User 4 - winner
    fn get_user4_signature() -> (felt252, felt252) {
        let r = 0x1a6033a241658f57a21c7b7b03334385713babe849e3cd26fa7db4f1bb09336;
        let s = 0x474324aace6e56868d1e6fc1b300126ba2896154235c5bee49d006a53897a2d;
        (r, s)
    }

    fn get_user4_merkle_proof() -> Array<felt252> {
        array![0x76b8fbc6e2c6fe62eadd1d56c2fa0d8577bc6d1260f4f507579d6d3f86cbc42]
    }

    fn get_user4_reward_amount() -> u256 {
        81000000000000000000
    }

    fn get_user4_total_payout() -> u256 {
        131000000000000000000
    }

    fn get_user1_start_time() -> u64 {
        1755691200
    }

    fn get_user1_duration() -> u64 {
        3600
    }

    fn get_user2_start_time() -> u64 {
        1755694800
    }

    fn get_user2_duration() -> u64 {
        7200
    }

    fn get_user4_start_time() -> u64 {
        1755702000
    }

    fn get_user4_duration() -> u64 {
        5400
    }

    #[test]
    fn test_constructor_initialization() {
        let mut spy = spy_events();
        let (_price_converter_dispatcher, phone_lock_dispatcher, _price_converter_address, phone_lock_contract_address, _token_dispatcher) = setup();

        let owner = phone_lock_dispatcher.get_owner();
        let expected_owner = get_owner_address();
        assert(owner == expected_owner, 'Wrong owner');

        let verified_signer = phone_lock_dispatcher.get_verified_signer();
        let expected_signer = get_verified_signer();
        assert(verified_signer == expected_signer, 'Wrong verified signer');

        let minimum_stake = phone_lock_dispatcher.get_minimum_stake_amount();
        assert(minimum_stake > 0, 'Minimum stake should be > 0');

        let expected_event = PhoneLockContract::Event::VerifiedSignerSet(VerifiedSignerSet{ 
            verified_signer: verified_signer 
        });
        
        let expected_events = array![(phone_lock_contract_address, expected_event)];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    fn test_phone_lock_contract_constants() {
        let (_price_converter_dispatcher, phone_lock_dispatcher, _price_converter_address, _phone_lock_contract_address, _token_dispatcher) = setup();

        let minimum_stake_amount = phone_lock_dispatcher.get_minimum_stake_amount();
        let expected_minimum_stake: u256 = 1_000_000_000_000_000_000;
        
        assert(minimum_stake_amount == expected_minimum_stake, 'Wrong minimum stake amount');
        assert(minimum_stake_amount > 0, 'Minimum stake should be > 0');
    }

    #[test]
    fn test_set_phone_lock_successful() {
        let (_price_converter_dispatcher, phone_lock_dispatcher, _price_converter_address, phone_lock_contract_address, token_dispatcher) = setup();
        
        // Setup test parameters
        let user = get_user_address();
        let current_time: u64 = 1000000; // Mock current timestamp
        let start_time: u64 = current_time + 86400; // 24 hours in the future
        let duration: u64 = 3600; // 1 hour lock
        let stake_amount: u256 = 50000000000000000000; // 50 STRK (>$0.2 USD min)
        
        // Setup block timestamp
        start_cheat_block_timestamp(phone_lock_contract_address, current_time);
        
        // Give user tokens and approve the time lock contract
        let owner = get_owner_address();
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.mint(user, stake_amount);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        // User approves time lock contract to spend tokens
        start_cheat_caller_address(token_dispatcher.contract_address, user);
        let approve_success = token_dispatcher.approve(phone_lock_contract_address, stake_amount);
        assert(approve_success, 'Token approval failed');
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        // Verify balances before setting lock
        let user_balance_before = token_dispatcher.balance_of(user);
        let contract_balance_before = token_dispatcher.balance_of(phone_lock_contract_address);
        
        // Setup event spy
        let mut spy = spy_events();
        
        // Set phone lock as user
        start_cheat_caller_address(phone_lock_contract_address, user);
        phone_lock_dispatcher.set_phone_lock(start_time, duration, stake_amount);
        stop_cheat_caller_address(phone_lock_contract_address);
        
        // Verify balances after setting lock
        let user_balance_after = token_dispatcher.balance_of(user);
        let contract_balance_after = token_dispatcher.balance_of(phone_lock_contract_address);
        
        // Verify token transfer occurred
        assert(user_balance_after == user_balance_before - stake_amount, 'User balance incorrect');
        assert(contract_balance_after == contract_balance_before + stake_amount, 'Contract balance incorrect');
        
        // Calculate expected day and period
        let _day = start_time / 86400; // ONE_DAY_IN_SECONDS
        let period_u64 = (start_time % 86400) / 21600; // SIX_HOURS_IN_SECONDS
        let _period: u8 = period_u64.try_into().unwrap();
        
        // Verify lock was created with correct data
        let (stored_stake, stored_start, stored_duration, stored_end, status) = phone_lock_dispatcher.get_user_lock(user, 1); // lock_id = 1
        assert(stored_stake == stake_amount, 'Wrong stored stake amount');
        assert(stored_start == start_time, 'Wrong stored start time');
        assert(stored_duration == duration, 'Wrong stored duration');
        assert(stored_end == start_time + duration, 'Wrong stored end time');
        assert(status == 'Active', 'Wrong lock status');
        
        // Verify event was emitted
        let expected_event = PhoneLockContract::Event::PhoneLockSet(
            PhoneLockSet {
                user: user,
                lock_id: 1, // First lock gets ID 1
                start_time: start_time,
                duration: duration,
                stake_amount: stake_amount,
            }
        );
        let expected_events = array![(phone_lock_contract_address, expected_event)];
        spy.assert_emitted(@expected_events);
        
        stop_cheat_block_timestamp(phone_lock_contract_address);
    }

    #[test]
    #[should_panic(expected: ('Invalid_Stake_Amount',))]
    fn test_set_phone_lock_zero_stake_amount() {
        let (_price_converter_dispatcher, phone_lock_dispatcher, _price_converter_address, phone_lock_contract_address, _token_dispatcher) = setup();
        
        let user = get_user_address();
        let current_time: u64 = 1000000;
        let start_time: u64 = current_time + 86400;
        let duration: u64 = 3600;
        let stake_amount: u256 = 0; // Zero stake amount - should fail
        
        start_cheat_block_timestamp(phone_lock_contract_address, current_time);
        start_cheat_caller_address(phone_lock_contract_address, user);
        
        // This should panic with INVALID_STAKE_AMOUNT
        phone_lock_dispatcher.set_phone_lock(start_time, duration, stake_amount);
    }

    #[test]
    #[should_panic(expected: ('Invalid_Start_Time',))]
    fn test_set_phone_lock_past_start_time_allowed_and_stored() {
        let (_price_converter_dispatcher, phone_lock_dispatcher, _price_converter_address, phone_lock_contract_address, token_dispatcher) = setup();
        
        let user = get_user_address();
        let current_time: u64 = 1_000_000;
        let start_time: u64 = current_time - 1; // Past start is allowed after removing check
        let duration: u64 = 3600;
        let stake_amount: u256 = 5000000000000000000;
        
        // Give user tokens and approve to avoid transfer_from failure
        let owner = get_owner_address();
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.mint(user, stake_amount);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        start_cheat_caller_address(token_dispatcher.contract_address, user);
        token_dispatcher.approve(phone_lock_contract_address, stake_amount);
        stop_cheat_caller_address(token_dispatcher.contract_address);

        start_cheat_block_timestamp(phone_lock_contract_address, current_time);
        start_cheat_caller_address(phone_lock_contract_address, user);
        
        // This should panic with INVALID_START_TIME
        phone_lock_dispatcher.set_phone_lock(start_time, duration, stake_amount);
    }

    #[test]
    #[should_panic(expected: ('Invalid_Duration',))]
    fn test_set_phone_lock_invalid_duration() {
        let (_price_converter_dispatcher, phone_lock_dispatcher, _price_converter_address, phone_lock_contract_address, _token_dispatcher) = setup();
        
        let user = get_user_address();
        let current_time: u64 = 1000000;
        let start_time: u64 = current_time + 86400;
        let duration: u64 = 100; // Too short - should fail (< 300 seconds)
        let stake_amount: u256 = 5000000000000000000;
        
        start_cheat_block_timestamp(phone_lock_contract_address, current_time);
        start_cheat_caller_address(phone_lock_contract_address, user);
        
        // This should panic with INVALID_DURATION
        phone_lock_dispatcher.set_phone_lock(start_time, duration, stake_amount);
    }

    #[test]
    #[should_panic(expected: ('Invalid_Duration',))]
    fn test_set_phone_lock_duration_too_long() {
        let (_price_converter_dispatcher, phone_lock_dispatcher, _price_converter_address, phone_lock_contract_address, _token_dispatcher) = setup();
        
        let user = get_user_address();
        let current_time: u64 = 1000000;
        let start_time: u64 = current_time + 86400;
        let duration: u64 = 100000; // Too long - should fail (> 86400 seconds)
        let stake_amount: u256 = 5000000000000000000;
        
        start_cheat_block_timestamp(phone_lock_contract_address, current_time);
        start_cheat_caller_address(phone_lock_contract_address, user);
        
        // This should panic with INVALID_DURATION
        phone_lock_dispatcher.set_phone_lock(start_time, duration, stake_amount);
    }

    #[test]
    #[should_panic(expected: ('Lock_Already_Exists_In_Pool',))]
    fn test_set_phone_lock_already_exists() {
        let (_price_converter_dispatcher, phone_lock_dispatcher, _price_converter_address, phone_lock_contract_address, token_dispatcher) = setup();
        
        let user = get_user_address();
        let current_time: u64 = 1000000;
        let start_time: u64 = current_time + 86400;
        let duration: u64 = 3600;
        let stake_amount: u256 = 5000000000000000000;
        
        // Setup tokens and approvals
        let owner = get_owner_address();
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.mint(user, stake_amount * 2); // Give enough for two locks
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_caller_address(token_dispatcher.contract_address, user);
        token_dispatcher.approve(phone_lock_contract_address, stake_amount * 2);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_block_timestamp(phone_lock_contract_address, current_time);
        start_cheat_caller_address(phone_lock_contract_address, user);
        
        // Set first lock successfully
        phone_lock_dispatcher.set_phone_lock(start_time, duration, stake_amount);
        
        // Try to set second lock for same day/period - should fail
        phone_lock_dispatcher.set_phone_lock(start_time + 1, duration, stake_amount); // Same day/period
    }

    #[test]
    fn test_set_verified_signer_as_owner() {
        // Setup event spy
        let mut spy = spy_events();
        
        let (_price_converter_dispatcher, phone_lock_dispatcher, _price_converter_address, phone_lock_contract_address, _token_dispatcher) = setup();
        
        // Test parameters
        let new_signer = get_new_signer();
        
        // Verify initial signer
        let initial_signer = phone_lock_dispatcher.get_verified_signer();
        assert(initial_signer == get_verified_signer(), 'Wrong initial signer');
        
        // Set caller as owner
        start_cheat_caller_address(phone_lock_contract_address, get_owner_address());
        
        // Set new verified signer
        phone_lock_dispatcher.set_verified_signer(new_signer);
        
        // Verify the signer was updated
        let updated_signer = phone_lock_dispatcher.get_verified_signer();
        assert(updated_signer == new_signer, 'Signer not updated');
        
        // Verify event was emitted
        let expected_event = PhoneLockContract::Event::VerifiedSignerSet(
            VerifiedSignerSet { verified_signer: new_signer }
        );
        let expected_events = array![(phone_lock_contract_address, expected_event)];
        spy.assert_emitted(@expected_events);
        
        stop_cheat_caller_address(phone_lock_contract_address);
    }

    #[test]
    #[should_panic(expected: ('Caller is not the owner',))]
    fn test_set_verified_signer_as_non_owner() {
        let (_price_converter_dispatcher, phone_lock_dispatcher, _price_converter_address, phone_lock_contract_address, _token_dispatcher) = setup();
        
        let new_signer = get_new_signer();
        let non_owner = get_user_address();
        
        // Set caller as non-owner
        start_cheat_caller_address(phone_lock_contract_address, non_owner);
        
        // This should panic with "Caller is not the owner"
        phone_lock_dispatcher.set_verified_signer(new_signer);
    }

    #[test]
    fn test_set_reward_merkle_root_as_owner() {
        // Setup event spy
        let mut spy = spy_events();
        
        let (_price_converter_dispatcher, phone_lock_dispatcher, _price_converter_address, phone_lock_contract_address, _token_dispatcher) = setup();
        
        // Test parameters
        let day: u64 = 100;
        let period: u8 = 0; // AM period
        let merkle_root: felt252 = 'test_merkle_root_123';
        
        // Verify initial pool state
        let (initial_root, initial_finalized, _initial_total_staked, _initial_user_count, _initial_pool_reward) = phone_lock_dispatcher.get_pool_info(day, period);
        assert(initial_root == 0, 'Initial root should be 0');
        assert(!initial_finalized, 'Pool not finalized initially');
        
        // Set caller as owner
        start_cheat_caller_address(phone_lock_contract_address, get_owner_address());
        
        // Set merkle root
        phone_lock_dispatcher.set_reward_merkle_root(day, period, merkle_root, 0, 0); // new_rewards=0, protocol_fees=0
        
        // Verify the merkle root was set and pool finalized
        let (updated_root, updated_finalized, _updated_total_staked, _updated_user_count, _updated_pool_reward) = phone_lock_dispatcher.get_pool_info(day, period);
        assert(updated_root == merkle_root, 'Merkle root not set');
        assert(updated_finalized, 'Pool should be finalized');
        
        // Also test get_merkle_root function
        let stored_root = phone_lock_dispatcher.get_merkle_root(day, period);
        assert(stored_root == merkle_root, 'Wrong stored merkle root');
        
        // Verify event was emitted
        let expected_event = PhoneLockContract::Event::MerkleRootSetForPool(
            MerkleRootSetForPool { merkle_root: merkle_root, day: day, period: period }
        );
        let expected_events = array![(phone_lock_contract_address, expected_event)];
        spy.assert_emitted(@expected_events);
        
        stop_cheat_caller_address(phone_lock_contract_address);
    }

    #[test]
    fn test_pool_info_update_single_user() {
        let (_price_converter_dispatcher, phone_lock_dispatcher, _price_converter_address, phone_lock_contract_address, token_dispatcher) = setup();
        
        // Setup test parameters
        let user = get_user_address();
        let current_time: u64 = 1000000;
        let start_time: u64 = current_time + 86400; // 24 hours in the future
        let duration: u64 = 3600; // 1 hour
        let stake_amount: u256 = 5000000000000000000; // 5 STRK
        
        // Calculate day and period
        let day = start_time / 86400;
        let period_u64 = (start_time % 86400) / 21600;
        let period: u8 = period_u64.try_into().unwrap();
        
        // Check initial pool info
        let (_initial_root, _initial_finalized, initial_total_staked, initial_user_count, _initial_pool_reward) = phone_lock_dispatcher.get_pool_info(day, period);
        assert(initial_total_staked == 0, 'Initial total staked != 0');
        assert(initial_user_count == 0, 'Initial user count != 0');
        
        // Setup tokens and set lock
        start_cheat_block_timestamp(phone_lock_contract_address, current_time);
        let owner = get_owner_address();
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.mint(user, stake_amount);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_caller_address(token_dispatcher.contract_address, user);
        token_dispatcher.approve(phone_lock_contract_address, stake_amount);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_caller_address(phone_lock_contract_address, user);
        phone_lock_dispatcher.set_phone_lock(start_time, duration, stake_amount);
        stop_cheat_caller_address(phone_lock_contract_address);
        
        // Check pool info after setting lock
        let (_updated_root, _updated_finalized, updated_total_staked, updated_user_count, _updated_pool_reward) = phone_lock_dispatcher.get_pool_info(day, period);
        assert(updated_total_staked == stake_amount, 'Total staked not updated');
        assert(updated_user_count == 1, 'User count not updated');
        
        stop_cheat_block_timestamp(phone_lock_contract_address);
    }

    #[test]
    fn test_claim_lock_rewards_winner() {
        let (_price_converter, phone_lock_dispatcher, _pc_addr, phone_lock_addr, token_dispatcher, _winner, _loser) = setup_two_users();

        let start_time = get_user1_start_time();
        let duration = get_user1_duration();
        let completion_status = true; // Winner
        let (r,s) = get_user1_signature();
        let reward_amount = get_user1_reward_amount();
        let merkle_root = get_phone_lock_merkle_root();
        let merkle_proof = get_user1_merkle_proof();
        let total_payout = get_user1_total_payout();
        
        // Give contract enough tokens to pay out rewards (total slashed amount from backend)
        let total_slashed: u256 = 150000000000000000000; // 150 STRK from 3 losers
        let owner = get_owner_address();
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.transfer(phone_lock_addr, total_slashed);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        // Set merkle root to finalize pool (generated for period 2)
        start_cheat_caller_address(phone_lock_addr, owner);
        phone_lock_dispatcher.set_reward_merkle_root(get_phone_lock_pool_day(), get_phone_lock_pool_period(), merkle_root, 0, 0); // new_rewards=0, protocol_fees=0
        stop_cheat_caller_address(phone_lock_addr);
        
        start_cheat_block_timestamp(phone_lock_addr, start_time + duration + 1);
        start_cheat_caller_address(phone_lock_addr, _winner);
        
        // Setup event spy
        let mut spy = spy_events();
        
        // Claim rewards
        phone_lock_dispatcher.claim_lock_rewards(1, completion_status, (r,s), reward_amount, merkle_proof); // lock_id = 1
        
        // Check that WinningsClaimed event was emitted
        let expected_event = PhoneLockContract::Event::WinningsClaimed(
            WinningsClaimed {
                user: _winner,
                lock_id: 1,
                completion_status: completion_status,
                winnings_amount: total_payout,
            }
        );
        spy.assert_emitted(@array![(phone_lock_addr, expected_event)]);
        
        stop_cheat_caller_address(phone_lock_addr);
    }

    #[test]
    fn test_claim_lock_rewards_loser() {
        let (_price_converter, phone_lock_dispatcher, _pc_addr, phone_lock_addr, token_dispatcher, _winner, _loser) = setup_two_users();

        let start_time = get_user2_start_time();
        let duration = get_user2_duration();
        let completion_status = false; // Loser
        let (r,s) = get_user2_signature();
        let reward_amount = get_user2_reward_amount();
        let merkle_root = get_phone_lock_merkle_root();
        let merkle_proof = get_user2_merkle_proof();
        let total_payout = get_user2_total_payout();
        
        // Give contract enough tokens to pay out rewards (total slashed amount from backend)
        let total_slashed: u256 = 150000000000000000000; // 150 STRK from 3 losers
        let owner = get_owner_address();
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.transfer(phone_lock_addr, total_slashed);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        // Set merkle root to finalize pool (generated for period 2)
        start_cheat_caller_address(phone_lock_addr, owner);
        phone_lock_dispatcher.set_reward_merkle_root(get_phone_lock_pool_day(), get_phone_lock_pool_period(), merkle_root, 0, 0); // new_rewards=0, protocol_fees=0
        stop_cheat_caller_address(phone_lock_addr);
        
        start_cheat_block_timestamp(phone_lock_addr, start_time + duration + 1);
        start_cheat_caller_address(phone_lock_addr, _loser);
        
        // Setup event spy
        let mut spy = spy_events();
        
        // Claim rewards (loser gets lock_id = 2)
        phone_lock_dispatcher.claim_lock_rewards(2, completion_status, (r,s), reward_amount, merkle_proof);
        
        // Check that WinningsClaimed event was emitted
        let expected_event = PhoneLockContract::Event::WinningsClaimed(
            WinningsClaimed {
                user: _loser,
                lock_id: 2,
                completion_status: completion_status,
                winnings_amount: total_payout,
            }
        );
        spy.assert_emitted(@array![(phone_lock_addr, expected_event)]);
        
        stop_cheat_caller_address(phone_lock_addr);
    }

    #[test]
    #[should_panic(expected: ('Lock_Time_Not_Reached',))]
    fn test_claim_lock_rewards_time_not_reached() {
        let (_price_converter, phone_lock_dispatcher, _pc_addr, phone_lock_addr, _token_dispatcher, _winner, _loser) = setup_two_users();

        let start_time = get_user1_start_time();
        let duration = get_user1_duration();
        let completion_status = true;
        let (r,s) = get_user1_signature();
        let reward_amount = get_user1_reward_amount();
        let merkle_root = get_phone_lock_merkle_root();
        let merkle_proof = get_user1_merkle_proof();
        
        // Set merkle root to finalize pool
        let owner = get_owner_address();
        start_cheat_caller_address(phone_lock_addr, owner);
        phone_lock_dispatcher.set_reward_merkle_root(get_phone_lock_pool_day(), get_phone_lock_pool_period(), merkle_root, 0, 0); // new_rewards=0, protocol_fees=0
        stop_cheat_caller_address(phone_lock_addr);
        
        // Set current time BEFORE lock end time
        start_cheat_block_timestamp(phone_lock_addr, start_time + duration - 1);
        start_cheat_caller_address(phone_lock_addr, _winner);
        
        // This should panic with "Lock_Time_Not_Reached"
        phone_lock_dispatcher.claim_lock_rewards(1, completion_status, (r,s), reward_amount, merkle_proof); // lock_id = 1
    }

    #[test]
    #[should_panic(expected: ('Invalid_Signature',))]
    fn test_claim_lock_rewards_invalid_signature() {
        let (_price_converter, phone_lock_dispatcher, _pc_addr, phone_lock_addr, _token_dispatcher, _winner, _loser) = setup_two_users();

        let start_time = get_user1_start_time();
        let duration = get_user1_duration();
        let completion_status = true;
        let (_,s) = get_user1_signature(); // Invalid signature - r is zero
        let reward_amount = get_user1_reward_amount();
        let merkle_root = get_phone_lock_merkle_root();
        let merkle_proof = get_user1_merkle_proof();
        
        // Set merkle root to finalize pool
        let owner = get_owner_address();
        start_cheat_caller_address(phone_lock_addr, owner);
        phone_lock_dispatcher.set_reward_merkle_root(get_phone_lock_pool_day(), get_phone_lock_pool_period(), merkle_root, 0, 0); // new_rewards=0, protocol_fees=0
        stop_cheat_caller_address(phone_lock_addr);
        
        start_cheat_block_timestamp(phone_lock_addr, start_time + duration + 1);
        start_cheat_caller_address(phone_lock_addr, _winner);
        
        // This should panic with "Invalid_Signature"
        phone_lock_dispatcher.claim_lock_rewards(1, completion_status, (0,s), reward_amount, merkle_proof); // lock_id = 1
    }

    #[test]
    #[should_panic(expected: ('Pool_Not_Finalized',))]
    fn test_claim_lock_rewards_pool_not_finalized() {
        let (_price_converter, phone_lock_dispatcher, _pc_addr, phone_lock_addr, _token_dispatcher, _winner, _loser) = setup_two_users();

        let start_time = get_user1_start_time();
        let duration = get_user1_duration();
        let completion_status = true;
        let (r,s) = get_user1_signature();
        let reward_amount = get_user1_reward_amount();
        let merkle_proof = get_user1_merkle_proof();
        
        // Don't set merkle root - pool remains unfinalized
        start_cheat_block_timestamp(phone_lock_addr, start_time + duration + 1);
        start_cheat_caller_address(phone_lock_addr, _winner);
        
        // This should panic with "Pool_Not_Finalized"
        phone_lock_dispatcher.claim_lock_rewards(1, completion_status, (r,s), reward_amount, merkle_proof); // lock_id = 1
    }

    #[test]
    fn test_five_users_end_to_end_claim_rewards() {
        let (_price_converter, phone_lock_dispatcher, _pc_addr, phone_lock_addr, token_dispatcher, users) = setup_five_users();
        
        // Get all the test data
        let start_times = get_five_users_start_times();
        let durations = get_five_users_durations();
        let completion_statuses = get_five_users_completion_statuses();
        let signatures = get_five_users_signatures();
        let merkle_root = get_phone_lock_merkle_root();
        let reward_amounts = get_five_users_reward_amounts();
        let total_payouts = get_five_users_total_payouts();
        let pool_day = get_phone_lock_pool_day();
        let pool_period = get_phone_lock_pool_period();
        
        // Give contract enough tokens to pay out rewards (total slashed amount from backend)
        let total_slashed: u256 = 150000000000000000000; // 150 STRK from 3 losers
        let owner = get_owner_address();
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.transfer(phone_lock_addr, total_slashed);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        // Set merkle root to finalize pool
        start_cheat_caller_address(phone_lock_addr, owner);
        phone_lock_dispatcher.set_reward_merkle_root(pool_day, pool_period, merkle_root, 0, 0); // new_rewards=0, protocol_fees=0
        stop_cheat_caller_address(phone_lock_addr);
        
        // Set current time AFTER all lock end times
        let latest_end_time = 1755723600 + 2400; // User5's start_time + duration
        start_cheat_block_timestamp(phone_lock_addr, latest_end_time + 1);
        
        // Setup event spy
        let mut spy = spy_events();
        
        // Process all 5 users
        let mut i = 0;
        loop {
            if i >= users.len() {
                break;
            }
            
            let user = *users.at(i);
            let _start_time = *start_times.at(i);
            let _duration = *durations.at(i);
            let completion_status = *completion_statuses.at(i);
            let (r, s) = *signatures.at(i);
            let reward_amount = *reward_amounts.at(i);
            let total_payout = *total_payouts.at(i);
            
            // Get merkle proof for current user from data
            let merkle_proof = if i == 0 {
                get_user1_merkle_proof() // user1 (winner)
            } else if i == 3 {
                get_user4_merkle_proof() // user4 (winner)
            } else {
                array![] // users 2, 3, 5 have no proof (losers)
            };
            
            // Set caller to current user
            start_cheat_caller_address(phone_lock_addr, user);
            
            // Get initial balance
            let initial_balance = token_dispatcher.balance_of(user);
            
            // Each user has their own lock_id (1-based index)
            let lock_id: u64 = (i + 1).try_into().unwrap();
            
            // Claim rewards
            phone_lock_dispatcher.claim_lock_rewards(lock_id, completion_status, (r, s), reward_amount, merkle_proof);
            
            // Check final balance
            let final_balance = token_dispatcher.balance_of(user);
            assert(final_balance == initial_balance + total_payout, 'Wrong payout amount');
            
            // Check that WinningsClaimed event was emitted
            let expected_event = PhoneLockContract::Event::WinningsClaimed(
                WinningsClaimed {
                    user: user,
                    lock_id: lock_id,
                    completion_status: completion_status,
                    winnings_amount: total_payout,
                }
            );
            spy.assert_emitted(@array![(phone_lock_addr, expected_event)]);
            
            // Check lock status is now Completed
            let (_, _, _, _, status) = phone_lock_dispatcher.get_user_lock(user, lock_id);
            assert(status == 'Completed', 'Status not Completed');
            
            // Check claim status
            let has_claimed = phone_lock_dispatcher.get_has_claimed_rewards(user, lock_id);
            assert(has_claimed == true, 'Should be marked claimed');
            
            stop_cheat_caller_address(phone_lock_addr);
            
            i += 1;
        };
        
        stop_cheat_block_timestamp(phone_lock_addr);
    }

    fn setup_two_users() -> (IPriceConverterDispatcher, IPhoneLockContractDispatcher, ContractAddress, ContractAddress, IMockERC20Dispatcher, ContractAddress, ContractAddress) {
        // Setup initial contracts
        let (_price_converter_dispatcher, phone_lock_dispatcher, price_converter_address, phone_lock_contract_address, token_dispatcher) = setup();
        
        // Define 2 user addresses
        let winner: ContractAddress = USER_1.try_into().unwrap();
        let loser: ContractAddress = USER_2.try_into().unwrap();
        
        // Define stake amounts
        let winner_stake: u256 = 50000000000000000000; // 50 STRK
        let loser_stake: u256 = 50000000000000000000; // 50 STRK
        
        // Use the same pool settings as data (day=20320, period=2)
        let base_time: u64 = 1755691200 - 3600; // start time - 1 hour
        
        // Set current timestamp
        start_cheat_block_timestamp(phone_lock_contract_address, base_time);
        
        // Setup winner user - use start time (PM period)
        let start_time_winner = get_user1_start_time();
        let duration_winner = get_user1_duration();
        let owner = get_owner_address();
        
        // Give winner tokens (using token contract context)
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.transfer(winner, winner_stake * 3); // Give 3x stake amount for rewards
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        // Winner approves time lock contract and sets lock
        start_cheat_caller_address(token_dispatcher.contract_address, winner);
        token_dispatcher.approve(phone_lock_contract_address, winner_stake);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_caller_address(phone_lock_contract_address, winner);
        phone_lock_dispatcher.set_phone_lock(start_time_winner, duration_winner, winner_stake);
        stop_cheat_caller_address(phone_lock_contract_address);
        
        // Setup loser user - use start time (PM period)
        let start_time_loser = get_user2_start_time();
        let duration_loser = get_user2_duration();
        
        // Give loser tokens (using token contract context)
        start_cheat_caller_address(token_dispatcher.contract_address, owner);
        token_dispatcher.transfer(loser, loser_stake * 3); // Give 3x stake amount for rewards
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        // Loser approves time lock contract and sets lock
        start_cheat_caller_address(token_dispatcher.contract_address, loser);
        token_dispatcher.approve(phone_lock_contract_address, loser_stake);
        stop_cheat_caller_address(token_dispatcher.contract_address);
        
        start_cheat_caller_address(phone_lock_contract_address, loser);
        phone_lock_dispatcher.set_phone_lock(start_time_loser, duration_loser, loser_stake);
        stop_cheat_caller_address(phone_lock_contract_address);
        
        stop_cheat_block_timestamp(phone_lock_contract_address);
        
        // Return everything including user addresses
        (_price_converter_dispatcher, phone_lock_dispatcher, price_converter_address, phone_lock_contract_address, token_dispatcher, winner, loser)
    }

    fn setup_five_users() -> (IPriceConverterDispatcher, IPhoneLockContractDispatcher, ContractAddress, ContractAddress, IMockERC20Dispatcher, Array<ContractAddress>) {
        // Setup initial contracts
        let (_price_converter_dispatcher, phone_lock_dispatcher, price_converter_address, phone_lock_contract_address, token_dispatcher) = setup();
        
        // Define 5 user addresses from time_lock_inputs.json
        let user1: ContractAddress = USER_1.try_into().unwrap();  // Winner
        let user2: ContractAddress = USER_2.try_into().unwrap();  // Loser
        let user3: ContractAddress = USER_3.try_into().unwrap();  // Loser
        let user4: ContractAddress = USER_4.try_into().unwrap();  // Winner
        let user5: ContractAddress = USER_5.try_into().unwrap();  // Loser
        
        // Define stake amounts from time_lock_inputs.json
        let user1_stake: u256 = 50000000000000000000; // 50 STRK
        let user2_stake: u256 = 50000000000000000000; // 50 STRK
        let user3_stake: u256 = 50000000000000000000; // 50 STRK
        let user4_stake: u256 = 50000000000000000000; // 50 STRK
        let user5_stake: u256 = 50000000000000000000; // 50 STRK

        // Pool settings from time_lock_inputs.json
        let _pool_day: u64 = 20320; // Day from JSON
        let _pool_period: u8 = 2; // Period 2 
        
        // Individual start times and durations from time_lock_inputs.json
        let start_times = get_five_users_start_times();
        let durations = get_five_users_durations();
        
        // Set current timestamp to before earliest start time for lock setting
        let earliest_start = 1755691200; // User 1 start time 
        start_cheat_block_timestamp(phone_lock_contract_address, earliest_start - 86400); // 1 day before
        
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
            let start_time = *start_times.at(i);
            let duration = *durations.at(i);
            
            // Give user tokens (using token contract context)
            start_cheat_caller_address(token_dispatcher.contract_address, owner);
            token_dispatcher.transfer(user, stake * 3); // Give 3x stake amount for rewards
            stop_cheat_caller_address(token_dispatcher.contract_address);
            
            // User approves time lock contract and sets lock
            start_cheat_caller_address(token_dispatcher.contract_address, user);
            token_dispatcher.approve(phone_lock_contract_address, stake);
            stop_cheat_caller_address(token_dispatcher.contract_address);
            
            start_cheat_caller_address(phone_lock_contract_address, user);
            phone_lock_dispatcher.set_phone_lock(start_time, duration, stake);
            stop_cheat_caller_address(phone_lock_contract_address);
            
            i += 1;
        };
        
        stop_cheat_block_timestamp(phone_lock_contract_address);
        
        // Return everything including users array
        (_price_converter_dispatcher, phone_lock_dispatcher, price_converter_address, phone_lock_contract_address, token_dispatcher, users)
    }

    // Helper functions for 5 users test data from time_lock_inputs.json
    fn get_five_users_start_times() -> Array<u64> {
        array![
            1755691200, // user1 
            1755694800, // user2 
            1755698400, // user3 
            1755702000, // user4 
            1755705600  // user5 
        ]
    }

    fn get_five_users_durations() -> Array<u64> {
        array![
            3600,  // user1 - 1 hour
            7200,  // user2 - 2 hours
            1800,  // user3 - 30 minutes
            5400,  // user4 - 1.5 hours
            2400   // user5 - 40 minutes
        ]
    }

    fn get_five_users_completion_statuses() -> Array<bool> {
        array![
            true,   // user1 - completed successfully
            false,  // user2 - failed
            false,  // user3 - failed
            true,   // user4 - completed successfully
            false   // user5 - failed
        ]
    }

    fn get_five_users_signatures() -> Array<(felt252, felt252)> {
        array![
            get_user1_signature(), // user1 
            get_user2_signature(), // user2 
            (0x6801ddfcd675828e4cecee57a6516b974e9323ca955cd8b06bda60f8e7950d3, 0x53f3276614d019712df009cb5b275407a64683b18fb44e2eb2c217e691c289f), // user3 
            get_user4_signature(), // user4 
            (0x7ccfa0ca3ddc623784c64e3d6cab277d62f0163eb446c4bfeda947cd232c8de, 0x5b508fcdc9d5479c49af021bdd4a05c0c706102add5aa0ca3b13e8020cc8526)  // user5 
        ]
    }

    fn get_five_users_reward_amounts() -> Array<u256> {
        array![
            54000000000000000000,  // user1 - 54 STRK reward 
            0,                      // user2 - no reward (failed)
            0,                      // user3 - no reward (failed)
            81000000000000000000,  // user4 - 81 STRK reward 
            0                       // user5 - no reward (failed)
        ]
    }

    fn get_five_users_total_payouts() -> Array<u256> {
        array![
            104000000000000000000, // user1 - 104 STRK total (50 stake + 54 reward)
            0,                     // user2 - 0 STRK total (failed)
            0,                     // user3 - 0 STRK total (failed)
            131000000000000000000, // user4 - 131 STRK total (50 stake + 81 reward)
            0                      // user5 - 0 STRK total (failed)
        ]
    }
}
