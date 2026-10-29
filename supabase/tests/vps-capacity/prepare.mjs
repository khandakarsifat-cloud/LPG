import { randomUUID } from 'node:crypto';
import { readFileSync, existsSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { parseEnv } from 'node:util';
import { createClient } from '@supabase/supabase-js';
import { state, frontend, remote, sql, save, read, uuid } from './common.mjs';

const checked = async query => {
  const { data, error } = await query;
  if (error) throw Error(`${error.code}: ${error.message}`);
  return data;
};
const action = process.argv[2];
const makeClient = () => createClient(frontend.VITE_SUPABASE_URL, frontend.VITE_SUPABASE_ANON_KEY,
  { auth: { persistSession: false, autoRefreshToken: false } });
const fixtureSource = readFileSync(new URL('./fixture.py', import.meta.url), 'utf8');
const fixturePath = '/tmp/lpg-capacity-fixture.py';
remote(`umask 077; cat > ${fixturePath}`, fixtureSource);
// Credentials are passed over encrypted stdin, never in SSH arguments/process lists.
const invoke = payload => {
  const encoded = Buffer.from(JSON.stringify(payload)).toString('base64');
  const program = `import base64,json,runpy,io,sys; sys.stdin=io.StringIO(base64.b64decode('${encoded}').decode()); runpy.run_path('${fixturePath}',run_name='__main__')`;
  return JSON.parse(remote('sudo -n python3 -', program));
};
// The encoded payload is in stdin above; it is never emitted to logs.

if (action === 'init') {
  if (existsSync(resolve(state, 'manifest.json'))) throw Error('Use the existing run manifest');
  const secrets = { ...parseEnv(readFileSync('.env.live-test', 'utf8')), ...process.env };
  const burner = makeClient();
  await checked(burner.auth.signInWithPassword({ email: secrets.LPG_TEST_EMAIL, password: secrets.LPG_TEST_PASSWORD }));
  const membership = await checked(burner.from('user_profiles').select('tenant_id,is_active').single());
  if (!membership.is_active) throw Error('Inactive burner');
  save('burner-membership.json', membership);
  await burner.auth.signOut({ scope: 'local' });
  const run = randomUUID();
  save('manifest.json', { run, created: new Date().toISOString(), accounts: [] });
  console.log('Verified configured API, normal Auth, and trusted burner membership; created private run manifest.');
} else if (action === 'accounts') {
  const manifest = read('manifest.json');
  const count = Number(process.argv[3]);
  if (!Number.isInteger(count) || count < 1 || count > 500) throw Error('Invalid account count');
  while (manifest.accounts.length < count) {
    if(existsSync(resolve(state,'stop-load'))) throw Error('Preparation stopped by marker');
    const index = manifest.accounts.length + 1;
    const account = { index, email: `capacity-${manifest.run}-${index}@example.invalid`, password: randomUUID() + 'Aa1!', seeded: 0 };
    const result = invoke({ action: 'provision', accounts: [account] });
    Object.assign(account, result[0]);
    manifest.accounts.push(account); save('manifest.json', manifest);
    const client = makeClient();
    const auth = await checked(client.auth.signInWithPassword({ email: account.email, password: account.password }));
    const business = await checked(client.rpc('setup_business', { p_business_name: `VPS Capacity ${manifest.run} Business ${index}`, p_owner_name: `Capacity user ${index}` }));
    account.tenant_id = business.tenant_id;
    account.brand_id = randomUUID(); account.plant_id = randomUUID(); account.truck_id = randomUUID();
    account.item_ids = Array.from({ length: 6 }, () => randomUUID());
    save('manifest.json', manifest);
    const t = uuid(account.tenant_id), actor = uuid(account.user_id);
    sql(`begin; set local lock_timeout='2s';
      insert into public.lpg_brands(tenant_id,brand_id,brand_name) values(${t},${uuid(account.brand_id)},'Capacity LPG');
      insert into public.gas_plants(tenant_id,plant_id,brand_id,plant_name) values(${t},${uuid(account.plant_id)},${uuid(account.brand_id)},'Capacity plant');
      insert into public.trucks(tenant_id,truck_id,name,serial_no,capacity,size) values(${t},${uuid(account.truck_id)},'Capacity truck','Capacity ${index}',500,'medium');
      ${account.item_ids.map((id, i) => `insert into public.items(tenant_id,item_id,brand_id,size_kg,filled_quantity,empty_quantity) values(${t},${uuid(id)},${uuid(account.brand_id)},${[5,12,15,20,35,45][i]},0,0);`).join('\n')}
      insert into public.customers(tenant_id,name,phone,tier,shop_name,address)
      select ${t},'Capacity ${index} Customer '||lpad(n::text,4,'0'),'019'||lpad(n::text,8,'0'),case when n%5=0 then 'wholesale' else 'retail' end,'Capacity store '||n,'Dhaka fixture area '||(n%20) from generate_series(0,1999) n;
      set local role authenticated; select set_config('request.jwt.claim.sub',${actor}::text,true);
      select public.move_wallet_money(jsonb_build_object('action','adjustment','wallet_id',wallet_id,'amount',80000000,'reason','Capacity fixture opening capital'),gen_random_uuid()) from public.wallets where tenant_id=${t} and type='dealership';
      reset role;
      insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,filled_quantity_change,empty_quantity_change,notes,created_by)
      select ${t},item_id,'adjustment','adjustment',0,2000,'Capacity fixture documented opening empties',${actor} from public.items where tenant_id=${t};
      insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price,effective_from)
      select ${t},x.id,tier,kind,case kind when 'package' then 2300+x.n*100 else 1200+x.n*100 end,now()-interval '200 days'
      from (values ${account.item_ids.map((id, i) => `(${uuid(id)},${i})`).join(',')}) x(id,n)
      cross join (values('retail'),('wholesale')) tiers(tier) cross join (values('refill'),('package')) kinds(kind); commit;`);
    account.cash = await checked(client.from('wallets').select('wallet_id').eq('type', 'cash').single());
    account.bank = await checked(client.from('wallets').select('wallet_id').eq('type', 'dealership').single());
    account.token = auth.session.access_token; account.refresh_token = auth.session.refresh_token;
    account.expires_at = auth.session.expires_at;
    save('manifest.json', manifest);
    console.log(`Prepared isolated business ${index}; 2,000 customers, six SKUs, trusted OWNER and opening capital/stock evidence.`);
  }
} else if (action === 'seed') {
  const manifest = read('manifest.json');
  const limit = Number(process.argv[3] || manifest.accounts.length);
  const target = Number(process.argv[4] || 20000);
  for (const account of manifest.accounts.slice(0, limit)) {
    while (account.seeded < target) {
      if(existsSync(resolve(state,'stop-load'))) throw Error('Preparation stopped by marker');
      const result = invoke({ ...account, action: 'seed', start: account.seeded, count: Math.min(500, target - account.seeded) });
      account.seeded = result.sales; save('manifest.json', manifest);
      console.log(`Seed business ${account.index}: ${account.seeded}/20000 sales; batch ${result.seconds}s`);
    }
  }
} else {
  throw Error('Usage: prepare.mjs init|accounts COUNT|seed [BUSINESSES] [TARGET_SALES]');
}
