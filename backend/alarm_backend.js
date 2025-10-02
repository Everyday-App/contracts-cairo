// alarm_backend.js - Integrated Database & Blockchain Backend
require('dotenv').config({ path: '../doc_2025-09-09_20-45-53.env' });
const { createClient } = require('@supabase/supabase-js');
const { Account, RpcProvider, hash, ec, Felt, getSelectorByName } = require('starknet');

// Try to import PaymasterRpc - might not be available in all versions
let PaymasterRpc;
try {
    PaymasterRpc = require('starknet').PaymasterRpc;
} catch (e) {
    console.log('⚠️  PaymasterRpc not available in this starknet version - transactions will not be sponsored');
}

/**
 * Backend logic for the Alarm Clock smart contract.
 * This class handles calculating stake returns, user rewards,
 * generating cryptographic proofs, and executing blockchain transactions.
 * Integrated with Supabase database and AVNU paymaster for gasless transactions.
 */
class AlarmContractBackend {
    constructor() {
        this.PERCENT_BASE = BigInt(100);
        this.SLASH_20_PERCENT = BigInt(80);
        this.SLASH_50_PERCENT = BigInt(50);
        this.SLASH_100_PERCENT = BigInt(0);
        
        // Initialize clients
        this.supabase = null;
        this.provider = null;
        this.paymasterRpc = null;
        this.account = null;
        
        console.log('🏗️ AlarmContractBackend initialized');
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
            
            this.provider = new RpcProvider({ 
                nodeUrl: rpcUrl
                // Simplified config for v8 RPC compatibility - removed blockIdentifier and default
            });
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
     * Calculate day and period from wakeup_time
     * @param {number} wakeupTime - Unix timestamp
     * @returns {Object} {day, period} where period is 0=AM, 1=PM
     */
    getPoolInfo(wakeupTime) {
        const day = Math.floor(wakeupTime / 86400); // Unix day
        const period = Math.floor((wakeupTime % 86400) / 43200); // 0=AM, 1=PM
        console.log(`📊 Pool Info - Wakeup Time: ${wakeupTime} → Day: ${day}, Period: ${period}`);
        return { day, period };
    }

    /**
     * Find the latest pool that contains alarms
     * @returns {Promise<Object|null>} {day, period} of the latest pool with alarms, or null if none found
     */
    async findLatestPoolWithAlarms() {
        try {
            console.log(`🔍 ========== FINDING LATEST POOL WITH ALARMS ==========`);
            
            // Debug: First check if any alarms exist at all
            console.log(`🔧 DEBUG: Testing basic alarms table access...`);
            const { data: testAlarms, error: testError } = await this.supabase
                .from('alarms')
                .select('id, wakeup_time')
                .limit(5);
            
            console.log(`🔧 DEBUG: Basic query result: ${testAlarms?.length || 0} alarms, error: ${testError?.message || 'none'}`);
            if (testAlarms && testAlarms.length > 0) {
                testAlarms.forEach(alarm => {
                    console.log(`   🔧 Alarm: ${alarm.id?.substring(0, 8)} - ${alarm.wakeup_time}`);
                });
            }
            
            // Get the most recent alarm (use same query pattern as fetchAlarmsFromDatabase)
            console.log(`🔧 DEBUG: Querying for latest alarm with profiles join...`);
            const { data: alarms, error } = await this.supabase
                .from('alarms')
                .select(`
                    wakeup_time,
                    profiles!inner(wallet_address)
                `)
                .order('wakeup_time', { ascending: false })
                .limit(1);
            
            console.log(`🔧 DEBUG: Profiles join query result: ${alarms?.length || 0} alarms, error: ${error?.message || 'none'}`);
            
            if (error) {
                console.log(`🔧 DEBUG: Query error details:`, error);
                throw new Error(`Database query failed: ${error.message}`);
            }
            
            if (!alarms || alarms.length === 0) {
                console.log(`⚠️ No alarms found in database (with profile join)`);
                
                // Try without profiles join as fallback
                console.log(`🔧 DEBUG: Trying without profiles join...`);
                const { data: fallbackAlarms, error: fallbackError } = await this.supabase
                    .from('alarms')
                    .select('wakeup_time')
                    .order('wakeup_time', { ascending: false })
                    .limit(1);
                
                console.log(`🔧 DEBUG: Fallback query result: ${fallbackAlarms?.length || 0} alarms`);
                
                if (fallbackAlarms && fallbackAlarms.length > 0) {
                    console.log(`⚠️ Found alarms without profile join - profile relationship issue detected`);
                    const latestWakeupTime = fallbackAlarms[0].wakeup_time;
                    const poolInfo = this.getPoolInfo(latestWakeupTime);
                    return poolInfo;
                }
                
                return null;
            }
            
            const latestWakeupTime = alarms[0].wakeup_time;
            const poolInfo = this.getPoolInfo(latestWakeupTime);
            
            console.log(`✅ Latest alarm pool found: Day ${poolInfo.day}, Period ${poolInfo.period}`);
            console.log(`📅 Latest alarm time: ${new Date(latestWakeupTime * 1000)}`);
            
            return poolInfo;
            
        } catch (error) {
            console.error(`❌ Failed to find latest pool:`, error);
            return null;
        }
    }

    /**
     * Fetch alarms data from Supabase database for a specific day/period
     * @param {number} day - Unix day
     * @param {number} period - 0=AM, 1=PM
     * @returns {Promise<Array>} Array of user alarm data
     */
    async fetchAlarmsFromDatabase(day, period) {
        try {
            console.log(`🔍 ========== FETCHING ALARMS FROM DATABASE ==========`);
            console.log(`📊 Querying for Day: ${day}, Period: ${period}`);
            
            // Calculate time range for this day/period
            const dayStart = day * 86400;
            const periodStart = dayStart + (period * 43200); // 0 or 43200 seconds
            const periodEnd = periodStart + 43200; // Next 12 hours
            
            console.log(`⏰ Time Range: ${periodStart} - ${periodEnd}`);
            console.log(`📅 Date Range: ${new Date(periodStart * 1000)} - ${new Date(periodEnd * 1000)}`);
            
            // Query alarms with profile data
            const { data: alarms, error } = await this.supabase
                .from('alarms')
                .select(`
                    *,
                    profiles!inner(wallet_address)
                `)
                .gte('wakeup_time', periodStart)
                .lt('wakeup_time', periodEnd)
                .order('wakeup_time');
            
            if (error) {
                throw new Error(`Database query failed: ${error.message}`);
            }
            
            if (!alarms || alarms.length === 0) {
                console.log(`⚠️ No alarms found for Day ${day}, Period ${period}`);
                return [];
            }
            
            console.log(`✅ Found ${alarms.length} alarms for this pool:`);
            
            // Transform data to match expected format
            const transformedAlarms = alarms.map(alarm => {
                const userData = {
                    address: alarm.profiles.wallet_address,
                    wake_up_time: alarm.wakeup_time.toString(),
                    stake_amount: alarm.stake_amount.toString(),
                    snooze_count: alarm.snooze_count || 0,
                    alarm_id: alarm.id // Keep alarm ID for database updates
                };
                
                console.log(`   👤 User: ${userData.address}`);
                console.log(`      Wakeup: ${userData.wake_up_time} (${new Date(parseInt(userData.wake_up_time) * 1000)})`);
                console.log(`      Stake: ${userData.stake_amount}`);
                console.log(`      Snoozes: ${userData.snooze_count}`);
                
                return userData;
            });
            
            console.log(`🎉 Database fetch completed successfully`);
            return transformedAlarms;
            
        } catch (error) {
            console.error(`❌ Failed to fetch alarms from database:`, error);
            throw error;
        }
    }

    /**
     * Helper: Normalizes a value to a "0x..." hex string.
     * @param {string | number | bigint} val - The value to normalize.
     * @returns {string} The normalized hex string.
     */
    toHexString(val) {
        if (typeof val === 'string' && val.startsWith('0x')) {
            return val.toLowerCase();
        }
        return '0x' + BigInt(val).toString(16);
    }

    /**
     * Parses a "0x..." hex string or number into a BigInt.
     * @param {string | number | bigint} val - The value to parse.
     * @returns {bigint} The parsed BigInt.
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
     * Calculates the amount of stake a user gets back based on their snooze count.
     * @param {bigint | string} stakeAmount - The user's initial stake.
     * @param {number} snoozeCount - The number of times the user snoozed.
     * @returns {bigint} The amount of stake to be returned.
     */
    calculateStakeReturn(stakeAmount, snoozeCount) {
        const stake = BigInt(stakeAmount);
        switch (Number(snoozeCount)) {
            case 0:
                return stake;
            case 1:
                return (stake * this.SLASH_20_PERCENT) / this.PERCENT_BASE;
            case 2:
                return (stake * this.SLASH_50_PERCENT) / this.PERCENT_BASE;
            default:
                return this.SLASH_100_PERCENT;
        }
    }

    /**
     * Calculates the total amount of stake slashed from all users.
     * @param {Array<Object>} users - A list of user objects with stake and snooze info.
     * @returns {bigint} The total amount slashed.
     */
    calculateTotalSlashedAmount(users) {
        let totalSlashed = BigInt(0);
        for (const user of users) {
            const stakeAmount = this.toBigInt(user.stake_amount);
            const returnAmount = this.calculateStakeReturn(stakeAmount, user.snooze_count);
            totalSlashed += (stakeAmount - returnAmount);
        }
        return totalSlashed;
    }

    /**
     * Calculates the rewards for winning users (who didn't snooze).
     * Rewards are distributed proportionally to their stake from the total slashed amount.
     * @param {Array<Object>} users - A list of all user objects.
     * @returns {Array<Object>} An array of winner objects with their address and reward amount.
     */
    calculateRewards(users) {
        const winners = users.filter(u => Number(u.snooze_count) === 0);
        const totalSlashed = this.calculateTotalSlashedAmount(users);
        if (winners.length === 0 || totalSlashed === BigInt(0)) {
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
     * @param {Array<Object>} users - A list of user objects to validate.
     * @throws {Error} If any user data is invalid.
     */
    validateInputTypes(users) {
        for (const user of users) {
            if (!user.address || typeof user.address !== 'string' || !user.address.startsWith('0x')) {
                throw new Error(`Invalid address: ${JSON.stringify(user)}`);
            }
            const wakeUpTime = this.toBigInt(user.wake_up_time);
            if (wakeUpTime < 0n || wakeUpTime >= (1n << 64n)) {
                throw new Error(`wake_up_time out of u64: ${user.wake_up_time}`);
            }
            const snoozeCount = Number(user.snooze_count);
            if (snoozeCount < 0 || snoozeCount > 255) {
                throw new Error(`snooze_count out of u8: ${user.snooze_count}`);
            }
            const stakeAmount = this.toBigInt(user.stake_amount);
            if (stakeAmount < 0n || stakeAmount >= (1n << 256n)) {
                throw new Error(`stake_amount out of u256: ${user.stake_amount}`);
            }
        }
    }

    /**
     * Creates a cryptographic signature for a user's outcome using a private key.
     * @param {string} userAddress - The user's wallet address.
     * @param {string | number | bigint} wakeUpTime - The user's wake-up timestamp.
     * @param {number} snoozeCount - The user's snooze count.
     * @param {string} privateKey - The verifier's private key.
     * @returns {Object} An object containing the message hash, signature (r, s), and public key.
     */
    createOutcomeSignature(userAddress, wakeUpTime, snoozeCount, privateKey) {
        let normalizedPrivateKey = privateKey;
        if (!normalizedPrivateKey.startsWith('0x')) {
            normalizedPrivateKey = '0x' + normalizedPrivateKey;
        }

        const callerFelt = this.toBigInt(userAddress);
        const wakeFelt = this.toBigInt(wakeUpTime);
        const snoozeFelt = this.toBigInt(snoozeCount);

        const messageHash = hash.computePoseidonHashOnElements([callerFelt, wakeFelt, snoozeFelt]);
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
     * @param {string} userAddress - The user's wallet address.
     * @param {string | bigint} rewardAmount - The user's reward amount.
     * @returns {string} The hex string of the leaf hash.
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
     * Set merkle root on-chain using AVNU sponsored transaction
     * @param {number} day - Unix day
     * @param {number} period - 0=AM, 1=PM
     * @param {string} merkleRoot - Merkle root hash
     * @returns {Promise<string>} Transaction hash
     */
    async setMerkleRootOnChain(day, period, merkleRoot) {
        try {
            console.log(`🚀 ========== SETTING MERKLE ROOT ON-CHAIN ==========`);
            console.log(`📊 Pool: Day ${day}, Period ${period}`);
            console.log(`🌳 Merkle Root: ${merkleRoot}`);
            
            const alarmContractAddress = process.env.ALARM_CONTRACT_ADDRESS_STRK;
            if (!alarmContractAddress) {
                throw new Error('Missing ALARM_CONTRACT_ADDRESS_STRK environment variable');
            }
            
            console.log(`📋 Contract Address: ${alarmContractAddress}`);
            
            // Prepare contract call
            const calls = [{
                contractAddress: alarmContractAddress,
                entrypoint: 'set_reward_merkle_root',
                calldata: [
                    day.toString(),           // day as u64
                    period.toString(),       // period as u8 (0=AM, 1=PM)
                    merkleRoot               // reward_merkle_root as felt252
                ]
            }];
            
            console.log(`🔨 Contract Call Prepared:`);
            console.log(`   Function: set_reward_merkle_root`);
            console.log(`   Day: ${day} (type: ${typeof day})`);
            console.log(`   Period: ${period} (type: ${typeof period})`);
            console.log(`   Merkle Root: ${merkleRoot} (type: ${typeof merkleRoot})`);
            console.log(`🔍 Debug - Call Data:`);
            console.log(`   Day string: '${day.toString()}'`);
            console.log(`   Period string: '${period.toString()}'`);
            console.log(`   Merkle Root: '${merkleRoot}'`);
            
            // Execute transaction (sponsored or regular)
            let result;
            
            if (this.paymasterRpc) {
                console.log(`💰 Executing sponsored transaction via AVNU Paymaster...`);
                
                try {
                    const feesDetails = {
                        feeMode: { mode: 'sponsored' }
                    };
                    
                    result = await this.account.executePaymasterTransaction(
                        calls,
                        feesDetails
                    );
                } catch (error) {
                    console.log(`❌ Paymaster execution failed:`, error);
                    throw error;
                }
            } else {
                console.log(`💳 Executing regular transaction (gas fees will be paid)...`);
                
                try {
                    console.log(`🔍 About to execute with calls:`, JSON.stringify(calls, null, 2));
                    
                    // Bypass fee estimation by providing manual parameters for v8 RPC compatibility
                    console.log(`🔍 Executing transaction with manual fee parameters...`);
                    
                    result = await this.account.execute(calls, undefined, {
                        maxFee: '1000000000000000', // 0.001 ETH
                        version: 2 // Use V1 to avoid V3 compatibility issues
                    });
                } catch (error) {
                    console.log(`❌ Regular execution failed:`, error);
                    console.log(`❌ Error type:`, typeof error);
                    console.log(`❌ Error keys:`, Object.keys(error));
                    if (error.stack) console.log(`❌ Stack:`, error.stack);
                    throw error;
                }
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
                console.log(`===============================================`);
                return result.transaction_hash;
            } else {
                throw new Error(`Transaction failed with status: ${receipt.execution_status}`);
            }
            
        } catch (error) {
            console.error(`❌ ========== SET MERKLE ROOT FAILED ==========`);
            console.error(`🚫 Error: ${error.message}`);
            console.error(`📊 Failed Pool: Day ${day}, Period ${period}`);
            console.error(`🌳 Failed Merkle Root: ${merkleRoot}`);
            console.error(`==========================================`);
            throw error;
        }
    }

    /**
     * Store processed results back to database
     * @param {Array} users - User data with alarm_id
     * @param {Array} rewards - Reward data  
     * @param {Object} merkleTree - Merkle tree with proofs
     * @param {string} verifierPrivateKey - Private key for signatures
     * @returns {Promise<void>}
     */
    async storeResultsToDatabase(users, rewards, merkleTree, verifierPrivateKey) {
        try {
            console.log(`💾 ========== STORING RESULTS TO DATABASE ==========`);
            
            const alarmUpdates = [];
            const claimDataInserts = [];
            
            for (const user of users) {
                console.log(`📊 Processing user: ${user.address}`);
                
                // Find reward for this user
                const userReward = rewards.find(r => r.address === user.address);
                const rewardAmount = userReward ? userReward.reward_amount : "0";
                
                // ✅ FIXED: ALL users now have merkle proofs (tree includes everyone)
                const merkleProof = merkleTree.proofs[user.address] || [];
                
                // ✅ FIXED: Always use actual snooze count - no artificial penalties!
                // Single users with 0 snoozes should get full stake back
                const actualSnoozeCount = user.snooze_count;
                
                // Generate signature for this user (use ACTUAL snooze count)
                const signature = this.createOutcomeSignature(
                    user.address,
                    user.wake_up_time,
                    actualSnoozeCount,
                    verifierPrivateKey
                );
                
                // Calculate stake return using ACTUAL snooze count
                const stakeReturn = this.calculateStakeReturn(user.stake_amount, actualSnoozeCount);
                
                console.log(`   💰 Reward: ${rewardAmount}`);
                console.log(`   🔄 Stake Return: ${stakeReturn.toString()}`);
                console.log(`   🏆 Is Winner: ${actualSnoozeCount === 0} (actual snooze: ${actualSnoozeCount})`);
                
                // Prepare alarm table update
                alarmUpdates.push({
                    id: user.alarm_id,
                    claim_ready: true,
                    has_claimed: false,
                    snooze_count: actualSnoozeCount  // Keep actual snooze count
                });
                
                // Prepare claim data insert
                claimDataInserts.push({
                    alarm_id: user.alarm_id,
                    signature_r: signature.signature_r,
                    signature_s: signature.signature_s,
                    message_hash: signature.message_hash,
                    reward_amount: rewardAmount,
                    merkle_proof: JSON.stringify(merkleProof),
                    processed_at: new Date().toISOString()
                });
            }
            
            // Batch update alarms table
            console.log(`🔄 Updating ${alarmUpdates.length} alarm records...`);
            for (const update of alarmUpdates) {
                const { error } = await this.supabase
                    .from('alarms')
                    .update({
                        claim_ready: update.claim_ready,
                        has_claimed: update.has_claimed
                    })
                    .eq('id', update.id);
                
                if (error) {
                    throw new Error(`Failed to update alarm ${update.id}: ${error.message}`);
                }
            }
            console.log(`✅ Alarms table updated successfully`);
            
            // Batch insert claim data
            console.log(`📝 Inserting ${claimDataInserts.length} claim data records...`);
            const { error: insertError } = await this.supabase
                .from('user_claim_data')
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
     * Builds a Merkle tree from a list of leaf hashes.
     * @param {Array<Object>} leaves - An array of leaf objects with address and hash.
     * @returns {Object} An object containing the Merkle root and a map of proofs for each address.
     */
    buildMerkleTree(leaves) {
        if (leaves.length === 0) {
            // Generate a valid non-zero merkle root for empty reward case
            // Use hash of a standard "no rewards" message
            const noRewardsHash = hash.computePoseidonHashOnElements([BigInt('0x6e6f5f726577617264734040')]);  // "no_rewards@@"
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

                // For the proof, the other node's hash is added
                proofs[left.address].push(this.toHexString(right.hashBig));
                if (right.address !== left.address) {
                    proofs[right.address].push(this.toHexString(left.hashBig));
                }

                // Compute the hash of the parent node
                const parentHashBig = hash.computePoseidonHashOnElements([left.hashBig, right.hashBig]);
                nextLevel.push({ hashBig: parentHashBig });
            }
            currentLevel = nextLevel;
        }

        return { root: this.toHexString(currentLevel[0].hashBig), proofs };
    }

    /**
     * Process alarm pool: fetch from database, calculate outcomes, set merkle root on-chain, store results
     * @param {number} day - Unix day
     * @param {number} period - 0=AM, 1=PM
     * @returns {Promise<Object>} The processing results
     */
    async processAlarmPool(day, period) {
        try {
            console.log(`🚀 ========== PROCESSING ALARM POOL ==========`);
            console.log(`📅 Pool: Day ${day}, Period ${period}`);
            console.log(`🕐 Processing Time: ${new Date()}`);
            
            // Step 1: Fetch alarm data from database
            console.log(`\n🔍 STEP 1: FETCHING ALARM DATA`);
            const users = await this.fetchAlarmsFromDatabase(day, period);
            
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
            
            // ✅ FIXED: Include ALL users in merkle tree, not just winners
            // This ensures every user gets a merkle proof for contract validation
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
            
            // Step 5: Set merkle root on-chain (REQUIRED - must succeed!)
            console.log(`\n⛓️ STEP 5: SETTING MERKLE ROOT ON-CHAIN`);
            let txHash = null;
            try {
                txHash = await this.setMerkleRootOnChain(day, period, merkleTree.root);
                console.log(`✅ Merkle root set on-chain - TX: ${txHash}`);
            } catch (error) {
                console.error(`❌ CRITICAL: Blockchain transaction failed - CANNOT store to database`);
                console.error(`🚫 Error: ${error.message}`);
                console.error(`⚠️ Pool cannot be finalized until blockchain transaction succeeds`);
                throw new Error(`Blockchain finalization required before database storage: ${error.message}`);
            }
            
            // Step 6: Store results to database (only after blockchain success!)
            console.log(`\n💾 STEP 6: STORING RESULTS TO DATABASE`);
            console.log(`🔗 Blockchain confirmed - safe to mark claims as ready`);
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
            console.log(`🎯 Users can now claim their winnings through the app!`);
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
            console.error(`❌ ========== ALARM POOL PROCESSING FAILED ==========`);
            console.error(`📅 Failed Pool: Day ${day}, Period ${period}`);
            console.error(`🚫 Error: ${error.message}`);
            console.error(`🔍 Stack: ${error.stack}`);
            console.error(`================================================`);
            throw error;
        }
    }

    /**
     * Validates that the generated signatures match the expected message hashes.
     * This is a sanity check to ensure the backend logic is working correctly.
     * @param {Object} results - The results object from processAlarmData.
     * @returns {boolean} True if all signatures are valid, false otherwise.
     */
    validateSignatures(results) {
        console.log('🔍 Validating signatures...');
        for (const user of results.user_results) {
            const callerFelt = this.toBigInt(user.address);
            const wakeFelt = this.toBigInt(user.wake_up_time);
            const snoozeFelt = this.toBigInt(user.snooze_count);

            const expectedHashBig = hash.computePoseidonHashOnElements([callerFelt, wakeFelt, snoozeFelt]);
            const expectedHashHex = this.toHexString(expectedHashBig);

            if (expectedHashHex.toLowerCase() !== user.signature.message_hash.toLowerCase()) {
                console.error(`❌ Hash mismatch for user ${user.address}`);
                console.error(`    backend: ${expectedHashHex}`);
                console.error(`    output : ${user.signature.message_hash}`);
                return false;
            }
            console.log(`✅ Hash verified for user ${user.address}`);
        }
        console.log('✅ All message hashes verified!');
        return true;
    }
}

// Main runner function - Integrated Database & Blockchain Processing
async function main() {
    console.log('🏗️ ========== ALARM BACKEND PROCESSOR ==========');
    console.log('🕐 Started at:', new Date());
    
    const backend = new AlarmContractBackend();
    
    try {
        // Initialize all services
        await backend.initialize();
        
        // Get day and period from command line arguments or environment
        let day = process.argv[2] || process.env.DAY;
        let period = process.argv[3] || process.env.PERIOD;
        
        if (!day || !period || day === 'auto' || day === 'latest') {
            if (day === 'auto' || day === 'latest') {
                // Find latest pool with alarms
                console.log('🔍 Auto-detecting latest pool with alarms...');
                const latestPool = await backend.findLatestPoolWithAlarms();
                if (latestPool) {
                    day = latestPool.day;
                    period = latestPool.period;
                    console.log('✅ Using latest pool with alarms');
                } else {
                    console.log('⚠️ No alarms found, falling back to current time pool');
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
        if (isNaN(day) || isNaN(period) || period < 0 || period > 1) {
            throw new Error('Invalid day/period. Period must be 0 (AM) or 1 (PM)');
        }
        
        // Process the pool
        const results = await backend.processAlarmPool(day, period);
        
        if (results.success) {
            console.log('🎉 ========== FINAL SUCCESS SUMMARY ==========');
            console.log('📊 Pool Info:', JSON.stringify(results.pool_info, null, 2));
            console.log('🎯 Ready for claims: Database ✅ + Blockchain ✅ = Perfect sync!');
        } else {
            console.log(`⚠️ Processing completed with message: ${results.message}`);
        }
        
    } catch (error) {
        console.error('💥 ========== FATAL ERROR ==========');
        console.error('❌ Error:', error.message);
        console.error('🔍 Stack:', error.stack);
        console.error('🕐 Failed at:', new Date());
        console.error('================================');
        process.exit(1);
    }
}

// Usage information
function printUsage() {
    console.log('📖 ========== USAGE ==========');
    console.log('node alarm_backend.js [day] [period]');
    console.log('');
    console.log('Arguments:');
    console.log('  day    - Unix day number (calculated as Math.floor(wakeup_time / 86400))');
    console.log('         - OR "auto"/"latest" to find the most recent pool with alarms');
    console.log('  period - Pool period: 0 for AM (00:00-11:59), 1 for PM (12:00-23:59)');
    console.log('');
    console.log('Examples:');
    console.log('  node alarm_backend.js 20321 1    # Process specific day 20321, PM period');
    console.log('  node alarm_backend.js auto       # Auto-detect latest pool with alarms');
    console.log('  node alarm_backend.js latest     # Same as auto');
    console.log('  node alarm_backend.js            # Process current time pool');
    console.log('');
    console.log('Environment Variables Required:');
    console.log('  SUPABASE_URL, SUPABASE_SERVICE_KEY');
    console.log('  STARKNET_RPC_URL, AVNU_PAYMASTER_API_KEY');
    console.log('  DEPLOYER_ADDRESS, DEPLOYER_PRIVATE_KEY');
    console.log('  ALARM_CONTRACT_ADDRESS_STRK, VERIFIER_PRIVATE_KEY');
    console.log('=============================');
}

// Show help if requested
if (process.argv.includes('--help') || process.argv.includes('-h')) {
    printUsage();
    process.exit(0);
}

module.exports = { AlarmContractBackend };

if (require.main === module) {
    main();
}
