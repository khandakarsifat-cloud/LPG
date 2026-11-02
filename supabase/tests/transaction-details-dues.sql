-- The runner restores the VPS into a disposable database; all fixture writes roll back.
begin;
create function pg_temp.assert_details(ok boolean,message text) returns void language plpgsql as $$begin
 if ok is not true then raise exception 'FAIL: %',message;end if;
end $$;
grant execute on function pg_temp.assert_details(boolean,text) to authenticated;
insert into auth.users(id,email,is_anonymous) values('de710000-0000-4000-8000-000000000001','details-dues@example.invalid',false);
select pg_temp.fixture_identity('de710000-0000-4000-8000-000000000001');
select pg_temp.fixture_business('Transaction details and dues disposable fixture','Details owner');
create temporary table details_fixture(sale uuid,customer uuid,kind text);
do $$declare t uuid:=app_private.current_tenant_id();i uuid;w uuid;s uuid;result jsonb;kind text;paid numeric;begin
 insert into public.items(tenant_id,brand_id,size_kg,mouth_size) values(t,pg_temp.fixture_brand(t,'Details test'),12,'22mm') returning item_id into i;
 perform public.adjust_inventory(jsonb_build_object('item_id',i,'kind','opening','filled_quantity',20,'empty_quantity',20,'filled_unit_cost',1000,'empty_unit_cost',500,'reason','Valued fixture stock'),gen_random_uuid());
 insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price,effective_from) values(t,i,'retail','refill',700,now()-interval '1 day'),(t,i,'retail','package',1500,now()-interval '1 day');
 select wallet_id into w from public.get_payment_wallets() where type='cash';
 foreach kind in array array['payment','bottle','both','none'] loop
  paid:=case when kind in ('bottle','none') then 700 else 0 end;
  result:=public.create_pos_sale('0177000000'||(select count(*)+1 from details_fixture),'Details '||kind,null,null,'retail',0,0,null,
   jsonb_build_array(jsonb_build_object('item_id',i,'type','refill','quantity',1,'unit_price',700),jsonb_build_object('item_id',i,'type','empty_return','quantity',1,'unit_price',0)),null,gen_random_uuid(),
   case when paid>0 then jsonb_build_array(jsonb_build_object('wallet_id',w,'amount',paid)) else '[]'::jsonb end,
   jsonb_build_object('lines',case when kind in ('payment','none') then jsonb_build_array(jsonb_build_object('received_item_id',i,'quantity',1)) else '[]'::jsonb end));
  s:=(result->>'sale_id')::uuid;
  insert into details_fixture select s,customer_id,kind from public.sales where tenant_id=t and sale_id=s;
  result:=public.get_sale_details(s);
  perform pg_temp.assert_details(result->>'sale_id'=s::text,'Saved sale details load');
  perform pg_temp.assert_details(result->'actor'->>'full_name'='Details owner','Recorded actor is retained');
  perform pg_temp.assert_details(jsonb_array_length(result->'sale_items')=2,'Original product lines load');
 end loop;
 perform pg_temp.assert_details((public.get_customer_directory('{"dues":"payment"}')->>'total')::int=2,'Payment Due includes customers with both dues');
 perform pg_temp.assert_details((public.get_customer_directory('{"dues":"bottle"}')->>'total')::int=2,'Bottle Due includes customers with both dues');
 perform pg_temp.assert_details((public.get_customer_directory('{"dues":"both"}')->>'total')::int=1,'Both is the intersection');
 perform pg_temp.assert_details((public.get_customer_directory('{"dues":"none"}')->>'total')::int=1,'None excludes both kinds of dues');
 result:=public.get_inventory_history('{}',0,10);
 perform pg_temp.assert_details(jsonb_array_length(result->'entries')>0,'Inventory history loads');
 perform pg_temp.assert_details(result->'entries'->0->'actor'->>'email'='details-dues@example.invalid','Movement actor is retained');
 perform pg_temp.assert_details(jsonb_array_length(public.get_inventory_history('{"item_ids":[]}',0,10)->'entries')=0,'Empty product filter stays empty');
 perform pg_temp.assert_details(jsonb_array_length(public.get_inventory_history('{"source":"purchase"}',0,10)->'entries')=0,'Source filter excludes sales/openings');
 perform pg_temp.assert_details(jsonb_array_length(public.get_inventory_history('{"source":"sale"}',0,10)->'entries')>0,'Source filter includes sale movements');
 -- A partially returned bottle obligation remains due; full settlement removes it.
 select f.sale into s from details_fixture f where f.kind='both';
 perform public.collect_sale_bottles(s,jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('received_item_id',i,'quantity',1))),gen_random_uuid());
 perform pg_temp.assert_details((public.get_customer_directory('{"dues":"bottle"}')->>'total')::int=1,'Physical collection removes bottle due');
 perform pg_temp.assert_details((public.get_customer_directory('{"dues":"both"}')->>'total')::int=0,'Money-only customer leaves Both');
 perform public.collect_sale_payment(s,jsonb_build_array(jsonb_build_object('wallet_id',w,'amount',700)),gen_random_uuid());
 perform pg_temp.assert_details((public.get_customer_directory('{"dues":"none"}')->>'total')::int=2,'Settlement moves customer to None');
end $$;
-- Run reads as the actual API role and verify RLS-equivalent boundaries.
set local role authenticated;
do $$declare result jsonb;begin
 result:=public.get_sale_details((select sale_id from public.sales where tenant_id=app_private.current_tenant_id() limit 1));
 perform pg_temp.assert_details(result->'actor'->>'full_name'='Details owner','Authenticated role can read attributed details');
 begin perform public.get_sale_details(gen_random_uuid());raise exception 'FAIL: absent sale accepted';exception when no_data_found then null;end;
 begin perform public.get_inventory_history('{"source":"invalid"}');raise exception 'FAIL: invalid source accepted';exception when raise_exception then if sqlerrm like 'FAIL:%' then raise;end if;end;
end $$;
reset role;
select pg_temp.fixture_identity('');
set local role anon;
do $$begin
 begin perform public.get_sale_details(gen_random_uuid());raise exception 'FAIL: anonymous details accepted';exception when insufficient_privilege then null;end;
 begin perform public.get_inventory_history();raise exception 'FAIL: anonymous inventory accepted';exception when insufficient_privilege then null;end;
end $$;
reset role;
select 'PASS: saved transaction and movement attribution, inclusive dues filters, collections, anonymous/absent-record denial';
rollback;
