// phone_lock_reward_calculator.js
const fs = require('fs');
const starknet = require('starknet');
const { hash, ec } = starknet;

/**
 * Reward and fee calculator for the Phone Lock smart contract.
 * This class handles calculating protocol fees, user rewards,
 * stake returns, and generating merkle trees for on-chain
 * reward distribution.
 * 
 * Phone Lock uses four 6-hour pools per day:
 * - Pool 0: 00:00 - 06:00 (Early morning)
 * - Pool 1: 06:00 - 12:00 (Morning) 
 * - Pool 2: 12:00 - 18:00 (Afternoon)
 * - Pool 3: 18:00 - 24:00 (Evening)
 */
class PhoneLockRewardCalculator {
    constructor() {
        this.PERCENT_BASE = BigInt(100);
        this.PROTOCOL_FEE_PERCENT = BigInt(10);
        this.WINNER_REWARD_PERCENT = BigInt(90);
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
        if (typeof val === 'string') {
            if (val.startsWith('0x')) {
                return BigInt(val);
            }
            // Handle decimal strings
            return BigInt(val);
        }
        return BigInt(val);
    }

    /**
     * Calculates which 6-hour pool a user belongs to based on their start time.
     * @param {string | number | bigint} startTime - The user's start time.
     * @returns {Object} Object containing day and period (0-3).
     */
    calculatePoolFromStartTime(startTime) {
        const start = this.toBigInt(startTime);
        const ONE_DAY_IN_SECONDS = BigInt(86400); // 24 * 60 * 60
        const SIX_HOURS_IN_SECONDS = BigInt(21600); // 6 * 60 * 60
        
        const day = start / ONE_DAY_IN_SECONDS;
        const period = (start % ONE_DAY_IN_SECONDS) / SIX_HOURS_IN_SECONDS;
        
        return {
            day: day.toString(),
            period: Number(period),
            poolName: this.getPoolName(Number(period))
        };
    }

    /**
     * Gets the human-readable name for a pool period.
     * @param {number} period - The period (0-3).
     * @returns {string} The pool name.
     */
    getPoolName(period) {
        const poolNames = [
            'Early Morning (00:00-06:00)',
            'Morning (06:00-12:00)',
            'Afternoon (12:00-18:00)',
            'Evening (18:00-24:00)'
        ];
        return poolNames[period] || 'Unknown Pool';
    }

    /**
     * Calculates the amount of stake a user gets back based on their completion status.
     * @param {bigint | string} stakeAmount - The user's initial stake.
     * @param {boolean} completionStatus - Whether the user completed their lock successfully.
     * @returns {bigint} The amount of stake to be returned.
     */
    calculateStakeReturn(stakeAmount, completionStatus) {
        const stake = this.toBigInt(stakeAmount);
        return completionStatus ? stake : BigInt(0);
    }

    /**
     * Calculates the total amount of stake slashed from all users who failed.
     * @param {Array<Object>} users - A list of user objects with stake and completion info.
     * @returns {bigint} The total amount slashed from losers.
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
     * Calculates the weighted score for a user based on stake amount and duration.
     * Higher stake and longer duration result in higher weight.
     * @param {bigint} stakeAmount - The user's stake amount.
     * @param {bigint} duration - The user's lock duration in seconds.
     * @returns {bigint} The weighted score for this user.
     */
    calculateUserWeight(stakeAmount, duration) {
        // Weight = stake_amount * duration
        // This gives more weight to users who stake more AND lock for longer
        return stakeAmount * duration;
    }

    /**
     * Calculates protocol fees and rewards for winning users (who completed successfully).
     * Rewards are distributed proportionally based on weighted scores (stake * duration).
     * The total reward pool comes from the slashed amount from losers.
     * @param {Array<Object>} users - A list of all user objects.
     * @returns {Object} Object containing protocol fees, reward details and new rewards from losers.
     */
    calculateProtocolFeesAndRewards(users) {
        const winners = users.filter(u => u.completion_status === true);
        const newRewardsFromLosers = this.calculateTotalSlashedAmount(users);
        
        if (winners.length === 0 || newRewardsFromLosers === BigInt(0)) {
            return {
                rewards: [],
                newRewardsFromLosers,
                totalRewardPool: newRewardsFromLosers,
                protocolFees: BigInt(0),
                rewardsForWinners: BigInt(0)
            };
        }

        // Calculate weighted scores for all winners
        const winnersWithWeights = winners.map(winner => {
            const stakeAmount = this.toBigInt(winner.stake_amount);
            const duration = this.toBigInt(winner.duration);
            const weight = this.calculateUserWeight(stakeAmount, duration);
            
            return {
                ...winner,
                weight: weight
            };
        });

        const totalWinnerWeight = winnersWithWeights.reduce((sum, w) => sum + w.weight, BigInt(0));
        if (totalWinnerWeight === BigInt(0)) {
            return {
                rewards: [],
                newRewardsFromLosers,
                totalRewardPool: newRewardsFromLosers,
                protocolFees: BigInt(0),
                rewardsForWinners: BigInt(0)
            };
        }

        // Calculate 10% protocol fees from total reward pool (losers' slashed amount)
        const protocolFees = (newRewardsFromLosers * this.PROTOCOL_FEE_PERCENT) / this.PERCENT_BASE;
        
        // Calculate 90% rewards for winners
        const rewardsForWinners = newRewardsFromLosers - protocolFees;

        const rewards = winnersWithWeights.map(winner => {
            // Distribute rewards based on weighted score (stake * duration)
            const proportionalReward = (rewardsForWinners * winner.weight) / totalWinnerWeight;
            return {
                address: winner.address,
                reward_amount: proportionalReward.toString(),
                weight: winner.weight.toString(),
                stake_amount: winner.stake_amount,
                duration: winner.duration
            };
        });
        
        return {
            rewards,
            newRewardsFromLosers,
            totalRewardPool: newRewardsFromLosers,
            protocolFees: protocolFees.toString(),
            rewardsForWinners: rewardsForWinners.toString()
        };
    }

