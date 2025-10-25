// alarm_reward_calculator.js
const fs = require('fs');
const starknet = require('starknet');
const { hash, ec } = starknet;

/**
 * Reward and fee calculator for the Alarm Clock smart contract.
 * This class handles calculating protocol fees, user rewards,
 * stake returns, and generating merkle trees for on-chain
 * reward distribution.
 */
class AlarmRewardCalculator {
    constructor() {
        this.PERCENT_BASE = BigInt(100);
        this.SLASH_20_PERCENT = BigInt(80);
        this.SLASH_50_PERCENT = BigInt(50);
        this.SLASH_100_PERCENT = BigInt(0);
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
     * Calculates protocol fees and rewards for winning users (who didn't snooze).
     * Rewards are distributed proportionally to their stake from the total reward pool.
     * The total reward pool includes both the slashed amount from losers and 
     * the accumulated rewards from edit/delete operations.
     * @param {Array<Object>} users - A list of all user objects.
     * @param {BigInt} existingPoolReward - The existing pool reward from edit/delete operations.
     * @returns {Object} Object containing protocol fees, reward details and new rewards from losers.
     */
    calculateProtocolFeesAndRewards(users, existingPoolReward = BigInt(0)) {
        const winners = users.filter(u => Number(u.snooze_count) === 0);
        const newRewardsFromLosers = this.calculateTotalSlashedAmount(users);
        
        // Total reward pool = slashed amount from losers + existing pool reward from edit/delete
        const totalRewardPool = newRewardsFromLosers + existingPoolReward;
        
        if (winners.length === 0 || totalRewardPool === BigInt(0)) {
            return {
                rewards: [],
                newRewardsFromLosers,
                totalRewardPool,
                protocolFees: BigInt(0),
                rewardsForWinners: BigInt(0)
            };
        }

        const totalWinnerStake = winners.reduce((sum, w) => sum + this.toBigInt(w.stake_amount), BigInt(0));
        if (totalWinnerStake === BigInt(0)) {
            return {
                rewards: [],
                newRewardsFromLosers,
                totalRewardPool,
                protocolFees: BigInt(0),
                rewardsForWinners: BigInt(0)
            };
        }

        // Calculate 10% protocol fees from total reward pool
        const protocolFees = (totalRewardPool * BigInt(10)) / BigInt(100);
        
        // Calculate 90% rewards for winners
        const rewardsForWinners = totalRewardPool - protocolFees;

        const rewards = winners.map(winner => {
            const winnerStake = this.toBigInt(winner.stake_amount);
            const proportionalReward = (rewardsForWinners * winnerStake) / totalWinnerStake;
            return {
                address: winner.address,
                reward_amount: proportionalReward.toString()
            };
        });
        
        return {
            rewards,
            newRewardsFromLosers,
            totalRewardPool,
            protocolFees: protocolFees.toString(),
            rewardsForWinners: rewardsForWinners.toString()
        };
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
     * Processes alarm data, calculates protocol fees and rewards,
     * generates merkle tree, and creates signed output for claim transactions.
     * @param {string} inputFile - Path to the input JSON file.
     * @param {string} outputFile - Path to the output JSON file.
     * @param {BigInt} existingPoolReward - Optional existing pool reward from contract.
     * @returns {Promise<Object>} The final results object with fees, rewards, and merkle tree.
     */
    async processRewardsAndGenerateMerkleTree(inputFile, outputFile, existingPoolReward = BigInt(0)) {
        try {
            const inputData = JSON.parse(fs.readFileSync(inputFile, 'utf8'));
            const { pool_info, users } = inputData;

            // Validate all user inputs first
            this.validateInputTypes(users);

            // Calculate protocol fees and rewards including existing pool reward from edit/delete operations
            const rewardData = this.calculateProtocolFeesAndRewards(users, existingPoolReward);
            const { rewards, newRewardsFromLosers, totalRewardPool, protocolFees, rewardsForWinners } = rewardData;

            const leaves = rewards.map(reward => ({
                address: reward.address,
                hash: this.createMerkleLeaf(reward.address, reward.reward_amount)
            }));
            const merkleTree = this.generateMerkleTree(leaves);

            const results = {
                pool_info: {
                    day: pool_info.day,
                    period: pool_info.period,
                    contract_address: pool_info.contract_address,
                    merkle_root: merkleTree.root,
                    new_rewards_from_losers: newRewardsFromLosers.toString(),
                    existing_pool_reward: existingPoolReward.toString(),
                    total_reward_pool: totalRewardPool.toString(),
                    protocol_fees: protocolFees,
                    rewards_for_winners: rewardsForWinners
                },
                user_results: []
            };

            for (const user of users) {
                const stakeReturn = this.calculateStakeReturn(user.stake_amount, user.snooze_count);
                const signature = this.createOutcomeSignature(
                    user.address,
                    user.wake_up_time,
                    user.snooze_count,
                    pool_info.verifier_private_key
                );
                const userReward = rewards.find(r => r.address === user.address);
                const rewardAmount = userReward ? userReward.reward_amount : "0";
                const merkleProof = userReward ? merkleTree.proofs[user.address] || [] : [];
                results.user_results.push({
                    address: user.address,
                    wake_up_time: user.wake_up_time,
                    snooze_count: user.snooze_count,
                    stake_amount: user.stake_amount,
                    stake_return_amount: stakeReturn.toString(),
                    reward_amount: rewardAmount,
                    total_payout: (BigInt(stakeReturn) + BigInt(rewardAmount)).toString(),
                    signature: {
                        r: signature.signature_r,
                        s: signature.signature_s,
                        message_hash: signature.message_hash,
                        public_key: signature.public_key
                    },
                    merkle_proof: merkleProof,
                    is_winner: Number(user.snooze_count) === 0,
                    claim_ready: true
                });
            }

            fs.writeFileSync(outputFile, JSON.stringify(results, null, 2));
            return results;
        } catch (error) {
            console.error('Error processing rewards and generating merkle tree:', error);
            throw error;
        }
    }

    /**
     * Validates that the generated signatures match the expected message hashes.
     * This is a sanity check to ensure the reward calculation logic is working correctly.
     * @param {Object} results - The results object from processRewardsAndGenerateMerkleTree.
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

// Main runner function
async function main() {
    const rewardCalculator = new AlarmRewardCalculator();
    
    // Allow custom input/output files via command line arguments
    const args = process.argv.slice(2);
    let inputFile = './inputs/alarm_inputs.json';
    let outputFile = './outputs/alarm_outputs.json';
    let existingPoolReward = BigInt(0);
    
    // Parse command line arguments
    for (let i = 0; i < args.length; i++) {
        const arg = args[i];
        if (arg === '--help' || arg === '-h') {
            console.log(`
🌅 Alarm Reward Calculator

Usage: node alarm_reward_calculator.js [options] [existing_pool_reward]

Options:
  --input <file>     Input JSON file (default: ./inputs/alarm_inputs.json)
  --output <file>    Output JSON file (default: ./outputs/alarm_outputs.json)
  --help, -h         Show this help message

Arguments:
  existing_pool_reward  Optional existing pool reward amount (default: 0)

Examples:
  node alarm_reward_calculator.js
  node alarm_reward_calculator.js 1000000000000000000
  node alarm_reward_calculator.js --input ./inputs/alarm_inputs_edit_delete.json --output ./outputs/alarm_outputs_edit_delete.json
  node alarm_reward_calculator.js --input ./inputs/alarm_inputs_edit_delete.json 5000000000000000000
            `);
            process.exit(0);
        } else if (arg === '--input' && i + 1 < args.length) {
            inputFile = args[i + 1];
            i++; // Skip next argument as it's the input file
        } else if (arg === '--output' && i + 1 < args.length) {
            outputFile = args[i + 1];
            i++; // Skip next argument as it's the output file
        } else if (!arg.startsWith('--') && !isNaN(arg)) {
            // If it's a number and not a flag, treat it as existing pool reward
            existingPoolReward = BigInt(arg);
        }
    }

    try {
        // Read input data to get pool information
        const inputData = JSON.parse(fs.readFileSync(inputFile, 'utf8'));
        const { pool_info } = inputData;
        const inputPoolReward = pool_info.existing_pool_reward;
        
        console.log(`📁 Input file: ${inputFile}`);
        console.log(`📁 Output file: ${outputFile}`);
        console.log(`Calculating protocol fees and rewards for day ${pool_info.day}, period ${pool_info.period}`);
        
        // Use existing pool reward from input file if present, otherwise use command line argument
        if (inputPoolReward !== undefined) {
            existingPoolReward = BigInt(inputPoolReward);
            console.log(`💰 Using existing pool reward from input file: ${existingPoolReward.toString()}`);
        } else if (existingPoolReward > 0) {
            console.log(`💰 Using provided existing pool reward: ${existingPoolReward.toString()}`);
        } else {
            console.log(`💰 No existing pool reward provided. Using 0.`);
            
            // TODO: In production, this would fetch from the contract:
            // const provider = new starknet.Provider({ ... });
            // const contract = new starknet.Contract(abi, pool_info.contract_address, provider);
            // const poolInfo = await contract.get_pool_info(pool_info.day, pool_info.period);
            // existingPoolReward = BigInt(poolInfo.pool_reward);
        }
        
        const results = await rewardCalculator.processRewardsAndGenerateMerkleTree(inputFile, outputFile, existingPoolReward);
        const isValid = rewardCalculator.validateSignatures(results);
        
        if (isValid) {
            console.log('✅ Protocol fees and rewards calculated successfully!');
            console.log(`📊 Existing pool reward: ${results.pool_info.existing_pool_reward}`);
            console.log(`💰 New rewards from losers: ${results.pool_info.new_rewards_from_losers}`);
            console.log(`🏆 Total reward pool: ${results.pool_info.total_reward_pool}`);
            console.log(`💸 Protocol fees: ${results.pool_info.protocol_fees}`);
            console.log(`📄 Use ${outputFile} for claim_winnings() calls`);
            console.log(`🌳 Merkle tree generated with root: ${results.pool_info.merkle_root}`);
            console.log(`📈 Use the following for set_merkle_root_for_pool():`);
            console.log(`   merkle_root: ${results.pool_info.merkle_root}`);
            console.log(`   new_rewards: ${results.pool_info.new_rewards_from_losers}`);
            console.log(`   protocol_fees: ${results.pool_info.protocol_fees}`);
        } else {
            console.log('❌ Some validations failed. Please check the output.');
        }
    } catch (error) {
        console.error('Fatal error:', error);
        process.exit(1);
    }
}

module.exports = { AlarmRewardCalculator };

if (require.main === module) {
    main();
}
