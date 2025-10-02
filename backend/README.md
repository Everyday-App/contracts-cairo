# Alarm Contract Backend - Integrated Processor

This enhanced backend script processes alarm pools by:
1. 📊 Fetching alarm data from Supabase database  
2. 🌳 Building merkle trees and calculating rewards
3. ⛓️ Setting merkle root on-chain via AVNU sponsored transactions
4. 💾 Storing claim data back to database for user claims

## Prerequisites

1. **Node.js** >= 18.0.0
2. **Database Tables** - Run these SQL commands first:

```sql
-- Add claim fields to existing alarms table
ALTER TABLE alarms ADD COLUMN claim_ready boolean default false;
ALTER TABLE alarms ADD COLUMN has_claimed boolean default false;

-- Create claim history table  
CREATE TABLE user_claim_data (
  id uuid primary key default uuid_generate_v4(),
  alarm_id uuid references alarms(id) on delete cascade,
  signature_r text,
  signature_s text,
  message_hash text,
  reward_amount numeric(30,0) default 0,
  merkle_proof jsonb,
  processed_at timestamp with time zone default now(),
  claimed_at timestamp with time zone,
  created_at timestamp with time zone default now()
);
```

## Installation

```bash
cd contracts-cairo/backend
npm install
```

## Environment Variables

Update your `.env` file with these additional variables:

```bash
# Existing variables (already in your .env)
VERIFIER_PRIVATE_KEY=0x2a49cbb553b2b8d8ba20b3c9981ece2f4148f987f0665344e06e641a88f3cf5
DEPLOYER_PRIVATE_KEY=0x2a49cbb553b2b8d8ba20b3c9981ece2f4148f987f0665344e06e641a88f3cf5  
DEPLOYER_ADDRESS=0xf4405c134b92a05d0f9e80382b6ab32a32689b8aa1e25b7de02b284778aa86
ALARM_CONTRACT_ADDRESS_STRK=0x04c797252e91b807545bfc5c45b386d585b3852f94f10df38f8711c832e2c012
STARKNET_RPC_URL=https://starknet-sepolia.public.blastapi.io/rpc/v0_9

# ADD THESE (get from your services)
AVNU_PAYMASTER_API_KEY=your_avnu_api_key_here
AVNU_PAYMASTER_RPC=https://sepolia.paymaster.avnu.fi
SUPABASE_URL=your_supabase_url
SUPABASE_SERVICE_KEY=your_service_role_key_not_anon_key
```

## Usage

### Process Specific Pool
```bash
# Process day 20321, PM period (1)
node alarm_backend.js 20321 1

# Process day 20320, AM period (0)  
node alarm_backend.js 20320 0
```

### Process Current Time Pool
```bash
# Automatically determines current day/period
node alarm_backend.js
```

### Get Help
```bash
node alarm_backend.js --help
```

## How It Works

### 1. Pool Calculation
- **Day**: `Math.floor(wakeup_time / 86400)`
- **Period**: `Math.floor((wakeup_time % 86400) / 43200)`
  - `0` = AM (00:00-11:59)
  - `1` = PM (12:00-23:59)

### 2. Processing Steps
1. **Fetch** - Query `alarms` + `profiles` tables for pool users
2. **Calculate** - Determine rewards based on snooze counts  
3. **Merkle Tree** - Build tree for reward distribution
4. **Blockchain** - Set merkle root on-chain (sponsored by AVNU)
5. **Database** - Update `alarms.claim_ready = true` + insert `user_claim_data`

### 3. After Processing
- Users see "claim ready" notifications in app
- Users can claim winnings through Flutter app (also sponsored)
- Blockchain calls use AVNU paymaster = gasless for users

## Example Output

```bash
🚀 ========== PROCESSING ALARM POOL ==========
📅 Pool: Day 20321, Period 1
🕐 Processing Time: 2025-01-15T10:30:00.000Z

🔍 STEP 1: FETCHING ALARM DATA
✅ Found 5 alarms for this pool

💰 STEP 3: CALCULATING REWARDS  
🏆 Winners: 2
💸 Total Slashed: 17000000000000000000

🌳 STEP 4: BUILDING MERKLE TREE
✅ Merkle tree built with root: 0x96232e42505516d6ce9d7a749ae1a269479a75f24bb899f67584d6075d5413

⛓️ STEP 5: SETTING MERKLE ROOT ON-CHAIN
✅ Merkle root set on-chain - TX: 0x123abc...

💾 STEP 6: STORING RESULTS TO DATABASE
✅ Results stored to database successfully

🎉 ========== PROCESSING COMPLETED SUCCESSFULLY ==========
```

## Error Handling

The script includes comprehensive error handling and logging:
- Database connection errors
- Invalid pool data  
- Blockchain transaction failures
- Environment variable validation
- Input validation

## Monitoring

All operations are logged with emojis and timestamps for easy monitoring:
- 🔍 Database queries
- 🌳 Merkle tree operations  
- ⛓️ Blockchain transactions
- 💾 Database updates
- ❌ Error details

## Integration with App

After backend processes a pool:
1. Flutter app queries `alarms` table (existing queries unchanged)
2. App shows notification for `claim_ready = true` alarms
3. User taps → App calls `claimWinnings()` (to be added to blockchain_service.dart)
4. Claim uses data from `user_claim_data` table
5. After successful claim → `has_claimed = true`
