-- Product pricing, buying-cost allocation, weekly boundaries and capability isolation.
-- Every fixture and price change rolls back. Run after the inventory migration.
begin;
do $$ begin
  if exists(select 1 from pg_proc where pronamespace='public'::regnamespace
    and position('errcode=''40001''' in prosrc)>0) then
    raise exception 'Business validation must not request serialization retries';
  end if;
end $$;
create function pg_temp.inv_check(ok boolean,label text) returns void language plpgsql as $$
begin if ok is not true then raise exception 'FAIL: %',label; end if; end $$;
create function pg_temp.inv_fails(statement text,expected text) returns void language plpgsql as $$
begin
  begin execute statement; exception when others then
    if position(expected in sqlerrm)>0 then
      if expected like '%changed%' and sqlstate <> 'P0001' then
        raise exception 'FAIL: stale edits must reject once with P0001, got %',sqlstate;
      end if;
      return;
    end if;
    raise exception 'FAIL: expected %, got %',expected,sqlerrm;
  end;
  raise exception 'FAIL: request succeeded: %',statement;
end $$;
grant execute on function pg_temp.inv_check(boolean,text),pg_temp.inv_fails(text,text) to authenticated,anon;
create temp table inv_context(a uuid,b uuid,saturday date);
grant all on inv_context to authenticated;
insert into auth.users(id,email,is_anonymous) values
 ('a1000000-0000-4000-8000-000000000001','inventory-a@example.invalid',false),
 ('b1000000-0000-4000-8000-000000000001','inventory-b@example.invalid',false),
 ('a1000000-0000-4000-8000-000000000002','inventory-reader@example.invalid',false),
 ('a1000000-0000-4000-8000-000000000003','inventory-manager@example.invalid',false);
set local role authenticated;
select set_config('request.jwt.claim.sub','a1000000-0000-4000-8000-000000000001',true);
insert into inv_context(a) select (public.setup_business('Inventory A','Owner A')->>'tenant_id')::uuid;
select set_config('request.jwt.claim.sub','b1000000-0000-4000-8000-000000000001',true);
update inv_context set b=(public.setup_business('Inventory B','Owner B')->>'tenant_id')::uuid;
reset role;
select set_config('request.jwt.claim.sub','',true);
update inv_context set saturday=(now() at time zone 'Asia/Dhaka')::date
  - ((extract(dow from now() at time zone 'Asia/Dhaka')::integer+1)%7);
insert into public.lpg_brands(tenant_id,brand_id,brand_name)
select t,'c1000000-0000-4000-8000-000000000001','Test brand' from inv_context cross join lateral(values(a),(b)) v(t);
insert into public.gas_plants(tenant_id,plant_id,plant_name,brand_id)
select t,'d1000000-0000-4000-8000-000000000001','Plant','c1000000-0000-4000-8000-000000000001'
from inv_context cross join lateral(values(a),(b)) v(t);
insert into public.items(tenant_id,item_id,brand_id,brand,size_kg,mouth_size,filled_quantity,empty_quantity)
select t,'f1000000-0000-4000-8000-000000000001','c1000000-0000-4000-8000-000000000001','Test brand',12,'22mm',100,100
from inv_context cross join lateral(values(a),(b)) v(t);
insert into public.items(tenant_id,item_id,brand_id,brand,size_kg,mouth_size)
select a,'f1000000-0000-4000-8000-000000000002','c1000000-0000-4000-8000-000000000001','Test brand',12,'20mm' from inv_context;
insert into public.items(tenant_id,item_id,brand_id,brand,size_kg)
select b,'f1000000-0000-4000-8000-000000000003','c1000000-0000-4000-8000-000000000001','Other tenant',25 from inv_context;
-- Pre-correction shared settings stay attributed and apply to both types without rewriting history.
insert into public.product_commission_rates(tenant_id,item_id,commission_per_unit,created_by)
select a,'f1000000-0000-4000-8000-000000000002'::uuid,7,'a1000000-0000-4000-8000-000000000001'::uuid from inv_context
union all select b,'f1000000-0000-4000-8000-000000000001'::uuid,999,'b1000000-0000-4000-8000-000000000001'::uuid from inv_context;
insert into public.customers(tenant_id,customer_id,name,phone)
select t,'e1000000-0000-4000-8000-000000000001','Customer','01700000000'
from inv_context cross join lateral(values(a),(b)) v(t);

