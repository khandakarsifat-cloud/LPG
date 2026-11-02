-- Retain payroll attribution at earning/advance creation, including partial
-- payouts and later returned funds after an employee changes assignments.
alter table public.employee_payments add column allocations jsonb;
alter table public.employee_payments disable trigger immutable_employee_payment;
update public.employee_payments p set allocations=case when p.kind='trips' then '{"logistics":100}'::jsonb else e.business_allocations end
from public.employees e where e.tenant_id=p.tenant_id and e.employee_id=p.employee_id;
alter table public.employee_payments enable trigger immutable_employee_payment;
alter table public.employee_payments alter column allocations set not null;
alter table public.employee_payments add check(app_private.valid_business_allocation(allocations));
-- Correct the formerly unallocated historical payroll settlement metadata to
-- the same earning ownership. Amounts and original source IDs are preserved.
alter table public.accounting_lines disable trigger accounting_immutable;
alter table public.wallet_transactions disable trigger immutable_wallet_entry;
do $$declare r record;entries jsonb;begin
 for r in select j.*,p.allocations from public.accounting_journals j join public.wallet_transactions x on x.tenant_id=j.tenant_id and x.transaction_id=j.source_id
 join public.employee_payment_entries e on e.tenant_id=x.tenant_id and e.entry_id=x.employee_entry_id join public.employee_payments p on p.tenant_id=e.tenant_id and p.payment_id=e.payment_id where j.source='wallet' loop
  select jsonb_agg(app_private.accounting_line(account,amount,'shared',entity_id,details)||jsonb_build_object('type_id',type_id,'allocations',r.allocations,'consolidated_amount',consolidated_amount)) into entries from public.accounting_lines where tenant_id=r.tenant_id and journal_id=r.journal_id;
  entries:=app_private.dimension_entries(r.tenant_id,r.source,r.source_id,entries);
  delete from public.accounting_lines where tenant_id=r.tenant_id and journal_id=r.journal_id;
  insert into public.accounting_lines(tenant_id,journal_id,line_no,account,amount,consolidated_amount,business_category,entity_id,details,type_id)
  select r.tenant_id,r.journal_id,n::integer,x->>'account',(x->>'amount')::numeric,(x->>'consolidated_amount')::numeric,x->>'business_category',(x->>'entity_id')::uuid,x->'details',(x->>'type_id')::uuid from jsonb_array_elements(entries) with ordinality a(x,n);
 end loop;
end $$;
update public.wallet_transactions x set allocations=p.allocations,business_amounts=(select jsonb_object_agg(business,amount) from app_private.allocate_money(x.amount,p.allocations))
from public.employee_payment_entries e join public.employee_payments p using(tenant_id,payment_id) where e.tenant_id=x.tenant_id and e.entry_id=x.employee_entry_id;
update public.wallets w set business_balances=(select jsonb_object_agg(k,coalesce((select sum(l.amount) from public.accounting_lines l where l.tenant_id=w.tenant_id and l.entity_id=w.wallet_id and l.account='cash' and l.business_category=k),0)) from unnest(array['lpg','stove','logistics'])k);
with running as(select x.tenant_id,x.transaction_id,
 sum(coalesce((x.business_amounts->>'lpg')::numeric,0)) over(partition by x.tenant_id,x.wallet_id order by entry_no) + (w.business_balances->>'lpg')::numeric-sum(coalesce((x.business_amounts->>'lpg')::numeric,0)) over(partition by x.tenant_id,x.wallet_id) lpg,
 sum(coalesce((x.business_amounts->>'stove')::numeric,0)) over(partition by x.tenant_id,x.wallet_id order by entry_no) + (w.business_balances->>'stove')::numeric-sum(coalesce((x.business_amounts->>'stove')::numeric,0)) over(partition by x.tenant_id,x.wallet_id) stove,
 sum(coalesce((x.business_amounts->>'logistics')::numeric,0)) over(partition by x.tenant_id,x.wallet_id order by entry_no) + (w.business_balances->>'logistics')::numeric-sum(coalesce((x.business_amounts->>'logistics')::numeric,0)) over(partition by x.tenant_id,x.wallet_id) logistics
 from public.wallet_transactions x join public.wallets w using(tenant_id,wallet_id))
