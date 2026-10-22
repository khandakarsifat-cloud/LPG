-- Real capability/tenant gates and workflow RPCs. All fixtures roll back.
begin;
set local row_security=on;
create function pg_temp.check_purchase(ok boolean,label text) returns void language plpgsql as $$
begin if ok is not true then raise exception 'FAIL: %',label; end if; end $$;
create function pg_temp.purchase_fails(statement text, expected text) returns void language plpgsql as $$
begin
  begin execute statement;
  exception when others then
    if position(expected in sqlerrm)>0 then return; end if;
    raise exception 'FAIL: expected %, got %',expected,sqlerrm;
  end;
  raise exception 'FAIL: invalid request succeeded: %',statement;
end $$;
create function pg_temp.purchase_header(id uuid) returns public.purchases language sql security definer set search_path='' as $$
  select p from public.purchases p where p.tenant_id=app_private.current_tenant_id() and p.purchase_id=id
$$;
create function pg_temp.purchase_lines(id uuid) returns jsonb language sql security definer set search_path='' as $$
  select coalesce(jsonb_agg(to_jsonb(pi) order by pi.type),'[]') from public.purchase_items pi
    where pi.tenant_id=app_private.current_tenant_id() and pi.purchase_id=id
$$;
grant execute on function pg_temp.check_purchase(boolean,text),pg_temp.purchase_fails(text,text),
  pg_temp.purchase_header(uuid),pg_temp.purchase_lines(uuid) to authenticated;
select pg_temp.check_purchase(not exists(
  select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where (n.nspname='app_private' and p.proname in ('purchase_activity_immutable','purchase_money','purchase_integer',
    'recalculate_purchase','save_purchase_lines','guard_purchase_transit','guard_truck_idle','guard_purchase_company')
    or n.nspname='public' and p.proname in ('create_purchase','update_purchase','dispatch_purchase',
      'receive_purchase','pay_purchase','cancel_purchase','save_transit_costs','transition_transit','list_purchases','get_purchase_activity','list_transits','update_transit_costs'))
    and pg_get_userbyid(p.proowner)<>'postgres'),'purchase helpers and RPCs share the existing application owner');
create temp table purchase_test_context(tenant_a uuid,tenant_b uuid,purchase_id uuid);
grant select,insert,update on purchase_test_context to authenticated;
insert into auth.users(id,email,is_anonymous) values
 ('aa000000-0000-4000-8000-000000000001','purchase-owner-a@example.invalid',false),
 ('bb000000-0000-4000-8000-000000000001','purchase-owner-b@example.invalid',false),
 ('aa000000-0000-4000-8000-000000000002','purchase-viewer@example.invalid',false),
 ('aa000000-0000-4000-8000-000000000003','purchase-operator@example.invalid',false);
set local role authenticated;
select set_config('request.jwt.claim.sub','aa000000-0000-4000-8000-000000000001',true);
insert into purchase_test_context(tenant_a) select (public.setup_business('Purchase tests A','Owner A')->>'tenant_id')::uuid;
select set_config('request.jwt.claim.sub','bb000000-0000-4000-8000-000000000001',true);
update purchase_test_context set tenant_b=(public.setup_business('Purchase tests B','Owner B')->>'tenant_id')::uuid;
reset role;
select set_config('request.jwt.claim.sub','',true);

insert into public.lpg_brands(tenant_id,brand_id,brand_name)
select t,'cc000000-0000-4000-8000-000000000001',name from purchase_test_context
  cross join lateral(values(tenant_a,'Company A'),(tenant_b,'Company B')) v(t,name);
insert into public.lpg_brands(tenant_id,brand_id,brand_name)
select tenant_a,'cc000000-0000-4000-8000-000000000002','Other company' from purchase_test_context;
insert into public.gas_plants(tenant_id,plant_id,brand_id,plant_name)
select t,'dd000000-0000-4000-8000-000000000001','cc000000-0000-4000-8000-000000000001',name from purchase_test_context
  cross join lateral(values(tenant_a,'Plant A'),(tenant_b,'Plant B')) v(t,name);
insert into public.gas_plants(tenant_id,plant_id,plant_name)
select tenant_a,'dd000000-0000-4000-8000-000000000002','Unassigned plant' from purchase_test_context;
insert into public.trucks(tenant_id,truck_id,name,serial_no,capacity,size)
select t,'ee000000-0000-4000-8000-000000000001',name,name,100,'medium' from purchase_test_context
  cross join lateral(values(tenant_a,'Truck A'),(tenant_b,'Truck B')) v(t,name);
