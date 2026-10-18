import { readFileSync, readdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { execFileSync } from 'node:child_process';

const root = new URL('../../', import.meta.url);
const read = name => readFileSync(new URL(name, import.meta.url),'utf8');
const replayIndex = process.argv.indexOf('--replay-module');
function report(name,results) {
  const success = results.flatMap(result => result.rows).find(row => JSON.stringify(row).includes('PASS:'));
  if (!success) throw new Error(`No success assertion from ${name}`);
  console.log(`${name}: ${Object.values(success).join(' ')}`);
}

if (replayIndex === -1) {
  // Existing configured local Compose instance, migrated first. Each SQL suite
  // uses a transaction and rolls back all fixtures. No credentials are read.
  const output = execFileSync('docker',[
    'compose','exec','-T','db','psql','-U','supabase_admin','-d','postgres','-v','ON_ERROR_STOP=1','-q','-t',
  ],{ input:read('purchases.sql'),encoding:'utf8',cwd:root });
  const result=output.split('\n').find(line=>line.includes('PASS:'));
  if(!result) throw new Error('No purchase success assertion');
  console.log(result.trim());
} else {
  // Optional verification-only PGlite install; never connects to an existing
  // database. This is a real disposable PostgreSQL engine with small Auth/role
  // fixtures, not a mock of the application SQL. It does not verify PostgREST,
  // GoTrue, production PostgreSQL's version, or concurrent sessions.
  if (!process.argv[replayIndex+1]) throw new Error('Provide the PGlite package directory');
  const moduleDir = resolve(process.argv[replayIndex+1]);
  const { PGlite } = await import(pathToFileURL(resolve(moduleDir,'dist/index.js')).href);
  const { uuid_ossp } = await import(pathToFileURL(resolve(moduleDir,'dist/contrib/uuid_ossp.js')).href);
  const db = new PGlite({ extensions:{uuid_ossp} });
  try {
    await db.exec(`create role anon; create role authenticated; create role service_role bypassrls; create role supabase_admin superuser;
      create schema auth; create schema extensions;
      create extension "uuid-ossp" with schema extensions;
      create table auth.users(id uuid primary key,email text,is_anonymous boolean default false,raw_app_meta_data jsonb,raw_user_meta_data jsonb);
      create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
      create function auth.jwt() returns jsonb language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb $$;
      grant usage on schema auth to anon,authenticated; grant execute on function auth.uid(),auth.jwt() to anon,authenticated;
      select set_config('lpg.disposable_replay','on',false);`);
    const names=readdirSync(new URL('../migrations/',import.meta.url)).filter(n=>n.endsWith('.sql')).sort();
    let exchangeCompatibility = false;
    let workflowCompatibility = false;
    for(const name of names) {
      if(name.endsWith('_purchase_transit_workflow.sql')) {
        report('exchange compatibility',await db.exec(read('purchases-exchange.after.sql')));
        await db.exec(`create temp table workflow_preservation as select
          (select md5(coalesce(jsonb_agg(to_jsonb(i) order by tenant_id,item_id)::text,'')) from public.items i) stock,
          (select md5(coalesce(jsonb_agg(to_jsonb(w) order by tenant_id,wallet_id)::text,'')) from public.wallets w) wallets,
          (select md5(coalesce(jsonb_agg(to_jsonb(m) order by tenant_id,movement_id)::text,'')) from public.inventory_movements m) movements,
          (select md5(coalesce(jsonb_agg(to_jsonb(w) order by tenant_id,transaction_id)::text,'')) from public.wallet_transactions w) transactions;`);
        workflowCompatibility = true;
      }
      if(name.endsWith('_purchase_refill_exchange.sql')) {
        report('historical compatibility',await db.exec(read('purchases-legacy.after.sql')));
        await db.exec(read('purchases-exchange.before.sql'));
        exchangeCompatibility = true;
      }
      if(name.endsWith('_purchase_created_status.sql')) {
        await db.exec(read('purchases-legacy.before.sql'));
        // Production migrations run as the platform administrator while the
        // existing application routines are owned by postgres. The SQL suite
        // checks ownership explicitly (PGlite's bootstrap postgres is superuser).
        await db.exec('set session authorization supabase_admin;');
        if(process.argv.includes('--deployment-batch')) await db.exec('begin;');
      }
      // The baseline dump disables body checking; verify newly authored RPCs
      // at migration time as well as by calling them in workflow tests.
      if(name.endsWith('_purchase_created_status.sql')) await db.exec('set check_function_bodies=on;');
      await db.exec(readFileSync(new URL('../migrations/'+name,import.meta.url),'utf8'));
    }
    if(process.argv.includes('--deployment-batch')) await db.exec('commit;');
    console.log('Migration replay:', (await db.query('select version()')).rows[0].version);
    await db.exec('set row_security=on; set check_function_bodies=on;');
    if(workflowCompatibility) {
      await db.exec(`do $$ begin if exists(select 1 from workflow_preservation s where
        s.stock is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(i) order by tenant_id,item_id)::text,'')) from public.items i)
        or s.wallets is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(w) order by tenant_id,wallet_id)::text,'')) from public.wallets w)
        or s.movements is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(m) order by tenant_id,movement_id)::text,'')) from public.inventory_movements m)
        or s.transactions is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(w) order by tenant_id,transaction_id)::text,'')) from public.wallet_transactions w))
        then raise exception 'Workflow migration changed stock or money'; end if; end $$;`);
      console.log('Workflow migration preserves stock, wallet balances and all ledger history.');
    }
    else if(exchangeCompatibility) report('exchange compatibility',await db.exec(read('purchases-exchange.after.sql')));
    else report('historical compatibility',await db.exec(read('purchases-legacy.after.sql')));
    for(const name of ['purchases.sql','authorization.sql','receipt_printers.sql','inventory.sql']) {
      await db.exec('set row_security=on;');
      report(name,await db.exec(read(name)));
    }
  } catch(error) {
    console.error({ message:error.message,detail:error.detail,where:error.where });
    process.exitCode=1;
  } finally { await db.close(); }
}
