// focus_lock_backend.js - Integrated Database & Blockchain Backend for Focus Locks
require('dotenv').config({ path: '../doc_2025-09-09_20-45-53.env' });
const { createClient } = require('@supabase/supabase-js');
const { Account, RpcProvider, hash, ec, getSelectorByName } = require('starknet');

// Try to import PaymasterRpc - might not be available in all versions
let PaymasterRpc;
try {
    PaymasterRpc = require('starknet').PaymasterRpc;
} catch (e) {
    console.log('⚠️  PaymasterRpc not available in this starknet version - transactions will not be sponsored');
}

/**
 * Backend logic for the Focus Lock (Time Lock) smart contract.
 * This class handles calculating stake returns, user rewards,
 * generating cryptographic proofs, and executing blockchain transactions.
 * Integrated with Supabase database and AVNU paymaster for gasless transactions.
 */
class FocusLockContractBackend {
    constructor() {
        this.SLASH_100_PERCENT = BigInt(0); // 100% slash for failed locks
        
        // Initialize clients
        this.supabase = null;
        this.provider = null;
        this.paymasterRpc = null;
        this.account = null;
        
        console.log('🏗️ FocusLockContractBackend initialized');
    }

    /**
     * Initialize all services (Supabase, Starknet, AVNU Paymaster)
     */
    async initialize() {
        try {
            console.log('🔧 ========== INITIALIZING BACKEND SERVICES ==========');
            
            // Initialize Supabase
            console.log('📊 Initializing Supabase client...');
            const supabaseUrl = process.env.SUPABASE_URL;
            const supabaseServiceKey = process.env.SUPABASE_SERVICE_KEY;
            
            if (!supabaseUrl || !supabaseServiceKey) {
                throw new Error('Missing SUPABASE_URL or SUPABASE_SERVICE_KEY environment variables');
            }
            
            this.supabase = createClient(supabaseUrl, supabaseServiceKey);
            console.log('✅ Supabase client initialized');
            
            // Initialize Starknet Provider
            console.log('⚡ Initializing Starknet provider...');
            const rpcUrl = process.env.STARKNET_RPC_URL;
            if (!rpcUrl) {
                throw new Error('Missing STARKNET_RPC_URL environment variable');
            }
            
            this.provider = new RpcProvider({ nodeUrl: rpcUrl });
            console.log('✅ Starknet provider initialized');
            
            // Initialize AVNU Paymaster (if available)
            console.log('💰 Initializing AVNU Paymaster...');
            const paymasterRpc = process.env.AVNU_PAYMASTER_RPC || 'https://sepolia.paymaster.avnu.fi';
            const paymasterApiKey = process.env.AVNU_PAYMASTER_API_KEY;
            
            if (PaymasterRpc && paymasterApiKey) {
                try {
                    this.paymasterRpc = new PaymasterRpc({
                        nodeUrl: paymasterRpc,
                        headers: { 'api-key': paymasterApiKey }
                    });
                    console.log('✅ AVNU Paymaster initialized (sponsored transactions enabled)');
                } catch (error) {
                    console.log('⚠️  AVNU Paymaster failed to initialize:', error.message);
                    console.log('⚠️  Will use regular transactions instead');
                    this.paymasterRpc = null;
                }
            } else {
                console.log('⚠️  AVNU Paymaster not available - using regular transactions');
                this.paymasterRpc = null;
            }
            
            // Initialize Account
            console.log('🔑 Initializing deployer account...');
            const deployerAddress = process.env.DEPLOYER_ADDRESS;
            const deployerPrivateKey = process.env.DEPLOYER_PRIVATE_KEY;
            
            if (!deployerAddress || !deployerPrivateKey) {
                throw new Error('Missing DEPLOYER_ADDRESS or DEPLOYER_PRIVATE_KEY environment variables');
            }
            
            if (this.paymasterRpc) {
                this.account = new Account(
                    this.provider,
                    deployerAddress,
                    deployerPrivateKey,
                    undefined,
                    this.paymasterRpc
                );
                console.log('✅ Deployer account initialized with paymaster support');
            } else {
                this.account = new Account(
                    this.provider,
                    deployerAddress,
                    deployerPrivateKey
                );
                console.log('✅ Deployer account initialized (regular transactions)');
            }
            
            console.log('🎉 ========== ALL SERVICES INITIALIZED SUCCESSFULLY ==========');
        } catch (error) {
            console.error('❌ Backend initialization failed:', error);
            throw error;
        }
    }

