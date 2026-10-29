-- Run on the local LPG database through execute_sql/psql. All fixtures roll back.
begin;

insert into public.tenants(tenant_id, business_name) values
  ('c1111111-1111-4111-8111-111111111111', 'Printer integration test A'),
  ('d1111111-1111-4111-8111-111111111111', 'Printer integration test B');
insert into auth.users(id, email, is_anonymous) values
  ('c2222222-2222-4222-8222-222222222222', 'tier-a@example.invalid', false),
  ('d2222222-2222-4222-8222-222222222222', 'tier-b@example.invalid', false);
insert into public.user_profiles(user_id, tenant_id, email) values
  ('c2222222-2222-4222-8222-222222222222', 'c1111111-1111-4111-8111-111111111111', 'tier-a@example.invalid'),
  ('d2222222-2222-4222-8222-222222222222', 'd1111111-1111-4111-8111-111111111111', 'tier-b@example.invalid');
insert into public.roles(tenant_id, role_id, name) values
  ('c1111111-1111-4111-8111-111111111111', 'c4444444-4444-4444-8444-444444444444', 'OWNER'),
  ('d1111111-1111-4111-8111-111111111111', 'd4444444-4444-4444-8444-444444444444', 'OWNER');
insert into public.role_permissions(tenant_id, role_id, permission_id)
select r.tenant_id, r.role_id, p.permission_id from public.roles r cross join public.permissions p
where r.tenant_id in ('c1111111-1111-4111-8111-111111111111', 'd1111111-1111-4111-8111-111111111111');
insert into public.user_roles(tenant_id, user_id, role_id) values
  ('c1111111-1111-4111-8111-111111111111', 'c2222222-2222-4222-8222-222222222222', 'c4444444-4444-4444-8444-444444444444'),
  ('d1111111-1111-4111-8111-111111111111', 'd2222222-2222-4222-8222-222222222222', 'd4444444-4444-4444-8444-444444444444');
insert into public.items(tenant_id,item_id,brand_id,size_kg,filled_quantity,empty_quantity) values ('c1111111-1111-4111-8111-111111111111', 'c3333333-3333-4333-8333-333333333333',pg_temp.fixture_brand('c1111111-1111-4111-8111-111111111111', 'Print test item'), 12, 10, 10);

insert into public.customers(tenant_id,customer_id,name,phone,tier) values
 ('c1111111-1111-4111-8111-111111111111','c5555555-5555-4555-8555-555555555555','Saved retail','01700000000','retail'),
 ('c1111111-1111-4111-8111-111111111111','c6666666-6666-4666-8666-666666666666','Saved wholesale','01700000001','wholesale'),
 ('d1111111-1111-4111-8111-111111111111','c5555555-5555-4555-8555-555555555555','Other tenant','01700000000','retail');
insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price,effective_from) values ('c1111111-1111-4111-8111-111111111111','c3333333-3333-4333-8333-333333333333','retail','package',2300,now()-interval '1 day');
set local role authenticated;
select set_config('request.jwt.claim.sub','c2222222-2222-4222-8222-222222222222',true);

reset role;
insert into public.items(tenant_id,item_id,brand_id,size_kg,mouth_size,filled_quantity,empty_quantity) values ('c1111111-1111-4111-8111-111111111111','cb000000-0000-4000-8000-000000000001',pg_temp.fixture_brand('c1111111-1111-4111-8111-111111111111','Other brand'),12,'22mm',20,10),
 ('c1111111-1111-4111-8111-111111111111','cb000000-0000-4000-8000-000000000002',pg_temp.fixture_brand('c1111111-1111-4111-8111-111111111111','Different size'),5,'20mm',20,10);
update public.items set mouth_size='22mm',filled_quantity=100,empty_quantity=10 where item_id='c3333333-3333-4333-8333-333333333333';
insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price,effective_from) values
 ('c1111111-1111-4111-8111-111111111111','c3333333-3333-4333-8333-333333333333','retail','refill',100,now()-interval '1 day');
