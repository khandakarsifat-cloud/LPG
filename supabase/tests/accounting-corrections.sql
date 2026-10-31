begin;
create function pg_temp.check_correction(ok boolean,note text) returns void language plpgsql as $$begin if ok is not true then raise exception 'FAIL: %',note;end if;end $$;
create function pg_temp.reject_correction(q text,expected text) returns void language plpgsql as $$begin begin execute q;exception when others then if position(lower(expected) in lower(sqlerrm))=0 then raise exception 'Expected %; got %',expected,sqlerrm;end if;return;end;raise exception 'Expected rejection: %',expected;end $$;
grant execute on function pg_temp.check_correction(boolean,text),pg_temp.reject_correction(text,text) to authenticated;

-- Check reconstructed source evidence, each historical period and all control
-- balances on the restored copy. Never manufacture a balancing profit plug.
do $$declare t record;r jsonb;actor uuid;d date;revenue numeric;begin
 for t in select * from public.accounting_periods where opening_note like 'Reconstructed development history.%' loop
  select u.user_id into actor from public.user_profiles u join public.user_roles ur using(tenant_id,user_id) join public.roles role using(tenant_id,role_id) where u.tenant_id=t.tenant_id and role.name='OWNER' limit 1;
  perform set_config('request.jwt.claim.sub',actor::text,true);
  r:=public.get_finance_analysis(jsonb_build_object('business_id',t.tenant_id,'from',(t.started_at at time zone 'Asia/Dhaka')::date,'to',(now() at time zone 'Asia/Dhaka')::date,'grain','day'));
  select sum(total_amount+additional_charges) into revenue from public.sales where tenant_id=t.tenant_id and status='completed';
  perform pg_temp.check_correction((r->'totals'->>'revenue')::numeric=coalesce(revenue,0),'Historical invoice revenue is recognized from actual sales');
  perform pg_temp.check_correction(r->>'invested_capital' is not null and (r->'totals'->>'profit')::numeric=(r->'totals'->>'position_profit')::numeric,'Reconstructed capital and profit reconcile');
  r:=public.get_finance_analysis(jsonb_build_object('business_id',t.tenant_id,'from',(t.started_at at time zone 'Asia/Dhaka')::date,'to',(now() at time zone 'Asia/Dhaka')::date,'grain','day','category','logistics'));
  perform pg_temp.check_correction((public.get_logistics_summary()->>'profit')::numeric=(r->'totals'->>'profit')::numeric,'Logistics summary equals canonical logistics profit, excluding internal transport allocations');
  perform pg_temp.check_correction(not exists(select 1 from public.inventory_movements m where m.tenant_id=t.tenant_id and not exists(select 1 from public.inventory_cost_entries e where e.tenant_id=m.tenant_id and e.movement_id=m.movement_id)),'Every historical physical movement has recorded carrying evidence');
  for d in select day::date from generate_series((t.started_at at time zone 'Asia/Dhaka')::date,(now() at time zone 'Asia/Dhaka')::date,'1 day')day loop
   r:=public.get_finance_analysis(jsonb_build_object('business_id',t.tenant_id,'from',d,'to',d,'grain','day'));
   perform pg_temp.check_correction((r->>'complete')::boolean and (r->'totals'->>'profit')::numeric=(r->'totals'->>'position_profit')::numeric,'Every historical day reconciles P&L to changes in net assets');
   perform pg_temp.check_correction((r->'closing'->>'assets')::numeric=(r->'closing'->>'liabilities')::numeric+(r->'closing'->>'equity')::numeric,'Every historical balance sheet balances');
  end loop;
 end loop;
end $$;
select 'PASS: reconstructed source history, complete carrying evidence, invested capital, daily P&L / net-assets profit and balance sheets';

