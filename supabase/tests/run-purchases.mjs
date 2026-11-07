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
  if (!process.argv.includes('--vps')) throw new Error('Current purchase checks require --vps; historical replay requires --replay-module.');
  execFileSync(process.execPath, ['supabase/tests/run-unified-accounting.mjs', '--vps'], { stdio: 'inherit', cwd: root });
} else {
  // Optional verification-only PGlite install; never connects to an existing
  // database. This is a real disposable PostgreSQL engine with small Auth/role
  // fixtures, not a mock of the application SQL. It does not verify PostgREST,
  // GoTrue, production PostgreSQL's version, or concurrent sessions.
  if (!process.argv[replayIndex+1]) throw new Error('Provide the PGlite package directory');
  const moduleDir = resolve(process.argv[replayIndex+1]);
  const { PGlite } = await import(pathToFileURL(resolve(moduleDir,'dist/index.js')).href);
  const { uuid_ossp } = await import(pathToFileURL(resolve(moduleDir,'dist/contrib/uuid_ossp.js')).href);
  const { pg_trgm } = await import(pathToFileURL(resolve(moduleDir,'dist/contrib/pg_trgm.js')).href);
  const db = new PGlite({ extensions:{uuid_ossp,pg_trgm} });
  try {
    await db.exec(`create role anon; create role authenticated; create role authenticator; create role service_role bypassrls; create role supabase_admin superuser;
      create schema auth; create schema extensions;
      -- Platform-owned Storage relations are not application migrations.
      create schema storage;
      create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
      create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text references storage.buckets(id),name text,metadata jsonb);
      alter table storage.objects enable row level security;
      create function storage.extension(text) returns text language sql immutable as $$ select reverse(split_part(reverse($1),'.',1)) $$;
      grant usage on schema storage to authenticated;
      grant select,insert,update,delete on storage.objects to authenticated;
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
      // Empty-install verification excludes intentionally obsolete migration
      // fixtures; current contract fixtures still run after all migrations.
      if(process.argv.includes('--schema-only')) {
        await db.exec('set search_path=public;');
        if(name.endsWith('_purchase_created_status.sql')) await db.exec('set session authorization supabase_admin;set check_function_bodies=on;');
        const source=readFileSync(new URL('../migrations/'+name,import.meta.url),'utf8');
        try { await db.exec(name.includes('canonical_development_model')?'begin;'+source+'commit;':source); }
        catch(error) { console.error('Migration:',name);throw error; }
        continue;
      }
      if(name.endsWith('_monthly_commission_fifo.sql')) {
        await db.exec(read('fixture-helpers.sql'));
        for(const historical of ['unified-accounting.sql','accounting-corrections.sql']) {
          const source=read(historical);
          const results=process.argv.includes('--deployment-batch')
            ? await db.exec('savepoint historical_contract;'+source.replace(/^begin;\s*/,'').replace(/rollback;\s*$/,'')+'rollback to savepoint historical_contract;release savepoint historical_contract;')
            : await db.exec(source);
          report('historical '+historical,results);
        }
      }
      // Match the deployment runner's fresh psql session for each batch; the
      // baseline dump clears search_path in this persistent replay connection.
      await db.exec('set search_path=public;');
      if(name.endsWith('_purchase_transit_workflow.sql')) {
        report('exchange compatibility',await db.exec(read('purchases-exchange.after.sql')));
        await db.exec(`create temp table workflow_preservation as select
          (select md5(coalesce(jsonb_agg(to_jsonb(i)-'brand'-'cylinder_weight' order by tenant_id,item_id)::text,'')) from public.items i) stock,
          (select md5(coalesce(jsonb_agg(jsonb_build_array(tenant_id,wallet_id,type,balance,created_at,updated_at) order by tenant_id,wallet_id)::text,'')) from public.wallets w) wallets,
          (select md5(coalesce(jsonb_agg(to_jsonb(m) order by tenant_id,movement_id)::text,'')) from public.inventory_movements m) movements,
          (select md5(coalesce(jsonb_agg(jsonb_build_array(tenant_id,transaction_id,wallet_id,amount,type,reference_id,description,created_at) order by tenant_id,transaction_id)::text,'')) from public.wallet_transactions w) transactions;`);
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
      if(name.endsWith('_sale_pricing_tier.sql')) await db.exec(read('sale-tier-legacy.before.sql'));
      if(name.endsWith('_multi_wallet_finance.sql')) await db.exec(read('finance-legacy.before.sql'));
      if(name.endsWith('_sales_bottle_receivables.sql')) await db.exec(read('bottles-legacy.before.sql'));
      if(name.endsWith('_aggregate_bottle_settlement.sql')) await db.exec(read('bottles-aggregate.before.sql'));
      if(name.endsWith('_dynamic_settlement_receipts.sql')) await db.exec(read('settlement-legacy.before.sql'));
      if(name.endsWith('_canonical_development_model.sql')) {
        // Historic replay assertions already consumed these snapshots. Their
        // enum-typed columns otherwise keep the retired domain type alive.
        await db.exec('drop table if exists pg_temp.legacy_stock_snapshot,pg_temp.exchange_stock_snapshot;');
        await db.exec(read('canonical.before.sql'));
      }
      if(name.endsWith('_employee_monthly_payroll.sql')) await db.exec(read('payroll-legacy.before.sql'));
      if(name.endsWith('_logistics_overhaul.sql')) await db.exec('drop table if exists pg_temp.exchange_transit_snapshot;');
      if(name.endsWith('_canonical_accounting.sql')) await db.exec(read('accounting-normalization.before.sql'));
      if(name.endsWith('_unified_accounting_foundation.sql')) {
        // Preserve the original contract suites at their owning migration
        // boundary. The next forward model deliberately removes buying-price
        // overrides and unvalued stock APIs.
        await db.exec(read('fixture-helpers.sql'));
        for(const suite of ['purchase-wallets.sql','authorization.sql','receipt_printers.sql','inventory.sql','sale-tier.sql','pos-integrity.sql','customers.sql','reporting.sql','finance.sql','bottles.sql','employees.sql','accounting.sql']) report('historical '+suite,await db.exec(read(suite)));
      }
      const definition = readFileSync(new URL('../migrations/'+name,import.meta.url),'utf8');
      try {
        await db.exec(name.includes('canonical_development_model') && !process.argv.includes('--deployment-batch') ? 'begin;\n'+definition+'\ncommit;' : definition);
      } catch(error) { console.error('Migration:',name,'position:',error.position,'context:',definition.slice(Math.max(0,Number(error.position)-160),Number(error.position)+80)); throw error; }
      if(name.endsWith('_purchase_transit_workflow.sql')) {
      await db.exec(`do $$ begin if exists(select 1 from workflow_preservation s where
        s.stock is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(i)-'brand'-'cylinder_weight' order by tenant_id,item_id)::text,'')) from public.items i)
        or s.wallets is distinct from (select md5(coalesce(jsonb_agg(jsonb_build_array(tenant_id,wallet_id,type,balance,created_at,updated_at) order by tenant_id,wallet_id)::text,'')) from public.wallets w where type in ('dealership','logistics'))
        or s.movements is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(m) order by tenant_id,movement_id)::text,'')) from public.inventory_movements m)
        or s.transactions is distinct from (select md5(coalesce(jsonb_agg(jsonb_build_array(tenant_id,transaction_id,wallet_id,amount,type,reference_id,description,created_at) order by tenant_id,transaction_id)::text,'')) from public.wallet_transactions w))
        then raise exception 'Workflow migration changed stock or money'; end if; end $$;`);
      console.log('Workflow migration preserves stock, wallet balances and all ledger history.');
      }
      if(name.endsWith('_canonical_development_model.sql')) report('canonical normalization',await db.exec(read('canonical.after.sql')));
      if(name.endsWith('_canonical_accounting.sql')) report('accounting normalization',await db.exec(read('accounting-normalization.after.sql')));
      if(name.endsWith('_dynamic_settlement_receipts.sql')) report('settlement history preservation',await db.exec(read('settlement-legacy.after.sql')));
      if(name.endsWith('_aggregate_bottle_settlement.sql')) report('tracked bottle preservation',await db.exec(read('bottles-aggregate.after.sql')));
      if(name.endsWith('_sales_bottle_receivables.sql')) report('bottle legacy preservation',await db.exec(read('bottles-legacy.after.sql')));
      if(name.endsWith('_employee_monthly_payroll.sql')) { report('payroll historical preservation',await db.exec(read('payroll-legacy.after.sql'))); if (!process.argv.includes('--deployment-batch')) report('historical payroll contract',await db.exec(read('payroll.sql'))); }
      if(name.endsWith('_sale_pricing_tier.sql')) report('sale tier backfill',await db.exec(read('sale-tier-legacy.after.sql')));
      if(name.endsWith('_multi_wallet_finance.sql')) report('wallet migration',await db.exec(read('finance-legacy.after.sql')));
    }
    if(process.argv.includes('--deployment-batch')&&!process.argv.includes('--schema-only')) await db.exec('commit;');
    console.log('Migration replay:', (await db.query('select version()')).rows[0].version);
    await db.exec('set row_security=on; set check_function_bodies=on;');
    await db.exec(read('fixture-helpers.sql'));
    for(const name of ['financial-system-dimensions.sql','financial-stove-transport.sql','financial-custom-types.sql','financial-payroll.sql','commission-pairs.sql','finance-entry-directory.sql','fifo-commissions.sql','authorization-current.sql','accounting-overview.sql']) {
      await db.exec('set row_security=on;');
      report(name,await db.exec(read(name)));
    }
    if(process.argv.includes('--performance')) {
      const results=await db.exec(read('customer-performance.sql'));
      for(const result of results) if(result.rows.length) console.log(JSON.stringify(result.rows));
      report('customer-performance.sql',results);
    }
  } catch(error) {
    console.error({ message:error.message,detail:error.detail,where:error.where });
    process.exitCode=1;
  } finally { await db.close(); }
}
