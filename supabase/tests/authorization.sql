-- Run with psql -v ON_ERROR_STOP=1 after the authorization migration.
-- Real roles, workflow calls and adversarial fixtures; every row rolls back.
begin;

create temporary table authorization_context(tenant_a uuid, tenant_b uuid, purchase_id uuid, employee_id uuid, sale_id uuid);
grant select, insert, update on authorization_context to authenticated;
create temporary table authorization_catalog as select permission_id from public.permissions;
grant select on authorization_catalog to authenticated;
create function pg_temp.assert_true(ok boolean, message text) returns void language plpgsql as $$
begin if ok is not true then raise exception 'FAIL: %', message; end if; end $$;
create function pg_temp.expect_denied(statement text) returns void language plpgsql as $$
begin
  begin execute statement;
  exception when insufficient_privilege then return;
  end;
  raise exception 'FAIL: unauthorized statement succeeded: %', statement;
end $$;
grant execute on function pg_temp.assert_true(boolean,text), pg_temp.expect_denied(text) to authenticated, anon;

insert into auth.users(id, email, is_anonymous) values
 ('a2222222-2222-4222-8222-222222222222','rls-owner-a@example.invalid',false),
 ('b2222222-2222-4222-8222-222222222222','rls-owner-b@example.invalid',false),
 ('a2222222-2222-4222-8222-222222222223','rls-manager@example.invalid',false),
 ('a2222222-2222-4222-8222-222222222224','rls-salesman@example.invalid',false),
 ('a2222222-2222-4222-8222-222222222225','rls-unassigned@example.invalid',false);

set local role authenticated;
select set_config('request.jwt.claim.sub','a2222222-2222-4222-8222-222222222222',true);
-- Bootstrap must work before membership/permissions exist.
insert into authorization_context(tenant_a)
select (public.setup_business('RLS fixture A','Owner A')->>'tenant_id')::uuid;
select pg_temp.expect_denied($s$select public.setup_business('Hijacked','Owner')$s$);
select pg_temp.assert_true(cardinality(public.get_my_permissions()) = (select count(*) from authorization_catalog), 'OWNER catalog mapping');
select set_config('request.jwt.claim.sub','b2222222-2222-4222-8222-222222222222',true);
update authorization_context set tenant_b = (public.setup_business('RLS fixture B','Owner B')->>'tenant_id')::uuid;
reset role;

insert into public.user_profiles(user_id,tenant_id,email)
select u.id, c.tenant_a, u.email from auth.users u cross join authorization_context c
where u.id in ('a2222222-2222-4222-8222-222222222223','a2222222-2222-4222-8222-222222222224','a2222222-2222-4222-8222-222222222225');
insert into public.user_roles(tenant_id,user_id,role_id)
select c.tenant_a, u.id, r.role_id
from authorization_context c cross join auth.users u join public.roles r
on r.tenant_id = c.tenant_a and r.name = case
 when u.id = 'a2222222-2222-4222-8222-222222222223' then 'MANAGER' else 'SALESMAN' end
