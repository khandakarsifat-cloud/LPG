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
insert into public.items(tenant_id, item_id, brand, size_kg, filled_quantity, empty_quantity)
  values ('c1111111-1111-4111-8111-111111111111', 'c3333333-3333-4333-8333-333333333333', 'Print test item', 12, 10, 10);

insert into public.customers(tenant_id,customer_id,name,phone,tier) values
 ('c1111111-1111-4111-8111-111111111111','c5555555-5555-4555-8555-555555555555','Saved retail','01700000000','retail'),
 ('c1111111-1111-4111-8111-111111111111','c6666666-6666-4666-8666-666666666666','Saved wholesale','01700000001','wholesale'),
 ('d1111111-1111-4111-8111-111111111111','c5555555-5555-4555-8555-555555555555','Other tenant','01700000000','retail');
insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price,effective_from) values ('c1111111-1111-4111-8111-111111111111','c3333333-3333-4333-8333-333333333333','retail','package',2300,now()-interval '1 day');
create temp table pos_context(request uuid,result jsonb);grant all on pos_context to authenticated;
set local role authenticated;
select set_config('request.jwt.claim.sub','c2222222-2222-4222-8222-222222222222',true);
create function pg_temp.pos_check(ok boolean,label text) returns void language plpgsql as $$
begin if ok is not true then raise exception 'FAIL: %',label; end if; end $$;
create function pg_temp.pos_fails(statement text,expected text) returns void language plpgsql as $$
begin
 begin execute statement;
 exception when others then
  if position(expected in sqlerrm)>0 then return; end if;
  raise exception 'FAIL: expected %, got %',expected,sqlerrm;
 end;
 raise exception 'FAIL: invalid POS request succeeded';
end $$;
do $$
declare result jsonb; repeated jsonb; request uuid:=gen_random_uuid(); bad jsonb;
 items jsonb:='[{"item_id":"c3333333-3333-4333-8333-333333333333","type":"package","quantity":1,"unit_price":2300}]';
 prefix text:='select public.create_pos_sale(''01700000000'',null,null,null,''retail'',';
 suffix text;
begin
 result:=public.create_pos_sale('01700000000',null,null,null,'retail',0,0,null,items,'c5555555-5555-4555-8555-555555555555',request);
 repeated:=public.create_pos_sale('01700000000',null,null,null,'retail',0,0,null,items,'c5555555-5555-4555-8555-555555555555',request);
 perform pg_temp.pos_check(result=repeated,'same request returns original result');
 insert into pos_context values(request,result);
 perform pg_temp.pos_check((select count(*) from public.sales)=1,'retry creates one sale');
 perform pg_temp.pos_check((select filled_quantity=9 and empty_quantity=9 from public.items limit 1),'retry moves stock once');
 perform pg_temp.pos_check((select count(*)=1 and sum(amount)=2300 from public.wallet_transactions where type='pos_sale_income'),'one income ledger row');
 perform pg_temp.pos_check((select balance from public.wallets where type='cash')=2300,'wallet credit matches ledger');
 perform pg_temp.pos_check((select count(*)=2 and sum(amount)=0 from public.customer_transactions),'paired customer transactions');
 perform pg_temp.pos_fails(format('select public.create_pos_sale(''01700000000'',null,null,null,''retail'',1,0,null,%L,''c5555555-5555-4555-8555-555555555555'',%L)',items,request),'different sale details');
 suffix:=format(',0,null,%L,''c5555555-5555-4555-8555-555555555555'',%L)',items,gen_random_uuid());
 perform pg_temp.pos_fails(prefix||quote_literal('NaN')||suffix,'finite');
 perform pg_temp.pos_fails(prefix||quote_literal('Infinity')||suffix,'finite');
 perform pg_temp.pos_fails(prefix||'0.001'||suffix,'decimal places');
 perform pg_temp.pos_fails(prefix||'-1'||suffix,'nonnegative');
 perform pg_temp.pos_fails(prefix||'2301'||suffix,'Discount');
 perform pg_temp.pos_fails(format('select public.create_pos_sale(''01700000000'',null,null,null,''retail'',0,''NaN'',null,%L,null,%L)',items,gen_random_uuid()),'finite');
 perform pg_temp.pos_fails(format('select public.create_pos_sale(''01700000000'',null,null,null,''retail'',0,0,null,%L)',items),'request ID');
 for bad in select value from jsonb_array_elements('[{"unit_price":1},{"unit_price":"NaN"},{"unit_price":1.001},{"quantity":1.5},{"quantity":0},{"quantity":-1},{"quantity":10},{"item_id":"d3333333-3333-4333-8333-333333333333"}]') loop
   begin
    perform public.create_pos_sale('01700000007','Should roll back',null,null,'retail',0,0,null,jsonb_build_array((items->0)||bad),null,gen_random_uuid());
    raise exception 'FAIL: invalid line accepted';
   exception when others then if sqlerrm like 'FAIL:%' then raise; end if; end;
 end loop;
 perform pg_temp.pos_fails(format('select public.create_pos_sale(''01700000000'',null,null,null,''retail'',0,0,null,%L,null,%L)',jsonb_build_array((items->0)||'{"type":"empty_return","unit_price":1}'::jsonb),gen_random_uuid()),'zero price');
 perform pg_temp.pos_check((select count(*) from public.sales)=1 and not exists(select 1 from public.customers where phone='01700000007'),'failed requests roll back all writes');
 perform pg_temp.pos_check((select balance from public.wallets where type='cash')=2300 and (select count(*) from public.inventory_movements)=1,'failed requests preserve wallet and stock');
 result:=public.create_pos_sale('01700000001',null,null,null,'wholesale',2300,0,null,items,'c6666666-6666-4666-8666-666666666666',gen_random_uuid());
 perform pg_temp.pos_check((result->>'total_amount')::numeric=0,'wholesale fallback and full discount');
 perform pg_temp.pos_check(not exists(select 1 from public.wallet_transactions where reference_id=(result->>'sale_id')::uuid),'zero-total sale creates no received money');