set local role authenticated;
select set_config('request.jwt.claim.sub','c2222222-2222-4222-8222-222222222222',true);


do $$
declare a uuid:='c3333333-3333-4333-8333-333333333333'; b uuid:='cb000000-0000-4000-8000-000000000001'; c uuid:='cb000000-0000-4000-8000-000000000002';
 sid uuid; second uuid; rid uuid:=gen_random_uuid(); cash uuid; bank uuid; result jsonb; details jsonb; body jsonb; cart jsonb; rejected jsonb; original_stock integer;
begin
 select wallet_id into cash from public.wallets where type='cash';
 select wallet_id into bank from public.wallets where type='dealership';
 cart:=jsonb_build_array(jsonb_build_object('item_id',a,'type','refill','quantity',5,'unit_price',100),jsonb_build_object('item_id',a,'type','empty_return','quantity',5,'unit_price',0));
 body:=jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('received_item_id',a,'quantity',1)));
 result:=public.create_pos_sale('01700000000',null,null,null,'retail',20,10,'Dynamic receipt fixture',cart,'c5555555-5555-4555-8555-555555555555',rid,'[]',body);sid:=(result->>'sale_id')::uuid;
 if public.create_pos_sale('01700000000',null,null,null,'retail',20,10,'Dynamic receipt fixture',cart,'c5555555-5555-4555-8555-555555555555',rid,'[]',body)<>result then raise exception 'Checkout retry changed'; end if;
 if (public.get_sale_bottles(sid)->>'outstanding')::integer<>4 then raise exception 'Partial checkout incorrect'; end if;
 body:=jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('received_item_id',a,'quantity',2)),'fee',100);
 rid:=gen_random_uuid(); result:=public.collect_sale_bottles(sid,body,rid);
 if public.collect_sale_bottles(sid,body,rid)<>result then raise exception 'Collection retry changed'; end if;
 begin perform public.collect_sale_bottles(sid,body||'{"fee":101}',rid);raise exception 'CHANGED KEY ACCEPTED';exception when raise_exception then if sqlerrm='CHANGED KEY ACCEPTED' then raise; end if;end;
 details:=public.get_sale_settlement(sid);
 if details->>'original_total'<>'490.00' or (details->>'total')::numeric<>590 or (details->>'due')::numeric<>590 or (details->>'paid')::numeric<>0 then raise exception 'Charge did not become customer liability %',details;end if;
 if (select balance from public.wallets where wallet_id=cash)<>0 then raise exception 'Recording cost moved money';end if;
 if public.get_customer_balance('c5555555-5555-4555-8555-555555555555')<>590 then raise exception 'Charge missing from customer ledger';end if;
 perform public.collect_sale_payment(sid,jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',100),jsonb_build_object('wallet_id',bank,'amount',50)),gen_random_uuid());
 if (public.get_sale_settlement(sid)->>'due')::numeric<>440 or (public.get_sale_bottles(sid)->>'outstanding')::integer<>2 then raise exception 'Partial payment coupled to bottles';end if;
 perform public.collect_sale_bottles(sid,jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('received_item_id',b,'quantity',2,'acknowledged',true)),'fee',25),gen_random_uuid());
 details:=public.get_sale_receipt(sid);
 if (details#>>'{bottles,outstanding}')::integer<>0 or (details#>>'{bottles,received}')::integer<>5 or (details#>>'{settlement,due}')::numeric<>465 then raise exception 'Latest receipt stale %',details;end if;
 if (details#>>'{sale,total_amount}')::numeric<>490 or (details#>>'{settlement,additional_charges}')::numeric<>125 then raise exception 'Invoice overwritten';end if;
 if jsonb_array_length(details#>'{bottles,actual}')<>3 then raise exception 'Checkout/collection products missing';end if;
 if not exists(select 1 from jsonb_array_elements(details#>'{bottles,obligations}') o where (o->>'item_id')::uuid=a and (o->>'expected')::integer=5 and (o->>'received')::integer=3) then raise exception 'Actual products allocated incorrectly';end if;
 rid:=gen_random_uuid();body:=jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',465));result:=public.collect_sale_payment(sid,body,rid);
 if public.collect_sale_payment(sid,body,rid)<>result or (public.get_sale_settlement(sid)->>'due')::numeric<>0 then raise exception 'Final payment/retry failed';end if;
 -- Fresh sale: validation failures must roll back charge, receipt and inventory together.
 result:=public.create_pos_sale('01700000000',null,null,null,'retail',0,0,null,cart,'c5555555-5555-4555-8555-555555555555',gen_random_uuid(),'[]','{"lines":[]}'); second:=(result->>'sale_id')::uuid;
 foreach rejected in array array[
 '{"lines":[],"fee":10}'::jsonb,
 jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('received_item_id',a,'quantity',-1)),'fee',10),
 jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('received_item_id',a,'quantity',1.5)),'fee',10),
 jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('received_item_id',a,'quantity',1),jsonb_build_object('received_item_id',a,'quantity',1)),'fee',10),
 jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('received_item_id',gen_random_uuid(),'quantity',1,'acknowledged',true)),'fee',10),
 jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('received_item_id',b,'quantity',1)),'fee',10),
 jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('received_item_id',a,'quantity',1)),'expense',10,'expense_wallet_id',cash),
 jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('received_item_id',a,'quantity',1)),'fee',1.001),
 jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('received_item_id',a,'quantity',1)),'fee',-1),
 jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('received_item_id',a,'quantity',1)),'fee','NaN'),
 jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('received_item_id',a,'quantity',1)),'fee',10,'payments',jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',1)))
 ] loop
  begin perform public.collect_sale_bottles(second,rejected,gen_random_uuid());raise exception 'INVALID ACCEPTED';
  exception when others then if sqlerrm='INVALID ACCEPTED' then raise;end if;end;
 end loop;
 if (public.get_sale_bottles(second)->>'outstanding')::integer<>5 or (public.get_sale_settlement(second)->>'additional_charges')::numeric<>0 then raise exception 'Failed collection leaked effects';end if;
 -- Overshoot is physical stock, never a negative debt or a credit against other sales.
 perform public.collect_sale_bottles(second,jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('received_item_id',c,'quantity',8,'acknowledged',true))),gen_random_uuid());
 if (public.get_sale_bottles(second)->>'received')::integer<>8 or (public.get_sale_bottles(second)->>'outstanding')::integer<>0 then raise exception 'Overreceipt capped or debt negative';end if;
 begin perform public.collect_sale_bottles(second,jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('received_item_id',a,'quantity',1))),gen_random_uuid());raise exception 'SETTLED ACCEPTED';exception when raise_exception then if sqlerrm='SETTLED ACCEPTED' then raise;end if;end;
 result:=public.create_pos_sale('01700000000',null,null,null,'retail',0,0,null,cart,'c5555555-5555-4555-8555-555555555555',gen_random_uuid(),'[]','{"lines":[]}');
 if (public.get_sales_overview()->>'bottles')::integer<>5 or public.get_customer_bottle_balance('c5555555-5555-4555-8555-555555555555')<>5 then raise exception 'Overreceipt cancelled another sale debt';end if;
 if (public.get_sales_directory('{"bottles":"received"}')->>'total')::integer<>2 then raise exception 'Settled filter excludes overreceipts';end if;
 -- Alternate product and overreceipt at checkout retain original expectations.
 result:=public.create_pos_sale('01700000000',null,null,null,'retail',0,0,null,cart,'c5555555-5555-4555-8555-555555555555',gen_random_uuid(),'[]',jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('received_item_id',b,'quantity',6,'acknowledged',true))));
 if (public.get_sale_bottles((result->>'sale_id')::uuid)->>'received')::integer<>6 then raise exception 'Alternate checkout lost stock';end if;
 begin delete from public.sale_bottle_receipts;raise exception 'DIRECT WRITE';exception when insufficient_privilege then null;end;
 perform set_config('lpg.receipt_fixture',sid::text,true);
