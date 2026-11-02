// Safe real-Auth probes. Only the explicitly created counterparty is removed.
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readFileSync,writeFileSync} from 'node:fs';
import {parseEnv} from 'node:util';
import {execFileSync} from 'node:child_process';
import {createClient} from '@supabase/supabase-js';
assert(process.argv.includes('--vps'),'Explicit --vps required');
const config=parseEnv(readFileSync('deploy/.env.frontend','utf8')),backend=parseEnv(readFileSync('deploy/.env.backend','utf8')),secret=parseEnv(readFileSync('.env.fifo-test','utf8'));
const manifest=JSON.parse(readFileSync('.temp/fifo-business/manifest.json','utf8'));const api='https://api.lpg.144.79.249.4.sslip.io';assert.equal(config.VITE_SUPABASE_URL,api);assert.equal(backend.VPS_HOST,'144.79.249.4');assert.equal(backend.VPS_PROJECT_DIR,'/opt/lpg');
const make=()=>createClient(api,config.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}}),owner=make(),other=make(),anon=make();
const checked=async p=>{const {data,error}=await p;if(error)throw Error(error.code+': '+error.message);return data;};
const rejected=async(p,pattern)=>{const {error}=await p;assert(error,'Unauthorized action succeeded');assert.match(error.message,pattern);};
const ssh=[...(backend.VPS_SSH_KEY?['-i',backend.VPS_SSH_KEY]:[]),'-p',backend.VPS_PORT,'-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',`${backend.VPS_USER}@${backend.VPS_HOST}`];
const sql=input=>execFileSync('ssh',[...ssh,'sudo -n docker compose --project-directory /opt/lpg --env-file /opt/lpg/.env -p lpg -f /opt/lpg/compose.yml -f /opt/lpg/compose.vps.yml exec -T db psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1'],{input,encoding:'utf8',maxBuffer:1024*1024}).trim();
const uid=v=>{assert.match(v,/^[a-f0-9-]{36}$/);return `'${v}'::uuid`;};
let counterparty,user;const password=randomUUID()+'Aa1!';
try{
 await checked(owner.auth.signInWithPassword({email:secret.LPG_TEST_EMAIL,password:secret.LPG_TEST_PASSWORD}));
 const signup=await checked(other.auth.signUp({email:`fifo-security-${randomUUID()}@example.invalid`,password}));user=signup.user.id;
 counterparty=(await checked(other.rpc('setup_business',{p_business_name:'FIFO security disposable counterparty '+randomUUID(),p_owner_name:'Security fixture operator'}))).tenant_id;
 const item=manifest.products[0].id,month='2026-10-01';
 await rejected(other.rpc('get_monthly_commissions',{p_item_id:item,p_month:month}),/Eligible LPG product not found/);
 await rejected(other.rpc('set_monthly_commission',{p_payload:{item_id:item,month,package_rate:1,refill_rate:1,expected_revision:0,reason:'Cross-tenant mutation must fail'},p_request_id:randomUUID()}),/Eligible LPG product not found/);
 await rejected(other.rpc('get_finance_analysis',{p_filters:{business_id:manifest.tenant,from:'2026-08-01',to:'2026-10-31'}}),/business|access|permission/i);
 assert.deepEqual(await checked(other.from('items').select('item_id').eq('item_id',item)),[]);
 await rejected(other.from('monthly_commission_rates').insert({tenant_id:manifest.tenant,item_id:item,month,package_rate:1,refill_rate:1,source:'manual'}),/permission|row.level/i);
 await rejected(anon.rpc('get_monthly_commissions',{p_item_id:item,p_month:month}),/permission denied/i);
 await rejected(anon.rpc('correct_commission_deduction',{p_payload:{},p_request_id:randomUUID()}),/permission denied/i);
 await rejected(owner.from('accounting_lines').insert({tenant_id:manifest.tenant,journal_id:randomUUID(),line_no:1,account:'cash',amount:1}),/permission|row.level/i);
 const catalog=await checked(owner.rpc('get_financial_catalog'));
 const definition=catalog.types.find(t=>t.origin==='custom');assert(definition,'Retained business must contain a custom type');
 assert(!(await checked(other.rpc('get_financial_catalog'))).types.some(t=>t.type_id===definition.type_id),'Catalog leaked a foreign custom type');
 await rejected(other.rpc('save_financial_type',{p_payload:{type_id:definition.type_id,revision:definition.revision,name:'Foreign mutation denied',account:'operating_expense',allocations:{lpg:100}}}),/changed|permission/i);
 await rejected(other.rpc('record_financial_entry',{p_payload:{type_id:definition.type_id,expected_revision:definition.revision,amount:1,date:new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Dhaka'}).format(new Date()),description:'Foreign recognition denied'},p_request_id:randomUUID()}),/changed|deactivated|permission/i);
 const ownEntries=await checked(owner.rpc('get_wallet_ledger',{p_filters:{type:definition.type_id}}));
 const foreignEntry=ownEntries.entries.find(e=>e.record_kind==='financial_entry');assert(foreignEntry,'Expected an actual retained custom entry');
 await rejected(other.rpc('get_financial_entry',{p_entry_id:foreignEntry.record_id}),/unavailable|permission/i);
 await rejected(owner.from('financial_types').update({allocations:{logistics:100}}).eq('type_id',definition.type_id),/permission|row.level/i);
 await rejected(anon.rpc('get_financial_catalog'),/permission denied/i);
 await rejected(anon.rpc('record_financial_entry',{p_payload:{},p_request_id:randomUUID()}),/permission denied/i);
 const old=await owner.rpc('set_product_commissions',{p_item_id:item,p_refill_rate:1,p_package_rate:1,p_expected:null});assert(old.error,'Superseded commission write contract remains callable');
 const current=await checked(owner.rpc('get_monthly_commissions',{p_item_id:item,p_month:month}));const revision=current.current.revision;
 await rejected(owner.rpc('set_monthly_commission',{p_payload:{item_id:item,month,package_rate:current.current.package_rate,refill_rate:current.current.refill_rate,expected_revision:revision-1,reason:'Stale authenticated API edit'},p_request_id:randomUUID()}),/changed/i);
 const results={tenant:manifest.tenant,checks:17,passed:true,temporaryCounterpartyRemoved:true};writeFileSync('.temp/fifo-business/security-api.json',JSON.stringify(results,null,2));
 console.log('PASS real Auth/PostgREST: foreign reads/writes/report scope, direct financial writes, anonymous denial, obsolete contract removal and stale monthly edits');
}catch(error){console.error(String(error.stack??error).replaceAll(password,'[redacted]').replaceAll(secret.LPG_TEST_PASSWORD,'[redacted]').replace(/eyJ[\w-]+\.[\w-]+\.[\w-]+/g,'[redacted JWT]'));process.exitCode=1;}
finally{
 await other.auth.signOut({scope:'global'}).catch(()=>{});
 if(counterparty){
  const tables=sql("select c.table_schema||'.'||c.table_name from information_schema.columns c join information_schema.tables t using(table_catalog,table_schema,table_name) where c.table_schema in ('public','app_private') and c.column_name='tenant_id' and t.table_type='BASE TABLE' order by 1;").split('\n');assert(tables.every(t=>/^(public|app_private)\.[a-z_]+$/.test(t)));
  sql(`begin;do $$begin if not exists(select 1 from public.tenants t join public.user_profiles p using(tenant_id) where t.tenant_id=${uid(counterparty)} and p.user_id=${uid(user)} and t.business_name like 'FIFO security disposable counterparty %') then raise exception 'Refusing non-fixture cleanup';end if;end$$;set local session_replication_role=replica;${tables.map(t=>`delete from ${t} where tenant_id=${uid(counterparty)};`).join('\n')}commit;`);
 }
 if(user)sql(`delete from auth.users where id=${uid(user)};`);
 await owner.auth.signOut({scope:'local'});console.log('PASS only the identified disposable security account/business was cleaned; the populated lab remains');
}