end $$;
reset role;
update public.price_books set price=2400 where tenant_id='c1111111-1111-4111-8111-111111111111';
update public.customers set name='Changed later',tier='wholesale' where tenant_id='c1111111-1111-4111-8111-111111111111';
set local role authenticated;
do $$ declare items jsonb:='[{"item_id":"c3333333-3333-4333-8333-333333333333","type":"package","quantity":1,"unit_price":2300}]';r jsonb;
begin
 r:=public.create_pos_sale('01700000000',null,null,null,'retail',0,0,null,items,'c5555555-5555-4555-8555-555555555555',(select request from pos_context));
 perform pg_temp.pos_check(r=(select result from pos_context),'replay retains original response after changes');
 perform pg_temp.pos_fails(format('select public.create_pos_sale(''01700000000'',null,null,null,''retail'',0,0,null,%L,null,%L)',items,gen_random_uuid()),'price book');
 perform pg_temp.pos_fails('select public.create_pos_sale(''01700000008'',null,null,null,''retail'',0,0,null,''[]'',null,gen_random_uuid())','nonempty');
end $$;
reset role;
create function pg_temp.reject_pos_income() returns trigger language plpgsql as $$
begin if new.type='pos_sale_income' then raise exception 'Injected accounting failure';end if;return new;end $$;
create trigger test_reject_pos before insert on public.wallet_transactions for each row execute function pg_temp.reject_pos_income();
set local role authenticated;
select pg_temp.pos_fails('select public.create_pos_sale(''01700000008'',''Rollback'',null,null,''retail'',0,0,null,''[{"item_id":"c3333333-3333-4333-8333-333333333333","type":"package","quantity":1,"unit_price":2400}]'',null,''c7777777-7777-4777-8777-777777777777'')','Injected accounting failure');
select pg_temp.pos_check(not exists(select 1 from public.customers where phone='01700000008') and (select count(*) from public.sales)=2,'late failure removes new customer and sale');
select pg_temp.pos_check((select filled_quantity=8 and empty_quantity=8 from public.items limit 1) and (select count(*) from public.customer_transactions)=3,'late failure restores stock and customer ledger; zero-total sale has no payment receipt');
reset role;
drop trigger test_reject_pos on public.wallet_transactions;
set local role authenticated;
select public.create_pos_sale('01700000008','Rollback',null,null,'retail',0,0,null,
 '[{"item_id":"c3333333-3333-4333-8333-333333333333","type":"package","quantity":1,"unit_price":2400}]',null,'c7777777-7777-4777-8777-777777777777');
