-- Deterministic customer reporting/update acceptance; every fixture rolls back.
begin;
insert into public.tenants(tenant_id,business_name) values
 ('a7100000-0000-4000-8000-000000000001','Customer test A'),('a7100000-0000-4000-8000-000000000002','Customer test B');
insert into auth.users(id,email,is_anonymous) values
 ('a7200000-0000-4000-8000-000000000001','customer-a@example.invalid',false),('a7200000-0000-4000-8000-000000000002','customer-b@example.invalid',false);
insert into public.user_profiles(user_id,tenant_id,email) values
 ('a7200000-0000-4000-8000-000000000001','a7100000-0000-4000-8000-000000000001','customer-a@example.invalid'),
 ('a7200000-0000-4000-8000-000000000002','a7100000-0000-4000-8000-000000000002','customer-b@example.invalid');
insert into public.roles(tenant_id,role_id,name) values
 ('a7100000-0000-4000-8000-000000000001','a7300000-0000-4000-8000-000000000001','OWNER'),
 ('a7100000-0000-4000-8000-000000000002','a7300000-0000-4000-8000-000000000002','OWNER');
insert into public.role_permissions(tenant_id,role_id,permission_id)
select r.tenant_id,r.role_id,p.permission_id from public.roles r cross join public.permissions p where r.role_id in ('a7300000-0000-4000-8000-000000000001','a7300000-0000-4000-8000-000000000002');
insert into public.user_roles(tenant_id,user_id,role_id) values
 ('a7100000-0000-4000-8000-000000000001','a7200000-0000-4000-8000-000000000001','a7300000-0000-4000-8000-000000000001'),
 ('a7100000-0000-4000-8000-000000000002','a7200000-0000-4000-8000-000000000002','a7300000-0000-4000-8000-000000000002');

-- Bulk setup measures reads, not per-row foreign-key trigger overhead.
-- This switch is permitted only in a newly created disposable test engine.
do $$ begin
 if current_database() not like 'lpg_verify_%' and current_setting('lpg.disposable_replay',true) is distinct from 'on' then
  raise exception 'Customer performance fixtures require a disposable database';
 end if;
