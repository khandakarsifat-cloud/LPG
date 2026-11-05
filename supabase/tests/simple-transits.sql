begin;
insert into auth.users(id,email,is_anonymous) values('bf910000-0000-4000-8000-000000000001','simple-transits@example.invalid',false);
select pg_temp.fixture_identity('bf910000-0000-4000-8000-000000000001');
select pg_temp.fixture_business('Simple transit disposable fixture','Owner');
create function pg_temp.check_transit(ok boolean,label text) returns void language plpgsql as $$begin if ok is not true then raise exception 'FAIL: %',label;end if;end$$;
grant execute on function pg_temp.check_transit(boolean,text) to authenticated;
set local role authenticated;
do $$declare t uuid;d uuid;h uuid;v uuid;tr uuid;sid uuid;cat uuid;cash uuid;bank uuid;body jsonb;req uuid;result jsonb;baseline numeric;rev integer;begin
 t:=app_private.current_tenant_id();
 d:=(public.save_employee('{"name":"Simple driver","employee_type_name":"Driver","business_unit":"truck_business","phones":[{"phone":"01700000941","is_primary":true}],"terms":{"monthly_salary":0,"effective_from":"2026-01-01","is_active":true}}',gen_random_uuid())->>'employee_id')::uuid;
 h:=(public.save_employee('{"name":"Simple helper","employee_type_name":"Helper","business_unit":"truck_business","phones":[{"phone":"01700000942","is_primary":true}],"terms":{"monthly_salary":0,"effective_from":"2026-01-01","is_active":true}}',gen_random_uuid())->>'employee_id')::uuid;
 v:=(public.save_vehicle(jsonb_build_object('name','Simple truck','serial_no','SIMPLE-TRUCK','capacity',0,'book_value',0,'funding','capital','driver_employee_id',d,'helper_employee_id',h),gen_random_uuid())->>'vehicle_id')::uuid;
 select wallet_id into cash from public.get_payment_wallets() where type='cash';
 select wallet_id into bank from public.get_payment_wallets() where type='dealership';
 select balance into baseline from public.wallets where wallet_id=cash;
 body:=jsonb_build_object('vehicle_id',v,'fee',5000,'client_name','Simple client','destination','Dhaka');req:=gen_random_uuid();
 result:=public.create_custom_transit(body,req);tr:=(result->>'transit_id')::uuid;
 perform pg_temp.check_transit((select balance from public.wallets where wallet_id=cash)=baseline+5000,'creation collects full fee into Cash Register');
 perform pg_temp.check_transit(public.create_custom_transit(body,req)=result,'creation retry returns original result');
 perform pg_temp.check_transit((public.get_transit(tr)->>'client_paid')::numeric=5000,'collection is canonical and counted once');
 perform public.save_transit_costs(tr,'{"driver_cost":100,"helper_cost":100,"oil_cost":10,"others_cost":50}',(public.get_transit(tr)->>'revision')::integer);
 -- An earlier partial payment must only leave the remainder for completion.
 perform public.employee_payment_operation(jsonb_build_object('action','pay','items',jsonb_build_array(jsonb_build_object('employee_id',d,'kind','trips','trip_count',1,'transit_id',tr,'trip_role','driver','payment_date',(now() at time zone 'Asia/Dhaka')::date,'payments',jsonb_build_array(jsonb_build_object('wallet_id',bank,'amount',25))))),gen_random_uuid());
 rev:=(public.get_transit(tr)->>'revision')::integer;
 begin perform public.transition_transit(tr,'return',rev);raise exception 'FAIL: separate custom return allowed';exception when others then if sqlerrm like 'FAIL:%' then raise;end if;end;
 begin perform public.transition_transit(tr,'complete',rev-1);raise exception 'FAIL: stale completion allowed';exception when others then if sqlerrm not like '%Transit changed%' then raise;end if;end;
 body:='{"driver_cost":100,"helper_cost":100,"oil_cost":20,"others_cost":50}';
 perform public.transition_transit(tr,'complete',rev,body);perform public.transition_transit(tr,'complete',rev,body);
 perform pg_temp.check_transit((public.get_transit(tr)->>'outstanding')::numeric=0 and public.get_transit(tr)->>'closed_at' is not null,'completion pays and closes');
 perform pg_temp.check_transit(public.get_vehicle(v)->>'location'='Home','completion returns vehicle Home');
 perform pg_temp.check_transit((select balance from public.wallets where wallet_id=cash)=baseline+5000-245,'completion saves costs and debits only unpaid amounts exactly once');
 perform pg_temp.check_transit((public.get_transit_payroll(tr)->>'driver_paid')::numeric=100,'driver receives canonical employee payment');
 select category_id into cat from public.get_vehicle_expense_categories() where name='Engine Oil';
 sid:=(public.save_service_trip(jsonb_build_object('vehicle_id',v,'title','Visible service trip','service_date',(now() at time zone 'Asia/Dhaka')::date,'expenses',jsonb_build_array(jsonb_build_object('category_id',cat,'amount',300))),gen_random_uuid())->>'service_trip_id')::uuid;
 result:=public.get_transit_directory(jsonb_build_object('vehicle_id',v,'type','service','expense_category','Engine Oil','status','outstanding'));
 perform pg_temp.check_transit((result->>'total')::integer=1 and result->'entries'->0->>'service_trip_id'=sid::text,'service trips participate in filtered directory');
 result:=public.get_transit_directory(jsonb_build_object('vehicle_id',v),1,1);
 perform pg_temp.check_transit((result->>'total')::integer=2 and jsonb_array_length(result->'entries')=1,'unified pagination counts journeys and services');
 perform pg_temp.check_transit(not exists(select 1 from public.wallets w where tenant_id=t and balance<>opening_balance+coalesce((select sum(amount) from public.wallet_transactions x where x.tenant_id=t and x.wallet_id=w.wallet_id),0)),'wallet ledger reconciles');