where u.id in ('a2222222-2222-4222-8222-222222222223','a2222222-2222-4222-8222-222222222224');
-- B reuses A's cashier role UUID with full permissions. An unqualified RBAC
-- join would incorrectly promote A's cashier to B's complete capability set.
insert into public.roles(tenant_id,role_id,name)
select c.tenant_b,r.role_id,'REUSED-ROLE'
from authorization_context c join public.roles r on r.tenant_id=c.tenant_a and r.name='SALESMAN';
insert into public.role_permissions(tenant_id,role_id,permission_id)
select r.tenant_id,r.role_id,p.permission_id from public.roles r cross join public.permissions p
where r.tenant_id=(select tenant_b from authorization_context) and r.name='REUSED-ROLE';
insert into public.user_roles(tenant_id,user_id,role_id)
select r.tenant_id,'b2222222-2222-4222-8222-222222222222',r.role_id from public.roles r
where r.tenant_id=(select tenant_b from authorization_context) and r.name='REUSED-ROLE';
-- Reused UUIDs deliberately exercise composite ownership, not UUID uniqueness.
select set_config('request.jwt.claim.sub','',true);
insert into public.lpg_brands(tenant_id,brand_id,brand_name)
select t, 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', label from authorization_context c
cross join lateral (values(c.tenant_a,'Brand A'),(c.tenant_b,'Brand B')) x(t,label);
insert into public.items(tenant_id,item_id,brand_id,brand,size_kg,filled_quantity,empty_quantity)
select t, 'cccccccc-cccc-4ccc-8ccc-cccccccccccc','cccccccc-cccc-4ccc-8ccc-cccccccccccc',label,12,40,40
from authorization_context c cross join lateral (values(c.tenant_a,'Item A'),(c.tenant_b,'Item B')) x(t,label);
insert into public.customers(tenant_id,customer_id,name,phone,tier)
select t, 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',label,'01700000000','retail'
from authorization_context c cross join lateral (values(c.tenant_a,'Customer A'),(c.tenant_b,'Customer B')) x(t,label);
insert into public.trucks(tenant_id,truck_id,name,serial_no,capacity,size)
select t, 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',label,label,100,'medium'
from authorization_context c cross join lateral (values(c.tenant_a,'Truck A'),(c.tenant_b,'Truck B')) x(t,label);
insert into public.gas_plants(tenant_id,plant_id,brand_id,plant_name)
select t, 'cccccccc-cccc-4ccc-8ccc-cccccccccccc','cccccccc-cccc-4ccc-8ccc-cccccccccccc',label
from authorization_context c cross join lateral (values(c.tenant_a,'Plant A'),(c.tenant_b,'Plant B')) x(t,label);
insert into public.purchases(tenant_id,purchase_id,truck_id,plant_id,status)
select t,'cccccccc-cccc-4ccc-8ccc-cccccccccccc','cccccccc-cccc-4ccc-8ccc-cccccccccccc','cccccccc-cccc-4ccc-8ccc-cccccccccccc','in_transit'
from authorization_context c cross join lateral (values(c.tenant_a),(c.tenant_b)) x(t);
insert into public.purchase_items(tenant_id,purchase_item_id,purchase_id,item_id,type,quantity,unit_price,line_total)
select t,'cccccccc-cccc-4ccc-8ccc-cccccccccccc','cccccccc-cccc-4ccc-8ccc-cccccccccccc','cccccccc-cccc-4ccc-8ccc-cccccccccccc','refill',q,100,q*100
from authorization_context c cross join lateral (values(c.tenant_a,1),(c.tenant_b,7)) x(t,q);
insert into public.transits(tenant_id,transit_id,truck_id,purchase_id,status)
select t,'cccccccc-cccc-4ccc-8ccc-cccccccccccc','cccccccc-cccc-4ccc-8ccc-cccccccccccc','cccccccc-cccc-4ccc-8ccc-cccccccccccc','active'
from authorization_context c cross join lateral (values(c.tenant_a),(c.tenant_b)) x(t);
insert into public.wallets(tenant_id,wallet_id,type,balance)
select t,'cccccccc-cccc-4ccc-8ccc-cccccccccccc','logistics',10000
from authorization_context c cross join lateral (values(c.tenant_a),(c.tenant_b)) x(t);
insert into public.wallets(tenant_id,wallet_id,type,balance)
select t,'dddddddd-dddd-4ddd-8ddd-dddddddddddd','dealership',10000
from authorization_context c cross join lateral (values(c.tenant_a),(c.tenant_b)) x(t);
insert into public.price_books(tenant_id,item_id,customer_tier,price)
select t,'cccccccc-cccc-4ccc-8ccc-cccccccccccc','retail',1200
from authorization_context c cross join lateral (values(c.tenant_a),(c.tenant_b)) x(t);
-- Force the next generated sale UUID to collide with a preexisting B sale.
-- The default change is test-only and rolls back with these fixtures.
insert into public.sales(tenant_id,sale_id,customer_id,status,subtotal,total_amount)
select tenant_b,'cccccccc-cccc-4ccc-8ccc-cccccccccccc','cccccccc-cccc-4ccc-8ccc-cccccccccccc','completed',8888,8888
from authorization_context;
insert into public.sale_items(tenant_id,sale_item_id,sale_id,item_id,type,quantity,unit_price,line_total)
select tenant_b,'cccccccc-cccc-4ccc-8ccc-cccccccccccc','cccccccc-cccc-4ccc-8ccc-cccccccccccc',
 'cccccccc-cccc-4ccc-8ccc-cccccccccccc','package',7,100,700 from authorization_context;
