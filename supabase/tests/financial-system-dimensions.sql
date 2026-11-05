begin;
create function pg_temp.assert(ok boolean,message text) returns void language plpgsql as $$begin if ok is not true then raise exception 'FAIL: %',message;end if;end $$;
select pg_temp.assert(not exists(select 1 from public.accounting_lines l left join public.financial_types t using(type_id) where t.type_id is null or l.business_category not in ('lpg','stove','logistics')),'Every existing line has a valid type/category/business');
select pg_temp.assert(not exists(select 1 from public.accounting_lines group by tenant_id,journal_id,business_category having sum(amount)<>0),'Every restored journal balances for each business');
insert into auth.users(id,email,is_anonymous) values('fd010000-0000-4000-8000-000000000001','financial-dimensions@example.invalid',false);
set local role authenticated;
select set_config('request.jwt.claim.sub','fd010000-0000-4000-8000-000000000001',true);
select public.setup_business('Disposable dimensional system acceptance','Owner');
reset role;
create temp table financial_fixture(t uuid,lpg uuid,brand uuid,plant uuid,wallet uuid,bank uuid,vehicle uuid,purchase uuid,sale uuid);
do $$declare t uuid:=app_private.current_tenant_id();l uuid;b uuid;pid uuid;v uuid;w uuid;bank uuid;begin
 b:=pg_temp.fixture_brand(t,'Dimensional supplier');pid:=(public.create_gas_plant('Dimensional plant',b,'Dhaka')->>'plant_id')::uuid;
 insert into public.items(tenant_id,brand_id,size_kg,mouth_size) values(t,b,12,'22mm') returning item_id into l;
 select wallet_id into w from public.get_payment_wallets() where type='cash';select wallet_id into bank from public.get_payment_wallets() where type='dealership';
 v:=(public.save_vehicle(jsonb_build_object('name','Dimensional truck','serial_no','FD-01','capacity',300,'book_value',100000,'funding','opening'),gen_random_uuid())->>'vehicle_id')::uuid;
 perform pg_temp.fixture_vehicle_crew(t,v);
 insert into financial_fixture values(t,l,b,pid,w,bank,v,null,null);
