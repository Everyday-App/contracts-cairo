const { createClient } = require('@supabase/supabase-js');

async function createTestData() {
    const supabase = createClient(
        process.env.SUPABASE_URL,
        process.env.SUPABASE_SERVICE_KEY
    );
    
    console.log('🔧 Creating test alarm data...');
    
    // Profile data from your Flutter logs
    const profileId = '9aa85e53-d152-46c0-a74b-82be8ae270a5';
    const walletAddress = '0xbefb936b1b65228c5d8adf73692bbdec0af59ca7261b99672e4ea03ba1ab76';
    
    // Ensure profile exists
    const { error: profileError } = await supabase
        .from('profiles')
        .upsert({ id: profileId, wallet_address: walletAddress });
        
    if (profileError) console.log('Profile error:', profileError.message);
    else console.log('✅ Profile ready');
    
    // Test alarms - various scenarios
    const testAlarms = [
        {
            id: 'af3c8e37-8d47-4ae4-824a-133fc78a57d0',
            user_id: profileId,
            wakeup_time: 1757691000, // Day 20343, Period 1 - Winner
            stake_amount: 20.0,
            snooze_count: 0
        },
        {
            id: 'test-alarm-loser-1-snooze',
            user_id: profileId, 
            wakeup_time: 1757695000, // Day 20343, Period 1 - 1 snooze
            stake_amount: 15.0,
            snooze_count: 1
        },
        {
            id: 'test-alarm-loser-2-snooze',
            user_id: profileId,
            wakeup_time: 1757700000, // Day 20343, Period 1 - 2 snoozes
            stake_amount: 25.0,
            snooze_count: 2
        }
    ];
    
    // Insert test alarms
    const { error: alarmError } = await supabase
        .from('alarms')
        .insert(testAlarms);
        
    if (alarmError) {
        console.log('❌ Error:', alarmError.message);
    } else {
        console.log('✅ Test alarms created!');
        testAlarms.forEach(alarm => {
            const day = Math.floor(alarm.wakeup_time / 86400);
            const period = Math.floor((alarm.wakeup_time % 86400) / 43200);
            console.log(`📅 ${alarm.id.substring(0, 15)} - Day: ${day}, Period: ${period}, Snoozes: ${alarm.snooze_count}`);
        });
    }
    
    // Verify
    const { count } = await supabase.from('alarms').select('*', { count: 'exact', head: true });
    console.log(`📊 Total alarms: ${count}`);
}

createTestData().catch(console.error);