alter table public.sales alter column sale_id set default 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'::uuid;
-- Whole B tenant snapshot: ALL routines below must leave it untouched.
create temporary table authorization_other_snapshot as
select name, row_data from authorization_context c cross join lateral (
 select 'items' name, to_jsonb(i) row_data from public.items i where i.tenant_id=c.tenant_b
 union all select 'wallets',to_jsonb(w) from public.wallets w where w.tenant_id=c.tenant_b
 union all select 'transits',to_jsonb(t) from public.transits t where t.tenant_id=c.tenant_b
 union all select 'trucks',to_jsonb(t) from public.trucks t where t.tenant_id=c.tenant_b
 union all select 'purchases',to_jsonb(p) from public.purchases p where p.tenant_id=c.tenant_b
 union all select 'purchase_items',to_jsonb(p) from public.purchase_items p where p.tenant_id=c.tenant_b
 union all select 'sales',to_jsonb(s) from public.sales s where s.tenant_id=c.tenant_b
 union all select 'sale_items',to_jsonb(s) from public.sale_items s where s.tenant_id=c.tenant_b
) x;

set local role authenticated;
select set_config('request.jwt.claim.sub','a2222222-2222-4222-8222-222222222222',true);
select pg_temp.assert_true((select count(*) from public.items where item_id='cccccccc-cccc-4ccc-8ccc-cccccccccccc')=1,'cross tenant SELECT');
select pg_temp.assert_true((select count(*) from public.user_profiles)=4,'inventory attribution can read same-tenant profiles');
select pg_temp.expect_denied($s$update public.user_profiles set tenant_id=(select tenant_b from authorization_context)$s$);
select pg_temp.expect_denied($s$update public.user_profiles set is_active=false$s$);
select pg_temp.expect_denied($s$update public.user_profiles set user_id='b2222222-2222-4222-8222-222222222222'$s$);
select pg_temp.expect_denied($s$insert into public.user_roles select tenant_a,'a2222222-2222-4222-8222-222222222224',gen_random_uuid() from authorization_context$s$);
select pg_temp.expect_denied($s$insert into public.role_permissions select tenant_a,gen_random_uuid(),'settings:manage' from authorization_context$s$);
select pg_temp.expect_denied($s$update public.roles set name='OWNER'$s$);
select pg_temp.expect_denied($s$insert into public.permissions values('escalated',null)$s$);
-- Every workflow/ledger write is denied even to OWNER when attempted directly.
do $$
declare t text;
begin
 foreach t in array array['sales','sale_items','inventory_movements','purchases','purchase_items','transits','trucks','wallets','customer_transactions','wallet_transactions','employees','employee_payments','employee_phone_numbers','employee_types','employee_payment_categories','lpg_brands','gas_plants','area_officers','audit_logs']
 loop
   perform pg_temp.expect_denied(format('insert into public.%I default values',t));
   perform pg_temp.expect_denied(format('update public.%I set tenant_id=tenant_id',t));
   perform pg_temp.expect_denied(format('delete from public.%I',t));
   perform pg_temp.assert_true(not has_table_privilege('authenticated','public.'||t,'TRUNCATE'),'no TRUNCATE: '||t);
   perform pg_temp.assert_true(not has_table_privilege('anon','public.'||t,'SELECT'),'no anon SELECT: '||t);
 end loop;
