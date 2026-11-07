-- Runs only in the disposable clone after finance-visibility-performance.sql.
select pg_temp.fixture_identity('fa050000-0000-4000-8000-000000000001');
do $$declare t uuid:=app_private.current_tenant_id();st uuid;a uuid;b uuid;s uuid;r jsonb;sid uuid;d date:=(now() at time zone 'Asia/Dhaka')::date;begin
 select type_id into st from public.stove_product_types where tenant_id=t limit 1;
 a:=(public.save_stove_product(jsonb_build_object('name','Margin fixture A','type_id',st),gen_random_uuid())->>'item_id')::uuid;
 b:=(public.save_stove_product(jsonb_build_object('name','Margin fixture B','type_id',st),gen_random_uuid())->>'item_id')::uuid;
 perform public.adjust_inventory(jsonb_build_object('item_id',a,'kind','capital','unit_quantity',4,'unit_unit_cost',50,'date',d-2,'reason','Actual stove cost A'),gen_random_uuid());
 perform public.adjust_inventory(jsonb_build_object('item_id',b,'kind','capital','unit_quantity',4,'unit_unit_cost',120,'date',d-2,'reason','Actual stove cost B'),gen_random_uuid());
 insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price) values(t,a,'retail','package',100),(t,b,'retail','package',200);
 r:=public.create_pos_sale('01790000058','Margin customer',null,null,'retail',1.01,0,'Exact discount allocation',jsonb_build_array(jsonb_build_object('item_id',a,'type','package','quantity',1,'unit_price',100),jsonb_build_object('item_id',b,'type','package','quantity',1,'unit_price',200)),p_request_id=>gen_random_uuid(),p_payments=>'[]',p_sold_on=>d-1);sid:=(r->>'sale_id')::uuid;
 r:=public.get_product_performance('stove',d-1,d-1);
 perform pg_temp.assert((r->'totals'->>'revenue')::numeric=298.99 and (r->'totals'->>'cogs')::numeric=170 and (r->'totals'->>'margin')::numeric=128.99 and (r->'totals'->>'average_margin')::numeric=64.50,'Actual FIFO cost, exact allocated discount, total and average margin');
 perform pg_temp.assert((r->'totals'->>'missing_units')::integer=0,'Complete original FIFO evidence is covered');
 perform pg_temp.assert((select sum(amount)=170 from public.accounting_lines where tenant_id=t and account='cogs' and business_category='stove'),'Stove report FIFO cost reconciles with canonical COGS');
 begin
  delete from app_private.fifo_consumptions where tenant_id=t and movement_id in(select movement_id from public.inventory_movements where tenant_id=t and reference_id=sid and item_id=a);
  r:=public.get_product_performance('stove',d-1,d-1);
  perform pg_temp.assert((r->'totals'->>'missing_units')::integer=1 and r->'totals'->'margin'='null'::jsonb,'Missing evidence does not silently create zero-cost margins');
  raise sqlstate 'P4220';
 exception when sqlstate 'P4220' then null;end;
 perform public.reverse_sale(sid,'Margin reversal in its own accounting period','CANCEL',gen_random_uuid());
 r:=public.get_product_performance('stove',d-1,d-1);
 perform pg_temp.assert((r->'totals'->>'margin')::numeric=128.99,'Later cancellation does not erase the original reporting period');
 r:=public.get_product_performance('stove',d,d);
 perform pg_temp.assert((r->'totals'->>'sold')::integer=-2 and (r->'totals'->>'revenue')::numeric=-298.99 and (r->'totals'->>'cogs')::numeric=-170 and r->'totals'->'average_margin'='null'::jsonb,'Return reverses original price, discount and actual cost on its own date');
 r:=public.get_product_performance('stove');
 perform pg_temp.assert((r->'totals'->>'sold')::integer=0 and (r->'totals'->>'margin')::numeric=0,'All-time source financial totals reconcile after reversal');
 insert into visibility_fixture values('margin_item',a);
end$$;

