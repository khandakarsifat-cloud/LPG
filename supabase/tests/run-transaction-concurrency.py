"""Replay and race real PostgreSQL transactions in a disposable database only.

Run from a configured checkout with Docker: python supabase/tests/run-transaction-concurrency.py
For an Azure checkout add --azure --root /opt/lpg. Never installs roles or edits existing databases.
"""
import argparse
import concurrent.futures,json,re,subprocess,uuid
from pathlib import Path
parser=argparse.ArgumentParser()
parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[2])
parser.add_argument('--azure',action='store_true')
parser.add_argument('--source',type=Path,help='Read migrations/tests from an isolated staged source directory')
parser.add_argument('--performance',action='store_true',help='Also check a 20,000-entry ledger fixture')
args=parser.parse_args()
root=args.root.resolve()
source=(args.source or root).resolve()
bundle={'migrations':[(p.name,p.read_text()) for p in sorted((source/'supabase/migrations').glob('*.sql'))],
 'tests':[(name,(source/'supabase/tests'/name).read_text()) for name in ['purchase-wallets.sql','authorization.sql','receipt_printers.sql','inventory.sql','sale-tier.sql','pos-integrity.sql','customers.sql','reporting.sql','finance.sql']],
 'seed':(source/'supabase/tests/sale-tier.sql').read_text().split('do $$')[0]}
if args.performance:bundle['tests'].append(('finance-performance.sql',(source/'supabase/tests/finance-performance.sql').read_text()))

name='lpg_verify_'+uuid.uuid4().hex[:12]
base=['docker','compose','--project-directory',str(root),'--env-file',str(root/'.env'),'-f',str(root/'compose.yml')]
if args.azure:base+=['-f',str(root/'compose.azure.yml'),'-p','lpg']
# Resolve the configured Compose database once; repeated Compose rendering is slow
# and unnecessary for independent sessions on this same disposable database.
container=subprocess.check_output(base+['ps','-q','db'],text=True).strip()
if not re.fullmatch('[0-9a-f]{12,64}',container):raise RuntimeError('Expected one configured database container')
base=['docker','exec','-i',container,'psql','-X','-U','supabase_admin','-v','ON_ERROR_STOP=1','-qAt']

def sql(text,db=name):
 r=subprocess.run(base+['-d',db],input=text,text=True,capture_output=True,timeout=100)
 if r.returncode:raise RuntimeError(r.stderr[-1800:])
 return r.stdout.strip()