    /**
     * Calculate day and period from start_time
     * @param {number} startTime - Unix timestamp
     * @returns {Object} {day, period} where period is 0-3 for 6-hour periods
     */
    getPoolInfo(startTime) {
        const day = Math.floor(startTime / 86400); // Unix day
        const timeOfDay = startTime % 86400; // Seconds since midnight
        const period = Math.floor(timeOfDay / 21600); // 0-3 for 6-hour periods (0=0-6h, 1=6-12h, 2=12-18h, 3=18-24h)
        
        console.log(`📊 Pool Info - Start Time: ${startTime} → Day: ${day}, Period: ${period}`);
        console.log(`   Time of day: ${timeOfDay}s (${Math.floor(timeOfDay/3600)}h ${Math.floor((timeOfDay%3600)/60)}m)`);
        console.log(`   Period breakdown: 0=0-6h, 1=6-12h, 2=12-18h, 3=18-24h`);
        
        return { day, period };
    }

    /**
     * Find the latest pool that contains focus locks
     * @returns {Promise<Object|null>} {day, period} of the latest pool with locks, or null if none found
     */
    async findLatestPoolWithLocks() {
        try {
            console.log(`🔍 ========== FINDING LATEST POOL WITH FOCUS LOCKS ==========`);
            
            // Get the most recent focus lock
            const { data: locks, error } = await this.supabase
                .from('focus_locks')
                .select(`
                    start_time,
                    user_id
                `)
                .order('start_time', { ascending: false })
                .limit(1);
            
            if (error) {
                throw new Error(`Database query failed: ${error.message}`);
            }
            
            if (!locks || locks.length === 0) {
                console.log(`⚠️ No focus locks found in database`);
                return null;
            }
            
            const latestStartTime = locks[0].start_time;
            const poolInfo = this.getPoolInfo(latestStartTime);
            
            console.log(`✅ Latest lock pool found: Day ${poolInfo.day}, Period ${poolInfo.period}`);
            console.log(`📅 Latest lock time: ${new Date(latestStartTime * 1000)}`);
            
            return poolInfo;
            
        } catch (error) {
            console.error(`❌ Failed to find latest pool:`, error);
            return null;
        }
    }

