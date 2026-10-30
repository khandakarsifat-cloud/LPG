// Verify on a newly named, disposable PostgreSQL database on the primary VPS.
// The application database is read only (pg_dump). Never reset or restore it.
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { parseEnv } from 'node:util';

assert(process.argv.includes('--vps'), 'Explicit --vps target required');
const config = parseEnv(readFileSync('deploy/.env.backend', 'utf8'));
assert.equal(config.VPS_HOST, '144.79.249.4'); assert.equal(config.VPS_PROJECT_DIR, '/opt/lpg');
const ssh = [...(config.VPS_SSH_KEY ? ['-i', config.VPS_SSH_KEY] : []), '-p', config.VPS_PORT, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', `${config.VPS_USER}@${config.VPS_HOST}`];
const migrations = process.argv.includes('--with-migrations') ? readdirSync('supabase/migrations').filter(name => /^\d{14}_.+\.sql$/.test(name)).sort().map(name => ({ version: name.slice(0, 14), sql: readFileSync('supabase/migrations/' + name, 'utf8') })) : [];
const tests = readFileSync('supabase/tests/logistics.sql', 'utf8')+'\n'+readFileSync('supabase/tests/spending.sql','utf8');
const regressions = ['authorization.sql','employees.sql','purchase-wallets.sql'].map(name => ({ name, source: readFileSync('supabase/tests/fixture-helpers.sql', 'utf8') + '\n' + readFileSync('supabase/tests/' + name, 'utf8') }));
const python = `import concurrent.futures,json,os,re,subprocess,sys,tempfile,uuid
os.umask(0o077)
payload=json.load(sys.stdin)
cmd=['docker','compose','--project-directory','/opt/lpg','--env-file','/opt/lpg/.env','-p','lpg','-f','/opt/lpg/compose.yml','-f','/opt/lpg/compose.vps.yml','exec','-T','db']
def run(args,**kw):
 r=subprocess.run(cmd+args,stderr=subprocess.PIPE,**kw)
 if r.returncode: raise RuntimeError(r.stderr.decode(errors='replace')[-5000:])
 return r.stdout
def sql(database,source):
 return run(['psql','-X','-U','supabase_admin','-d',database,'-qAt','-v','ON_ERROR_STOP=1'],input=source.encode(),stdout=subprocess.PIPE).decode()
db='lpg_logistics_test_'+uuid.uuid4().hex[:16]
created=False
try:
 with tempfile.TemporaryFile() as dump:
  run(['pg_dump','-U','supabase_admin','-d','postgres','-Fc'],stdout=dump)
  sql('postgres','CREATE DATABASE '+db+' TEMPLATE template0 OWNER postgres;')
  created=True
  dump.seek(0)
  run(['pg_restore','-U','supabase_admin','-d',db,'--exit-on-error','--single-transaction'],stdin=dump,stdout=subprocess.PIPE)
 preservation="select jsonb_build_array("+','.join("(select md5(coalesce(jsonb_agg(to_jsonb(r) order by to_jsonb(r)::text)::text,'')) from public."+table+" r)" for table in ['wallets','wallet_transactions','inventory_movements','items','sales','sale_items','purchase_items','employee_payments','employee_payment_entries'])+');'
 before=sql(db,preservation)
 applied=set(sql(db,'select version from supabase_migrations.schema_migrations;').splitlines())
 for definition in payload['migrations']:
  if definition['version'] not in applied:
   sql(db,'begin; set check_function_bodies=on; '+definition['sql']+' commit;')
 assert sql(db,preservation)==before,'Migration changed financial or inventory evidence'
 print('PASS: migration preserves every existing wallet, ledger, stock, sale, purchase line and employee payment',flush=True)
 result=sql(db,'begin; set check_function_bodies=on; '+payload['tests']+' commit;')
 for line in result.splitlines():
  if line.startswith('PASS:'): print(line,flush=True)
 # Concurrent financial requests use only the committed disposable SQL fixtures.
 actor='92222222-2222-4222-8222-222222222222'
 def call(expression):
  result=sql(db,"begin; set local role authenticated; select set_config('request.jwt.claim.sub','"+actor+"',true); select "+expression+"; commit;")
  return json.loads(result.splitlines()[-1])
 def literal(value): return "'"+json.dumps(value).replace("'","''")+"'::jsonb"
 driver=sql(db,"select employee_id from public.employees where tenant_id='91111111-1111-4111-8111-111111111111' and name='Logistics Driver One';").strip()
 wallet=sql(db,"select wallet_id from public.wallets where tenant_id='91111111-1111-4111-8111-111111111111' and type='cash';").strip()
 vehicle=call("public.save_vehicle("+literal(dict(name='Concurrent vehicle',serial_no='CONCURRENT',capacity=0,driver_employee_id=driver))+",'"+str(uuid.uuid4())+"')")['vehicle_id']
 transit=call("public.create_custom_transit("+literal(dict(vehicle_id=vehicle,fee=1000,client_name='Concurrent client',destination='Dhaka'))+",'"+str(uuid.uuid4())+"')")['transit_id']
 call("public.save_transit_costs('"+transit+"',"+literal(dict(driver_cost=500,helper_cost=0,oil_cost=100,others_cost=0))+",1)")
 today=sql(db,"select (now() at time zone 'Asia/Dhaka')::date;").strip()
 def pay(amount,request):
  body=dict(action='pay',items=[dict(employee_id=driver,kind='trips',trip_count=1,transit_id=transit,trip_role='driver',payment_date=today,payments=[dict(wallet_id=wallet,amount=amount)])])
  try: return call("public.employee_payment_operation("+literal(body)+",'"+request+"')")
  except RuntimeError as error:
   assert 'exceeds' in str(error),str(error)
   return None
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
  results=list(pool.map(lambda _:pay(300,str(uuid.uuid4())),range(2)))
 assert sum(x is not None for x in results)==1,'Competing payments overpaid the role'
 request=str(uuid.uuid4())
 with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
  results=list(pool.map(lambda _:pay(200,request),range(8)))
 assert len(set(json.dumps(x) for x in results))==1,'Duplicate requests created different payments'
 assert call("public.get_transit_payroll('"+transit+"')")['driver_paid']==500
 def complete(_): return call("public.transition_transit('"+transit+"','complete',4)")
 with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool: list(pool.map(complete,range(4)))
 assert sql(db,"select count(*) from public.wallet_transactions where reference_id='"+transit+"' and type='transit_close_cost';").strip()=='1'
 assert sql(db,"select count(*) from public.wallets w where tenant_id='91111111-1111-4111-8111-111111111111' and balance<>opening_balance+coalesce((select sum(amount) from public.wallet_transactions x where x.tenant_id=w.tenant_id and x.wallet_id=w.wallet_id),0);").strip()=='0'
 print('PASS: competing partial payments cannot overpay; eight duplicate requests pay once; four completions charge once; all wallets reconcile',flush=True)
 for suite in payload['regressions']:
  result=sql(db,suite['source'])
  for line in result.splitlines():
   if 'PASS:' in line: print(suite['name']+': '+line,flush=True)
finally:
 if created:
  assert re.fullmatch(r'lpg_logistics_test_[a-f0-9]{16}',db)
  sql('postgres','DROP DATABASE '+db+';')
`;
const quote = value => "'" + value.replaceAll("'", "'\"'\"'") + "'";
try {
 const output = execFileSync('ssh', [...ssh, 'sudo -n python3 -c ' + quote(python)], { input: JSON.stringify({ migrations, tests, regressions }), encoding: 'utf8', maxBuffer: 8 * 1024 * 1024, stdio: ['pipe', 'pipe', 'pipe'] });
 assert.match(output, /PASS:/); process.stdout.write(output);
} catch (error) {
 console.error(error.stderr?.toString() ?? error.message); process.exitCode = 1;
}
