"""Executed only inside core-overhaul-runner.py's owned disposable clone."""
owner = 'fc041000-0000-4000-8000-000000000001'
setup = '''begin;
''' + payload['access_helpers'] + '''
insert into auth.users(id,email,is_anonymous) values(''' + lit(owner) + ''','core-races@example.invalid',false);
select pg_temp.fixture_identity(''' + lit(owner) + ''');
select pg_temp.fixture_business('Core concurrency disposable acceptance','Concurrency owner');
create temp table race_fixture(value jsonb);
do $$declare t uuid:=app_private.current_tenant_id();b uuid;i uuid;p uuid;w uuid;bank uuid;driver uuid;vehicle uuid;vehicles jsonb:='[]';r jsonb;n integer;
begin
 select wallet_id into w from public.wallets where tenant_id=t and type='cash';
 select wallet_id into bank from public.wallets where tenant_id=t and type='dealership';
 perform public.move_wallet_money(jsonb_build_object('action','adjustment','wallet_id',w,'classification','capital','business','lpg','amount',10000,'reason','Concurrency funds'),gen_random_uuid());
 insert into public.lpg_brands(tenant_id,brand_name) values(t,'Concurrency Gas') returning brand_id into b;
 insert into public.items(tenant_id,brand_id,size_kg,mouth_size) values(t,b,12,'22mm') returning item_id into i;
 insert into public.gas_plants(tenant_id,brand_id,plant_name) values(t,b,'Concurrency plant') returning plant_id into p;
 insert into public.price_books(tenant_id,item_id,price_type,customer_tier,price) values(t,i,'package','retail',3000);
 perform public.adjust_inventory(jsonb_build_object('item_id',i,'kind','capital','filled_quantity',3,'empty_quantity',5,'filled_unit_cost',2000,'filled_shell_unit_cost',1200,'empty_unit_cost',1000,'reason','Historical concurrency stock'),gen_random_uuid());
 insert into public.employee_types(tenant_id,name) values(t,'Driver') on conflict do nothing;
 for n in 1..2 loop
  r:=public.save_employee(jsonb_build_object('name','Race Driver '||n,'employee_type_name','Driver','business_unit','truck_business','phones',jsonb_build_array(jsonb_build_object('phone','0179000042'||n,'is_primary',true)),'terms',jsonb_build_object('effective_from',(now() at time zone 'Asia/Dhaka')::date,'monthly_salary',0,'is_active',true)),gen_random_uuid());driver:=(r->>'employee_id')::uuid;
  r:=public.save_vehicle(jsonb_build_object('name','Race truck '||n,'serial_no','RACE-'||n,'capacity',200,'driver_employee_id',driver,'book_value',500000,'funding','capital'),gen_random_uuid());
  vehicles:=vehicles||jsonb_build_array(r->>'vehicle_id');
 end loop;
 insert into race_fixture values(jsonb_build_object('tenant',t,'item',i,'plant',p,'wallet',w,'bank',bank,'vehicles',vehicles));
end$$;
select value from race_fixture;
commit;'''
fixture = json.loads(sql(setup).strip().splitlines()[-1])
tenant = fixture['tenant']


def rpc(expression, actor=owner):
    claims = json.dumps({'sub': actor, 'session_id': actor, 'role': 'authenticated'})
    text = "begin;set local statement_timeout='45s';set local lock_timeout='20s';set local role authenticated;"
    text += "select set_config('request.jwt.claim.sub'," + lit(actor) + ",true);select set_config('request.jwt.claims'," + lit(claims) + ",true);"
    text += 'select ' + expression + ';commit;'
    return json.loads(sql(text).strip().splitlines()[-1])


def attempt(expression):
    try:
        return {'ok': True, 'result': rpc(expression)}
    except RuntimeError as error:
        return {'ok': False, 'error': str(error)}