update public.wallet_transactions x set business_balance_after=jsonb_build_object('lpg',r.lpg,'stove',r.stove,'logistics',r.logistics) from running r where x.tenant_id=r.tenant_id and x.transaction_id=r.transaction_id;
alter table public.wallet_transactions enable trigger immutable_wallet_entry;
alter table public.accounting_lines enable trigger accounting_immutable;
create function app_private.payment_business_allocation() returns trigger language plpgsql set search_path='' as $$declare
 period date;sid uuid;begin
 if new.reversal_of is not null then select allocations into new.allocations from public.employee_payments where tenant_id=new.tenant_id and payment_id=new.reversal_of;
 elsif new.kind='trips' then new.allocations:='{"logistics":100}';
 else
  select business_allocations into new.allocations from public.employees where tenant_id=new.tenant_id and employee_id=new.employee_id;
  if new.kind='salary' then
   select m.period into period from public.employee_salary_months m where tenant_id=new.tenant_id and salary_month_id=new.salary_month_id;
   sid:=md5(new.employee_id::text||period::text)::uuid;
   insert into app_private.salary_business_allocations values(new.tenant_id,sid,new.employee_id,new.allocations) on conflict do nothing;
   select allocations into new.allocations from app_private.salary_business_allocations where tenant_id=new.tenant_id and source_id=sid;
  end if;
 end if;return new;end $$;
create trigger aa_payment_business_allocation before insert on public.employee_payments for each row execute function app_private.payment_business_allocation();