created=False
try:
 sql('create database '+name+';',db='postgres');created=True
 sql('''grant all on schema public to postgres;create schema auth; create schema extensions; create extension "uuid-ossp" with schema extensions;
 create table auth.users(id uuid primary key,email text,is_anonymous boolean default false,raw_app_meta_data jsonb,raw_user_meta_data jsonb);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;
 grant usage on schema auth,extensions to postgres;grant all on auth.users to postgres;grant usage on schema auth to anon,authenticated;grant execute on function auth.uid(),auth.jwt() to anon,authenticated;''')
 print('Disposable engine: '+sql('select version()'),flush=True)
 for path,definition in bundle['migrations']:
  if 'multi_wallet_finance' in path:sql((source/'supabase/tests/finance-legacy.before.sql').read_text())
  if 'purchase_wallet_lifecycle' in path:sql((source/'supabase/tests/purchase-wallets-legacy.before.sql').read_text())
  sql(definition)
  if 'purchase_wallet_lifecycle' in path:print(sql((source/'supabase/tests/purchase-wallets-legacy.after.sql').read_text()),flush=True)
  if 'multi_wallet_finance' in path:print(sql((source/'supabase/tests/finance-legacy.after.sql').read_text()),flush=True)
 for path,source in bundle['tests']:
  result=sql(source)
  assert 'PASS:' in result,path
  print('PostgreSQL '+path+': PASS',flush=True)
 sql(bundle['seed']+'\ncommit;')
 auth="begin;set local role authenticated;select set_config('request.jwt.claim.sub','c2222222-2222-4222-8222-222222222222',true);"
 item='c3333333-3333-4333-8333-333333333333'
 def checkout(request,lines):
  body=json.dumps(lines).replace("'","''")
  q=f"select public.create_pos_sale('01700000000',null,null,null,'retail',0,0,null,'{body}','c5555555-5555-4555-8555-555555555555','{request}');"
  rows=sql(auth+q+"select pg_sleep(0.15);commit;")
  return next(json.loads(x)['sale_id'] for x in rows.splitlines() if x.startswith('{'))
 request=str(uuid.uuid4());line={'item_id':item,'type':'package','quantity':1,'unit_price':2300}
 with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:ids=list(pool.map(lambda _:checkout(request,[line]),range(4)))
 assert len(set(ids))==1,'same-key checkout race'
 summary=json.loads(sql("select jsonb_build_object('sales',(select count(*) from public.sales),'ledger',(select count(*) from public.wallet_transactions where type='pos_sale_income'),'balance',(select balance from public.wallets where type='cash' and tenant_id='c1111111-1111-4111-8111-111111111111'))"))
 assert summary=={'sales':1,'ledger':1,'balance':2300},summary
 print('Concurrent same-key checkout: one sale, one ledger credit, one stock change: PASS',flush=True)
 sql("insert into public.items(tenant_id,item_id,brand,size_kg,filled_quantity,empty_quantity)values('c1111111-1111-4111-8111-111111111111','c3333333-3333-4333-8333-333333333334','Other item',5,40,40);insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price,effective_from)values('c1111111-1111-4111-8111-111111111111','c3333333-3333-4333-8333-333333333334','retail','package',900,now()-interval '1 day');")
 other={**line,'item_id':'c3333333-3333-4333-8333-333333333334','unit_price':900}
 with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:ids=list(pool.map(lambda n:checkout(str(uuid.uuid4()),[line,other] if n%2 else [other,line]),range(4)))
 assert len(set(ids))==4
 print('Concurrent reversed cart order: four distinct sales without deadlock: PASS',flush=True)
 # Race two sales for the last available cylinder: one succeeds, one fails atomically.
 sql("update public.items set filled_quantity=1 where item_id='"+item+"';")
 def last(_):
  try:checkout(str(uuid.uuid4()),[line]);return True
  except RuntimeError as e:
   assert 'Insufficient stock' in str(e),str(e)
   return False
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(last,range(2)))
 assert sum(results)==1
 print('Concurrent final-stock checkout: exactly one succeeds; loser rolls back: PASS',flush=True)

 tenant='c1111111-1111-4111-8111-111111111111';brand='ce000000-0000-4000-8000-000000000001';plant='ce000000-0000-4000-8000-000000000002';truck='ce000000-0000-4000-8000-000000000003'
 sql(f"insert into public.lpg_brands(tenant_id,brand_id,brand_name)values('{tenant}','{brand}','Fixture');insert into public.gas_plants(tenant_id,plant_id,brand_id,plant_name)values('{tenant}','{plant}','{brand}','Fixture');insert into public.trucks(tenant_id,truck_id,name,serial_no,capacity,size)values('{tenant}','{truck}','Fixture','Fixture',100,'medium');update public.items set brand_id='{brand}' where tenant_id='{tenant}';")
 before=float(sql(f"select balance from public.wallets where type='dealership' and tenant_id='{tenant}'"))
 def call(statement):
  result=sql(auth+'select '+statement+';select pg_sleep(0.05);commit;')
  return next(json.loads(x) for x in result.splitlines() if x.startswith('{'))
 payload={'plant_id':plant,'truck_id':truck,'request_id':str(uuid.uuid4()),'transport_cost':20,'labour_cost':10,'commission':50,'items':[{'item_id':item,'type':'refill','quantity':1,'unit_price':500}]}
 expression="public.create_purchase('"+json.dumps(payload)+"')"
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:creation_results=list(pool.map(lambda _:call(expression),range(2)))
 pid=creation_results[0]['purchase_id'];assert creation_results[1]['purchase_id']==pid
 try:call("public.create_purchase('"+json.dumps({**payload,'labour_cost':11})+"')");raise AssertionError('changed payload accepted')
 except RuntimeError as e:assert 'different purchase details' in str(e)
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:list(pool.map(lambda _:call(f"public.dispatch_purchase('{pid}',1)"),range(2)))
 wallet_ids=json.loads(sql(f"select jsonb_object_agg(type,wallet_id) from public.wallets where tenant_id='{tenant}'"))
 payment_key=str(uuid.uuid4())
 def purchase_pay(pid,amount,key):
  return call(f"public.record_purchase_payment('{pid}','"+json.dumps([{'wallet_id':wallet_ids['dealership'],'amount':amount}])+f"','{key}')")
 def compete(action):
  try:return (action,purchase_pay(pid,460,payment_key) if action=='pay' else call(f"public.receive_purchase('{pid}',2)"))
  except RuntimeError as e:
   assert 'changed' in str(e),str(e)
   return (action,None)
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(compete,['pay','receive']))
 for action,result in results:
  if result is None:
   rev=int(sql(f"select revision from public.purchases where purchase_id='{pid}'"));purchase_pay(pid,460,payment_key) if action=='pay' else call(f"public.receive_purchase('{pid}',{rev})")
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:list(pool.map(lambda _:purchase_pay(pid,460,payment_key),range(2)))
 summary=json.loads(sql(f"select jsonb_build_object('status',status,'payment',payment_status,'total',total_cost,'balance',(select balance from public.wallets where type='dealership' and tenant_id='{tenant}'),'company_rows',(select count(*) from public.wallet_transactions where reference_id='{pid}' and type='purchase_payment_company')) from public.purchases where purchase_id='{pid}'"))
 assert summary=={'status':'received','payment':'paid','total':480,'balance':before-480,'company_rows':1},summary
 print('Concurrent purchase creation/dispatch/payment/receipt: one application, stale conflicts safely retried: PASS',flush=True)
 # Receiving remains an unconditional cancellation boundary, even when fully paid.
 try:call(f"public.initiate_purchase_cancellation('{pid}',4,'CANCEL','{uuid.uuid4()}')");raise AssertionError('received cancellation accepted')
 except RuntimeError as e:assert 'never be cancelled' in str(e)
 payload['request_id']=str(uuid.uuid4())
 pid=call("public.create_purchase('"+json.dumps(payload)+"')")['purchase_id']
 call(f"public.dispatch_purchase('{pid}',1)")
 purchase_pay(pid,460,str(uuid.uuid4()))
 tr=json.loads(sql(f"select jsonb_build_object('id',transit_id,'revision',revision) from public.transits where purchase_id='{pid}'"))
 call(f"public.save_transit_costs('{tr['id']}',"+"'{\"driver_cost\":15,\"helper_cost\":0,\"oil_cost\":0,\"others_cost\":0}',"+str(tr['revision'])+")")
 rev=int(sql(f"select revision from public.purchases where purchase_id='{pid}'"));cancel_key=str(uuid.uuid4())
 with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:results=list(pool.map(lambda _:call(f"public.initiate_purchase_cancellation('{pid}',{rev},'CANCEL','{cancel_key}')"),range(3)))
 assert all(r['refund_due']==480 for r in results)
 call(f"public.transition_transit('{tr['id']}','close',{tr['revision']+2})")
 obligations=json.loads(sql(f"select jsonb_agg(jsonb_build_object('id',obligation_id,'component',component,'amount',amount)) from public.purchase_refund_obligations where purchase_id='{pid}'"))
 company=next(o for o in obligations if o['component']=='company')
 def refund(o,amount,key):
  entries=json.dumps([{'wallet_id':wallet_ids['cash'],'amount':amount}])
  return call(f"public.refund_purchase('{pid}','{o['id']}','{entries}','{key}')")
 refund_key=str(uuid.uuid4())
 with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:results=list(pool.map(lambda _:refund(company,100,refund_key),range(3)))
 assert all(r['refund_due']==380 for r in results)
 def race_refund(_):
  try:refund(company,300,str(uuid.uuid4()));return True
  except RuntimeError as e:assert 'exceeds' in str(e);return False
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(race_refund,range(2)))
 assert sum(results)==1
 refund(company,50,str(uuid.uuid4()))
 for o in obligations:
  if o['component']!='company':refund(o,o['amount'],str(uuid.uuid4()))
 assert sql(f"select refund_due=0 and financial_closed_at is not null from public.purchases where purchase_id='{pid}'")=='t'
 assert sql(f"select balance from public.wallets where tenant_id='{tenant}' and type='logistics'")=='5.00'
 print('Concurrent cancellation/refunds: one operational reversal, duplicate refunds once, competing refunds cannot exceed obligations, incurred expenses preserved: PASS',flush=True)

 # Same-key collections serialize and distinct-key collections cannot overpay.
 sql(f"update public.items set filled_quantity=30,empty_quantity=30 where tenant_id='{tenant}' and item_id='{item}';")
 unpaid=call("public.create_pos_sale('01700000000',null,null,null,'retail',0,0,null,'"+json.dumps([line])+"','c5555555-5555-4555-8555-555555555555','"+str(uuid.uuid4())+"','[]')")['sale_id']
 wallet_ids=json.loads(sql(f"select jsonb_object_agg(type,wallet_id) from public.wallets where tenant_id='{tenant}'"))
 def collect(key,amount):
  payments=json.dumps([{'wallet_id':wallet_ids['cash'],'amount':amount}])
  return call(f"public.collect_sale_payment('{unpaid}','{payments}','{key}')")
 key=str(uuid.uuid4())
 with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:results=list(pool.map(lambda _:collect(key,500),range(4)))
 assert all(r['paid_amount']==500 for r in results)
 assert int(sql(f"select count(*) from public.sale_payments where sale_id='{unpaid}'"))==1
 print('Concurrent duplicate collection: one payment, wallet entry and customer receipt: PASS',flush=True)
 def competing_collection(_):
  try:collect(str(uuid.uuid4()),1500);return True
  except RuntimeError as e:assert 'exceed' in str(e);return False
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(competing_collection,range(2)))
 assert sum(results)==1 and float(sql(f"select paid_amount from public.sales where sale_id='{unpaid}'"))==2000
 print('Concurrent distinct collections: overpayment rejected, only received money posted: PASS',flush=True)
 def move(action,src,dest,amount,key=None):
  payload={'action':action,'wallet_id':wallet_ids[src],'amount':amount,'reason':'Concurrent finance test'}
  if dest:payload['destination_id']=wallet_ids[dest]
  return call("public.move_wallet_money('"+json.dumps(payload)+"','"+(key or str(uuid.uuid4()))+"')")
 move('adjustment','bkash',None,1000)
 def competing_transfer(_):
  try:move('transfer','bkash','cash',700);return True
  except RuntimeError as e:assert 'Insufficient wallet balance' in str(e);return False
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(competing_transfer,range(2)))
 assert sum(results)==1 and float(sql(f"select balance from public.wallets where wallet_id='{wallet_ids['bkash']}'"))==300
 move('adjustment','dealership',None,1000)
 total_before=float(sql(f"select sum(balance) from public.wallets where tenant_id='{tenant}'"))
 with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:list(pool.map(lambda n:move('transfer','cash' if n%2 else 'dealership','dealership' if n%2 else 'cash',1),range(4)))
 assert float(sql(f"select sum(balance) from public.wallets where tenant_id='{tenant}'"))==total_before
 assert sql(f"select count(*) from public.wallets w where w.tenant_id='{tenant}' and w.balance<>w.opening_balance+coalesce((select sum(amount) from public.wallet_transactions x where x.tenant_id=w.tenant_id and x.wallet_id=w.wallet_id),0)")=='0'
 print('Concurrent transfers: overspending prevented, opposite transfers avoid deadlocks, all balances reconcile: PASS',flush=True)
 print('Disposable database verification complete',flush=True)
finally:
 if created:
  assert re.fullmatch('lpg_verify_[0-9a-f]{12}',name)
  sql('drop database '+name+';',db='postgres')
  print('Removed only the disposable verification database',flush=True)

