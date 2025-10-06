use pragma_lib::types::{DataType, PragmaPricesResponse};

#[starknet::interface]
pub trait IMockOracle<TContractState> {
    fn get_data_median(self: @TContractState, data_type: DataType) -> PragmaPricesResponse;
}

#[starknet::contract]
pub mod EthMockOracle {
    use starknet::get_block_timestamp;
    use pragma_lib::types::{DataType, PragmaPricesResponse};

    #[storage]
    struct Storage {}

    #[constructor]
    fn constructor(ref self: ContractState) {}

    #[abi(embed_v0)]
    impl IMockOracleImpl of super::IMockOracle<ContractState> {
        // @notice Returns a fixed mocked price of ETH/USD as $4000 (400,000,000,000 with 8 decimals)
        // @dev This is a mock implementation for testing purposes only.
        fn get_data_median(self: @ContractState, data_type: DataType) -> PragmaPricesResponse {
            let timestamp = get_block_timestamp();
            PragmaPricesResponse {
                price: 400000000000,
                decimals: 8,
                last_updated_timestamp: timestamp,
                num_sources_aggregated: 5,
                expiration_timestamp: Option::None,
            }
        }
    }
}