do $$declare s text;begin
 s:=pg_get_functiondef('app_private.source_allocation(uuid,text,uuid)'::regprocedure);
 s:=replace(s,'select e.business_allocations into a from public.employee_payments x join public.employees e using(tenant_id,employee_id)', 'select x.allocations into a from public.employee_payments x');execute s;
 s:=pg_get_functiondef('app_private.wallet_dimensions()'::regprocedure);
 s:=replace(s,'select business_allocations into a from public.employees where tenant_id=new.tenant_id and employee_id=p.employee_id;', 'a:=p.allocations;');execute s;
 s:=pg_get_functiondef('public.save_employee(jsonb,uuid)'::regprocedure);
 s:=replace(s,'employee_type_id,business_unit,notes,created_by)', 'employee_type_id,business_unit,notes,created_by,business_allocations)');
 s:=replace(s,'auth.uid()) returning employee_id into eid;', 'auth.uid(),coalesce(p_payload->''business_allocations'',case when p_payload->>''business_unit''=''truck_business'' then ''{"logistics":100}''::jsonb else ''{"lpg":100}''::jsonb end)) returning employee_id into eid;');
 s:=replace(s,'business_unit=p_payload->>''business_unit'',notes=', 'business_allocations=coalesce(p_payload->''business_allocations'',business_allocations),business_unit=p_payload->>''business_unit'',notes=');execute s;
 s:=pg_get_functiondef('public.update_purchase(uuid,jsonb,integer)'::regprocedure);
 s:=replace(s,'-- Costs and quantities', '-- Costs and quantities');
 s:=replace(s,'update public.purchases set payment_status=',
 'if p_payload ? ''transport_wallet_id'' then if p.status<>''created'' then raise exception ''Transport wallet is fixed at dispatch'';end if; update public.purchases set transport_wallet_id=nullif(p_payload->>''transport_wallet_id'','''')::uuid where tenant_id=t and purchase_id=p_purchase_id;end if; update public.purchases set payment_status=');execute s;
end $$;

-- An improvement increases the same identifiable asset; later depreciation and
-- disposal use that cost. It never creates a second vehicle/equipment value.
do $$declare s text;begin s:=pg_get_functiondef('public.accounting_operation(jsonb,uuid)'::regprocedure);
 s:=replace(s,'wallet_id=wallet and is_active for update;', 'wallet_id=wallet and is_active;');
 s:=replace(s,'or action=''asset_dispose'' then', 'or action=''asset_dispose'' or action=''asset_improve'' and p_payload->>''funding''=''wallet'' then');
 s:=replace(s,'elsif action in (''asset_depreciate'',''asset_dispose'') then',
 'elsif action=''asset_improve'' then
 select * into asset from public.business_assets where tenant_id=t and asset_id=(p_payload->>''asset_id'')::uuid for update;
 if not found or asset.status<>''active'' or amount<=0 or d<coalesce((select max(occurred_on) from public.asset_activity where tenant_id=t and asset_id=asset.asset_id),asset.acquired_on) or coalesce(p_payload->>''funding'','''') not in (''wallet'',''credit'',''capital'') then raise exception ''Choose an active asset, valid improvement cost and funding'';end if;
 id:=asset.asset_id;alloc:=asset.allocations;counter:=case p_payload->>''funding'' when ''wallet'' then ''other_assets'' when ''credit'' then ''other_liability'' else ''capital'' end;
 update public.business_assets set cost=cost+amount,revision=revision+1 where tenant_id=t and asset_id=id;
 if counter=''other_assets'' then insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,operation_id,description,accounting_date,allocations) values(t,wallet,-amount,''asset_purchase'',id,p_request_id,note,d,alloc);end if;
 if counter=''other_liability'' then insert into public.finance_obligations(tenant_id,obligation_id,account,origin,cash_activity,entity_id,description,amount,occurred_on,created_by,allocations) values(t,p_request_id,''other_liability'',''incurred'',''investing'',id,note,amount,d,auth.uid(),alloc);end if;
 entries:=jsonb_build_array(app_private.accounting_line(asset.kind,amount,''shared'',id),app_private.accounting_line(counter,-amount,''shared'',case when counter in (''other_assets'',''other_liability'') then id end));
 insert into public.asset_activity(tenant_id,asset_id,action,occurred_on,details,created_by) values(t,id,action,d,p_payload||jsonb_build_object(''amount'',amount,''allocations'',alloc),auth.uid());
 elsif action in (''asset_depreciate'',''asset_dispose'') then');
 s:=replace(s,'''other_liability'',''operating_payable'',''employee_payable'') then raise exception ''Choose an opening', '''other_liability'',''operating_payable'',''employee_payable'',''retained_earnings'') then raise exception ''Choose an opening');
 s:=replace(s,'amount:=case when account in (''supplier_payable'',''other_liability'',''operating_payable'',''employee_payable'')', 'amount:=case when account in (''supplier_payable'',''other_liability'',''operating_payable'',''employee_payable'',''retained_earnings'')');execute s;
end $$;

