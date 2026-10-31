// Verify the unified accounting contracts and races on a disposable VPS copy.
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { parseEnv } from 'node:util';
assert(process.argv.includes('--vps'), 'Explicit --vps target required');
const config = parseEnv(readFileSync('deploy/.env.backend', 'utf8'));
assert.equal(config.VPS_HOST, '144.79.249.4');
assert.equal(config.VPS_PROJECT_DIR, '/opt/lpg');
const ssh = [
  ...(config.VPS_SSH_KEY ? ['-i', config.VPS_SSH_KEY] : []),
  '-p',
  config.VPS_PORT,
  '-o',
  'BatchMode=yes',
  '-o',
  'StrictHostKeyChecking=yes',
  '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3',
  `${config.VPS_USER}@${config.VPS_HOST}`,
];
const migrations = readdirSync('supabase/migrations')
  .filter((n) => /^\d{14}_.+\.sql$/.test(n))
  .sort()
  .map((n) => ({
    version: n.slice(0, 14),
    sql: readFileSync('supabase/migrations/' + n, 'utf8'),
  }));
const names = process.argv.filter((v) => v.endsWith('.sql'));
const tests = (names.length ? names : ['unified-accounting.sql','unified-opening-transits.sql','accounting-corrections.sql'])
  .filter((n) => existsSync('supabase/tests/' + n))
  .map((n) => ({
    name: n,
    sql:
      readFileSync('supabase/tests/fixture-helpers.sql', 'utf8') +
      '\n' +
      (n === 'spending.sql'
        ? 'begin;\n' +
          readFileSync('supabase/tests/logistics.sql', 'utf8')
            .replace(/^begin;\s*/, '')
            .replace(/rollback;\s*$/, '') +
          '\n' +
          readFileSync('supabase/tests/spending.sql', 'utf8') +
          '\nrollback;'
        : readFileSync('supabase/tests/' + n, 'utf8')),
  }));