end $$;
select pg_temp.expect_denied($s$insert into public.items(tenant_id,brand,size_kg,filled_quantity) select tenant_a,'Spoof',5,999 from authorization_context$s$);
select pg_temp.expect_denied($s$insert into public.items(tenant_id,brand,size_kg) select tenant_b,'Spoof',5 from authorization_context$s$);
select pg_temp.expect_denied($s$insert into public.customers(tenant_id,name,phone) select tenant_b,'Spoof','01700000001' from authorization_context$s$);
select pg_temp.expect_denied($s$select app_private.ensure_tenant_wallets((select tenant_b from authorization_context))$s$);
select pg_temp.expect_denied($s$select app_private.ensure_default_employee_payment_categories((select tenant_b from authorization_context))$s$);
select pg_temp.expect_denied($s$select app_private.resolve_employee_type((select tenant_b from authorization_context),'Escalated')$s$);
select pg_temp.expect_denied($s$select app_private.record_inventory_movement('cccccccc-cccc-4ccc-8ccc-cccccccccccc','adjust_gain',999,0,null)$s$);
select pg_temp.expect_denied($s$select app_private.require_permission('pos:sell')$s$);
select pg_temp.expect_denied($s$select app_private.audit_trucks()$s$);

-- Existing registry/customer writes and printer upsert still work.
insert into public.items(tenant_id,brand,size_kg) select tenant_a,'New registry',5 from authorization_context;
insert into public.customers(tenant_id,name,phone) select tenant_a,'Form customer','01700000001' from authorization_context;
insert into public.receipt_printers(tenant_id,printer)
select tenant_a,'{"transport":"windows_usb","queue_id":"test","host_id":"test","queue_name":"test","port_name":"USB001"}'::jsonb from authorization_context;
insert into public.receipt_printers(tenant_id,printer,paper_width_mm,printable_width_dots)
select tenant_a,'{"transport":"windows_usb","queue_id":"test","host_id":"test","queue_name":"test","port_name":"USB001"}'::jsonb,58,384 from authorization_context
on conflict(tenant_id) do update set paper_width_mm=excluded.paper_width_mm,printable_width_dots=excluded.printable_width_dots;
select pg_temp.expect_denied($s$update public.receipt_printers set tenant_id=(select tenant_b from authorization_context)$s$);

-- The purchase read must never join B's reused purchase/truck/plant/item/brand IDs.
do $$
declare r record;
begin
 select * into strict r from public.list_purchases() where purchase_id='cccccccc-cccc-4ccc-8ccc-cccccccccccc';
 perform pg_temp.assert_true(r.truck_name='Truck A' and r.plant_name='Plant A','tenant-qualified purchase parents');
 perform pg_temp.assert_true(jsonb_array_length(r.items)=1 and r.items->0->>'brand_name'='Brand A'
   and (r.items->0->>'quantity')::int=1,'tenant-qualified purchase lines');
end $$;
select public.update_transit_costs('cccccccc-cccc-4ccc-8ccc-cccccccccccc',10,20,30,'[]','completed');
select public.update_purchase('cccccccc-cccc-4ccc-8ccc-cccccccccccc',20,30,null,
 '[{"item_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","quantity":2,"unit_price":100}]');
select public.complete_purchase('cccccccc-cccc-4ccc-8ccc-cccccccccccc');
update authorization_context set purchase_id=(public.create_purchase(
 'cccccccc-cccc-4ccc-8ccc-cccccccccccc','cccccccc-cccc-4ccc-8ccc-cccccccccccc',10,5,null,
 '[{"item_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","type":"refill","quantity":1,"unit_price":100}]')->>'purchase_id')::uuid;
