// time_lock_backend.js
const fs = require('fs');
const starknet = require('starknet');
const { hash, ec } = starknet;

/**
 * Backend logic for the Time Lock smart contract.
 * This class handles calculating stake returns, user rewards,
 * and generating the cryptographic proofs required for on-chain
 * transactions.
 */
class TimeLockContractBackend {
    constructor() {
        this.PERCENT_BASE = BigInt(100);
        this.SLASH_100_PERCENT = BigInt(0); // 100% slash for failed locks
        this.SLASH_0_PERCENT = BigInt(100); // 0% slash for successful locks
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
     * Calculates the amount of stake a user gets back based on their completion status.
     * @param {bigint | string} stakeAmount - The user's initial stake.
     * @param {boolean} completionStatus - Whether the user completed their lock successfully.
     * @returns {bigint} The amount of stake to be returned.
     */
    calculateStakeReturn(stakeAmount, completionStatus) {
        const stake = BigInt(stakeAmount);
        if (completionStatus) {
            // Completed successfully - return full stake (like snooze_count = 0 in alarm)
            return stake;
        } else {
            // Failed/exited early - return 0 (like snooze_count > 0 in alarm)
            return this.SLASH_100_PERCENT;
        }
    }

    /**
     * Calculates the total amount of stake slashed from all users.
     * @param {Array<Object>} users - A list of user objects with stake and completion info.
     * @returns {bigint} The total amount slashed.
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
     * Rewards are distributed proportionally to their stake from the total slashed amount.
     * @param {Array<Object>} users - A list of all user objects.
     * @returns {Array<Object>} An array of winner objects with their address and reward amount.
     */
    calculateRewards(users) {
        const winners = users.filter(u => u.completion_status === true);
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
            const startTime = this.toBigInt(user.start_time);
            if (startTime < 0n || startTime >= (1n << 64n)) {
                throw new Error(`start_time out of u64: ${user.start_time}`);
            }
            const duration = this.toBigInt(user.duration);
            if (duration < 300n || duration > 86400n) {
                throw new Error(`duration out of range (300-86400): ${user.duration}`);
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
     * @param {string} userAddress - The user's wallet address.
     * @param {string | number | bigint} startTime - The user's lock start timestamp.
     * @param {string | number | bigint} duration - The user's lock duration.
     * @param {boolean} completionStatus - The user's completion status.
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
     * Builds a Merkle tree from a list of leaf hashes.
     * @param {Array<Object>} leaves - An array of leaf objects with address and hash.
     * @returns {Object} An object containing the Merkle root and a map of proofs for each address.
     */
    buildMerkleTree(leaves) {
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

                // Compute the hash of the parent node
                const parentHashBig = hash.computePoseidonHashOnElements([left.hashBig, right.hashBig]);
                nextLevel.push({ hashBig: parentHashBig });
            }
            currentLevel = nextLevel;
        }

        return { root: this.toHexString(currentLevel[0].hashBig), proofs };
    }

    /**
     * Processes time lock data from an input file, calculates outcomes,
     * and generates a signed and verifiable JSON output file.
     * @param {string} inputFile - Path to the input JSON file.
     * @param {string} outputFile - Path to the output JSON file.
     * @returns {Promise<Object>} The final results object.
     */
    async processTimeLockData(inputFile, outputFile) {
        try {
            const inputData = JSON.parse(fs.readFileSync(inputFile, 'utf8'));
            const { pool_info, users } = inputData;

            // Validate all user inputs first
            this.validateInputTypes(users);

            const rewards = this.calculateRewards(users);
            const totalSlashed = this.calculateTotalSlashedAmount(users);

            const leaves = rewards.map(reward => ({
                address: reward.address,
                hash: this.createMerkleLeaf(reward.address, reward.reward_amount)
            }));
            const merkleTree = this.buildMerkleTree(leaves);

            const results = {
                pool_info: {
                    day: pool_info.day,
                    period: pool_info.period,
                    contract_address: pool_info.contract_address,
                    merkle_root: merkleTree.root,
                    total_slashed_amount: totalSlashed.toString()
                },
                user_results: []
            };

            for (const user of users) {
                const stakeReturn = this.calculateStakeReturn(user.stake_amount, user.completion_status);
                const signature = this.createOutcomeSignature(
                    user.address,
                    user.start_time,
                    user.duration,
                    user.completion_status,
                    pool_info.verifier_private_key
                );
                const userReward = rewards.find(r => r.address === user.address);
                const rewardAmount = userReward ? userReward.reward_amount : "0";
                const merkleProof = userReward ? merkleTree.proofs[user.address] || [] : [];
                results.user_results.push({
                    address: user.address,
                    start_time: user.start_time,
                    duration: user.duration,
                    stake_amount: user.stake_amount,
                    completion_status: user.completion_status,
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
                    is_winner: user.completion_status === true,
                    claim_ready: true
                });
            }

            fs.writeFileSync(outputFile, JSON.stringify(results, null, 2));
            return results;
        } catch (error) {
            console.error('Error processing time lock data:', error);
            throw error;
        }
    }

    /**
     * Validates that the generated signatures match the expected message hashes.
     * This is a sanity check to ensure the backend logic is working correctly.
     * @param {Object} results - The results object from processTimeLockData.
     * @returns {boolean} True if all signatures are valid, false otherwise.
     */
    validateSignatures(results) {
        console.log('🔍 Validating signatures...');
        for (const user of results.user_results) {
            const callerFelt = this.toBigInt(user.address);
            const startFelt = this.toBigInt(user.start_time);
            const durationFelt = this.toBigInt(user.duration);
            const completionFelt = user.completion_status ? BigInt(1) : BigInt(0);

            const expectedHashBig = hash.computePoseidonHashOnElements([callerFelt, startFelt, durationFelt, completionFelt]);
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
    const backend = new TimeLockContractBackend();
    const inputFile = './time_lock_inputs.json';
    const outputFile = './time_lock_outputs.json';

    try {
        const results = await backend.processTimeLockData(inputFile, outputFile);
        const isValid = backend.validateSignatures(results);
        if (isValid) {
            console.log('All data processed and validated successfully!');
            console.log(`Use ${outputFile} for claim_lock_rewards() calls`);
        } else {
            console.log('Some validations failed. Please check the output.');
        }
    } catch (error) {
        console.error('Fatal error:', error);
        process.exit(1);
    }
}

module.exports = { TimeLockContractBackend };

if (require.main === module) {
    main();
}