    /**
     * Fetch focus locks data from Supabase database for a specific day/period
     * @param {number} day - Unix day
     * @param {number} period - 0-3 for 6-hour periods
     * @returns {Promise<Array>} Array of user lock data
     */
    async fetchLocksFromDatabase(day, period) {
        try {
            console.log(`🔍 ========== FETCHING FOCUS LOCKS FROM DATABASE ==========`);
            console.log(`📊 Querying for Day: ${day}, Period: ${period}`);
            
            // Calculate time range for this day/period
            const dayStart = day * 86400;
            const periodStart = dayStart + (period * 21600); // 6-hour periods
            const periodEnd = periodStart + 21600; // Next 6 hours
            
            console.log(`⏰ Time Range: ${periodStart} - ${periodEnd}`);
            console.log(`📅 Date Range: ${new Date(periodStart * 1000)} - ${new Date(periodEnd * 1000)}`);
            
            // Query focus locks BY day and period columns (not by time range)
            // This ensures we match what the contract stored, even if time calculations differ
            const { data: locks, error } = await this.supabase
                .from('focus_locks')
                .select('*')
                .eq('day', day)
                .eq('period', period)
                .order('start_time');
            
            if (error) {
                throw new Error(`Database query failed: ${error.message}`);
            }
            
            if (!locks || locks.length === 0) {
                console.log(`⚠️ No focus locks found for Day ${day}, Period ${period}`);
                return [];
            }
            
            console.log(`✅ Found ${locks.length} focus locks for this pool:`);
            
            // Get wallet addresses for all users
            const userIds = locks.map(l => l.user_id);
            const { data: profiles, error: profileError } = await this.supabase
                .from('profiles')
                .select('id, wallet_address')
                .in('id', userIds);
            
            if (profileError) {
                throw new Error(`Failed to fetch profiles: ${profileError.message}`);
            }
            
            // Create a map of user_id -> wallet_address
            const walletMap = {};
            profiles.forEach(p => {
                walletMap[p.id] = p.wallet_address;
            });
            
            // Transform data to match expected format
            const transformedLocks = locks.map(lock => {
                const duration = lock.duration_minutes * 60; // Convert to seconds
                const walletAddress = walletMap[lock.user_id];
                
                if (!walletAddress) {
                    throw new Error(`No wallet address found for user ${lock.user_id}`);
                }
                
                const userData = {
                    address: walletAddress,
                    start_time: lock.start_time.toString(),
                    duration: duration.toString(),
                    stake_amount: lock.stake_amount.toString(),
                    completion_status: lock.completion_status !== null ? lock.completion_status : false,
                    lock_id: lock.id // Keep lock ID for database updates
                };
                
                console.log(`   👤 User: ${userData.address}`);
                console.log(`      Start: ${userData.start_time} (${new Date(parseInt(userData.start_time) * 1000)})`);
                console.log(`      Duration: ${userData.duration}s`);
                console.log(`      Stake: ${userData.stake_amount}`);
                console.log(`      Completed: ${userData.completion_status}`);
                
                return userData;
            });
            
            console.log(`🎉 Database fetch completed successfully`);
            return transformedLocks;
            
        } catch (error) {
            console.error(`❌ Failed to fetch focus locks from database:`, error);
            throw error;
        }
    }

    /**
     * Helper: Normalizes a value to a "0x..." hex string.
     */
    toHexString(val) {
        if (typeof val === 'string' && val.startsWith('0x')) {
            return val.toLowerCase();
        }
        return '0x' + BigInt(val).toString(16);
    }

    /**
     * Parses a "0x..." hex string or number into a BigInt.
     */
    toBigInt(val) {
        if (typeof val === 'bigint') {
            return val;
        }
        if (typeof val === 'number') {
            return BigInt(val);
        }
        if (typeof val === 'string' && val.startsWith('0x')) {
            return BigInt(val);
        }
        return BigInt(val);
    }

    /**
     * Calculates the amount of stake a user gets back based on their completion status.
     */
    calculateStakeReturn(stakeAmount, completionStatus) {
        const stake = BigInt(stakeAmount);
        if (completionStatus) {
            // Completed successfully - return full stake
            return stake;
        } else {
            // Failed/exited early - return 0 (100% slash)
            return this.SLASH_100_PERCENT;
        }
    }

    /**
     * Calculates the total amount of stake slashed from all users.
     */
    calculateTotalSlashedAmount(users) {
        let totalSlashed = BigInt(0);
        for (const user of users) {
            const stakeAmount = this.toBigInt(user.stake_amount);
            const returnAmount = this.calculateStakeReturn(stakeAmount, user.completion_status);
            totalSlashed += (stakeAmount - returnAmount);
        }
        return totalSlashed;
    }

