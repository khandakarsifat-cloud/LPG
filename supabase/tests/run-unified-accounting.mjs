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
const accessHelpers = readFileSync('supabase/tests/account-access-fixtures.sql','utf8');
const adaptAccess = source => source.replaceAll('public.setup_business(', 'pg_temp.fixture_business(').replace(/set_config\('request\.jwt\.claim\.sub',([^;]*?),true\)/g,'pg_temp.fixture_identity($1)');
const tests = (names.length ? names : ['dashboard-stove-types.sql','dashboard.sql','financial-system-dimensions.sql','financial-stove-transport.sql','financial-custom-types.sql','financial-payroll.sql','commission-pairs.sql','finance-entry-directory.sql','fifo-commissions.sql','authorization-current.sql','unified-opening-transits.sql','accounting-overview.sql'])
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
for (const suite of tests) suite.sql = accessHelpers + '\n' + adaptAccess(suite.sql);
const concurrency = accessHelpers + '\n' + adaptAccess(readFileSync('supabase/tests/fixture-helpers.sql','utf8') + '\n' + readFileSync(
  'supabase/tests/unified-accounting-concurrency.sql',
  'utf8',
));
const historicalReport = readFileSync('supabase/migrations/20261031140003_financial_analysis_and_audit.sql','utf8');
const baseline = historicalReport.slice(0,historicalReport.indexOf('-- Page headers')).replaceAll('app_private.accounting_position','app_private.benchmark_full_position').replaceAll('public.get_finance_analysis','public.benchmark_full_analysis') + '\n' +
 readFileSync('supabase/migrations/20261023012148_sales_bottle_receivables.sql','utf8').split('create or replace function public.get_customer_directory')[1].split('end $$;')[0].replace(/^/, 'create or replace function public.benchmark_full_directory')+'end $$;';
