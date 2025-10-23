use starknet::ContractAddress;

#[starknet::interface]
pub trait IAlarmContract<TContractState> {
    fn set_alarm(ref self: TContractState, wakeup_time: u64, stake_amount: u256);
    fn edit_alarm(
        ref self: TContractState,
        alarm_id: u64,
        new_wakeup_time: u64,
        new_stake_amount: u256,
    );
    fn delete_alarm(ref self: TContractState, alarm_id: u64);
    fn claim_winnings(
        ref self: TContractState,
        alarm_id: u64,
        snooze_count: u8,
        signature: (felt252, felt252), // STARK signature (r, s)
        reward_amount: u256,
        merkle_proof: Array<felt252>,
    );

    fn set_verified_signer(ref self: TContractState, new_signer: felt252);
    fn set_merkle_root_for_pool(
        ref self: TContractState, day: u64, period: u8, merkle_root: felt252, new_rewards: u256, protocol_fees: u256,
    );
    fn withdraw_protocol_fees(ref self: TContractState);
    
    fn get_pool_info(self: @TContractState, day: u64, period: u8) -> (felt252, bool, u256, u64, u256);
    fn get_alarm(self: @TContractState, user: ContractAddress, alarm_id: u64) -> (u256, u64, u8, u64, felt252);
    fn get_has_claimed_winnings(self: @TContractState, user: ContractAddress, alarm_id: u64) -> bool;
    fn get_has_alarm_in_pool(self: @TContractState, user: ContractAddress, day: u64, period: u8) -> bool;
    fn get_owner(self: @TContractState) -> starknet::ContractAddress;
    fn get_verified_signer(self: @TContractState) -> felt252;
    fn get_merkle_root_for_pool(self: @TContractState, day: u64, period: u8) -> felt252;
    fn get_minimum_stake_amount(self: @TContractState) -> u256;
    fn get_next_alarm_id(self: @TContractState) -> u64;
}

mod AlarmContractErrors {
    pub const ZERO_ADDRESS: felt252 = 'Zero_Address';
    pub const INVALID_STAKE_AMOUNT: felt252 = 'Invalid_Stake_Amount';
    pub const LESS_THAN_MINIMUM_USD: felt252 = 'Less_Than_Minimum_USD';
    
    pub const INVALID_WAKEUP_TIME: felt252 = 'Invalid_WakeUp_Time';
    pub const WAKEUP_TIME_NOT_REACHED: felt252 = 'WakeUp_Time_Not_Reached'; 
    
    pub const INVALID_POOL: felt252 = 'Invalid_Pool';
    pub const POOL_NOT_FINALIZED: felt252 = 'Pool_Not_Finalized';
    pub const POOL_IS_FINALIZED: felt252 = 'Pool_Is_Finalized';

    pub const INVALID_PUBLIC_KEY: felt252 = 'Invalid_Public_Key';
    pub const INVALID_MERKLE_ROOT: felt252 = 'Invalid_Merkle_Root';
    pub const INVALID_SIGNATURE: felt252 = 'Invalid_Signature';
    pub const INVALID_PROOF: felt252 = 'Invalid_Proof';

    pub const STAKE_TRANSFER_FAILED: felt252 = 'Stake_Transfer_Failed';
    pub const PROTOCOL_FEE_TRANSFER_FAILED: felt252 = 'Protocol_Fee_Transfer_Failed';
    pub const PAYOUT_TRANSFER_FAILED: felt252 = 'Payout_Transfer_Failed';
    pub const INSUFFICIENT_POOL_REWARDS: felt252 = 'Insufficient_Pool_Rewards';
    
    pub const ALARM_NOT_ACTIVE: felt252 = 'Alarm_Not_Active';
    pub const ALARM_NOT_FOUND: felt252 = 'Alarm_Not_Found';
    pub const ALARM_HAS_BEEN_DELETED: felt252 = 'Alarm_Has_Been_Deleted';
    pub const ALARM_ALREADY_CLAIMED: felt252 = 'Alarm_Already_Claimed';
    pub const ALARM_ALREADY_EXISTS_IN_POOL: felt252 = 'Alarm_Already_Exists_In_Pool';
    pub const NOT_ALARM_OWNER: felt252 = 'Not_Alarm_Owner';
    pub const MUST_BE_WINNER_TO_CLAIM_REWARD: felt252 = 'Must_Be_Winner_To_Claim_Reward';

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
    const SLASH_20: u256 = 20;
    const SLASH_50: u256 = 50;
    const PROTOCOL_FEE_PERCENT: u256 = 10;
    const PERCENT_BASE: u256 = 100;

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
        Completed,
        Deleted
    }

