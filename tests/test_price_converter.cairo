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
    const STRK_USD_PRICE: u256 = 2_000_000_000_000_000_000; // $0.20 in 18 decimals
    const ONE_E8: u128 = 100_000_000;
    const ONE_E18: u128 = 1_000_000_000_000_000_000;

    fn setup() -> (IPriceConverterDispatcher, ContractAddress, ContractAddress) {
        // Declare Contracts
        let mock_pragma_oracle_class = declare("MockOracle").unwrap().contract_class();
        let price_convertor_class = declare("PriceConverter").unwrap().contract_class();

        // Deploy Mock Contract
        let (mock_pragma_oracle_address, _) = mock_pragma_oracle_class.deploy(@array![]).unwrap();

        // Construct constructor args for PriceConverter
        let owner: ContractAddress = 123.try_into().unwrap();
        let constructor_args_price_converter = array![
            mock_pragma_oracle_address.into(), owner.into(),
        ];

        // Deploy PriceConverter Contract
        let (price_convertor_address, _) = price_convertor_class
            .deploy(@constructor_args_price_converter)
            .unwrap();

        // Create dispatcher
        let dispatcher = IPriceConverterDispatcher { contract_address: price_convertor_address };

        // Return dispatcher and mock oracle address
        (dispatcher, price_convertor_address, mock_pragma_oracle_address)
    }

    #[test]
    fn test_get_strk_usd_price() {
        let (dispatcher, _price_convertor_address, _mock_pragma_oracle_address) = setup();

        let (price, decimals) = dispatcher.get_strk_usd_price();

        assert(price == STRK_USD_ORACLE_PRICE, 'Wrong price');
        assert(decimals == ORACLE_DECIMALS, 'Wrong decimals');
    }

    #[test]
    fn test_convert_strk_to_usd() {
        let (dispatcher, _price_convertor_address, _mock_pragma_oracle_address) = setup();

        // Convert 1 STRK (1e18) to USD
        let strk_amount_low: u128 = ONE_E18; // 1e18
        let strk_amount_high: u128 = 0;

        let (usd_low, usd_high) = dispatcher.convert_strk_to_usd(strk_amount_low, strk_amount_high);

        // Expected: 1 STRK * 0.20 USD = 0.20 USD = 200000000000000000 (with 18 decimals)
        assert(usd_low == STRK_USD_ORACLE_PRICE * ONE_E18 / ONE_E8, 'Wrong USD conversion');
        assert(usd_high == 0, 'Wrong USD high part');
    }

    #[test]
    fn test_convert_usd_to_strk() {
        let (dispatcher, _price_convertor_address, _mock_pragma_oracle_address) = setup();

        // Convert 1 USD to STRK
        let usd_amount_low: u128 = 200_000_000_000_000_000; // 2e18
        let usd_amount_high: u128 = 0;

        let (strk_low, strk_high) = dispatcher.convert_usd_to_strk(usd_amount_low, usd_amount_high);

        // Expected: 2 USD * 10^8 / 0.20 = 1 STRK = 1000000000000000000 (with 18 decimals)
        assert(strk_low == 1_000_000_000_000_000_000, 'Wrong STRK conversion');
        assert(strk_high == 0, 'Wrong STRK high part');
    }

    #[test]
    fn test_get_pragma_address() {
        let (dispatcher, _price_convertor_address, _mock_pragma_oracle_address) = setup();
        let pragma_address: ContractAddress = dispatcher.get_pragma_address();
        let expected_address: ContractAddress = _mock_pragma_oracle_address;
        // Check if the function returns the correct pragma address
        assert(pragma_address == expected_address, 'Wrong pragma address');
    }

    #[test]
    fn test_get_owner_address() {
        let (dispatcher, _price_convertor_address, _mock_pragma_oracle_address) = setup();
        let owner_address: ContractAddress = dispatcher.get_owner();
        let expected_address: ContractAddress = 123.try_into().unwrap();
        // Check if the function returns the correct owner address
        assert(owner_address == expected_address, 'Wrong owner address');
    }

    #[test]
    fn test_set_pragma_address() {
        let (dispatcher, price_convertor_address, _mock_pragma_oracle_address) = setup();
        let owner: ContractAddress = dispatcher.get_owner();
        let new_pragma_address: ContractAddress = 456.try_into().unwrap();

        // Simulate a call from owner address
        start_cheat_caller_address(price_convertor_address, owner);

        // Set new pragma oracle address
        dispatcher.set_pragma_address(new_pragma_address);
        let pragma_address: ContractAddress = dispatcher.get_pragma_address();
        stop_cheat_caller_address(price_convertor_address);

        // Check if the new pragma address is correctly set by the owner
        assert(pragma_address == new_pragma_address, 'Wrong pragma address');
    }

    #[test]
    #[should_panic(expected: ('Owner only',))]
    fn test_set_pragma_address_not_owner() {
        let (dispatcher, price_convertor_address, _mock_pragma_oracle_address) = setup();
        let new_pragma_address: ContractAddress = 456.try_into().unwrap();

        // Simulate a call from a non-owner address
        let non_owner: ContractAddress = 789.try_into().unwrap();

        start_cheat_caller_address(price_convertor_address, non_owner);
        // This should panic with "Owner only" error
        dispatcher.set_pragma_address(new_pragma_address);
        stop_cheat_caller_address(price_convertor_address);
    }

    #[test]
    fn test_get_price_with_timestamp() {
        let (dispatcher, _price_convertor_address, mock_pragma_oracle_address) = setup();
        let timestamp: u64 = 1234567890;

        start_cheat_block_timestamp(mock_pragma_oracle_address, timestamp);
        let (price, timestamp, decimals) = dispatcher.get_price_with_timestamp();
        stop_cheat_block_timestamp(mock_pragma_oracle_address);

        assert(price == STRK_USD_ORACLE_PRICE, 'Wrong price');
        assert(timestamp > 0, 'Wrong timestamp');
        assert(decimals == ORACLE_DECIMALS, 'Wrong decimals');
    }

    #[test]
    fn test_convert_zero_amounts() {
        let (dispatcher, _price_convertor_address, _mock_pragma_oracle_address) = setup();

        // Test zero STRK to USD conversion
        let (usd_low, usd_high) = dispatcher.convert_strk_to_usd(0, 0);
        assert(usd_low == 0, 'Zero STRK should give zero USD');
        assert(usd_high == 0, 'Zero STRK high should be zero');

        // Test zero USD to STRK conversion
        let (strk_low, strk_high) = dispatcher.convert_usd_to_strk(0, 0);
        assert(strk_low == 0, 'Zero USD should give zero STRK');
        assert(strk_high == 0, 'Zero USD high should be zero');
    }

    #[test]
    fn test_convert_large_amounts() {
        let (dispatcher, _price_convertor_address, _mock_pragma_oracle_address) = setup();

        // Test large STRK amount conversion (using high part)
        let large_strk_low: u128 = ONE_E18; // 1e18
        let large_strk_high: u128 = 100; // Large high part

        let (usd_low, usd_high) = dispatcher.convert_strk_to_usd(large_strk_low, large_strk_high);

        // Should handle large numbers without overflow
        assert(usd_low > 0 || usd_high > 0, 'Large conversion works');

        // Test large USD amount conversion
        let large_usd_low: u128 = ONE_E18 * 2; // 2e18
        let large_usd_high: u128 = 50; // Large high part

        let (strk_low, strk_high) = dispatcher.convert_usd_to_strk(large_usd_low, large_usd_high);

        // Should handle large numbers without overflow
        assert(strk_low > 0 || strk_high > 0, 'Large USD conversion works');
    }

    #[test]
    fn test_constructor_initialization() {
        let (dispatcher, _price_convertor_address, mock_pragma_oracle_address) = setup();

        // Verify constructor properly initialized storage
        let stored_pragma_address = dispatcher.get_pragma_address();
        let stored_owner = dispatcher.get_owner();
        let expected_owner: ContractAddress = 123.try_into().unwrap();

        assert(stored_pragma_address == mock_pragma_oracle_address, 'Pragma address not set');
        assert(stored_owner == expected_owner, 'Owner not set correctly');
    }
}