insert into public.items(tenant_id,item_id,brand_id,brand,size_kg,empty_quantity,filled_quantity)
select t,'ff000000-0000-4000-8000-000000000001','cc000000-0000-4000-8000-000000000001',name,12,10,5 from purchase_test_context
  cross join lateral(values(tenant_a,'Item A'),(tenant_b,'Item B')) v(t,name);
insert into public.items(tenant_id,item_id,brand_id,brand,size_kg,empty_quantity)
select tenant_a,'ff000000-0000-4000-8000-000000000002','cc000000-0000-4000-8000-000000000002','Wrong company',12,10 from purchase_test_context;
insert into public.items(tenant_id,item_id,brand_id,brand,size_kg,empty_quantity)
select tenant_a,'ff000000-0000-4000-8000-000000000003','cc000000-0000-4000-8000-000000000001','Empty stock SKU',25,0 from purchase_test_context;
insert into public.user_profiles(user_id,tenant_id,email)
select u.id,c.tenant_a,u.email from auth.users u cross join purchase_test_context c
where u.id in ('aa000000-0000-4000-8000-000000000002','aa000000-0000-4000-8000-000000000003');
insert into public.roles(tenant_id,role_id,name) select tenant_a,'aa000000-0000-4000-8000-000000000002','Purchase viewer' from purchase_test_context;
insert into public.roles(tenant_id,role_id,name) select tenant_a,'aa000000-0000-4000-8000-000000000003','Purchase operator' from purchase_test_context;
insert into public.role_permissions(tenant_id,role_id,permission_id)
select tenant_a,'aa000000-0000-4000-8000-000000000002'::uuid,'purchases:view' from purchase_test_context
union all select tenant_a,'aa000000-0000-4000-8000-000000000003'::uuid,'purchases:manage' from purchase_test_context;
insert into public.user_roles(tenant_id,user_id,role_id)
select tenant_a,id,id from purchase_test_context cross join lateral(values
 ('aa000000-0000-4000-8000-000000000002'::uuid),('aa000000-0000-4000-8000-000000000003'::uuid)) v(id);

set local role authenticated;
select set_config('request.jwt.claim.sub','aa000000-0000-4000-8000-000000000001',true);
do $$
declare id uuid; draft_id uuid; received_id uuid; cash uuid; bank uuid; bk uuid; ng uuid; tr uuid; p public.purchases;
 key uuid; args jsonb; result jsonb; o record; n integer; before_amount numeric;