insert into auth.users(id,email,is_anonymous) values('ae060000-0000-4000-8000-000000000001','corrections-owner@example.invalid',false),('ae070000-0000-4000-8000-000000000001','corrections-other@example.invalid',false);
set local role authenticated;
select set_config('request.jwt.claim.sub','ae060000-0000-4000-8000-000000000001',true);
select public.setup_business('Accounting corrections disposable fixture','Owner');
select set_config('request.jwt.claim.sub','ae070000-0000-4000-8000-000000000001',true);
select public.setup_business('Accounting corrections other tenant','Other');
select set_config('request.jwt.claim.sub','ae060000-0000-4000-8000-000000000001',true);

do $$declare t uuid:=app_private.current_tenant_id();d date:=(now() at time zone 'Asia/Dhaka')::date;b uuid;plant uuid;i uuid;other_i uuid;v uuid;driver uuid;pid uuid;hid uuid;r jsonb;before_report jsonb;req uuid;rate uuid;begin
 r:=public.get_finance_analysis(jsonb_build_object('from',d-365,'to',d,'business_id',t,'grain','month'));
 perform pg_temp.check_correction((r->>'complete')::boolean and (r->'totals'->>'profit')::numeric=0 and (r->>'invested_capital')::numeric=0,'Empty new business has a complete zero history');
 b:=(public.create_lpg_brand('Corrections LPG',null)->>'brand_id')::uuid;
 plant:=(public.create_gas_plant('Corrections plant',b,'Dhaka')->>'plant_id')::uuid;
 insert into public.items(tenant_id,brand_id,size_kg,mouth_size) values(t,b,12,'22mm') returning item_id into i;
 insert into public.items(tenant_id,brand_id,size_kg,mouth_size) values(t,b,5,'22mm') returning item_id into other_i;
 perform public.adjust_inventory(jsonb_build_object('item_id',i,'kind','opening','filled_quantity',10,'empty_quantity',10,'filled_unit_cost',3000,'empty_unit_cost',1500,'reason','Verified fixture inventory'),gen_random_uuid());
 driver:=(public.save_employee(jsonb_build_object('name','Corrections fixture driver','employee_type_name','Driver','business_unit','truck_business','phones',jsonb_build_array(jsonb_build_object('phone','01700000602','is_primary',true)),'terms',jsonb_build_object('monthly_salary',0,'effective_from',d,'is_active',true)),gen_random_uuid())->>'employee_id')::uuid;
 v:=(public.save_vehicle(jsonb_build_object('name','Corrections truck','serial_no','CORRECTIONS','capacity',100,'driver_employee_id',driver,'book_value',20000,'funding','opening'),gen_random_uuid())->>'vehicle_id')::uuid;
 pid:=(public.create_purchase(jsonb_build_object('request_id',gen_random_uuid(),'plant_id',plant,'vehicle_id',v,'commission',50,'transport_cost',100,'labour_cost',20,'items',jsonb_build_array(jsonb_build_object('item_id',i,'type','refill','quantity',5,'unit_price',1000),jsonb_build_object('item_id',i,'type','package','quantity',5,'unit_price',2500))))->>'purchase_id')::uuid;
 perform public.dispatch_purchase(pid,1);perform public.receive_purchase(pid,2);
 r:=public.get_financial_activity(jsonb_build_object('source','transit'),0,1);
 perform pg_temp.check_correction((r->'entries'->0->>'revenue')::numeric=0 and (r->'entries'->0->>'internal_allocation')::numeric=100,'Internal purchase transport remains visible but never becomes external activity revenue');
 perform pg_temp.check_correction((public.get_transit((select transit_id from public.transits where tenant_id=t and purchase_id=pid))->>'revenue')::numeric=0,'Per-transit revenue follows the canonical journal');
 before_report:=public.get_finance_analysis(jsonb_build_object('from',d-1,'to',d,'business_id',t,'grain','day'));
 r:=public.get_product_inventory(i);rate:=(r->'commission'->>'version')::uuid;
 perform public.set_product_commissions(i,20,50,rate);
 r:=public.get_product_inventory(i);
 perform pg_temp.check_correction((select (p->>'automatic_price')::numeric=992 from jsonb_array_elements(r->'buying_prices')p where p->>'price_type'='refill'),'Automatic refill estimate uses latest receipt plus overhead less configured commission');
 perform pg_temp.check_correction((select (p->>'automatic_price')::numeric=2462 from jsonb_array_elements(r->'buying_prices')p where p->>'price_type'='package'),'Automatic package estimate restored');
 select (p->>'history_id')::uuid into hid from jsonb_array_elements(r->'buying_prices')p where p->>'price_type'='refill';
 req:=gen_random_uuid();r:=jsonb_build_object('item_id',i,'price_type','refill','is_manual',true,'price',555,'reason','Manual operational test','expected',hid);
 perform public.set_product_buying_price(r,req);perform public.set_product_buying_price(r,req);
 r:=public.get_product_inventory(i);perform public.set_product_commissions(i,30,60,(r->'commission'->>'version')::uuid);
 r:=public.get_product_inventory(i);
 perform pg_temp.check_correction((select (p->>'new_price')::numeric=555 and (p->>'automatic_price')::numeric=982 and (p->>'is_manual')::boolean from jsonb_array_elements(r->'buying_prices')p where p->>'price_type'='refill'),'Commission changes preserve manual overrides and update suggestions');
 select (p->>'history_id')::uuid into hid from jsonb_array_elements(r->'buying_prices')p where p->>'price_type'='refill';
 perform public.set_product_buying_price(jsonb_build_object('item_id',i,'price_type','refill','is_manual',false,'reason','Restore automatic suggestion','expected',hid),gen_random_uuid());
 perform pg_temp.check_correction(public.get_finance_analysis(jsonb_build_object('from',d-1,'to',d,'business_id',t,'grain','day'))=before_report,'Approximate prices and manual commissions have zero effect on any financial report value');
 perform pg_temp.check_correction((public.get_buying_price_history(i)->>'total')::integer>=6 and (public.get_product_commission_history(i)->>'total')::integer=2,'Buying and commission histories retained');
 perform public.set_product_buying_price(jsonb_build_object('item_id',other_i,'price_type','refill','is_manual',true,'price',500,'reason','Reference without a purchase','expected',null),gen_random_uuid());
 perform pg_temp.reject_correction(format('select public.set_product_image(%L,%L)',i,'https://example.invalid/foreign.svg'),'uploaded image belonging');
 -- Different bottles are rejected only at checkout. The existing Sales
 -- settlement RPC remains available and is covered by the unified suite.
 perform pg_temp.reject_correction(format('select public.create_pos_sale(%L,%L,null,null,%L,0,0,null,%L::jsonb,null,%L,null,%L::jsonb)',
 '01700000601','Checkout fixture','retail',jsonb_build_array(jsonb_build_object('item_id',i,'type','refill','quantity',1,'unit_price',1200),jsonb_build_object('item_id',i,'type','empty_return','quantity',1,'unit_price',0)),gen_random_uuid(),jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('received_item_id',other_i,'quantity',1,'acknowledged',true)))),'only expected');
 r:=public.get_analysis_details(jsonb_build_object('from',d-1,'to',d,'business_id',t),'journal',null,0,1);
 perform pg_temp.check_correction(jsonb_array_length(r->'entries')=1 and not(r->'entries'->0 ? 'lines'),'Journal header pages never embed unbounded lines');
 hid:=(r->'entries'->0->>'journal_id')::uuid;
 r:=public.get_journal_lines(jsonb_build_object('business_id',t),hid,0,1);
 perform pg_temp.check_correction(jsonb_array_length(r->'entries')=1 and r->'entries'->0->>'entity_name' is not null,'Expanded journal lines are paged and described');
 perform pg_temp.reject_correction(format('select public.get_journal_lines(%L::jsonb,%L,0,101)',jsonb_build_object('business_id',t),hid),'Invalid line page');
