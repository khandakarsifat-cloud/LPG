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
insert into public.customers(tenant_id,customer_id,name,phone,tier,shop_name,address,created_at)
select 'a7100000-0000-4000-8000-000000000001',('a7400000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 case n when 1 then 'Shahidul Islam' when 2 then 'Rahman' else 'Customer '||n end,'017'||lpad(n::text,8,'0'),
 case when n in(1,4) then 'wholesale' else 'retail' end,case when n=1 then 'Mirpur Alpha' when n=4 then 'New shop' else null end,
 case n when 1 then 'Mirpur Dhaka' when 2 then 'Uttara Dhaka' else 'Dhaka' end,
 case when n<=3 then now()-interval '4 months' else now() end from generate_series(1,90) n;
insert into public.customers(tenant_id,customer_id,name,phone,tier) values
 ('a7100000-0000-4000-8000-000000000002','a7400000-0000-4000-8000-000000000001','Other tenant','01700000001','wholesale'),
 ('a7100000-0000-4000-8000-000000000002','a7400000-0000-4000-8000-000000000099','Foreign only','01700000099','retail');
insert into public.items(tenant_id,item_id,brand,size_kg,filled_quantity,empty_quantity)
select t,('a7500000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'Test brand',12,100,100
from (values('a7100000-0000-4000-8000-000000000001'::uuid),('a7100000-0000-4000-8000-000000000002'::uuid)) x(t) cross join generate_series(1,2) n;
insert into public.sales(tenant_id,sale_id,customer_id,status,sale_tier,subtotal,total_amount,created_by,created_at)
select t,('a7600000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'a7400000-0000-4000-8000-000000000001','completed','wholesale',1000,1000,
 case when t='a7100000-0000-4000-8000-000000000001' then 'a7200000-0000-4000-8000-000000000001'::uuid else 'a7200000-0000-4000-8000-000000000002'::uuid end,
 case n when 1 then '2026-10-01 18:00:00+00'::timestamptz when 2 then '2026-10-01 17:59:59+00'::timestamptz else now() end
from (values('a7100000-0000-4000-8000-000000000001'::uuid),('a7100000-0000-4000-8000-000000000002'::uuid)) x(t) cross join generate_series(1,3) n;
insert into public.sales(tenant_id,sale_id,customer_id,status,sale_tier,subtotal,total_amount,created_by,created_at) values
 ('a7100000-0000-4000-8000-000000000001','a7600000-0000-4000-8000-000000000004','a7400000-0000-4000-8000-000000000002','completed','retail',1000,1000,'a7200000-0000-4000-8000-000000000001',now()-interval '3 months');
insert into public.sale_items(tenant_id,sale_id,item_id,type,quantity,unit_price,line_total)
select t,('a7600000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 ('a7500000-0000-4000-8000-'||lpad(case when n=3 then '2' else '1' end,12,'0'))::uuid,'refill',case n when 1 then 10 when 2 then 4 else 3 end,100,1000
from (values('a7100000-0000-4000-8000-000000000001'::uuid),('a7100000-0000-4000-8000-000000000002'::uuid)) x(t) cross join generate_series(1,3) n;
insert into public.sale_items(tenant_id,sale_id,item_id,type,quantity,unit_price,line_total) values
 ('a7100000-0000-4000-8000-000000000001','a7600000-0000-4000-8000-000000000001','a7500000-0000-4000-8000-000000000001','package',2,100,200),
 ('a7100000-0000-4000-8000-000000000001','a7600000-0000-4000-8000-000000000001','a7500000-0000-4000-8000-000000000001','empty_return',10,0,0);

insert into public.gas_plants(tenant_id,plant_id,plant_name) select tenant_id,'a7700000-0000-4000-8000-000000000001','Mirpur plant' from public.tenants where tenant_id in ('a7100000-0000-4000-8000-000000000001','a7100000-0000-4000-8000-000000000002');
insert into public.purchases(tenant_id,purchase_id,plant_id,status,payment_status,company_payable,total_cost,created_at,notes)
select 'a7100000-0000-4000-8000-000000000001',('a7800000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'a7700000-0000-4000-8000-000000000001',
 case when n=2 then 'in_transit'::public.purchase_status else 'created'::public.purchase_status end,'unpaid',n*100,n*100,'2026-10-01 18:00:00+00'::timestamptz,'Order '||n from generate_series(1,25) n;
insert into public.purchases(tenant_id,purchase_id,plant_id,status,total_cost) values ('a7100000-0000-4000-8000-000000000002','a7800000-0000-4000-8000-000000000001','a7700000-0000-4000-8000-000000000001','created',9999);
insert into public.purchase_items(tenant_id,purchase_id,item_id,type,quantity,unit_price,line_total,billed_quantity)
select tenant_id,purchase_id,'a7500000-0000-4000-8000-000000000001','refill',2,100,200,2 from public.purchases where tenant_id='a7100000-0000-4000-8000-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.sub','a7200000-0000-4000-8000-000000000001',true);
do $$ declare r jsonb; expected jsonb; begin
 r:=public.get_purchase_directory('{}',20,6);
 if (r->>'total')::int<>25 or jsonb_array_length(r->'entries')<>5 then raise exception 'Purchase page/count failed: %',r; end if;
 select jsonb_agg(legacy.row order by legacy.row->>'purchase_id') into expected from public.list_purchases() legacy(row) where legacy.row->>'purchase_id' in (select value->>'purchase_id' from jsonb_array_elements(public.get_purchase_directory('{}',0,6)->'entries'));
 select jsonb_agg(value order by value->>'purchase_id') into r from jsonb_array_elements(public.get_purchase_directory('{}',0,6)->'entries');
 if r is distinct from expected then raise exception 'Paged purchase details differ from legacy contract'; end if;
 r:=public.get_purchase_directory('{"search":"mirpur 12kg refill, nonexistent","status":"in_transit","from":"2026-10-02","to":"2026-10-02"}',0,6);
 if (r->>'total')::int<>1 then raise exception 'Purchase combined AND/OR/status/date/product search failed: %',r; end if;
 if (public.get_purchase_directory('{"search":" , , "}')->>'total')::int<>25 then raise exception 'Empty purchase OR groups failed'; end if;
 if (public.get_purchase_directory('{"from":"2026-10-01","to":"2026-10-01"}')->>'total')::int<>0 then raise exception 'Purchase Dhaka date boundary failed'; end if;
 if public.get_purchase_directory('{"sort":"amount_desc"}',0,1)->'entries'->0->>'total_cost'<>'2500.00' then raise exception 'Purchase amount sort failed'; end if;
 if (public.get_purchase_directory('{"search":"%"}')->>'total')::int<>0 then raise exception 'Purchase search treats wildcard as literal'; end if;
 r:=public.get_purchase_overview();
 if (r->>'total')::int<>25 or (r->>'created')::int<>24 or (r->>'unpaid')::int<>1 or (r->>'company_payable')::numeric<>200 then raise exception 'Purchase overview failed: %',r; end if;
 if (select count(*) from public.get_purchases_by_ids(array['a7800000-0000-4000-8000-000000000001'::uuid,'a7800000-0000-4000-8000-000000000099'::uuid]))<>1 then raise exception 'Exact purchase selection or tenant isolation failed'; end if;
 begin perform public.get_purchase_directory('{}',0,101); raise exception 'Unbounded purchase page accepted'; exception when raise_exception then if sqlerrm<>'Invalid purchase page' then raise; end if; end;
 begin perform public.get_purchases_by_ids(null); raise exception 'Unbounded purchase IDs accepted'; exception when raise_exception then if sqlerrm<>'Invalid purchase selection' then raise; end if; end;
end $$;
reset role;
do $$ begin
 if has_function_privilege('anon','public.get_purchase_directory(jsonb,integer,integer)','execute') or has_function_privilege('authenticated','app_private.purchase_rows(uuid,uuid[])','execute') then raise exception 'Reporting function grants too broad'; end if;
end $$;
delete from public.role_permissions where role_id='a7300000-0000-4000-8000-000000000001' and permission_id<>'customers:view';
set local role authenticated;
do $$ begin
 begin perform public.get_purchase_directory(); raise exception 'Purchase view permission bypass'; exception when insufficient_privilege then null; end;
 begin perform public.get_purchase_overview(); raise exception 'Purchase overview permission bypass'; exception when insufficient_privilege then null; end;
 begin perform public.get_purchases_by_ids('{}'); raise exception 'Purchase ID permission bypass'; exception when insufficient_privilege then null; end;
end $$;
reset role;
select 'PASS: backend purchase pagination, complete overview, bounded details, filter/search/date parity and tenant/capability isolation';
rollback;
