# Backend Processors - Alarm & Focus Lock

This backend includes two integrated processors for habit-based staking:

## Alarm Backend (`alarm_backend.js`)
Processes alarm pools by:
1. 📊 Fetching alarm data from Supabase database  
2. 🌳 Building merkle trees and calculating rewards
3. ⛓️ Setting merkle root on-chain via AVNU sponsored transactions
4. 💾 Storing claim data back to database for user claims

## Focus Lock Backend (`focus_lock_backend.js`)
Processes focus lock pools by:
1. 📊 Fetching focus lock data from Supabase database
2. 🌳 Building merkle trees and calculating stake returns
3. ⛓️ Setting merkle root on-chain via AVNU sponsored transactions
4. 💾 Storing claim data back to database for user claims

## Prerequisites

1. **Node.js** >= 18.0.0
2. **Database Tables** - Run migrations from `supabase_migrations/`:
   - `add_focus_locks_table.sql` - Creates focus_locks and user_claim_data_locks tables
   - Or manually run:

```sql
-- Alarm Tables (if not exists)
ALTER TABLE alarms ADD COLUMN claim_ready boolean default false;
ALTER TABLE alarms ADD COLUMN has_claimed boolean default false;

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

-- Focus Lock Tables
CREATE TABLE focus_locks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade,
  habit_name text not null,
  duration_minutes integer not null check (duration_minutes between 5 and 240),
  stake_amount numeric(10,2) not null default 0,
  start_time bigint not null,
  end_time bigint not null,
  completion_status boolean,
  is_active boolean not null default true,
  claim_ready boolean not null default false,
  has_claimed boolean not null default false,
  blockchain_stake_tx_hash text,
  blockchain_claim_tx_hash text,
  day integer not null,
  period smallint not null check (period between 0 and 3),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

CREATE TABLE user_claim_data_locks (
  id uuid primary key default gen_random_uuid(),
  focus_lock_id uuid references focus_locks(id) on delete cascade,
  signature_r text not null,
  signature_s text not null,
  message_hash text not null,
  reward_amount numeric(10,2) not null,
  merkle_proof jsonb not null,
  processed_at timestamptz not null default now(),
  claimed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
```

## Installation

```bash
cd contracts-cairo/backend
npm install
```

## Environment Variables

Update your `.env` file (or `doc_2025-09-09_20-45-53.env`):

```bash
# Blockchain Configuration
VERIFIER_PRIVATE_KEY=0x2a49cbb553b2b8d8ba20b3c9981ece2f4148f987f0665344e06e641a88f3cf5
VERIFIER_ADDRESS=0xf4405c134b92a05d0f9e80382b6ab32a32689b8aa1e25b7de02b284778aa86
DEPLOYER_PRIVATE_KEY=0x2a49cbb553b2b8d8ba20b3c9981ece2f4148f987f0665344e06e641a88f3cf5  
DEPLOYER_ADDRESS=0xf4405c134b92a05d0f9e80382b6ab32a32689b8aa1e25b7de02b284778aa86
STARKNET_RPC_URL=https://starknet-sepolia.public.blastapi.io/rpc/v0_8

# Contract Addresses
ALARM_CONTRACT_ADDRESS_STRK=0x05a99933dd192a1e3266b1de938169289cbc96a53aa39504627a0f8a447d19fe
TIME_LOCK_CONTRACT_ADDRESS=0x07c7c797f8b5be4a9a552f4ac46fb00a9c095e19a15c9610006c641cff409a79

# AVNU Paymaster (Optional - for gasless transactions)
AVNU_PAYMASTER_API_KEY=your_avnu_api_key_here
AVNU_PAYMASTER_RPC=https://sepolia.paymaster.avnu.fi

# Supabase (Required)
SUPABASE_URL=your_supabase_url
SUPABASE_SERVICE_KEY=your_service_role_key_not_anon_key
```

## Usage

### Alarm Backend

#### Process Specific Pool
```bash
# Process day 20321, PM period (1)
node alarm_backend.js 20321 1

# Process day 20320, AM period (0)  
node alarm_backend.js 20320 0
```

#### Auto Mode
```bash
# Automatically determines current day/period
node alarm_backend.js auto
```

#### Get Help
```bash
node alarm_backend.js --help
```

### Focus Lock Backend

#### Process Specific Pool
```bash
# Process day 20373, period 0 (0-6h)
node focus_lock_backend.js 20373 0

# Process day 20373, period 1 (6-12h)
node focus_lock_backend.js 20373 1

# Process day 20373, period 2 (12-18h)
node focus_lock_backend.js 20373 2

# Process day 20373, period 3 (18-24h)
node focus_lock_backend.js 20373 3
```

#### Auto Mode
```bash
# Automatically determines current day/period
node focus_lock_backend.js auto
```

#### Get Help
```bash
node focus_lock_backend.js --help
```

## How It Works

### 1. Pool Calculation

#### Alarms (12-hour periods)
- **Day**: `Math.floor(wakeup_time / 86400)`
- **Period**: `Math.floor((wakeup_time % 86400) / 43200)`
  - `0` = AM (00:00-11:59)
  - `1` = PM (12:00-23:59)

