#[cfg(test)]
mod tests {
    use everydayapp::price_converter::price_converter::{
        IPriceConverterDispatcher,
    };
    use everydayapp::phone_lock::phone_lock::{IPhoneLockContractDispatcher, IPhoneLockContractDispatcherTrait};
    use everydayapp::mocks::mock_erc20::{IMockERC20Dispatcher, IMockERC20DispatcherTrait};
    use snforge_std::{
        ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address, 
        stop_cheat_caller_address, start_cheat_block_timestamp
    };
    use starknet::ContractAddress;

    const OWNER: felt252 = 'owner';
    const NON_OWNER : felt252 = 'non_owner';
    const VERIFIED_SIGNER: felt252 = 0x42f53a290543042b07333f31cf9cc4ad7d3ef0ac2996c2d1af302fdf7ae2fbf;
    const VERIFIED_SIGNER_PRIVATE_KEY: felt252 = 0x02a49cbb553b2b8d8ba20b3c9981ece2f4148f987f0665344e06e641a88f3cf5;

    // Test user addresses
    const USER_1: felt252 = 0x068e5011bbef90f8227382ea517277b631339205af237d5e853573248fc726a4;
    const USER_2: felt252 = 0x04b30350238863e574f135c84b48f860be87c90afc37843709b4613aab32f018;
    const USER_3: felt252 = 0x043abd6f2049a4de67a533068dd90336887eab3786864c50e2b2ca8be17de564;
    const USER_4: felt252 = 0x04e1cd2b21092ceb6999a2480bcc12a8b206867885d14a28aa7a1eb2169b015a;
    const USER_5: felt252 = 0x07bd8a637e29d94961f31c9561b952069057a5a9cad3179303b9c37710eb2cdd;
    
    // User lock parameters (all in period 2: 12:00-18:00)
    const USER_1_START_TIME: u64 = 1755691200;
    const USER_1_DURATION: u64 = 3600;
    const USER_1_STAKE_AMOUNT: u256 = 50000000000000000000;

    const USER_2_START_TIME: u64 = 1755694800;
    const USER_2_DURATION: u64 = 7200;
    const USER_2_STAKE_AMOUNT: u256 = 50000000000000000000;
    
    const USER_3_START_TIME: u64 = 1755698400;
    const USER_3_DURATION: u64 = 1800;
    const USER_3_STAKE_AMOUNT: u256 = 50000000000000000000;
    
    const USER_4_START_TIME: u64 = 1755702000;
    const USER_4_DURATION: u64 = 5400;
    const USER_4_STAKE_AMOUNT: u256 = 50000000000000000000;
    
    const USER_5_START_TIME: u64 = 1755705600;
    const USER_5_DURATION: u64 = 2400;
    const USER_5_STAKE_AMOUNT: u256 = 50000000000000000000;
    
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

    const NEW_VERIFIED_SIGNER: felt252 = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcde;
    
    fn get_new_signer() -> felt252 {
        NEW_VERIFIED_SIGNER
    }

