#[cfg(test)]
mod tests {
    use everydayapp::price_converter::price_converter::{
        IPriceConverterDispatcher, IPriceConverterDispatcherTrait,
    };
    use snforge_std::{
        ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp,
        start_cheat_caller_address, stop_cheat_block_timestamp, stop_cheat_caller_address,
    };
    use starknet::ContractAddress;

    const ORACLE_DECIMALS: u8 = 8;
    const STRK_USD_ORACLE_PRICE: u128 = 20_000_000;
    const ETH_USD_ORACLE_PRICE: u128 = 400_000_000_000; // $4000 with 8 decimals
    const STRK_USD_PRICE: u256 = 2_000_000_000_000_000_000; // $0.20 in 18 decimals
    const ONE_E8: u128 = 100_000_000;
    const ONE_E18: u128 = 1_000_000_000_000_000_000;
    const STRK_USD_PAIR_ID: felt252 = 'STRK/USD'; // Pragma pair identifier
    const ETH_USD_PAIR_ID: felt252 = 'ETH/USD'; // Pragma pair identifier


    fn setup() -> (
        IPriceConverterDispatcher, // STRK/USD price converter
        IPriceConverterDispatcher, // ETH/USD price converter
        ContractAddress, // STRK price converter address
        ContractAddress, // ETH price converter address
        ContractAddress, // STRK oracle address
        ContractAddress  // ETH oracle address
    ) {
        // Declare Contracts
        let mock_strk_usd_pragma_oracle_class = declare("StrkMockOracle").unwrap().contract_class();
        let mock_eth_usd_pragma_oracle_class = declare("EthMockOracle").unwrap().contract_class();
        let price_convertor_class = declare("PriceConverter").unwrap().contract_class();

        // Deploy Mock Contracts
        let (mock_strk_usd_pragma_oracle_address, _) = mock_strk_usd_pragma_oracle_class.deploy(@array![]).unwrap();
        let (mock_eth_usd_pragma_oracle_address, _) = mock_eth_usd_pragma_oracle_class.deploy(@array![]).unwrap();

        let owner: ContractAddress = 123.try_into().unwrap();

        // Deploy STRK/USD PriceConverter
        let constructor_args_strk_price_converter = array![
            mock_strk_usd_pragma_oracle_address.into(), owner.into()
        ];
        let (strk_price_convertor_address, _) = price_convertor_class
            .deploy(@constructor_args_strk_price_converter)
            .unwrap();

        // Deploy ETH/USD PriceConverter
        let constructor_args_eth_price_converter = array![
            mock_eth_usd_pragma_oracle_address.into(), owner.into()
        ];
        let (eth_price_convertor_address, _) = price_convertor_class
            .deploy(@constructor_args_eth_price_converter)
            .unwrap();

        // Create dispatchers
        let strk_dispatcher = IPriceConverterDispatcher { contract_address: strk_price_convertor_address };
        let eth_dispatcher = IPriceConverterDispatcher { contract_address: eth_price_convertor_address };

        (
            strk_dispatcher,
            eth_dispatcher, 
            strk_price_convertor_address,
            eth_price_convertor_address,
            mock_strk_usd_pragma_oracle_address,
            mock_eth_usd_pragma_oracle_address
        )
    }

    #[test]
    fn test_get_strk_usd_price() {
        let (strk_dispatcher, _eth_dispatcher, _strk_price_convertor_address, _eth_price_convertor_address, _mock_strk_usd_pragma_oracle_address, _mock_eth_usd_pragma_oracle_address) = setup();

        let (price, decimals) = strk_dispatcher.get_strk_usd_price();

        assert(price == STRK_USD_ORACLE_PRICE, 'Wrong price');
        assert(decimals == ORACLE_DECIMALS, 'Wrong decimals');
    }

    #[test]
    fn test_convert_strk_to_usd() {
        let (strk_dispatcher, _eth_dispatcher, _strk_price_convertor_address, _eth_price_convertor_address, _mock_strk_usd_pragma_oracle_address, _mock_eth_usd_pragma_oracle_address) = setup();

        // Convert 1 STRK (1e18) to USD
        let strk_amount_low: u128 = ONE_E18; // 1e18
        let strk_amount_high: u128 = 0;

        let (usd_low, usd_high) = strk_dispatcher.convert_strk_to_usd(strk_amount_low, strk_amount_high);

        // Expected: 1 STRK * 0.20 USD = 0.20 USD = 200000000000000000 (with 18 decimals)
        assert(usd_low == STRK_USD_ORACLE_PRICE * ONE_E18 / ONE_E8, 'Wrong USD conversion');
        assert(usd_high == 0, 'Wrong USD high part');
    }

