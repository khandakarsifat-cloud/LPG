// Real Auth/API and published UI acceptance on explicitly created disposable businesses.
import assert from 'node:assert/strict';
import { provisionTestBusiness } from './trusted-test-provisioning.mjs';
import { randomUUID } from 'node:crypto';
import { readFileSync, mkdirSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { execFileSync } from 'node:child_process';
import { createClient } from '@supabase/supabase-js';
import { chromium } from 'playwright';
import { positionGroupValue } from '../../src/lib/accountingPosition.ts';
assert(process.argv.includes('--vps'), 'Explicit --vps is required');
const frontend = parseEnv(readFileSync('deploy/.env.frontend', 'utf8'));
const backend = parseEnv(readFileSync('deploy/.env.backend', 'utf8'));
const secret = {
  ...parseEnv(readFileSync('.env.live-test', 'utf8')),
  ...process.env,
};
const api = 'https://api.lpg.144.79.249.4.sslip.io';
const worker = 'https://floral-dew-443b.khandakarsifat.workers.dev';
assert.equal(frontend.VITE_SUPABASE_URL, api);
assert.equal(backend.VPS_HOST, '144.79.249.4');
assert.equal(backend.VPS_PROJECT_DIR, '/opt/lpg');
assert.equal(secret.LPG_TEST_EMAIL, 'sifatsiam244@gmail.com');
const ssh = [
  ...(backend.VPS_SSH_KEY ? ['-i', backend.VPS_SSH_KEY] : []),
  '-p',
  backend.VPS_PORT,
  '-o',
  'BatchMode=yes',
  '-o',
  'StrictHostKeyChecking=yes',
  `${backend.VPS_USER}@${backend.VPS_HOST}`,
];
const sql = (input) =>
  execFileSync(
    'ssh',
    [
      ...ssh,
      'sudo -n docker compose --project-directory /opt/lpg --env-file /opt/lpg/.env -p lpg -f /opt/lpg/compose.yml -f /opt/lpg/compose.vps.yml exec -T db psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1',
    ],
    { input, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 },
  ).trim();
const uuid = (v) => {
  assert.match(v, /^[a-f0-9-]{36}$/i);
  return `'${v}'::uuid`;
};
const checked = async (request) => {
  const { data, error } = await request;
  if (error) throw Error(`${error.code}: ${error.message}`);
  return data;
};
const tables=sql("select c.table_name from information_schema.columns c join information_schema.tables t using(table_catalog,table_schema,table_name) where c.table_schema='public' and c.column_name='tenant_id' and t.table_type='BASE TABLE' order by c.table_name;").split('\n');
assert(tables.every(t=>/^[a-z_]+$/.test(t)));
const preservation =
  'select jsonb_build_array(' +
  tables
    .map(
      (t) =>
        `(select md5(coalesce(jsonb_agg(to_jsonb(r) order by to_jsonb(r)::text)::text,'')) from ${t === 'attendance_devices' ? '(select tenant_id,device_id,serial,name,enabled,approved_at,removed_at,created_at from public.attendance_devices)' : 'public.' + t} r)`,
    )
    .join(',') +
  ');';
let before = sql(preservation);
const clients = [],
  users = [],
  tenants = [];
const fixtureAccounts = [];
let browser;const browserErrors=[];
const client = () => {
  const c = createClient(api, frontend.VITE_SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  clients.push(c);
  return c;
};
async function account(label) {
 const c=client(); const email=`wallet-${randomUUID()}@example.invalid`, password=randomUUID()+'Aa1!';
 const auth=await provisionTestBusiness(c,{email,password,businessName:'Unified accounting API fixture wallet '+label+' '+randomUUID()});
 users.push(auth.user.id);tenants.push(auth.tenant_id);fixtureAccounts.push({c,tenant:auth.tenant_id});
 return {c,user:auth.user,session:auth.session,tenant:auth.tenant_id};
}
try {
 const trusted=JSON.parse(sql("select jsonb_build_object('tenant',p.tenant_id,'active',p.is_active,'business_active',t.status='active') from auth.users u join public.user_profiles p on p.user_id=u.id join public.tenants t using(tenant_id) where u.email='sifatsiam244@gmail.com';"));
 assert(trusted.active&&trusted.business_active);
 const burner=client(); await checked(burner.auth.signInWithPassword({email:secret.LPG_TEST_EMAIL,password:secret.LPG_TEST_PASSWORD}));
 await checked(burner.rpc('get_access_context'));
 before=sql(preservation);
 const owner=await account('owner'), c=owner.c;
 const rpc=(name,args={})=>checked(c.rpc(name,args));
 const wallets=await rpc('get_payment_wallets'), cash=wallets.find(w=>w.type==='cash').wallet_id, bank=wallets.find(w=>w.type==='dealership').wallet_id;
 for(const [business,amount] of [['lpg',9000],['stove',3000],['logistics',-2000]])await rpc('move_wallet_money',{p_payload:{action:'adjustment',wallet_id:cash,business,amount,reason:'Signed disposable fixture seed'},p_request_id:randomUUID()});
 const key=randomUUID(),payload={action:'transfer',wallet_id:cash,destination_id:bank,amount:8000,reason:'Live signed proportional transfer'};
 await rpc('move_wallet_money',{p_payload:payload,p_request_id:key});await rpc('move_wallet_money',{p_payload:payload,p_request_id:key});
 let w=await checked(c.from('wallets').select('*'));assert.equal(Number(w.find(x=>x.wallet_id===cash).balance),2000);assert.deepEqual(w.find(x=>x.wallet_id===cash).business_balances,{lpg:1800,stove:600,logistics:-400});
 assert.equal(sql(`select count(*) from public.wallet_transactions where operation_id=${uuid(key)};`),'6');
 const advancedKey=randomUUID();await rpc('move_wallet_money',{p_payload:{action:'transfer',transfer_mode:'business',wallet_id:cash,destination_id:cash,business:'lpg',destination_business:'stove',amount:10,reason:'Live advanced business reallocation'},p_request_id:advancedKey});
 assert.equal(sql(`select count(*) from public.wallet_transactions where operation_id=${uuid(advancedKey)};`),'2');
 const type=(await rpc('get_stove_product_types')).find(t=>t.is_active);
 const product=(await rpc('save_stove_product',{p_payload:{name:'Wallet contribution acceptance stove',type_id:type.type_id},p_request_id:randomUUID()})).item_id;
 await rpc('adjust_inventory',{p_payload:{item_id:product,kind:'capital',filled_quantity:2,empty_quantity:0,filled_unit_cost:125,reason:'Unified stock capital contribution'},p_request_id:randomUUID()});
 assert.equal((await rpc('get_inventory_cost_history',{p_item_id:product})).pool.filled_value,250);
 console.log('PASS live Auth/PostgREST: signed proportions, six entries, retry and Advanced two entries');
 browser=await chromium.launch({headless:true,channel:'chrome'});const context=await browser.newContext({viewport:{width:1440,height:1000}});
 await context.addInitScript(({api,session})=>localStorage.setItem('sb-'+new URL(api).host+'-auth-token',JSON.stringify(session)),{api,session:owner.session});
 const page=await context.newPage();await page.goto(worker+'/#/finance');
 await page.getByRole('heading',{name:'Finance',exact:true}).last().waitFor();
 await page.getByRole('button',{name:'Transfer',exact:true}).click();let dialog=page.getByRole('dialog').last();
 assert.equal(await dialog.getByLabel('Source business',{exact:true}).count(),0);
 assert.equal(await dialog.getByLabel('Destination business',{exact:true}).count(),0);
 await dialog.getByRole('button',{name:'Advanced',exact:true}).click();assert.equal(await dialog.getByLabel('Source business',{exact:true}).count(),1);assert.equal(await dialog.getByLabel('Destination business',{exact:true}).count(),1);
 await dialog.getByRole('button',{name:'Cancel',exact:true}).click();
 await page.getByRole('button',{name:'Transfer',exact:true}).click();dialog=page.getByRole('dialog').last();
 await dialog.getByLabel('From wallet',{exact:true}).selectOption(cash);await dialog.getByLabel('To wallet',{exact:true}).selectOption(bank);await dialog.getByLabel('Amount (Tk)',{exact:true}).fill('1');await dialog.getByLabel('Reason / reference',{exact:true}).fill('Published browser proportional transfer');
 const [response]=await Promise.all([page.waitForResponse(r=>r.url().includes('/rpc/move_wallet_money')&&r.request().method()==='POST'),dialog.getByRole('button',{name:'Record transfer',exact:true}).click()]);const posted=await response.json();assert(posted.operation_id);await dialog.waitFor({state:'hidden'});
 assert.equal(sql(`select count(*) from public.wallet_transactions where operation_id=${uuid(posted.operation_id)};`),'6');
 await page.getByRole('button',{name:'Adjust balance',exact:true}).click();dialog=page.getByRole('dialog').last();
 const purposes=await dialog.getByLabel('Purpose',{exact:true}).locator('option').allTextContents();assert.deepEqual(purposes,['Balance correction','Capital contribution']);
 await dialog.getByRole('button',{name:'Cancel',exact:true}).click();
 await page.getByRole('button',{name:'Wallet ledger',exact:true}).click();await page.getByRole('button',{name:'Filters',exact:true}).click();dialog=page.getByRole('dialog').last();
 mkdirSync('.temp/wallet-contributions',{recursive:true});
 for(const width of [1440,390]){
  await page.setViewportSize({width,height:1000});
  assert.equal(await dialog.getByText('From date',{exact:true}).count(),1);assert.equal(await dialog.getByText('To date',{exact:true}).count(),1);
  assert(await dialog.evaluate(el=>el.scrollWidth<=el.clientWidth),'Filter dialog horizontal overflow');
  await page.screenshot({path:`.temp/wallet-contributions/filter-${width}.png`});
 }
 await dialog.getByRole('button',{name:'Cancel',exact:true}).click();
 await page.setViewportSize({width:1440,height:1000});await page.goto(worker+'/#/inventory');await page.getByRole('button',{name:'Stove Business',exact:true}).click();
 await page.getByRole('button',{name:'Adjustment',exact:true}).click();dialog=page.getByRole('dialog').last();
 const kinds=await dialog.getByLabel('Reason category',{exact:true}).locator('option').allTextContents();assert(kinds.includes('Stock capital contribution'));assert(!kinds.some(k=>/Opening|Owner stock/.test(k)));
 console.log('PASS published browser: default/Advanced controls, unified purpose and labeled responsive ledger dates');
} catch(error) {
 console.error(String(error?.stack??error).replaceAll(secret.LPG_TEST_PASSWORD,'[redacted]').replace(/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g,'[redacted JWT]'));process.exitCode=1;
} finally {
  if (browser) await browser.close();
  for(const fixture of fixtureAccounts) {
    const pictured=await checked(fixture.c.from('items').select('item_id,image_url').not('image_url','is',null));
    for(const item of pictured)await checked(fixture.c.rpc('set_product_image',{p_item_id:item.item_id,p_image_path:null}));
    const objects=await checked(fixture.c.storage.from('product-images').list(fixture.tenant,{limit:100}));
    if(objects.length)await checked(fixture.c.storage.from('product-images').remove(objects.map(o=>`${fixture.tenant}/${o.name}`)));
    assert.equal((await checked(fixture.c.storage.from('product-images').list(fixture.tenant,{limit:100}))).length,0,'Fixture image cleanup incomplete');
  }
  if (tenants.length) {
    const ids = tenants.map(uuid).join(',');
    const cleanupTables = sql(
      "select c.table_schema||'.'||c.table_name from information_schema.columns c join information_schema.tables t using(table_catalog,table_schema,table_name) where c.table_schema in ('public','app_private') and c.column_name='tenant_id' and t.table_type='BASE TABLE' order by c.table_schema,c.table_name;",
    ).split('\n');
    assert(cleanupTables.every((t) => /^(public|app_private)\.[a-z_]+$/.test(t)));
    sql(
      `begin;do $$begin if exists(select 1 from public.tenants where tenant_id in (${ids}) and business_name not like 'Unified accounting API fixture %') then raise exception 'Not an accounting fixture';end if;end$$;set local session_replication_role=replica;${cleanupTables.map((t) => `delete from ${t} where tenant_id in (${ids});`).join('\n')}commit;`,
    );
  }
  if (users.length)
    sql(`delete from auth.users where id in (${users.map(uuid).join(',')});`);
  for (const c of clients) await c.auth.signOut({ scope: 'local' });
  assert.equal(
    sql(preservation),
    before,
    'Original business accounting/stock fingerprints changed',
  );
  console.log(
    'PASS: only explicitly created fixtures cleaned; original businesses unchanged and burner retained',
  );
}