select public.complete_purchase(purchase_id) from authorization_context;
select public.create_custom_transit('cccccccc-cccc-4ccc-8ccc-cccccccccccc',25,'Test');
select public.create_lpg_brand('New brand','Test');
select public.update_lpg_brand('cccccccc-cccc-4ccc-8ccc-cccccccccccc','Brand A updated',null,true);
select public.create_gas_plant('New plant','cccccccc-cccc-4ccc-8ccc-cccccccccccc',null);
select public.update_gas_plant('cccccccc-cccc-4ccc-8ccc-cccccccccccc','Plant A updated',null,null,true);
select public.create_area_officer('cccccccc-cccc-4ccc-8ccc-cccccccccccc','Officer A',null,null);
select public.update_area_officer(officer_id,'Officer edited',null,null) from public.list_gas_plants()
 where officer_name='Officer A';
select public.create_truck('New truck','new-truck',100,'medium',null);
select public.update_truck('cccccccc-cccc-4ccc-8ccc-cccccccccccc','Truck A updated',null,null,null,'idle',null);
select public.create_inventory_movement('cccccccc-cccc-4ccc-8ccc-cccccccccccc','adjust_gain',1,1,'Manual');
update authorization_context set employee_id=(public.create_employee('Employee A',
 '[{"phone":"01700000009","is_primary":true}]',null,1000,'Driver','gas_business',null)->>'employee_id')::uuid;
select public.update_employee(employee_id,'Employee edited','[{"phone":"01700000009","is_primary":true}]',
 null,1100,'Driver','gas_business',null,true) from authorization_context;
select public.create_employee_payment(c.employee_id, cat.category_id,1000,current_date,'Salary',2026,10,null)
from authorization_context c cross join public.list_employee_payment_categories() cat where cat.code='salary';
select pg_temp.assert_true((select count(*) from public.list_employees())=1,'employee read');
select pg_temp.assert_true((select count(*) from public.list_employee_payments((select employee_id from authorization_context)))=1,'payroll read');
-- Same membership, no role-name branch: removing a permission immediately closes its RPC.
reset role;
delete from public.role_permissions rp using public.roles r, authorization_context c
where rp.tenant_id=c.tenant_a and rp.role_id=r.role_id and r.tenant_id=rp.tenant_id
 and r.name='OWNER' and rp.permission_id='settings:manage';
set local role authenticated;
select pg_temp.expect_denied($s$select public.create_lpg_brand('Forbidden',null)$s$);
reset role;
insert into public.role_permissions select r.tenant_id,r.role_id,'settings:manage'
from public.roles r cross join authorization_context c where r.tenant_id=c.tenant_a and r.name='OWNER';

-- MANAGER is a separate role with the complete current catalog.
set local role authenticated;
select set_config('request.jwt.claim.sub','a2222222-2222-4222-8222-222222222223',true);
select pg_temp.assert_true(cardinality(public.get_my_permissions())=(select count(*) from authorization_catalog),'MANAGER full catalog');
select public.create_lpg_brand('Manager brand',null);
select pg_temp.assert_true((select count(*) from public.list_employees())=1,'MANAGER employee access');
select public.get_dashboard_stats(date_trunc('day',now()));
-- Remove inventory:manage from MANAGER only: other permissions keep working.
reset role;
delete from public.role_permissions rp using public.roles r, authorization_context c
where rp.tenant_id=c.tenant_a and rp.role_id=r.role_id and r.tenant_id=rp.tenant_id
 and r.name='MANAGER' and rp.permission_id='inventory:manage';
set local role authenticated;
select pg_temp.expect_denied($s$select public.create_inventory_movement('cccccccc-cccc-4ccc-8ccc-cccccccccccc','adjust_gain',1,0,null)$s$);
-- Purchases need their own capability, not the public inventory-adjustment capability.
update authorization_context set purchase_id=(public.create_purchase(
 'cccccccc-cccc-4ccc-8ccc-cccccccccccc','cccccccc-cccc-4ccc-8ccc-cccccccccccc',0,0,null,
 '[{"item_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","type":"refill","quantity":1,"unit_price":100}]')->>'purchase_id')::uuid;