#### Focus Locks (6-hour periods)
- **Day**: `Math.floor(start_time / 86400)`
- **Period**: `Math.floor((start_time % 86400) / 21600)`
  - `0` = 0-6h (00:00-05:59)
  - `1` = 6-12h (06:00-11:59)
  - `2` = 12-18h (12:00-17:59)
  - `3` = 18-24h (18:00-23:59)

**Important**: Backend queries by `day` and `period` columns (not time ranges) to match what the contract stores.

### 2. Processing Steps

#### Alarm Backend
1. **Fetch** - Query `alarms` + `profiles` tables for pool users
2. **Calculate** - Determine rewards based on snooze counts  
3. **Merkle Tree** - Build tree for reward distribution
4. **Blockchain** - Set merkle root on-chain (sponsored by AVNU)
5. **Database** - Update `alarms.claim_ready = true` + insert `user_claim_data`

#### Focus Lock Backend
1. **Fetch** - Query `focus_locks` + `profiles` tables for pool users
2. **Calculate** - Determine stake returns based on completion status
   - Completed (`completion_status = true`) → Get stake back
   - Failed/Exited (`completion_status = false`) → Stake slashed (goes to pool)
3. **Merkle Tree** - Build tree for reward distribution
4. **Blockchain** - Set merkle root on-chain (sponsored by AVNU)
5. **Database** - Update `focus_locks.claim_ready = true` + insert `user_claim_data_locks`

### 3. After Processing
- Users see "claim ready" notifications in app
- Users can claim rewards through Flutter app (gasless via AVNU)
- Blockchain calls use AVNU paymaster = gasless for users
- Claimed habits disappear from dashboard

## Example Output

### Alarm Backend
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

### Focus Lock Backend
```bash
🚀 ========== PROCESSING FOCUS LOCK POOL ==========
📅 Pool: Day 20373, Period 0
🕐 Processing Time: Sun Oct 12 2025 17:35:30 GMT+0530

🔍 STEP 1: FETCHING LOCK DATA
✅ Found 1 focus locks for this pool:
   👤 User: 0x2256e2b6...
      Start: 1760266770 (Sun Oct 12 2025 16:29:30 GMT+0530)
      Duration: 300s
      Stake: 20
      Completed: true

💰 STEP 3: CALCULATING REWARDS
🏆 Winners: 1
💸 Total Slashed: 0

🌳 STEP 4: BUILDING MERKLE TREE
✅ Merkle tree built with root: 0x75d1ab377574aeb4198812079a2b259216d2fa6e2163aa30893ea0ae1e00cc1

⛓️ STEP 5: SETTING MERKLE ROOT ON-CHAIN
✅ Merkle root set on-chain - TX: 0x6dc46e8c...

💾 STEP 6: STORING RESULTS TO DATABASE
✅ Results stored to database successfully

🎉 ========== PROCESSING COMPLETED SUCCESSFULLY ==========
📊 Pool Info: {
  "day": 20373,
  "period": 0,
  "total_users": 1,
  "winners": 1
}
🎯 Users can now claim their rewards through the app!
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

### Alarm Flow
After backend processes an alarm pool:
1. Flutter app queries `alarms` table
2. App shows "Claim" button for `claim_ready = true` alarms
3. User taps → App calls `BlockchainService.claimAlarmRewards()`
4. Claim uses data from `user_claim_data` table
5. After successful claim → `has_claimed = true`
6. Claimed alarms remain visible in history

### Focus Lock Flow
After backend processes a focus lock pool:
1. Flutter app queries `focus_locks` table
2. App shows "Claim" button for `claim_ready = true` locks
3. User taps → App calls `FocusLockBlockchainService.claimLockRewards()`
4. Claim uses data from `user_claim_data_locks` table
5. After successful claim → `has_claimed = true`
6. Claimed focus locks are hidden from dashboard

## Troubleshooting

### Pool Not Found
If backend shows "No locks/alarms found":
- Check `day` and `period` columns in database match what the contract stored
- Run: `SELECT day, period, start_time FROM focus_locks;` to see stored values
- The contract's period calculation may differ from time-based calculations

### Transaction Failures
- Ensure deployer account has sufficient ETH for gas
- Check AVNU_PAYMASTER_API_KEY is valid (or set to empty for regular txs)
- Verify contract addresses are correct in `.env`

### Database Errors
- Ensure all tables exist (run migrations)
- Check Supabase service key has full permissions
- Verify RLS policies allow backend writes

## Key Differences: Alarms vs Focus Locks

| Feature | Alarms | Focus Locks |
|---------|--------|-------------|
| **Period Length** | 12 hours (AM/PM) | 6 hours (4 periods/day) |
| **Reward Logic** | Snooze-based penalties | Completion-based returns |
| **Contract** | `ALARM_CONTRACT_ADDRESS_STRK` | `TIME_LOCK_CONTRACT_ADDRESS` |
| **Claim Table** | `user_claim_data` | `user_claim_data_locks` |
| **After Claim** | Visible in history | Hidden from dashboard |
| **Pool Query** | By time range | By `day` & `period` columns |
