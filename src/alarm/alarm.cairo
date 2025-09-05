use starknet::ContractAddress;

#[starknet::interface]
pub trait IAlarmContract<TContractState> {
    fn set_alarm(ref self: TContractState, wakeup_time: u64, stake_amount: u256);
    fn claim_winnings(
        ref self: TContractState,
        wakeup_time: u64,
        snooze_count: u8,
        signature: (felt252, felt252), // STARK signature (r, s)
        reward_amount: u256,
        merkle_proof: Array<felt252>,
    );
    fn set_verified_signer(ref self: TContractState, new_signer: felt252);
    fn set_reward_merkle_root(
        ref self: TContractState, day: u64, period: u8, reward_merkle_root: felt252,
    );
    fn get_pool_info(self: @TContractState, day: u64, period: u8) -> (felt252, bool);
    fn get_user_alarm(
        self: @TContractState, user: ContractAddress, day: u64, period: u8,
    ) -> (u256, u64, felt252);
    fn get_has_claimed_winnings(
        self: @TContractState, user: ContractAddress, day: u64, period: u8,
    ) -> bool;
    fn get_owner(self: @TContractState) -> starknet::ContractAddress;
    fn get_verified_signer(self: @TContractState) -> felt252;
    fn get_merkle_root(self: @TContractState, day: u64, period: u8) -> felt252;
    fn get_minimum_stake_amount(self: @TContractState) -> u256;
}

mod AlarmContractErrors {
    pub const ZERO_ADDRESS: felt252 = 'Zero_Address';
    pub const ALARM_ALREADY_EXISTS_IN_POOL: felt252 = 'Alarm_Already_Exists_In_Pool';
    pub const INVALID_STAKE_AMOUNT: felt252 = 'Invalid_Stake_Amount';
    pub const INVALID_WAKEUP_TIME: felt252 = 'Invalid_WakeUp_Time';
    pub const WAKEUP_TIME_NOT_REACHED: felt252 = 'WakeUp_Time_Not_Reached'; 
    pub const INVALID_PUBLIC_KEY: felt252 = 'Invalid_Public_Key';
    pub const INVALID_POOL: felt252 = 'Invalid_Pool';
    pub const INVALID_MERKLE_ROOT: felt252 = 'Invalid_Merkle_Root';
    pub const INVALID_SIGNATURE: felt252 = 'Invalid_Signature';
    pub const INVALID_PROOF: felt252 = 'Invalid_Proof';
    pub const TRANSFER_FAILED: felt252 = 'Transfer_Failed';
    pub const ALARM_NOT_ACTIVE: felt252 = 'Alarm_Not_Active';
    pub const POOL_NOT_FINALIZED: felt252 = 'Pool_Not_Finalized';
    pub const ALREADY_CLAIMED: felt252 = 'Already_Claimed';
    pub const MUST_BE_WINNER_TO_CLAIM_REWARD: felt252 = 'Must_Be_Winner_To_Claim_Reward';
    pub const NOT_ALARM_OWNER: felt252 = 'Not_Alarm_Owner';
}