    /**
     * Calculates the rewards for winning users (who completed their locks successfully).
     */
    calculateRewards(users) {
        const winners = users.filter(u => u.completion_status === true);
        const totalSlashed = this.calculateTotalSlashedAmount(users);
        
        console.log(`🔍 DEBUG: Total users: ${users.length}, Winners found: ${winners.length}`);
        console.log(`🔍 DEBUG: Total slashed: ${totalSlashed.toString()}`);
        users.forEach(u => {
            console.log(`   User ${u.address.substring(0, 10)}... completion=${u.completion_status} (type: ${typeof u.completion_status})`);
        });
        
        if (winners.length === 0 || totalSlashed === BigInt(0)) {
            console.log(`⚠️ No rewards to distribute: winners=${winners.length}, slashed=${totalSlashed.toString()}`);
            return [];
        }

        const totalWinnerStake = winners.reduce((sum, w) => sum + this.toBigInt(w.stake_amount), BigInt(0));
        if (totalWinnerStake === BigInt(0)) {
            return [];
        }

        return winners.map(winner => {
            const winnerStake = this.toBigInt(winner.stake_amount);
            const proportionalReward = (totalSlashed * winnerStake) / totalWinnerStake;
            return {
                address: winner.address,
                reward_amount: proportionalReward.toString()
            };
        });
    }

    /**
     * Validates the input types and ranges for user data.
     */
    validateInputTypes(users) {
        for (const user of users) {
            if (!user.address || typeof user.address !== 'string' || !user.address.startsWith('0x')) {
                throw new Error(`Invalid address: ${JSON.stringify(user)}`);
            }
            const startTime = this.toBigInt(user.start_time);
            if (startTime < 0n || startTime >= (1n << 64n)) {
                throw new Error(`start_time out of u64: ${user.start_time}`);
            }
            const duration = this.toBigInt(user.duration);
            if (duration < 60n || duration > 86400n) {
                throw new Error(`duration out of range (60-86400 seconds): ${user.duration}`);
            }
            if (typeof user.completion_status !== 'boolean') {
                throw new Error(`completion_status must be boolean: ${user.completion_status}`);
            }
            const stakeAmount = this.toBigInt(user.stake_amount);
            if (stakeAmount < 0n || stakeAmount >= (1n << 256n)) {
                throw new Error(`stake_amount out of u256: ${user.stake_amount}`);
            }
        }
    }

    /**
     * Creates a cryptographic signature for a user's outcome using a private key.
     */
    createOutcomeSignature(userAddress, startTime, duration, completionStatus, privateKey) {
        let normalizedPrivateKey = privateKey;
        if (!normalizedPrivateKey.startsWith('0x')) {
            normalizedPrivateKey = '0x' + normalizedPrivateKey;
        }

        const callerFelt = this.toBigInt(userAddress);
        const startFelt = this.toBigInt(startTime);
        const durationFelt = this.toBigInt(duration);
        const completionFelt = completionStatus ? BigInt(1) : BigInt(0);

        const messageHash = hash.computePoseidonHashOnElements([callerFelt, startFelt, durationFelt, completionFelt]);
        const signature = ec.starkCurve.sign(messageHash, normalizedPrivateKey);

        return {
            message_hash: this.toHexString(messageHash),
            signature_r: this.toHexString(signature.r),
            signature_s: this.toHexString(signature.s),
            public_key: this.toHexString(ec.starkCurve.getStarkKey(normalizedPrivateKey)),
        };
    }

    /**
     * Creates a Merkle tree leaf hash for a user and their reward amount.
     */
    createMerkleLeaf(userAddress, rewardAmount) {
        const callerFelt = this.toBigInt(userAddress);
        const reward = this.toBigInt(rewardAmount);

        const mask128 = (BigInt(1) << BigInt(128)) - BigInt(1);
        const rewardLow = reward & mask128;
        const rewardHigh = reward >> BigInt(128);

        const leafHash = hash.computePoseidonHashOnElements([callerFelt, rewardLow, rewardHigh]);
        return this.toHexString(leafHash);
    }