    #[test]
    fn test_convert_usd_to_strk() {
        let (strk_dispatcher, _eth_dispatcher, _strk_price_convertor_address, _eth_price_convertor_address, _mock_strk_usd_pragma_oracle_address, _mock_eth_usd_pragma_oracle_address) = setup();

        // Convert 1 USD to STRK
        let usd_amount_low: u128 = 200_000_000_000_000_000; // 2e18
        let usd_amount_high: u128 = 0;

        let (strk_low, strk_high) = strk_dispatcher.convert_usd_to_strk(usd_amount_low, usd_amount_high);

        // Expected: 2 USD * 10^8 / 0.20 = 1 STRK = 1000000000000000000 (with 18 decimals)
        assert(strk_low == 1_000_000_000_000_000_000, 'Wrong STRK conversion');
        assert(strk_high == 0, 'Wrong STRK high part');
    }

    #[test]
    fn test_get_pragma_address() {
        let (strk_dispatcher, eth_dispatcher, _strk_price_convertor_address, _eth_price_convertor_address, mock_strk_usd_pragma_oracle_address, mock_eth_usd_pragma_oracle_address) = setup();
        
        // Check STRK converter pragma address
        let strk_pragma_address: ContractAddress = strk_dispatcher.get_pragma_address();
        assert(strk_pragma_address == mock_strk_usd_pragma_oracle_address, 'Wrong STRK pragma address');

        // Check ETH converter pragma address
        let eth_pragma_address: ContractAddress = eth_dispatcher.get_pragma_address();
        assert(eth_pragma_address == mock_eth_usd_pragma_oracle_address, 'Wrong ETH pragma address');
    }

    #[test]
    fn test_get_owner_address() {
        let (strk_dispatcher, eth_dispatcher, _strk_price_convertor_address, _eth_price_convertor_address, _mock_strk_usd_pragma_oracle_address, _mock_eth_usd_pragma_oracle_address) = setup();
        let expected_address: ContractAddress = 123.try_into().unwrap();
        
        // Check STRK converter owner
        let strk_owner_address: ContractAddress = strk_dispatcher.get_owner();
        assert(strk_owner_address == expected_address, 'Wrong STRK owner address');

        // Check ETH converter owner
        let eth_owner_address: ContractAddress = eth_dispatcher.get_owner();
        assert(eth_owner_address == expected_address, 'Wrong ETH owner address');
    }

    #[test]
    fn test_set_pragma_address() {
        let (strk_dispatcher, eth_dispatcher, strk_price_convertor_address, eth_price_convertor_address, _mock_strk_usd_pragma_oracle_address, _mock_eth_usd_pragma_oracle_address) = setup();
        let owner: ContractAddress = strk_dispatcher.get_owner();
        let new_pragma_address: ContractAddress = 456.try_into().unwrap();

        // Test STRK price converter
        start_cheat_caller_address(strk_price_convertor_address, owner);
        strk_dispatcher.set_pragma_address(new_pragma_address);
        let strk_pragma_address = strk_dispatcher.get_pragma_address();
        stop_cheat_caller_address(strk_price_convertor_address);
        assert(strk_pragma_address == new_pragma_address, 'Wrong STRK pragma address');

        // Test ETH price converter
        let new_eth_pragma_address: ContractAddress = 789.try_into().unwrap();
        start_cheat_caller_address(eth_price_convertor_address, owner);
        eth_dispatcher.set_pragma_address(new_eth_pragma_address);
        let eth_pragma_address = eth_dispatcher.get_pragma_address();
        stop_cheat_caller_address(eth_price_convertor_address);
        assert(eth_pragma_address == new_eth_pragma_address, 'Wrong ETH pragma address');
    }

    #[test]
    #[should_panic(expected: ('Owner only',))]
    fn test_set_pragma_address_not_owner() {
        let (strk_dispatcher, _eth_dispatcher, strk_price_convertor_address, _eth_price_convertor_address, _mock_strk_usd_pragma_oracle_address, _mock_eth_usd_pragma_oracle_address) = setup();
        let new_pragma_address: ContractAddress = 456.try_into().unwrap();
        let non_owner: ContractAddress = 789.try_into().unwrap();

        start_cheat_caller_address(strk_price_convertor_address, non_owner);
        // This should panic with "Owner only" error
        strk_dispatcher.set_pragma_address(new_pragma_address);
        stop_cheat_caller_address(strk_price_convertor_address);
    }

    #[test]
    fn test_get_strk_usd_price_with_timestamp() {
        let (strk_dispatcher, _eth_dispatcher, _strk_price_convertor_address, _eth_price_convertor_address, mock_strk_usd_pragma_oracle_address, _mock_eth_usd_pragma_oracle_address) = setup();
        let timestamp: u64 = 1234567890;

        start_cheat_block_timestamp(mock_strk_usd_pragma_oracle_address, timestamp);
        let (price, timestamp, decimals) = strk_dispatcher.get_price_with_timestamp(STRK_USD_PAIR_ID);
        stop_cheat_block_timestamp(mock_strk_usd_pragma_oracle_address);

        assert(price == STRK_USD_ORACLE_PRICE, 'Wrong price');
        assert(timestamp > 0, 'Wrong timestamp');
        assert(decimals == ORACLE_DECIMALS, 'Wrong decimals');
    }