select public.complete_purchase(purchase_id) from authorization_context;

-- SALESMAN supporting reads, customer creation, real checkout and receipt readback.
select set_config('request.jwt.claim.sub','a2222222-2222-4222-8222-222222222224',true);
select pg_temp.assert_true(public.get_my_permissions() @> array['dashboard:view','pos:sell','sales:view','receipts:print']
 and cardinality(public.get_my_permissions())=4,'SALESMAN minimal catalog');
select pg_temp.assert_true((select count(*) from public.items)>0,'POS product lookup');
select pg_temp.assert_true((select count(*) from public.price_books)=1,'POS price lookup');
select pg_temp.assert_true((select count(*) from public.receipt_printers)=1,'receipt config read');
select pg_temp.assert_true((select count(*) from public.inventory_movements)=0,'no inventory history');
select pg_temp.assert_true((select count(*) from public.wallets)=0,'no wallets');
select pg_temp.assert_true((select count(*) from public.audit_logs)=0,'no audit');
insert into public.customers(tenant_id,name,phone) select tenant_a,'Cashier customer','01700000002' from authorization_context;
update authorization_context set sale_id=(public.create_pos_sale('01700000002','ignored',null,null,'retail',100,50,'POS test',
 '[{"item_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","type":"refill","quantity":1,"unit_price":1200},{"item_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","type":"empty_return","quantity":1,"unit_price":0}]',
 (select customer_id from public.customers where phone='01700000002'))->>'sale_id')::uuid;
select pg_temp.assert_true((select total_amount from public.sales where sale_id=(select sale_id from authorization_context))=1150,'checkout totals');
select pg_temp.assert_true((select created_by from public.sales where sale_id=(select sale_id from authorization_context))
 = 'a2222222-2222-4222-8222-222222222224'::uuid,'server-set sale actor');
select pg_temp.assert_true((select count(*) from public.sale_items where sale_id=(select sale_id from authorization_context))=2,'receipt lines');
select pg_temp.assert_true((select count(*) from public.sales s join public.customers c on c.tenant_id=s.tenant_id and c.customer_id=s.customer_id
 join public.sale_items si on si.tenant_id=s.tenant_id and si.sale_id=s.sale_id join public.items i on i.tenant_id=si.tenant_id and i.item_id=si.item_id
 join public.lpg_brands b on b.tenant_id=i.tenant_id and b.brand_id=i.brand_id where s.sale_id=(select sale_id from authorization_context))=2,'receipt embeds');
select pg_temp.assert_true((public.get_dashboard_stats(date_trunc('day',now()))->>'todayRevenue')::numeric=1150,'Dashboard revenue');
do $$
declare statement text;
begin
 foreach statement in array array[
  $s$select public.list_purchases()$s$, $s$select public.list_trucks(false)$s$,
  $s$select public.list_gas_plants(false)$s$, $s$select public.list_employees()$s$,
  $s$select public.list_employee_payment_categories()$s$,
  $s$select public.list_employee_payments(null)$s$,
  $s$select public.create_lpg_brand('Forbidden',null)$s$,
  $s$select public.create_inventory_movement('cccccccc-cccc-4ccc-8ccc-cccccccccccc','adjust_gain',1,0,null)$s$,
  $s$select public.create_employee('Bad','[]',null,0,null,'gas_business',null)$s$,
  $s$select public.create_employee_payment(null,null,1,current_date,null,null,null,null)$s$,
  $s$select public.complete_purchase('cccccccc-cccc-4ccc-8ccc-cccccccccccc')$s$,
  $s$select public.update_transit_costs('cccccccc-cccc-4ccc-8ccc-cccccccccccc',0,0,0,'[]','completed')$s$,
  $s$insert into public.items(tenant_id,brand,size_kg) select tenant_a,'Forbidden',5 from authorization_context$s$,
  $s$insert into public.receipt_printers(tenant_id,printer) select tenant_a,'{"transport":"windows_usb","queue_id":"bad","host_id":"test","queue_name":"test","port_name":"USB001"}'::jsonb from authorization_context$s$
 ] loop perform pg_temp.expect_denied(statement); end loop;