const normalizedBaseline = baseline.replaceAll('case when s.payment_tracking then greatest(0,s.total_amount+s.additional_charges-s.paid_amount) else 0 end due','greatest(0,s.total_amount+s.additional_charges-s.paid_amount) due');
const benchmark = 'grant execute on function public.benchmark_full_analysis(jsonb),public.benchmark_full_directory(jsonb,integer,integer,uuid) to authenticated;\n' + readFileSync('supabase/tests/accounting-overview-performance.sql','utf8');
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
  run(['pg_dump','--exclude-extension=pg_cron','--exclude-schema=cron','-U','supabase_admin','-d','postgres','-Fc'],stdout=dump)
  sql('postgres','CREATE DATABASE '+db+' TEMPLATE template0 OWNER postgres;');created=True;dump.seek(0)
  run(['pg_restore','-U','supabase_admin','-d',db,'--exit-on-error','--single-transaction'],stdin=dump,stdout=subprocess.PIPE)
 preservation='select jsonb_build_array('+','.join("(select md5(coalesce(jsonb_agg((to_jsonb(r)-'allocations'-'valuation'-'movement_no'-'shell_unit_cost'-'empty_quantity'-'empty_quantity_change'-'business_category'-'product_name'-'product_type_id'-'image_url'-'low_stock_threshold') order by (to_jsonb(r)-'allocations'-'valuation'-'movement_no'-'shell_unit_cost'-'empty_quantity'-'empty_quantity_change'-'business_category'-'product_name'-'product_type_id'-'image_url'-'low_stock_threshold')::text)::text,'')) from public."+t+" r)" for t in ['inventory_movements','items','sales','sale_items','purchase_items','employee_payments'])+');'
 before=sql(db,preservation)
 stock_before=sql(db,"select jsonb_agg(jsonb_build_array(tenant_id,item_id,filled_quantity,empty_quantity) order by tenant_id,item_id) from public.items;")
 if sql(db,"select to_regclass('app_private.inventory_normalization_audit') is not null;").strip()=='t':
  stock_before=sql(db,"select jsonb_agg(jsonb_build_array(i.tenant_id,i.item_id,i.filled_quantity,i.empty_quantity-coalesce(q.qty,0)) order by i.tenant_id,i.item_id) from public.items i left join lateral(select sum(-(a.original->>'empty_quantity_change')::integer) qty from app_private.inventory_normalization_audit a where a.tenant_id=i.tenant_id and (a.original->>'item_id')::uuid=i.item_id)q on true;")
 applied=set(sql(db,'select version from supabase_migrations.schema_migrations;').splitlines())
 for m in p['migrations']:
  if m['version'] not in applied:
   sql(db,'begin; set check_function_bodies=on; '+m['sql']+' commit;')
   print('PASS migration '+m['version'],flush=True)
 assert sql(db,preservation)==before,'Migration changed source identities, filled stock, sales, invoice prices or employee payments'
 if sql(db,"select to_regclass('app_private.inventory_normalization_audit') is not null;").strip()=='t':
  stock_after=sql(db,"select jsonb_agg(jsonb_build_array(i.tenant_id,i.item_id,i.filled_quantity,i.empty_quantity-coalesce(q.qty,0)) order by i.tenant_id,i.item_id) from public.items i left join lateral(select sum(-(a.original->>'empty_quantity_change')::integer) qty from app_private.inventory_normalization_audit a where a.tenant_id=i.tenant_id and (a.original->>'item_id')::uuid=i.item_id)q on true;")
  assert stock_after==stock_before,'Migration stock change differs from audited duplicate-shell correction'
 else:
  assert sql(db,"select jsonb_agg(jsonb_build_array(tenant_id,item_id,filled_quantity,empty_quantity) order by tenant_id,item_id) from public.items;")==stock_before,'Unexpected stock normalization'

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
  result=sql(db,p['accessHelpers']+"begin;set local role authenticated;select pg_temp.fixture_identity('"+actor+"');select "+expression+";commit;")
  return json.loads(result.splitlines()[-1])
 def operation(body,key=None):return call("public.accounting_operation("+literal(body)+",'"+(key or str(uuid.uuid4()))+"')")
 def repayment(wallet,amount,key=None):
  try:return operation(dict(action='loan_repay',loan_id=fixture['loan'],wallet_id=fixture[wallet],amount=amount,date=today,description='Concurrent principal repayment'),key)
  except RuntimeError as e:
   assert 'outstanding principal' in str(e),str(e)
   return None
 def monthly_rate(rate,revision,key):
  try:return call("public.set_monthly_commission("+literal(dict(item_id=fixture['lpg'],month=today[:7]+'-01',package_rate=rate,refill_rate=rate,expected_revision=revision,reason='Concurrent supplier confirmation'))+",'"+key+"')")
  except RuntimeError as e:
   assert 'Monthly commission changed' in str(e),str(e)
   return None
 rate_key=str(uuid.uuid4())
 with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:rates=list(pool.map(lambda _:monthly_rate(25,0,rate_key),range(8)))
 assert all(x is not None for x in rates),'Matching commission retries lost their result'
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:rates=list(pool.map(lambda rate:monthly_rate(rate,1,str(uuid.uuid4())),[35,45]))
 assert sum(x is not None for x in rates)==1,'Concurrent monthly edits overwrote a newer rate'
 print('PASS eight matching monthly-rate retries and concurrent stale-edit exclusion',flush=True)
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
 # New dimensional writes share source locks and recoverable request identity.
 custom=call("public.save_financial_type("+literal(dict(name='Concurrent electricity',account='operating_expense',allocations=dict(lpg=70,stove=30)))+")")['type_id']
 custom_key=str(uuid.uuid4())
 def custom_entry():return call("public.record_financial_entry("+literal(dict(type_id=custom,expected_revision=1,wallet_id=fixture['wallet'],amount=1000,date=today,description='Concurrent shared cost'))+",'"+custom_key+"')")
 with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:shared=list(pool.map(lambda _:custom_entry(),range(8)))
 assert len(set(json.dumps(x,sort_keys=True) for x in shared))==1,'Shared entry retries posted twice'
 original=shared[0]['entry_id']
 def return_custom(amount,key):
  try:return call("public.record_financial_entry("+literal(dict(reversal_of=original,wallet_id=fixture['wallet'],amount=amount,date=today,description='Concurrent actual returned funds'))+",'"+key+"')")
  except RuntimeError as e:
   assert 'Return exceeds' in str(e),str(e)
   return None
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:returned=list(pool.map(lambda _:return_custom(700,str(uuid.uuid4())),range(2)))
 assert sum(x is not None for x in returned)==1,'Concurrent custom returns exceeded their original amount'
 return_key=str(uuid.uuid4())
 with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:returned=list(pool.map(lambda _:return_custom(300,return_key),range(8)))
 assert len(set(json.dumps(x,sort_keys=True) for x in returned))==1,'Shared return retries posted twice'
 assert sql(db,"select sum(amount) from public.financial_entries where tenant_id='"+fixture['t']+"' and reversal_of='"+original+"';").strip()=='1000.00','Custom settlement mismatch'
 print('PASS eight shared-cost retries, concurrent partial-return ceiling and eight matching return retries',flush=True)

 brand=sql(db,"select brand_id from public.items where tenant_id='"+fixture['t']+"' and item_id='"+fixture['lpg']+"';").strip()
 plant=call("public.create_gas_plant('Concurrent transport plant','"+brand+"','Dhaka')")['plant_id']
 crew=[]
 for role,phone in [('Driver','01700000971'),('Helper','01700000972')]:
  crew.append(call("public.save_employee("+literal(dict(name='Concurrent '+role,employee_type_name=role,business_unit='truck_business',phones=[dict(phone=phone,is_primary=True)],terms=dict(monthly_salary=0,effective_from=today,is_active=True)))+",'"+str(uuid.uuid4())+"')")['employee_id'])
 vehicle=call("public.save_vehicle("+literal(dict(name='Concurrent transport vehicle',serial_no='CONC-T1',capacity=100,book_value=0,funding='opening',driver_employee_id=crew[0],helper_employee_id=crew[1]))+",'"+str(uuid.uuid4())+"')")['vehicle_id']
 transport=call("public.create_purchase("+literal(dict(request_id=str(uuid.uuid4()),plant_id=plant,vehicle_id=vehicle,transport_cost=3000,transport_wallet_id=fixture['bank'],items=[dict(item_id=fixture['lpg'],type='package',quantity=1,unit_price=2500,shell_unit_cost=1500)]))+")")['purchase_id']
 def dispatch_same():
  try:return call("public.dispatch_purchase('"+transport+"',1,'"+today+"')")
  except RuntimeError as e:
   assert any(word in str(e).lower() for word in ['created','dispatch','changed','revision']),str(e)
   return None
 with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:departures=list(pool.map(lambda _:dispatch_same(),range(8)))
 assert any(x is not None for x in departures),'All concurrent dispatches failed'
 assert sql(db,"select count(*) from public.wallet_transactions where tenant_id='"+fixture['t']+"' and reference_id='"+transport+"' and type like 'internal_transport_%';").strip()=='2','Internal transport charged twice'
 call("public.initiate_purchase_cancellation('"+transport+"',2,'CANCEL','"+str(uuid.uuid4())+"')")
 assert sql(db,"select sum(amount) from public.wallet_transactions where tenant_id='"+fixture['t']+"' and reference_id='"+transport+"';").strip()=='0.00','Internal transport return changed organization cash'
 print('PASS eight concurrent internal transport dispatches produce one cash pair; cancellation restores source business balances',flush=True)
 # Check every control account against its operational projection after races.
 assert sql(db,"select count(*) from public.wallets w where w.tenant_id='"+fixture['t']+"' and w.balance<>coalesce((select sum(amount) from public.accounting_lines l where l.tenant_id=w.tenant_id and l.account='cash' and l.entity_id=w.wallet_id),0);").strip()=='0','Journal/wallet discrepancy after concurrency'
 assert sql(db,"select count(*) from public.inventory_costs c join public.items i using(tenant_id,item_id) where c.tenant_id='"+fixture['t']+"' and (c.filled_quantity<>i.filled_quantity or c.empty_quantity<>i.empty_quantity or c.filled_value+c.empty_value<>coalesce((select sum(amount) from public.accounting_lines l where l.tenant_id=c.tenant_id and l.entity_id=c.item_id and l.account in ('inventory_lpg','inventory_stove')),0));").strip()=='0','Stock/cost/journal discrepancy after concurrency'
 assert sql(db,"select count(*) from(select journal_id from public.accounting_lines group by tenant_id,journal_id having sum(amount)<>0)x;").strip()=='0','Unbalanced journal after concurrency'
 print('PASS concurrent loan repayment across wallets, eight matching retries, depreciation ceiling, cancellation versus POS, and exact wallet/stock/journal reconciliation',flush=True)

 backdate=sql(db,"select ((now() at time zone 'Asia/Dhaka')::date-40)::text;").strip()
 operation(dict(action='capital',wallet_id=fixture['wallet'],amount=10,date=backdate,description='Disposable backdated snapshot race funding'))
 race_key=str(uuid.uuid4())
 def snapshot_race(i):
  if i==0:return sql(db,"select app_private.build_accounting_snapshots('"+fixture['t']+"',24);")
  return operation(dict(action='capital',wallet_id=fixture['wallet'],amount=20,date=backdate,description='Disposable concurrent backdated contribution'),race_key)
 with concurrent.futures.ThreadPoolExecutor(max_workers=9) as pool:race=list(pool.map(snapshot_race,range(9)))
 assert len(set(json.dumps(x,sort_keys=True) for x in race[1:]))==1,'Backdated retries posted more than once'
 sql(db,"select app_private.build_accounting_snapshots('"+fixture['t']+"',24);")
 mismatch=sql(db,"with full_history as(select l.tenant_id,l.account,l.business_category,l.entity_id,sum(l.amount) amount from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where l.tenant_id='"+fixture['t']+"' and j.occurred_on<='"+today+"' group by 1,2,3,4), projected as(select * from app_private.accounting_balances(array['"+fixture['t']+"'::uuid],'"+today+"')), differences as((select * from full_history except select * from projected) union all (select * from projected except select * from full_history)) select count(*) from differences;").strip()
 assert mismatch=='0','Snapshot race lost a committed journal'
 print('PASS concurrent snapshot building, backdated source writes and eight matching retries; exact full-history recomputation',flush=True)

 def coherent_report(i):
  for j in range(5):
   if i<2:
    report=call("public.get_finance_analysis("+literal(dict(business_id=fixture['t'],**{'from':today,'to':today},grain='day'))+")")
    assert report['totals']['profit']==report['totals']['position_profit'],'Report mixed positions from different committed states'
   else:operation(dict(action='capital',wallet_id=fixture['wallet'],amount=1,date=backdate,description='Disposable report snapshot concurrency'))
 with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:list(pool.map(coherent_report,range(4)))
 print('PASS coherent opening/closing/period reports during concurrent backdated writes',flush=True)

 sql(db,'select app_private.start_reconciliation_sweep();')
 for _ in range(150):
  outcome=json.loads(sql(db,'select app_private.run_accounting_maintenance(100);').strip())
  assert outcome.get('errors',0)==0,'Reconciliation runtime error: '+str(outcome)+' '+sql(db,"select jsonb_agg(x) from(select distinct kind,diagnostic from app_private.reconciliation_findings where status='error' limit 10)x;")
  pending=sql(db,"select (select count(*) from app_private.reconciliation_sweeps where completed_at is null)+(select count(*) from app_private.reconciliation_queue where available_at<=clock_timestamp());").strip()
  if pending=='0':break
 else:raise AssertionError('Reconciliation sweep did not finish within bounded resumable calls')
 findings=sql(db,"select coalesce(jsonb_agg(x),'[]') from(select kind,status,count(*) from app_private.reconciliation_findings group by kind,status)x;").strip()
 print('PASS resumed comprehensive reconciliation across restored operational records; findings '+findings,flush=True)

 if p['performance']:
  sql(db,p['baseline'])
  result=sql(db,p['benchmark'])
  for line in result.splitlines():
   if line.startswith('BENCH:') or line.startswith('PASS:'): print(line,flush=True)
  print('START 20,000-journal performance fixture (all balance constraints enabled)',flush=True)
  sql(db,"begin;with headers as(insert into public.accounting_journals(tenant_id,source,source_id,event_key,occurred_on,description) select '"+fixture['t']+"','performance',gen_random_uuid(),n::text,'"+today+"','Disposable performance evidence' from generate_series(1,20000)n returning tenant_id,journal_id) insert into public.accounting_lines(tenant_id,journal_id,line_no,account,amount,consolidated_amount,business_category,type_id) select h.tenant_id,h.journal_id,x.n,x.account,x.amount,x.amount,'lpg',md5('lpg:type:opening_entry')::uuid from headers h cross join(values(1,'other_assets',1),(2,'other_liability',-1)) x(n,account,amount);analyze public.accounting_journals;analyze public.accounting_lines;commit;")
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
      input: JSON.stringify({ migrations, tests, concurrency, accessHelpers, baseline: normalizedBaseline, benchmark, performance: process.argv.includes('--performance') }),
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