const concurrency = readFileSync(
  'supabase/tests/unified-accounting-concurrency.sql',
  'utf8',
);
const python = `import concurrent.futures,json,os,re,subprocess,sys,tempfile,time,uuid
os.umask(0o077)
p=json.load(sys.stdin)
cmd=['docker','compose','--project-directory','/opt/lpg','--env-file','/opt/lpg/.env','-p','lpg','-f','/opt/lpg/compose.yml','-f','/opt/lpg/compose.vps.yml','exec','-T','db']
def run(args,**kw):
 r=subprocess.run(cmd+args,stderr=subprocess.PIPE,**kw)
 if r.returncode: raise RuntimeError(r.stderr.decode(errors='replace')[-7000:])
 return r.stdout
def sql(db,source): return run(['psql','-X','-U','supabase_admin','-d',db,'-qAt','-v','ON_ERROR_STOP=1'],input=source.encode(),stdout=subprocess.PIPE).decode()
db='lpg_accounting_test_'+uuid.uuid4().hex[:16]
created=False
try:
 with tempfile.TemporaryFile() as dump:
  run(['pg_dump','-U','supabase_admin','-d','postgres','-Fc'],stdout=dump)
  sql('postgres','CREATE DATABASE '+db+' TEMPLATE template0 OWNER postgres;');created=True;dump.seek(0)
  run(['pg_restore','-U','supabase_admin','-d',db,'--exit-on-error','--single-transaction'],stdin=dump,stdout=subprocess.PIPE)
 preservation='select jsonb_build_array('+','.join("(select md5(coalesce(jsonb_agg((to_jsonb(r)-'valuation'-'business_category'-'product_name'-'product_type_id'-'image_url') order by (to_jsonb(r)-'valuation'-'business_category'-'product_name'-'product_type_id'-'image_url')::text)::text,'')) from public."+t+" r)" for t in ['inventory_movements','items','sales','sale_items','purchase_items','employee_payments'])+');'
 before=sql(db,preservation)
 applied=set(sql(db,'select version from supabase_migrations.schema_migrations;').splitlines())
 for m in p['migrations']:
  if m['version'] not in applied:
   sql(db,'begin; set check_function_bodies=on; '+m['sql']+' commit;')
   print('PASS migration '+m['version'],flush=True)
 assert sql(db,preservation)==before,'Migration changed original stock, sales, purchase lines or employee payments'
 assert sql(db,"select count(*) from public.wallets w where balance<>opening_balance+coalesce((select sum(amount) from public.wallet_transactions x where x.tenant_id=w.tenant_id and x.wallet_id=w.wallet_id),0);").strip()=='0','Wallet reconciliation failed'
 print('PASS original stock/business evidence preservation and all wallet reconciliation',flush=True)
 for test in p['tests']:
  result=sql(db,test['sql'])
  print('PASS suite '+test['name'],flush=True)
  for line in result.splitlines():
   if line.startswith('PASS:'): print(line,flush=True)

 sql(db,'begin; '+p['concurrency']+' commit;')
 fixture=json.loads(sql(db,'select row_to_json(f) from app_private.unified_concurrency_fixture f;').strip())
 actor='ae910000-0000-4000-8000-000000000001'
 today=sql(db,"select (now() at time zone 'Asia/Dhaka')::date;").strip()
 def literal(value):return "'"+json.dumps(value).replace("'","''")+"'::jsonb"
 def call(expression):
  result=sql(db,"begin;set local role authenticated;select set_config('request.jwt.claim.sub','"+actor+"',true);select "+expression+";commit;")
  return json.loads(result.splitlines()[-1])
 def operation(body,key=None):return call("public.accounting_operation("+literal(body)+",'"+(key or str(uuid.uuid4()))+"')")
 def repayment(wallet,amount,key=None):
  try:return operation(dict(action='loan_repay',loan_id=fixture['loan'],wallet_id=fixture[wallet],amount=amount,date=today,description='Concurrent principal repayment'),key)
  except RuntimeError as e:
   assert 'outstanding principal' in str(e),str(e)
   return None
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(lambda wallet:repayment(wallet,700),['wallet','bank']))
 assert sum(x is not None for x in results)==1,'Concurrent loan repayments overpaid principal'
 key=str(uuid.uuid4())
 with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:results=list(pool.map(lambda _:repayment('wallet',300,key),range(8)))
 assert len(set(json.dumps(x,sort_keys=True) for x in results))==1,'Duplicate repayment changed its original result'
 def depreciation(wallet):
  try:return operation(dict(action='asset_depreciate',asset_id=fixture['asset'],amount=700,date=today,description='Concurrent depreciation'))
  except RuntimeError as e:
   assert 'remaining book value' in str(e),str(e)
   return None
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(depreciation,['wallet','bank']))
 assert sum(x is not None for x in results)==1,'Concurrent depreciation exceeded book value'
 def sell_or_cancel(action):
  try:
   if action=='cancel':return call("public.initiate_purchase_cancellation('"+fixture['purchase']+"',2,'CANCEL','"+str(uuid.uuid4())+"')")
   return call("public.create_pos_sale('01700000499','Concurrency buyer',null,null,'retail',0,0,null,"+literal([dict(item_id=fixture['item'],type='package',quantity=7,unit_price=200)])+",null,'"+str(uuid.uuid4())+"',null,null)")
  except RuntimeError as e:
   assert 'stock' in str(e).lower(),str(e)
   return None
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(sell_or_cancel,['cancel','sale']))
 assert sum(x is not None for x in results)==1,'Cancellation and sale both consumed the same stock'
 # Check every control account against its operational projection after races.
 assert sql(db,"select count(*) from public.wallets w where w.tenant_id='"+fixture['t']+"' and w.balance<>coalesce((select sum(amount) from public.accounting_lines l where l.tenant_id=w.tenant_id and l.account='cash' and l.entity_id=w.wallet_id),0);").strip()=='0','Journal/wallet discrepancy after concurrency'
 assert sql(db,"select count(*) from public.inventory_costs c join public.items i using(tenant_id,item_id) where c.tenant_id='"+fixture['t']+"' and (c.filled_quantity<>i.filled_quantity or c.empty_quantity<>i.empty_quantity or c.filled_value+c.empty_value<>coalesce((select sum(amount) from public.accounting_lines l where l.tenant_id=c.tenant_id and l.entity_id=c.item_id and l.account in ('inventory_lpg','inventory_stove')),0));").strip()=='0','Stock/cost/journal discrepancy after concurrency'
 assert sql(db,"select count(*) from(select journal_id from public.accounting_lines group by tenant_id,journal_id having sum(amount)<>0)x;").strip()=='0','Unbalanced journal after concurrency'
 print('PASS concurrent loan repayment across wallets, eight matching retries, depreciation ceiling, cancellation versus POS, and exact wallet/stock/journal reconciliation',flush=True)

 if p['performance']:
  print('START 20,000-journal performance fixture (all balance constraints enabled)',flush=True)
  sql(db,"begin;with headers as(insert into public.accounting_journals(tenant_id,source,source_id,event_key,occurred_on,description) select '"+fixture['t']+"','performance',gen_random_uuid(),n::text,'"+today+"','Disposable performance evidence' from generate_series(1,20000)n returning tenant_id,journal_id) insert into public.accounting_lines(tenant_id,journal_id,line_no,account,amount) select h.tenant_id,h.journal_id,x.n,x.account,x.amount from headers h cross join(values(1,'other_assets',1),(2,'other_liability',-1)) x(n,account,amount);analyze public.accounting_journals;analyze public.accounting_lines;commit;")
  times=[]
  for _ in range(3):
   start=time.perf_counter();report=call("public.get_finance_analysis("+literal(dict(business_id=fixture['t'],**{'from':today,'to':today},grain='day'))+")");times.append(round((time.perf_counter()-start)*1000))
   assert report['totals']['profit']==report['totals']['position_profit']
  print('PASS 20,000-journal / 40,000-line aggregate report with exact period reconciliation; round-trip milliseconds '+str(times),flush=True)

finally:
 if created:
  assert re.fullmatch(r'lpg_accounting_test_[a-f0-9]{16}',db)
  sql('postgres','DROP DATABASE '+db+';')
`;
const quote = (value) => "'" + value.replaceAll("'", "'\"'\"'") + "'";
try {
  const output = execFileSync(
    'ssh',
    [...ssh, 'sudo -n python3 -c ' + quote(python)],
    {
      input: JSON.stringify({ migrations, tests, concurrency, performance: process.argv.includes('--performance') }),
      encoding: 'utf8',
      maxBuffer: 12 * 1024 * 1024,
      stdio: ['pipe', 'inherit', 'pipe'],
    },
  );
  if (output) process.stdout.write(output);
} catch (error) {
  console.error(error.stdout?.toString() ?? '');
  console.error(error.stderr?.toString() ?? error.message);
  process.exitCode = 1;
}
