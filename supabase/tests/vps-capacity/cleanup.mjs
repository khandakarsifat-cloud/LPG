import assert from 'node:assert/strict';
import { unlinkSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { createClient } from '@supabase/supabase-js';
import { state, frontend, read, save, sql, uuid } from './common.mjs';
import { preservation } from './verify.mjs';

assert(process.argv.includes('--created-fixtures-only'),'Explicit fixture cleanup scope required');
const manifest=read('manifest.json');
const tables=['finance_requests','wallet_transactions','customer_transactions','sale_payments','purchase_payments',
 'purchase_refund_obligations','purchase_activity','sale_bottle_receipt_lines','sale_bottle_receipts','sale_items','sales',
 'inventory_movements','purchase_items','transits','purchases','product_commission_rates','price_books','items',
 'area_officers','gas_plants','lpg_brands','customers','trucks','receipt_printers','wallets','user_roles','role_permissions',
 'roles','audit_logs','user_profiles','tenants'];
const removed=[];
for(const a of manifest.accounts) {
  assert(a.email.startsWith('capacity-'+manifest.run+'-') && a.email.endsWith('@example.invalid'));
  if(sql(`select exists(select 1 from auth.users where id=${uuid(a.user_id)} and email='${a.email}');`)==='t') {
    const client=createClient(frontend.VITE_SUPABASE_URL,frontend.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
    const session=await client.auth.setSession({access_token:a.token,refresh_token:a.refresh_token});
    if(!session.error) {
      assert.equal(session.data.user.id,a.user_id);
      const logout=await client.auth.signOut({scope:'global'});assert.ifError(logout.error);
    } else assert(session.error.name==='AuthSessionMissingError' || ['refresh_token_not_found','refresh_token_already_used','session_not_found'].includes(session.error.code),'Unexpected Auth cleanup failure');
  }
  if(a.tenant_id) {
    const t=uuid(a.tenant_id),actor=uuid(a.user_id);
    const label=`VPS Capacity ${manifest.run} Business ${a.index}`;
    assert(/^[a-zA-Z0-9 -]+$/.test(label));
    sql(`begin; set local lock_timeout='3s'; set local statement_timeout='180s';
     do $guard$ begin
      if exists(select 1 from public.tenants where tenant_id=${t}) and not exists(select 1 from public.tenants where tenant_id=${t} and business_name='${label}') then raise exception 'Foreign business cleanup refused'; end if;
      if exists(select 1 from public.user_profiles where user_id=${actor} and tenant_id<>${t}) then raise exception 'Changed membership cleanup refused'; end if;
     end $guard$;
     set local session_replication_role=replica;
     ${tables.map(table=>`delete from public.${table} where tenant_id=${t};`).join('\n')}
     commit;`);
  }
  if(a.user_id) {
    assert(a.email.startsWith('capacity-'+manifest.run+'-') && a.email.endsWith('@example.invalid'));
    sql(`begin; do $guard$ begin if exists(select 1 from auth.users where id=${uuid(a.user_id)} and email<>'${a.email}') then raise exception 'Foreign Auth cleanup refused'; end if; end $guard$;
      delete from auth.users where id=${uuid(a.user_id)} and email='${a.email}';commit;`);
  }
  removed.push({index:a.index,tenant_id:a.tenant_id,user_id:a.user_id});
  console.log(`Removed only registered capacity business/account ${a.index}.`);
}
sql(`set lock_timeout='3s'; set statement_timeout='300s'; vacuum (analyze, skip_locked) ${tables.map(table=>'public.'+table).join(',')};`);
const after=preservation(read('original-businesses.json'));
assert.deepEqual(after,read('preservation-before.json'),'Non-fixture preservation mismatch after cleanup');
save('preservation-after-cleanup.json',after);
save('cleanup-result.json',{time:new Date().toISOString(),removed,preservation_match:true});
save('manifest.json',{run:manifest.run,created:manifest.created,cleaned:true,accounts:removed});
for(const file of ['accounts.json','config.json','transport-config.json','private-error.txt','private-seed-error.txt']) {
  if(existsSync(join(state,file))) unlinkSync(join(state,file));
}
console.log('PASS: registered fixtures removed, original business fingerprints preserved, local fixture credentials removed.');