begin
 select wallet_id into cash from public.wallets where tenant_id=app_private.current_tenant_id() and type='cash';
 select wallet_id into bank from public.wallets where tenant_id=app_private.current_tenant_id() and type='dealership';
 select wallet_id into bk from public.wallets where tenant_id=app_private.current_tenant_id() and type='bkash';
 select wallet_id into ng from public.wallets where tenant_id=app_private.current_tenant_id() and type='nagad';
 draft_id:=(public.create_purchase(jsonb_build_object('plant_id','dd000000-0000-4000-8000-000000000001','request_id',gen_random_uuid()))->>'purchase_id')::uuid;
 perform pg_temp.purchase_fails(format('select public.initiate_purchase_cancellation(%L,1,%L,%L)',draft_id,'cancel',gen_random_uuid()),'exactly CANCEL');
 key:=gen_random_uuid();
 result:=public.initiate_purchase_cancellation(draft_id,1,'CANCEL',key);
 perform pg_temp.check_purchase(result=public.initiate_purchase_cancellation(draft_id,1,'CANCEL',key),'cancellation response-loss retry');
 perform pg_temp.check_purchase((result->>'financially_closed')::boolean,'unfunded draft closes immediately');
 perform pg_temp.purchase_fails(format('select public.cancel_purchase(%L,1)',draft_id),'Refresh');
 id:=(public.create_purchase(jsonb_build_object('plant_id','dd000000-0000-4000-8000-000000000001','truck_id','ee000000-0000-4000-8000-000000000001','request_id',gen_random_uuid(),
 'commission',50,'transport_cost',20,'labour_cost',10,'items','[{"item_id":"ff000000-0000-4000-8000-000000000001","type":"refill","quantity":4,"unit_price":100},{"item_id":"ff000000-0000-4000-8000-000000000001","type":"package","quantity":2,"unit_price":200}]'::jsonb))->>'purchase_id')::uuid;
 update purchase_test_context set purchase_id=id;
 perform pg_temp.purchase_fails(format('select public.record_purchase_payment(%L,%L,%L)',id,jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',1)),gen_random_uuid()),'dispatched');
 perform public.dispatch_purchase(id,1); perform public.dispatch_purchase(id,1);
 p:=pg_temp.purchase_header(id);
 perform pg_temp.check_purchase(p.total_cost=780 and p.paid_amount=20,'dispatch funding counted once');
 select transit_id into tr from public.transits where purchase_id=id and tenant_id=app_private.current_tenant_id();
 perform public.save_transit_costs(tr,'{"driver_cost":15,"helper_cost":0,"oil_cost":0,"others_cost":0}',1);
 args:=jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',100),jsonb_build_object('wallet_id',bk,'amount',200,'reference','PURCHASE-BK-123'));
 key:=gen_random_uuid();result:=public.record_purchase_payment(id,args,key);
 perform pg_temp.check_purchase(result=public.record_purchase_payment(id,args,key),'multi-wallet retry returns original response');
 perform pg_temp.check_purchase((result->>'paid_amount')::numeric=320 and (result->>'due')::numeric=460,'partial split settlement');
 perform pg_temp.purchase_fails(format('select public.record_purchase_payment(%L,%L,%L)',id,args||jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',1)),key),'different details');
 perform pg_temp.purchase_fails(format('select public.update_purchase(%L,%L,3)',id,'{"labour_cost":11}'),'lock after');
 perform public.update_purchase(id,'{"notes":"Partial settlement retained"}',3);
 select count(*) into n from public.purchase_activity where purchase_id=id;
 perform pg_temp.purchase_fails(format('select public.record_purchase_payment(%L,%L,%L)',id,jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',100),jsonb_build_object('wallet_id',bk,'amount',500)),gen_random_uuid()),'exceed');
 perform pg_temp.check_purchase((pg_temp.purchase_header(id)).paid_amount=320 and (select count(*) from public.purchase_activity where purchase_id=id)=n,'overpayment rolls back entire split');
 perform pg_temp.purchase_fails(format('select public.record_purchase_payment(%L,%L,%L)',id,jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',1.001)),gen_random_uuid()),'two decimal');
 perform pg_temp.purchase_fails(format('select public.record_purchase_payment(%L,%L,%L)',id,jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',0)),gen_random_uuid()),'positive');
 perform public.save_finance_wallet(jsonb_build_object('wallet_id',cash,'revision',1,'name','Renamed cash','kind','cash','is_active',true));
 perform pg_temp.check_purchase(exists(select 1 from jsonb_array_elements(public.get_purchase_settlement(id)->'payments') e where e->>'wallet_name'='Cash Register'),'payment wallet snapshot survives rename');
 perform pg_temp.check_purchase((public.get_wallet_ledger('{"search":"PURCHASE-BK-123"}')->>'total')::int=1,'finance ledger searches purchase references');
 result:=public.record_purchase_payment(id,jsonb_build_array(jsonb_build_object('wallet_id',bank,'amount',460)),gen_random_uuid());
 perform pg_temp.check_purchase((pg_temp.purchase_header(id)).payment_status='paid' and (result->>'due')::numeric=0,'additional payment fully settles company and labour');
 perform set_config('request.jwt.claim.sub','aa000000-0000-4000-8000-000000000003',true);
 perform pg_temp.purchase_fails(format('select public.initiate_purchase_cancellation(%L,5,%L,%L)',id,'CANCEL',gen_random_uuid()),'OWNER');
 perform set_config('request.jwt.claim.sub','aa000000-0000-4000-8000-000000000001',true);
 p:=pg_temp.purchase_header(id); key:=gen_random_uuid();result:=public.initiate_purchase_cancellation(id,p.revision,'CANCEL',key);
 perform pg_temp.check_purchase((result->>'refund_due')::numeric=780 and not (result->>'financially_closed')::boolean,'cancellation creates pending obligations without moving money');
 perform pg_temp.check_purchase((select empty_quantity=10 from public.items where tenant_id=app_private.current_tenant_id() and item_id='ff000000-0000-4000-8000-000000000001'),'cancellation returns dispatched empties');
 perform pg_temp.check_purchase((select status='idle' from public.trucks where tenant_id=app_private.current_tenant_id() and truck_id='ee000000-0000-4000-8000-000000000001'),'cancellation releases truck');
 perform pg_temp.purchase_fails(format('select public.receive_purchase(%L,6)',id),'In Transit');
 perform pg_temp.purchase_fails(format('select public.record_purchase_payment(%L,%L,%L)',id,args,gen_random_uuid()),'non-cancelled');
 perform pg_temp.purchase_fails(format('select public.update_purchase(%L,%L,6)',id,'{"notes":"no"}'),'locked');
 perform pg_temp.check_purchase((select total_cost=15 and closed_at is null and status='cancelled' from public.transits where tenant_id=app_private.current_tenant_id() and transit_id=tr),'incurred costs preserved');
 perform public.transition_transit(tr,'close',3);
 perform pg_temp.check_purchase((select balance=5 from public.wallets where tenant_id=app_private.current_tenant_id() and type='logistics'),'operating costs close independently before refunds');
 select * into o from jsonb_to_recordset(public.get_purchase_settlement(id)->'obligations') as q(obligation_id uuid,component text,amount numeric,remaining numeric) where component='company';
 args:=jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',200),jsonb_build_object('wallet_id',bk,'amount',100));key:=gen_random_uuid();
 result:=public.refund_purchase(id,o.obligation_id,args,key);
 perform pg_temp.check_purchase(result=public.refund_purchase(id,o.obligation_id,args,key),'partial multi-wallet refund retries once');
 perform pg_temp.check_purchase((result->>'refund_due')::numeric=480,'partial refund remains pending');
 perform pg_temp.purchase_fails(format('select public.refund_purchase(%L,%L,%L,%L)',id,o.obligation_id,jsonb_build_array(jsonb_build_object('wallet_id',ng,'amount',451)),gen_random_uuid()),'exceeds');
 for o in select * from jsonb_to_recordset(public.get_purchase_settlement(id)->'obligations') as q(obligation_id uuid,component text,remaining numeric) where remaining>0 loop
  if o.component='transport' then
   result:=public.refund_purchase(id,o.obligation_id,jsonb_build_array(jsonb_build_object('wallet_id',ng,'amount',10)),gen_random_uuid());
   perform pg_temp.check_purchase((pg_temp.purchase_header(id)).financial_closed_at is null,'partial transport reversal does not close purchase');
   o.remaining:=o.remaining-10;
  end if;
  result:=public.refund_purchase(id,o.obligation_id,jsonb_build_array(jsonb_build_object('wallet_id',ng,'amount',o.remaining)),gen_random_uuid());
 end loop;
 p:=pg_temp.purchase_header(id);
 perform pg_temp.check_purchase(p.refund_due=0 and p.refunded_amount=780 and p.financial_closed_at is not null,'final closure requires all refunds');
 perform pg_temp.check_purchase((select balance=-15 from public.wallets where tenant_id=app_private.current_tenant_id() and type='logistics'),'transport reversal preserves actual expense');
 perform pg_temp.check_purchase((select sum(balance)=0 from public.wallets where tenant_id=app_private.current_tenant_id() and type<>'logistics'),'refund destinations reconcile purchasing balances');
 perform pg_temp.check_purchase((public.get_purchase_directory('{"status":"closed"}')->>'total')::int=2,'closed filtering');
 received_id:=(public.create_purchase(jsonb_build_object('plant_id','dd000000-0000-4000-8000-000000000001','truck_id','ee000000-0000-4000-8000-000000000001','request_id',gen_random_uuid(),
 'items','[{"item_id":"ff000000-0000-4000-8000-000000000001","type":"refill","quantity":1,"unit_price":100}]'::jsonb))->>'purchase_id')::uuid;
 perform public.dispatch_purchase(received_id,1);perform public.receive_purchase(received_id,2);
 perform pg_temp.purchase_fails(format('select public.initiate_purchase_cancellation(%L,3,%L,%L)',received_id,'CANCEL',gen_random_uuid()),'never be cancelled');
 perform public.record_purchase_payment(received_id,jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',100)),gen_random_uuid());
 perform pg_temp.purchase_fails(format('select public.initiate_purchase_cancellation(%L,4,%L,%L)',received_id,'CANCEL',gen_random_uuid()),'never be cancelled');
 perform set_config('request.jwt.claim.sub','bb000000-0000-4000-8000-000000000001',true);
 perform pg_temp.purchase_fails(format('select public.get_purchase_settlement(%L)',id),'not found');
 perform pg_temp.purchase_fails(format('select public.refund_purchase(%L,%L,%L,%L)',id,gen_random_uuid(),args,gen_random_uuid()),'not found');
 perform set_config('request.jwt.claim.sub','aa000000-0000-4000-8000-000000000002',true);
 perform pg_temp.purchase_fails(format('select public.record_purchase_payment(%L,%L,%L)',id,args,gen_random_uuid()),'Permission denied');
 perform pg_temp.check_purchase(not has_table_privilege('authenticated','public.purchase_payments','INSERT') and not has_table_privilege('authenticated','public.purchase_refund_obligations','UPDATE'),'direct financial writes denied');
end $$;
reset role;
do $$begin
 if exists(select 1 from public.wallets w where tenant_id in(select tenant_a from purchase_test_context) and balance<>opening_balance+coalesce((select sum(amount) from public.wallet_transactions x where x.tenant_id=w.tenant_id and x.wallet_id=w.wallet_id),0)) then raise exception 'Wallet ledger does not reconcile'; end if;
end $$;
select 'PASS: purchase split/full/additional payments, cancellation boundaries, owner confirmation, partial multi-wallet refunds, independent expense closure, snapshot history, retries, rollback and tenant gates';
rollback;