create function app_private.financial_source_link(t uuid,src text,id uuid) returns jsonb language plpgsql stable set search_path='' as $$declare
 k text;ref uuid:=id;x public.wallet_transactions;m public.inventory_movements;e public.operating_cost_events;result_id uuid;begin
 if src in ('sale','sale_reversal') then k:='sale';
 elsif src in ('purchase','internal_transport') then k:='purchase';
 elsif src in ('inventory','bottle_obligation','internal_inventory','internal_cogs') then
  select * into m from public.inventory_movements where tenant_id=t and movement_id=id;
  ref:=m.reference_id;k:=case when m.reference_type in ('sale','sale_reversal') then 'sale' when m.reference_type like '%purchase%' then 'purchase' else 'product' end;if k='product' then ref:=m.item_id;end if;
 elsif src='transit_revenue' then k:='transit';
 elsif src='operating_cost' then select * into e from public.operating_cost_events where tenant_id=t and event_id=id;ref:=e.transit_id;k:='transit';
 elsif src='salary_accrual' then select employee_id into ref from app_private.salary_business_allocations where tenant_id=t and source_id=id;k:='employee';
 elsif src='bonus' then select employee_id into ref from public.employee_payments where tenant_id=t and payment_id=id;k:='employee';
 elsif src='owner_operation' then
  select (result->>'id')::uuid into result_id from public.finance_requests where tenant_id=t and request_id=id;ref:=result_id;
  if exists(select 1 from public.business_assets where tenant_id=t and asset_id=ref) then k:='asset';elsif exists(select 1 from public.loans where tenant_id=t and loan_id=ref) then k:='loan';end if;
 elsif src='wallet' then
  select * into x from public.wallet_transactions where tenant_id=t and transaction_id=id;ref:=x.reference_id;
  if x.type in ('pos_sale_income','customer_collection','sale_refund') then k:='sale';
  elsif x.type like 'purchase%' or x.type like 'internal_transport_%' then k:='purchase';
  elsif x.type like 'transit_%' then k:='transit';
  elsif x.type like 'payroll_%' then select p.employee_id into ref from public.employee_payment_entries e join public.employee_payments p using(tenant_id,payment_id) where e.tenant_id=t and e.entry_id=x.employee_entry_id;k:='employee';
  elsif x.type like 'asset_%' then k:='asset';elsif x.type like 'loan_%' then k:='loan';
  elsif x.type='custom_entry' or exists(select 1 from public.financial_entries where tenant_id=t and entry_id=ref) then k:='financial_entry';end if;
 end if;
 return case when k is not null and ref is not null then jsonb_build_object('record_kind',k,'record_id',ref) else '{}'::jsonb end;
end $$;

