use starknet::ContractAddress;

#[starknet::interface]
pub trait IPhoneLockContract<TContractState> {
    fn set_phone_lock(
        ref self: TContractState,
        start_time: u64,
        duration: u64,
        stake_amount: u256,
    );
    fn claim_lock_rewards(
        ref self: TContractState,
        lock_id: u64,
        completion_status: bool, // true = completed successfully, false = failed/exited
        signature: (felt252, felt252), // STARK signature (r, s)
        reward_amount: u256,
        merkle_proof: Array<felt252>,
    );
    fn set_verified_signer(ref self: TContractState, new_signer: felt252);
    fn set_reward_merkle_root(
        ref self: TContractState, day: u64, period: u8, reward_merkle_root: felt252, new_rewards: u256, protocol_fees: u256,
    );
    fn withdraw_protocol_fees(ref self: TContractState);
    fn get_pool_info(self: @TContractState, day: u64, period: u8) -> (felt252, bool, u256, u64, u256);
    fn get_user_lock(
        self: @TContractState, user: ContractAddress, lock_id: u64,
    ) -> (u256, u64, u64, u64, felt252);
    fn get_has_claimed_rewards(
        self: @TContractState, user: ContractAddress, lock_id: u64,
    ) -> bool;
    fn get_owner(self: @TContractState) -> starknet::ContractAddress;
    fn get_verified_signer(self: @TContractState) -> felt252;
    fn get_merkle_root(self: @TContractState, day: u64, period: u8) -> felt252;
    fn get_minimum_stake_amount(self: @TContractState) -> u256;
    fn get_next_lock_id(self: @TContractState) -> u64;
}

mod PhoneLockContractErrors {
    pub const ZERO_ADDRESS: felt252 = 'Zero_Address';
    pub const INVALID_STAKE_AMOUNT: felt252 = 'Invalid_Stake_Amount';
    pub const LESS_THAN_MINIMUM_USD: felt252 = 'Less_Than_Minimum_USD';
    
    pub const INVALID_DURATION: felt252 = 'Invalid_Duration';
    pub const INVALID_START_TIME: felt252 = 'Invalid_Start_Time';
    pub const LOCK_TIME_NOT_REACHED: felt252 = 'Lock_Time_Not_Reached';
    
    pub const INVALID_POOL: felt252 = 'Invalid_Pool';
    pub const POOL_NOT_FINALIZED: felt252 = 'Pool_Not_Finalized';
    pub const POOL_IS_FINALIZED: felt252 = 'Pool_Is_Finalized';

    pub const INVALID_PUBLIC_KEY: felt252 = 'Invalid_Public_Key';
    pub const INVALID_MERKLE_ROOT: felt252 = 'Invalid_Merkle_Root';
    pub const INVALID_SIGNATURE: felt252 = 'Invalid_Signature';
    pub const INVALID_PROOF: felt252 = 'Invalid_Proof';

    pub const TRANSFER_FAILED: felt252 = 'Transfer_Failed';
    pub const PROTOCOL_FEE_TRANSFER_FAILED: felt252 = 'Protocol_Fee_Transfer_Failed';
    
    pub const LOCK_NOT_ACTIVE: felt252 = 'Lock_Not_Active';
    pub const LOCK_NOT_FOUND: felt252 = 'Lock_Not_Found';
    pub const LOCK_ALREADY_EXISTS_IN_POOL: felt252 = 'Lock_Already_Exists_In_Pool';
    pub const LOCK_ALREADY_CLAIMED: felt252 = 'Already_Claimed';
    pub const NOT_LOCK_OWNER: felt252 = 'Not_Lock_Owner';
    pub const MUST_BE_WINNER_TO_CLAIM_REWARD: felt252 = 'Must_Be_Winner_To_Claim_Reward';
}

#[starknet::contract]
pub mod PhoneLockContract {
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
    use super::PhoneLockContractErrors;
    use everydayapp::price_converter::price_converter::{
        IPriceConverterDispatcher, IPriceConverterDispatcherTrait, _pow_10,
    };

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(
        path: ReentrancyGuardComponent, storage: reentrancy_guard, event: ReentrancyGuardEvent,
    );

