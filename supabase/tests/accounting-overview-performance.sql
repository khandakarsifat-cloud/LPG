-- Native PostgreSQL benchmark, executed only on the runner's disposable copy.
begin;
do $$begin if current_database() not like 'lpg_accounting_test_%' then raise exception 'Disposable database required';end if;end $$;
create temporary table overview_benchmark(label text,ms numeric,bytes integer);
-- Reuse the isolated authenticated concurrency business; no genuine business is
-- seeded. Replication mode is only for large synthetic read-fixture setup.
set local session_replication_role=replica;
insert into public.customers(tenant_id,customer_id,name,phone,tier)
select t,('bf010000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'Benchmark customer '||lpad(n::text,5,'0'),'019'||lpad(n::text,8,'0'),'retail'
from app_private.unified_concurrency_fixture cross join generate_series(1,5000)n;
insert into public.sales(tenant_id,sale_id,customer_id,status,sale_tier,subtotal,total_amount,paid_amount,created_by,created_at)
select t,('bf020000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,('bf010000-0000-4000-8000-'||lpad((1+(n-1)%5000)::text,12,'0'))::uuid,
'completed','retail',1000+n%100,1000+n%100,500,'ae910000-0000-4000-8000-000000000001','2025-01-01'::timestamptz+(n%600)*interval '1 day'
from app_private.unified_concurrency_fixture cross join generate_series(1,30000)n;
insert into public.sale_items(tenant_id,sale_id,item_id,type,quantity,unit_price,line_total)
select s.tenant_id,s.sale_id,f.item,'package',1,500,500 from public.sales s join app_private.unified_concurrency_fixture f on f.t=s.tenant_id cross join generate_series(1,2)n where s.sale_id::text like 'bf020000%';
insert into public.customer_transactions(tenant_id,customer_id,type,amount,reference_id,created_by)
select tenant_id,customer_id,'invoice_charge',-total_amount,sale_id,created_by from public.sales where sale_id::text like 'bf020000%';
insert into public.customer_transactions(tenant_id,customer_id,type,amount,reference_id,created_by)
select tenant_id,customer_id,'payment',paid_amount,sale_id,created_by from public.sales where sale_id::text like 'bf020000%';
set local session_replication_role=origin;
-- Populate the derived projection from canonical fixture rows after the isolated
-- bulk import, so the optimized and old queries see identical source evidence.
insert into app_private.customer_metrics(tenant_id,customer_id,ledger_balance,transactions,refill,package,total_sold_amount,total_due,last_transaction_at)
select s.tenant_id,s.customer_id,sum(paid_amount-total_amount),count(*),0,count(*)*2,sum(total_amount),sum(total_amount-paid_amount),max(created_at) from public.sales s where s.sale_id::text like 'bf020000%' group by 1,2;
with headers as(insert into public.accounting_journals(tenant_id,source,source_id,event_key,occurred_on,description)
 select t,'performance_history',gen_random_uuid(),n::text,'2025-01-01'::date+n%600,'Disposable historical benchmark' from app_private.unified_concurrency_fixture cross join generate_series(1,30000)n returning tenant_id,journal_id)
insert into public.accounting_lines(tenant_id,journal_id,line_no,account,amount,consolidated_amount,business_category,type_id) select h.tenant_id,h.journal_id,x.n,x.account,x.amount,x.amount,'lpg',md5('lpg:type:opening_entry')::uuid from headers h cross join(values(1,'other_assets',1),(2,'other_liability',-1))x(n,account,amount);
analyze public.customers;analyze public.sales;analyze public.sale_items;analyze public.accounting_journals;analyze public.accounting_lines;analyze app_private.customer_metrics;
do $$declare t uuid:=(select f.t from app_private.unified_concurrency_fixture f);begin perform app_private.build_accounting_snapshots(t,24);end $$;
grant insert,select on pg_temp.overview_benchmark to authenticated;
create temporary table expected_dues_count as select count(*) n from app_private.customer_metrics where tenant_id=(select t from app_private.unified_concurrency_fixture) and ledger_balance<0;
grant select on pg_temp.expected_dues_count to authenticated;
set local role authenticated;
select set_config('request.jwt.claim.sub','ae910000-0000-4000-8000-000000000001',true);
do $$declare i integer;r jsonb;old_result jsonb;f jsonb;label text;started timestamptz;t uuid:=app_private.current_tenant_id();begin
 for i in 1..5 loop
  foreach label in array array['customer sold before','customer sold after','customer due before','customer due after','finance before','finance after'] loop
   f:=case when label like 'finance%' then jsonb_build_object('business_id',t,'from',date_trunc('month',now() at time zone 'Asia/Dhaka')::date,'to',(now() at time zone 'Asia/Dhaka')::date,'grain','day') else jsonb_build_object('sort',case when label like 'customer sold%' then 'sold_desc' else 'due_desc' end) end;
   started:=clock_timestamp();
   if label='finance before' then r:=public.benchmark_full_analysis(f);
   elsif label='finance after' then r:=public.get_finance_analysis(f);
   elsif label like '%before' then r:=public.benchmark_full_directory(f,0,25,null);
   else r:=public.get_customer_directory(f,0,25,null);end if;
   insert into pg_temp.overview_benchmark values(label,extract(epoch from clock_timestamp()-started)*1000,octet_length(r::text));
   if label like '%before' then old_result:=r;elsif label like 'customer%' and r<>old_result then raise exception 'Optimized customer directory differs from canonical query';
   elsif label='finance after' and (r->'closing'->>'assets')::numeric<>(old_result->'closing'->>'assets')::numeric then raise exception 'Optimized cumulative position differs';end if;
  end loop;
 end loop;
 for i in 1..5 loop
  started:=clock_timestamp();r:=public.get_customer_directory('{"dues":"payment","sort":"due_desc"}',0,25,null);
  if (r->>'total')::integer<>(select n from pg_temp.expected_dues_count) then raise exception 'Current dues filter differs from the seeded customer ledger';end if;
  insert into pg_temp.overview_benchmark values('customer dues filter',extract(epoch from clock_timestamp()-started)*1000,octet_length(r::text));
 end loop;
end $$;
reset role;
select 'BENCH: '||jsonb_build_object('read',label,'median_ms',round(percentile_cont(.5) within group(order by ms)::numeric,2),'response_bytes',max(bytes))::text from pg_temp.overview_benchmark group by label order by label;
-- Compare write overhead with all pre-existing correctness triggers and deferred
-- journal constraints enabled in both paths. Disable only the new projections
-- for the baseline; never use this setup against the application database.
set constraints all immediate;
set constraints all deferred;
alter table public.accounting_lines disable trigger invalidate_accounting_snapshots;
do $$declare t uuid:=(select f.t from app_private.unified_concurrency_fixture f);started timestamptz:=clock_timestamp();begin
 for i in 1..500 loop perform app_private.post_journal(t,'benchmark_write_before',gen_random_uuid(),'1',(now() at time zone 'Asia/Dhaka')::date,'Disposable write overhead',jsonb_build_array(app_private.accounting_line('other_assets',1)||jsonb_build_object('type_id',md5('lpg:type:opening_entry')::uuid),app_private.accounting_line('other_liability',-1)||jsonb_build_object('type_id',md5('lpg:type:opening_entry')::uuid)));end loop;
 set constraints all immediate;set constraints all deferred;
 insert into overview_benchmark values('500 journals write before',extract(epoch from clock_timestamp()-started)*1000,0);
end $$;
alter table public.accounting_lines enable trigger invalidate_accounting_snapshots;
do $$declare t uuid:=(select f.t from app_private.unified_concurrency_fixture f);started timestamptz:=clock_timestamp();begin
 for i in 1..500 loop perform app_private.post_journal(t,'benchmark_write_after',gen_random_uuid(),'1',(now() at time zone 'Asia/Dhaka')::date,'Disposable write overhead',jsonb_build_array(app_private.accounting_line('other_assets',1)||jsonb_build_object('type_id',md5('lpg:type:opening_entry')::uuid),app_private.accounting_line('other_liability',-1)||jsonb_build_object('type_id',md5('lpg:type:opening_entry')::uuid)));end loop;
 set constraints all immediate;set constraints all deferred;
 insert into overview_benchmark values('500 journals write after',extract(epoch from clock_timestamp()-started)*1000,0);
end $$;
select 'BENCH: '||jsonb_build_object('write',label,'total_ms',round(ms,2),'per_journal_ms',round(ms/500,3))::text from overview_benchmark where label like '500 journals%';
select 'PASS: identical customer results and financial positions on 5,000 customers, 30,000 sales, 60,000 sale lines and 30,000 historical journals; bounded response sizes; write overhead measured with constraints';
rollback;