end $$;
update public.receipt_printers set auto_cut=true;
select pg_temp.assert_true((select auto_cut is false from public.receipt_printers),'cashier printer UPDATE changed no rows');
-- Change SALESMAN mapping without touching any policy/function/application code.
reset role;
insert into public.role_permissions select r.tenant_id,r.role_id,'inventory:manage'
from public.roles r cross join authorization_context c where r.tenant_id=c.tenant_a and r.name='SALESMAN';
set local role authenticated;
select public.create_inventory_movement('cccccccc-cccc-4ccc-8ccc-cccccccccccc','adjust_gain',1,0,'Mapped grant');
reset role;
delete from public.role_permissions rp using public.roles r, authorization_context c
where rp.tenant_id=c.tenant_a and rp.role_id=r.role_id and r.tenant_id=rp.tenant_id
 and r.name='SALESMAN' and rp.permission_id='inventory:manage';
set local role authenticated;
select pg_temp.expect_denied($s$select public.create_inventory_movement('cccccccc-cccc-4ccc-8ccc-cccccccccccc','adjust_gain',1,0,null)$s$);

-- Inactive membership, suspended tenant and unassigned account are all fail closed.
reset role;
update public.roles set name='CUSTOM CASHIER'
where tenant_id=(select tenant_a from authorization_context) and name='SALESMAN';
set local role authenticated;
select pg_temp.assert_true(cardinality(public.get_my_permissions())=4,'role names do not control authorization');
select public.get_dashboard_stats(date_trunc('day',now()));
reset role;
update public.user_profiles set is_active=false where user_id='a2222222-2222-4222-8222-222222222224';
set local role authenticated;
select pg_temp.assert_true(cardinality(public.get_my_permissions())=0 and (select count(*) from public.items)=0,'inactive user');
select pg_temp.expect_denied($s$select public.get_dashboard_stats(now())$s$);
reset role;
update public.user_profiles set is_active=true where user_id='a2222222-2222-4222-8222-222222222224';
update public.tenants set status='suspended' where tenant_id=(select tenant_a from authorization_context);
set local role authenticated;
select pg_temp.assert_true(cardinality(public.get_my_permissions())=0 and (select count(*) from public.sales)=0,'suspended tenant');
select pg_temp.expect_denied($s$select public.get_dashboard_stats(now())$s$);
reset role;
update public.tenants set status='active' where tenant_id=(select tenant_a from authorization_context);
set local role authenticated;
select set_config('request.jwt.claim.sub','a2222222-2222-4222-8222-222222222225',true);
select pg_temp.assert_true(cardinality(public.get_my_permissions())=0 and (select count(*) from public.items)=0,'no role assignment');
select pg_temp.expect_denied($s$select public.get_dashboard_stats(now())$s$);