end$$;
reset role;
-- Fault injection and obsolete unpaid-source arrangement stay inside this disposable transaction.
alter table public.wallets drop constraint wallet_system_active;
do $$declare t uuid:=app_private.current_tenant_id();v uuid;tr uuid;cash uuid;rev integer;before_balance numeric;kind uuid;item uuid;p uuid;body jsonb;begin
 select vehicle_id into v from public.vehicles where tenant_id=t and serial_no='SIMPLE-TRUCK';
 select wallet_id into cash from public.wallets where tenant_id=t and type='cash';
 perform set_config('session_replication_role','replica',true);
 update public.wallets set is_active=false where tenant_id=t and wallet_id=cash;
 perform set_config('session_replication_role','origin',true);
 begin
  perform public.create_custom_transit(jsonb_build_object('vehicle_id',v,'fee',100,'client_name','Missing cash','destination','Dhaka'),gen_random_uuid());
  raise exception 'FAIL: creation without Cash Register allowed';
 exception when others then if sqlerrm not like '%Activate Cash Register%' then raise;end if;end;
 perform pg_temp.check_transit(public.get_vehicle(v)->>'location'='Home','failed creation rolls back vehicle departure');
 perform set_config('session_replication_role','replica',true);
 update public.wallets set is_active=true where tenant_id=t and wallet_id=cash;
 perform set_config('session_replication_role','origin',true);
 -- Represent an existing unpaid transit without inventing historical money.
 insert into public.transits(tenant_id,vehicle_id,status,transport_fee,client_name,destination) values(t,v,'active',100,'Legacy open collection','Dhaka') returning transit_id into tr;
 update public.vehicles set status='going' where tenant_id=t and vehicle_id=v;
 rev:=(public.get_transit(tr)->>'revision')::integer;
 select balance into before_balance from public.wallets where wallet_id=cash;
 perform set_config('session_replication_role','replica',true);
 update public.wallets set is_active=false where tenant_id=t and wallet_id=cash;
 perform set_config('session_replication_role','origin',true);
 body:='{"driver_cost":6000,"helper_cost":20,"oil_cost":10,"others_cost":0}';
 begin perform public.transition_transit(tr,'complete',rev,body);raise exception 'FAIL: inactive cash completion allowed';exception when others then if sqlerrm not like '%Activate Cash Register%' then raise;end if;end;
 perform pg_temp.check_transit((public.get_transit(tr)->>'revision')::integer=rev and (public.get_transit(tr)->>'total_cost')::numeric=0,'failed completion rolls back cost edits and payments');
 perform set_config('session_replication_role','replica',true);
 update public.wallets set is_active=true where tenant_id=t and wallet_id=cash;
 perform set_config('session_replication_role','origin',true);
 perform public.transition_transit(tr,'complete',rev,body);
 perform pg_temp.check_transit((public.get_transit(tr)->>'client_paid')::numeric=100 and (select balance from public.wallets where wallet_id=cash)=before_balance-5930,'confirmed legacy completion collects remaining fee and permits wallet deficit');
 -- Purchase dispatch/receipt and internal transport remain unchanged.
 select type_id into kind from public.get_stove_product_types() limit 1;
 item:=(public.save_stove_product(jsonb_build_object('name','Simple purchase stove','type_id',kind),gen_random_uuid())->>'item_id')::uuid;
 p:=(public.create_purchase(jsonb_build_object('request_id',gen_random_uuid(),'business_category','stove','supplier_name','Simple supplier','vehicle_id',v,'transport_cost',1000,'items',jsonb_build_array(jsonb_build_object('item_id',item,'type','package','quantity',2,'unit_price',300))))->>'purchase_id')::uuid;
 perform public.dispatch_purchase(p,1,(now() at time zone 'Asia/Dhaka')::date);
 select transit_id into tr from public.transits where tenant_id=t and purchase_id=p;
 begin perform public.transition_transit(tr,'complete',(public.get_transit(tr)->>'revision')::integer);raise exception 'FAIL: purchase completed before receipt';exception when others then if sqlerrm not like '%Receive or cancel%' then raise;end if;end;
 perform public.receive_purchase(p,2,(now() at time zone 'Asia/Dhaka')::date);
 select balance into before_balance from public.wallets where wallet_id=cash;
 perform public.transition_transit(tr,'complete',(public.get_transit(tr)->>'revision')::integer,'{"driver_cost":10.01,"helper_cost":20.02,"oil_cost":3.30,"others_cost":0}');
 perform pg_temp.check_transit((select balance from public.wallets where wallet_id=cash)=before_balance-33.33,'purchase completion pays exact cents from Cash Register');
 perform pg_temp.check_transit((select count(*) from public.wallet_transactions where tenant_id=t and reference_id=p and type like 'internal_transport_%')=2,'purchase internal transfer is not charged again');
 perform pg_temp.check_transit((select filled_quantity from public.items where tenant_id=t and item_id=item)=2,'purchase stock unchanged by completion');
 -- Cancellation must retain real cash refund evidence.
 tr:=(public.create_custom_transit(jsonb_build_object('vehicle_id',v,'fee',100,'client_name','Cancel fixture','destination','Dhaka'),gen_random_uuid())->>'transit_id')::uuid;
 perform public.transition_transit(tr,'cancel',(public.get_transit(tr)->>'revision')::integer);
 begin perform public.transition_transit(tr,'complete',(public.get_transit(tr)->>'revision')::integer);raise exception 'FAIL: unrefunded cancellation completed';exception when others then if sqlerrm not like '%Refund outstanding%' then raise;end if;end;
 perform public.record_operating_payment(jsonb_build_object('transit_id',tr,'kind','client_refund','payment_date',(now() at time zone 'Asia/Dhaka')::date,'payments',jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',100))),gen_random_uuid());
 perform public.transition_transit(tr,'complete',(public.get_transit(tr)->>'revision')::integer);
 perform pg_temp.check_transit(public.get_transit(tr)->>'status'='cancelled','cancelled history retained');
 -- Commit this source only in the disposable runner, for competing completions.
 tr:=(public.create_custom_transit(jsonb_build_object('vehicle_id',v,'fee',0,'client_name','Race fixture','destination','Dhaka'),gen_random_uuid())->>'transit_id')::uuid;
 perform public.save_transit_costs(tr,'{"driver_cost":50,"helper_cost":25,"oil_cost":25,"others_cost":0}',(public.get_transit(tr)->>'revision')::integer);
end$$;
-- A transit manager cannot use automatic completion to bypass payment permissions.
insert into auth.users(id,email,is_anonymous) values('bf910000-0000-4000-8000-000000000002','simple-transit-manager@example.invalid',false);
insert into public.user_profiles(user_id,tenant_id,email) select 'bf910000-0000-4000-8000-000000000002',tenant_id,'simple-transit-manager@example.invalid' from public.user_profiles where user_id='bf910000-0000-4000-8000-000000000001';
insert into public.user_roles(tenant_id,user_id,role_id) select tenant_id,'bf910000-0000-4000-8000-000000000002',role_id from public.roles where tenant_id=app_private.current_tenant_id() and name='MANAGER';
delete from public.role_permissions where tenant_id=app_private.current_tenant_id() and role_id in(select role_id from public.roles where tenant_id=app_private.current_tenant_id() and name='MANAGER') and permission_id in('payroll:pay','logistics:pay');
select pg_temp.fixture_identity('bf910000-0000-4000-8000-000000000002');
set local role authenticated;
do $$declare tr jsonb;begin
 tr:=public.get_transit_directory('{"search":"Race fixture"}')->'entries'->0;
 begin perform public.transition_transit((tr->>'transit_id')::uuid,'complete',(tr->>'revision')::integer,'{"driver_cost":500,"helper_cost":25,"oil_cost":25,"others_cost":0}');raise exception 'FAIL: payment permission bypass';exception when others then if sqlerrm <> 'Permission denied' then raise;end if;end;
 perform pg_temp.check_transit((public.get_transit((tr->>'transit_id')::uuid)->>'total_cost')::numeric=100,'permission rejection rolls back cost edits');
end$$;
reset role;
insert into auth.users(id,email,is_anonymous) values('bf910000-0000-4000-8000-000000000003','simple-transit-foreign@example.invalid',false);
select pg_temp.fixture_identity('bf910000-0000-4000-8000-000000000003');
select pg_temp.fixture_business('Simple transit foreign disposable fixture','Foreign owner');
set local role authenticated;
select pg_temp.check_transit((public.get_transit_directory('{"type":"service"}')->>'total')::integer=0,'service directory is tenant isolated');
reset role;
select pg_temp.check_transit(not has_function_privilege('anon','public.transition_transit(uuid,text,integer,jsonb)','execute'),'anonymous completion denied');
select 'PASS: automatic collections and cost settlement, failure rollback, stale requests, exact cents, cancellation, purchase workflow, service filters, tenant and payment permission guards';
rollback;