-- Reused IDs in tenant B must never contribute to tenant A's estimates/history.
insert into public.purchases(tenant_id,purchase_id,plant_id,brand_id,status,received_at,subtotal,company_payable,transport_cost,labour_cost,commission,total_cost)
select t,id,'d1000000-0000-4000-8000-000000000001','c1000000-0000-4000-8000-000000000001',status::public.purchase_status,
  received,subtotal,subtotal-commission,transport,labour,commission,subtotal-commission+transport+labour
from inv_context cross join lateral(values
 (a,'91000000-0000-4000-8000-000000000001'::uuid,'received',(saturday::timestamp at time zone 'Asia/Dhaka'),4000,300,100,400),
 (a,'91000000-0000-4000-8000-000000000002'::uuid,'received',(saturday::timestamp at time zone 'Asia/Dhaka')-interval '1 microsecond',600,0,0,0),
 (a,'91000000-0000-4000-8000-000000000003'::uuid,'cancelled',now(),99999,999,999,0),
 (a,'91000000-0000-4000-8000-000000000004'::uuid,'in_transit',null::timestamptz,99999,999,999,0),
 (b,'91000000-0000-4000-8000-000000000001'::uuid,'received',now(),99999,999,999,0)
) v(t,id,status,received,subtotal,transport,labour,commission);
insert into public.purchase_items(tenant_id,purchase_id,item_id,type,quantity,billed_quantity,received_quantity,unit_price,line_total)
select t,id,item,kind::public.purchase_type,qty,qty,received,price,qty*price
from inv_context cross join lateral(values
 (a,'91000000-0000-4000-8000-000000000001'::uuid,'f1000000-0000-4000-8000-000000000001'::uuid,'refill',4,4,100),
 (a,'91000000-0000-4000-8000-000000000001'::uuid,'f1000000-0000-4000-8000-000000000001'::uuid,'package',2,2,200),
 (a,'91000000-0000-4000-8000-000000000001'::uuid,'f1000000-0000-4000-8000-000000000002'::uuid,'package',4,4,800),
 (a,'91000000-0000-4000-8000-000000000002'::uuid,'f1000000-0000-4000-8000-000000000001'::uuid,'refill',3,2,200),
 (a,'91000000-0000-4000-8000-000000000003'::uuid,'f1000000-0000-4000-8000-000000000001'::uuid,'refill',99,99,1010),
 (a,'91000000-0000-4000-8000-000000000004'::uuid,'f1000000-0000-4000-8000-000000000001'::uuid,'refill',99,null::integer,1010),
 (b,'91000000-0000-4000-8000-000000000001'::uuid,'f1000000-0000-4000-8000-000000000001'::uuid,'refill',99,99,1010)
) v(t,id,item,kind,qty,received,price);
insert into public.sales(tenant_id,sale_id,customer_id,status,created_at)
select t,id,'e1000000-0000-4000-8000-000000000001',status::public.sale_status,stamp
from inv_context cross join lateral(values
 (a,'92000000-0000-4000-8000-000000000001'::uuid,'completed',(saturday::timestamp at time zone 'Asia/Dhaka')),
 (a,'92000000-0000-4000-8000-000000000002'::uuid,'completed',(saturday::timestamp at time zone 'Asia/Dhaka')-interval '1 microsecond'),
 (a,'92000000-0000-4000-8000-000000000003'::uuid,'voided',now()),
 (b,'92000000-0000-4000-8000-000000000001'::uuid,'completed',now())
) v(t,id,status,stamp);
insert into public.sale_items(tenant_id,sale_id,item_id,type,quantity)
select t,id,'f1000000-0000-4000-8000-000000000001',kind::public.sale_item_type,qty
from inv_context cross join lateral(values
 (a,'92000000-0000-4000-8000-000000000001'::uuid,'refill',7),
 (a,'92000000-0000-4000-8000-000000000001'::uuid,'package',3),
 (a,'92000000-0000-4000-8000-000000000001'::uuid,'empty_return',7),
 (a,'92000000-0000-4000-8000-000000000002'::uuid,'package',2),
 (a,'92000000-0000-4000-8000-000000000003'::uuid,'refill',99),
 (b,'92000000-0000-4000-8000-000000000001'::uuid,'refill',99)
) v(t,id,kind,qty);
insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price,mrp,effective_from,effective_to)
select a,'f1000000-0000-4000-8000-000000000001','retail',kind,price,mrp,start_time,end_time
from inv_context cross join lateral(values
 ('refill',1200,1500,now()-interval '1 day',null::timestamptz),
 ('package',2400,3000,now()-interval '1 day',null::timestamptz),
 ('refill',9999,9999,now()+interval '1 day',null::timestamptz),
 ('refill',1,1,now()-interval '2 days',now()-interval '1 day')
) v(kind,price,mrp,start_time,end_time);
insert into public.user_profiles(user_id,tenant_id,email)
select 'a1000000-0000-4000-8000-000000000002',a,'inventory-reader@example.invalid' from inv_context;
insert into public.roles(tenant_id,role_id,name) select a,'a1000000-0000-4000-8000-000000000002','Inventory reader' from inv_context;
insert into public.role_permissions(tenant_id,role_id,permission_id) select a,'a1000000-0000-4000-8000-000000000002','inventory:view' from inv_context;
insert into public.user_roles(tenant_id,user_id,role_id) select a,'a1000000-0000-4000-8000-000000000002','a1000000-0000-4000-8000-000000000002' from inv_context;
insert into public.user_profiles(user_id,tenant_id,email)
select 'a1000000-0000-4000-8000-000000000003',a,'inventory-manager@example.invalid' from inv_context;
insert into public.user_roles(tenant_id,user_id,role_id)
select a,'a1000000-0000-4000-8000-000000000003',r.role_id from inv_context join public.roles r on r.tenant_id=a and r.name='MANAGER';