    const ONE_DAY_IN_SECONDS: u64 = 86400; // 24 * 60 * 60
    const SIX_HOURS_IN_SECONDS: u64 = 21600; // 6 * 60 * 60
    const MIN_DURATION: u64 = 300;   // 5 minutes minimum
    const MAX_DURATION: u64 = 86400; // 24 hours maximum
    
    // Minimum stake: 1 USD expressed with 18 decimals to match STRK token precision
    const MINIMUM_STAKE_AMOUNT_IN_USD: u256 = 1_000_000_000_000_000_000;

    // Ownable & ReentrancyGuard
    #[abi(embed_v0)]
    impl OwnableMixinImpl = OwnableComponent::OwnableMixinImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;
    impl InternalImpl = ReentrancyGuardComponent::InternalImpl<ContractState>;

    #[derive(Copy, Drop, PartialEq, starknet::Store, Serde)]
    pub enum PhoneLockStatus {
        #[default]
        Inactive,
        Active,
        Completed,
    }

    #[derive(Copy, Drop, starknet::Store, Serde)]
    pub struct Pool {
        pub user_count: u64, // Number of users who have set locks in this pool
        pub total_staked: u256, // Total amount staked in this pool
        pub reward_merkle_root: felt252, // Merkle root for the reward distribution
        pub is_finalized: bool, // Indicates if the pool is finalized
        pub pool_reward: u256, // Total rewards available for this pool's winners
    }

    #[derive(Copy, Drop, starknet::Store, Serde)]
    pub struct PhoneLock {
        pub user: ContractAddress, // Address of the user who set the lock
        pub period: u8, // 6-hour period (0-3)
        pub day: u64, // Day calculated from start_time
        pub stake_amount: u256, // Amount staked by the user
        pub start_time: u64, // When lock begins
        pub duration: u64, // Lock duration in seconds
        pub end_time: u64, // start_time + duration
        pub lock_id: u64, // Unique identifier for the lock
        pub status: PhoneLockStatus, // Status of the lock
    }

    #[storage]
    struct Storage {
        
        verified_signer: felt252, // Verified signer public key
        token: ContractAddress, // Address of the ERC20 token used for staking
        price_converter: ContractAddress, // Price converter contract address
        protocol_fees_address: ContractAddress,
        protocol_fees: u256, 
        lock_id: u64,
        
        pools: Map<(u64, u8), Pool>, // Day -> Period(0-3) -> Pool mapping
        
        user_locks: Map<(ContractAddress, u64), PhoneLock>, // User Address -> Lock ID -> Lock mapping
        
        user_has_claimed_rewards: Map<(ContractAddress, u64), bool>, // User Address -> Lock ID -> Claim status mapping
        
