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
set local role authenticated;
select set_config('request.jwt.claim.sub','c2222222-2222-4222-8222-222222222222',true);
create function pg_temp.finance_check(ok boolean,msg text) returns void language plpgsql as $$ begin if ok is not true then raise exception 'FAIL: %',msg; end if; end $$;
create function pg_temp.finance_fails(statement text,expected text) returns void language plpgsql as $$
begin
 begin execute statement; exception when others then
  if position(lower(expected) in lower(sqlerrm))=0 then raise exception 'Expected %; got %',expected,sqlerrm; end if;
  return;
 end;
 raise exception 'Expected rejection: %',expected;
end $$;
do $$
declare t uuid:='c1111111-1111-4111-8111-111111111111'; cash uuid; bank uuid; bkash uuid; other uuid; foreign_wallet uuid;
 payload jsonb:='[{"item_id":"c3333333-3333-4333-8333-333333333333","type":"package","quantity":1,"unit_price":2300}]';
 r jsonb; replay jsonb; sid uuid; zero_sale uuid; request uuid:=gen_random_uuid(); collection uuid:=gen_random_uuid(); move uuid:=gen_random_uuid();
 before_stock integer; before_sales integer; before_entries integer; before_balance numeric; before_total numeric;
begin
 perform pg_temp.finance_check((select count(*) from public.wallets)=5,'new business defaults and RLS');
 select wallet_id into cash from public.wallets where type='cash'; select wallet_id into bank from public.wallets where type='dealership'; select wallet_id into bkash from public.wallets where type='bkash';
 perform pg_temp.finance_check((select count(*) from public.get_payment_wallets())=4,'POS destinations exclude logistics');
 perform public.move_wallet_money(jsonb_build_object('action','adjustment','wallet_id',bank,'amount',10000,'reason','Opening bank funds'),gen_random_uuid());
 r:=public.create_pos_sale('01700000000',null,null,null,'retail',0,0,null,payload,'c5555555-5555-4555-8555-555555555555',request);
 replay:=public.create_pos_sale('01700000000',null,null,null,'retail',0,0,null,payload,'c5555555-5555-4555-8555-555555555555',request);
 perform pg_temp.finance_check(r=replay and (select balance from public.wallets where wallet_id=cash)=2300 and (select balance from public.wallets where wallet_id=bank)=10000,'default cash and retry once');
 request:=gen_random_uuid();
 r:=public.create_pos_sale('01700000000',null,null,null,'retail',0,0,null,payload,'c5555555-5555-4555-8555-555555555555',request,
  jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',500),jsonb_build_object('wallet_id',bkash,'amount',700,'reference','BK-ABC')));
 sid:=(r->>'sale_id')::uuid;
 perform pg_temp.finance_check((r->>'due')::numeric=1100 and (select count(*) from public.sale_payments where sale_id=sid)=2,'split partial payment');
 perform pg_temp.finance_check(public.get_customer_balance('c5555555-5555-4555-8555-555555555555')=1100,'invoice due stays out of wallets');
 r:=public.collect_sale_payment(sid,jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',600),jsonb_build_object('wallet_id',bank,'amount',500)),collection);
 replay:=public.collect_sale_payment(sid,jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',600),jsonb_build_object('wallet_id',bank,'amount',500)),collection);
 perform pg_temp.finance_check(r=replay and (r->>'due')::numeric=0 and (select count(*) from public.sale_payments where sale_id=sid)=4,'collection retry and attribution');
 perform pg_temp.finance_check((select balance from public.wallets where wallet_id=cash)=3400 and (select balance from public.wallets where wallet_id=bkash)=700 and (select balance from public.wallets where wallet_id=bank)=10500,'wallet balances equal received money');
 perform pg_temp.finance_check((select sum(amount) from public.customer_transactions where reference_id=sid)=0,'customer reconciles after collection');
 perform pg_temp.finance_fails(format('select public.collect_sale_payment(%L,%L,%L)',sid,jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',1)),collection),'different details');
 perform pg_temp.finance_fails(format('select public.collect_sale_payment(%L,%L,%L)',sid,jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',1)),gen_random_uuid()),'exceed');
 r:=public.create_pos_sale('01700000000',null,null,null,'retail',0,0,null,payload,'c5555555-5555-4555-8555-555555555555',gen_random_uuid(),'[]');zero_sale:=(r->>'sale_id')::uuid;
 perform pg_temp.finance_check((r->>'paid_amount')::numeric=0 and (r->>'due')::numeric=2300 and not exists(select 1 from public.wallet_transactions where reference_id=zero_sale),'zero initial payment');
 perform pg_temp.finance_check(public.get_customer_balance('c5555555-5555-4555-8555-555555555555')=2300 and (public.get_finance_dues()->>'due')::numeric=2300,'customer and finance outstanding agree');
 before_stock:=(select filled_quantity from public.items limit 1);before_sales:=(select count(*) from public.sales);before_entries:=(select count(*) from public.wallet_transactions);before_balance:=(select balance from public.wallets where wallet_id=cash);
 perform pg_temp.finance_fails(format('select public.create_pos_sale(''01700000000'',null,null,null,''retail'',0,0,null,%L,''c5555555-5555-4555-8555-555555555555'',%L,%L)',payload,gen_random_uuid(),jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',1),jsonb_build_object('wallet_id',cash,'amount',2300))),'exceed');
 perform pg_temp.finance_check((select filled_quantity from public.items limit 1)=before_stock and (select count(*) from public.sales)=before_sales and (select count(*) from public.wallet_transactions)=before_entries and (select balance from public.wallets where wallet_id=cash)=before_balance,'overpayment rolls back sale, stock, payment, wallet and customer writes');
 perform pg_temp.finance_fails(format('select public.collect_sale_payment(%L,%L,%L)',zero_sale,jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',-1)),gen_random_uuid()),'nonnegative');
 perform pg_temp.finance_fails(format('select public.collect_sale_payment(%L,%L,%L)',zero_sale,jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount','NaN')),gen_random_uuid()),'numbers');
 perform pg_temp.finance_fails(format('select public.collect_sale_payment(%L,%L,%L)',zero_sale,jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',1.001)),gen_random_uuid()),'decimal');
 before_total:=(select sum(balance) from public.wallets);
 r:=public.move_wallet_money(jsonb_build_object('action','transfer','wallet_id',bank,'destination_id',cash,'amount',1000,'reason','Cash replenishment'),move);
 replay:=public.move_wallet_money(jsonb_build_object('action','transfer','wallet_id',bank,'destination_id',cash,'amount',1000,'reason','Cash replenishment'),move);
 perform pg_temp.finance_check(r=replay and (select sum(balance) from public.wallets)=before_total and (select count(*)=2 and sum(amount)=0 from public.wallet_transactions where operation_id=move),'transfer is balanced and idempotent');
 perform pg_temp.finance_fails(format('select public.move_wallet_money(%L,%L)',jsonb_build_object('action','transfer','wallet_id',bkash,'destination_id',cash,'amount',701,'reason','Over limit transfer'),gen_random_uuid()),'Insufficient');
 other:=public.save_finance_wallet('{"name":"Secondary Bank","kind":"bank"}');
 perform public.move_wallet_money(jsonb_build_object('action','adjustment','wallet_id',other,'amount',100,'reason','Opening float'),gen_random_uuid());
 perform pg_temp.finance_fails(format('select public.save_finance_wallet(%L)',jsonb_build_object('wallet_id',other,'revision',1,'name','Secondary Bank','kind','bank','is_active',false)),'zero');
 perform public.move_wallet_money(jsonb_build_object('action','transfer','wallet_id',other,'destination_id',cash,'amount',100,'reason','Close float'),gen_random_uuid());
 perform public.save_finance_wallet(jsonb_build_object('wallet_id',other,'revision',1,'name','Archived Bank','kind','bank','is_active',false));
 perform pg_temp.finance_check(not exists(select 1 from public.get_payment_wallets() where wallet_id=other),'archived wallets excluded from payments');
 perform pg_temp.finance_fails(format('select public.collect_sale_payment(%L,%L,%L)',zero_sale,jsonb_build_array(jsonb_build_object('wallet_id',other,'amount',1)),gen_random_uuid()),'active payment wallet');
 perform pg_temp.finance_fails(format('select public.save_finance_wallet(%L)',jsonb_build_object('wallet_id',cash,'revision',1,'name','Cash Register','kind','cash','is_active',false)),'Default wallets');
 perform public.save_finance_wallet(jsonb_build_object('wallet_id',bkash,'revision',1,'name','Company bKash','kind','bkash','is_active',true));
 perform pg_temp.finance_check(exists(select 1 from public.sale_payments where wallet_id=bkash and wallet_name='bKash'),'renaming preserves historical payment wallet names');
 perform pg_temp.finance_check((public.get_wallet_ledger(jsonb_build_object('search','BK-ABC','wallet',bkash))->>'total')::integer=1,'ledger reference and wallet filters');
 perform pg_temp.finance_check((public.get_wallet_ledger('{"search":"absent,BK-ABC","min":"700","max":"700","direction":"in"}')->>'total')::integer=1,'ledger OR search, amount and direction filters');
 perform pg_temp.finance_check((public.get_wallet_ledger('{"search":"%"}')->>'total')::integer=0,'search wildcard is literal');
 perform pg_temp.finance_check((public.get_wallet_ledger(jsonb_build_object('search','''; select 1; --'))->>'total')::integer=0,'search SQL punctuation is quoted');
 perform pg_temp.finance_check((public.get_wallet_ledger('{"type":"wallet_transfer"}',0,1)->'entries') @> jsonb_build_array(jsonb_build_object('type','wallet_transfer')),'ledger pagination');
 perform pg_temp.finance_check((public.get_sale_settlement(sid)->>'paid')::numeric=2300 and (public.get_sale_settlement(sid)->>'payment_count')::integer=4,'saved receipt settlement');
 perform pg_temp.finance_fails('delete from public.wallets','permission denied');
 perform pg_temp.finance_fails('update public.wallet_transactions set amount=100','permission denied');
 perform pg_temp.finance_fails('insert into public.sale_payments(tenant_id) values(null)','permission denied');
end $$;
create temporary table finance_cross as select sale_id,(select wallet_id from public.wallets where type='cash') wallet_id
 from public.sales where paid_amount<total_amount limit 1;
reset role;
do $$ begin
 if exists(select 1 from public.wallets w where w.tenant_id='c1111111-1111-4111-8111-111111111111' and w.balance<>w.opening_balance+coalesce((select sum(amount) from public.wallet_transactions x where x.tenant_id=w.tenant_id and x.wallet_id=w.wallet_id),0)) then raise exception 'Ledger and balance mismatch'; end if;
end $$;
select pg_temp.finance_fails('update public.wallet_transactions set amount=1','immutable');
select pg_temp.finance_fails('delete from public.sale_payments','immutable');
select set_config('request.jwt.claim.sub','d2222222-2222-4222-8222-222222222222',true);
set local role authenticated;
do $$ declare sid uuid; other uuid; own_wallet uuid; begin
 perform pg_temp.finance_check((select count(*) from public.wallets)=5 and not exists(select 1 from public.wallet_transactions),'cross-tenant history is invisible');
 select sale_id,wallet_id into sid,other from finance_cross;
 select wallet_id into own_wallet from public.wallets where type='cash';
 perform pg_temp.finance_fails(format('select public.get_sale_settlement(%L)',sid),'not found');
 perform pg_temp.finance_fails(format('select public.collect_sale_payment(%L,%L,%L)',sid,jsonb_build_array(jsonb_build_object('wallet_id',own_wallet,'amount',1)),gen_random_uuid()),'does not support');
 perform pg_temp.finance_fails(format('select public.move_wallet_money(%L,%L)',jsonb_build_object('action','transfer','wallet_id',own_wallet,'destination_id',other,'amount',1,'reason','Cross tenant attempt'),gen_random_uuid()),'destination wallet');
end $$;
reset role;
delete from public.role_permissions where tenant_id='c1111111-1111-4111-8111-111111111111' and permission_id='finance:manage';
select set_config('request.jwt.claim.sub','c2222222-2222-4222-8222-222222222222',true);
set local role authenticated;
do $$ begin
 perform pg_temp.finance_fails('select public.move_wallet_money(''{}'',gen_random_uuid())','permission');
 perform pg_temp.finance_fails('select public.collect_sale_payment(gen_random_uuid(),''[]'',gen_random_uuid())','permission');
 perform pg_temp.finance_fails('select public.save_finance_wallet(''{}'')','permission');
 perform pg_temp.finance_check((select count(*) from public.get_payment_wallets())=4,'read-only finance retains destination reads');
end $$;
reset role;
select 'PASS: wallet initialization, default cash, split/partial/zero payments, collections, retries, rollback, transfers, adjustments, custom wallets, filters, receipt attribution, tenant isolation and authorization';
rollback;