end $$;
select 'PASS: zero-history new business, restored suggestions / overrides / histories, strict accounting independence, expected-only checkout, and paged journal lines';
reset role;
create temporary table correction_audit_fixture(tenant_id uuid,item_id uuid,journal_id uuid,image_path text);
do $$declare t uuid;i uuid;j uuid;path text;entries jsonb;begin
 select tenant_id into t from public.user_profiles where user_id='ae060000-0000-4000-8000-000000000001';
 select item_id into i from public.items where tenant_id=t order by size_kg limit 1;
 path:=t::text||'/rollback-image-fixture.webp';
 insert into storage.objects(bucket_id,name,metadata) values('product-images',path,'{"mimetype":"image/webp","size":100}');
 select jsonb_agg(app_private.accounting_line('other_assets',1,'shared',gen_random_uuid())) into entries from generate_series(1,1000);
 entries:=entries||jsonb_build_array(app_private.accounting_line('opening_equity',-1000));
 j:=app_private.post_journal(t,'audit_fixture',gen_random_uuid(),'large',(now() at time zone 'Asia/Dhaka')::date,'Large opening journal fixture',entries,false,true);
 insert into correction_audit_fixture values(t,i,j,path);
end $$;
grant select on correction_audit_fixture to authenticated;
set local role authenticated;
do $$declare fixture record;r jsonb;b uuid;i uuid;begin
 select * into fixture from correction_audit_fixture;
 b:=(public.create_lpg_brand('Photo registration fixture',null)->>'brand_id')::uuid;
 insert into public.items(tenant_id,brand_id,size_kg,mouth_size,image_url)
 values(fixture.tenant_id,b,12,'22mm',fixture.image_path) returning item_id into i;
 perform pg_temp.check_correction(exists(select 1 from public.items where item_id=i and image_url=fixture.image_path and filled_quantity=0 and empty_quantity=0),'Normal LPG registration accepts its validated photo with zero stock');
 perform pg_temp.check_correction(not has_column_privilege('authenticated','public.items','filled_quantity','INSERT') and not has_table_privilege('authenticated','public.items','UPDATE'),'Photo registration never grants direct stock writes');
 perform public.set_product_image(fixture.item_id,fixture.image_path);
 perform pg_temp.check_correction(exists(select 1 from storage.objects where bucket_id='product-images' and name=fixture.image_path),'Own tenant may read its image');
 perform pg_temp.check_correction(not app_private.product_image_unused(fixture.image_path),'Referenced images fail the Storage deletion-policy predicate');
 r:=public.get_journal_lines(jsonb_build_object('business_id',fixture.tenant_id),fixture.journal_id,0,25);
 perform pg_temp.check_correction((r->>'total')::integer=1001 and jsonb_array_length(r->'entries')=25,'Large opening journal returns exactly one bounded line page');
 r:=public.get_journal_lines(jsonb_build_object('business_id',fixture.tenant_id),fixture.journal_id,1000,25);
 perform pg_temp.check_correction(jsonb_array_length(r->'entries')=1 and r->'entries'->0->>'account_code'='opening_equity','Final expanded page contains only its remaining lines');
end $$;
select set_config('request.jwt.claim.sub','ae070000-0000-4000-8000-000000000001',true);
do $$declare fixture record;begin
 select * into fixture from correction_audit_fixture;
 perform pg_temp.check_correction(not exists(select 1 from storage.objects where bucket_id='product-images' and name=fixture.image_path),'Other tenant cannot read private image objects');
 perform pg_temp.reject_correction(format('insert into storage.objects(bucket_id,name) values(%L,%L)','product-images',fixture.tenant_id::text||'/foreign-upload.webp'),'row-level security');
 perform pg_temp.reject_correction(format('select public.get_journal_lines(%L::jsonb,%L,0,25)','{}',fixture.journal_id),'Journal not found');
end $$;
select 'PASS: private image tenant isolation, referenced-image protection, 1,001-line journal pagination and cross-tenant audit denial';
reset role;
set constraints all immediate;
rollback;