        user_has_lock_in_pool: Map<(ContractAddress, u64, u8), bool>, // User Address -> Day -> Period(0-3) -> true/false if user has a lock in this pool
        
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        reentrancy_guard: ReentrancyGuardComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        PhoneLockSet: PhoneLockSet,
        WinningsClaimed: WinningsClaimed,
        MerkleRootSetForPool: MerkleRootSetForPool,
        PoolIsFinalized: PoolIsFinalized,
        VerifiedSignerSet: VerifiedSignerSet,
        ProtocolFeeUpdated: ProtocolFeeUpdated,
        ProtocolFeesWithdrawn: ProtocolFeesWithdrawn,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PhoneLockSet {
        #[key]
        pub user: starknet::ContractAddress,
        #[key]
        pub lock_id: u64,
        #[key]
        pub start_time: u64,
        #[key]
        pub duration: u64,
        #[key]
        pub stake_amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct WinningsClaimed {
        #[key]
        pub user: starknet::ContractAddress,
        #[key]
        pub lock_id: u64,
        #[key]
        pub completion_status: bool,
        #[key]
        pub winnings_amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct MerkleRootSetForPool {
        #[key]
        pub merkle_root: felt252,
        #[key]
        pub day: u64,
        #[key]
        pub period: u8,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PoolIsFinalized {
        #[key]
        pub day: u64,
        #[key]
        pub period: u8,
    }

    #[derive(Drop, starknet::Event)]
    pub struct VerifiedSignerSet {
        #[key]
        pub verified_signer: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ProtocolFeeUpdated {
        #[key]
        pub protocol_fees: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ProtocolFeesWithdrawn {
        #[key]
        pub amount: u256,
        #[key]
        pub recipient: starknet::ContractAddress,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress, // Address of the contract owner
        verified_signer: felt252, // Public key of the verified signer
        token: ContractAddress, // Address of the ERC20 token used for staking
        price_converter: ContractAddress, // Address of the price converter contract
        protocol_fees_address: ContractAddress, // Address that receives protocol fees
    ) {
        assert(!owner.is_zero(), PhoneLockContractErrors::ZERO_ADDRESS);
        assert(!token.is_zero(), PhoneLockContractErrors::ZERO_ADDRESS);
        assert(!verified_signer.is_zero(), PhoneLockContractErrors::INVALID_PUBLIC_KEY);
        assert(!price_converter.is_zero(), PhoneLockContractErrors::ZERO_ADDRESS);
        assert(!protocol_fees_address.is_zero(), PhoneLockContractErrors::ZERO_ADDRESS);
        self.ownable.initializer(owner);
        self.verified_signer.write(verified_signer);
        self.token.write(token);
        self.price_converter.write(price_converter);
        self.protocol_fees_address.write(protocol_fees_address);
        self.protocol_fees.write(0);
        self.lock_id.write(1); // Reserve 0 for NO LOCK
        self.emit(Event::VerifiedSignerSet(VerifiedSignerSet { verified_signer: verified_signer }));
    }

    #[abi(embed_v0)]
    impl PhoneLockContract of super::IPhoneLockContract<ContractState> {
        fn set_phone_lock(
            ref self: ContractState,
            start_time: u64,
            duration: u64,
            stake_amount: u256,
        ) {
            self.reentrancy_guard.start();
            
            // Check if the stake amount is greater than 0 and greater than minimum stake amount in USD
            self._stake_amount_is_valid(stake_amount);
            
            // Check if the duration is valid (between 5 minutes and 24 hours)
            self._duration_is_valid(duration);

            // Check if the start time is valid
            self._start_time_is_valid(start_time);

            // Calculate day and period 
            let (day, period) = self._calculate_day_and_period(start_time);

            // Calculate end time
            let end_time: u64 = start_time + duration;

            let user = get_caller_address();
            
            // Check if the user already has a lock in this pool
            let has_lock_in_pool = self.user_has_lock_in_pool.read((user, day, period));
            assert(!has_lock_in_pool, PhoneLockContractErrors::LOCK_ALREADY_EXISTS_IN_POOL);

            // Check if the pool is already finalized
            let pool = self.pools.read((day, period));
            assert(!pool.is_finalized, PhoneLockContractErrors::POOL_NOT_FINALIZED);

            // Get current lock ID
            let lock_id = self.lock_id.read();

            // Create a new phone lock
            let new_phone_lock = PhoneLock {
                user: user,
                period: period,
                day: day,
                stake_amount: stake_amount,
                start_time: start_time,
                duration: duration,
                end_time: end_time,
                lock_id: lock_id,
                status: PhoneLockStatus::Active,
            };

            // Store the new lock in the user_locks mapping
            self.user_locks.write((user, lock_id), new_phone_lock);
            
            // Mark that user has a lock in this pool
            self.user_has_lock_in_pool.write((user, day, period), true);

            // Update staked amount & user count in the pool (same as alarm logic)
            let mut pool = self.pools.read((day, period));
            pool.total_staked += stake_amount;
            pool.user_count += 1;
            self.pools.write((day, period), pool);

            // Increment the lock ID counter for the next lock
            self.lock_id.write(lock_id + 1);

            // transfer stake amount from user to contract
            let token_dispatcher = IERC20Dispatcher { contract_address: self.token.read() };

            let success: bool = token_dispatcher
                .transfer_from(user, get_contract_address(), stake_amount);
            assert(success, PhoneLockContractErrors::TRANSFER_FAILED);

            self
                .emit(
                    Event::PhoneLockSet(
                        PhoneLockSet {
                            user: user,
                            lock_id: lock_id,
                            start_time: start_time, 
                            duration: duration,
                            stake_amount: stake_amount,
                        },
                    ),
                );
            self.reentrancy_guard.end();
        }

        fn claim_lock_rewards(
            ref self: ContractState,
            lock_id: u64,
            completion_status: bool, // true = completed successfully, false = failed/exited
            signature: (felt252, felt252), // STARK signature (r, s)
            reward_amount: u256,
            merkle_proof: Array<felt252>,
        ) {
            self.reentrancy_guard.start();

            let claimer = get_caller_address();
            let lock = self.user_locks.read((claimer, lock_id));


            // Perform initial checks 
            self._validate_claim_preconditions(lock, claimer);

            // Verify the outcome signature from the backend
            let (signature_r, signature_s) = signature;
            self._verify_outcome_signature(lock.start_time, lock.duration, completion_status, signature_r, signature_s);

            // Calculate how much of the original stake should be returned based on completion status
            let amount_to_return: u256 = if completion_status {lock.stake_amount} else {0};

            // Verify the reward claim if the user was a winner (completed successfully)
            if (completion_status) {
                self._verify_reward_claim(lock.day, lock.period, reward_amount, merkle_proof);
            } else {
                assert(reward_amount == 0, PhoneLockContractErrors::MUST_BE_WINNER_TO_CLAIM_REWARD);
            }

            // Mark the user as having claimed rewards for this lock
            self.user_has_claimed_rewards.write((claimer, lock_id), true);

            // Update lock status to Completed
            let mut updated_lock = lock;
            updated_lock.status = PhoneLockStatus::Completed;
            self.user_locks.write((claimer, lock_id), updated_lock);

            let total_payout: u256 = amount_to_return + reward_amount;
            if (total_payout > 0) {
                // Transfer the total payout to the claimer
                let token_dispatcher = IERC20Dispatcher { contract_address: self.token.read() };
                let success: bool = token_dispatcher.transfer(claimer, total_payout);
                assert(success, PhoneLockContractErrors::TRANSFER_FAILED);
            }
            
            self
                .emit(
                    Event::WinningsClaimed(
                        WinningsClaimed {
                            user: claimer,
                            lock_id: lock_id,
                            completion_status: completion_status,
                            winnings_amount: total_payout,
                        },
                    ),
                );
            self.reentrancy_guard.end();
        }

        fn set_verified_signer(ref self: ContractState, new_signer: felt252) {
            self.reentrancy_guard.start();
            self.ownable.assert_only_owner();
            assert(!new_signer.is_zero(), PhoneLockContractErrors::INVALID_PUBLIC_KEY);
            self.verified_signer.write(new_signer);
            self.emit(Event::VerifiedSignerSet(VerifiedSignerSet { verified_signer: new_signer }));
            self.reentrancy_guard.end();
        }

        fn set_reward_merkle_root(
            ref self: ContractState, day: u64, period: u8, reward_merkle_root: felt252, new_rewards: u256, protocol_fees: u256,
        ) {
            self.reentrancy_guard.start();
            self.ownable.assert_only_owner();
            // Ensure period is valid (0-3 for 6-hour pools)
            assert(period >= 0 && period <= 3, PhoneLockContractErrors::INVALID_POOL);

            // Ensure merkle root is not zero
            assert(reward_merkle_root != 0, PhoneLockContractErrors::INVALID_MERKLE_ROOT);

            // Get existing pool data to preserve total_staked and user_count
            let existing_pool = self.pools.read((day, period));
            
            // Check if pool is already finalized
            assert(!existing_pool.is_finalized, PhoneLockContractErrors::POOL_IS_FINALIZED);

            // Add 10% protocol fees from the total pool rewards 
            self.protocol_fees.write(self.protocol_fees.read() + protocol_fees);

            self
                .pools
                .write(
                    (day, period),
                    Pool {
                        user_count: existing_pool.user_count,
                        total_staked: existing_pool.total_staked,
                        reward_merkle_root: reward_merkle_root,
                        is_finalized: true, // Set the pool as finalized
                        pool_reward: new_rewards, // Set the pool reward
                    },
                );
            self.emit(Event::ProtocolFeeUpdated(ProtocolFeeUpdated { protocol_fees: self.protocol_fees.read() }));
            self.emit(Event::PoolIsFinalized(PoolIsFinalized { day: day, period: period }));
            self.emit(Event::MerkleRootSetForPool(MerkleRootSetForPool { merkle_root: reward_merkle_root, day: day, period: period }));
            self.reentrancy_guard.end();
        }

        fn withdraw_protocol_fees(ref self: ContractState) {
            self.reentrancy_guard.start();
            self.ownable.assert_only_owner();
            
            let accumulated_fees = self.protocol_fees.read();
            assert(accumulated_fees > 0, 'No fees to withdraw');
            
            // Reset the counter
            self.protocol_fees.write(0);
            
            // Transfer to protocol fees address
            let token_dispatcher = IERC20Dispatcher { contract_address: self.token.read() };
            let fees_addr = self.protocol_fees_address.read();
            let success: bool = token_dispatcher.transfer(fees_addr, accumulated_fees);
            assert(success, PhoneLockContractErrors::PROTOCOL_FEE_TRANSFER_FAILED);
            
            self.emit(Event::ProtocolFeeUpdated(ProtocolFeeUpdated { protocol_fees: self.protocol_fees.read() }));
            self.emit(Event::ProtocolFeesWithdrawn(ProtocolFeesWithdrawn { amount: accumulated_fees, recipient: fees_addr }));
            self.reentrancy_guard.end();
        }

        fn get_pool_info(self: @ContractState, day: u64, period: u8) -> (felt252, bool, u256, u64, u256) {
            assert(period >= 0 && period <= 3, PhoneLockContractErrors::INVALID_POOL);

            let pool = self.pools.read((day, period));

            (pool.reward_merkle_root, pool.is_finalized, pool.total_staked, pool.user_count, pool.pool_reward)
        }

        fn get_user_lock(
            self: @ContractState, user: ContractAddress, lock_id: u64,
        ) -> (u256, u64, u64, u64, felt252) {
            assert(!user.is_zero(), PhoneLockContractErrors::ZERO_ADDRESS);

            let lock = self.user_locks.read((user, lock_id));
            let lock_status: felt252 = match lock.status {
                PhoneLockStatus::Inactive => 'Inactive',
                PhoneLockStatus::Active => 'Active',
                PhoneLockStatus::Completed => 'Completed',
            };

            (lock.stake_amount, lock.start_time, lock.duration, lock.end_time, lock_status)
        }

        fn get_has_claimed_rewards(
            self: @ContractState, user: ContractAddress, lock_id: u64,
        ) -> bool {
            self.user_has_claimed_rewards.read((user, lock_id))
        }

        fn get_owner(self: @ContractState) -> ContractAddress {
            self.ownable.owner()
        }

        fn get_verified_signer(self: @ContractState) -> felt252 {
            self.verified_signer.read()
        }

        fn get_merkle_root(self: @ContractState, day: u64, period: u8) -> felt252 {
            assert(period >= 0 && period <= 3, PhoneLockContractErrors::INVALID_POOL);
            self.pools.read((day, period)).reward_merkle_root
        }

        fn get_minimum_stake_amount(self: @ContractState) -> u256 {
            MINIMUM_STAKE_AMOUNT_IN_USD
        }

        fn get_next_lock_id(self: @ContractState) -> u64 {
            self.lock_id.read()
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn _stake_amount_is_valid(self: @ContractState, stake_amount: u256) {
            assert(stake_amount > 0, PhoneLockContractErrors::INVALID_STAKE_AMOUNT);
            
            // Check if stake amount meets the minimum USD requirement
            let usd_value: u256 = self._get_strk_usd_value(stake_amount);
            assert(
                usd_value >= MINIMUM_STAKE_AMOUNT_IN_USD, PhoneLockContractErrors::LESS_THAN_MINIMUM_USD,
            );
        }

        fn _duration_is_valid(self: @ContractState, duration: u64) {
            assert(duration >= MIN_DURATION, PhoneLockContractErrors::INVALID_DURATION);
            assert(duration <= MAX_DURATION, PhoneLockContractErrors::INVALID_DURATION);
        }

        fn _start_time_is_valid(self: @ContractState, start_time: u64) {
            assert(start_time >= get_block_timestamp(), PhoneLockContractErrors::INVALID_START_TIME);
        }

        fn _calculate_day_and_period(self: @ContractState, start_time: u64) -> (u64, u8) {
            let day: u64 = (start_time / ONE_DAY_IN_SECONDS);
            let period_in_u64: u64 = ((start_time % ONE_DAY_IN_SECONDS) / SIX_HOURS_IN_SECONDS);
            let period: u8 = period_in_u64.try_into().unwrap();
            (day, period)
        }

        fn _get_strk_usd_value(self: @ContractState, stake_amount: u256) -> u256 {
            let price_converter = IPriceConverterDispatcher {
                contract_address: self.price_converter.read(),
            };

            // Get STRK/USD price and its decimals
            let (strk_usd_price, decimals) = price_converter.get_strk_usd_price();
            let price_u256: u256 = strk_usd_price.into();
            assert(price_u256 > 0, 'Price must be positive');

            let price_divisor = _pow_10(decimals.into()); // 10^8 
            assert(price_divisor > 0, 'Price divisor cannot be zero');

            // The Pragma Oracle provides price with 8 decimals -> price * 10^8
            // The staked amount (STRK token) has 18 decimals
            // We need to convert the USD value to have 18 decimals for consistency

            // Calculation -> (STRK_amount_18_decimals * USD_price_8_decimals) / 10^8 = USD_value_18_decimals
            let usd_value: u256 = (stake_amount * price_u256) / (price_divisor);

            // Return the USD value with 18 decimals
            (usd_value)
        }


        fn _validate_claim_preconditions(
            ref self: ContractState, lock: PhoneLock, claimer: ContractAddress) {
            // Checks for user to be able to claim winnings
            //   -> The user should be the lock OWNER
            //   -> The lock is Active/Not Inactive
            //   -> The end time has been reached
            //   -> The pool is Finalised
            //   -> The user has not yet claimed

            assert(lock.user == claimer, PhoneLockContractErrors::NOT_LOCK_OWNER);
            assert(lock.status != PhoneLockStatus::Inactive, PhoneLockContractErrors::LOCK_NOT_FOUND);
            assert(lock.status == PhoneLockStatus::Active, PhoneLockContractErrors::LOCK_NOT_ACTIVE);
                        
            assert(get_block_timestamp() >= lock.end_time, PhoneLockContractErrors::LOCK_TIME_NOT_REACHED);
            
            assert(self.pools.read((lock.day, lock.period)).is_finalized, PhoneLockContractErrors::POOL_NOT_FINALIZED);
            assert(!self.user_has_claimed_rewards.read((claimer, lock.lock_id)), PhoneLockContractErrors::LOCK_ALREADY_CLAIMED,);
        }

        fn _verify_outcome_signature(
            ref self: ContractState,
            start_time: u64,
            duration: u64,
            completion_status: bool,
            signature_r: felt252,
            signature_s: felt252,
        ) {
            let caller = get_caller_address();
            let verified_signer = self.verified_signer.read();

            // Input validation
            assert(!verified_signer.is_zero(), PhoneLockContractErrors::INVALID_PUBLIC_KEY);
            assert(signature_r != 0, PhoneLockContractErrors::INVALID_SIGNATURE);
            assert(signature_s != 0, PhoneLockContractErrors::INVALID_SIGNATURE);

            // Create message hash using Poseidon (STARK-native hashing)
            // Message Hash: [caller, start_time, duration, completion_status]
            let mut message_data = ArrayTrait::new();
            message_data.append(caller.into());
            message_data.append(start_time.into());
            message_data.append(duration.into());
            message_data.append(completion_status.into());

            let message_hash = poseidon_hash_span(message_data.span());

            // Verify STARK curve signature
            let is_valid = check_ecdsa_signature(
                message_hash,
                verified_signer, // Public key 
                signature_r,
                signature_s,
            );

            assert(is_valid, PhoneLockContractErrors::INVALID_SIGNATURE);
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
            assert(is_valid, PhoneLockContractErrors::INVALID_PROOF);
        }
    }
}