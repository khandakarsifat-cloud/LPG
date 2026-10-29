import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { createClient } from '@supabase/supabase-js';
import { checkPublicAPI, workerURL } from '../../../deploy/deploy.mjs';
import { frontend, read, save, sql } from './common.mjs';
import { preservation } from './verify.mjs';

assert(read('cleanup-result.json').preservation_match,'Complete exact fixture cleanup first');
await checkPublicAPI(frontend.VITE_SUPABASE_URL,frontend.VITE_SUPABASE_ANON_KEY);
const published=await fetch(workerURL,{signal:AbortSignal.timeout(15000)});
assert(published.ok,'Published frontend unavailable');
const secrets={...parseEnv(readFileSync('.env.live-test','utf8')),...process.env};
const client=createClient(frontend.VITE_SUPABASE_URL,frontend.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
const auth=await client.auth.signInWithPassword({email:secrets.LPG_TEST_EMAIL,password:secrets.LPG_TEST_PASSWORD});
assert.ifError(auth.error);
const profile=await client.from('user_profiles').select('tenant_id,is_active').single();
assert.ifError(profile.error);assert.deepEqual(profile.data,read('burner-membership.json'));
const permissions=await client.rpc('get_my_permissions');assert.ifError(permissions.error);assert(permissions.data.length);
await client.auth.signOut({scope:'local'});
assert.deepEqual(preservation(read('original-businesses.json')),read('preservation-before.json'));
const database=JSON.parse(sql(`select jsonb_build_object(
 'active_api_queries',(select count(*) from pg_stat_activity where datname=current_database() and usename='authenticator' and state='active'),
 'leftover_fixture_schema',to_regnamespace('lpg_capacity_fixture') is not null,
 'leftover_date_triggers',(select count(*) from pg_trigger where tgname='zzz_lpg_capacity_date'),
 'fixture_businesses_remaining',(select count(*) from public.tenants where business_name like 'VPS Capacity ${read('manifest.json').run}%'),
 'fixture_users_remaining',(select count(*) from auth.users where email like 'capacity-${read('manifest.json').run}-%@example.invalid'),
 'database_bytes',pg_database_size(current_database()));`));
assert.equal(database.active_api_queries,0);assert.equal(database.leftover_fixture_schema,false);
assert.equal(database.leftover_date_triggers,0);assert.equal(database.fixture_businesses_remaining,0);assert.equal(database.fixture_users_remaining,0);
const before=read('environment.json'),after=read('environment-after.json');
assert.equal(after.server.services.length,10);
for(const service of after.server.services) {
  assert.equal(service.status,'running');if(service.health)assert.equal(service.health,'healthy');
  assert.equal(service.oom_killed,false);
  assert.equal(service.restart_count,before.server.services.find(s=>s.name===service.name).restart_count,'Unexpected service restart');
}
save('post-test-health.json',{time:new Date().toISOString(),public_https:true,published_frontend:true,
 burner_membership_preserved:true,normal_auth_and_permissions:true,original_business_fingerprints_match:true,
 services:after.server.services,database});
console.log('PASS: public HTTPS, existing frontend, normal burner Auth/membership, all ten services, unchanged restart counts, drained requests, no fixture accounts/rows/hooks, and original business preservation.');