    #[test]
    fn test_get_eth_usd_price_with_timestamp() {
        let (_strk_dispatcher, eth_dispatcher, _strk_price_convertor_address, _eth_price_convertor_address, _mock_strk_usd_pragma_oracle_address, mock_eth_usd_pragma_oracle_address) = setup();
        let timestamp: u64 = 1234567890;

        start_cheat_block_timestamp(mock_eth_usd_pragma_oracle_address, timestamp);
        let (price, timestamp, decimals) = eth_dispatcher.get_price_with_timestamp(ETH_USD_PAIR_ID);
        stop_cheat_block_timestamp(mock_eth_usd_pragma_oracle_address);

        assert(price == ETH_USD_ORACLE_PRICE, 'Wrong price');
        assert(timestamp > 0, 'Wrong timestamp');
        assert(decimals == ORACLE_DECIMALS, 'Wrong decimals');
    }

    #[test]
    fn test_convert_zero_amounts() {
        let (strk_dispatcher, eth_dispatcher, _strk_price_convertor_address, _eth_price_convertor_address, _mock_strk_usd_pragma_oracle_address, _mock_eth_usd_pragma_oracle_address) = setup();

        // Test zero STRK to USD conversion
        let (usd_low, usd_high) = strk_dispatcher.convert_strk_to_usd(0, 0);
        assert(usd_low == 0, 'Zero STRK should give zero USD');
        assert(usd_high == 0, 'Zero STRK high should be zero');

        // Test zero USD to STRK conversion
        let (strk_low, strk_high) = strk_dispatcher.convert_usd_to_strk(0, 0);
        assert(strk_low == 0, 'Zero USD should give zero STRK');
        assert(strk_high == 0, 'Zero USD high should be zero');

        // Test zero ETH to USD conversion
        let (usd_low, usd_high) = eth_dispatcher.convert_eth_to_usd(0, 0);
        assert(usd_low == 0, 'Zero ETH should give zero USD');
        assert(usd_high == 0, 'Zero ETH high should be zero');

        // Test zero USD to ETH conversion
        let (eth_low, eth_high) = eth_dispatcher.convert_usd_to_eth(0, 0);
        assert(eth_low == 0, 'Zero USD should give zero ETH');
        assert(eth_high == 0, 'Zero ETH high should be zero');
    }

    #[test]
    fn test_convert_large_amounts() {
        let (strk_dispatcher, eth_dispatcher, _strk_price_convertor_address, _eth_price_convertor_address, _mock_strk_usd_pragma_oracle_address, _mock_eth_usd_pragma_oracle_address) = setup();

        // Test large STRK amount conversion
        let large_strk_low: u128 = ONE_E18; // 1e18
        let large_strk_high: u128 = 100; // Large high part
        let (usd_low, usd_high) = strk_dispatcher.convert_strk_to_usd(large_strk_low, large_strk_high);
        assert(usd_low > 0 || usd_high > 0, 'Large STRK conversion works');

        // Test large ETH amount conversion
        let large_eth_low: u128 = ONE_E18; // 1e18
        let large_eth_high: u128 = 100; // Large high part
        let (usd_low, usd_high) = eth_dispatcher.convert_eth_to_usd(large_eth_low, large_eth_high);
        assert(usd_low > 0 || usd_high > 0, 'Large ETH conversion works');

        // Test large USD to STRK conversion
        let large_usd_low: u128 = ONE_E18 * 2; // 2e18
        let large_usd_high: u128 = 50; // Large high part
        let (strk_low, strk_high) = strk_dispatcher.convert_usd_to_strk(large_usd_low, large_usd_high);
        assert(strk_low > 0 || strk_high > 0, 'Large USD to STRK works');

        // Test large USD to ETH conversion
        let (eth_low, eth_high) = eth_dispatcher.convert_usd_to_eth(large_usd_low, large_usd_high);
        assert(eth_low > 0 || eth_high > 0, 'Large USD to ETH works');
    }

    #[test]
    fn test_constructor_initialization() {
        let (strk_dispatcher, eth_dispatcher, _strk_price_convertor_address, _eth_price_convertor_address, mock_strk_usd_pragma_oracle_address, mock_eth_usd_pragma_oracle_address) = setup();
        let expected_owner: ContractAddress = 123.try_into().unwrap();

        // Verify STRK/USD constructor initialization
        let strk_stored_pragma_address = strk_dispatcher.get_pragma_address();
        let strk_stored_owner = strk_dispatcher.get_owner();
        assert(strk_stored_pragma_address == mock_strk_usd_pragma_oracle_address, 'STRK pragma address not set');
        assert(strk_stored_owner == expected_owner, 'STRK owner not set correctly');

        // Verify ETH/USD constructor initialization
        let eth_stored_pragma_address = eth_dispatcher.get_pragma_address();
        let eth_stored_owner = eth_dispatcher.get_owner();
        assert(eth_stored_pragma_address == mock_eth_usd_pragma_oracle_address, 'ETH pragma address not set');
        assert(eth_stored_owner == expected_owner, 'ETH owner not set correctly');
    }
}