end $$;
reset role;
-- Current identity, saved transaction amounts. No receipt snapshot is persisted.
update public.customers set name='Current receipt customer' where tenant_id='c1111111-1111-4111-8111-111111111111' and customer_id='c5555555-5555-4555-8555-555555555555';
update public.tenants set business_name='Current receipt business' where tenant_id='c1111111-1111-4111-8111-111111111111';
update public.lpg_brands set brand_name='Current receipt brand' where (tenant_id,brand_id) in (select tenant_id,brand_id from public.items where tenant_id='c1111111-1111-4111-8111-111111111111' and item_id='c3333333-3333-4333-8333-333333333333');
do $$begin
 if exists(select 1 from public.wallet_transactions where type='sale_bottle_expense' and tenant_id='c1111111-1111-4111-8111-111111111111') then raise exception 'New collection created expense';end if;
 if exists(select 1 from public.wallets w where balance<>opening_balance+coalesce((select sum(amount) from public.wallet_transactions x where x.tenant_id=w.tenant_id and x.wallet_id=w.wallet_id),0)) then raise exception 'Wallet reconciliation failed';end if;
 begin update public.sale_bottle_receipts set note='rewrite';raise exception 'HISTORY MUTABLE';exception when raise_exception then if sqlerrm='HISTORY MUTABLE' then raise;end if;end;