key = str(uuid.uuid4())
transfer = dict(action='transfer', wallet_id=fixture['wallet'], destination_id=fixture['bank'], amount=1000, reason='Identical concurrent treasury retry')
expression = 'public.move_wallet_money(' + object_sql(transfer) + ',' + lit(key) + ')'
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    results = list(pool.map(lambda _: rpc(expression), range(8)))
assert len({json.dumps(value, sort_keys=True) for value in results}) == 1, 'Exact transfer retries differ'
assert sql('select count(*)=2 and sum(amount)=0 from public.wallet_transactions where tenant_id=' + lit(tenant) + ' and operation_id=' + lit(key)).strip() == 't', 'Transfer principal posted more than once'
changed = attempt('public.move_wallet_money(' + object_sql({**transfer, 'amount': 1001}) + ',' + lit(key) + ')')
assert not changed['ok'] and 'different details' in changed['error'], 'Changed transfer intent was silently accepted'
print('PASS eight authenticated-role treasury retries produce exactly two principal legs; changed intent is rejected', flush=True)


def sale(index):
    items = [dict(item_id=fixture['item'], type='package', quantity=2, unit_price=3000)]
    return attempt('public.create_pos_sale(' + ','.join([lit('0179000041' + str(index)), lit('Race buyer ' + str(index)), 'null', 'null', lit('retail'), '0', '0', lit('Concurrent oldest-stock sale'), object_sql(items)]) + ',p_request_id=>' + lit(uuid.uuid4()) + ",p_payments=>'[]'::jsonb)")


with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    results = list(pool.map(sale, range(2)))
assert sum(value['ok'] for value in results) == 1, 'Oversell race did not have exactly one successful sale'
failure = next(value for value in results if not value['ok'])
assert any(word in failure['error'].lower() for word in ['stock', 'filled']), 'Oversell failed for an unrelated reason'
assert sql('select filled_quantity=1 from public.items where tenant_id=' + lit(tenant) + ' and item_id=' + lit(fixture['item'])).strip() == 't'
assert sql('select filled_value=2000 from public.inventory_costs where tenant_id=' + lit(tenant) + ' and item_id=' + lit(fixture['item'])).strip() == 't'
print('PASS concurrent sales cannot oversell; actual remaining quantity and historical FIFO value reconcile', flush=True)

loan_body = dict(action='loan_create', amount=1000, lender='Race lender', wallet_id=fixture['wallet'], date=sql("select (now() at time zone 'Asia/Dhaka')::date::text").strip(), description='Concurrent principal repayment', allocations={'lpg': 100})
loan = rpc('public.accounting_operation(' + object_sql(loan_body) + ',' + lit(uuid.uuid4()) + ')')['id']


def repay(wallet):
    body = dict(action='loan_repay', loan_id=loan, wallet_id=wallet, amount=700, date=loan_body['date'], description='Concurrent principal repayment')
    return attempt('public.accounting_operation(' + object_sql(body) + ',' + lit(uuid.uuid4()) + ')')


with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    results = list(pool.map(repay, [fixture['wallet'], fixture['bank']]))
assert sum(value['ok'] for value in results) == 1, 'Concurrent repayment exceeded principal'
assert sql('select outstanding=300 from public.loans where tenant_id=' + lit(tenant) + ' and loan_id=' + lit(loan)).strip() == 't'
print('PASS competing repayments from different real wallets cannot overpay principal', flush=True)

lent_body = dict(loan_body, action='loan_lend', lender='Race borrower', description='Concurrent lending collections')
lent = rpc('public.accounting_operation(' + object_sql(lent_body) + ',' + lit(uuid.uuid4()) + ')')['id']


def collect(wallet):
    body = dict(action='loan_collect', loan_id=lent, wallet_id=wallet, amount=700, date=loan_body['date'], description='Concurrent lending collection')
    return attempt('public.accounting_operation(' + object_sql(body) + ',' + lit(uuid.uuid4()) + ')')


with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    results = list(pool.map(collect, [fixture['wallet'], fixture['bank']]))
assert sum(value['ok'] for value in results) == 1, 'Concurrent collection exceeded lent principal'
assert sql('select outstanding=300 from public.loans where tenant_id=' + lit(tenant) + ' and loan_id=' + lit(lent)).strip() == 't'
print('PASS competing lending collections cannot collect more than the outstanding principal', flush=True)