end $$;
do $$declare f financial_fixture;d date:=(now() at time zone 'Asia/Dhaka')::date;k uuid:=gen_random_uuid();body jsonb;r jsonb;before numeric;asset uuid;p uuid;s uuid;begin
 select * into f from financial_fixture;
 perform public.accounting_operation(jsonb_build_object('action','opening_entry','account','supplier_payable','amount',2000,'date',d,'description','Shared supported opening payable','business_category','lpg','allocations',jsonb_build_object('lpg',60,'stove',40)),gen_random_uuid());
 perform pg_temp.assert(not exists(select 1 from public.accounting_lines where tenant_id=f.t group by journal_id,business_category having sum(amount)<>0),'Shared opening entry overrides single-business caller defaults consistently on both sides');
 -- No available-balance gate: same-wallet transfer creates a negative LPG
 -- business amount while preserving total cash, with no profit or debt.
 body:=jsonb_build_object('action','transfer','transfer_mode','business','wallet_id',f.wallet,'destination_id',f.wallet,'business','lpg','destination_business','stove','amount',100,'reason','Independent business allocation');
 perform public.move_wallet_money(body,k);perform public.move_wallet_money(body,k);
 perform pg_temp.assert((select balance=0 and (business_balances->>'lpg')::numeric=-100 and (business_balances->>'stove')::numeric=100 from public.wallets where tenant_id=f.t and wallet_id=f.wallet),'Same-wallet business transfer, deficit and exact retry');
 perform public.move_wallet_money(jsonb_build_object('action','transfer','transfer_mode','business','wallet_id',f.bank,'destination_id',f.wallet,'business','logistics','destination_business','lpg','amount',200,'reason','Independent overdraft transfer'),gen_random_uuid());
 perform pg_temp.assert((select balance=-200 from public.wallets where tenant_id=f.t and wallet_id=f.bank),'Overall wallet deficits supported');
 asset:=(public.accounting_operation(jsonb_build_object('action','asset_register','kind','equipment','name','Shared shop equipment','amount',100000,'funding','wallet','wallet_id',f.wallet,'date',d,'description','Independent shared ownership','allocations',jsonb_build_object('lpg',60,'stove',40)),gen_random_uuid())->>'id')::uuid;
 perform public.accounting_operation(jsonb_build_object('action','asset_depreciate','asset_id',asset,'amount',1000,'date',d,'description','Independent shared depreciation'),gen_random_uuid());
 perform pg_temp.assert((select sum(amount)=59400 from public.accounting_lines where tenant_id=f.t and account='equipment' and entity_id=asset and business_category='lpg'),'One equipment asset retains 60% LPG after depreciation');
 perform pg_temp.assert((select sum(amount)=39600 from public.accounting_lines where tenant_id=f.t and account='equipment' and entity_id=asset and business_category='stove'),'One equipment asset retains 40% Stove after depreciation');
 perform public.accounting_operation(jsonb_build_object('action','asset_improve','asset_id',asset,'funding','credit','amount',5000,'date',d,'description','Qualifying capital improvement'),gen_random_uuid());
 perform pg_temp.assert((select cost=105000 and accumulated_depreciation=1000 from public.business_assets where tenant_id=f.t and asset_id=asset),'Improvement increases the same asset without immediate expense');
 -- Ten packages, Tk 25,000 external acquisition plus Tk 3,000 internal
 -- transportation. Sell four packages: external COGS 10,000, internal 1,200.
 p:=(public.create_purchase(jsonb_build_object('request_id',gen_random_uuid(),'plant_id',f.plant,'vehicle_id',f.vehicle,'transport_cost',3000,'transport_wallet_id',f.bank,'items',jsonb_build_array(jsonb_build_object('item_id',f.lpg,'type','package','quantity',10,'unit_price',2500,'shell_unit_cost',1500))))->>'purchase_id')::uuid;
 select balance into before from public.wallets where tenant_id=f.t and wallet_id=f.wallet;
 perform public.dispatch_purchase(p,1,d);
 perform pg_temp.assert((select balance=before+3000 and (business_balances->>'logistics')::numeric=3000 from public.wallets where tenant_id=f.t and wallet_id=f.wallet),'Internal transport credits Logistics Cash Register');
 perform pg_temp.assert((select balance=-3200 and (business_balances->>'lpg')::numeric=-3000 from public.wallets where tenant_id=f.t and wallet_id=f.bank),'Internal transport debits selected LPG wallet');
 perform public.receive_purchase(p,2,d);
 insert into public.price_books(tenant_id,item_id,price_type,customer_tier,price,effective_from) values(f.t,f.lpg,'package','retail',4000,now()-interval '1 day');
 s:=(public.create_pos_sale('01700000961','Dimensional customer',null,null,'retail',0,0,null,jsonb_build_array(jsonb_build_object('item_id',f.lpg,'type','package','quantity',4,'unit_price',4000)),null,gen_random_uuid(),'[]',null)->>'sale_id')::uuid;
 perform pg_temp.assert((select sum(amount)=16800 and sum(consolidated_amount)=15000 from public.accounting_lines where tenant_id=f.t and account='inventory_lpg'),'Unsold internal margin 1800 eliminated from consolidated inventory');
 perform pg_temp.assert((public.get_inventory_valuation()->>'business_lpg_value')::numeric=16800 and (public.get_inventory_valuation()->>'lpg_value')::numeric=15000,'Inventory exposes the same business and consolidated stock values as Finance');
 perform pg_temp.assert((select sum(amount)=11200 and sum(consolidated_amount)=10000 from public.accounting_lines where tenant_id=f.t and account='cogs'),'Sold internal transport 1200 eliminated from consolidated COGS');
 r:=public.get_finance_analysis(jsonb_build_object('business_id',f.t,'from',d,'to',d,'category','lpg','grain','day'));
 perform pg_temp.assert((r->'totals'->>'revenue')::numeric=16000 and (r->'totals'->>'expenses')::numeric=11800,'LPG report: revenue 16000 less COGS 11200 and depreciation 600');
 perform pg_temp.assert((r->'closing'->>'assets')::numeric=(r->'closing'->>'liabilities')::numeric+(r->'closing'->>'equity')::numeric,'LPG equation reconciles');
 r:=public.get_finance_analysis(jsonb_build_object('business_id',f.t,'from',d,'to',d,'category','logistics','grain','day'));
 perform pg_temp.assert((r->'totals'->>'revenue')::numeric=3000,'Logistics report recognizes internal revenue once');
 r:=public.get_finance_analysis(jsonb_build_object('business_id',f.t,'from',d,'to',d,'grain','day'));
 perform pg_temp.assert((r->'closing'->>'assets')::numeric=(app_private.accounting_position(array[f.t],d)->>'assets')::numeric,'Private unscoped position uses the same consolidated elimination');
 perform pg_temp.assert((r->'totals'->>'revenue')::numeric=16000 and (r->'totals'->>'expenses')::numeric=11000+(select coalesce(sum(amount),0) from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where l.tenant_id=f.t and account='employee_expense' and j.occurred_on=d),'Consolidated revenue excludes internal 3000 and expenses exclude internal 1200');
 perform pg_temp.assert((r->'totals'->>'profit')::numeric=(r->'totals'->>'position_profit')::numeric,'Independent profit and net-asset change reconcile');
 perform public.reverse_sale(s,'Independent original-layer return','CANCEL',gen_random_uuid());
 perform pg_temp.assert((select sum(amount)=28000 and sum(consolidated_amount)=25000 from public.accounting_lines where tenant_id=f.t and account='inventory_lpg'),'Return restores original internal and external FIFO values');
 perform pg_temp.assert((select sum(remaining_internal_value)=3000 from app_private.fifo_layers where tenant_id=f.t and item_id=f.lpg),'Original internal transport layers restored');
 perform pg_temp.assert((public.get_logistics_summary()->>'transport_fees')::numeric=3000,'Logistics overview uses same internal revenue');
 update financial_fixture set purchase=p,sale=s;