    /**
     * Builds a Merkle tree from a list of leaf hashes.
     */
    buildMerkleTree(leaves) {
        if (leaves.length === 0) {
            // Generate a valid non-zero merkle root for empty reward case
            const noRewardsHash = hash.computePoseidonHashOnElements([BigInt('0x6e6f5f726577617264734040')]);
            return { root: this.toHexString(noRewardsHash), proofs: {} };
        }
        if (leaves.length === 1) {
            return { root: leaves[0].hash, proofs: { [leaves[0].address]: [] } };
        }

        const proofs = {};
        leaves.forEach(leaf => proofs[leaf.address] = []);

        let currentLevel = leaves.map(l => ({ address: l.address, hashBig: this.toBigInt(l.hash) }));

        while (currentLevel.length > 1) {
            const nextLevel = [];
            for (let i = 0; i < currentLevel.length; i += 2) {
                const left = currentLevel[i];
                const right = (i + 1 < currentLevel.length) ? currentLevel[i + 1] : left;

                proofs[left.address].push(this.toHexString(right.hashBig));
                if (right.address !== left.address) {
                    proofs[right.address].push(this.toHexString(left.hashBig));
                }

                const parentHashBig = hash.computePoseidonHashOnElements([left.hashBig, right.hashBig]);
                nextLevel.push({ hashBig: parentHashBig });
            }
            currentLevel = nextLevel;
        }

        return { root: this.toHexString(currentLevel[0].hashBig), proofs };
    }

    /**
     * Set merkle root on-chain using AVNU sponsored transaction
     */
    async setMerkleRootOnChain(day, period, merkleRoot) {
        try {
            console.log(`🚀 ========== SETTING MERKLE ROOT ON-CHAIN ==========`);
            console.log(`📊 Pool: Day ${day}, Period ${period}`);
            console.log(`🌳 Merkle Root: ${merkleRoot}`);
            
            const timeLockContractAddress = process.env.TIME_LOCK_CONTRACT_ADDRESS;
            if (!timeLockContractAddress) {
                throw new Error('Missing TIME_LOCK_CONTRACT_ADDRESS environment variable');
            }
            
            console.log(`📋 Contract Address: ${timeLockContractAddress}`);
            
            // Prepare contract call
            const calls = [{
                contractAddress: timeLockContractAddress,
                entrypoint: 'set_reward_merkle_root',
                calldata: [
                    day.toString(),
                    period.toString(),
                    merkleRoot
                ]
            }];
            
            console.log(`🔨 Contract Call Prepared:`);
            console.log(`   Function: set_reward_merkle_root`);
            console.log(`   Day: ${day}`);
            console.log(`   Period: ${period}`);
            console.log(`   Merkle Root: ${merkleRoot}`);
            
            // Execute transaction (sponsored or regular)
            let result;
            
            if (this.paymasterRpc) {
                console.log(`💰 Executing sponsored transaction via AVNU Paymaster...`);
                const feesDetails = { feeMode: { mode: 'sponsored' } };
                result = await this.account.executePaymasterTransaction(calls, feesDetails);
            } else {
                console.log(`💳 Executing regular transaction (gas fees will be paid)...`);
                result = await this.account.execute(calls, undefined, {
                    maxFee: '1000000000000000',
                    version: 2
                });
            }
            
            console.log(`✅ Transaction submitted successfully!`);
            console.log(`📋 Transaction Hash: ${result.transaction_hash}`);
            
            // Wait for transaction confirmation
            console.log(`⏳ Waiting for transaction confirmation...`);
            const receipt = await this.provider.waitForTransaction(result.transaction_hash);
            
            if (receipt.execution_status === 'SUCCEEDED') {
                console.log(`🎉 ========== MERKLE ROOT SET SUCCESSFULLY ==========`);
                console.log(`📋 Final Transaction Hash: ${result.transaction_hash}`);
                console.log(`🌳 Merkle Root ${merkleRoot} set for Day ${day}, Period ${period}`);
                return result.transaction_hash;
            } else {
                throw new Error(`Transaction failed with status: ${receipt.execution_status}`);
            }
            
        } catch (error) {
            console.error(`❌ ========== SET MERKLE ROOT FAILED ==========`);
            console.error(`🚫 Error: ${error.message}`);
            console.error(`📊 Failed Pool: Day ${day}, Period ${period}`);
            console.error(`🌳 Failed Merkle Root: ${merkleRoot}`);
            throw error;
        }
    }

