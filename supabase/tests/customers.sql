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
set local role authenticated;
select set_config('request.jwt.claim.sub','a7200000-0000-4000-8000-000000000001',true);
do $$ declare r jsonb; c jsonb; begin
 r:=public.get_customer_directory('{}',88,2);
 if (r->>'total')::int<>90 or jsonb_array_length(r->'entries')<>2 then raise exception 'Directory was truncated or paged before filtering'; end if;
 r:=public.get_customer_directory('{"search":"mirpur alpha, uttara"}');
 if (r->>'total')::int<>2 then raise exception 'Comma OR failed'; end if;
 if (public.get_customer_directory('{"search":"mirpur uttara"}')->>'total')::int<>0 then raise exception 'Whitespace AND failed'; end if;
 if (public.get_customer_directory('{"search":" ,  , "}')->>'total')::int<>90 then raise exception 'Empty OR groups failed'; end if;
 if (public.get_customer_directory('{"search":"08801700000001"}')->>'total')::int<>1 then raise exception 'Phone normalization failed'; end if;
 r:=public.get_customer_directory('{}',0,1,'a7400000-0000-4000-8000-000000000001'); c:=r->'entries'->0;
 if (c->>'transactions')::int<>3 or (c->>'refill')::int<>17 or (c->>'package')::int<>2 or (c->>'total_sold')::int<>19 then raise exception 'Sale counts, units, returns or tenant isolation failed'; end if;
 r:=public.get_customer_directory('{"from":"2026-10-02","to":"2026-10-02"}',0,1,'a7400000-0000-4000-8000-000000000001');
 if (r->'entries'->0->>'total_sold')::int<>12 or (r->'entries'->0->>'transactions')::int<>1 then raise exception 'Dhaka inclusive date boundaries failed'; end if;
 r:=public.get_customer_directory('{"item_ids":["a7500000-0000-4000-8000-000000000001"],"transactions_min":"2","transactions_max":"2","refill_min":"14","package_min":"2"}');
 if (r->>'total')::int<>1 or (r->'entries'->0->>'total_sold')::int<>16 then raise exception 'Combined product/range filters failed'; end if;
 if (public.get_customer_directory('{"item_ids":[]}')->>'total')::int<>0 then raise exception 'Empty product selection failed'; end if;
 if (public.get_customer_directory('{"tier":"wholesale"}')->>'total')::int<>2 then raise exception 'Tier filter failed'; end if;
 if public.get_customer_directory('{"sort":"sold_desc"}',0,1)->'entries'->0->>'customer_id'<>'a7400000-0000-4000-8000-000000000001' then raise exception 'Quantity sort failed'; end if;
 r:=public.get_customer_overview();
 if (r->>'wholesale')::int<>2 or (r->>'retail')::int<>88 or (r->>'inactive_retail')::int<>2 or (r->>'inactive_wholesale')::int<>0 then raise exception 'Global or inactive overview failed: %',r; end if;
 if (r->>'new_wholesale')::int<>1 or (r->>'new_retail')::int<>86 then raise exception 'Saturday week/new customer count failed'; end if;
 r:=public.get_customer_transactions('a7400000-0000-4000-8000-000000000001','{}',1,1);
 if (r->>'total')::int<>3 or jsonb_array_length(r->'entries')<>1 then raise exception 'Transaction paging failed'; end if;
 r:=public.get_customer_transactions('a7400000-0000-4000-8000-000000000001','{"item_ids":["a7500000-0000-4000-8000-000000000001"],"from":"2026-10-02","to":"2026-10-02"}',0,1);
 if (r->>'total')::int<>1 or (r->'entries'->0->>'refill')::int<>10 or (r->'entries'->0->>'package')::int<>2 then raise exception 'Paged history changed product-scoped quantities or dates'; end if;
 if (public.get_customer_transactions('a7400000-0000-4000-8000-000000000001','{"item_ids":[]}')->>'total')::int<>0 then raise exception 'History empty product selection failed'; end if;
 if (public.get_customer_transactions('a7400000-0000-4000-8000-000000000001','{"search":"no matching product"}')->>'total')::int<>0 then raise exception 'History search ignored'; end if;
 r:=public.get_customer_directory('{"transactions_min":"0"}',0,6);
 if r is distinct from public.get_customer_directory('{}',0,6) then raise exception 'Paged directory differs from full reporting path'; end if;
 if public.get_customer_directory('{"transactions_min":"0","sort":"name_desc"}',0,6) is distinct from public.get_customer_directory('{"sort":"name_desc"}',0,6) then raise exception 'Descending customer page changed'; end if;
 r:=public.get_customer_filter_products();
 if jsonb_array_length(r->'items')<>2 or (r->'items'->0)?'filled_quantity' then raise exception 'Catalog identity boundary failed'; end if;
 begin perform public.get_customer_directory('{"transactions_min":"-1"}'); raise exception 'Negative range accepted'; exception when raise_exception then if sqlerrm<>'Invalid activity range' then raise; end if; end;
 begin perform public.get_customer_directory('{}',0,null); raise exception 'Unbounded customer page accepted'; exception when raise_exception then if sqlerrm<>'Invalid customer page' then raise; end if; end;
 begin perform public.get_customer_directory('{"from":"2026-10-03","to":"2026-10-02"}'); raise exception 'Reversed dates accepted'; exception when raise_exception then if sqlerrm<>'Start date must not follow end date' then raise; end if; end;
 begin perform public.update_customer_details('a7400000-0000-4000-8000-000000000099','{"tier":"retail","phone":"01700000999"}'); raise exception 'Foreign customer updated'; exception when raise_exception then if sqlerrm<>'Customer not found' then raise; end if; end;
 begin perform public.update_customer_details('a7400000-0000-4000-8000-000000000001','{"tier":"retail","phone":"01700000002"}'); raise exception 'Duplicate phone accepted'; exception when raise_exception then if sqlerrm<>'A customer with this phone number already exists' then raise; end if; end;
 r:=public.update_customer_details('a7400000-0000-4000-8000-000000000001','{"tier":"retail","phone":"01700000999","name":" Updated name ","address":" Mirpur "}');
 if r->>'name'<>'Updated name' or r->>'tier'<>'retail' then raise exception 'Customer update failed'; end if;
 if exists(select 1 from public.sales where sale_tier<>'wholesale' and customer_id='a7400000-0000-4000-8000-000000000001') then raise exception 'Customer edit rewrote sale tier'; end if;