end $$;
select 'PASS: negative business/total wallets, exact retries, shared equipment, internal transport cash, FIFO issues/returns and consolidated elimination';
do $$declare f financial_fixture;p uuid;d date:=(now() at time zone 'Asia/Dhaka')::date;before jsonb;begin
 select * into f from financial_fixture;
 -- Releasing the first vehicle permits a second unreceived shipment fixture.
 update public.transits set status='returned' where tenant_id=f.t and purchase_id=f.purchase;
 update public.vehicles set status='idle' where tenant_id=f.t and vehicle_id=f.vehicle;
 p:=(public.create_purchase(jsonb_build_object('request_id',gen_random_uuid(),'plant_id',f.plant,'vehicle_id',f.vehicle,'transport_cost',100,'items',jsonb_build_array(jsonb_build_object('item_id',f.lpg,'type','package','quantity',1,'unit_price',2500,'shell_unit_cost',1500))))->>'purchase_id')::uuid;
 select business_balances into before from public.wallets where tenant_id=f.t and wallet_id=f.wallet;
 perform public.dispatch_purchase(p,1,d);
 perform public.initiate_purchase_cancellation(p,2,'CANCEL',gen_random_uuid());
 perform pg_temp.assert((select business_balances=before from public.wallets where tenant_id=f.t and wallet_id=f.wallet),'Unreceived cancellation reverses exact same-wallet transport business amounts');
 perform pg_temp.assert(not exists(select 1 from public.wallets w where tenant_id=f.t and balance<>(business_balances->>'lpg')::numeric+(business_balances->>'stove')::numeric+(business_balances->>'logistics')::numeric),'All wallet portions equal total');
 perform pg_temp.assert(not exists(select 1 from public.accounting_lines where tenant_id=f.t group by journal_id having sum(amount)<>0 or sum(consolidated_amount)<>0),'All journals balance under both views');
 perform pg_temp.assert(not exists(select 1 from public.accounting_lines where tenant_id=f.t group by journal_id,business_category having sum(amount)<>0),'Every individual business equation balances');
 perform pg_temp.assert((public.get_wallet_ledger(jsonb_build_object('business','logistics'))->>'total')::integer>0,'Business wallet ledger works');
end $$;
do $$declare f financial_fixture;w uuid;d date:=(now() at time zone 'Asia/Dhaka')::date;begin
 select * into f from financial_fixture;
 w:=public.save_finance_wallet(jsonb_build_object('name','Zero-net business allocation wallet','kind','other','details','','is_active',true));
 perform public.move_wallet_money(jsonb_build_object('action','transfer','transfer_mode','business','wallet_id',w,'destination_id',w,'business','lpg','destination_business','stove','amount',100,'reason','Offset portions at zero total'),gen_random_uuid());
 begin perform public.save_finance_wallet(jsonb_build_object('wallet_id',w,'revision',1,'name','Zero-net business allocation wallet','kind','other','details','','is_active',false));raise exception 'FAIL: wallet with stranded business portions archived';exception when raise_exception then if sqlerrm like 'FAIL:%' then raise;end if;perform pg_temp.assert(sqlerrm like 'Clear every business balance%','Expected archive ownership guard');end;
 perform public.move_wallet_money(jsonb_build_object('action','transfer','transfer_mode','business','wallet_id',w,'destination_id',w,'business','stove','destination_business','lpg','amount',100,'reason','Clear portions before closure'),gen_random_uuid());
 perform public.save_finance_wallet(jsonb_build_object('wallet_id',w,'revision',1,'name','Zero-net business allocation wallet','kind','other','details','','is_active',false));
 begin
  perform app_private.post_journal(f.t,'opening_entry',gen_random_uuid(),'test',d,'Disposable source-bug injection',jsonb_build_array(app_private.accounting_line('other_assets',1,'lpg'),app_private.accounting_line('other_liability',-1,'stove')));
  set constraints all immediate;raise exception 'FAIL: cross-business unbalanced journal accepted';
 exception when raise_exception then if sqlerrm like 'FAIL:%' then raise;end if;perform pg_temp.assert(sqlerrm like 'Journal must balance for every business%','Deferred business equation rejects malformed source code');end;
end $$;
set constraints all immediate;
select 'PASS: internal transport cancellation, wallet portions, each business equation and deferred constraints';
rollback;