set local role authenticated;
select set_config('request.jwt.claim.sub','a1000000-0000-4000-8000-000000000002',true);
do $$ declare d jsonb; begin
  d:=public.get_product_inventory('f1000000-0000-4000-8000-000000000001');
  perform pg_temp.inv_check(jsonb_array_length(d->'weeks')=8,'exactly eight weeks, including zero weeks');
  perform pg_temp.inv_check((d#>>'{weeks,0,sold_refill}')::integer=7 and (d#>>'{weeks,0,sold_package}')::integer=3
    and (d#>>'{weeks,0,empty_return}')::integer=7,'sale types, completed status and tenant join');
  perform pg_temp.inv_check((d#>>'{weeks,1,sold_package}')::integer=2,'Friday one microsecond before Saturday');
  perform pg_temp.inv_check((d#>>'{weeks,0,bought_refill}')::integer=4 and (d#>>'{weeks,0,bought_package}')::integer=2
    and (d#>>'{weeks,1,bought_refill}')::integer=2,'actual received quantities, receipt date, excluded cancelled and pending purchases');
  perform pg_temp.inv_check((d#>>'{weeks,7,sold_refill}')::integer=0,'zero activity stays visible');
  perform pg_temp.inv_check(extract(dow from (d#>>'{weeks,0,start_date}')::date)=6
    and extract(dow from (d#>>'{weeks,0,end_date}')::date)=5,'Saturday to Friday in Dhaka');
  perform pg_temp.inv_check((select (x->>'estimated_unit_cost')::numeric=140 from jsonb_array_elements(d->'buying_costs') x where x->>'type'='refill'),
    'refill cost 100 + (300+100)/10, excluding purchase commission');
  perform pg_temp.inv_check((select (x->>'estimated_unit_cost')::numeric=240 from jsonb_array_elements(d->'buying_costs') x where x->>'type'='package'),
    'package cost 200 + shared overhead 40, excluding purchase commission');
  perform pg_temp.inv_check((d->>'can_manage_prices')::boolean=false,'reader has no pricing authority');
  perform pg_temp.inv_check(jsonb_array_length(d->'prices')=2,'current price windows only');
  perform pg_temp.inv_fails($q$select public.save_product_prices('f1000000-0000-4000-8000-000000000001','retail','{}','{}')$q$,'Permission denied');
  perform pg_temp.inv_fails($q$select public.get_product_inventory('f1000000-0000-4000-8000-000000000003')$q$,'Product not found');
  perform pg_temp.inv_fails('select public.set_lpg_brand_order(array[]::uuid[],array[]::uuid[])','Permission denied');
end $$;
select set_config('request.jwt.claim.sub','a1000000-0000-4000-8000-000000000003',true);
do $$ begin
  perform pg_temp.inv_check(app_private.has_permission('inventory:manage'),'manager still has inventory management');
  perform pg_temp.inv_check((public.get_product_inventory('f1000000-0000-4000-8000-000000000001')->>'can_manage_prices')::boolean=false,'manager not an owner');
  perform pg_temp.inv_fails($q$select public.save_product_prices('f1000000-0000-4000-8000-000000000001','retail','{}','{}')$q$,'Only the owner');
  perform pg_temp.inv_fails($q$select public.set_product_commissions('f1000000-0000-4000-8000-000000000001',10,20,null)$q$,'Only the owner');
end $$;
select set_config('request.jwt.claim.sub','a1000000-0000-4000-8000-000000000001',true);
do $$ declare d jsonb; expected jsonb; begin
  d:=public.get_product_inventory('f1000000-0000-4000-8000-000000000001');
  select jsonb_object_agg(x->>'price_type',x->'effective_from') into expected from jsonb_array_elements(d->'prices') x;
  perform public.save_product_prices('f1000000-0000-4000-8000-000000000001','retail',
    '{"refill":{"price":1250,"mrp":1600},"package":{"price":2500,"mrp":null}}',expected);
  perform pg_temp.inv_fails(format($q$select public.save_product_prices('f1000000-0000-4000-8000-000000000001','retail',
    '{"refill":{"price":1},"package":{"price":1}}',%L)$q$,expected),'Prices changed');
  perform pg_temp.inv_fails($q$select public.save_product_prices('f1000000-0000-4000-8000-000000000001','bad','{}','{}')$q$,'Invalid customer tier');
  perform pg_temp.inv_fails($q$select public.save_product_prices('f1000000-0000-4000-8000-000000000001','wholesale',
    '{"refill":{"price":1},"package":{"price":-1}}','{"refill":null,"package":null}')$q$,'nonnegative');
  perform pg_temp.inv_fails($q$select public.save_product_prices('f1000000-0000-4000-8000-000000000001','wholesale',
    '{"refill":{"price":1.001},"package":{"price":1}}','{"refill":null,"package":null}')$q$,'two decimal');
  perform pg_temp.inv_fails($q$select public.save_product_prices('f1000000-0000-4000-8000-000000000001','wholesale',
    '{"refill":{"price":"NaN"},"package":{"price":1}}','{"refill":null,"package":null}')$q$,'selling prices');
  perform pg_temp.inv_fails($q$select public.save_product_prices('f1000000-0000-4000-8000-000000000001','wholesale',
    '{"refill":{"price":1,"mrp":-1},"package":{"price":1}}','{"refill":null,"package":null}')$q$,'nonnegative');
  perform pg_temp.inv_fails($q$select public.save_product_prices('f1000000-0000-4000-8000-000000000003','retail','{}','{}')$q$,'Product not found');
end $$;
-- Each explicit rate save appends an attributed row; separate rates reduce their corresponding received-cost estimates.
do $$ declare d jsonb; first_version uuid; latest_version uuid; original_order uuid[]; new_order uuid[]; created uuid; begin
  d:=public.get_product_inventory('f1000000-0000-4000-8000-000000000002');
  perform pg_temp.inv_check((d#>>'{commission,refill_rate}')::numeric=7 and (d#>>'{commission,package_rate}')::numeric=7,'legacy shared manual rate preserved for both types');
  d:=public.get_product_inventory('f1000000-0000-4000-8000-000000000001');
  perform pg_temp.inv_check((d->>'can_manage_prices')::boolean and d#>>'{commission,version}' is null,'owner access, no fabricated commission history');
  perform public.set_product_commissions('f1000000-0000-4000-8000-000000000001',15,35,null);
  d:=public.get_product_inventory('f1000000-0000-4000-8000-000000000001');
  first_version:=(d#>>'{commission,version}')::uuid;
  perform pg_temp.inv_check((d#>>'{commission,refill_rate}')::numeric=15 and (d#>>'{commission,package_rate}')::numeric=35 and first_version is not null,'explicit current commission');
  perform pg_temp.inv_check((select (x->>'estimated_unit_cost')::numeric=125 and (x->>'commission_per_unit')::numeric=15 from jsonb_array_elements(d->'buying_costs') x where x->>'type'='refill'),'manual refill commission deducted from estimate');
  perform pg_temp.inv_check((select (x->>'estimated_unit_cost')::numeric=205 and (x->>'commission_per_unit')::numeric=35 from jsonb_array_elements(d->'buying_costs') x where x->>'type'='package'),'separate manual package commission deducted from estimate');
  perform pg_temp.inv_fails($q$select public.set_product_commissions('f1000000-0000-4000-8000-000000000001',0,-1,null)$q$,'nonnegative');
  perform pg_temp.inv_fails($q$select public.set_product_commissions('f1000000-0000-4000-8000-000000000001',0,1.001,null)$q$,'two decimal');
  perform pg_temp.inv_fails($q$select public.set_product_commissions('f1000000-0000-4000-8000-000000000001',0,'Infinity'::numeric,null)$q$,'nonnegative');
  perform pg_temp.inv_fails($q$select public.set_product_commissions('f1000000-0000-4000-8000-000000000001',0,null,null)$q$,'nonnegative');
  perform pg_temp.inv_fails($q$select public.set_product_commission('f1000000-0000-4000-8000-000000000001',15,null)$q$,'Reload the application');
  perform public.set_product_commissions('f1000000-0000-4000-8000-000000000001',20,45,first_version);
  perform pg_temp.inv_fails(format($q$select public.set_product_commissions('f1000000-0000-4000-8000-000000000001',30,50,%L)$q$,first_version),'Commission changed');
  d:=public.get_product_inventory('f1000000-0000-4000-8000-000000000001');
  latest_version:=(d#>>'{commission,version}')::uuid;
  perform public.set_product_commissions('f1000000-0000-4000-8000-000000000001',20,45,latest_version);
  perform pg_temp.inv_fails($q$select public.set_product_commissions('f1000000-0000-4000-8000-000000000001',-1,0,null)$q$,'nonnegative');
  perform pg_temp.inv_fails($q$select public.set_product_commissions('f1000000-0000-4000-8000-000000000001',1.001,0,null)$q$,'two decimal');
  perform pg_temp.inv_fails($q$select public.set_product_commissions('f1000000-0000-4000-8000-000000000001','NaN'::numeric,0,null)$q$,'nonnegative');
  perform pg_temp.inv_fails($q$select public.set_product_commissions('f1000000-0000-4000-8000-000000000003',1,2,null)$q$,'Product not found');
  perform pg_temp.inv_fails('select * from public.product_commission_rates','permission denied');

  perform public.create_lpg_brand('Second brand');
  created:=(public.create_lpg_brand('Inactive brand')->>'brand_id')::uuid;
  perform public.update_lpg_brand(created,null,null,false);
  original_order:=array(select brand_id from public.list_lpg_brands(false));
  perform pg_temp.inv_check(cardinality(original_order)=3,'all brands available for ordering, including inactive');
  new_order:=array[original_order[3],original_order[1],original_order[2]];
  perform public.set_lpg_brand_order(new_order,original_order);
  perform pg_temp.inv_check(array(select brand_id from public.list_lpg_brands(false))=new_order,'saved catalog order');
  perform pg_temp.inv_check(array(select brand_id from public.list_lpg_brands(true))=array[original_order[1],original_order[2]],'active filtering preserves catalog order');
  perform pg_temp.inv_fails(format('select public.set_lpg_brand_order(%L::uuid[],%L::uuid[])',original_order,original_order),'Brand order changed');
  perform pg_temp.inv_fails(format('select public.set_lpg_brand_order(%L::uuid[],%L::uuid[])',array[new_order[1],new_order[1],new_order[3]],new_order),'exactly once');
  perform pg_temp.inv_fails(format('select public.set_lpg_brand_order(%L::uuid[],%L::uuid[])',array[new_order[1],new_order[2],'99999999-0000-4000-8000-000000000000'::uuid],new_order),'exactly once');
  created:=(public.create_lpg_brand('Appended brand')->>'brand_id')::uuid;
  perform pg_temp.inv_check((array(select brand_id from public.list_lpg_brands(false)))[4]=created,'new brands append to configured order');
end $$;
reset role;
select pg_temp.inv_check((select count(*)=4 from public.product_commission_rates where created_by='a1000000-0000-4000-8000-000000000001'),'rate history includes legacy entry and each explicit save');
select pg_temp.inv_check((select count(*)=3 and bool_and(package_commission_per_unit is not null) from public.product_commission_rates where created_by='a1000000-0000-4000-8000-000000000001' and item_id='f1000000-0000-4000-8000-000000000001'),'each new save records both rates atomically');
select pg_temp.inv_check((select bool_and(created_by='a1000000-0000-4000-8000-000000000001') from public.product_commission_rates c join inv_context i on c.tenant_id=i.a),'rate actor is authenticated owner');
select pg_temp.inv_fails($q$update public.product_commission_rates set commission_per_unit=99 where created_by='a1000000-0000-4000-8000-000000000001'$q$,'immutable');
select pg_temp.inv_fails($q$update public.product_commission_rates set package_commission_per_unit=99 where created_by='a1000000-0000-4000-8000-000000000001'$q$,'immutable');
select pg_temp.inv_fails($q$delete from public.product_commission_rates where created_by='a1000000-0000-4000-8000-000000000001'$q$,'immutable');
select pg_temp.inv_check((select count(*)=1 and max(display_order)=0 from public.lpg_brands b join inv_context c on b.tenant_id=c.b),'other tenant brand order unchanged');
select pg_temp.inv_check((select count(*)=0 from public.price_books where customer_tier='wholesale'),'second-line failure rolls back both prices');
select pg_temp.inv_check((select count(*)=2 from public.price_books where price in (1250,2500)),'refill and package share one timestamp without collision');
select pg_temp.inv_check((select count(*)=1 from public.price_books where price=9999 and effective_to is null),'future scheduled price preserved');
select pg_temp.inv_check((select bool_and(effective_to=now()+interval '1 day') from public.price_books where price=1250),
  'new price ends at the next scheduled price');
select pg_temp.inv_check((select count(*)=2 from public.price_books where effective_to=(select min(effective_from) from public.price_books where price=1250)),
  'old active prices closed, history preserved');
select pg_temp.inv_check(not has_function_privilege('anon','public.get_product_inventory(uuid)','EXECUTE')
  and not has_function_privilege('anon','public.save_product_prices(uuid,text,jsonb,jsonb)','EXECUTE'),'anonymous denied');
select pg_temp.inv_check((select count(*)=0 from public.price_books p join inv_context c on p.tenant_id=c.b),'other tenant prices unchanged');
select pg_temp.inv_check((select bool_and(pg_get_userbyid(proowner)='postgres') from pg_proc
  where oid in ('public.get_product_inventory(uuid)'::regprocedure,'public.save_product_prices(uuid,text,jsonb,jsonb)'::regprocedure)),
  'RPC ownership matches application functions');
select 'PASS: owner-only prices/commission, immutable rate history, separate manual commission deductions, saved brand order, price windows, eight Dhaka weeks and tenant isolation';
rollback;
