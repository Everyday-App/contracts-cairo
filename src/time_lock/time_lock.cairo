use starknet::ContractAddress;

#[starknet::interface]
pub trait ITimeLockContract<TContractState> {
    fn set_phone_lock(
        ref self: TContractState,
        start_time: u64,
        duration: u64,
        stake_amount: u256,
    );
    fn claim_lock_rewards(
        ref self: TContractState,
        start_time: u64,
        duration: u64,
        completion_status: bool, // true = completed successfully, false = failed/exited
        signature: (felt252, felt252), // STARK signature (r, s)
        reward_amount: u256,
        merkle_proof: Array<felt252>,
    );
    fn set_verified_signer(ref self: TContractState, new_signer: felt252);
    fn set_reward_merkle_root(
        ref self: TContractState, day: u64, period: u8, reward_merkle_root: felt252,
    );
    fn get_pool_info(self: @TContractState, day: u64, period: u8) -> (felt252, bool, u256, u64);
    fn get_user_lock(
        self: @TContractState, user: ContractAddress, day: u64, period: u8,
    ) -> (u256, u64, u64, u64, felt252);
    fn get_has_claimed_rewards(
        self: @TContractState, user: ContractAddress, day: u64, period: u8,
    ) -> bool;
    fn get_owner(self: @TContractState) -> starknet::ContractAddress;
    fn get_verified_signer(self: @TContractState) -> felt252;
    fn get_merkle_root(self: @TContractState, day: u64, period: u8) -> felt252;
    fn get_minimum_stake_amount(self: @TContractState) -> u256;
}

mod TimeLockContractErrors {
    pub const ZERO_ADDRESS: felt252 = 'Zero_Address';
    pub const LOCK_ALREADY_EXISTS_IN_POOL: felt252 = 'Lock_Already_Exists_In_Pool';
    pub const INVALID_STAKE_AMOUNT: felt252 = 'Invalid_Stake_Amount';
    pub const INVALID_START_TIME: felt252 = 'Invalid_Start_Time';
    pub const INVALID_DURATION: felt252 = 'Invalid_Duration';
    pub const LOCK_TIME_NOT_REACHED: felt252 = 'Lock_Time_Not_Reached';
    pub const INVALID_PUBLIC_KEY: felt252 = 'Invalid_Public_Key';
    pub const INVALID_POOL: felt252 = 'Invalid_Pool';
    pub const INVALID_MERKLE_ROOT: felt252 = 'Invalid_Merkle_Root';
    pub const INVALID_SIGNATURE: felt252 = 'Invalid_Signature';
    pub const INVALID_PROOF: felt252 = 'Invalid_Proof';
    pub const TRANSFER_FAILED: felt252 = 'Transfer_Failed';
    pub const LOCK_NOT_ACTIVE: felt252 = 'Lock_Not_Active';
    pub const POOL_NOT_FINALIZED: felt252 = 'Pool_Not_Finalized';
    pub const ALREADY_CLAIMED: felt252 = 'Already_Claimed';
    pub const MUST_BE_WINNER_TO_CLAIM_REWARD: felt252 = 'Must_Be_Winner_To_Claim_Reward';
    pub const NOT_LOCK_OWNER: felt252 = 'Not_Lock_Owner';
}

#[starknet::contract]
pub mod TimeLockContract {
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
    use super::TimeLockContractErrors;
    use everydayapp::price_converter::price_converter::{
        IPriceConverterDispatcher, IPriceConverterDispatcherTrait, _pow_10,
    };

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(
        path: ReentrancyGuardComponent, storage: reentrancy_guard, event: ReentrancyGuardEvent,
    );

    // Time constants (same as alarm contract)
    const ONE_DAY_IN_SECONDS: u64 = 86400; // 24 * 60 * 60
    const TWELVE_HOURS_IN_SECONDS: u64 = 43200; // 12 * 60 * 60
    
    // Minimum and maximum duration constraints
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
    pub enum LockStatus {
        #[default]
        Inactive,
        Active,
        Completed,
    }

    #[derive(Copy, Drop, starknet::Store, Serde)]
    pub struct Pool {
        pub reward_merkle_root: felt252, // Merkle root for the reward distribution
        pub is_finalized: bool, // Indicates if the pool is finalized
        pub total_staked: u256, // Total amount staked in this pool
        pub user_count: u64, // Number of users who have set locks in this pool
    }