    /**
     * Validates the input types and ranges for user data.
     * Note: Period validation (0-3 for 6-hour pools) is handled by the contract.
     * @param {Array<Object>} users - A list of user objects to validate.
     * @throws {Error} If any user data is invalid.
     */
    validateUserData(users) {
        if (!Array.isArray(users)) {
            throw new Error('Users must be an array');
        }

        for (const user of users) {
            if (!user.address || typeof user.address !== 'string') {
                throw new Error('User address must be a non-empty string');
            }
            if (!user.stake_amount || this.toBigInt(user.stake_amount) <= 0) {
                throw new Error('User stake_amount must be a positive number');
            }
            if (typeof user.completion_status !== 'boolean') {
                throw new Error('User completion_status must be a boolean');
            }
            if (!user.start_time || this.toBigInt(user.start_time) <= 0) {
                throw new Error('User start_time must be a positive number');
            }
            if (!user.duration || this.toBigInt(user.duration) <= 0) {
                throw new Error('User duration must be a positive number');
            }
        }
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
     * Generates a Merkle tree from a list of leaf hashes for reward distribution.
     * @param {Array<Object>} leaves - An array of leaf objects with address and hash.
     * @returns {Object} An object containing the Merkle root and a map of proofs for each address.
     */
    generateMerkleTree(leaves) {
        if (leaves.length === 0) {
            return { root: "0x0", proofs: {} };
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

                // Compute the hash of the parent node using sorted pairs (OpenZeppelin standard)
                const [sorted_a, sorted_b] = left.hashBig < right.hashBig 
                    ? [left.hashBig, right.hashBig] 
                    : [right.hashBig, left.hashBig];
                const parentHashBig = hash.computePoseidonHashOnElements([sorted_a, sorted_b]);
                nextLevel.push({ hashBig: parentHashBig });
            }
            currentLevel = nextLevel;
        }

        return { root: this.toHexString(currentLevel[0].hashBig), proofs };
    }


