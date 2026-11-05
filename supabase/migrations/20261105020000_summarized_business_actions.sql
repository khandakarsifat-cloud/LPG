-- Forward writes only. Historical journals and their source identities are immutable.
-- The collector is transaction-local memory; it is neither another durable event
-- store nor a second posting path. Existing RPC request/revision guards own retries.
create function app_private.begin_accounting_action(action text, request_id uuid default null)
returns void language plpgsql set search_path='' as $$
declare c jsonb:=nullif(current_setting('lpg.accounting_action',true),'')::jsonb;
begin
 if c is null then
  c:=jsonb_build_object('action',action,'id',coalesce(request_id,gen_random_uuid()),'depth',1,'posts','[]'::jsonb);
 else c:=jsonb_set(c,'{depth}',to_jsonb((c->>'depth')::integer+1));end if;
 perform set_config('lpg.accounting_action',c::text,true);
end $$;

create function app_private.finish_accounting_action()
returns void language plpgsql set search_path='' as $$
declare c jsonb:=nullif(current_setting('lpg.accounting_action',true),'')::jsonb;
 g record;p jsonb;link jsonb;src text;sid uuid;jid uuid;lines jsonb;start_day date;label text;
begin
 if c is null then raise exception 'Accounting action is missing';end if;
 if (c->>'depth')::integer>1 then
  perform set_config('lpg.accounting_action',jsonb_set(c,'{depth}',to_jsonb((c->>'depth')::integer-1))::text,true);return;
 end if;
 for g in
  select (x->>'tenant')::uuid tenant,(x->>'date')::date occurred_on,
   case when x->>'source'='salary_accrual' then x->>'id' else '' end salary,
   (x->>'opening')::boolean opening,(x->>'estimate')::boolean estimate,
   jsonb_agg(x order by n) posts
  from jsonb_array_elements(c->'posts') with ordinality v(x,n) group by 1,2,3,4,5
 loop
  with raw as (
   select x->>'account' account,x->>'business_category' business,
    -- Product/FIFO attribution belongs to immutable acquisition/issue evidence.
    -- Keep real wallets and counterparty/asset/custody identities where meaningful.
    case when x->>'account' not in ('inventory_lpg','inventory_stove','cogs','inventory_loss',
     'sales_revenue','logistics_revenue','other_income','operating_expense','employee_expense',
     'logistics_expense','vehicle_expense','interest_expense','depreciation_expense',
     'capital','opening_equity','equity_adjustment','withdrawals','business_allocation_equity')
     then (x->>'entity_id')::uuid end entity,
    case
     -- Checkout inventory, its replacement claim and historical transport are
     -- one stock issue. Payment/invoice legs likewise describe one sale.
     when c->>'action'='create_pos_sale' and x->>'account' in ('inventory_lpg','inventory_stove','cogs','bottle_receivable','bottle_exchange') then app_private.system_type('inventory_sale')
     when c->>'action'='create_pos_sale' and x->>'account' in ('cash','customer_receivable') then app_private.system_type('sale')
     when c->>'action'='collect_sale_bottles' and x->>'account' in ('inventory_lpg','inventory_stove','cogs','bottle_receivable','bottle_exchange') then app_private.system_type('bottle_return')
     when c->>'action'='reverse_sale' and x->>'account' in ('inventory_lpg','inventory_stove','cogs','bottle_receivable','bottle_exchange') then app_private.system_type('sale_reversal')
     when c->>'action' in ('receive_purchase','record_purchase_payment') and x->>'account' in ('inventory_lpg','inventory_stove')
      and exists(select 1 from jsonb_array_elements(g.posts) candidate where candidate->>'source'='purchase') then app_private.system_type('purchase')
     when c->>'action' in ('receive_purchase','record_purchase_payment') and x->>'account' in ('inventory_lpg','inventory_stove','inventory_transit') then app_private.system_type('purchase_receipt')
     when c->>'action'='record_purchase_payment' and x->>'account'='supplier_payable'
      and exists(select 1 from jsonb_array_elements(g.posts) candidate where candidate->>'source'='purchase') then app_private.system_type('purchase')
     when c->>'action'='create_custom_transit' and x->>'account'='transport_receivable' then app_private.system_type('transit_revenue')
     when c->>'action'='employee_payment_operation' and x->>'account'='employee_payable'
      and exists(select 1 from jsonb_array_elements(g.posts) candidate where candidate->>'source'='bonus') then app_private.system_type('bonus')
     when c->>'action' in ('transition_transit','save_transit_costs','record_operating_payment','save_service_trip','finalize_service_trip')
      and x->>'account' in ('employee_payable','operating_payable') then app_private.system_type('operating_cost')
     when c->>'action'='accounting_operation' and x->>'account'='other_assets'
      and exists(select 1 from jsonb_array_elements(g.posts) candidate where candidate->>'source'='owner_operation')
      then (select (line->>'type_id')::uuid from jsonb_array_elements(g.posts) candidate
       cross join lateral jsonb_array_elements(candidate->'entries') line where candidate->>'source'='owner_operation' limit 1)
     else (x->>'type_id')::uuid end type_id,x->'details'->>'type_name' type_name,
    (x->>'amount')::numeric amount,(x->>'consolidated_amount')::numeric external_amount
   from jsonb_array_elements(g.posts) v(post) cross join lateral jsonb_array_elements(post->'entries') v2(x)
  ), net as (
   select account,business,entity,type_id,max(type_name) type_name,sum(amount) amount,sum(external_amount) external_amount
   from raw group by 1,2,3,4
  )
  select coalesce(jsonb_agg(app_private.accounting_line(account,amount,business,entity,jsonb_strip_nulls(jsonb_build_object('type_name',type_name)))||
   jsonb_build_object('type_id',type_id,'consolidated_amount',external_amount)
   order by account,business,entity,type_id) filter(where amount<>0 or external_amount<>0),'[]') into lines from net;
  if lines='[]' then continue;end if;
  if exists(select 1 from jsonb_array_elements(lines)x group by x->>'business_category' having sum((x->>'amount')::numeric)<>0)
   or (select sum((x->>'consolidated_amount')::numeric)<>0 from jsonb_array_elements(lines)x)
   then raise exception 'Collected action does not balance';end if;
  select post into p from jsonb_array_elements(g.posts) post
   order by case post->>'source' when 'sale' then 0 when 'purchase' then 1 when 'owner_operation' then 2 when 'transit_revenue' then 3 else 4 end limit 1;
  src:=p->>'source';sid:=(p->>'id')::uuid;
  link:=app_private.financial_source_link(g.tenant,src,sid);
  if link ? 'record_id' then src:=link->>'record_kind';sid:=(link->>'record_id')::uuid;end if;
  if g.salary<>'' then src:='salary_accrual';sid:=g.salary::uuid;end if;
  label:=case c->>'action'
   when 'create_pos_sale' then 'New sale' when 'collect_sale_payment' then 'Customer payment received'
   when 'collect_sale_bottles' then 'Bottles received' when 'reverse_sale' then 'Sale cancelled'
   when 'refund_sale' then 'Customer refunded' when 'dispatch_purchase' then 'Purchase dispatched'
   when 'receive_purchase' then 'Purchase received' when 'set_purchase_rebate' then 'Purchase rebate updated'
   when 'record_purchase_payment' then 'Supplier paid' when 'refund_purchase' then 'Supplier refund received'
   when 'initiate_purchase_cancellation' then 'Purchase cancelled' when 'create_custom_transit' then 'Delivery started'
   when 'transition_transit' then 'Delivery updated' when 'save_transit_costs' then 'Delivery costs updated'
   when 'record_operating_payment' then 'Operating costs settled' when 'save_service_trip' then 'Vehicle service recorded'
   when 'finalize_service_trip' then 'Vehicle service completed' when 'employee_payment_operation' then 'Employee payment recorded'
   when 'save_employee' then 'Salary terms updated' when 'record_financial_entry' then p->>'note'
   when 'save_vehicle' then 'Vehicle recorded' when 'adjust_inventory' then 'Stock adjusted'
   when 'move_wallet_money' then 'Wallet balance adjusted' else p->>'note' end;
  if g.salary<>'' then label:=p->>'note';end if;
  select (started_at at time zone 'Asia/Dhaka')::date into start_day from public.accounting_periods where tenant_id=g.tenant;
  if start_day is null then raise exception 'Accounting opening position is missing';end if;
  if g.occurred_on<start_day then update public.accounting_periods set started_at=g.occurred_on::timestamp at time zone 'Asia/Dhaka' where tenant_id=g.tenant;end if;
  jid:=md5((c->>'id')||g.tenant::text||g.occurred_on::text||g.salary||g.opening::text||g.estimate::text)::uuid;
  insert into public.accounting_journals(tenant_id,journal_id,source,source_id,event_key,occurred_on,description,estimated,is_opening,created_by)
  values(g.tenant,jid,src,sid,encode(uuid_send(jid),'base64'),
   g.occurred_on,label,g.estimate,g.opening,case when g.salary<>'' then null else auth.uid() end);
  insert into public.accounting_lines(tenant_id,journal_id,line_no,account,amount,consolidated_amount,business_category,entity_id,type_id,details)
  select g.tenant,jid,n::integer,x->>'account',(x->>'amount')::numeric,(x->>'consolidated_amount')::numeric,
   x->>'business_category',(x->>'entity_id')::uuid,(x->>'type_id')::uuid,x->'details' from jsonb_array_elements(lines) with ordinality v(x,n);
 end loop;
 perform set_config('lpg.accounting_action','',true);
end $$;

create or replace function app_private.post_journal(t uuid,src text,id uuid,event text,d date,note text,entries jsonb,estimate boolean default false,opening_entry boolean default false)
returns uuid language plpgsql set search_path='' as $$
declare c jsonb;standalone boolean;result uuid;
begin
 if jsonb_typeof(entries) is distinct from 'array' then raise exception 'Journal lines are required';end if;
 entries:=app_private.dimension_entries(t,src,id,entries);
 if exists(select 1 from jsonb_array_elements(entries)x where x->>'type_id' is null) then raise exception 'Unclassified accounting source: %',src;end if;
 if (select coalesce(sum((x->>'amount')::numeric),0)<>0 or coalesce(sum((x->>'consolidated_amount')::numeric),0)<>0 from jsonb_array_elements(entries)x)
  then raise exception 'Unbalanced accounting source: %',src;end if;
 if entries='[]' then return null;end if;
 if d is null or not isfinite(d) then raise exception 'A finite accounting date is required';end if;
 -- Acquire the original source -> snapshot -> downstream-wallet lock order now,
 -- rather than deferring this lock until final journal insertion.
 insert into app_private.accounting_snapshot_state(tenant_id,invalid_from) values(t,d)
  on conflict(tenant_id) do update set invalid_from=least(app_private.accounting_snapshot_state.invalid_from,excluded.invalid_from),changed_at=clock_timestamp()
  where app_private.accounting_snapshot_state.invalid_from>excluded.invalid_from;
 perform 1 from app_private.accounting_snapshot_state where tenant_id=t for update;
 c:=nullif(current_setting('lpg.accounting_action',true),'')::jsonb;standalone:=c is null;
 if standalone then perform app_private.begin_accounting_action(src);c:=current_setting('lpg.accounting_action')::jsonb;end if;
 c:=jsonb_set(c,'{posts}',(c->'posts')||jsonb_build_array(jsonb_build_object('tenant',t,'source',src,'id',id,
  'event',event,'date',d,'note',note,'entries',entries,'estimate',estimate,'opening',opening_entry)));
 perform set_config('lpg.accounting_action',c::text,true);
 result:=md5((c->>'id')||t::text||d::text||case when src='salary_accrual' then id::text else '' end||opening_entry::text||estimate::text)::uuid;
 if standalone then perform app_private.finish_accounting_action();end if;
 return result;