    /**
     * Store processed results back to database
     */
    async storeResultsToDatabase(users, rewards, merkleTree, verifierPrivateKey) {
        try {
            console.log(`💾 ========== STORING RESULTS TO DATABASE ==========`);
            
            const lockUpdates = [];
            const claimDataInserts = [];
            
            for (const user of users) {
                console.log(`📊 Processing user: ${user.address}`);
                
                // Find reward for this user
                const userReward = rewards.find(r => r.address === user.address);
                const rewardAmount = userReward ? userReward.reward_amount : "0";
                
                // All users have merkle proofs
                const merkleProof = merkleTree.proofs[user.address] || [];
                
                // Generate signature for this user
                const signature = this.createOutcomeSignature(
                    user.address,
                    user.start_time,
                    user.duration,
                    user.completion_status,
                    verifierPrivateKey
                );
                
                // Calculate stake return
                const stakeReturn = this.calculateStakeReturn(user.stake_amount, user.completion_status);
                
                console.log(`   💰 Reward: ${rewardAmount}`);
                console.log(`   🔄 Stake Return: ${stakeReturn.toString()}`);
                console.log(`   🏆 Is Winner: ${user.completion_status}`);
                
                // Prepare focus_locks table update
                lockUpdates.push({
                    id: user.lock_id,
                    claim_ready: true,
                    has_claimed: false
                });
                
                // Prepare claim data insert
                claimDataInserts.push({
                    lock_id: user.lock_id,
                    signature_r: signature.signature_r,
                    signature_s: signature.signature_s,
                    message_hash: signature.message_hash,
                    reward_amount: rewardAmount,
                    merkle_proof: JSON.stringify(merkleProof),
                    processed_at: new Date().toISOString()
                });
            }
            
            // Batch update focus_locks table
            console.log(`🔄 Updating ${lockUpdates.length} lock records...`);
            for (const update of lockUpdates) {
                const { error } = await this.supabase
                    .from('focus_locks')
                    .update({
                        claim_ready: update.claim_ready,
                        has_claimed: update.has_claimed
                    })
                    .eq('id', update.id);
                
                if (error) {
                    throw new Error(`Failed to update lock ${update.id}: ${error.message}`);
                }
            }
            console.log(`✅ Focus locks table updated successfully`);
            
            // Batch insert claim data
            console.log(`📝 Inserting ${claimDataInserts.length} claim data records...`);
            const { error: insertError } = await this.supabase
                .from('user_claim_data_locks')
                .insert(claimDataInserts);
            
            if (insertError) {
                throw new Error(`Failed to insert claim data: ${insertError.message}`);
            }
            console.log(`✅ Claim data inserted successfully`);
            
            console.log(`🎉 All database operations completed successfully!`);
            
        } catch (error) {
            console.error(`❌ Database storage failed:`, error);
            throw error;
        }
    }

