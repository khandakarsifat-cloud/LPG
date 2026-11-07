"""Concurrent component writers on the runner's isolated database."""
from concurrent.futures import ThreadPoolExecutor

owner = 'fc072000-0000-4000-8000-000000000001'
sql("insert into auth.users(id,email,is_anonymous) values(" + lit(owner) + ",'component-concurrency@example.invalid',false);")
setup = sql('begin;\n' + payload['access_helpers'] + """
select pg_temp.fixture_identity('fc072000-0000-4000-8000-000000000001');
select pg_temp.fixture_business('Component concurrency disposable acceptance','Component concurrency owner');
do $$declare t uuid:=app_private.current_tenant_id();brand uuid;item uuid;begin
 insert into public.lpg_brands(tenant_id,brand_name) values(t,'Concurrent Gas') returning brand_id into brand;
 insert into public.items(tenant_id,brand_id,size_kg,mouth_size) values(t,brand,12,'22mm') returning item_id into item;
 perform public.adjust_inventory(jsonb_build_object('item_id',item,'kind','capital','gas_quantity',1,
   'bottle_quantity',1,'gas_unit_cost',700,'bottle_unit_cost',100,'reason','Single concurrent component unit'),gen_random_uuid());
 insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price)
 values(t,item,'retail','package',1400);
end$$;
select json_build_object('tenant',tenant_id,'item',item_id) from public.items where tenant_id=app_private.current_tenant_id();
commit;
""")
fixture = json.loads(setup.strip().splitlines()[-1])


def sell(index):
    try:
        sql("select set_config('request.jwt.claims'," + lit(json.dumps({'sub': owner, 'role': 'authenticated', 'session_id': owner})) + ",false);set role authenticated;" +
            "select public.create_pos_sale(" + lit('0170000072' + str(index)) +
            ",'Concurrent buyer',null,null,'retail',0,0,'Concurrent component issue'," +
            object_sql([{'item_id': fixture['item'], 'type': 'package', 'quantity': 1, 'unit_price': 1400}]) +
            ",p_request_id=>" + lit(str(uuid.uuid4())) + "::uuid,p_payments=>'[]',p_bottles=>jsonb_build_object('lines','[]'::jsonb));")
        return True
    except RuntimeError as error:
        if 'Insufficient stock' not in str(error):
            raise
        return False


with ThreadPoolExecutor(max_workers=2) as executor:
    outcomes = list(executor.map(sell, [1, 2]))
assert sum(outcomes) == 1, 'Competing component sales must commit exactly once'
evidence = json.loads(sql("select json_build_object('gas',gas_quantity,'bottle',bottle_quantity,'consistent',"
                         "(app_private.component_inventory_evidence(tenant_id,item_id)->>'consistent')::boolean)"
                         " from public.items where item_id=" + lit(fixture['item']) + "::uuid;"))
assert evidence == {'gas': 0, 'bottle': 0, 'consistent': True}
print('PASS concurrent component sales cannot oversell Gas or Bottle and reconcile exact FIFO and journals', flush=True)