purchases = []
for vehicle in fixture['vehicles']:
    body = dict(request_id=str(uuid.uuid4()), plant_id=fixture['plant'], vehicle_id=vehicle, transport_cost=0, labour_cost=0,
                items=[dict(item_id=fixture['item'], quantity=4, bottle_quantity=0, unit_price=900, bottle_unit_price=0)])
    purchases.append(rpc('public.create_purchase(' + object_sql(body) + ')')['purchase_id'])
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    results = list(pool.map(lambda pid: attempt('public.dispatch_purchase(' + lit(pid) + ',1)'), purchases))
assert sum(value['ok'] for value in results) == 1, 'Concurrent dispatch consumed more than five empties'
assert sql('select empty_quantity=1 from public.items where tenant_id=' + lit(tenant) + ' and item_id=' + lit(fixture['item'])).strip() == 't'
received = purchases[next(index for index, value in enumerate(results) if value['ok'])]
rpc('public.receive_purchase(' + lit(received) + ',2)')
trip = sql('select transit_id from public.transits where tenant_id=' + lit(tenant) + ' and purchase_id=' + lit(received)).strip()
revision = int(sql('select revision from public.transits where tenant_id=' + lit(tenant) + ' and transit_id=' + lit(trip)).strip())
costs = [dict(driver_cost=0, helper_cost=0, oil_cost=value, others_cost=0, additional_costs=[]) for value in [10, 11]]
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    results = list(pool.map(lambda body: attempt('public.transition_transit(' + lit(trip) + ",'complete'," + str(revision) + ',' + object_sql(body) + ')'), costs))
assert sum(value['ok'] for value in results) == 1, 'Conflicting completion intent reported two successes'
winner = costs[next(index for index, value in enumerate(results) if value['ok'])]
assert rpc('public.transition_transit(' + lit(trip) + ",'complete'," + str(revision) + ',' + object_sql(winner) + ')')['already_applied']
assert sql('select count(*)=1 and sum(amount)=' + str(winner['oil_cost']) + ' from public.operating_payments where tenant_id=' + lit(tenant) + ' and transit_id=' + lit(trip)).strip() == 't'
print('PASS competing empty dispatches preserve ownership; conflicting transit completion is rejected and exact retries settle once', flush=True)

# Exact rebate retries and conflicting revisions on an already received purchase.
rev = int(sql('select revision from public.purchases where purchase_id=' + lit(received)).strip())
key = str(uuid.uuid4())
rebate_body = dict(amount=500, revision=rev)
expression = 'public.set_purchase_rebate(' + lit(received) + ',' + object_sql(rebate_body) + ',' + lit(key) + ')'
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    results = list(pool.map(lambda _: rpc(expression), range(8)))
assert len({json.dumps(x, sort_keys=True) for x in results}) == 1
assert sql('select count(*)=1 and sum(income_delta)=500 from app_private.purchase_rebate_events where purchase_id=' + lit(received)).strip() == 't'
rev = int(sql('select revision from public.purchases where purchase_id=' + lit(received)).strip())
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    results = list(pool.map(lambda amount: attempt('public.set_purchase_rebate(' + lit(received) + ',' + object_sql(dict(amount=amount, revision=rev)) + ',' + lit(uuid.uuid4()) + ')'), [600, 700]))
assert sum(x['ok'] for x in results) == 1, 'Conflicting rebate corrections both succeeded'

# A cancelled Stove order releases one company credit. Competing new receipts
# must share it rather than each claiming its full value. Another supplier is isolated.
stove_type = sql('select type_id from public.stove_product_types where tenant_id=' + lit(tenant) + ' and is_active order by type_id limit 1').strip()
stove = rpc('public.save_stove_product(' + object_sql(dict(name='Rebate credit race stove', type_id=stove_type)) + ',' + lit(uuid.uuid4()) + ')')['item_id']
def rebate_order(supplier, amount):
    value = dict(business_category='stove', supplier_name=supplier, request_id=str(uuid.uuid4()), rebate_amount=amount, items=[dict(item_id=stove, quantity=2, bottle_quantity=0, unit_price=1000, bottle_unit_price=0)])
    return rpc('public.create_purchase(' + object_sql(value) + ')')['purchase_id']