    #[derive(Copy, Drop, starknet::Store, Serde)]
    pub struct PhoneLock {
        pub user: ContractAddress, // Address of the user who set the lock
        pub stake_amount: u256, // Amount staked by the user
        pub start_time: u64, // When lock begins
        pub duration: u64, // Lock duration in seconds
        pub end_time: u64, // start_time + duration
        pub status: LockStatus, // Status of the lock
    }

    #[storage]
    struct Storage {
        // Public key of the verified signer
        verified_signer: felt252,
        // Address of the ERC20 token used for staking
        token: ContractAddress,
        // Price converter contract address
        price_converter: ContractAddress,
        // Protocol fees address
        protocol_fees_address: ContractAddress,
        // Pool key: (day, period) - same as alarm contract
        pools: Map<(u64, u8), Pool>,
        // User -> Day -> Period -> Lock (same as alarm's user_alarms)
        user_locks: Map<(ContractAddress, u64, u8), PhoneLock>,
        // User Address -> Day -> Period -> Claim status mapping
        user_has_claimed_rewards: Map<(ContractAddress, u64, u8), bool>,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        reentrancy_guard: ReentrancyGuardComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        PhoneLockSet: PhoneLockSet,
        LockRewardsClaimed: LockRewardsClaimed,
        MerkleRootSet: MerkleRootSet,
        VerifiedSignerSet: VerifiedSignerSet,
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
        pub start_time: u64,
        #[key]
        pub duration: u64,
        #[key]
        pub stake_amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct LockRewardsClaimed {
        #[key]
        pub user: starknet::ContractAddress,
        #[key]
        pub start_time: u64,
        #[key]
        pub duration: u64,
        #[key]
        pub completion_status: bool,
        #[key]
        pub rewards_amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct MerkleRootSet {
        #[key]
        pub merkle_root: felt252,
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

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress, // Address of the contract owner
        verified_signer: felt252, // Public key of the verified signer
        token: ContractAddress, // Address of the ERC20 token used for staking
        price_converter: ContractAddress, // Address of the price converter contract
        protocol_fees_address: ContractAddress, // Address that receives protocol fees
    ) {
        assert(!owner.is_zero(), TimeLockContractErrors::ZERO_ADDRESS);
        assert(!token.is_zero(), TimeLockContractErrors::ZERO_ADDRESS);
        assert(!verified_signer.is_zero(), TimeLockContractErrors::INVALID_PUBLIC_KEY);
        assert(!price_converter.is_zero(), TimeLockContractErrors::ZERO_ADDRESS);
        assert(!protocol_fees_address.is_zero(), TimeLockContractErrors::ZERO_ADDRESS);
        self.ownable.initializer(owner);
        self.verified_signer.write(verified_signer);
        self.token.write(token);
        self.price_converter.write(price_converter);
        self.protocol_fees_address.write(protocol_fees_address);
        self.emit(Event::VerifiedSignerSet(VerifiedSignerSet { verified_signer: verified_signer }));
    }

    #[abi(embed_v0)]
    impl TimeLockContract of super::ITimeLockContract<ContractState> {
        fn set_phone_lock(
            ref self: ContractState,
            start_time: u64,
            duration: u64,
            stake_amount: u256,
        ) {
            self.reentrancy_guard.start();
            assert(stake_amount > 0, TimeLockContractErrors::INVALID_STAKE_AMOUNT);
            assert(start_time > get_block_timestamp(), TimeLockContractErrors::INVALID_START_TIME);
            assert(duration >= MIN_DURATION, TimeLockContractErrors::INVALID_DURATION);
            assert(duration <= MAX_DURATION, TimeLockContractErrors::INVALID_DURATION);

            // Check if stake amount meets the minimum USD requirement
            let usd_value: u256 = self._get_strk_usd_value(stake_amount);
            assert(
                usd_value >= MINIMUM_STAKE_AMOUNT_IN_USD, TimeLockContractErrors::INVALID_STAKE_AMOUNT,
            );

            // Calculate day and period (same logic as alarm contract)
            let day: u64 = (start_time / ONE_DAY_IN_SECONDS);
            let period_in_u64: u64 = ((start_time % ONE_DAY_IN_SECONDS) / TWELVE_HOURS_IN_SECONDS);
            let period: u8 = period_in_u64.try_into().unwrap();

            // Calculate end time
            let end_time: u64 = start_time + duration;

            let user = get_caller_address();
            let existing_lock = self.user_locks.read((user, day, period));

            // Check if the lock already exists for the user in this pool (same as alarm logic)
            assert(
                existing_lock.status == LockStatus::Inactive, TimeLockContractErrors::LOCK_ALREADY_EXISTS_IN_POOL);

            // Create a new phone lock
            let new_phone_lock = PhoneLock {
                user: user,
                stake_amount: stake_amount,
                start_time: start_time,
                duration: duration,
                end_time: end_time,
                status: LockStatus::Active,
            };

            // Store the new lock in the user_locks mapping
            self.user_locks.write((user, day, period), new_phone_lock);

            // Update staked amount & user count in the pool (same as alarm logic)
            let mut pool = self.pools.read((day, period));
            pool.total_staked += stake_amount;
            pool.user_count += 1;
            self.pools.write((day, period), pool);

            // transfer stake amount from user to contract
            let token_dispatcher = IERC20Dispatcher { contract_address: self.token.read() };

            let success: bool = token_dispatcher
                .transfer_from(user, get_contract_address(), stake_amount);
            assert(success, TimeLockContractErrors::TRANSFER_FAILED);

            self
                .emit(
                    Event::PhoneLockSet(
                        PhoneLockSet {
                            user: user, 
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
            start_time: u64,
            duration: u64,
            completion_status: bool, // true = completed successfully, false = failed/exited
            signature: (felt252, felt252), // STARK signature (r, s)
            reward_amount: u256,
            merkle_proof: Array<felt252>,
        ) {
            self.reentrancy_guard.start();

            // Calculate day and period (same logic as alarm contract)
            let day: u64 = (start_time / ONE_DAY_IN_SECONDS);
            let period_in_u64: u64 = ((start_time % ONE_DAY_IN_SECONDS) / TWELVE_HOURS_IN_SECONDS);
            let period: u8 = period_in_u64.try_into().unwrap();

            let claimer = get_caller_address();
            let lock = self.user_locks.read((claimer, day, period));

            // Only the lock owner can claim their own rewards
            assert(lock.user == claimer, TimeLockContractErrors::NOT_LOCK_OWNER);
            // Check if lock time has been reached (current time >= start_time + duration)
            assert(get_block_timestamp() >= lock.end_time, TimeLockContractErrors::LOCK_TIME_NOT_REACHED);

            // Perform initial checks (same as alarm logic)
            self._validate_claim_preconditions(lock, day, period);

            // Verify the outcome signature from the backend
            let (signature_r, signature_s) = signature;
            self._verify_outcome_signature(start_time, duration, completion_status, signature_r, signature_s);

            // Calculate how much of the original stake should be returned based on completion status
            // Same as alarm's _calculate_stake_return function
            let amount_to_return: u256 = if completion_status {
                // Completed successfully - return full stake (like snooze_count = 0 in alarm)
                lock.stake_amount
            } else {
                // Failed/exited - return 0 (like snooze_count > 0 in alarm)
                0
            };

            // Verify the reward claim if the user was a winner (completed successfully)
            if (completion_status) {
                self._verify_reward_claim(day, period, reward_amount, merkle_proof);
            } else {
                assert(reward_amount == 0, TimeLockContractErrors::MUST_BE_WINNER_TO_CLAIM_REWARD);
            }

            // Mark the user as having claimed rewards for this lock
            self.user_has_claimed_rewards.write((claimer, day, period), true);

            // Update lock status to Completed
            let mut updated_lock = lock;
            updated_lock.status = LockStatus::Completed;
            self.user_locks.write((claimer, day, period), updated_lock);

            let total_payout: u256 = amount_to_return + reward_amount;
            if (total_payout > 0) {
                // Transfer the total payout to the claimer
                let token_dispatcher = IERC20Dispatcher { contract_address: self.token.read() };
                let success: bool = token_dispatcher.transfer(claimer, total_payout);
                assert(success, TimeLockContractErrors::TRANSFER_FAILED);
            }
            
            self
                .emit(
                    Event::LockRewardsClaimed(
                        LockRewardsClaimed {
                            user: claimer,
                            start_time: start_time,
                            duration: duration,
                            completion_status: completion_status,
                            rewards_amount: total_payout,
                        },
                    ),
                );
            self.reentrancy_guard.end();
        }

        fn set_verified_signer(ref self: ContractState, new_signer: felt252) {
            self.ownable.assert_only_owner();
            assert(!new_signer.is_zero(), TimeLockContractErrors::INVALID_PUBLIC_KEY);
            self.verified_signer.write(new_signer);
            self.emit(Event::VerifiedSignerSet(VerifiedSignerSet { verified_signer: new_signer }));
        }

        fn set_reward_merkle_root(
            ref self: ContractState, day: u64, period: u8, reward_merkle_root: felt252,
        ) {
            self.ownable.assert_only_owner();
            // Ensure period is either AM (0) or PM (1) - same as alarm contract
            assert(period == 0 || period == 1, TimeLockContractErrors::INVALID_POOL);

            // Ensure merkle root is not zero
            assert(reward_merkle_root != 0, TimeLockContractErrors::INVALID_MERKLE_ROOT);

            // Get existing pool data to preserve total_staked and user_count
            let existing_pool = self.pools.read((day, period));

            self
                .pools
                .write(
                    (day, period),
                    Pool {
                        reward_merkle_root: reward_merkle_root,
                        is_finalized: true, // Set the pool as finalized
                        total_staked: existing_pool.total_staked,
                        user_count: existing_pool.user_count,
                    },
                );

            self.emit(Event::MerkleRootSet(MerkleRootSet { 
                merkle_root: reward_merkle_root, 
                day: day, 
                period: period 
            }));
        }

        fn get_pool_info(self: @ContractState, day: u64, period: u8) -> (felt252, bool, u256, u64) {
            assert(period == 0 || period == 1, TimeLockContractErrors::INVALID_POOL);

            let pool = self.pools.read((day, period));

            (pool.reward_merkle_root, pool.is_finalized, pool.total_staked, pool.user_count)
        }

        fn get_user_lock(
            self: @ContractState, user: ContractAddress, day: u64, period: u8,
        ) -> (u256, u64, u64, u64, felt252) {
            assert(!user.is_zero(), TimeLockContractErrors::ZERO_ADDRESS);
            assert(period == 0 || period == 1, TimeLockContractErrors::INVALID_POOL);

            let lock = self.user_locks.read((user, day, period));
            let lock_status: felt252 = match lock.status {
                LockStatus::Inactive => 'Inactive',
                LockStatus::Active => 'Active',
                LockStatus::Completed => 'Completed',
            };

            (lock.stake_amount, lock.start_time, lock.duration, lock.end_time, lock_status)
        }

        fn get_has_claimed_rewards(
            self: @ContractState, user: ContractAddress, day: u64, period: u8,
        ) -> bool {
            assert(period == 0 || period == 1, TimeLockContractErrors::INVALID_POOL);
            self.user_has_claimed_rewards.read((user, day, period))
        }

        fn get_owner(self: @ContractState) -> ContractAddress {
            self.ownable.owner()
        }

        fn get_verified_signer(self: @ContractState) -> felt252 {
            self.verified_signer.read()
        }

        fn get_merkle_root(self: @ContractState, day: u64, period: u8) -> felt252 {
            assert(period == 0 || period == 1, TimeLockContractErrors::INVALID_POOL);
            self.pools.read((day, period)).reward_merkle_root
        }

        fn get_minimum_stake_amount(self: @ContractState) -> u256 {
            MINIMUM_STAKE_AMOUNT_IN_USD
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
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
            ref self: ContractState, lock: PhoneLock, day: u64, period: u8,
        ) {
            assert(lock.status == LockStatus::Active, TimeLockContractErrors::LOCK_NOT_ACTIVE);
            assert(
                self.pools.read((day, period)).is_finalized,
                TimeLockContractErrors::POOL_NOT_FINALIZED,
            );
            assert(
                !self.user_has_claimed_rewards.read((get_caller_address(), day, period)),
                TimeLockContractErrors::ALREADY_CLAIMED,
            );
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
            assert(!verified_signer.is_zero(), TimeLockContractErrors::INVALID_PUBLIC_KEY);
            assert(signature_r != 0, TimeLockContractErrors::INVALID_SIGNATURE);
            assert(signature_s != 0, TimeLockContractErrors::INVALID_SIGNATURE);

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

            assert(is_valid, TimeLockContractErrors::INVALID_SIGNATURE);
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
            assert(is_valid, TimeLockContractErrors::INVALID_PROOF);
        }
    }
}