    fn setup() -> (IPriceConverterDispatcher, IPhoneLockContractDispatcher, ContractAddress, ContractAddress, IMockERC20Dispatcher) {
        let mock_pragma_oracle_class = declare("StrkMockOracle").unwrap().contract_class();
        let price_convertor_class = declare("PriceConverter").unwrap().contract_class();
        let phone_lock_contract_class = declare("PhoneLockContract").unwrap().contract_class();
        let mock_erc20_class = declare("MockERC20").unwrap().contract_class();

        let (mock_strk_usd_pragma_oracle_address, _) = mock_pragma_oracle_class.deploy(@array![]).unwrap();

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

        let constructor_args_price_converter = array![
            mock_strk_usd_pragma_oracle_address.into(), owner.into(),
        ];

        let (price_converter_address, _) = price_convertor_class
            .deploy(@constructor_args_price_converter)
            .unwrap();

        let verified_signer: felt252 = get_verified_signer();
        let constructor_args_phone_lock_contract = array![
            owner.into(), 
            verified_signer.into(), 
            token_address.into(),
            price_converter_address.into(),
            owner.into(),
        ];
        
        let (phone_lock_contract_address, _) = phone_lock_contract_class.deploy(@constructor_args_phone_lock_contract).unwrap();
        
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

    fn get_user1_signature() -> (felt252, felt252) {
        let r = 0x440168f810198af2e85f21e21532f64a15394eaf88fd7d32a212d601f98404f;
        let s = 0x55f4b347e066865916ff5b3097882f0eb441534e070d8da2af586d3ab49b888;
        (r, s)
    }

    fn get_user1_proof() -> Array<felt252> {
        array![0x3e1acd662d4c63ee46f5a2e573f14cccebde805d1a35892010fb9edf04be7b4]
    }

    fn get_user4_merkle_proof() -> Array<felt252> {
        array![0x76b8fbc6e2c6fe62eadd1d56c2fa0d8577bc6d1260f4f507579d6d3f86cbc42]
    }

    fn get_user4_signature() -> (felt252, felt252) {
        let r = 0x1a6033a241658f57a21c7b7b03334385713babe849e3cd26fa7db4f1bb09336;
        let s = 0x474324aace6e56868d1e6fc1b300126ba2896154235c5bee49d006a53897a2d;
        (r, s)
    }

#[test]
fn test_phone_lock_e2e() {
    let (_price_converter_dispatcher, phone_lock_dispatcher, _price_converter_address, phone_lock_contract_address, token_dispatcher) = setup();
    
    let user1_address: ContractAddress = USER_1.try_into().unwrap();
    let user2_address: ContractAddress = USER_2.try_into().unwrap();
    let user3_address: ContractAddress = USER_3.try_into().unwrap();
    let user4_address: ContractAddress = USER_4.try_into().unwrap();
    let user5_address: ContractAddress = USER_5.try_into().unwrap();
    
    let initial_balance = 100000000000000000000_u256;
    
    start_cheat_caller_address(token_dispatcher.contract_address, get_owner_address());
    token_dispatcher.transfer(user1_address, initial_balance);
    stop_cheat_caller_address(token_dispatcher.contract_address);
    
    start_cheat_caller_address(token_dispatcher.contract_address, get_owner_address());
    token_dispatcher.transfer(user2_address, initial_balance);
    stop_cheat_caller_address(token_dispatcher.contract_address);
    
    start_cheat_caller_address(token_dispatcher.contract_address, get_owner_address());
    token_dispatcher.transfer(user3_address, initial_balance);
    stop_cheat_caller_address(token_dispatcher.contract_address);
    
    start_cheat_caller_address(token_dispatcher.contract_address, get_owner_address());
    token_dispatcher.transfer(user4_address, initial_balance);
    stop_cheat_caller_address(token_dispatcher.contract_address);
    
    start_cheat_caller_address(token_dispatcher.contract_address, get_owner_address());
    token_dispatcher.transfer(user5_address, initial_balance);
    stop_cheat_caller_address(token_dispatcher.contract_address);
    
    // Set phone locks for all users
    start_cheat_caller_address(token_dispatcher.contract_address, user1_address);
    token_dispatcher.approve(phone_lock_contract_address, USER_1_STAKE_AMOUNT);
    stop_cheat_caller_address(token_dispatcher.contract_address);
    
    start_cheat_caller_address(phone_lock_contract_address, user1_address);
    phone_lock_dispatcher.set_phone_lock(USER_1_START_TIME, USER_1_DURATION, USER_1_STAKE_AMOUNT);
    stop_cheat_caller_address(phone_lock_contract_address);
    
    let (u1_stake, u1_start, _u1_duration, _u1_end, _u1_status) = phone_lock_dispatcher.get_user_lock(user1_address, 1);
    assert(u1_stake == USER_1_STAKE_AMOUNT, 'U1: stake mismatch');
    assert(u1_start == USER_1_START_TIME, 'U1: start time mismatch');
    
    start_cheat_caller_address(token_dispatcher.contract_address, user2_address);
    token_dispatcher.approve(phone_lock_contract_address, USER_2_STAKE_AMOUNT);
    stop_cheat_caller_address(token_dispatcher.contract_address);
    
    start_cheat_caller_address(phone_lock_contract_address, user2_address);
    phone_lock_dispatcher.set_phone_lock(USER_2_START_TIME, USER_2_DURATION, USER_2_STAKE_AMOUNT);
    stop_cheat_caller_address(phone_lock_contract_address);
    

    start_cheat_caller_address(token_dispatcher.contract_address, user3_address);
    token_dispatcher.approve(phone_lock_contract_address, USER_3_STAKE_AMOUNT);
    stop_cheat_caller_address(token_dispatcher.contract_address);
    
    start_cheat_caller_address(phone_lock_contract_address, user3_address);
    phone_lock_dispatcher.set_phone_lock(USER_3_START_TIME, USER_3_DURATION, USER_3_STAKE_AMOUNT);
    stop_cheat_caller_address(phone_lock_contract_address);
    

    start_cheat_caller_address(token_dispatcher.contract_address, user4_address);
    token_dispatcher.approve(phone_lock_contract_address, USER_4_STAKE_AMOUNT);
    stop_cheat_caller_address(token_dispatcher.contract_address);
    
    start_cheat_caller_address(phone_lock_contract_address, user4_address);
    phone_lock_dispatcher.set_phone_lock(USER_4_START_TIME, USER_4_DURATION, USER_4_STAKE_AMOUNT);
    stop_cheat_caller_address(phone_lock_contract_address);
    

    start_cheat_caller_address(token_dispatcher.contract_address, user5_address);
    token_dispatcher.approve(phone_lock_contract_address, USER_5_STAKE_AMOUNT);
    stop_cheat_caller_address(token_dispatcher.contract_address);
    
    start_cheat_caller_address(phone_lock_contract_address, user5_address);
    phone_lock_dispatcher.set_phone_lock(USER_5_START_TIME, USER_5_DURATION, USER_5_STAKE_AMOUNT);
    stop_cheat_caller_address(phone_lock_contract_address);

    start_cheat_caller_address(phone_lock_contract_address, get_owner_address());
    phone_lock_dispatcher.set_reward_merkle_root(get_phone_lock_pool_day(), get_phone_lock_pool_period(), get_phone_lock_merkle_root(), 135000000000000000000, 15000000000000000000);
    stop_cheat_caller_address(phone_lock_contract_address);
    
    let (merkle_root, is_finalized, _total_staked, _user_count, _pool_reward) = phone_lock_dispatcher.get_pool_info(get_phone_lock_pool_day(), get_phone_lock_pool_period());
    assert(is_finalized, 'Pool should be finalized');
    assert(merkle_root == get_phone_lock_merkle_root(), 'Merkle root mismatch');
    
    let (stake, _start, _duration, _end, _status) = phone_lock_dispatcher.get_user_lock(user1_address, 1);
    assert(stake == USER_1_STAKE_AMOUNT, 'User1 stake mismatch');
    
    let claim_time = 1755708000 + 100;
    start_cheat_block_timestamp(phone_lock_contract_address, claim_time);
    
    start_cheat_caller_address(phone_lock_contract_address, user1_address);
    phone_lock_dispatcher.claim_lock_rewards(1, true, get_user1_signature(), 54000000000000000000, get_user1_proof());
    stop_cheat_caller_address(phone_lock_contract_address);
    
    start_cheat_caller_address(phone_lock_contract_address, user4_address);
    phone_lock_dispatcher.claim_lock_rewards(4, true, get_user4_signature(), 81000000000000000000, get_user4_merkle_proof());
    stop_cheat_caller_address(phone_lock_contract_address);

    assert(token_dispatcher.balance_of(user1_address) == 154000000000000000000_u256, 'User 1 balance');
    assert(token_dispatcher.balance_of(user4_address) == 181000000000000000000_u256, 'User 4 balance');
}
}