def rebate_receive(pid):
    rev = int(sql('select revision from public.purchases where purchase_id=' + lit(pid)).strip())
    return rpc('public.receive_purchase(' + lit(pid) + ',' + str(rev) + ')')
def rebate_cancel(pid):
    rev = int(sql('select revision from public.purchases where purchase_id=' + lit(pid)).strip())
    return rpc('public.initiate_purchase_cancellation(' + lit(pid) + ',' + str(rev) + ",'CANCEL'," + lit(uuid.uuid4()) + ')')
original = rebate_order('Concurrency company credit', 1000)
rebate_receive(original)
rebate_cancel(original)
foreign = rebate_order('Other company credit', 600)
rebate_receive(foreign)
assert sql('select sum(income_delta)=600 from app_private.purchase_rebate_events where purchase_id=' + lit(foreign)).strip() == 't', 'Foreign company credit was consumed'
rebate_cancel(foreign)
orders = [rebate_order('Concurrency company credit', 600) for _ in range(2)]
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    list(pool.map(rebate_receive, orders))
assert sql('select sum(income_delta)=200 and sum(applied_delta)=1200 from app_private.purchase_rebate_events where purchase_id in (' + ','.join(lit(v) for v in orders) + ')').strip() == 't', 'Company credit was spent twice or income duplicated'
assert sql('select sum(e.income_delta-e.applied_delta)=0 from app_private.purchase_rebate_events e join app_private.purchase_rebate_accounts a using(tenant_id,account_id) where a.tenant_id=' + lit(tenant) + " and a.company_key='stove:concurrency company credit'").strip() == 't'
print('PASS concurrent rebate retries, stale corrections, cross-company isolation and single-use released company credit', flush=True)

backdate = sql("select ((now() at time zone 'Asia/Dhaka')::date-40)::text").strip()
capital = dict(action='capital', wallet_id=fixture['wallet'], amount=10, date=backdate, description='Backdated snapshot fixture funds', allocations={'lpg': 100})
rpc('public.accounting_operation(' + object_sql(capital) + ',' + lit(uuid.uuid4()) + ')')
key = str(uuid.uuid4())
capital['amount'] = 20


def snapshot_race(index):
    if index == 0:
        return sql('select app_private.build_accounting_snapshots(' + lit(tenant) + ',24)')
    return rpc('public.accounting_operation(' + object_sql(capital) + ',' + lit(key) + ')')


with concurrent.futures.ThreadPoolExecutor(max_workers=9) as pool:
    list(pool.map(snapshot_race, range(9)))
sql('select app_private.build_accounting_snapshots(' + lit(tenant) + ',24)')
today = loan_body['date']
diff = sql('''with full_history as(select l.tenant_id,l.account,l.business_category,l.entity_id,l.type_id,sum(l.amount) amount,sum(l.consolidated_amount) consolidated_amount
 from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where l.tenant_id=''' + lit(tenant) + ' and j.occurred_on<=' + lit(today) + ''' group by 1,2,3,4,5),
 projected as(select * from app_private.dimensional_balances(array[''' + lit(tenant) + '::uuid],' + lit(today) + '''::date)),
 difference as((select * from full_history except select * from projected) union all(select * from projected except select * from full_history)) select count(*) from difference''').strip()
assert diff == '0', 'Savepoint differs from full canonical journal recomputation'
assert sql('select count(*)=1 from public.wallet_transactions where tenant_id=' + lit(tenant) + ' and operation_id=' + lit(key)).strip() == 't'
assert sql('select sum(balance)=(select sum(amount) from public.accounting_lines where tenant_id=' + lit(tenant) + " and account='cash') from public.wallets where tenant_id=" + lit(tenant)).strip() == 't'
assert sql('select count(*)=0 from (select journal_id from public.accounting_lines where tenant_id=' + lit(tenant) + ' group by journal_id,business_category having sum(amount)<>0)x').strip() == 't'
print('PASS concurrent month-end savepoints and backdated retries equal full journal recomputation; pooled wallets and journals reconcile', flush=True)