    /**
     * Process focus lock pool: fetch from database, calculate outcomes, set merkle root on-chain, store results
     */
    async processFocusLockPool(day, period) {
        try {
            console.log(`🚀 ========== PROCESSING FOCUS LOCK POOL ==========`);
            console.log(`📅 Pool: Day ${day}, Period ${period}`);
            console.log(`🕐 Processing Time: ${new Date()}`);
            
            // Step 1: Fetch lock data from database
            console.log(`\n🔍 STEP 1: FETCHING LOCK DATA`);
            const users = await this.fetchLocksFromDatabase(day, period);
            
            if (users.length === 0) {
                console.log(`⚠️ No users found in this pool - skipping processing`);
                return { success: false, message: 'No users in pool' };
            }
            
            // Step 2: Validate user data
            console.log(`\n✅ STEP 2: VALIDATING USER DATA`);
            console.log(`👥 Total users in pool: ${users.length}`);
            this.validateInputTypes(users);
            console.log(`✅ All user data validated successfully`);
            
            // Step 3: Calculate rewards and slashed amounts
            console.log(`\n💰 STEP 3: CALCULATING REWARDS`);
            const rewards = this.calculateRewards(users);
            const totalSlashed = this.calculateTotalSlashedAmount(users);
            
            console.log(`🏆 Winners: ${rewards.length}`);
            console.log(`💸 Total Slashed: ${totalSlashed.toString()}`);
            
            // Step 4: Build merkle tree
            console.log(`\n🌳 STEP 4: BUILDING MERKLE TREE`);
            
            // Include ALL users in merkle tree
            const leaves = users.map(user => {
                const userReward = rewards.find(r => r.address === user.address);
                const rewardAmount = userReward ? userReward.reward_amount : "0";
                return {
                    address: user.address,
                    hash: this.createMerkleLeaf(user.address, rewardAmount)
                };
            });
            
            const merkleTree = this.buildMerkleTree(leaves);
            console.log(`✅ Merkle tree built with root: ${merkleTree.root}`);
            console.log(`📊 Tree includes ${leaves.length} users (${rewards.length} winners + ${users.length - rewards.length} non-winners)`);
            
            // Step 5: Set merkle root on-chain (REQUIRED)
            console.log(`\n⛓️ STEP 5: SETTING MERKLE ROOT ON-CHAIN`);
            let txHash = null;
            try {
                txHash = await this.setMerkleRootOnChain(day, period, merkleTree.root);
                console.log(`✅ Merkle root set on-chain - TX: ${txHash}`);
            } catch (error) {
                console.error(`❌ CRITICAL: Blockchain transaction failed`);
                throw new Error(`Blockchain finalization required: ${error.message}`);
            }
            
            // Step 6: Store results to database
            console.log(`\n💾 STEP 6: STORING RESULTS TO DATABASE`);
            const verifierPrivateKey = process.env.VERIFIER_PRIVATE_KEY;
            if (!verifierPrivateKey) {
                throw new Error('Missing VERIFIER_PRIVATE_KEY environment variable');
            }
            
            await this.storeResultsToDatabase(users, rewards, merkleTree, verifierPrivateKey);
            console.log(`✅ Results stored to database successfully`);
            
            // Step 7: Summary
            console.log(`\n🎉 ========== PROCESSING COMPLETED SUCCESSFULLY ==========`);
            console.log(`📅 Pool: Day ${day}, Period ${period}`);
            console.log(`👥 Total Users: ${users.length}`);
            console.log(`🏆 Winners: ${rewards.length}`);
            console.log(`💸 Total Slashed: ${totalSlashed.toString()}`);
            console.log(`🌳 Merkle Root: ${merkleTree.root}`);
            console.log(`📋 Transaction Hash: ${txHash}`);
            console.log(`🕐 Completed At: ${new Date()}`);
            console.log(`💾 Database Status: ✅ All claim data stored`);
            console.log(`⛓️ Blockchain Status: ✅ Pool finalized on-chain`);
            console.log(`🎯 Users can now claim their rewards through the app!`);
            console.log(`====================================================`);
            
            return {
                success: true,
                pool_info: {
                    day: day,
                    period: period,
                    merkle_root: merkleTree.root,
                    total_slashed_amount: totalSlashed.toString(),
                    transaction_hash: txHash,
                    total_users: users.length,
                    winners: rewards.length,
                    processed_at: new Date().toISOString(),
                    blockchain_status: 'success'
                }
            };
            
        } catch (error) {
            console.error(`❌ ========== FOCUS LOCK POOL PROCESSING FAILED ==========`);
            console.error(`📅 Failed Pool: Day ${day}, Period ${period}`);
            console.error(`🚫 Error: ${error.message}`);
            console.error(`🔍 Stack: ${error.stack}`);
            console.error(`================================================`);
            throw error;
        }
    }
}

