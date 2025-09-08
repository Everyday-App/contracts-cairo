use starknet::ContractAddress;

// Interface for the Price Converter contract using Pragma Oracle
#[starknet::interface]
pub trait IPriceConverter<TContractState> {
    fn get_strk_usd_price(self: @TContractState) -> (u128, u8);
    fn get_eth_usd_price(self: @TContractState) -> (u128, u8);
    fn get_price_with_timestamp(self: @TContractState, pair_id: felt252) -> (u128, u64, u8);
    fn convert_eth_to_usd(
        self: @TContractState, eth_amount_low: u128, eth_amount_high: u128,
    ) -> (u128, u128);
    fn convert_usd_to_eth(
        self: @TContractState, usd_amount_low: u128, usd_amount_high: u128,
    ) -> (u128, u128);
    fn convert_strk_to_usd(
        self: @TContractState, strk_amount_low: u128, strk_amount_high: u128,
    ) -> (u128, u128);
    fn convert_usd_to_strk(
        self: @TContractState, usd_amount_low: u128, usd_amount_high: u128,
    ) -> (u128, u128);
    fn get_pragma_address(self: @TContractState) -> ContractAddress;
    fn set_pragma_address(ref self: TContractState, new_address: ContractAddress);
    fn get_owner(self: @TContractState) -> ContractAddress;
}

// Price Converter contract using Pragma Oracle
#[starknet::contract]
pub mod PriceConverter {
    use pragma_lib::abi::{IPragmaABIDispatcher, IPragmaABIDispatcherTrait};
    use pragma_lib::types::{DataType, PragmaPricesResponse};
    use starknet::storage::*;
    use starknet::{ContractAddress, get_caller_address};

    const STRK_USD_PAIR_ID: felt252 = 'STRK/USD'; // Pragma pair identifier
    const ETH_USD_PAIR_ID: felt252 = 'ETH/USD'; // Pragma pair identifier
    const PRAGMA_DECIMALS: u8 = 8; // Pragma Oracle returns 8 decimals
    const PRECISION: u256 = 1000000000000000000; // 1e18 for calculations