#[derive(Copy, Drop, starknet::Store, Serde)]
pub struct Pool {        
    pub user_count: u64, // Number of users who have set alarms in this pool
    pub total_staked: u256, // Total amount staked in this pool
    pub merkle_root: felt252, // Merkle root for the reward distribution
    pub is_finalized: bool, // Indicates if the pool is finalized
    pub pool_reward: u256, // Total rewards available for this pool's winners
}

    #[derive(Copy, Drop, starknet::Store, Serde)]
    pub struct Alarm {
        pub user: ContractAddress, // Address of the user who set the alarm
        pub period: u8, // AM (0) or PM (1)
        pub day: u64, // Day calculated from wakeup_time
        pub stake_amount: u256, // Amount staked by the user
        pub wakeup_time: u64, // Time when the alarm should trigger
        pub alarm_id: u64, // Unique identifier for the alarm
        pub status: Status // Status of the alarm     
    }

    #[storage]
    struct Storage {
        
        verified_signer: felt252, // Verified signer public key
        token: ContractAddress, // Address of the ERC20 token used for staking
        price_converter: ContractAddress, // Price converter contract address
        protocol_fees_address: ContractAddress,
        protocol_fees: u256, 
        alarm_id: u64, 
        
        pools: Map<(u64, u8), Pool>, // Day -> Period(AM/PM) -> Pool mapping
        
        user_alarms: Map<(ContractAddress, u64), Alarm>, // User Address -> Alarm ID -> Alarm mapping

        user_has_alarm_in_pool: Map<(ContractAddress, u64, u8), bool>, // User Address -> Day -> Period(AM/PM) -> true/false if user has an alarm in this pool

        user_has_claimed_winnings: Map<(ContractAddress, u64), bool>, // User Address -> Alarm ID -> Claim status mapping
                
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        reentrancy_guard: ReentrancyGuardComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        AlarmSet: AlarmSet,
        AlarmEdited: AlarmEdited,
        AlarmDeleted: AlarmDeleted,
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
    pub struct AlarmSet {
        #[key]
        pub user: starknet::ContractAddress,
        #[key]
        pub alarm_id: u64,
        #[key]
        pub wakeup_time: u64,
        #[key]
        pub stake_amount: u256,
    }
    
    #[derive(Drop, starknet::Event)]
    pub struct AlarmEdited {
        #[key]
        pub user: starknet::ContractAddress,
        #[key]
        pub alarm_id: u64,
        #[key]
        pub new_wakeup_time: u64,
        #[key]
        pub new_stake_amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct AlarmDeleted {
        #[key]
        pub user: starknet::ContractAddress,
        #[key]
        pub alarm_id: u64,
        #[key]
        pub wakeup_time: u64,
        #[key]
        pub refunded_stake_amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct WinningsClaimed {
        #[key]
        pub user: starknet::ContractAddress,
        #[key]
        pub alarm_id: u64,
        #[key]
        pub snooze_count: u8,
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
        assert(!owner.is_zero(), AlarmContractErrors::ZERO_ADDRESS);
        assert(!token.is_zero(), AlarmContractErrors::ZERO_ADDRESS);
        assert(!verified_signer.is_zero(), AlarmContractErrors::INVALID_PUBLIC_KEY);
        assert(!price_converter.is_zero(), AlarmContractErrors::ZERO_ADDRESS);
        assert(!protocol_fees_address.is_zero(), AlarmContractErrors::ZERO_ADDRESS);

        self.ownable.initializer(owner);
        self.verified_signer.write(verified_signer);
        self.token.write(token);
        self.price_converter.write(price_converter);
        self.protocol_fees_address.write(protocol_fees_address);
        self.alarm_id.write(1); // Reserve 0 for NO ALARM
        self.protocol_fees.write(0); 

        self.emit(Event::VerifiedSignerSet(VerifiedSignerSet { verified_signer: verified_signer }));
    }

    #[abi(embed_v0)]
    impl AlarmContract of super::IAlarmContract<ContractState> {
        fn set_alarm(ref self: ContractState, wakeup_time: u64, stake_amount: u256) {
            self.reentrancy_guard.start();

            // Check if stake amount is greater than 0 and greater than minimum stake amount in USD
            self._stake_amount_is_valid(stake_amount);

            // Check if the wakeup time is in the future
            self._wakeup_time_is_valid(wakeup_time);

            let (day, period) = self._calculate_day_and_period(wakeup_time);

            let user = get_caller_address();
            
            // Check if the user already has an alarm in this pool
            let has_alarm_in_pool = self.user_has_alarm_in_pool.read((user, day, period));
            assert(!has_alarm_in_pool, AlarmContractErrors::ALARM_ALREADY_EXISTS_IN_POOL);

            // Check if the pool is already finalized
            let pool = self.pools.read((day, period));
            assert(!pool.is_finalized, AlarmContractErrors::POOL_NOT_FINALIZED);

            // Get current alarm ID
            let alarm_id = self.alarm_id.read();
            
            // Create a new alarm
            let new_user_alarm = Alarm {
                user: user,
                period: period,
                day: day,
                stake_amount: stake_amount,
                wakeup_time: wakeup_time,
                alarm_id: alarm_id,
                status: Status::Active,
            };

            // Store the new alarm in the user_alarms mapping
            self.user_alarms.write((user, alarm_id), new_user_alarm);
            
            // Mark that user has an alarm in this pool
            self.user_has_alarm_in_pool.write((user, day, period), true);

            // Update staked amount & user count in the pool 
            let mut pool = self.pools.read((day, period));
            pool.total_staked += stake_amount;
            pool.user_count += 1;
            self.pools.write((day, period), pool);

            // Increment the alarm ID counter for the next alarm
            self.alarm_id.write(alarm_id + 1);

            // Transfer stake amount from user to contract
            let token_dispatcher = IERC20Dispatcher { contract_address: self.token.read() };

            let success: bool = token_dispatcher
                .transfer_from(user, get_contract_address(), stake_amount);
            assert(success, AlarmContractErrors::STAKE_TRANSFER_FAILED);

            self
                .emit(
                    Event::AlarmSet(
                        AlarmSet {
                            user: user, 
                            alarm_id: alarm_id,
                            wakeup_time: wakeup_time, 
                            stake_amount: stake_amount,
                        },
                    ),
                );
            self.reentrancy_guard.end();
        }

        fn edit_alarm(
            ref self: ContractState,
            alarm_id: u64,
            new_wakeup_time: u64,
            new_stake_amount: u256,
        ) {
            self.reentrancy_guard.start();

            // Check if the new stake amount is greater than 0 and greater than minimum stake amount in USD
            self._stake_amount_is_valid(new_stake_amount);

            // Check if the new wakeup time is in the future
            self._wakeup_time_is_valid(new_wakeup_time);

            let user = get_caller_address();
            let mut alarm = self.user_alarms.read((user, alarm_id));

            // Perform checks
            self._validate_if_alarm_can_be_edited_or_deleted(alarm, user);

            let (old_day, old_period) = self._calculate_day_and_period(alarm.wakeup_time);
            let (new_day, new_period) = self._calculate_day_and_period(new_wakeup_time);

            let is_same_pool: bool = (old_day == new_day) && (old_period == new_period);
            let new_pool = if is_same_pool { self.pools.read((old_day, old_period)) } else { self.pools.read((new_day, new_period)) };
            
            if (!is_same_pool) {
                // Check if the user already has an alarm in the new pool
                let has_alarm_in_new_pool = self.user_has_alarm_in_pool.read((user, new_day, new_period));
                assert(!has_alarm_in_new_pool, AlarmContractErrors::ALARM_ALREADY_EXISTS_IN_POOL);
                assert(!new_pool.is_finalized, AlarmContractErrors::POOL_IS_FINALIZED);
            }

            // Calculate the 20% slash to existing stake & the return amount to user
            let old_stake = alarm.stake_amount;
            let slash_20: u256 = (old_stake * SLASH_20) / PERCENT_BASE;
            let return_80: u256 = old_stake - slash_20;
            
            // Allocate 90% of slash to pool rewards and 10% to protocol fees
            let protocol_fee_amount: u256 = (slash_20 * PROTOCOL_FEE_PERCENT) / PERCENT_BASE;
            let pool_reward_amount: u256 = slash_20 - protocol_fee_amount;
            
            // Add to pool rewards
            let (day, period) = self._calculate_day_and_period(alarm.wakeup_time);
            let mut pool = self.pools.read((day, period));
            pool.pool_reward += pool_reward_amount;
            self.pools.write((day, period), pool);
            
            // Add to protocol fees
            self.protocol_fees.write(self.protocol_fees.read() + protocol_fee_amount);

            if (is_same_pool) {
                self._edit_alarm_in_same_pool(alarm, new_wakeup_time, new_stake_amount);
            } else {
                self._edit_alarm_in_new_pool(alarm, new_day, new_period, new_wakeup_time, new_stake_amount);
            }
            
            let token_dispatcher = IERC20Dispatcher { contract_address: self.token.read() };

            // Refund remaining amount to user 
            let user_refund_success: bool = token_dispatcher.transfer(user, return_80);
            assert(user_refund_success, AlarmContractErrors::STAKE_TRANSFER_FAILED);

            // Transfer new stake amount from user to contract
            let new_stake_transfer_success: bool = token_dispatcher.transfer_from(user, get_contract_address(), new_stake_amount);
            assert(new_stake_transfer_success, AlarmContractErrors::STAKE_TRANSFER_FAILED);

            self.emit(Event::ProtocolFeeUpdated(ProtocolFeeUpdated { protocol_fees: self.protocol_fees.read() }));
            self.emit(Event::AlarmEdited(AlarmEdited { user: user, alarm_id: alarm_id, new_wakeup_time: new_wakeup_time, new_stake_amount: new_stake_amount }));
           
            self.reentrancy_guard.end();
        }

        fn delete_alarm(ref self: ContractState, alarm_id: u64) {
            self.reentrancy_guard.start();

            let user = get_caller_address();
            let mut alarm = self.user_alarms.read((user, alarm_id));
            
            // Perform checks
            self._validate_if_alarm_can_be_edited_or_deleted(alarm, user);

            let (day, period) = self._calculate_day_and_period(alarm.wakeup_time);

            // Apply 50% slash
            let stake = alarm.stake_amount;
            let slash_50: u256 = (stake * SLASH_50) / PERCENT_BASE;
            let return_50: u256 = stake - slash_50;

            // Allocate 90% of slash to pool rewards and 10% to protocol fees
            let protocol_fee_amount: u256 = (slash_50 * PROTOCOL_FEE_PERCENT) / PERCENT_BASE;
            let pool_reward_amount: u256 = slash_50 - protocol_fee_amount;
            
            // Add to protocol fees
            self.protocol_fees.write(self.protocol_fees.read() + protocol_fee_amount);

            // Update pool 
            let mut pool = self.pools.read((day, period));
            pool.pool_reward += pool_reward_amount;
            pool.total_staked -= stake;
            pool.user_count -= 1;
            self.pools.write((day, period), pool);
            
            // Mark that the user no longer has an alarm in the pool
            self.user_has_alarm_in_pool.write((user, day, period), false);

            // Mark alarm as Deleted and clear stake amount
            alarm.status = Status::Deleted;
            alarm.stake_amount = 0;
            self.user_alarms.write((user, alarm_id), alarm);

            let token_dispatcher = IERC20Dispatcher { contract_address: self.token.read() };
            
            // Refund remaining amount to user 
            let user_refund_success: bool = token_dispatcher.transfer(user, return_50);
            assert(user_refund_success, AlarmContractErrors::STAKE_TRANSFER_FAILED);

            self.emit(Event::ProtocolFeeUpdated(ProtocolFeeUpdated { protocol_fees: self.protocol_fees.read() }));
            self.emit(Event::AlarmDeleted(AlarmDeleted { user: user, alarm_id: alarm_id, wakeup_time: alarm.wakeup_time, refunded_stake_amount: return_50 }));
            self.reentrancy_guard.end();
        }

        fn claim_winnings(
            ref self: ContractState,
            alarm_id: u64,
            snooze_count: u8,
            signature: (felt252, felt252), // STARK signature (r, s)
            reward_amount: u256,
            merkle_proof: Array<felt252>,
        ) {
            self.reentrancy_guard.start();
            
            let claimer = get_caller_address();
            let alarm = self.user_alarms.read((claimer, alarm_id));
        
            // Perform initial checks
            self._validate_claim_preconditions(alarm, claimer);

            // Verify the outcome signature from the backend
            let (signature_r, signature_s) = signature;
            self._verify_outcome_signature(alarm.wakeup_time, snooze_count, signature_r, signature_s);

            // Calculate how much of the original stake should be returned based on snooze count
            let amount_to_return: u256 = InternalFunctionsTrait::_calculate_stake_return(
                alarm.stake_amount, snooze_count,
            );

            // Verify the reward claim if the user was a winner
            if (snooze_count == 0) {
                self._verify_reward_claim(alarm.day, alarm.period, reward_amount, merkle_proof);
                // Ensure the pool has enough rewards
                let pool = self.pools.read((alarm.day, alarm.period));
                assert(pool.pool_reward >= reward_amount, AlarmContractErrors::INSUFFICIENT_POOL_REWARDS);
                
                // Deduct the reward from the pool
                let mut updated_pool = pool;
                updated_pool.pool_reward -= reward_amount;
                self.pools.write((alarm.day, alarm.period), updated_pool);
            } else {
                assert(reward_amount == 0, AlarmContractErrors::MUST_BE_WINNER_TO_CLAIM_REWARD);
            }

            // Mark the user as having claimed winnings for this alarm ID
            self.user_has_claimed_winnings.write((claimer, alarm_id), true);

            // Update alarm status to Completed
            let mut updated_alarm = alarm;
            updated_alarm.status = Status::Completed;
            self.user_alarms.write((claimer, alarm_id), updated_alarm);

            let total_payout: u256 = amount_to_return + reward_amount;
            if (total_payout > 0) {
                // Transfer the total payout to the claimer
                let token_dispatcher = IERC20Dispatcher { contract_address: self.token.read() };
                let success: bool = token_dispatcher.transfer(claimer, total_payout);
                assert(success, AlarmContractErrors::PAYOUT_TRANSFER_FAILED);
            }
            self
                .emit(
                    Event::WinningsClaimed(
                        WinningsClaimed {
                            user: claimer,
                            alarm_id: alarm_id,
                            snooze_count: snooze_count,
                            winnings_amount: total_payout,
                        },
                    ),
                );
            self.reentrancy_guard.end();
        }

        fn set_verified_signer(ref self: ContractState, new_signer: felt252) {
            self.reentrancy_guard.start();
            self.ownable.assert_only_owner();
            assert(!new_signer.is_zero(), AlarmContractErrors::INVALID_PUBLIC_KEY);
            self.verified_signer.write(new_signer);
            self.emit(Event::VerifiedSignerSet(VerifiedSignerSet { verified_signer: new_signer }));
            self.reentrancy_guard.end();
        }

        fn set_merkle_root_for_pool(
            ref self: ContractState, day: u64, period: u8, merkle_root: felt252, new_rewards: u256, protocol_fees: u256,
        ) {
            self.reentrancy_guard.start();
            self.ownable.assert_only_owner();
            // Ensure period is either AM (0) or PM (1)
            assert(period == 0 || period == 1, AlarmContractErrors::INVALID_POOL);

            // Ensure merkle root is not zero
            assert(merkle_root != 0, AlarmContractErrors::INVALID_MERKLE_ROOT);

            // Get existing pool data to preserve total_staked, user_count and add to existing pool_reward
            let existing_pool = self.pools.read((day, period));
            
            // Add new rewards from losers to the existing pool_reward from edit/delete operations
            let total_pool_reward = existing_pool.pool_reward + new_rewards;
            
            // Add 10% protocol fees from the total pool rewards 
            self.protocol_fees.write(self.protocol_fees.read() + protocol_fees);

            self
                .pools
                .write(
                    (day, period),
                    Pool {
                        merkle_root: merkle_root,
                        is_finalized: true, // Set the pool as finalized
                        total_staked: existing_pool.total_staked,
                        user_count: existing_pool.user_count,
                        pool_reward: total_pool_reward, // Add new rewards to existing pool_reward
                    },
                );
            self.emit(Event::ProtocolFeeUpdated(ProtocolFeeUpdated { protocol_fees: self.protocol_fees.read() }));
            self.emit(Event::PoolIsFinalized(PoolIsFinalized { day: day, period: period }) );
            self.emit(Event::MerkleRootSetForPool(MerkleRootSetForPool { merkle_root: merkle_root, day: day, period: period }) );
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
            assert(success, AlarmContractErrors::PROTOCOL_FEE_TRANSFER_FAILED);

            self.emit(Event::ProtocolFeeUpdated(ProtocolFeeUpdated { protocol_fees: 0 }));
            self.emit(Event::ProtocolFeesWithdrawn(ProtocolFeesWithdrawn { amount: accumulated_fees, recipient: fees_addr }));
            self.reentrancy_guard.end();
        }

        fn get_pool_info(self: @ContractState, day: u64, period: u8) -> (felt252, bool, u256, u64, u256) {
            assert(period == 0 || period == 1, AlarmContractErrors::INVALID_POOL);

            let pool = self.pools.read((day, period));

            (pool.merkle_root, pool.is_finalized, pool.total_staked, pool.user_count, pool.pool_reward)
        }

        fn get_alarm(
            self: @ContractState, user: ContractAddress, alarm_id: u64,
        ) -> (u256, u64, u8, u64, felt252) {
            assert(!user.is_zero(), AlarmContractErrors::ZERO_ADDRESS);

            let alarm = self.user_alarms.read((user, alarm_id));
            let alarm_status: felt252 = match alarm.status {
                Status::Inactive => 'Inactive',
                Status::Active => 'Active',
                Status::Completed => 'Completed',
                Status::Deleted => 'Deleted',
            };

            // Return stake_amount, wakeup_time, period, day, status
            (alarm.stake_amount, alarm.wakeup_time, alarm.period, alarm.day, alarm_status)
        }

        fn get_has_claimed_winnings(
            self: @ContractState, user: ContractAddress, alarm_id: u64,
        ) -> bool {
            assert(!user.is_zero(), AlarmContractErrors::ZERO_ADDRESS);
            self.user_has_claimed_winnings.read((user, alarm_id))
        }
        
        fn get_has_alarm_in_pool(
            self: @ContractState, user: ContractAddress, day: u64, period: u8,
        ) -> bool {
            assert(!user.is_zero(), AlarmContractErrors::ZERO_ADDRESS);
            assert(period == 0 || period == 1, AlarmContractErrors::INVALID_POOL);
            self.user_has_alarm_in_pool.read((user, day, period))
        }

        fn get_owner(self: @ContractState) -> ContractAddress {
            self.ownable.owner()
        }

        fn get_verified_signer(self: @ContractState) -> felt252 {
            self.verified_signer.read()
        }

        fn get_merkle_root_for_pool(self: @ContractState, day: u64, period: u8) -> felt252 {
            assert(period == 0 || period == 1, AlarmContractErrors::INVALID_POOL);
            self.pools.read((day, period)).merkle_root
        }

        fn get_minimum_stake_amount(self: @ContractState) -> u256 {
            MINIMUM_STAKE_AMOUNT_IN_USD
        }
        
        fn get_next_alarm_id(self: @ContractState) -> u64 {
            self.alarm_id.read()
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn _stake_amount_is_valid(self: @ContractState, stake_amount: u256) {
            assert(stake_amount > 0, AlarmContractErrors::INVALID_STAKE_AMOUNT);
            let usd_value: u256 = self._get_strk_usd_value(stake_amount);
            assert(usd_value >= MINIMUM_STAKE_AMOUNT_IN_USD, AlarmContractErrors::LESS_THAN_MINIMUM_USD);
        }

        fn _wakeup_time_is_valid(self: @ContractState, wakeup_time: u64) {
            assert(wakeup_time > get_block_timestamp(), AlarmContractErrors::INVALID_WAKEUP_TIME);
        }

        fn _calculate_day_and_period(self: @ContractState, wakeup_time: u64) -> (u64, u8) {
            let day: u64 = (wakeup_time / ONE_DAY_IN_SECONDS);
            let period_in_u64: u64 = ((wakeup_time % ONE_DAY_IN_SECONDS) / TWELVE_HOURS_IN_SECONDS);
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

        fn _validate_if_alarm_can_be_edited_or_deleted(self: @ContractState, alarm:Alarm, user:ContractAddress) {
            // Checks for user to be able to edit/delete their alarm 
            //   -> The user should be the alarm OWNER
            //   -> The alarm is Active/Not Deleted
            //   -> The alarm is Not Triggered Yet
            //   -> The pool is Not Finalised Yet

            assert(alarm.user == user, AlarmContractErrors::NOT_ALARM_OWNER);
            assert(alarm.status != Status::Inactive, AlarmContractErrors::ALARM_NOT_FOUND);
            assert(alarm.status != Status::Deleted, AlarmContractErrors::ALARM_HAS_BEEN_DELETED);
            assert(alarm.status == Status::Active, AlarmContractErrors::ALARM_NOT_ACTIVE);
            assert(get_block_timestamp() < alarm.wakeup_time, AlarmContractErrors::INVALID_WAKEUP_TIME);
            assert(!self.pools.read((alarm.day, alarm.period)).is_finalized, AlarmContractErrors::POOL_IS_FINALIZED);
        }

        fn _edit_alarm_in_same_pool(ref self: ContractState, alarm: Alarm, new_wakeup_time: u64, new_stake_amount: u256) {
            let old_day = alarm.day;
            let old_period = alarm.period;
            let old_stake = alarm.stake_amount;
            let user = alarm.user;
            let alarm_id = alarm.alarm_id;

            let mut pool = self.pools.read((old_day, old_period));
            
            pool.total_staked = pool.total_staked - old_stake + new_stake_amount;
            self.pools.write((old_day, old_period), pool);

            let updated_alarm = Alarm {
                user: user,
                period: old_period,
                day: old_day,
                stake_amount: new_stake_amount,
                wakeup_time: new_wakeup_time,
                alarm_id: alarm_id,
                status: Status::Active,
            };
            
            // Write the updated alarm back to storage
            self.user_alarms.write((user, alarm_id), updated_alarm);
        }

        fn _edit_alarm_in_new_pool(ref self: ContractState, alarm: Alarm, new_day: u64, new_period: u8, new_wakeup_time: u64, new_stake_amount: u256) {
                // Move alarm between pools
                let old_day = alarm.day;
                let old_period = alarm.period;
                let old_stake = alarm.stake_amount;
                let user = alarm.user;
                let alarm_id = alarm.alarm_id;
                let mut old_pool = self.pools.read((old_day, old_period));

                old_pool.total_staked -= old_stake;
                old_pool.user_count -= 1;
                self.pools.write((old_day, old_period), old_pool);

                let mut new_pool = self.pools.read((new_day, new_period));
                new_pool.total_staked += new_stake_amount;
                new_pool.user_count += 1;
                self.pools.write((new_day, new_period), new_pool);

                // Mark that the user no longer has an alarm in the old pool and has an alarm in the new pool
                self.user_has_alarm_in_pool.write((user, old_day, old_period), false);
                self.user_has_alarm_in_pool.write((user, new_day, new_period), true);

                let updated_alarm = Alarm {
                    user: user,
                    period: new_period,
                    day: new_day,
                    stake_amount: new_stake_amount,
                    wakeup_time: new_wakeup_time,
                    alarm_id: alarm_id,
                    status: Status::Active,
                };
                
                // Write the updated alarm back to storage
                self.user_alarms.write((user, alarm_id), updated_alarm);
        }

        fn _validate_claim_preconditions(
            ref self: ContractState, alarm: Alarm, claimer: ContractAddress) {
            // Checks for user to be able to claim winnings
            //   -> The user should be the alarm OWNER
            //   -> The alarm is Active/Not Deleted
            //   -> The pool is Finalised
            //   -> The user has not yet claimed
            //   -> The wakeup time has been reached

            assert(alarm.user == claimer, AlarmContractErrors::NOT_ALARM_OWNER);
            assert(alarm.status != Status::Inactive, AlarmContractErrors::ALARM_NOT_FOUND);
            assert(alarm.status != Status::Deleted, AlarmContractErrors::ALARM_HAS_BEEN_DELETED);
            assert(alarm.status == Status::Active, AlarmContractErrors::ALARM_NOT_ACTIVE);
            
            assert(get_block_timestamp() >= alarm.wakeup_time, AlarmContractErrors::WAKEUP_TIME_NOT_REACHED);

            assert(self.pools.read((alarm.day, alarm.period)).is_finalized, AlarmContractErrors::POOL_NOT_FINALIZED,);
            assert(!self.user_has_claimed_winnings.read((claimer, alarm.alarm_id)),AlarmContractErrors::ALARM_ALREADY_CLAIMED);
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
            let is_valid = merkle_proof::verify_poseidon(proof_span, pool.merkle_root, leaf);
            assert(is_valid, AlarmContractErrors::INVALID_PROOF);
        }
    }
}