end $$;

-- An interrupted/unbalanced collector can never commit a source without a journal.
create function app_private.check_accounting_collector() returns trigger
language plpgsql set search_path='' as $$begin
 if nullif(current_setting('lpg.accounting_action',true),'') is not null then raise exception 'Financial action was not finalized';end if;
 return null;
end $$;
create constraint trigger accounting_collector_guard after insert or update on app_private.accounting_source_state
 deferrable initially deferred for each row execute function app_private.check_accounting_collector();
create constraint trigger accounting_collector_guard after insert on public.wallet_transactions
 deferrable initially deferred for each row execute function app_private.check_accounting_collector();
create constraint trigger accounting_collector_guard after insert on app_private.purchase_rebate_events
 deferrable initially deferred for each row execute function app_private.check_accounting_collector();
create constraint trigger accounting_collector_guard after insert on public.finance_requests
 deferrable initially deferred for each row execute function app_private.check_accounting_collector();

-- Preserve the existing implementation and authorization in one private function;
-- the public contract adds exactly one action boundary, with no legacy path.
do $$declare r record;definition text;args text;call_args text;request_arg text;wrapper text;schema_name text;new_name text;
begin
 for r in select p.*,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where (n.nspname='public' and p.proname=any(array[
   'accounting_operation','adjust_inventory','collect_sale_bottles','collect_sale_payment','create_custom_transit',
   'create_pos_sale','create_purchase','dispatch_purchase','employee_payment_operation','finalize_service_trip',
   'initiate_purchase_cancellation','move_wallet_money','receive_purchase','record_financial_entry',
   'record_operating_payment','record_purchase_payment','refund_purchase','refund_sale','reverse_sale',
   'save_employee','save_service_trip','save_transit_costs','save_vehicle','set_purchase_rebate',
   'transition_transit','update_purchase','set_product_buying_price']))
   or (n.nspname='app_private' and p.proname='sync_payroll')
 loop
  definition:=pg_get_functiondef(r.oid);args:=pg_get_function_identity_arguments(r.oid);
  select string_agg(quote_ident(a),',' order by i) into call_args from unnest(r.proargnames) with ordinality v(a,i);
  request_arg:=case when 'p_request_id'=any(r.proargnames) then 'p_request_id' else 'null::uuid' end;
  new_name:='action_'||r.proname;
  execute format('alter function %I.%I(%s) rename to %I',r.nspname,r.proname,args,new_name);
  if r.nspname='public' then execute format('alter function public.%I(%s) set schema app_private',new_name,args);end if;
  execute format('revoke all on function app_private.%I(%s) from public,anon,authenticated',new_name,args);
  wrapper:=format(E'declare result %s;begin\n perform app_private.begin_accounting_action(%L,%s);\n %s app_private.%I(%s);\n perform app_private.finish_accounting_action();\n %s\nend',
   case when r.prorettype='void'::regtype then 'jsonb' else pg_get_function_result(r.oid) end,r.proname,request_arg,
   case when r.prorettype='void'::regtype then 'perform' else 'result:=' end,new_name,call_args,
   case when r.prorettype='void'::regtype then 'return;' else 'return result;' end);
  -- Function arguments/defaults/security settings are retained from the original.
  definition:=regexp_replace(definition,'AS \$function\$[\s\S]*\$function\$[;\s]*$', 'AS $function$'||wrapper||'$function$;');
  execute definition;
  execute format('alter function %I.%I(%s) owner to %I',r.nspname,r.proname,args,pg_get_userbyid(r.proowner));
  if r.nspname='public' then execute format('revoke all on function public.%I(%s) from public,anon',r.proname,args);
   execute format('grant execute on function public.%I(%s) to authenticated',r.proname,args);
  else execute format('revoke all on function app_private.%I(%s) from public,anon,authenticated',r.proname,args);end if;
 end loop;
end $$;

revoke all on function app_private.begin_accounting_action(text,uuid),app_private.finish_accounting_action(),app_private.check_accounting_collector() from public,anon,authenticated;
do $$declare owner_name text;signature text;begin
 select pg_get_userbyid(proowner) into owner_name from pg_proc where oid='app_private.post_journal(uuid,text,uuid,text,date,text,jsonb,boolean,boolean)'::regprocedure;
 foreach signature in array array['app_private.begin_accounting_action(text,uuid)','app_private.finish_accounting_action()','app_private.check_accounting_collector()'] loop
  execute format('alter function %s owner to %I',signature,owner_name);
 end loop;
end $$;