end $$;
set local session_replication_role=replica;
insert into public.customers(tenant_id,customer_id,name,phone,tier)
select t,('b7400000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'Perf Customer '||lpad(n::text,5,'0'),
 '019'||lpad(n::text,8,'0'),case when n%3=0 then 'wholesale' else 'retail' end
from (values('a7100000-0000-4000-8000-000000000001'::uuid),('a7100000-0000-4000-8000-000000000002'::uuid)) x(t) cross join generate_series(1,5000) n;
insert into public.items(tenant_id,item_id,brand,size_kg)
select t,('b7500000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'Perf product',12
from (values('a7100000-0000-4000-8000-000000000001'::uuid),('a7100000-0000-4000-8000-000000000002'::uuid)) x(t) cross join generate_series(1,2) n;
insert into public.sales(tenant_id,sale_id,customer_id,status,sale_tier,subtotal,total_amount,payment_tracking,paid_amount,created_by,created_at)
select t,('b7600000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 ('b7400000-0000-4000-8000-'||lpad((1+(n-1)%5000)::text,12,'0'))::uuid,'completed','retail',1000+n%100,1000+n%100,true,500,
 case when t='a7100000-0000-4000-8000-000000000001' then 'a7200000-0000-4000-8000-000000000001'::uuid else 'a7200000-0000-4000-8000-000000000002'::uuid end,
 '2026-01-01 00:00:00+06'::timestamptz+(n%90)*interval '1 day'
from (values('a7100000-0000-4000-8000-000000000001'::uuid),('a7100000-0000-4000-8000-000000000002'::uuid)) x(t) cross join generate_series(1,30000) n;
insert into public.sale_items(tenant_id,sale_id,item_id,type,quantity,unit_price,line_total)
select s.tenant_id,s.sale_id,
 ('b7500000-0000-4000-8000-'||lpad(case when line=2 or right(s.sale_id::text,1)::int%2<>0 then '2' else '1' end,12,'0'))::uuid,
 case line when 1 then 'refill' when 2 then 'package' else 'empty_return' end::public.sale_item_type,
 case when line=2 then 2 else 1 end,case when line=3 then 0 else 100 end,case when line=3 then 0 when line=2 then 200 else 100 end
from public.sales s cross join generate_series(1,3) line where s.sale_id::text like 'b7600000%';
set local session_replication_role=origin;
analyze public.customers; analyze public.sales; analyze public.sale_items;
set local role authenticated;
select set_config('request.jwt.claim.sub','a7200000-0000-4000-8000-000000000001',true);
create temporary table customer_timing(label text,ms numeric,bytes integer);
do $$ declare f jsonb; r jsonb; started timestamptz; i int; label text; begin
 for i in 1..5 loop
  for label,f in select * from (values
   ('name page','{"sort":"name_asc"}'::jsonb),
   ('sold page','{"sort":"sold_desc"}'::jsonb),
   ('due page','{"sort":"due_desc"}'::jsonb),
   ('last sale page','{"sort":"last_sale_asc"}'::jsonb),
   ('product/date/ranges deep page','{"search":"perf customer","from":"2026-01-01","to":"2026-03-31","item_ids":["b7500000-0000-4000-8000-000000000001"],"transactions_min":"6","refill_max":"6","package_max":"0","sort":"due_desc"}'::jsonb)
  ) x(label,f) loop
   started:=clock_timestamp();
   r:=public.get_customer_directory(f,case when label='product/date/ranges deep page' then 2400 else 0 end,25);
   insert into customer_timing values(label,extract(epoch from clock_timestamp()-started)*1000,octet_length(r::text));
   if (r->>'total')::int<>(case when label='product/date/ranges deep page' then 2500 else 5000 end) or jsonb_array_length(r->'entries')<>25 then raise exception 'Large directory count/page incorrect: %',label; end if;
   if label='product/date/ranges deep page' and exists(select 1 from jsonb_array_elements(r->'entries') c where (c->>'transactions')::int<>6 or (c->>'refill')::int<>6 or (c->>'package')::int<>0 or (c->>'total_due')::numeric<>(c->>'total_sold_amount')::numeric-3000) then raise exception 'Large scoped statistics mismatch'; end if;
  end loop;
 end loop;
end $$;
select label,round(percentile_cont(.5) within group(order by ms)::numeric,2) median_ms,max(bytes) response_bytes from customer_timing group by label order by label;
reset role;
-- Plans expose real table/index work; no EXPLAIN ANALYZE runs against genuine business data.
explain (analyze,buffers,summary)
with scoped_customers as materialized (select customer_id from public.customers where tenant_id='a7100000-0000-4000-8000-000000000001'), headers as materialized (
    select s.customer_id,s.sale_id,s.created_at,s.total_amount,
      case when s.payment_tracking then greatest(0,s.total_amount-s.paid_amount) else 0 end due
    from public.sales s join scoped_customers c on c.customer_id=s.customer_id
    where s.tenant_id='a7100000-0000-4000-8000-000000000001'::uuid and s.status='completed'
      and ('2026-01-01'::date is null or s.created_at >= ('2026-01-01'::date::timestamp at time zone 'Asia/Dhaka'))
      and ('2026-03-31'::date is null or s.created_at < (('2026-03-31'::date+1)::timestamp at time zone 'Asia/Dhaka'))
  ), quantities as (
    select si.sale_id,
      sum(si.quantity) filter(where si.type='refill') refill,
      sum(si.quantity) filter(where si.type='package') package
    from public.sale_items si join headers h on h.sale_id=si.sale_id
    where si.tenant_id='a7100000-0000-4000-8000-000000000001'::uuid and si.type in ('refill','package') and (false or si.item_id=any(array['b7500000-0000-4000-8000-000000000001'::uuid]))
    group by si.sale_id
  ), qualifying as (
    select h.*,coalesce(q.refill,0) refill,coalesce(q.package,0) package
    from headers h left join quantities q on q.sale_id=h.sale_id
    where false or q.sale_id is not null
  )
  select a.customer_id,count(*),sum(a.refill),sum(a.package),sum(a.total_amount),sum(a.due),max(a.created_at)
  from qualifying a group by a.customer_id;
select 'PASS: 10,000 customers, 60,000 sales, 180,000 lines across two tenants; monetary sorts, selected quantities, current dues, full filtered counts and deep pages';
rollback;
