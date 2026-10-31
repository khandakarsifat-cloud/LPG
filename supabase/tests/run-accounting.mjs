// Apply the current pending batch and run accounting suites on a disposable VPS copy.
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
const tests = (names.length ? names : ['accounting.sql'])
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
  'supabase/tests/accounting-concurrency.sql',
  'utf8',
);
const python = `import concurrent.futures,json,os,re,subprocess,sys,tempfile,uuid
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
 preservation='select jsonb_build_array('+','.join("(select md5(coalesce(jsonb_agg(to_jsonb(r) order by to_jsonb(r)::text)::text,'')) from public."+t+" r)" for t in ['inventory_movements','items','sales','sale_items','purchase_items','employee_payments'])+');'
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
 fixture=json.loads(sql(db,'select row_to_json(f) from app_private.accounting_concurrency_fixture f;').strip())
 actor='ac910000-0000-4000-8000-000000000001'
 today=sql(db,"select (now() at time zone 'Asia/Dhaka')::date;").strip()
 def literal(value): return "'"+json.dumps(value).replace("'","''")+"'::jsonb"
 def call(expression):
  result=sql(db,"begin;set local role authenticated;select set_config('request.jwt.claim.sub','"+actor+"',true);select "+expression+";commit;")
  return json.loads(result.splitlines()[-1])
 def pay(kind,amount,key):
  body=dict(transit_id=fixture['transit'],kind=kind,payment_date=today,payments=[dict(wallet_id=fixture['wallet'],amount=amount)])
  try:return call("public.record_operating_payment("+literal(body)+",'"+key+"')")
  except RuntimeError as error:
   assert 'exceeds' in str(error),str(error)
   return None
 for kind,first,rest in [('expense',70,30),('client_receipt',600,400)]:
  with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool: results=list(pool.map(lambda _:pay(kind,first,str(uuid.uuid4())),range(2)))
  assert sum(x is not None for x in results)==1,'Competing payments overpaid '+kind
  key=str(uuid.uuid4())
  with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool: results=list(pool.map(lambda _:pay(kind,rest,key),range(8)))
  assert len(set(json.dumps(x) for x in results))==1,'Duplicate operating request created more than one result'
 result=call("public.get_transit('"+fixture['transit']+"')")
 assert result['operating_paid']==100 and result['client_paid']==1000 and result['profit']==900
 revision=result['revision']
 with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool: list(pool.map(lambda _:call("public.transition_transit('"+fixture['transit']+"','complete',"+str(revision)+")"),range(4)))
 def price(value):
  body=dict(item_id=fixture['item'],price_type='package',is_manual=True,expected=fixture['history'],price=value,reason='Concurrent owner change')
  try:return call("public.set_product_buying_price("+literal(body)+",'"+str(uuid.uuid4())+"')")
  except RuntimeError as error:
   assert 'changed' in str(error),str(error)
   return None
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool: results=list(pool.map(price,[1100,1200]))
 assert sum(x is not None for x in results)==1,'Stale concurrent buying prices both committed'
 assert sql(db,"select count(*) from public.product_buying_price_history where tenant_id='"+fixture['t']+"' and item_id='"+fixture['item']+"';").strip()=='2'
 assert sql(db,"select count(*) from public.wallets w where balance<>opening_balance+coalesce((select sum(amount) from public.wallet_transactions x where x.tenant_id=w.tenant_id and x.wallet_id=w.wallet_id),0);").strip()=='0'
 print('PASS concurrent partial payments/collections, eight matching retries, four completions, stale price races and exact wallet reconciliation',flush=True)
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
      input: JSON.stringify({ migrations, tests, concurrency }),
      encoding: 'utf8',
      maxBuffer: 12 * 1024 * 1024,
      stdio: ['pipe', 'pipe', 'pipe'],
    },
  );
  process.stdout.write(output);
} catch (error) {
  console.error(error.stdout?.toString() ?? '');
  console.error(error.stderr?.toString() ?? error.message);
  process.exitCode = 1;
}