#[starknet::contract]
pub mod AlarmContract {
    use core::ecdsa::check_ecdsa_signature;
    use core::num::traits::Zero;
    use core::poseidon::poseidon_hash_span;
    use openzeppelin_access::ownable::OwnableComponent;
    use openzeppelin_merkle_tree::merkle_proof;
    use openzeppelin_security::ReentrancyGuardComponent;
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::event::EventEmitter;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};
    use super::AlarmContractErrors;
    use everydayapp::price_converter::price_converter::{
        IPriceConverterDispatcher, IPriceConverterDispatcherTrait, _pow_10,
    };

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(
        path: ReentrancyGuardComponent, storage: reentrancy_guard, event: ReentrancyGuardEvent,
    );

    const ONE_DAY_IN_SECONDS: u64 = 86400; // 24 * 60 * 60
    const TWELVE_HOURS_IN_SECONDS: u64 = 43200; // 12 * 60 * 60

    // Minimum stake: 1 USD expressed with 18 decimals to match STRK token precision
    // This allows direct comparison without additional decimal conversions
    const MINIMUM_STAKE_AMOUNT_IN_USD: u256 = 1_000_000_000_000_000_000;

    // Ownable & ReentrancyGuard
    #[abi(embed_v0)]
    impl OwnableMixinImpl = OwnableComponent::OwnableMixinImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;
    impl InternalImpl = ReentrancyGuardComponent::InternalImpl<ContractState>;

    #[derive(Copy, Drop, PartialEq, starknet::Store, Serde)]
    pub enum Status {
        #[default]
        Inactive,
        Active,
        Completed
    }

    #[derive(Copy, Drop, starknet::Store, Serde)]
    pub struct Pool {
        pub reward_merkle_root: felt252, // Merkle root for the reward distribution
        pub is_finalized: bool // Indicates if the pool is finalized
    }

    #[derive(Copy, Drop, starknet::Store, Serde)]
    pub struct Alarm {
        pub user: ContractAddress, // Address of the user who set the alarm
        pub stake_amount: u256, // Amount staked by the user
        pub wakeup_time: u64, // Time when the alarm should trigger
        pub status: Status // Status of the alarm     
    }

    #[storage]
    struct Storage {
        // Public key of the verified signer
        verified_signer: felt252,
        // Address of the ERC20 token used for staking
        token: ContractAddress,
        // Price converter contract address
        price_converter: ContractAddress,
        // Day -> Period(AM/PM) -> Pool mapping
        pools: Map<(u64, u8), Pool>,
        // User Address -> Day -> Period(AM/PM) -> Alarm mapping
        user_alarms: Map<(ContractAddress, u64, u8), Alarm>,
        // User Address -> Day -> Period(AM/PM) -> Claim status mapping
        user_has_claimed_winnings: Map<(ContractAddress, u64, u8), bool>,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        reentrancy_guard: ReentrancyGuardComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        AlarmSet: AlarmSet,
        WinningsClaimed: WinningsClaimed,
        MerkleRootSet: MerkleRootSet,
        VerifiedSignerSet: VerifiedSignerSet,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct AlarmSet {
        #[key]
        pub user: starknet::ContractAddress,
        #[key]
        pub wakeup_time: u64,
        #[key]
        pub stake_amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct WinningsClaimed {
        #[key]
        pub user: starknet::ContractAddress,
        #[key]
        pub wakeup_time: u64,
        #[key]
        pub snooze_count: u8,
        #[key]
        pub winnings_amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct MerkleRootSet {
        #[key]
        pub merkle_root: felt252, // add more info about pool and day
        #[key]
        pub day: u64,
        #[key]
        pub period: u8, // 0 -> AM, 1 -> PM
    }

    #[derive(Drop, starknet::Event)]
    pub struct VerifiedSignerSet {
        #[key]
        pub verified_signer: felt252,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress, // Address of the contract owner
        verified_signer: felt252, // Public key of the verified signer
        token: ContractAddress, // Address of the ERC20 token used for staking
        price_converter: ContractAddress, // Address of the price converter contract
    ) {
        assert(!owner.is_zero(), AlarmContractErrors::ZERO_ADDRESS);
        assert(!token.is_zero(), AlarmContractErrors::ZERO_ADDRESS);
        assert(!verified_signer.is_zero(), AlarmContractErrors::INVALID_PUBLIC_KEY);
        assert(!price_converter.is_zero(), AlarmContractErrors::ZERO_ADDRESS);
        self.ownable.initializer(owner);
        self.verified_signer.write(verified_signer);
        self.token.write(token);
        self.price_converter.write(price_converter);
        self.emit(Event::VerifiedSignerSet(VerifiedSignerSet { verified_signer: verified_signer }));
    }

    #[abi(embed_v0)]
    impl AlarmContract of super::IAlarmContract<ContractState> {
        fn set_alarm(ref self: ContractState, wakeup_time: u64, stake_amount: u256) {
            self.reentrancy_guard.start();
            assert(stake_amount > 0, AlarmContractErrors::INVALID_STAKE_AMOUNT);

            // Check if the wakeup time is in the future
            assert(wakeup_time > get_block_timestamp(), AlarmContractErrors::INVALID_WAKEUP_TIME);

            // Check if stake amount meets the minimum USD requirement
            let usd_value: u256 = self._get_eth_usd_value(stake_amount);
            assert(
                usd_value >= MINIMUM_STAKE_AMOUNT_IN_USD, AlarmContractErrors::INVALID_STAKE_AMOUNT,
            );

            let day: u64 = (wakeup_time / ONE_DAY_IN_SECONDS);
            let period_in_u64: u64 = ((wakeup_time % ONE_DAY_IN_SECONDS) / TWELVE_HOURS_IN_SECONDS);

            let period: u8 = period_in_u64.try_into().unwrap();

            let user = get_caller_address();
            let existing_alarm = self.user_alarms.read((user, day, period));

            // Check if the alarm already exists for the user on the specified day and period (pool)
            assert(
                existing_alarm.status == Status::Inactive,
                AlarmContractErrors::ALARM_ALREADY_EXISTS_IN_POOL,
            );

            // Create a new alarm
            let new_user_alarm = Alarm {
                user: user,
                stake_amount: stake_amount,
                wakeup_time: wakeup_time,
                status: Status::Active,
            };

            // Store the new alarm in the user_alarms mapping
            self.user_alarms.write((user, day, period), new_user_alarm);

            // transfer stake amount from user to contract
            let token_dispatcher = IERC20Dispatcher { contract_address: self.token.read() };

            let success: bool = token_dispatcher
                .transfer_from(user, get_contract_address(), stake_amount);
            assert(success, AlarmContractErrors::TRANSFER_FAILED);

            self
                .emit(
                    Event::AlarmSet(
                        AlarmSet {
                            user: user, wakeup_time: wakeup_time, stake_amount: stake_amount,
                        },
                    ),
                );
            self.reentrancy_guard.end();
        }

        fn claim_winnings(
            ref self: ContractState,
            wakeup_time: u64,
            snooze_count: u8,
            signature: (felt252, felt252), // STARK signature (r, s)
            reward_amount: u256,
            merkle_proof: Array<felt252>,
        ) {
            self.reentrancy_guard.start();

            assert(get_block_timestamp() >= wakeup_time, AlarmContractErrors::WAKEUP_TIME_NOT_REACHED);
            
            let day: u64 = (wakeup_time / ONE_DAY_IN_SECONDS);
            let period_in_u64: u64 = ((wakeup_time % ONE_DAY_IN_SECONDS) / TWELVE_HOURS_IN_SECONDS);
            let period: u8 = period_in_u64.try_into().unwrap();
            let claimer = get_caller_address();

            let alarm = self.user_alarms.read((claimer, day, period));

            // Only the alarm owner can claim their own winnings
            assert(alarm.user == claimer, AlarmContractErrors::NOT_ALARM_OWNER);

            // Perform initial checks
            self._validate_claim_preconditions(alarm, day, period);

            // Verify the outcome signature from the backend
            let (signature_r, signature_s) = signature;
            self._verify_outcome_signature(wakeup_time, snooze_count, signature_r, signature_s);

            // Calculate how much of the original stake should be returned based on snooze count
            let amount_to_return: u256 = InternalFunctionsTrait::_calculate_stake_return(
                alarm.stake_amount, snooze_count,
            );

            // Verify the reward claim if the user was a winner
            if (snooze_count == 0) {
                self._verify_reward_claim(day, period, reward_amount, merkle_proof);
            } else {
                assert(reward_amount == 0, AlarmContractErrors::MUST_BE_WINNER_TO_CLAIM_REWARD);
            }

            // Mark the user as having claimed winnings for this day and period
            self.user_has_claimed_winnings.write((claimer, day, period), true);

            // Update alarm status to Completed
            let mut updated_alarm = alarm;
            updated_alarm.status = Status::Completed;
            self.user_alarms.write((claimer, day, period), updated_alarm);

            let total_payout: u256 = amount_to_return + reward_amount;
            if (total_payout > 0) {
                // Transfer the total payout to the claimer
                let token_dispatcher = IERC20Dispatcher { contract_address: self.token.read() };
                let success: bool = token_dispatcher.transfer(claimer, total_payout);
                assert(success, AlarmContractErrors::TRANSFER_FAILED);
            }
            self
                .emit(
                    Event::WinningsClaimed(
                        WinningsClaimed {
                            user: claimer,
                            wakeup_time: wakeup_time,
                            snooze_count: snooze_count,
                            winnings_amount: total_payout,
                        },
                    ),
                );
            self.reentrancy_guard.end();
        }

        fn set_verified_signer(ref self: ContractState, new_signer: felt252) {
            self.ownable.assert_only_owner();
            assert(!new_signer.is_zero(), AlarmContractErrors::INVALID_PUBLIC_KEY);
            self.verified_signer.write(new_signer);
            self.emit(Event::VerifiedSignerSet(VerifiedSignerSet { verified_signer: new_signer }));
        }

        fn set_reward_merkle_root(
            ref self: ContractState, day: u64, period: u8, reward_merkle_root: felt252,
        ) {
            self.ownable.assert_only_owner();
            // Ensure period is either AM (0) or PM (1)
            assert(period == 0 || period == 1, AlarmContractErrors::INVALID_POOL);

            // Ensure merkle root is not zero
            assert(reward_merkle_root != 0, AlarmContractErrors::INVALID_MERKLE_ROOT);

            self
                .pools
                .write(
                    (day, period),
                    Pool {
                        reward_merkle_root: reward_merkle_root,
                        is_finalized: true // Set the pool as finalized
                    },
                );

            self.emit(Event::MerkleRootSet(MerkleRootSet { merkle_root: reward_merkle_root, day: day, period: period }) );
        }

        fn get_pool_info(self: @ContractState, day: u64, period: u8) -> (felt252, bool) {
            assert(period == 0 || period == 1, AlarmContractErrors::INVALID_POOL);

            let pool = self.pools.read((day, period));

            (pool.reward_merkle_root, pool.is_finalized)
        }

        fn get_user_alarm(
            self: @ContractState, user: ContractAddress, day: u64, period: u8,
        ) -> (u256, u64, felt252) {
            assert(!user.is_zero(), AlarmContractErrors::ZERO_ADDRESS);
            assert(period == 0 || period == 1, AlarmContractErrors::INVALID_POOL);

            let alarm = self.user_alarms.read((user, day, period));
            let alarm_status: felt252 = match alarm.status {
                Status::Inactive => 'Inactive',
                Status::Active => 'Active',
                Status::Completed => 'Completed',
            };

            (alarm.stake_amount, alarm.wakeup_time, alarm_status)
        }

        fn get_has_claimed_winnings(
            self: @ContractState, user: ContractAddress, day: u64, period: u8,
        ) -> bool {
            assert(period == 0 || period == 1, AlarmContractErrors::INVALID_POOL);
            self.user_has_claimed_winnings.read((user, day, period))
        }

        fn get_owner(self: @ContractState) -> ContractAddress {
            self.ownable.owner()
        }

        fn get_verified_signer(self: @ContractState) -> felt252 {
            self.verified_signer.read()
        }

        fn get_merkle_root(self: @ContractState, day: u64, period: u8) -> felt252 {
            // self.ownable.assert_only_owner();
            assert(period == 0 || period == 1, AlarmContractErrors::INVALID_POOL);
            self.pools.read((day, period)).reward_merkle_root
        }

        fn get_minimum_stake_amount(self: @ContractState) -> u256 {
            MINIMUM_STAKE_AMOUNT_IN_USD
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn _get_eth_usd_value(self: @ContractState, stake_amount: u256) -> u256 {
            let price_converter = IPriceConverterDispatcher {
                contract_address: self.price_converter.read(),
            };

            // Get ETH/USD price and its decimals
            let (eth_usd_price, decimals) = price_converter.get_eth_usd_price();
            let price_u256: u256 = eth_usd_price.into();
            assert(price_u256 > 0, 'Price must be positive');

            let price_divisor = _pow_10(decimals.into()); // 10^8 
            assert(price_divisor > 0, 'Price divisor cannot be zero');

            // The Pragma Oracle provides price with 8 decimals -> price * 10^8
            // The staked amount (ETH token) has 18 decimals
            // We need to convert the USD value to have 18 decimals for consistency

            // Calculation -> (ETH_amount_18_decimals * USD_price_8_decimals) / 10^8 = USD_value_18_decimals
            let usd_value: u256 = (stake_amount * price_u256) / (price_divisor);

            // Return the USD value with 18 decimals
            (usd_value)
        }

        fn _validate_claim_preconditions(
            ref self: ContractState, alarm: Alarm, day: u64, period: u8,
        ) {
            assert(alarm.status == Status::Active, AlarmContractErrors::ALARM_NOT_ACTIVE);
            assert(
                self.pools.read((day, period)).is_finalized,
                AlarmContractErrors::POOL_NOT_FINALIZED,
            );
            assert(
                !self.user_has_claimed_winnings.read((get_caller_address(), day, period)),
                AlarmContractErrors::ALREADY_CLAIMED,
            );
        }

        fn _verify_outcome_signature(
            ref self: ContractState,
            wakeup_time: u64,
            snooze_count: u8,
            signature_r: felt252,
            signature_s: felt252,
        ) {
            let caller = get_caller_address();
            let verified_signer = self.verified_signer.read();

            // Input validation
            assert(!verified_signer.is_zero(), AlarmContractErrors::INVALID_PUBLIC_KEY);
            assert(signature_r != 0, AlarmContractErrors::INVALID_SIGNATURE);
            assert(signature_s != 0, AlarmContractErrors::INVALID_SIGNATURE);
            assert(snooze_count >= 0, 'Invalid snooze count');

            // Create message hash using Poseidon (STARK-native hashing)
            // Message Hash: [caller, wakeup_time, snooze_count]
            let mut message_data = ArrayTrait::new();
            message_data.append(caller.into());
            message_data.append(wakeup_time.into());
            message_data.append(snooze_count.into());

            let message_hash = poseidon_hash_span(message_data.span());

            // Verify STARK curve signature
            let is_valid = check_ecdsa_signature(
                message_hash,
                verified_signer, // Public key 
                signature_r,
                signature_s,
            );

            assert(is_valid, AlarmContractErrors::INVALID_SIGNATURE);
        }

        fn _calculate_stake_return(stake_amount: u256, snooze_count: u8) -> u256 {
            const PERCENT_BASE: u256 = 100;
            const SLASH_20_PERCENT: u256 = 80; // 20% slash -> keep 80%
            const SLASH_50_PERCENT: u256 = 50; // 50% slash -> keep 50%
            const SLASH_100_PERCENT: u256 = 0; // 100% slash -> keep 0%

            match snooze_count {
                0 => stake_amount, // No snooze, return full stake
                1 => (stake_amount * SLASH_20_PERCENT) / PERCENT_BASE,
                2 => (stake_amount * SLASH_50_PERCENT) / PERCENT_BASE,
                _ => SLASH_100_PERCENT,
            }
        }

        fn _verify_reward_claim(
            ref self: ContractState,
            day: u64,
            period: u8,
            reward_amount: u256,
            merkle_proof: Array<felt252>,
        ) {
            let caller = get_caller_address();
            let pool = self.pools.read((day, period));

            // Create leaf hash using Poseidon (STARK native)
            // Hash caller address and reward amount
            let mut leaf_data = ArrayTrait::new();
            leaf_data.append(caller.into());
            leaf_data.append(reward_amount.low.into());
            leaf_data.append(reward_amount.high.into());

            let leaf = poseidon_hash_span(leaf_data.span());

            // Convert Array to Span for the OpenZeppelin function
            let proof_span = merkle_proof.span();

            // Using OpenZeppelin's verify_poseidon for Starknet-native verification
            let is_valid = merkle_proof::verify_poseidon(proof_span, pool.reward_merkle_root, leaf);
            assert(is_valid, AlarmContractErrors::INVALID_PROOF);
        }
    }
}