end $$;
set local role authenticated;
do $$declare r jsonb;begin
 r:=public.get_sale_receipt(current_setting('lpg.receipt_fixture')::uuid);
 if r->>'shop_name'<>'Current receipt business' or r#>>'{sale,customers,name}'<>'Current receipt customer' or r#>>'{sale,sale_items,0,items,lpg_brands,brand_name}'<>'Current receipt brand' then raise exception 'Current identity stale';end if;
end $$;
reset role;
delete from public.role_permissions where tenant_id='c1111111-1111-4111-8111-111111111111' and permission_id in ('finance:manage','receipts:print');
set local role authenticated;
do $$declare sid uuid; a uuid:='c3333333-3333-4333-8333-333333333333';begin
 begin perform public.get_sale_receipt(current_setting('lpg.receipt_fixture')::uuid);raise exception 'RECEIPT PERMISSION';exception when insufficient_privilege then null;end;
 select sale_id into sid from public.sales where sale_id<>current_setting('lpg.receipt_fixture')::uuid and sale_id in (select (e->>'sale_id')::uuid from jsonb_array_elements(public.get_sales_directory('{"bottles":"outstanding"}')->'entries') e) limit 1;
 begin perform public.collect_sale_bottles(sid,jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('received_item_id',a,'quantity',1)),'fee',1),gen_random_uuid());raise exception 'CHARGE PERMISSION';exception when insufficient_privilege then null;end;
 perform public.collect_sale_bottles(sid,jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('received_item_id',a,'quantity',1))),gen_random_uuid());
end $$;
select set_config('request.jwt.claim.sub','d2222222-2222-4222-8222-222222222222',true);
do $$begin
 if (public.get_sales_directory()->>'total')::integer<>0 then raise exception 'Foreign sale leaked';end if;
 begin perform public.get_sale_receipt(current_setting('lpg.receipt_fixture')::uuid);raise exception 'FOREIGN RECEIPT';exception when raise_exception then if sqlerrm='FOREIGN RECEIPT' then raise;end if;end;
end $$;
reset role;
do $$ begin
 begin
  update public.sale_items set quantity=quantity+1 where sale_id=current_setting('lpg.receipt_fixture')::uuid;
  raise exception 'IMMUTABLE AGREEMENT CHANGED';
 exception when raise_exception then
  if sqlerrm not like 'Financial records are immutable%' then raise; end if;
 end;
end $$;
select 'PASS: dynamic receipts, original invoice preservation, alternate/over/partial/multiple receipts, customer settlement costs, split/partial payments, retry safety, rollback and tenant/capability isolation';
rollback;