-- Dependent source reads no longer depend on product-specific journal lines.
CREATE OR REPLACE FUNCTION app_private.financial_source_link(t uuid, src text, id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$declare
 k text;ref uuid:=id;x public.wallet_transactions;m public.inventory_movements;cost_event public.operating_cost_events;result_id uuid;begin
 if src in ('transit','service_trip','employee','financial_entry','product','asset','loan') then k:=src;
 elsif src in ('sale','sale_bottle_claim_reversal','sale_exchange_reversal') then k:='sale';
 elsif src in ('purchase','purchase_rebate','internal_transport') then k:='purchase';
 elsif src in ('inventory','bottle_obligation','internal_inventory','internal_cogs') then
  select * into m from public.inventory_movements where tenant_id=t and movement_id=id;
  ref:=m.reference_id;k:=case when m.reference_type in ('sale','sale_reversal') then 'sale' when m.reference_type like '%purchase%' then 'purchase' else 'product' end;if k='product' then ref:=m.item_id;end if;
 elsif src='transit_revenue' then k:='transit';
 elsif src='operating_cost' then select * into cost_event from public.operating_cost_events where tenant_id=t and event_id=id;ref:=coalesce(cost_event.transit_id,cost_event.service_trip_id);k:=case when cost_event.service_trip_id is null then 'transit' else 'service_trip' end;
 elsif src='salary_accrual' then select employee_id into ref from app_private.salary_business_allocations where tenant_id=t and source_id=id;k:='employee';
 elsif src='bonus' then select employee_id into ref from public.employee_payments where tenant_id=t and payment_id=id;k:='employee';
 elsif src='owner_operation' then
  select (result->>'id')::uuid into result_id from public.finance_requests where tenant_id=t and request_id=id;ref:=result_id;
  if exists(select 1 from public.business_assets where tenant_id=t and asset_id=ref) then k:='asset';elsif exists(select 1 from public.loans where tenant_id=t and loan_id=ref) then k:='loan';end if;
 elsif src='wallet' then
  select * into x from public.wallet_transactions where tenant_id=t and transaction_id=id;ref:=x.reference_id;
  if x.type in ('pos_sale_income','customer_collection','sale_refund') then k:='sale';
  elsif x.type like 'purchase%' then k:='purchase';
  elsif x.type like 'transit_%' then k:='transit';
  elsif x.type like 'payroll_%' then select p.employee_id into ref from public.employee_payment_entries e join public.employee_payments p using(tenant_id,payment_id) where e.tenant_id=t and e.entry_id=x.employee_entry_id;k:='employee';
  elsif x.type like 'asset_%' then k:='asset';elsif x.type like 'loan_%' then k:='loan';
  elsif x.type='custom_entry' or exists(select 1 from public.financial_entries where tenant_id=t and entry_id=ref) then k:='financial_entry';end if;
 end if;
 return case when k is not null and ref is not null then jsonb_build_object('record_kind',k,'record_id',ref) else '{}'::jsonb end;
end $function$;

-- Source recognition targets retain trip attribution and are updated before a
-- command returns its trip view; financial position still comes from journals.
create or replace function app_private.logistics_result(t uuid,transit_ids uuid[],service_ids uuid[] default '{}'::uuid[])
returns jsonb language sql stable set search_path='' as $$
 with sources as (
  select 'transit_revenue' source,unnest(transit_ids) id,false service
  union select 'operating_cost',e.event_id,e.service_trip_id is not null from public.operating_cost_events e
   where e.tenant_id=t and (e.transit_id=any(transit_ids) or e.service_trip_id=any(service_ids))
 ), facts as (
  select a.kind,(l->>'amount')::numeric amount,s.service from sources s
   join app_private.accounting_source_state state on state.tenant_id=t and state.source=s.source and state.source_id=s.id
   cross join lateral jsonb_array_elements(state.lines)l join public.accounting_accounts a on a.code=l->>'account'
  union all
  select 'income',-settlement.amount,false from app_private.internal_transport_settlements settlement
   where settlement.tenant_id=t and not settlement.reversed and exists(select 1 from public.transits tr
    where tr.tenant_id=t and tr.transit_id=any(transit_ids) and tr.purchase_id=settlement.purchase_id)
 )
 select jsonb_build_object('revenue',coalesce(-sum(amount) filter(where kind='income'),0),
  'transit_expenses',coalesce(sum(amount) filter(where kind='expense' and not service),0),
  'service_expenses',coalesce(sum(amount) filter(where kind='expense' and service),0),
  'profit',coalesce(-sum(amount) filter(where kind in ('income','expense')),0)) from facts;
$$;

CREATE OR REPLACE FUNCTION app_private.reconcile_record(t uuid, k text, id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare observed jsonb;expected jsonb;safe boolean:=false;note text:='Canonical source comparison';v numeric;v2 numeric;salary_period record;d date;pos jsonb;hash text;begin
 if k='customer' then
  if not exists(select 1 from public.customers where tenant_id=t and customer_id=id) then return false;end if;
  insert into app_private.customer_metrics(tenant_id,customer_id) values(t,id) on conflict do nothing;
  perform 1 from app_private.customer_metrics where tenant_id=t and customer_id=id for update nowait;
  select to_jsonb(c)-'tenant_id'-'customer_id' into observed from app_private.customer_metrics c where tenant_id=t and customer_id=id;
  select jsonb_build_object('ledger_balance',coalesce((select sum(amount) from public.customer_transactions where tenant_id=t and customer_id=id),0),
   'transactions',count(*),'refill',coalesce(sum(q.refill),0),'package',coalesce(sum(q.package),0),
   'total_sold_amount',coalesce(sum(s.total_amount+s.additional_charges),0),'total_due',coalesce(sum(greatest(0,s.total_amount+s.additional_charges-s.paid_amount)),0),'last_transaction_at',max(s.created_at)) into expected
  from public.sales s left join lateral(select coalesce(sum(quantity) filter(where type='refill'),0) refill,coalesce(sum(quantity) filter(where type='package'),0) package from public.sale_items i where i.tenant_id=t and i.sale_id=s.sale_id)q on true
  where s.tenant_id=t and s.customer_id=id and s.status='completed';
  if observed is distinct from expected then
   update app_private.customer_metrics set ledger_balance=(expected->>'ledger_balance')::numeric,transactions=(expected->>'transactions')::bigint,refill=(expected->>'refill')::bigint,package=(expected->>'package')::bigint,total_sold_amount=(expected->>'total_sold_amount')::numeric,total_due=(expected->>'total_due')::numeric,last_transaction_at=(expected->>'last_transaction_at')::timestamptz where tenant_id=t and customer_id=id;
   safe:=found;end if;
 elsif k='wallet' then
  perform 1 from public.wallets where tenant_id=t and wallet_id=id for update nowait;
  if not found then return false;end if;
  select balance,opening_balance+coalesce((select sum(amount) from public.wallet_transactions where tenant_id=t and wallet_id=id),0) into v,v2 from public.wallets where tenant_id=t and wallet_id=id;
  observed:=jsonb_build_object('balance',v,'combined_cash',(select coalesce(sum(balance),0) from public.wallets where tenant_id=t));
  expected:=jsonb_build_object('balance',v2,'combined_cash',(select coalesce(sum(amount),0) from public.accounting_lines where tenant_id=t and account='cash'));
  -- A wallet is reconciled to its own ledger; only the pooled total is compared
  -- with journal Cash. Treasury transfers deliberately have no business journal.
  if v<>v2 and (select coalesce(sum(opening_balance),0)+coalesce((select sum(amount) from public.wallet_transactions where tenant_id=t),0) from public.wallets where tenant_id=t)=(expected->>'combined_cash')::numeric then
   update public.wallets set balance=v2 where tenant_id=t and wallet_id=id;safe:=true;
  end if;
 elsif k='inventory' then
  -- Never repair physical stock from a financial discrepancy. Cost evidence and
  -- movement coverage must agree before an operator can investigate a count.
  perform 1 from public.items where tenant_id=t and item_id=id for update nowait;
  if not found then return false;end if;
  perform 1 from public.inventory_costs where tenant_id=t and item_id=id for update nowait;
  select jsonb_build_object('filled',i.filled_quantity,'empty',i.empty_quantity,'pool_filled',c.filled_quantity,'pool_empty',c.empty_quantity,'filled_value',c.filled_value,'empty_value',c.empty_value,'journal_value',c.filled_value+c.empty_value,'missing_movements',0) into observed from public.items i join public.inventory_costs c using(tenant_id,item_id) where i.tenant_id=t and i.item_id=id;
  select jsonb_build_object('filled',coalesce(sum(filled_change),0),'empty',coalesce(sum(empty_change),0),'pool_filled',coalesce(sum(filled_change),0),'pool_empty',coalesce(sum(empty_change),0),'filled_value',coalesce(sum(filled_value),0),'empty_value',coalesce(sum(empty_value),0),
   'journal_value',coalesce((select sum(filled_value+empty_value) from public.inventory_cost_entries where tenant_id=t and item_id=id),0),
   'missing_movements',(select count(*) from public.inventory_movements m where m.tenant_id=t and m.item_id=id and not exists(select 1 from public.inventory_cost_entries e where e.tenant_id=t and e.movement_id=m.movement_id))) into expected from public.inventory_cost_entries where tenant_id=t and item_id=id;
 observed:=observed||jsonb_build_object('fifo_consistent',
  not exists(select 1 from app_private.fifo_layers l left join lateral(select coalesce(sum(x.quantity),0) q,coalesce(sum(x.value),0) v,coalesce(sum(x.shell_value),0) s,coalesce(sum(x.internal_value),0) iv,coalesce(sum(x.internal_shell_value),0) ish from app_private.fifo_consumptions x where x.tenant_id=t and x.layer_id=l.layer_id)x on true where l.tenant_id=t and l.item_id=id and (l.quantity<>l.remaining+x.q or l.value<>l.remaining_value+x.v or l.shell_value<>l.remaining_shell_value+x.s or l.internal_value<>l.remaining_internal_value+x.iv or l.internal_shell_value<>l.remaining_internal_shell_value+x.ish))
  and coalesce((select c.filled_quantity=x.f and c.empty_quantity=x.e and c.filled_value=x.fv and c.empty_value=x.ev from public.inventory_costs c cross join lateral(select coalesce(sum(remaining) filter(where component='filled'),0) f,coalesce(sum(remaining) filter(where component='empty'),0) e,coalesce(sum(remaining_value) filter(where component='filled'),0) fv,coalesce(sum(remaining_value) filter(where component='empty'),0) ev from app_private.fifo_layers where tenant_id=t and item_id=id and remaining>0)x where c.tenant_id=t and c.item_id=id),true));
 expected:=expected||jsonb_build_object('fifo_consistent',true);
 observed:=observed||jsonb_build_object('inventory_control',coalesce((select sum(l.consolidated_amount) from public.accounting_lines l where l.tenant_id=t and l.account=case when (select business_category from public.items where tenant_id=t and item_id=id)='stove' then 'inventory_stove' else 'inventory_lpg' end),0));
 expected:=expected||jsonb_build_object('inventory_control',coalesce((select sum(c.filled_value+c.empty_value) from public.inventory_costs c join public.items i using(tenant_id,item_id) where c.tenant_id=t and i.business_category=(select business_category from public.items where tenant_id=t and item_id=id)),0));
 observed:=observed||jsonb_build_object('full_inventory_control',coalesce((select sum(l.amount) from public.accounting_lines l where l.tenant_id=t and l.account=case when (select business_category from public.items where tenant_id=t and item_id=id)='stove' then 'inventory_stove' else 'inventory_lpg' end),0));
 expected:=expected||jsonb_build_object('full_inventory_control',coalesce((select sum(c.filled_value+c.empty_value+coalesce((select sum(l.remaining_internal_value) from app_private.fifo_layers l where l.tenant_id=c.tenant_id and l.item_id=c.item_id),0)) from public.inventory_costs c join public.items i using(tenant_id,item_id) where c.tenant_id=t and i.business_category=(select business_category from public.items where tenant_id=t and item_id=id)),0));
 elsif k='loan' then
  perform 1 from public.loans where tenant_id=t and loan_id=id for update nowait;
  if not found then return false;end if;
  select jsonb_build_object('outstanding',outstanding) into observed from public.loans where tenant_id=t and loan_id=id;
  select jsonb_build_object('outstanding',principal-coalesce((select sum(amount) from public.loan_activity where tenant_id=t and loan_id=id and action in ('principal repayment','repayment received')),0)) into expected from public.loans where tenant_id=t and loan_id=id;
 elsif k='asset' then
  perform 1 from public.business_assets where tenant_id=t and asset_id=id for update nowait;
  if not found then return false;end if;
  select jsonb_build_object('book_value',case when status='active' then cost-accumulated_depreciation else 0 end) into observed from public.business_assets where tenant_id=t and asset_id=id;
  select jsonb_build_object('book_value',coalesce(sum(amount),0)) into expected from public.accounting_lines where tenant_id=t and entity_id=id and account in ('vehicles','equipment','other_assets');
 elsif k='obligation' then
  perform 1 from public.finance_obligations where tenant_id=t and obligation_id=id for update nowait;
  if not found then return false;end if;
  select jsonb_build_object('settled',settled) into observed from public.finance_obligations where tenant_id=t and obligation_id=id;
  select jsonb_build_object('settled',coalesce(sum(abs(amount)),0)) into expected from public.wallet_transactions where tenant_id=t and reference_id=id and type='obligation_settlement';
 elsif k='payroll' then
  perform 1 from public.employees where tenant_id=t and employee_id=id for update nowait;
  if not found then return false;end if;
  -- Compare each actual payment header with its immutable wallet allocations.
  select jsonb_build_object('payments',coalesce(sum(amount),0)) into observed from public.employee_payments where tenant_id=t and employee_id=id;
  select jsonb_build_object('payments',coalesce(sum(e.amount),0)) into expected from public.employee_payment_entries e join public.employee_payments p using(tenant_id,payment_id) where p.tenant_id=t and p.employee_id=id;
  for salary_period in select date_trunc('month',x)::date period from generate_series((select min(effective_from)::timestamp from public.employee_terms where tenant_id=t and employee_id=id),date_trunc('month',now() at time zone 'Asia/Dhaka'),'1 month')x loop
   v:=(app_private.employee_month_balance(t,id,salary_period.period)->>'salary_amount')::numeric;
   v2:=coalesce((select sum(l.amount) from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where j.tenant_id=t and j.source='salary_accrual' and j.source_id=md5(id::text||salary_period.period::text)::uuid and l.account='employee_expense'),0);
   if v<>v2 then observed:=observed||jsonb_build_object(salary_period.period::text,v2);expected:=expected||jsonb_build_object(salary_period.period::text,v);end if;
  end loop;
 elsif k='sale' then
  perform 1 from public.sales where tenant_id=t and sale_id=id for update nowait;
  if not found then return false;end if;
  select jsonb_build_object('recognized_invoice',case when status='completed' then total_amount+additional_charges else 0 end) into expected from public.sales where tenant_id=t and sale_id=id;
  select jsonb_build_object('recognized_invoice',coalesce(sum((l->>'amount')::numeric),0)) into observed from app_private.accounting_source_state s cross join lateral jsonb_array_elements(s.lines)l where s.tenant_id=t and s.source='sale' and s.source_id=id and l->>'account'='customer_receivable';
 elsif k='purchase' then
  perform 1 from public.purchases where tenant_id=t and purchase_id=id for update nowait;
  if not found then return false;end if;
  select jsonb_build_object('recognized_invoice',case when status in ('in_transit','received') then payable_amount else 0 end) into expected from public.purchases where tenant_id=t and purchase_id=id;
  select jsonb_build_object('recognized_invoice',coalesce(-sum((l->>'amount')::numeric),0)) into observed from app_private.accounting_source_state s cross join lateral jsonb_array_elements(s.lines)l where s.tenant_id=t and s.source='purchase' and s.source_id=id and l->>'account'='supplier_payable';
 elsif k='transit' then
  perform 1 from public.transits where tenant_id=t and transit_id=id for update nowait;
  if not found then return false;end if;
  select jsonb_build_object('earned_revenue',case when purchase_id is null and status<>'cancelled' then transport_fee else 0 end,
   'incurred_costs',coalesce((select sum(amount) from public.operating_cost_events where tenant_id=t and transit_id=id),0)) into expected from public.transits where tenant_id=t and transit_id=id;
  select jsonb_build_object('earned_revenue',coalesce((select -sum((l->>'amount')::numeric) from app_private.accounting_source_state s cross join lateral jsonb_array_elements(s.lines)l where s.tenant_id=t and s.source='transit_revenue' and s.source_id=id and l->>'account'='logistics_revenue'),0),
   'incurred_costs',coalesce((select sum((l->>'amount')::numeric) from public.operating_cost_events e join app_private.accounting_source_state s on s.tenant_id=e.tenant_id and s.source='operating_cost' and s.source_id=e.event_id cross join lateral jsonb_array_elements(s.lines)l join public.accounting_accounts a on a.code=l->>'account' where e.tenant_id=t and e.transit_id=id and a.kind='expense'),0)) into observed;
 elsif k='journal' then
  select jsonb_build_object('imbalance',coalesce(sum(amount),0),'has_lines',count(*)>0) into observed from public.accounting_lines where tenant_id=t and journal_id=id;
  expected:=jsonb_build_object('imbalance',0,'has_lines',true);
 elsif k='snapshot' then
  -- Validate one month per queue item; requeue the next month through its audit
  -- revision in the sweep. Exact rows, not just the equation, must agree.
  select min(month_end) into d from app_private.accounting_snapshots s where s.tenant_id=t and md5(s.month_end::text)::uuid=id;
  if d is null then return false;end if;
  if exists(select 1 from app_private.accounting_snapshot_state where tenant_id=t and invalid_from<=d) then return false;end if;
  select checksum into hash from app_private.accounting_snapshots where tenant_id=t and month_end=d;
  observed:=jsonb_build_object('checksum',hash,'difference',0);
  with full_history as(select l.account,l.business_category,l.entity_id,l.type_id,sum(l.amount) amount,sum(l.consolidated_amount) consolidated_amount from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where j.tenant_id=t and j.occurred_on<=d group by 1,2,3,4),
 diff as(select * from full_history except select account,business_category,entity_id,type_id,amount,consolidated_amount from app_private.accounting_snapshot_lines where tenant_id=t and month_end=d),
 reverse_diff as(select account,business_category,entity_id,type_id,amount,consolidated_amount from app_private.accounting_snapshot_lines where tenant_id=t and month_end=d except select * from full_history)
 select jsonb_build_object('checksum',md5(coalesce((select string_agg(concat_ws(':',account,business_category,entity_id,type_id,amount,consolidated_amount),'|' order by account,business_category,entity_id,type_id) from full_history),'')),'difference',(select count(*) from diff)+(select count(*) from reverse_diff)) into expected;
  if observed is distinct from expected then update app_private.accounting_snapshot_state set invalid_from=least(invalid_from,d) where tenant_id=t;note:='Savepoint invalidated; canonical journals remain unchanged';end if;
 else raise exception 'Unknown reconciliation kind';end if;
 if observed is null and expected is null then return false;end if;
 if observed is distinct from expected then
  insert into app_private.reconciliation_findings(tenant_id,kind,entity_id,observed,expected,status,diagnostic) values(t,k,id,coalesce(observed,'null'),coalesce(expected,'null'),case when safe then 'repaired' else 'unresolved' end,note);return true;
 end if;return false;end $function$;

CREATE OR REPLACE FUNCTION public.get_inventory_cost_history(p_item_id uuid, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['inventory:view','inventory:manage','finance:view','finance:manage']);r jsonb;begin
 if p_offset is null or p_offset<0 then raise exception 'Invalid page';end if;
 select jsonb_build_object('pool',(select to_jsonb(c)||jsonb_build_object('internal_value',coalesce((select sum(remaining_internal_value) from app_private.fifo_layers where tenant_id=t and item_id=p_item_id and remaining_internal_value<>0),0)) from public.inventory_costs c where tenant_id=t and item_id=p_item_id),
 'total',(select count(*) from public.inventory_cost_entries where tenant_id=t and item_id=p_item_id),
 'entries',coalesce((select jsonb_agg(to_jsonb(e)||jsonb_build_object('internal_value',coalesce((select sum((l->>'amount')::numeric) from app_private.accounting_source_state s cross join lateral jsonb_array_elements(s.lines)l where s.tenant_id=t and s.source in ('internal_inventory','internal_cogs') and s.source_id=e.movement_id and l->>'account' in ('inventory_lpg','inventory_stove')),0))) from(select * from public.inventory_cost_entries where tenant_id=t and item_id=p_item_id order by created_at desc,entry_id desc offset p_offset limit 10)e),'[]')) into r;return r;end $function$;

-- Bottle settlement uses the original FIFO shell evidence, never journal fragments.
CREATE OR REPLACE FUNCTION app_private.fifo_cost_movement(m inventory_movements)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
 c public.inventory_costs;old_cost app_private.fifo_movement_costs;p public.purchases;
 cat text;account text;counter text:='cogs';fc numeric:=0;ec numeric:=0;shell numeric:=0;iv numeric:=0;isv numeric:=0;
 gas_value numeric:=0;gas_internal numeric:=0;bottle_value numeric:=0;bottle_internal numeric:=0;
 gas_piece numeric;gas_internal_piece numeric;basis numeric:=0;variance numeric:=0;expected integer;prior_qty integer;counted integer:=0;slice integer:=0;
 lines jsonb;batch record;component record;f_after numeric;e_after numeric;
 d date:=(m.created_at at time zone 'Asia/Dhaka')::date;
begin
 select * into c from public.inventory_costs where tenant_id=m.tenant_id and item_id=m.item_id for update;
 select business_category into cat from public.items where tenant_id=m.tenant_id and item_id=m.item_id;
 account:=case when cat='stove' then 'inventory_stove' else 'inventory_lpg' end;
 select * into old_cost from app_private.fifo_movement_costs where tenant_id=m.tenant_id and movement_id=m.movement_id;
 if m.reference_type in ('sale_reversal','stove_purchase_cancellation') then
  -- Only the exact incoming customer/receipt batches may be returned.
  if m.empty_quantity_change<0 or m.reference_type='stove_purchase_cancellation' then
   for batch in select l.* from app_private.fifo_layers l join public.inventory_movements im using(tenant_id,movement_id)
    where l.tenant_id=m.tenant_id and l.item_id=m.item_id and im.reference_id=m.reference_id
    and ((m.reference_type='sale_reversal' and im.reference_type='sale' and im.empty_quantity_change>0 and l.component='empty')
      or (m.reference_type='stove_purchase_cancellation' and im.reference_type='stove_purchase_receipt'))
    order by l.acquired_at,l.acquired_order,l.slice_no for update of l loop
    if batch.remaining<>batch.quantity or batch.remaining_value<>batch.value or batch.remaining_internal_value<>batch.internal_value then raise exception 'The original received batch has been consumed or changed; cancellation cannot substitute other stock';end if;
    counted:=counted+batch.quantity;
    if batch.component='empty' then ec:=ec-batch.remaining_value;else fc:=fc-batch.remaining_value;end if;
    insert into app_private.fifo_consumptions(tenant_id,movement_id,layer_id,quantity,value,shell_value,internal_value,internal_shell_value) values(m.tenant_id,m.movement_id,batch.layer_id,batch.quantity,batch.value,batch.shell_value,batch.internal_value,batch.internal_shell_value);
    update app_private.fifo_layers set remaining=0,remaining_value=0,remaining_shell_value=0,remaining_internal_value=0,remaining_internal_shell_value=0 where tenant_id=m.tenant_id and layer_id=batch.layer_id;
   end loop;
   if counted<>(case when m.reference_type='sale_reversal' then -m.empty_quantity_change else -m.filled_quantity_change end) then raise exception 'Original received quantity does not reconcile';end if;
  end if;
  if m.reference_type='sale_reversal' then
   for batch in select x.* from app_private.fifo_consumptions x join public.inventory_movements im on im.tenant_id=x.tenant_id and im.movement_id=x.movement_id join app_private.fifo_layers l on l.tenant_id=x.tenant_id and l.layer_id=x.layer_id
    where im.tenant_id=m.tenant_id and im.item_id=m.item_id and im.reference_id=m.reference_id and im.reference_type='sale' and im.filled_quantity_change<0 and l.component='filled' loop
    fc:=fc+batch.value;
    update app_private.fifo_layers set remaining=remaining+batch.quantity,remaining_value=remaining_value+batch.value,remaining_shell_value=remaining_shell_value+batch.shell_value,remaining_internal_value=remaining_internal_value+batch.internal_value,remaining_internal_shell_value=remaining_internal_shell_value+batch.internal_shell_value where tenant_id=m.tenant_id and layer_id=batch.layer_id;
    insert into app_private.fifo_consumptions(tenant_id,movement_id,layer_id,quantity,value,shell_value,internal_value,internal_shell_value) values(m.tenant_id,m.movement_id,batch.layer_id,-batch.quantity,-batch.value,-batch.shell_value,-batch.internal_value,-batch.internal_shell_value);
   end loop;
  else counter:='inventory_transit';end if;
 else
  if m.filled_quantity_change<0 then fc:=-app_private.fifo_take(m.tenant_id,m.item_id,m.movement_id,'filled',-m.filled_quantity_change);end if;
  if m.empty_quantity_change<0 then ec:=-app_private.fifo_take(m.tenant_id,m.item_id,m.movement_id,'empty',-m.empty_quantity_change);end if;
  if m.reference_type in ('purchase_receipt','stove_purchase_receipt') then
   select * into p from public.purchases where tenant_id=m.tenant_id and purchase_id=m.reference_id;
   for component in select * from app_private.purchase_components(m.tenant_id,m.reference_id) where item_id=m.item_id loop
    if component.component='bottle' then bottle_value:=component.invoice_value+component.labour_value;bottle_internal:=component.transport_value;
    else gas_value:=component.invoice_value+component.labour_value;gas_internal:=component.transport_value;end if;
   end loop;
   fc:=gas_value+bottle_value;counter:='inventory_transit';
   if cat='lpg' then
    -- Dispatched bottles retain their original source and age in linked slices.
    for batch in select x.*,l.acquired_at,l.shell_acquired_at,l.shell_source_movement_id,l.movement_id source_movement from app_private.fifo_consumptions x
     join app_private.fifo_layers l using(tenant_id,layer_id) join public.inventory_movements im on im.tenant_id=x.tenant_id and im.movement_id=x.movement_id
     where im.tenant_id=m.tenant_id and im.item_id=m.item_id and im.reference_id=m.reference_id and im.reference_type='purchase_dispatch'
     order by l.acquired_at,l.acquired_order,l.slice_no loop
     gas_piece:=round(gas_value*(counted+batch.quantity)/m.filled_quantity_change,2)-round(gas_value*counted/m.filled_quantity_change,2);
     gas_internal_piece:=round(gas_internal*(counted+batch.quantity)/m.filled_quantity_change,2)-round(gas_internal*counted/m.filled_quantity_change,2);
     perform app_private.fifo_component_layer(m.tenant_id,m.item_id,m.movement_id,'filled',m.created_at,batch.quantity,gas_piece+batch.value,batch.value,gas_internal_piece+batch.internal_value,batch.internal_value,slice,coalesce(batch.shell_source_movement_id,batch.source_movement),coalesce(batch.shell_acquired_at,batch.acquired_at));
     counted:=counted+batch.quantity;slice:=slice+1;fc:=fc+batch.value;
    end loop;
    select bottle_quantity into expected from public.purchase_items where tenant_id=m.tenant_id and purchase_id=m.reference_id and item_id=m.item_id;
    if counted+expected<>m.filled_quantity_change then raise exception 'Received filled units do not match dispatched and newly purchased bottle evidence';end if;
    if expected>0 then
     perform app_private.fifo_component_layer(m.tenant_id,m.item_id,m.movement_id,'filled',m.created_at,expected,gas_value-round(gas_value*counted/m.filled_quantity_change,2)+bottle_value,bottle_value,gas_internal-round(gas_internal*counted/m.filled_quantity_change,2)+bottle_internal,bottle_internal,slice);
    end if;
   else perform app_private.fifo_component_layer(m.tenant_id,m.item_id,m.movement_id,'filled',m.created_at,m.filled_quantity_change,fc,0,gas_internal,0);end if;
  elsif m.reference_type='purchase_dispatch' then counter:='inventory_transit';
  elsif m.reference_type='purchase_cancellation' then
   counter:='inventory_transit';
   for batch in select x.* from app_private.fifo_consumptions x join public.inventory_movements im on im.tenant_id=x.tenant_id and im.movement_id=x.movement_id where im.tenant_id=m.tenant_id and im.item_id=m.item_id and im.reference_id=m.reference_id and im.reference_type='purchase_dispatch' loop
    ec:=ec+batch.value;counted:=counted+batch.quantity;
    update app_private.fifo_layers set remaining=remaining+batch.quantity,remaining_value=remaining_value+batch.value,remaining_shell_value=remaining_shell_value+batch.shell_value,remaining_internal_value=remaining_internal_value+batch.internal_value,remaining_internal_shell_value=remaining_internal_shell_value+batch.internal_shell_value where tenant_id=m.tenant_id and layer_id=batch.layer_id;
    insert into app_private.fifo_consumptions(tenant_id,movement_id,layer_id,quantity,value,shell_value,internal_value,internal_shell_value) values(m.tenant_id,m.movement_id,batch.layer_id,-batch.quantity,-batch.value,-batch.shell_value,-batch.internal_value,-batch.internal_shell_value);
   end loop;
   if counted<>m.empty_quantity_change then raise exception 'Dispatched bottle quantity does not reconcile';end if;
  elsif m.valuation->>'counter_account' is not null then
   counter:=m.valuation->>'counter_account';
   if counter not in ('opening_equity','inventory_loss','other_income','capital') then raise exception 'Invalid stock adjustment classification';end if;
   if m.filled_quantity_change>0 then
    fc:=round(m.filled_quantity_change*app_private.purchase_money((m.valuation->>'filled_unit_cost')::numeric),2);
    shell:=case when cat='lpg' then round(m.filled_quantity_change*app_private.purchase_money((m.valuation->>'filled_shell_unit_cost')::numeric),2) else 0 end;
    perform app_private.fifo_component_layer(m.tenant_id,m.item_id,m.movement_id,'filled',m.created_at,m.filled_quantity_change,fc,shell,0,0);
   end if;
   if m.empty_quantity_change>0 then ec:=round(m.empty_quantity_change*app_private.purchase_money((m.valuation->>'empty_unit_cost')::numeric),2);end if;
  elsif m.reference_type='sale' then
   if m.filled_quantity_change<0 and cat='lpg' and m.valuation->>'sale_type'='refill' then
    select coalesce(sum(x.shell_value),0),coalesce(sum(x.internal_shell_value),0) into shell,isv from app_private.fifo_consumptions x where x.tenant_id=m.tenant_id and x.movement_id=m.movement_id;
    perform app_private.sync_journal(m.tenant_id,'bottle_obligation',m.movement_id,d,'Historical bottle replacement claim',jsonb_build_array(app_private.accounting_line('bottle_receivable',shell+isv,'lpg',m.reference_id)||jsonb_build_object('consolidated_amount',shell),app_private.accounting_line('cogs',-shell-isv,'lpg')||jsonb_build_object('consolidated_amount',-shell)));
   end if;
   if m.empty_quantity_change>0 then
    ec:=round(m.empty_quantity_change*app_private.purchase_money((m.valuation->>'bottle_unit_cost')::numeric),2);
    select coalesce(sum(quantity),0) into expected from public.sale_items where tenant_id=m.tenant_id and sale_id=m.reference_id and type='empty_return';
    select coalesce(sum(empty_quantity_change),0) into prior_qty from public.inventory_movements where tenant_id=m.tenant_id and reference_type='sale' and reference_id=m.reference_id and empty_quantity_change>0 and (created_at,movement_no)<(m.created_at,m.movement_no);
    select coalesce(sum(x.shell_value+x.internal_shell_value),0),coalesce(sum(x.shell_value),0) into shell,gas_value from app_private.fifo_consumptions x join public.inventory_movements issued using(tenant_id,movement_id) where x.tenant_id=m.tenant_id and issued.reference_type='sale' and issued.reference_id=m.reference_id and issued.filled_quantity_change<0 and issued.valuation->>'sale_type'='refill';
    basis:=case when expected>0 then round(shell*least(expected,prior_qty+m.empty_quantity_change)/expected,2)-round(shell*least(expected,prior_qty)/expected,2) else 0 end;
    gas_value:=case when expected>0 then round(gas_value*least(expected,prior_qty+m.empty_quantity_change)/expected,2)-round(gas_value*least(expected,prior_qty)/expected,2) else 0 end;
    lines:=jsonb_build_array(app_private.accounting_line(account,ec,cat,m.item_id),app_private.accounting_line('bottle_receivable',-basis,cat,m.reference_id)||jsonb_build_object('consolidated_amount',-gas_value),app_private.accounting_line('bottle_exchange',basis-ec,cat,m.reference_id)||jsonb_build_object('consolidated_amount',gas_value-ec));
   end if;
  else raise exception 'Stock movement requires recorded acquisition evidence';end if;
  if m.empty_quantity_change>0 and m.reference_type<>'purchase_cancellation' then perform app_private.fifo_component_layer(m.tenant_id,m.item_id,m.movement_id,'empty',m.created_at,m.empty_quantity_change,ec,ec,0,0);end if;
 end if;
 if fc is null or ec is null then raise exception 'Missing FIFO acquisition evidence';end if;
 f_after:=c.filled_value+fc;e_after:=c.empty_value+ec;
 update public.inventory_costs set filled_quantity=filled_quantity+m.filled_quantity_change,empty_quantity=empty_quantity+m.empty_quantity_change,filled_value=f_after,empty_value=e_after where tenant_id=m.tenant_id and item_id=m.item_id;
 if old_cost.movement_id is null then
  insert into public.inventory_cost_entries(tenant_id,item_id,movement_id,occurred_on,filled_change,empty_change,filled_value,empty_value,filled_after,empty_after,reason,estimated,created_by)
  values(m.tenant_id,m.item_id,m.movement_id,d,m.filled_quantity_change,m.empty_quantity_change,fc,ec,f_after,e_after,coalesce(m.notes,'FIFO component carrying cost'),c.estimated,m.created_by);
 elsif old_cost.filled_value<>fc or old_cost.empty_value<>ec then
  insert into public.inventory_cost_entries(tenant_id,item_id,occurred_on,filled_change,empty_change,filled_value,empty_value,filled_after,empty_after,reason,estimated,created_by)
  values(m.tenant_id,m.item_id,d,0,0,fc-old_cost.filled_value,ec-old_cost.empty_value,f_after,e_after,'FIFO recalculation of '||m.movement_id,c.estimated,auth.uid());
 end if;
 insert into app_private.fifo_movement_costs values(m.tenant_id,m.movement_id,m.item_id,m.created_at,fc,ec) on conflict(tenant_id,movement_id) do update set filled_value=excluded.filled_value,empty_value=excluded.empty_value;
 if lines is null then lines:=jsonb_build_array(app_private.accounting_line(account,fc+ec,cat,m.item_id),app_private.accounting_line(counter,-fc-ec,cat,m.reference_id));end if;
 perform app_private.sync_journal(m.tenant_id,'inventory',m.movement_id,d,coalesce(m.notes,'FIFO component carrying cost'),lines,counter='opening_equity');
 perform app_private.sync_internal_fifo(m);
end$function$;

CREATE OR REPLACE FUNCTION app_private.sync_sale_bottle_reversal(t uuid, sid uuid, d date)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare claim numeric;consolidated_claim numeric;variance numeric;consolidated_variance numeric;
begin
 select coalesce(sum((l->>'amount')::numeric),0),coalesce(sum(coalesce((l->>'consolidated_amount')::numeric,(l->>'amount')::numeric)),0) into claim,consolidated_claim
 from app_private.accounting_source_state state cross join lateral jsonb_array_elements(state.lines)l
 where state.tenant_id=t and l->>'account'='bottle_receivable' and (l->>'entity_id')::uuid=sid and state.source<>'sale_bottle_claim_reversal';
 perform app_private.sync_journal(t,'sale_bottle_claim_reversal',sid,d,'Cancel historical bottle replacement claim',jsonb_build_array(
  app_private.accounting_line('bottle_receivable',-claim,'lpg',sid)||jsonb_build_object('consolidated_amount',-consolidated_claim),
  app_private.accounting_line('cogs',claim,'lpg')||jsonb_build_object('consolidated_amount',consolidated_claim)));
 select coalesce(sum((l->>'amount')::numeric),0),coalesce(sum(coalesce((l->>'consolidated_amount')::numeric,(l->>'amount')::numeric)),0) into variance,consolidated_variance
 from app_private.accounting_source_state state cross join lateral jsonb_array_elements(state.lines)l
 join public.inventory_movements m on m.tenant_id=state.tenant_id and m.movement_id=state.source_id
 where state.tenant_id=t and l->>'account'='bottle_exchange' and state.source='inventory' and m.reference_type='sale' and m.reference_id=sid;
 perform app_private.sync_journal(t,'sale_exchange_reversal',sid,d,'Reverse cancelled cylinder exchange difference',jsonb_build_array(
  app_private.accounting_line('bottle_exchange',-variance,'lpg',sid)||jsonb_build_object('consolidated_amount',-consolidated_variance),
  app_private.accounting_line('cogs',variance,'lpg')||jsonb_build_object('consolidated_amount',consolidated_variance)));
end$function$;

-- Old product-attributed lines and new control lines share the same inventory asset.
CREATE OR REPLACE FUNCTION app_private.position_from_balances(balances jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
 with b as(select x.tenant_id,x.account,case when x.account in ('cash','inventory_lpg','inventory_stove') then null::uuid else x.entity_id end entity_id,a.name,a.kind,sum(x.amount) balance from jsonb_to_recordset(balances)x(tenant_id uuid,account text,entity_id uuid,amount numeric) join public.accounting_accounts a on a.code=x.account group by 1,2,3,4,5),
 classified as(select *,case when kind='liability' and balance>0 then 'asset' when kind='asset' and account<>'cash' and balance<0 then 'liability' else kind end reported_kind from b),
 s as(select tenant_id,account,name,kind,reported_kind,case when account='cash' then entity_id end entity_id,sum(balance) balance from classified group by 1,2,3,4,5,6)
 select jsonb_build_object('assets',coalesce(sum(s.balance) filter(where reported_kind='asset'),0),'liabilities',coalesce(-sum(s.balance) filter(where reported_kind='liability'),0),
 'equity',coalesce(-sum(s.balance) filter(where s.kind in ('equity','income','expense')),0),'cash',coalesce(sum(s.balance) filter(where account='cash'),0),
 'capital',coalesce(-sum(s.balance) filter(where account in ('capital','opening_equity')),0),
 'revenue',coalesce(-sum(s.balance) filter(where s.kind='income'),0),'expenses',coalesce(sum(s.balance) filter(where s.kind='expense'),0),
 'withdrawals',coalesce(sum(s.balance) filter(where account='withdrawals'),0),'other_equity',coalesce(-sum(s.balance) filter(where account in ('equity_adjustment','business_allocation_equity','retained_earnings')),0),
 'historical_earnings',coalesce(-sum(s.balance) filter(where account='retained_earnings'),0),'accumulated_income',coalesce(-sum(s.balance) filter(where s.kind in ('income','expense')),0),
 'accounts',coalesce(jsonb_agg(jsonb_build_object('tenant_id',s.tenant_id,'account',account,'name',s.name,'kind',reported_kind,'entity_id',s.entity_id,'entity_name',case when account='cash' then 'Pooled business cash' else w.name end,
 'amount',case when reported_kind in ('asset','expense') then s.balance else -s.balance end) order by reported_kind,s.name,s.tenant_id,s.entity_id) filter(where s.balance<>0),'[]'))
 from s left join public.wallets w on w.tenant_id=s.tenant_id and w.wallet_id=s.entity_id and account='cash';$function$;


-- Search product/company/customer evidence at its source, without persisting
-- those dimensions on every journal line or creating another search/event store.
create function app_private.accounting_source_search(t uuid,src text,id uuid)
returns text language plpgsql stable set search_path='' as $$
declare link jsonb:=app_private.financial_source_link(t,src,id);k text;ref uuid;r text;begin
 k:=link->>'record_kind';ref:=(link->>'record_id')::uuid;
 if k='sale' then
  select concat_ws(' ',s.notes,c.name,c.shop_name,c.phone,(select string_agg(concat_ws(' ',b.brand_name,i.product_name,i.size_kg,i.mouth_size),' ') from public.sale_items si join public.items i using(tenant_id,item_id) left join public.lpg_brands b using(tenant_id,brand_id) where si.tenant_id=t and si.sale_id=ref)) into r
  from public.sales s left join public.customers c using(tenant_id,customer_id) where s.tenant_id=t and s.sale_id=ref;
 elsif k='purchase' then
  select concat_ws(' ',p.notes,p.supplier_name,b.brand_name,g.plant_name,(select string_agg(concat_ws(' ',i.product_name,i.size_kg,i.mouth_size),' ') from public.purchase_items pi join public.items i using(tenant_id,item_id) where pi.tenant_id=t and pi.purchase_id=ref)) into r
  from public.purchases p left join public.lpg_brands b using(tenant_id,brand_id) left join public.gas_plants g using(tenant_id,plant_id) where p.tenant_id=t and p.purchase_id=ref;
 elsif k='product' then
  select concat_ws(' ',b.brand_name,i.product_name,i.size_kg,i.mouth_size) into r from public.items i left join public.lpg_brands b using(tenant_id,brand_id) where i.tenant_id=t and i.item_id=ref;
 elsif k='transit' then select concat_ws(' ',tr.destination,v.name,v.serial_no) into r from public.transits tr left join public.vehicles v using(tenant_id,vehicle_id) where tr.tenant_id=t and tr.transit_id=ref;
 elsif k='service_trip' then select concat_ws(' ',s.title,s.expenses::text,v.name,v.serial_no) into r from public.vehicle_service_trips s left join public.vehicles v using(tenant_id,vehicle_id) where s.tenant_id=t and s.service_trip_id=ref;
 elsif k='employee' then select name into r from public.employees where tenant_id=t and employee_id=ref;
 elsif k='loan' then select concat_ws(' ',lender,description) into r from public.loans where tenant_id=t and loan_id=ref;
 elsif k='asset' then select name into r from public.business_assets where tenant_id=t and asset_id=ref;
 elsif k='financial_entry' then select concat_ws(' ',type_name,description) into r from public.financial_entries where tenant_id=t and entry_id=ref;
 end if;
 return coalesce(r,'');
end $$;
revoke all on function app_private.accounting_source_search(uuid,text,uuid) from public,anon,authenticated;
do $$declare owner_name text;begin
 select pg_get_userbyid(proowner) into owner_name from pg_proc where oid='app_private.financial_source_link(uuid,text,uuid)'::regprocedure;
 execute format('alter function app_private.accounting_source_search(uuid,text,uuid) owner to %I',owner_name);
end $$;

-- Activity rows are financial actions; expansion shows their actual posted lines once.
CREATE OR REPLACE FUNCTION public.get_accounting_breakdown(p_filters jsonb, p_group text, p_side text, p_mode text DEFAULT 'components'::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$declare
 ids uuid[]:=app_private.analysis_scope(p_filters);d date:=(p_filters->>'to')::date;f date:=(p_filters->>'from')::date;
 cat text:=coalesce(p_filters->>'category','all');original boolean:=false;before_day boolean:=false;r jsonb;begin
 perform app_private.require_any_permission(array['reports:view','finance:activity']);
 if coalesce(p_filters->>'direction','all') not in ('all','increase','decrease') or coalesce(p_filters->>'sort','newest') not in ('newest','oldest','largest','smallest')
 or nullif(p_filters->>'min','')::numeric<0 or nullif(p_filters->>'max','')::numeric<0
 or nullif(p_filters->>'min','')::numeric>nullif(p_filters->>'max','')::numeric
 or nullif(p_filters->>'history_from','')::date>d then raise exception 'Invalid activity ranges';end if;
 if p_side not in ('opening','closing','period') or p_mode not in ('components','history') or p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100
 or p_group not in ('all','assets','liabilities','equity','accumulated_income','cash','inventory','receivables','fixed_assets','other_assets','dues','employees','other_liabilities','capital','revenue','expenses','withdrawals','other_equity')
 or f is null or d is null or not isfinite(f) or not isfinite(d) or f>d or d>(now() at time zone 'Asia/Dhaka')::date or length(coalesce(p_filters->>'search',''))>500 or cat not in ('all','lpg','stove','logistics') then raise exception 'Invalid breakdown filters';end if;
 if coalesce((p_filters->>'all_time')::boolean,false) then select min((started_at at time zone 'Asia/Dhaka')::date) into f from public.accounting_periods where tenant_id=any(ids);f:=least(f,d);end if;
 if p_side='opening' then before_day:=true;d:=f;original:=coalesce((p_filters->>'all_time')::boolean,false);end if;
 with evidence as(select *,1 sign from app_private.dimensional_balances(ids,d,before_day,original) union all select *,-1 from app_private.dimensional_balances(ids,f,true,coalesce((p_filters->>'all_time')::boolean,false)) where p_side='period'),
 balances as materialized(select b.tenant_id,b.account,b.business_category,b.type_id,
 case when a.kind in ('income','expense','equity') or b.account in ('cash','inventory_lpg','inventory_stove') then null else b.entity_id end entity_id,a.kind,a.name,
 sum(b.sign*b.amount) amount
 from evidence b join public.accounting_accounts a on a.code=b.account where cat='all' or b.business_category=cat group by 1,2,3,4,5,6,7),
 classified as(select *,sum(amount) over(partition by tenant_id,account,entity_id,business_category) control_total,case when kind='liability' and sum(amount) over(partition by tenant_id,account,entity_id,business_category)>0 then 'asset'
 when kind='asset' and account<>'cash' and sum(amount) over(partition by tenant_id,account,entity_id,business_category)<0 then 'liability' else kind end reported_kind from balances),
 selected as materialized(select *,case when p_group='withdrawals' or p_group='all' and account='withdrawals' then 1 when p_group in ('equity','accumulated_income') or reported_kind in ('liability','income','equity') then -1 else 1 end sign
 from classified where (p_group='all' or app_private.analysis_matches(p_group,account,reported_kind))
 and (nullif(p_filters->>'account','') is null or account=p_filters->>'account')
 and (nullif(p_filters->>'type_id','') is null or type_id=(p_filters->>'type_id')::uuid)
 and (nullif(p_filters->>'component_business','') is null or business_category=p_filters->>'component_business')
 and (nullif(p_filters->>'entity_id','') is null or p_filters->>'entity_id'='none' and entity_id is null or entity_id=nullif(nullif(p_filters->>'entity_id',''),'none')::uuid)),
 described as materialized(select s.*,case ft.code when 'internal_inventory' then 'Transport in Supplies' when 'internal_cogs' then 'Transport COGS' when 'internal_transport' then 'Purchase transport' else ft.name end type_name,app_private.analysis_entity(s.tenant_id,s.account,s.entity_id) entity from selected s join public.financial_types ft using(type_id)),
 components as materialized(select * from described where
 (nullif(p_filters->>'min','') is null or abs(amount)>=(p_filters->>'min')::numeric)
 and (nullif(p_filters->>'max','') is null or abs(amount)<=(p_filters->>'max')::numeric)
 and (coalesce(p_filters->>'direction','all')='all' or p_filters->>'direction'='increase' and amount*sign>0 or p_filters->>'direction'='decrease' and amount*sign<0) and amount<>0 and (kind in ('income','expense','equity') or control_total<>0) and app_private.finance_search(concat_ws(' ',name,type_name,business_category,entity->>'entity_name'),coalesce(p_filters->>'search',''))),
 component_page as(select * from components order by abs(amount) desc,tenant_id,account,type_id,business_category,entity_id nulls first offset p_offset limit p_limit),
 movements as materialized(select j.tenant_id,j.journal_id,j.entry_no,j.occurred_on,j.description,j.source,j.source_id,j.source_id transaction_reference,j.estimated,l.line_no,l.account,s.name,l.type_id,coalesce((select max(nullif(snapshot.details->>'type_name','')) from public.accounting_lines snapshot where snapshot.tenant_id=l.tenant_id and snapshot.journal_id=l.journal_id and snapshot.type_id=l.type_id),s.type_name) type_name,l.business_category,l.entity_id,
 (l.amount)*s.sign amount,app_private.analysis_entity(l.tenant_id,l.account,l.entity_id)||app_private.financial_source_link(j.tenant_id,j.source,j.source_id) entity
 from described s join public.accounting_lines l on l.tenant_id=s.tenant_id and l.account=s.account and l.type_id=s.type_id and l.business_category=s.business_category
 and (s.kind in ('income','expense','equity') or s.account in ('cash','inventory_lpg','inventory_stove') or l.entity_id is not distinct from s.entity_id)
 join public.accounting_journals j on j.tenant_id=l.tenant_id and j.journal_id=l.journal_id
 where p_mode='history' and (p_side<>'period' or j.occurred_on>=f) and (case when before_day then j.occurred_on<d or original and j.is_opening and j.occurred_on=d else j.occurred_on<=d end)
 and (nullif(p_filters->>'history_from','') is null or j.occurred_on>=(p_filters->>'history_from')::date)
 and (nullif(p_filters->>'source','') is null or j.source=p_filters->>'source')
 and app_private.finance_search(concat_ws(' ',j.description,s.name,s.type_name,s.business_category,s.entity->>'entity_name',j.source,j.source_id,case when nullif(p_filters->>'search','') is not null then app_private.accounting_source_search(j.tenant_id,j.source,j.source_id) end),coalesce(p_filters->>'search',''))),
 filtered_movements as materialized(select * from movements where
 (coalesce(p_filters->>'direction','all')='all' or p_filters->>'direction'='increase' and amount>0 or p_filters->>'direction'='decrease' and amount<0)),
 grouped_events as materialized(select tenant_id,journal_id,max(entry_no) entry_no,max(occurred_on) occurred_on,max(description) description,max(source) source,
  (array_agg(source_id))[1] source_id,(array_agg(transaction_reference))[1] transaction_reference,bool_or(estimated) estimated,
  0 line_no,(array_agg(account order by line_no))[1] account,
  case when count(distinct account)=1 then max(name) else 'Financial action' end name,
  (array_agg(type_id))[1] type_id,case when count(distinct type_id)=1 then max(type_name) else 'Multiple entry types' end type_name,
  case when count(distinct business_category)=1 then max(business_category) else 'all' end business_category,null::uuid entity_id,
  case when p_group='all' and nullif(p_filters->>'account','') is null
   and nullif(p_filters->>'entity_id','') is null then (select max(abs(account_amount)) from(select sum(effect.amount) account_amount from filtered_movements effect where effect.tenant_id=m.tenant_id and effect.journal_id=m.journal_id group by effect.account) account_totals) else sum(amount) end amount,
  case when p_group='all' and nullif(p_filters->>'account','') is null
   and nullif(p_filters->>'entity_id','') is null then 'value' else 'change' end amount_kind,
  true event_row,count(*) matched_lines,
  (select count(*) from public.accounting_lines l where l.tenant_id=m.tenant_id and l.journal_id=m.journal_id) line_count,
  (jsonb_agg(entity order by case when account in ('customer_receivable','supplier_payable','loan_payable','loan_receivable') then 0 when account='cash' then 9 else 5 end,line_no)->0) entity,
  jsonb_agg(jsonb_build_object('account',account,'name',name,'business_category',business_category,'amount',amount) order by line_no) effects
 from filtered_movements m group by tenant_id,journal_id),
 events as materialized(select * from grouped_events where
 (nullif(p_filters->>'min','') is null or abs(amount)>=(p_filters->>'min')::numeric)
 and (nullif(p_filters->>'max','') is null or abs(amount)<=(p_filters->>'max')::numeric)),
 history_page as(select * from events order by
 case when p_filters->>'sort'='oldest' then occurred_on end asc,
 case when p_filters->>'sort'='largest' then abs(amount) end desc,
 case when p_filters->>'sort'='smallest' then abs(amount) end asc,
 occurred_on desc,entry_no desc,line_no offset p_offset limit p_limit)
 select jsonb_build_object('cutoff',case when before_day and not original then d-1 else d end,'original_opening',original,'accounts',(select jsonb_agg(jsonb_build_object('code',code,'name',name) order by name) from public.accounting_accounts),'sources',coalesce((select jsonb_agg(source order by source) from(select distinct source from public.accounting_journals where tenant_id=any(ids)) sources),'[]'::jsonb),
 'balance',coalesce((select sum(amount*sign) from selected),0),
 'total',case when p_mode='components' then (select count(*) from components) else (select count(*) from events) end,
 'filtered_movement',case when p_mode='history' then (select coalesce(sum(m.amount),0) from filtered_movements m where exists(select 1 from events e where e.tenant_id=m.tenant_id and e.journal_id=m.journal_id)) end,
 'entries',case when p_mode='components' then coalesce((select jsonb_agg(jsonb_build_object('tenant_id',tenant_id,'account',account,'name',name,'kind',reported_kind,'entity_id',entity_id,'type_id',type_id,'type_name',type_name,'business_category',business_category,'amount',amount*sign)||entity order by abs(amount) desc,tenant_id,account,type_id,business_category,entity_id nulls first) from component_page),'[]')
 else coalesce((select jsonb_agg((to_jsonb(p)-'entity')||entity order by case when p_filters->>'sort'='oldest' then occurred_on end asc,case when p_filters->>'sort'='largest' then abs(amount) end desc,case when p_filters->>'sort'='smallest' then abs(amount) end asc,occurred_on desc,entry_no desc,line_no) from history_page p),'[]') end) into r;return r;end $function$;

-- Keep immutable custom-type names in journal and historical expansion.
CREATE OR REPLACE FUNCTION public.get_journal_lines(p_filters jsonb, p_journal_id uuid, p_offset integer DEFAULT 0, p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$declare
 ids uuid[]:=app_private.analysis_scope(p_filters);t uuid;r jsonb;begin
 if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page';end if;
 select tenant_id into t from public.accounting_journals where journal_id=p_journal_id and tenant_id=any(ids);
 if t is null then raise exception 'Journal unavailable' using errcode='42501';end if;
 with page as(select l.line_no,l.account account_code,a.name account,l.amount,l.consolidated_amount,l.business_category,l.type_id,coalesce((select max(nullif(snapshot.details->>'type_name','')) from public.accounting_lines snapshot where snapshot.tenant_id=l.tenant_id and snapshot.journal_id=l.journal_id and snapshot.type_id=l.type_id),case ft.code when 'internal_inventory' then 'Transport in Supplies' when 'internal_cogs' then 'Transport COGS' when 'internal_transport' then 'Purchase transport' else ft.name end) type_name,l.entity_id,
 app_private.analysis_entity(l.tenant_id,l.account,l.entity_id)->>'entity_name' entity_name
 from public.accounting_lines l join public.accounting_accounts a on a.code=l.account join public.financial_types ft using(type_id)
 where l.tenant_id=t and l.journal_id=p_journal_id order by l.line_no offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from public.accounting_lines where tenant_id=t and journal_id=p_journal_id),'entries',coalesce((select jsonb_agg(to_jsonb(p) order by line_no) from page p),'[]')) into r;return r;end $function$;

-- Compact only future maintained replay targets; existing history is untouched.
CREATE OR REPLACE FUNCTION app_private.sync_journal(t uuid, src text, id uuid, d date, note text, target jsonb, opening_entry boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$declare prior app_private.accounting_source_state;delta jsonb;begin
 target:=app_private.dimension_entries(t,src,id,target);
 -- Replay needs prior account dimensions and amounts, not repeated empty/null
 -- metadata or a duplicate external amount when it equals the business amount.
 select coalesce(jsonb_agg(
  (case when coalesce(x->'details','{}')='{}' then jsonb_strip_nulls(x)-'details' else jsonb_strip_nulls(x) end)
  -case when (x->>'consolidated_amount')::numeric=(x->>'amount')::numeric then 'consolidated_amount' else '__unused__' end),'[]') into target
 from jsonb_array_elements(target)x;
 insert into app_private.accounting_source_state values(t,src,id,'[]',0) on conflict do nothing;
 select * into prior from app_private.accounting_source_state where tenant_id=t and source=src and source_id=id for update;
 with all_lines as(select x,1 sign from jsonb_array_elements(target)x union all select x,-1 from jsonb_array_elements(prior.lines)x),
 grouped as(select x->>'account' account,x->>'business_category' category,(x->>'entity_id')::uuid entity,(x->>'type_id')::uuid type_id,
  sum(sign*(x->>'amount')::numeric) amount,sum(sign*coalesce((x->>'consolidated_amount')::numeric,(x->>'amount')::numeric)) consolidated_amount from all_lines group by 1,2,3,4)
 select coalesce(jsonb_agg(app_private.accounting_line(account,amount,category,entity)||jsonb_build_object('type_id',type_id,'consolidated_amount',consolidated_amount)) filter(where amount<>0 or consolidated_amount<>0),'[]') into delta from grouped;
 if delta<>'[]' then perform app_private.post_journal(t,src,id,(prior.revision+1)::text,d,note,delta,false,opening_entry);
 update app_private.accounting_source_state set lines=target,revision=revision+1 where tenant_id=t and source=src and source_id=id;end if;
end $function$;

-- Cash classifications use immutable principal legs, independent of journal headers.
CREATE OR REPLACE FUNCTION app_private.finance_analysis_report(p_filters jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare ids uuid[]:=app_private.analysis_scope(p_filters);f date:=(p_filters->>'from')::date;u date:=(p_filters->>'to')::date;cat text:=coalesce(p_filters->>'category','all');
 grain text:=coalesce(p_filters->>'grain','month');opening jsonb;closing jsonb;result jsonb;r record;coverage boolean;estimated boolean;missing bigint;original boolean:=coalesce((p_filters->>'all_time')::boolean,false);begin

 if f is null or u is null or not isfinite(f) or not isfinite(u) or f>u or u>(now() at time zone 'Asia/Dhaka')::date or u-f>36525 or grain not in ('day','month','year') or grain='day' and u-f>730 or cat not in ('all','lpg','stove','logistics') then raise exception 'Choose a valid reporting period and business activity';end if;
 if original then select min((started_at at time zone 'Asia/Dhaka')::date) into f from public.accounting_periods where tenant_id=any(ids);f:=least(f,u);if grain='day' and u-f>730 then grain:='month';end if;end if;
 select bool_and(true),bool_or(a.estimated) into coverage,estimated from public.accounting_periods a where tenant_id=any(ids);
 select count(*) into missing from public.vehicles v where v.tenant_id=any(ids) and v.availability<>'retired' and not exists(select 1 from public.business_assets a where a.tenant_id=v.tenant_id and a.vehicle_id=v.vehicle_id);
 coverage:=coalesce(coverage,false) and missing=0;
 opening:=app_private.scoped_position(ids,f,cat,true,original);closing:=app_private.scoped_position(ids,u,cat);
 with period_lines as materialized(
 select j.tenant_id,j.journal_id,j.occurred_on,j.source,j.source_id,j.description,l.account,l.amount amount,l.amount business_amount,l.business_category,l.entity_id,a.kind,a.name
 from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) join public.accounting_accounts a on a.code=l.account
 where j.tenant_id=any(ids) and j.occurred_on between f and u and not j.is_opening),
 attributed as materialized(select * from period_lines where cat='all' or business_category=cat),
 totals as(select coalesce(-sum(amount) filter(where kind='income'),0) revenue,coalesce(sum(amount) filter(where kind='expense'),0) expenses,
 coalesce(-sum(amount) filter(where account='capital'),0) contributions,coalesce(sum(amount) filter(where account='withdrawals'),0) withdrawals,
 coalesce(-sum(amount) filter(where account in ('opening_equity','equity_adjustment','business_allocation_equity','retained_earnings')),0)+coalesce((
 select -sum(l.amount) from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id)
 where j.tenant_id=any(ids) and j.is_opening and j.occurred_on>=f and j.occurred_on<=u and not(original and j.occurred_on=f)
 and l.account in ('opening_equity','equity_adjustment','business_allocation_equity','retained_earnings','capital') and (cat='all' or l.business_category=cat)),0) equity_adjustments,
 coalesce(sum(amount) filter(where account='cash' and amount>0 ),0) gross_cash_in,
 coalesce(-sum(amount) filter(where account='cash' and amount<0 ),0) gross_cash_out from attributed),
 cash as materialized(select x.tenant_id,x.accounting_date occurred_on,b.key business_category,b.value::numeric amount,x.type,
 case when x.type='custom_entry' then (select case when e.account in ('capital','withdrawals') then 'financing' when e.account in ('equipment','other_assets') then 'investing' else 'operating' end from public.financial_entries e where e.tenant_id=x.tenant_id and e.entry_id=x.reference_id) when x.type='obligation_settlement' then coalesce((select o.cash_activity from public.finance_obligations o where o.tenant_id=x.tenant_id and o.obligation_id=x.reference_id),'unclassified') when x.type in ('loan_lend','loan_collect') then 'investing' when x.type in ('loan_receipt','loan_repayment','owner_capital','balance_adjustment','owner_withdrawal') then 'financing'
 when x.type in ('asset_purchase','asset_proceeds','asset_disposal_expense') then 'investing' else 'operating' end cash_category
 from public.wallet_transactions x cross join lateral jsonb_each_text(x.business_amounts)b where x.tenant_id=any(ids) and x.accounting_date between f and u and x.type not in ('wallet_transfer','opening_cash') and b.value::numeric<>0 and (cat='all' or b.key=cat)),
 buckets as(select d::date period from generate_series(date_trunc(grain,f::timestamp),date_trunc(grain,u::timestamp),('1 '||grain)::interval)d),
 activity_trend as(select date_trunc(grain,occurred_on)::date period,coalesce(-sum(amount) filter(where kind='income'),0) revenue,coalesce(sum(amount) filter(where kind='expense'),0) expenses
 from attributed group by 1),
 cash_trend as(select date_trunc(grain,occurred_on)::date period,sum(greatest(0,amount)) cash_in,-sum(least(0,amount)) cash_out,sum(amount) cash_flow from cash group by 1),
 position_events as (
 select b.tenant_id,b.account,case when b.account in ('cash','inventory_lpg','inventory_stove') then null::uuid else b.entity_id end entity_id,b.business_category,date_trunc(grain,f::timestamp)::date period,b.amount amount
 from app_private.dimensional_balances(ids,f,true,original)b join public.accounting_accounts a on a.code=b.account where (cat='all' or b.business_category=cat) and a.kind in ('asset','liability')
 union all
 select l.tenant_id,l.account,case when l.account in ('cash','inventory_lpg','inventory_stove') then null::uuid else l.entity_id end,l.business_category,date_trunc(grain,j.occurred_on)::date,l.amount
 from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) join public.accounting_accounts a on a.code=l.account
 where j.tenant_id=any(ids) and j.occurred_on between f and u and not(original and j.is_opening and j.occurred_on=f) and (cat='all' or l.business_category=cat) and a.kind in ('asset','liability')),
 position_deltas as(select tenant_id,account,entity_id,business_category,period,sum(amount) amount from position_events group by 1,2,3,4,5),
 position_running as(select *,sum(amount) over(partition by tenant_id,account,entity_id,business_category order by period) balance from position_deltas),
 position_changes as(select *,case when account='cash' then balance-lag(balance,1,0::numeric) over(partition by tenant_id,account,entity_id,business_category order by period) else greatest(balance,0)-greatest(lag(balance,1,0::numeric) over(partition by tenant_id,account,entity_id,business_category order by period),0) end asset_change,
 case when account='cash' then 0 else -least(balance,0)+least(lag(balance,1,0::numeric) over(partition by tenant_id,account,entity_id,business_category order by period),0) end liability_change from position_running),
 position_trend as(select period,sum(asset_change) asset_change,sum(liability_change) liability_change from position_changes group by period),
 trend as(select b.period,greatest(f,b.period) period_start,least(u,(b.period+('1 '||grain)::interval-interval '1 day')::date) period_end,
 coalesce(a.revenue,0) revenue,coalesce(a.expenses,0) expenses,coalesce(a.revenue,0)-coalesce(a.expenses,0) profit,
 coalesce(c.cash_in,0) cash_in,coalesce(c.cash_out,0) cash_out,coalesce(c.cash_flow,0) cash_flow,
 sum(coalesce(p.asset_change,0)) over(order by b.period) assets,sum(coalesce(p.liability_change,0)) over(order by b.period) liabilities,
 sum(coalesce(p.asset_change,0)-coalesce(p.liability_change,0)) over(order by b.period) net_worth
 from buckets b left join activity_trend a using(period) left join cash_trend c using(period) left join position_trend p using(period)),
 categories as(select account,name,kind,sum(case when kind='income' then -amount else amount end) amount from attributed where kind in ('income','expense') group by 1,2,3),
 business as(select tenant_id,business_category,coalesce(-sum(business_amount) filter(where kind='income'),0) revenue,coalesce(sum(business_amount) filter(where kind='expense'),0) expenses from period_lines where kind in ('income','expense') group by 1,2)
 select jsonb_build_object('from',f,'to',u,'category',cat,'opening',opening,'closing',closing,'complete',coverage,'estimated',estimated,'missing_asset_values',missing,
 'coverage',coalesce((select jsonb_agg(jsonb_build_object('tenant_id',a.tenant_id,'started_at',a.started_at,'note',a.opening_note)) from public.accounting_periods a where a.tenant_id=any(ids)),'[]'),
 'totals',jsonb_build_object('revenue',revenue,'expenses',expenses,'profit',case when coverage then revenue-expenses end,
 'contributions',contributions,'withdrawals',withdrawals,'equity_adjustments',equity_adjustments,
 'cash_in',coalesce((select sum(amount) from cash where amount>0),0),'cash_out',coalesce((select -sum(amount) from cash where amount<0),0),
 'cash_flow',coalesce((select sum(amount) from cash),0),'transfers',case when cat='all' then coalesce((select sum(x.amount) from public.wallet_transactions x where x.tenant_id=any(ids) and x.type='wallet_transfer' and x.amount>0 and x.accounting_date between f and u),0) else 0 end,
 'position_profit',case when coverage then (closing->>'assets')::numeric-(closing->>'liabilities')::numeric-(opening->>'assets')::numeric+(opening->>'liabilities')::numeric-contributions+withdrawals-equity_adjustments end),
 'categories',coalesce((select jsonb_agg(to_jsonb(c) order by kind,amount desc) from categories c),'[]'),
 'cash_categories',coalesce((select jsonb_agg(to_jsonb(c)) from(select cash_category category,sum(greatest(0,amount)) received,-sum(least(0,amount)) spent,sum(amount) net from cash group by cash_category)c),'[]'),
 'trend',coalesce((select jsonb_agg(to_jsonb(t) order by period) from trend t),'[]'),
 'businesses',coalesce((select jsonb_agg(to_jsonb(b)) from business b),'[]'),
 'all_time',original,'period_income',(closing->>'accumulated_income')::numeric-(opening->>'accumulated_income')::numeric,
 'invested_capital',closing->'capital','retained_earnings',(closing->>'accumulated_income')::numeric+coalesce((closing->>'historical_earnings')::numeric,0),'capital_recorded',closing->'capital','withdrawals_to_date',closing->'withdrawals') into result from totals;
 return result||jsonb_build_object('business_positions',(select jsonb_agg(jsonb_build_object('category',b,'opening',case when b=cat then opening else app_private.scoped_position(ids,f,b,true,original) end,'closing',case when b=cat then closing else app_private.scoped_position(ids,u,b) end)) from unnest(array['lpg','stove','logistics','all'])b),'period_values',app_private.period_financial_values(p_filters||jsonb_build_object('from',result->>'from')));end $function$;

-- A direct receipt recognizes acquisitions on Supplies after its transit legs net out.
CREATE OR REPLACE FUNCTION app_private.period_financial_values(p_filters jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$declare
 ids uuid[]:=app_private.analysis_scope(p_filters);cat text:=coalesce(p_filters->>'category','all');r jsonb;begin
 with lines as(select j.source,l.account,l.amount amount,t.code,t.origin
 from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) join public.financial_types t using(type_id)
 where j.tenant_id=any(ids) and j.occurred_on between (p_filters->>'from')::date and (p_filters->>'to')::date and not j.is_opening and (cat='all' or l.business_category=cat))
 select jsonb_build_object(
 'stock_acquisitions',coalesce(sum(case when account='inventory_transit' and code in ('purchase','internal_transport') then amount when account in ('inventory_lpg','inventory_stove') and code in ('purchase','inventory_capital','inventory_gain') then amount else 0 end),0),
 'stock_change',coalesce(sum(amount) filter(where account in ('inventory_lpg','inventory_stove','inventory_transit','bottle_receivable')),0),
 'equipment_acquisitions',coalesce(sum(amount) filter(where account in ('equipment','vehicles','other_assets') and (code in ('asset_register','asset_improve') or origin='custom') and amount>0),0),
 'receivable_change',coalesce(sum(amount) filter(where account in ('customer_receivable','transport_receivable','supplier_receivable')),0),
 'payable_change',coalesce(-sum(amount) filter(where account in ('supplier_payable','employee_payable','operating_payable','other_liability')),0),
 'loan_movement',coalesce(-sum(amount) filter(where account='loan_payable'),0),
 'wallet_movement',coalesce(sum(amount) filter(where account='cash'),0)) into r from lines;return r;end $function$;

-- A payment cannot settle more than the original cents owned by a business.
-- Boundary-rounded percentage allocations are not monotonic with three shares;
-- cap proposed payment cents to remaining principal and distribute the remainder.
create function app_private.loan_settlement_amounts(t uuid,id uuid,wallet_amount numeric)
returns jsonb language plpgsql set search_path='' as $$
declare loan public.loans;part record;remaining jsonb:='{}';result jsonb:='{}';
 prior numeric;prior_total numeric:=0;assigned numeric:=0;payment numeric:=abs(wallet_amount);give numeric;leftover numeric;
begin
 select * into loan from public.loans where tenant_id=t and loan_id=id for update;
 if not found or payment<=0 or round(payment,2)<>payment or loan.principal-loan.outstanding<payment
  then raise exception 'Loan settlement source is inconsistent';end if;
 for part in select original.business,original.amount principal,proposed.amount proposed
  from app_private.allocate_money(loan.principal,loan.allocations) original
  join app_private.allocate_money(payment,loan.allocations) proposed using(business) order by original.business loop
  select coalesce(sum(sign(w.amount)*coalesce((w.business_amounts->>part.business)::numeric,0)),0) into prior
   from public.wallet_transactions w where w.tenant_id=t and w.reference_id=id and w.type=case loan.direction when 'lent' then 'loan_collect' else 'loan_repayment' end;
  if prior<0 or prior>part.principal then raise exception 'Historical loan allocation needs source reconciliation before another repayment';end if;
  prior_total:=prior_total+prior;
  remaining:=remaining||jsonb_build_object(part.business,part.principal-prior);
  give:=least(part.proposed,part.principal-prior);
  result:=result||jsonb_build_object(part.business,give);assigned:=assigned+give;
 end loop;
 if prior_total<>loan.principal-loan.outstanding-payment then raise exception 'Loan repayments do not reconcile with principal';end if;
 leftover:=payment-assigned;
 for part in select key,value::text::numeric capacity from jsonb_each(remaining) order by key loop
  give:=least(leftover,part.capacity-(result->>part.key)::numeric);
  result:=jsonb_set(result,array[part.key],to_jsonb((result->>part.key)::numeric+give));leftover:=leftover-give;
 end loop;
 if leftover<>0 then raise exception 'Loan settlement exceeds remaining business principal';end if;
 select jsonb_object_agg(key,sign(wallet_amount)*value::text::numeric) into result from jsonb_each(result);
 return result;
end $$;
revoke all on function app_private.loan_settlement_amounts(uuid,uuid,numeric) from public,anon,authenticated;
do $$declare owner_name text;begin
 select pg_get_userbyid(proowner) into owner_name from pg_proc where oid='app_private.wallet_dimensions()'::regprocedure;
 execute format('alter function app_private.loan_settlement_amounts(uuid,uuid,numeric) owner to %I',owner_name);
end $$;

-- Future principal settlements use original ownership and cumulative cents.
CREATE OR REPLACE FUNCTION app_private.wallet_dimensions()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$declare cat text;a jsonb;p public.employee_payments;begin
 if new.type_id is null then new.type_id:=app_private.system_type(new.type);end if;
 if new.type='wallet_transfer' then
  if new.type_id is null or new.allocations is not null or new.business_amounts is not null then raise exception 'Treasury transfers have no business allocation';end if;return new;
 end if;
 if new.allocations is null then
  if new.type in ('pos_sale_income','customer_collection','sale_refund') then select jsonb_build_object(business_category,100) into a from public.sales where tenant_id=new.tenant_id and sale_id=new.reference_id;
  elsif new.type like 'purchase%' then select jsonb_build_object(business_category,100) into a from public.purchases where tenant_id=new.tenant_id and purchase_id=new.reference_id;
  elsif new.type like 'payroll_%' then
   select ep.* into p from public.employee_payment_entries e join public.employee_payments ep using(tenant_id,payment_id) where e.tenant_id=new.tenant_id and e.entry_id=new.employee_entry_id;
   if p.kind='trips' then a:='{"logistics":100}';else a:=p.allocations;end if;
  elsif new.type like 'transit_%' or new.type like 'vehicle_service_%' then a:='{"logistics":100}';
  elsif new.type in ('loan_receipt','loan_repayment','loan_lend','loan_collect') then select allocations into a from public.loans where tenant_id=new.tenant_id and loan_id=new.reference_id;
  elsif new.type like 'asset_%' then select allocations into a from public.business_assets where tenant_id=new.tenant_id and asset_id=new.reference_id;
  elsif new.type='obligation_settlement' then select allocations into a from public.finance_obligations where tenant_id=new.tenant_id and obligation_id=new.reference_id;
  end if;
  new.allocations:=coalesce(a,'{"lpg":100}'::jsonb);
 end if;
 if new.type_id is null or not coalesce(app_private.valid_business_allocation(new.allocations),false) then raise exception 'Wallet type and business allocation are required';end if;
 if new.business_amounts is null and new.type in ('loan_collect','loan_repayment') then
  new.business_amounts:=app_private.loan_settlement_amounts(new.tenant_id,new.reference_id,new.amount);
 end if;
 if new.business_amounts is null then new.business_amounts:=(select jsonb_object_agg(business,amount) from app_private.allocate_money(new.amount,new.allocations));end if; if not coalesce(app_private.valid_business_amounts(new.amount,new.business_amounts),false) then raise exception 'Business amounts must equal the wallet movement';end if;return new;end $function$;