do $$declare s text;begin
 s:=pg_get_functiondef('public.get_accounting_breakdown(jsonb,text,text,text,integer,integer)'::regprocedure);
 s:=replace(s,'app_private.analysis_entity(l.tenant_id,l.account,l.entity_id) entity', 'app_private.analysis_entity(l.tenant_id,l.account,l.entity_id)||app_private.financial_source_link(j.tenant_id,j.source,j.source_id) entity');execute s;
 s:=pg_get_functiondef('public.get_wallet_ledger(jsonb,integer,integer)'::regprocedure);
 s:=replace(s,'''type_name'',ft.name,',
 '''amount'',keys.amount,''total_amount'',p.amount,''balance_after'',case when nullif($2->>''business'','''') is null then p.balance_after else (p.business_balance_after->>($2->>''business''))::numeric end,''type_name'',coalesce((select e.type_name from public.financial_entries e where e.tenant_id=p.tenant_id and e.entry_id=p.reference_id),ft.name),');
 s:=replace(s,'or x.business_amounts ? ($2->>''business''))', 'or coalesce((x.business_amounts->>($2->>''business''))::numeric,0)<>0)');
 s:=replace(s,'x.amount>0','(case when nullif($2->>''business'','''') is null then x.amount else (x.business_amounts->>($2->>''business''))::numeric end)>0');
 s:=replace(s,'x.amount<0','(case when nullif($2->>''business'','''') is null then x.amount else (x.business_amounts->>($2->>''business''))::numeric end)<0');
 s:=replace(s,'abs(x.amount)','abs(case when nullif($2->>''business'','''') is null then x.amount else (x.business_amounts->>($2->>''business''))::numeric end)');
 s:=replace(s,'to_jsonb(p)-''search_document'')||jsonb_build_object', 'to_jsonb(p)-''search_document'')||app_private.financial_source_link(p.tenant_id,''wallet'',p.transaction_id)||jsonb_build_object');execute s;
 s:=pg_get_functiondef('app_private.period_financial_values(jsonb)'::regprocedure);
 s:=replace(s,'amount,t.code','amount,t.code,t.origin');s:=replace(s,'code in (''asset_register'',''asset_improve'')','(code in (''asset_register'',''asset_improve'') or origin=''custom'')');execute s;
 s:=pg_get_functiondef('app_private.finance_analysis_report(jsonb)'::regprocedure);
 s:=replace(s,'case when x.type=''obligation_settlement'' then',
 'case when x.type=''custom_entry'' then (select case when e.account in (''capital'',''withdrawals'') then ''financing'' when e.account in (''equipment'',''other_assets'') then ''investing'' else ''operating'' end from public.financial_entries e where e.tenant_id=x.tenant_id and e.entry_id=x.reference_id) when x.type=''obligation_settlement'' then');execute s;
end $$;

create function public.get_financial_entry(p_entry_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$declare
 t uuid:=app_private.require_any_permission(array['finance:view','finance:manage']);result jsonb;begin
 select to_jsonb(e)||jsonb_build_object('returned',coalesce((select sum(amount) from public.financial_entries r where r.tenant_id=t and r.reversal_of=e.entry_id),0)) into result from public.financial_entries e where e.tenant_id=t and e.entry_id=p_entry_id;
 if result is null then raise exception 'Financial entry unavailable' using errcode='42501';end if;return result;end $$;

-- Log seeded as well as user-created definitions. Entry snapshots remain the
-- authority for recognition even if a type's category later changes.
create function app_private.audit_financial_type() returns trigger language plpgsql set search_path='' as $$begin
 if new.origin='custom' then insert into public.financial_type_history values(new.tenant_id,new.type_id,new.revision,to_jsonb(new),clock_timestamp(),auth.uid());end if;return new;end $$;
create trigger audit_financial_type after insert or update on public.financial_types for each row execute function app_private.audit_financial_type();
do $$declare s text;begin s:=pg_get_functiondef('public.save_financial_type(jsonb)'::regprocedure);
 s:=replace(s,'insert into public.financial_type_history values(t,definition.type_id,definition.revision,to_jsonb(definition),clock_timestamp(),auth.uid());','');execute s;end $$;

alter function public.get_financial_entry(uuid) owner to postgres;
revoke all on function public.get_financial_entry(uuid) from public,anon;
grant execute on function public.get_financial_entry(uuid) to authenticated;
do $$declare r record;begin for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='app_private' and p.proname in ('payment_business_allocation','financial_source_link','audit_financial_type') loop
 execute format('alter function %s owner to postgres',r.sig);execute format('revoke all on function %s from public,anon,authenticated',r.sig);end loop;end $$;

-- The retired standalone commission model is empty on the inspected development
-- target. Monthly earned FIFO rebates are its sole canonical replacement.
do $$begin
 if exists(select 1 from public.supplier_commissions) or exists(select 1 from public.commission_applications) or exists(select 1 from public.accounting_lines where account='commission_revenue') then raise exception 'Inspect standalone commission evidence before removing the retired model';end if;
end $$;
drop trigger reverse_purchase_commissions on public.purchases;
drop function app_private.reverse_purchase_commissions();
do $$declare s text;a integer;b integer;begin
 s:=pg_get_functiondef('public.accounting_operation(jsonb,uuid)'::regprocedure);
 s:=replace(s,'commission public.supplier_commissions;','');execute s;
 s:=pg_get_functiondef('public.get_accounting_register(text,integer)'::regprocedure);
 a:=strpos(s,'elsif p_kind=''commissions'' then');b:=strpos(s,'elsif p_kind in (''opening'',''obligations'')');
 if a<1 or b<=a then raise exception 'Register definition changed';end if;s:=overlay(s placing '' from a for b-a);execute s;
 s:=pg_get_functiondef('app_private.reconcile_record(uuid,text,uuid)'::regprocedure);
 a:=strpos(s,'elsif k=''commission'' then');b:=strpos(s,'elsif k=''obligation'' then');
 if a<1 or b<=a then raise exception 'Reconciliation definition changed';end if;s:=overlay(s placing '' from a for b-a);execute s;
 s:=pg_get_functiondef('app_private.start_reconciliation_sweep()'::regprocedure);s:=replace(s,',''commission''','');execute s;
 s:=pg_get_functiondef('app_private.reconciliation_sweep_batch(integer)'::regprocedure);s:=replace(s,'(''commission'',''supplier_commissions'',''commission_id''),','');execute s;
 s:=pg_get_functiondef('app_private.analysis_entity(uuid,text,uuid)'::regprocedure);
 s:=replace(s,'if not found then select supplier_name,''commission'' into label,k from public.supplier_commissions where tenant_id=t and commission_id=id;end if;','');execute s;
end $$;
delete from app_private.reconciliation_queue where kind='commission';
delete from app_private.reconciliation_sweeps where kind='commission';
drop table public.commission_applications;
drop table public.supplier_commissions;
delete from public.accounting_accounts where code='commission_revenue';

-- Opening historical earnings are an explicit equity component, not another
-- sale/expense. Reclassification changes neither cash nor period profit.
do $$declare s text;begin
 s:=pg_get_functiondef('app_private.position_from_balances(jsonb)'::regprocedure);
 s:=replace(s,'''accumulated_income'',', '''historical_earnings'',coalesce(-sum(s.balance) filter(where account=''retained_earnings''),0),''accumulated_income'',');execute s;
 s:=pg_get_functiondef('app_private.finance_analysis_report(jsonb)'::regprocedure);
 s:=replace(s,'''retained_earnings'',closing->''accumulated_income''', '''retained_earnings'',(closing->>''accumulated_income'')::numeric+coalesce((closing->>''historical_earnings'')::numeric,0)');execute s;
end $$;

-- Historical cash type strings remain source evidence, but only their current
-- named custom types appear in the active type catalog.
delete from public.financial_types t where code in ('business_spending','commission_reversal','commission_receipt') and not exists(select 1 from public.accounting_lines l where l.type_id=t.type_id) and not exists(select 1 from public.wallet_transactions x where x.type_id=t.type_id);

-- Inventory exposes both the consolidated external value and buyer-business
-- acquisition overhead; the two views must never be presented as one figure.
do $$declare s text;begin
 s:=pg_get_functiondef('public.get_inventory_valuation()'::regprocedure);
 s:=replace(s,'return result;',
 'return result||jsonb_build_object(''internal_transport_value'',coalesce((select sum(remaining_internal_value) from app_private.fifo_layers where tenant_id=t and remaining_internal_value<>0),0),''business_lpg_value'',(result->>''lpg_value'')::numeric+coalesce((select sum(l.remaining_internal_value) from app_private.fifo_layers l join public.items i using(tenant_id,item_id) where l.tenant_id=t and l.remaining_internal_value<>0 and i.business_category=''lpg''),0),''business_stove_value'',(result->>''stove_value'')::numeric+coalesce((select sum(l.remaining_internal_value) from app_private.fifo_layers l join public.items i using(tenant_id,item_id) where l.tenant_id=t and l.remaining_internal_value<>0 and i.business_category=''stove''),0));');execute s;
 s:=pg_get_functiondef('public.get_inventory_cost_history(uuid,integer)'::regprocedure);
 s:=replace(s,'select to_jsonb(c) from public.inventory_costs c',
 'select to_jsonb(c)||jsonb_build_object(''internal_value'',coalesce((select sum(remaining_internal_value) from app_private.fifo_layers where tenant_id=t and item_id=p_item_id and remaining_internal_value<>0),0)) from public.inventory_costs c');
 s:=replace(s,'jsonb_agg(to_jsonb(e))',
 'jsonb_agg(to_jsonb(e)||jsonb_build_object(''internal_value'',coalesce((select sum(l.amount) from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) where j.tenant_id=t and j.source in (''internal_inventory'',''internal_cogs'') and j.source_id=e.movement_id and l.account in (''inventory_lpg'',''inventory_stove'') and l.entity_id=p_item_id),0)))');execute s;
end $$;