    #[storage]
    pub struct Storage {
        pragma_oracle: ContractAddress,
        owner: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        PragmaOracleUpdated: PragmaOracleUpdated,
        OwnershipTransferred: OwnershipTransferred,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PragmaOracleUpdated {
        old_address: ContractAddress,
        new_address: ContractAddress,
        updated_by: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct OwnershipTransferred {
        previous_owner: ContractAddress,
        new_owner: ContractAddress,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState, pragma_oracle_address: ContractAddress, owner: ContractAddress,
    ) {
        self.pragma_oracle.write(pragma_oracle_address);
        self.owner.write(owner);
    }

    #[abi(embed_v0)]
    impl PriceConverterImpl of super::IPriceConverter<ContractState> {
        fn get_eth_usd_price(self: @ContractState) -> (u128, u8) {
            let pragma_address = self.pragma_oracle.read();
            let pragma_dispatcher = IPragmaABIDispatcher { contract_address: pragma_address };

            // Get ETH/USD price from Pragma
            let output: PragmaPricesResponse = pragma_dispatcher
                .get_data_median(DataType::SpotEntry(ETH_USD_PAIR_ID));

            // Validate price data
            assert(output.price > 0, 'Invalid price data');

            (output.price, PRAGMA_DECIMALS)
        }

        fn get_strk_usd_price(self: @ContractState) -> (u128, u8) {
            let pragma_address = self.pragma_oracle.read();
            let pragma_dispatcher = IPragmaABIDispatcher { contract_address: pragma_address };

            // Get STRK/USD price from Pragma
            let output: PragmaPricesResponse = pragma_dispatcher
                .get_data_median(DataType::SpotEntry(STRK_USD_PAIR_ID));

            // Validate price data
            assert(output.price > 0, 'Invalid price data');

            (output.price, PRAGMA_DECIMALS)
        }

        fn get_price_with_timestamp(self: @ContractState, pair_id: felt252) -> (u128, u64, u8) {
            let pragma_address = self.pragma_oracle.read();
            let pragma_dispatcher = IPragmaABIDispatcher { contract_address: pragma_address };

            // Get pair_id (STRK/USD or ETH/USD) price from Pragma
            let output: PragmaPricesResponse = pragma_dispatcher
                .get_data_median(DataType::SpotEntry(pair_id));

            // Validate price data
            assert(output.price > 0, 'Invalid price data');

            // Validate price is not stale
            let current_time = starknet::get_block_timestamp();

            // Safe staleness check - prevents underflow
            if current_time >= output.last_updated_timestamp {
                assert(current_time - output.last_updated_timestamp < 3600, 'Price data is stale');
            }
            // If oracle timestamp is in future (small clock drift), treat as fresh
            (output.price, output.last_updated_timestamp, PRAGMA_DECIMALS)
        }

        fn convert_eth_to_usd(
            self: @ContractState, eth_amount_low: u128, eth_amount_high: u128,
        ) -> (u128, u128) {
            let (price, decimals) = self.get_eth_usd_price();
            let price_u256: u256 = price.into();

            // Reconstruct u256 from low and high parts
            let eth_amount = u256 { low: eth_amount_low, high: eth_amount_high };

            // Convert ETH to USD: (eth_amount * price) / 10^decimals
            let usd_value = (eth_amount * price_u256) / super::_pow_10(decimals.into());
            (usd_value.low, usd_value.high)
        }

        fn convert_usd_to_eth(
            self: @ContractState, usd_amount_low: u128, usd_amount_high: u128,
        ) -> (u128, u128) {
            let (price, decimals) = self.get_eth_usd_price();
            let price_u256: u256 = price.into();

            // Reconstruct u256 from low and high parts
            let usd_amount = u256 { low: usd_amount_low, high: usd_amount_high };

            // Convert USD to ETH: (usd_amount * 10^decimals) / price
            let eth_value = (usd_amount * super::_pow_10(decimals.into())) / price_u256;
            (eth_value.low, eth_value.high)
        }

        fn convert_strk_to_usd(
            self: @ContractState, strk_amount_low: u128, strk_amount_high: u128,
        ) -> (u128, u128) {
            let (price, decimals) = self.get_strk_usd_price();
            let price_u256: u256 = price.into();

            // Reconstruct u256 from low and high parts
            let strk_amount = u256 { low: strk_amount_low, high: strk_amount_high };

            // Convert STRK to USD: (strk_amount * price) / 10^decimals
            let usd_value = (strk_amount * price_u256) / super::_pow_10(decimals.into());
            (usd_value.low, usd_value.high)
        }

        fn convert_usd_to_strk(
            self: @ContractState, usd_amount_low: u128, usd_amount_high: u128,
        ) -> (u128, u128) {
            let (price, decimals) = self.get_strk_usd_price();
            let price_u256: u256 = price.into();

            // Reconstruct u256 from low and high parts
            let usd_amount = u256 { low: usd_amount_low, high: usd_amount_high };

            // Convert USD to STRK: (usd_amount * 10^decimals) / price
            let strk_value = (usd_amount * super::_pow_10(decimals.into())) / price_u256;
            (strk_value.low, strk_value.high)
        }

        fn set_pragma_address(ref self: ContractState, new_address: ContractAddress) {
            self._assert_only_owner();
            let old_address = self.pragma_oracle.read();
            self.pragma_oracle.write(new_address);

            self
                .emit(
                    Event::PragmaOracleUpdated(
                        PragmaOracleUpdated {
                            old_address, new_address, updated_by: get_caller_address(),
                        },
                    ),
                );
        }

        fn get_pragma_address(self: @ContractState) -> ContractAddress {
            self.pragma_oracle.read()
        }

        fn get_owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _assert_only_owner(self: @ContractState) {
            let caller = get_caller_address();
            let owner = self.owner.read();
            assert(caller == owner, 'Owner only');
        }
    }
}

// Helper function to calculate 10^n - made public for reuse
pub fn _pow_10(exp: u256) -> u256 {
    let mut result: u256 = 1;
    let mut i: u256 = 0;
    while i < exp {
        result = result * 10;
        i += 1;
    }
    result
}
