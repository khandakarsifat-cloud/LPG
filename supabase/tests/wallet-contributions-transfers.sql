begin;
create function pg_temp.assert(ok boolean,message text) returns void language plpgsql as $$begin if ok is not true then raise exception 'FAIL: %',message;end if;end $$;
select pg_temp.assert(not exists(select 1 from public.accounting_lines l left join public.financial_types t using(type_id) where t.type_id is null or l.business_category not in ('lpg','stove','logistics')),'Every existing line has a valid type/category/business');
select pg_temp.assert(not exists(select 1 from public.accounting_lines group by tenant_id,journal_id,business_category having sum(amount)<>0),'Every restored journal balances for each business');
insert into auth.users(id,email,is_anonymous) values('fd010000-0000-4000-8000-000000000001','financial-dimensions@example.invalid',false);
set local role authenticated;
select set_config('request.jwt.claim.sub','fd010000-0000-4000-8000-000000000001',true);
select public.setup_business('Disposable dimensional system acceptance','Owner');
reset role;

do $$declare t uuid:=app_private.current_tenant_id();src uuid;dest uuid;k uuid:=gen_random_uuid();body jsonb; r jsonb; b text;before jsonb;after jsonb;pid uuid;bid uuid;val numeric;d date:=(now() at time zone 'Asia/Dhaka')::date;begin
 select wallet_id into src from public.get_payment_wallets() where type='cash';
 select wallet_id into dest from public.get_payment_wallets() where type='dealership';
 foreach b in array array['lpg','stove','logistics'] loop
  perform public.move_wallet_money(jsonb_build_object('action','adjustment','wallet_id',src,'business',b,'classification','correction','amount',case b when 'lpg' then 9000 when 'stove' then 3000 else -2000 end,'reason','Signed fixture seed'),gen_random_uuid());
 end loop;
 before:=app_private.accounting_position(array[t],d);
 body:=jsonb_build_object('action','transfer','wallet_id',src,'destination_id',dest,'amount',8000,'reason','Signed proportional transfer');
 perform public.move_wallet_money(body,k);perform public.move_wallet_money(body,k);
 perform pg_temp.assert((select balance=2000 and business_balances='{"lpg":1800,"stove":600,"logistics":-400}'::jsonb from public.wallets where wallet_id=src),'Signed source remainder');
 perform pg_temp.assert((select balance=8000 and business_balances='{"lpg":7200,"stove":2400,"logistics":-1600}'::jsonb from public.wallets where wallet_id=dest),'Signed destination distribution');
 perform pg_temp.assert((select count(*)=6 and sum(amount)=0 from public.wallet_transactions where tenant_id=t and operation_id=k),'Six paired entries and idempotent retry');
 after:=app_private.accounting_position(array[t],d);
 perform pg_temp.assert((before-'accounts')=(after-'accounts'),'Full position unchanged by proportional transfer');
 perform pg_temp.assert(not exists(select 1 from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where j.source='wallet' and j.source_id in (select transaction_id from public.wallet_transactions where operation_id=k) group by l.business_category,l.account having sum(l.amount)<>0),'All businesses retain cash and equity');
 perform public.move_wallet_money(jsonb_build_object('action','transfer','transfer_mode','business','wallet_id',src,'destination_id',src,'business','lpg','destination_business','stove','amount',10,'reason','Advanced ownership transfer'),gen_random_uuid());
 perform pg_temp.assert((select balance=2000 and (business_balances->>'lpg')::numeric=1790 and (business_balances->>'stove')::numeric=610 from public.wallets where wallet_id=src),'Advanced same-wallet transfer');
 -- Unified stock contribution retains quantity, value and capital recognition.
 bid:=pg_temp.fixture_brand(t,'Contribution fixture brand');
 insert into public.items(tenant_id,brand_id,size_kg,mouth_size) values(t,bid,12,'22mm') returning item_id into pid;
 perform public.adjust_inventory(jsonb_build_object('item_id',pid,'kind','capital','filled_quantity',2,'empty_quantity',1,'filled_unit_cost',2000,'empty_unit_cost',1000,'reason','Unified initial stock contribution','date',d),gen_random_uuid());
 perform pg_temp.assert((select filled_quantity=2 and empty_quantity=1 from public.items where item_id=pid),'Contributed stock quantity');
 perform pg_temp.assert((select sum(amount)=-5000 from public.accounting_lines where tenant_id=t and account='capital'),'Contributed stock posts capital');
 -- Exact cents when shares are recurring decimals.
 perform public.move_wallet_money(jsonb_build_object('action','transfer','wallet_id',src,'destination_id',dest,'amount',0.01,'reason','One paisa rounding'),gen_random_uuid());
 perform pg_temp.assert((select balance=1999.99 from public.wallets where wallet_id=src),'Paisa rounding keeps exact wallet total');
 perform public.move_wallet_money(jsonb_build_object('action','adjustment','wallet_id',src,'business','lpg','classification','capital','amount',123,'reason','Unified capital contribution'),gen_random_uuid());
 perform pg_temp.assert((select sum(amount)=-5123 from public.accounting_lines where tenant_id=t and account='capital'),'Contribution posts capital once');
 perform pg_temp.assert(not exists(select 1 from public.wallets w where w.tenant_id=t and balance<>(business_balances->>'lpg')::numeric+(business_balances->>'stove')::numeric+(business_balances->>'logistics')::numeric),'Every wallet reconciles');
 -- Reset only these disposable wallets using supported corrections.
 foreach b in array array['lpg','stove','logistics'] loop
  select -(business_balances->>b)::numeric into val from public.wallets where wallet_id=src;
  if val<>0 then perform public.move_wallet_money(jsonb_build_object('action','adjustment','wallet_id',src,'business',b,'amount',val,'reason','Reset fixture portion'),gen_random_uuid());end if;
 end loop;
 begin
  perform public.move_wallet_money(jsonb_build_object('action','transfer','wallet_id',src,'destination_id',dest,'amount',10,'reason','Zero denominator guard'),gen_random_uuid());
  raise exception 'FAIL: zero-total transfer accepted';
 exception when others then if sqlerrm not like 'A zero-total wallet%' then raise;end if;end;
 foreach b in array array['lpg','stove','logistics'] loop
  perform public.move_wallet_money(jsonb_build_object('action','adjustment','wallet_id',src,'business',b,'amount',case b when 'lpg' then 5000 else 2500 end,'reason','Positive fixture seed'),gen_random_uuid());
 end loop;
 k:=gen_random_uuid();
 perform public.move_wallet_money(jsonb_build_object('action','transfer','wallet_id',src,'destination_id',dest,'amount',8000,'reason','Positive proportional transfer'),k);
 perform pg_temp.assert((select business_balances='{"lpg":1000,"stove":500,"logistics":500}'::jsonb from public.wallets where wallet_id=src),'Positive 4000/2000/2000 distribution');
 perform pg_temp.assert((select count(*)=6 from public.wallet_transactions where operation_id=k),'Positive transfer has six entries');
 -- A transfer above the source total is permitted, preserving deficit semantics.
 perform public.move_wallet_money(jsonb_build_object('action','transfer','wallet_id',src,'destination_id',dest,'amount',4000,'reason','Overdraw proportional transfer'),gen_random_uuid());
 perform pg_temp.assert((select balance=-2000 from public.wallets where wallet_id=src),'Negative wallet total supported');
 perform public.move_wallet_money(jsonb_build_object('action','transfer','wallet_id',src,'destination_id',dest,'amount',1000,'reason','Negative total proportional transfer'),gen_random_uuid());
 perform pg_temp.assert((select balance=-3000 and business_balances='{"lpg":-1500,"stove":-750,"logistics":-750}'::jsonb from public.wallets where wallet_id=src),'Negative denominator distribution reconciles');

end $$;
select 'PASS: signed proportional transfers, six entries, exact retries, paisa rounding, advanced ownership and capital';
rollback;