select pg_temp.pos_check((select count(*) from public.sales)=3,'the same request succeeds after a rolled-back accounting failure');
reset role;
insert into public.items(tenant_id,item_id,brand,size_kg,filled_quantity,empty_quantity) values
 ('c1111111-1111-4111-8111-111111111111','c3333333-3333-4333-8333-333333333334','Zero-price fixture',5,2,2);
insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price,effective_from) values
 ('c1111111-1111-4111-8111-111111111111','c3333333-3333-4333-8333-333333333334','retail','package',0,now()-interval '1 day'),
 ('c1111111-1111-4111-8111-111111111111','c3333333-3333-4333-8333-333333333334','wholesale','package',900,now()+interval '1 day');
set local role authenticated;
select public.create_pos_sale('01700000000',null,null,null,'wholesale',0,0,null,
 '[{"item_id":"c3333333-3333-4333-8333-333333333334","type":"package","quantity":1.0,"unit_price":0}]',
 'c5555555-5555-4555-8555-555555555555',gen_random_uuid());
select pg_temp.pos_check((select count(*) from public.sales)=4,'whole-number decimals, explicit zero price, future-price exclusion and wholesale fallback');
reset role;
update public.price_books set effective_to=now()-interval '1 hour' where tenant_id='c1111111-1111-4111-8111-111111111111'
 and item_id='c3333333-3333-4333-8333-333333333334' and customer_tier='retail';
set local role authenticated;
select pg_temp.pos_fails('select public.create_pos_sale(''01700000000'',null,null,null,''wholesale'',0,0,null,''[{"item_id":"c3333333-3333-4333-8333-333333333334","type":"package","quantity":1,"unit_price":0}]'',null,gen_random_uuid())','No active selling price');
reset role;
insert into public.items(tenant_id,item_id,brand,size_kg,filled_quantity,empty_quantity) values
 ('d1111111-1111-4111-8111-111111111111','c3333333-3333-4333-8333-333333333333','Other business',12,2,2);
insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price,effective_from) values
 ('d1111111-1111-4111-8111-111111111111','c3333333-3333-4333-8333-333333333333','retail','package',2300,now()-interval '1 day');
set local role authenticated;
select set_config('request.jwt.claim.sub','d2222222-2222-4222-8222-222222222222',true);
do $$ declare r jsonb; begin
 r:=public.create_pos_sale('01700000000',null,null,null,'retail',0,0,null,
  '[{"item_id":"c3333333-3333-4333-8333-333333333333","type":"package","quantity":1,"unit_price":2300}]',
  'c5555555-5555-4555-8555-555555555555',(select request from pos_context));
 perform pg_temp.pos_check(r->>'sale_id'<>(select result->>'sale_id' from pos_context),'request IDs are tenant-scoped');
 perform pg_temp.pos_check((select count(*) from public.sales)=1 and (select balance from public.wallets where type='cash')=2300,'reused IDs cannot replay or change another tenant sale');
end $$;
select set_config('request.jwt.claim.sub','c2222222-2222-4222-8222-222222222222',true);
reset role;
delete from public.role_permissions where tenant_id='c1111111-1111-4111-8111-111111111111' and permission_id='pos:sell';
set local role authenticated;
select pg_temp.pos_fails('select public.create_pos_sale(''01700000000'',null,null,null,''retail'',0,0,null,''[]'',null,gen_random_uuid())','Permission denied');
set local role anon;
select pg_temp.pos_fails('select public.create_pos_sale(''01700000000'',null,null,null,''retail'',0,0,null,''[]'',null,gen_random_uuid())','permission denied');
reset role;
select 'PASS: POS idempotency, changed requests, strict prices/money/quantities, original response, atomic stock/customer/wallet posting, rollback and authorization' as verification;
rollback;