    /**
     * Creates a cryptographic signature for a user's outcome using a private key.
     * @param {string} userAddress - The user's wallet address.
     * @param {string | number | bigint} startTime - The user's start time.
     * @param {string | number | bigint} duration - The user's lock duration.
     * @param {boolean} completionStatus - Whether the user completed successfully.
     * @param {string} privateKey - The verifier's private key.
     * @returns {Object} An object containing the message hash, signature (r, s), and public key.
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
     * Processes the phone lock data and generates all necessary outputs.
     * @param {Object} inputData - The input data containing pool info and users.
     * @returns {Object} The processed results.
     */
    processRewardsAndGenerateMerkleTree(inputData) {
        console.log('🔍 Processing phone lock rewards and generating merkle tree...');
        
        const { pool_info, users } = inputData;
        console.log(`📊 Processing ${users.length} users`);
        
        // Validate input data
        this.validateUserData(users);
        
        // Calculate actual pool info from first user's start time
        const actualPoolInfo = this.calculatePoolFromStartTime(users[0].start_time);
        console.log(`🏊 Calculated pool: ${actualPoolInfo.poolName} (Day ${actualPoolInfo.day}, Period ${actualPoolInfo.period})`);
        
        // Calculate protocol fees and rewards
        console.log('💰 Calculating protocol fees and rewards...');
        const feeAndRewardData = this.calculateProtocolFeesAndRewards(users);
        console.log(`📈 Found ${feeAndRewardData.rewards.length} winners`);
        
        // Create leaves for merkle tree
        const leaves = feeAndRewardData.rewards.map(reward => ({
            address: reward.address,
            hash: this.createMerkleLeaf(reward.address, reward.reward_amount)
        }));
        
        // Generate merkle tree with proofs
        const merkleTree = this.generateMerkleTree(leaves);
        
        // Process individual user results
        const userResults = [];
        for (const user of users) {
            const stakeReturn = this.calculateStakeReturn(user.stake_amount, user.completion_status);
            const isWinner = user.completion_status === true;
            
            // Generate signature for this user
            const signature = this.createOutcomeSignature(
                user.address,
                user.start_time,
                user.duration,
                user.completion_status,
                pool_info.verifier_private_key
            );
            
            // Find reward amount for winners
            let rewardAmount = BigInt(0);
            let merkleProof = [];
            
            if (isWinner) {
                const winnerReward = feeAndRewardData.rewards.find(r => r.address === user.address);
                if (winnerReward) {
                    rewardAmount = this.toBigInt(winnerReward.reward_amount);
                    merkleProof = merkleTree.proofs[user.address] || [];
                }
            }
            
            const totalPayout = stakeReturn + rewardAmount;
            
            userResults.push({
                address: user.address,
                start_time: user.start_time,
                duration: user.duration,
                stake_amount: user.stake_amount,
                completion_status: user.completion_status,
                stake_return_amount: stakeReturn.toString(),
                reward_amount: rewardAmount.toString(),
                total_payout: totalPayout.toString(),
                signature: {
                    r: signature.signature_r,
                    s: signature.signature_s,
                    message_hash: signature.message_hash,
                    public_key: signature.public_key
                },
                merkle_proof: merkleProof,
                is_winner: isWinner,
                claim_ready: true
            });
        }
        
        // Create final output using actual calculated pool info
        const output = {
            pool_info: {
                day: actualPoolInfo.day,
                period: actualPoolInfo.period,
                contract_address: pool_info.contract_address,
                merkle_root: merkleTree.root,
                total_slashed_amount: feeAndRewardData.newRewardsFromLosers.toString()
            },
            protocol_fees: feeAndRewardData.protocolFees,
            rewards_for_winners: feeAndRewardData.rewardsForWinners,
            user_results: userResults
        };
        
        console.log('✅ Phone lock rewards processed successfully!');
        console.log(`📊 Total slashed from losers: ${feeAndRewardData.newRewardsFromLosers.toString()} wei`);
        console.log(`💰 Protocol fees (10%): ${feeAndRewardData.protocolFees} wei`);
        console.log(`🎁 Rewards for winners (90%): ${feeAndRewardData.rewardsForWinners} wei`);
        console.log(`🌳 Merkle root: ${merkleTree.root}`);
        
        // Show weighted distribution details
        console.log('\n⚖️ Weighted Distribution Details:');
        if (feeAndRewardData.rewards && feeAndRewardData.rewards.length > 0) {
            feeAndRewardData.rewards.forEach((reward, index) => {
                const weight = BigInt(reward.weight);
                const stake = BigInt(reward.stake_amount);
                const duration = BigInt(reward.duration);
                const rewardAmount = BigInt(reward.reward_amount);
                
                console.log(`  Winner ${index + 1}: ${reward.address.slice(0, 10)}...`);
                console.log(`    Stake: ${(stake / BigInt(10**18)).toString()} STRK`);
                console.log(`    Duration: ${(Number(duration) / 3600).toFixed(1)} hours`);
                console.log(`    Weight: ${weight.toString()} (stake × duration)`);
                console.log(`    Reward: ${(rewardAmount / BigInt(10**18)).toString()} STRK`);
                console.log('');
            });
        } else {
            console.log('  No winners found.');
        }
        
        console.log(`🏊 Final Pool: ${actualPoolInfo.poolName} (Day ${actualPoolInfo.day}, Period ${actualPoolInfo.period})`);
        
        return output;
    }

    /**
     * Main function to run the reward calculation process.
     */
    async run() {
        try {
            console.log('🚀 Starting Phone Lock Reward Calculator...');
            
            // Parse command line arguments
            const args = process.argv.slice(2);
            let inputFile = './inputs/phone_lock_inputs.json';
            let outputFile = './outputs/phone_lock_outputs.json';
            
            for (let i = 0; i < args.length; i++) {
                if (args[i] === '--input' || args[i] === '-i') {
                    inputFile = args[i + 1];
                    i++;
                } else if (args[i] === '--output' || args[i] === '-o') {
                    outputFile = args[i + 1];
                    i++;
                } else if (args[i] === '--help' || args[i] === '-h') {
                    console.log('Usage: node phone_lock_reward_calculator.js [options]');
                    console.log('Options:');
                    console.log('  --input, -i <file>    Input JSON file (default: ./inputs/phone_lock_inputs.json)');
                    console.log('  --output, -o <file>   Output JSON file (default: ./outputs/phone_lock_outputs.json)');
                    console.log('  --help, -h            Show this help message');
                    return;
                }
            }
            
            console.log(`📖 Reading input from: ${inputFile}`);
            
            // Read input file
            const inputData = JSON.parse(fs.readFileSync(inputFile, 'utf8'));
            
            // Process the data
            const results = this.processRewardsAndGenerateMerkleTree(inputData);
            
            // Write output file
            console.log(`💾 Writing output to: ${outputFile}`);
            fs.writeFileSync(outputFile, JSON.stringify(results, null, 2));
            
            console.log('🎉 Phone lock reward calculation completed successfully!');
            
        } catch (error) {
            console.error('❌ Error:', error.message);
            process.exit(1);
        }
    }
}

// Run the calculator if this file is executed directly
if (require.main === module) {
    const calculator = new PhoneLockRewardCalculator();
    calculator.run();
}

module.exports = PhoneLockRewardCalculator;