-- Anonymous access is denied at grants, including every public function.
set local role anon;
select set_config('request.jwt.claim.sub','',true);
select pg_temp.expect_denied($s$select * from public.items$s$);
select pg_temp.expect_denied($s$select * from public.tenants$s$);
select pg_temp.expect_denied($s$select public.setup_business('Anon','Anon')$s$);
select pg_temp.expect_denied($s$select public.get_my_permissions()$s$);
reset role;
do $$
declare f record; t record;
begin
 for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','app_private')
 loop
   perform pg_temp.assert_true(not has_function_privilege('anon',f.oid,'EXECUTE'),'no anonymous execution '||f.oid::regprocedure);
 end loop;
 for t in select oid from pg_class where relnamespace='public'::regnamespace and relkind='r'
 loop
   perform pg_temp.assert_true(not has_table_privilege('anon',t.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'),'no anon table privilege');
   perform pg_temp.assert_true(not has_table_privilege('authenticated',t.oid,'TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'),'no elevated table privilege');
 end loop;
 -- Trusted operations must also respect the composite identity FK.
 begin
   insert into public.user_roles(tenant_id,user_id,role_id)
   select c.tenant_b,'a2222222-2222-4222-8222-222222222224',r.role_id
   from authorization_context c join public.roles r on r.tenant_id=c.tenant_b and r.name='OWNER';
   raise exception 'FAIL: cross-tenant assignment accepted';
 exception when foreign_key_violation then null; end;
 begin
   insert into public.inventory_movements(tenant_id,item_id,movement_type,created_by)
   select tenant_b,'cccccccc-cccc-4ccc-8ccc-cccccccccccc','adjust_gain','a2222222-2222-4222-8222-222222222224' from authorization_context;
   raise exception 'FAIL: cross-tenant actor accepted';
 exception when foreign_key_violation then null; end;
end $$;
-- Deliberately colliding UUIDs never changed B's records.
with current_b as (
 select name,row_data from authorization_context c cross join lateral (
 select 'items' name,to_jsonb(i) row_data from public.items i where i.tenant_id=c.tenant_b
 union all select 'wallets',to_jsonb(w) from public.wallets w where w.tenant_id=c.tenant_b
 union all select 'transits',to_jsonb(t) from public.transits t where t.tenant_id=c.tenant_b
 union all select 'trucks',to_jsonb(t) from public.trucks t where t.tenant_id=c.tenant_b
 union all select 'purchases',to_jsonb(p) from public.purchases p where p.tenant_id=c.tenant_b
 union all select 'purchase_items',to_jsonb(p) from public.purchase_items p where p.tenant_id=c.tenant_b
 union all select 'sales',to_jsonb(s) from public.sales s where s.tenant_id=c.tenant_b
 union all select 'sale_items',to_jsonb(s) from public.sale_items s where s.tenant_id=c.tenant_b
 ) x
)
select pg_temp.assert_true(not exists(
 (select * from authorization_other_snapshot except select * from current_b)
 union all
 (select * from current_b except select * from authorization_other_snapshot)
),'reused UUIDs must not cause cross-tenant inserts, updates or deletes');
-- Future objects must not inherit the old browser grants for either creator.
create table public.authorization_future_admin(id integer);
alter table public.authorization_future_admin enable row level security;
create function public.authorization_future_admin_fn() returns integer language sql as 'select 1';
set local role postgres;
create table public.authorization_future_postgres(id integer);
alter table public.authorization_future_postgres enable row level security;
create function public.authorization_future_postgres_fn() returns integer language sql as 'select 1';
reset role;
select pg_temp.assert_true(
 not has_table_privilege('anon','public.authorization_future_admin','SELECT,INSERT,UPDATE,DELETE,TRUNCATE') and
 not has_table_privilege('authenticated','public.authorization_future_admin','SELECT,INSERT,UPDATE,DELETE,TRUNCATE') and
 not has_table_privilege('anon','public.authorization_future_postgres','SELECT,INSERT,UPDATE,DELETE,TRUNCATE') and
 not has_table_privilege('authenticated','public.authorization_future_postgres','SELECT,INSERT,UPDATE,DELETE,TRUNCATE') and
 not has_function_privilege('anon','public.authorization_future_admin_fn()','EXECUTE') and
 not has_function_privilege('authenticated','public.authorization_future_admin_fn()','EXECUTE') and
 not has_function_privilege('anon','public.authorization_future_postgres_fn()','EXECUTE') and
 not has_function_privilege('authenticated','public.authorization_future_postgres_fn()','EXECUTE'),
 'least privilege future-object defaults');
select 'PASS: RBAC, active membership, grants, escalation denial, tenant-qualified workflows, future-object defaults and reused UUID isolation' as verification;
rollback;