end $$;
reset role;
do $$ begin
 if (select phone from public.customers where tenant_id='a7100000-0000-4000-8000-000000000002' and customer_id='a7400000-0000-4000-8000-000000000001')<>'01700000001' then raise exception 'Reused customer ID crossed tenant'; end if;
 if has_function_privilege('anon','public.get_customer_overview()','execute') or has_function_privilege('authenticated','app_private.customer_activity_rows(uuid,date,date,uuid[])','execute') then raise exception 'Function grants are too broad'; end if;
end $$;
delete from public.role_permissions where role_id='a7300000-0000-4000-8000-000000000001' and permission_id<>'customers:view';
set local role authenticated;
do $$ begin
 perform public.get_customer_directory();
 perform public.get_customer_filter_products();
 begin perform public.get_customer_transactions('a7400000-0000-4000-8000-000000000001'); raise exception 'Sales permission bypass'; exception when insufficient_privilege then null; end;
 begin perform public.update_customer_details('a7400000-0000-4000-8000-000000000001','{"tier":"retail","phone":"01700000999"}'); raise exception 'Customer manage permission bypass'; exception when insufficient_privilege then null; end;
end $$;
reset role;
update public.user_profiles set is_active=false where user_id='a7200000-0000-4000-8000-000000000001';
set local role authenticated;
do $$ begin begin perform public.get_customer_overview(); raise exception 'Inactive user admitted'; exception when insufficient_privilege then null; end; end $$;
reset role;
select 'PASS: customer aggregates, complete pagination, AND/OR/phone search, date/product/range filters, edit integrity, tenant and capability isolation';
rollback;