// Main runner function - Integrated Database & Blockchain Processing
async function main() {
    console.log('🏗️ ========== FOCUS LOCK BACKEND PROCESSOR ==========');
    console.log('🕐 Started at:', new Date());
    
    const backend = new FocusLockContractBackend();
    
    try {
        // Initialize all services
        await backend.initialize();
        
        // Get day and period from command line arguments or environment
        let day = process.argv[2] || process.env.DAY;
        let period = process.argv[3] || process.env.PERIOD;
        
        if (!day || !period || day === 'auto' || day === 'latest') {
            if (day === 'auto' || day === 'latest') {
                // Find latest pool with locks
                console.log('🔍 Auto-detecting latest pool with focus locks...');
                const latestPool = await backend.findLatestPoolWithLocks();
                if (latestPool) {
                    day = latestPool.day;
                    period = latestPool.period;
                    console.log('✅ Using latest pool with focus locks');
                } else {
                    console.log('⚠️ No locks found, falling back to current time pool');
                    const currentTime = Math.floor(Date.now() / 1000);
                    const poolInfo = backend.getPoolInfo(currentTime);
                    day = poolInfo.day;
                    period = poolInfo.period;
                }
            } else {
                // Use current time to determine pool if not specified
                const currentTime = Math.floor(Date.now() / 1000);
                const poolInfo = backend.getPoolInfo(currentTime);
                day = poolInfo.day;
                period = poolInfo.period;
                console.log('⚠️ No day/period specified, using current time pool');
            }
        }
        
        day = parseInt(day);
        period = parseInt(period);
        
        console.log(`🎯 Target Pool: Day ${day}, Period ${period}`);
        
        // Validate inputs
        if (isNaN(day) || isNaN(period) || period < 0 || period > 3) {
            throw new Error('Invalid day/period. Period must be 0-3 for 6-hour periods');
        }
        
        // Process the pool
        const results = await backend.processFocusLockPool(day, period);
        
        if (results.success) {
            console.log('🎉 ========== FINAL SUCCESS SUMMARY ==========');
            console.log('📊 Pool Info:', JSON.stringify(results.pool_info, null, 2));
            console.log('🎯 Ready for claims: Database ✅ + Blockchain ✅');
        } else {
            console.log(`⚠️ Processing completed with message: ${results.message}`);
        }
        
    } catch (error) {
        console.error('💥 ========== FATAL ERROR ==========');
        console.error('❌ Error:', error.message);
        console.error('🔍 Stack:', error.stack);
        console.error('🕐 Failed at:', new Date());
        process.exit(1);
    }
}

// Usage information
function printUsage() {
    console.log('📖 ========== USAGE ==========');
    console.log('node focus_lock_backend.js [day] [period]');
    console.log('');
    console.log('Arguments:');
    console.log('  day    - Unix day number (calculated as Math.floor(start_time / 86400))');
    console.log('         - OR "auto"/"latest" to find the most recent pool with locks');
    console.log('  period - Pool period: 0-3 for 6-hour periods (0=0-6h, 1=6-12h, 2=12-18h, 3=18-24h)');
    console.log('');
    console.log('Examples:');
    console.log('  node focus_lock_backend.js 20321 1    # Process specific day 20321, period 1');
    console.log('  node focus_lock_backend.js auto       # Auto-detect latest pool with locks');
    console.log('  node focus_lock_backend.js latest     # Same as auto');
    console.log('  node focus_lock_backend.js            # Process current time pool');
    console.log('');
    console.log('Environment Variables Required:');
    console.log('  SUPABASE_URL, SUPABASE_SERVICE_KEY');
    console.log('  STARKNET_RPC_URL, AVNU_PAYMASTER_API_KEY');
    console.log('  DEPLOYER_ADDRESS, DEPLOYER_PRIVATE_KEY');
    console.log('  TIME_LOCK_CONTRACT_ADDRESS, VERIFIER_PRIVATE_KEY');
    console.log('=============================');
}

// Show help if requested
if (process.argv.includes('--help') || process.argv.includes('-h')) {
    printUsage();
    process.exit(0);
}

module.exports = { FocusLockContractBackend };

if (require.main === module) {
    main();
}