update app_private.user_permission_sets set permissions=array['pos:sell','finance:view','finance:manage','finance:capital'] where user_id='fa050000-0000-4000-8000-000000000002';
select pg_temp.fixture_identity('fa050000-0000-4000-8000-000000000002');
set local role authenticated;
do $$declare i uuid:=(select value from visibility_fixture where key='margin_item');cash uuid:=(select value from visibility_fixture where key='cash');begin
 perform public.move_wallet_money(jsonb_build_object('action','adjustment','classification','capital','wallet_id',cash,'business','stove','amount',10,'date',current_date,'reason','Delegated capital only'),gen_random_uuid());
 begin perform public.move_wallet_money(jsonb_build_object('action','adjustment','classification','correction','wallet_id',cash,'business','stove','amount',10,'date',current_date,'reason','Denied correction'),gen_random_uuid());raise exception 'Capital grant authorized correction';exception when insufficient_privilege then null;end;
 begin perform public.accounting_operation(jsonb_build_object('action','opening_entry','amount',10,'date',current_date,'description','Denied opening','account','supplier_payable'),gen_random_uuid());raise exception 'Capital grant authorized opening';exception when insufficient_privilege then null;end;
 begin perform public.accounting_operation(jsonb_build_object('action','loan_create','amount',10,'date',current_date,'description','Denied loan'),gen_random_uuid());raise exception 'Capital grant authorized loan';exception when insufficient_privilege then null;end;
 begin perform public.create_pos_sale('01790000059','Denied discount',null,null,'retail',1,0,'Denied discount',jsonb_build_array(jsonb_build_object('item_id',i,'type','package','quantity',1,'unit_price',100)),p_request_id=>gen_random_uuid(),p_payments=>'[]');raise exception 'POS grant authorized discount';exception when insufficient_privilege then null;end;
 begin perform public.get_permission_catalog();raise exception 'Staff granted access administration';exception when insufficient_privilege then null;end;
 begin perform app_private.business_deletion_preview((select value from visibility_fixture where key='tenant'));raise exception 'Authenticated caller reached root deletion';exception when insufficient_privilege then null;end;
 begin perform set_config('lpg.business_deletion','fa050000-0000-4000-8000-000000000099',true);delete from public.financial_entries;raise exception 'Client GUC bypassed financial immutability';exception when insufficient_privilege then null;end;
end$$;
reset role;

-- Exercise real child-first removal of the complete visibility fixture, with
-- all constraints/source immutability guards enabled and another tenant intact.
insert into auth.users(id,email,is_anonymous) values('fa050000-0000-4000-8000-000000000003','deletion-admin@example.invalid',false),('fa050000-0000-4000-8000-000000000004','deletion-preserved@example.invalid',false);
insert into app_private.platform_superadmins(user_id,is_active) values('fa050000-0000-4000-8000-000000000003',true);
select pg_temp.fixture_identity('fa050000-0000-4000-8000-000000000004');
insert into visibility_fixture select 'preserved_tenant',(pg_temp.fixture_business('Deletion control business','Preserved owner')->>'tenant_id')::uuid;
create temp table preserved_other_rows as select tenant_id,business_name,status,created_at from public.tenants where tenant_id=(select value from visibility_fixture where key='preserved_tenant');
do $$declare t uuid:=(select value from visibility_fixture where key='tenant');j uuid:='fa050000-0000-4000-8000-000000000099';r jsonb;begin
 r:=app_private.prepare_business_deletion(t,j,'fa050000-0000-4000-8000-000000000003','Finance visibility disposable acceptance');
 perform set_config('lpg.business_deletion','',true);
 perform pg_temp.assert((select status='suspended' from public.tenants where tenant_id=t),'Business fenced before backup');
 begin update public.tenants set status='active' where tenant_id=t;raise exception 'Deletion fence was removed';exception when insufficient_privilege then null;end;
 begin perform app_private.purge_business_data(j);raise exception 'Missing backup allowed deletion';exception when others then if sqlerrm='Missing backup allowed deletion' then raise;end if;end;
 -- Only this rolled-back clone test supplies a simulated verified point. The
 -- deployed root worker obtains one from the real cloud+restore pipeline.
 update app_private.business_deletions set status='backed_up',backup_id=repeat('a',64) where job_id=j;
 r:=app_private.purge_business_data(j);
 perform pg_temp.assert(r->>'status'='data_removed','Complete business dependency graph purged with all FKs active');
 perform pg_temp.assert(not exists(select 1 from public.tenants where tenant_id=t),'Target business removed');
 r:=app_private.purge_business_data(j);perform pg_temp.assert(r->>'status'='data_removed','Database removal retry is idempotent');
 perform pg_temp.assert(not exists((select tenant_id,business_name,status,created_at from public.tenants where tenant_id=(select value from visibility_fixture where key='preserved_tenant')) except select * from preserved_other_rows),'Other business preserved');
 perform pg_temp.assert(exists(select 1 from app_private.platform_superadmins where user_id='fa050000-0000-4000-8000-000000000003'),'Platform administrator preserved');
end$$;
