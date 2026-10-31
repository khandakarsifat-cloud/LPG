-- All reports aggregate the balanced journal. Operational tables only supply
-- labels and completeness checks, never alternative profit formulas.
create function app_private.accounting_position(ids uuid[],as_of date,before_day boolean default false) returns jsonb language sql stable set search_path='' as $$
 with balances as(
 select l.tenant_id,l.account,l.entity_id,a.name,a.kind,sum(l.amount) balance
 from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) join public.accounting_accounts a on a.code=l.account
 where l.tenant_id=any(ids) and (case when before_day then j.occurred_on<as_of or j.is_opening and j.occurred_on=as_of else j.occurred_on<=as_of end)
 group by l.tenant_id,l.account,l.entity_id,a.name,a.kind),
 classified as(select *,case when kind='liability' and balance>0 then 'asset' when kind='asset' and balance<0 then 'liability' else kind end reported_kind,
 case when kind in ('income','liability','equity') then -balance else balance end display_amount from balances)
 select jsonb_build_object('assets',coalesce(sum(case when reported_kind='asset' then balance else 0 end),0),
 'liabilities',coalesce(sum(case when reported_kind='liability' then -balance else 0 end),0),
 'equity',coalesce(sum(case when kind in ('equity','income','expense') then -balance else 0 end),0),
 'cash',coalesce(sum(balance) filter(where account='cash'),0),
 'accounts',coalesce(jsonb_agg(jsonb_build_object('tenant_id',tenant_id,'account',account,'name',name,'kind',reported_kind,'entity_id',entity_id,
 'amount',case when reported_kind='liability' then -balance when reported_kind='asset' then balance else display_amount end)) filter(where balance<>0),'[]')) from classified;$$;
create or replace function public.get_finance_analysis(p_filters jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare ids uuid[]:=app_private.analysis_scope(p_filters);f date:=(p_filters->>'from')::date;u date:=(p_filters->>'to')::date;cat text:=coalesce(p_filters->>'category','all');
 grain text:=coalesce(p_filters->>'grain','month');opening jsonb;closing jsonb;result jsonb;r record;coverage boolean;estimated boolean;missing bigint;begin
 if f is null or u is null or not isfinite(f) or not isfinite(u) or f>u or u>(now() at time zone 'Asia/Dhaka')::date or u-f>36525 or grain not in ('day','month','year') or grain='day' and u-f>730 or cat not in ('all','lpg','stove','logistics','shared') then raise exception 'Choose a valid reporting period and business activity';end if;
 for r in select unnest(ids) id loop perform app_private.sync_payroll(r.id);end loop;
 select bool_and(f>=(started_at at time zone 'Asia/Dhaka')::date),bool_or(a.estimated) into coverage,estimated from public.accounting_periods a where tenant_id=any(ids);
 select count(*) into missing from public.vehicles v where v.tenant_id=any(ids) and v.availability<>'retired' and not exists(select 1 from public.business_assets a where a.tenant_id=v.tenant_id and a.vehicle_id=v.vehicle_id);
 coverage:=coalesce(coverage,false) and missing=0;
 opening:=app_private.accounting_position(ids,f,true);closing:=app_private.accounting_position(ids,u);
 with period_lines as materialized(
 select j.tenant_id,j.journal_id,j.occurred_on,j.source,j.source_id,j.description,l.account,l.amount,l.business_category,l.entity_id,a.kind,a.name
 from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) join public.accounting_accounts a on a.code=l.account
 where j.tenant_id=any(ids) and j.occurred_on between f and u and not j.is_opening),
 attributed as materialized(select * from period_lines where cat='all' or business_category=cat),
 totals as(select coalesce(-sum(amount) filter(where kind='income'),0) revenue,coalesce(sum(amount) filter(where kind='expense'),0) expenses,
 coalesce(-sum(amount) filter(where account='capital'),0) contributions,coalesce(sum(amount) filter(where account='withdrawals'),0) withdrawals,
 coalesce(-sum(amount) filter(where account in ('opening_equity','equity_adjustment')),0) equity_adjustments,
 coalesce(sum(amount) filter(where account='cash' and amount>0 and description is not null and source='wallet'),0) gross_cash_in,
 coalesce(-sum(amount) filter(where account='cash' and amount<0 and source='wallet'),0) gross_cash_out from attributed),
 cash as materialized(select l.*,x.type,
 case when x.type='obligation_settlement' then coalesce((select o.cash_activity from public.finance_obligations o where o.tenant_id=x.tenant_id and o.obligation_id=x.reference_id),'unclassified') when x.type='wallet_transfer' then 'transfer' when x.type in ('loan_receipt','loan_repayment','owner_capital','balance_adjustment','owner_withdrawal') then 'financing'
 when x.type in ('asset_purchase','asset_proceeds','asset_disposal_expense') then 'investing' else 'operating' end cash_category
 from attributed l join public.wallet_transactions x on x.tenant_id=l.tenant_id and x.transaction_id=l.source_id where l.account='cash' and l.source='wallet'),
 trend as(select date_trunc(grain,occurred_on)::date period,coalesce(-sum(amount) filter(where kind='income'),0) revenue,coalesce(sum(amount) filter(where kind='expense'),0) expenses,
 coalesce(sum(amount) filter(where account='cash'),0) cash_flow from attributed group by 1),
 categories as(select account,name,kind,sum(case when kind='income' then -amount else amount end) amount from attributed where kind in ('income','expense') group by 1,2,3),
 business as(select tenant_id,business_category,coalesce(-sum(amount) filter(where kind='income'),0) revenue,coalesce(sum(amount) filter(where kind='expense'),0) expenses from period_lines where kind in ('income','expense') group by 1,2)
 select jsonb_build_object('from',f,'to',u,'category',cat,'opening',opening,'closing',closing,'complete',coverage,'estimated',estimated,'missing_asset_values',missing,
 'coverage',coalesce((select jsonb_agg(jsonb_build_object('tenant_id',a.tenant_id,'started_at',a.started_at,'note',a.opening_note)) from public.accounting_periods a where a.tenant_id=any(ids)),'[]'),
 'totals',jsonb_build_object('revenue',revenue,'expenses',expenses,'profit',case when coverage then revenue-expenses end,
 'contributions',contributions,'withdrawals',withdrawals,'equity_adjustments',equity_adjustments,
 'cash_in',coalesce((select sum(amount) from cash where amount>0 and cash_category<>'transfer'),0),'cash_out',coalesce((select -sum(amount) from cash where amount<0 and cash_category<>'transfer'),0),
 'cash_flow',coalesce((select sum(amount) from cash where cash_category<>'transfer'),0),'transfers',coalesce((select sum(amount) from cash where amount>0 and cash_category='transfer'),0),
 'position_profit',case when coverage and cat='all' then (closing->>'assets')::numeric-(closing->>'liabilities')::numeric-(opening->>'assets')::numeric+(opening->>'liabilities')::numeric-contributions+withdrawals-equity_adjustments end),
 'categories',coalesce((select jsonb_agg(to_jsonb(c) order by kind,amount desc) from categories c),'[]'),
 'cash_categories',coalesce((select jsonb_agg(to_jsonb(c)) from(select cash_category category,sum(greatest(0,amount)) received,-sum(least(0,amount)) spent,sum(amount) net from cash group by cash_category)c),'[]'),
 'trend',coalesce((select jsonb_agg(to_jsonb(t) order by period) from trend t),'[]'),
 'businesses',coalesce((select jsonb_agg(to_jsonb(b)) from business b),'[]'),
 'invested_capital',case when not estimated and not exists(select 1 from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where l.tenant_id=any(ids) and l.account='opening_equity' and j.occurred_on<=u and l.amount<>0) then coalesce((select sum(-l.amount) from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where l.tenant_id=any(ids) and l.account='capital' and j.occurred_on<=u),0) end,
 'capital_recorded',coalesce((select sum(-l.amount) from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where l.tenant_id=any(ids) and l.account='capital' and j.occurred_on<=u),0),
 'withdrawals_to_date',coalesce((select sum(l.amount) from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where l.tenant_id=any(ids) and l.account='withdrawals' and j.occurred_on<=u),0)) into result from totals;
 return result;end $$;
create or replace function public.get_analysis_details(p_filters jsonb,p_metric text,p_category text default null,p_offset integer default 0,p_limit integer default 12) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare ids uuid[]:=app_private.analysis_scope(p_filters);r jsonb;f date:=(p_filters->>'from')::date;u date:=(p_filters->>'to')::date;begin
 if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 or f is null or u is null or f>u then raise exception 'Invalid journal filters';end if;
 with matching as materialized(select j.*,coalesce((select jsonb_agg(jsonb_build_object('account',a.name,'amount',l.amount,'business_category',l.business_category,'entity_id',l.entity_id) order by l.line_no) from public.accounting_lines l join public.accounting_accounts a on a.code=l.account where l.tenant_id=j.tenant_id and l.journal_id=j.journal_id),'[]') lines
 from public.accounting_journals j where j.tenant_id=any(ids) and j.occurred_on between f and u
 and (coalesce(p_filters->>'category','all')='all' or exists(select 1 from public.accounting_lines l where l.tenant_id=j.tenant_id and l.journal_id=j.journal_id and l.business_category=p_filters->>'category'))
 and (p_category is null or exists(select 1 from public.accounting_lines l where l.tenant_id=j.tenant_id and l.journal_id=j.journal_id and l.account=p_category))),
 page as(select * from matching order by occurred_on desc,entry_no desc offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(to_jsonb(p) order by occurred_on desc,entry_no desc) from page p),'[]')) into r;return r;end $$;
-- Before retiring the previous valuation implementation, redefine its only
-- remaining product-detail consumer with the shared recorded-cost projection.
-- Further function definitions below are generated from the owning current RPCs.

CREATE OR REPLACE FUNCTION public.get_product_inventory(p_item_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  t uuid := app_private.require_any_permission(array['inventory:view','inventory:manage']);
  as_of timestamptz := clock_timestamp();
  local_today date := (as_of at time zone 'Asia/Dhaka')::date;
  saturday date;
  result jsonb;
begin
  if not exists(select 1 from public.items where tenant_id=t and item_id=p_item_id) then
    raise exception 'Product not found';
  end if;
  saturday := local_today - ((extract(dow from local_today)::integer + 1) % 7);
  with current_commission as (
    select coalesce(c.refill_commission_per_unit,0) refill_rate,
      coalesce(c.package_commission_per_unit,0) package_rate,c.rate_id version
    from (select 1) singleton left join lateral (
      select refill_commission_per_unit,package_commission_per_unit,rate_id
      from public.product_commission_rates where tenant_id=t and item_id=p_item_id
      order by created_at desc,rate_id desc limit 1
    ) c on true
  ), current_prices as (
    select distinct on (customer_tier,price_type) customer_tier,price_type,price,mrp,effective_from
    from public.price_books
    where tenant_id=t and item_id=p_item_id and effective_from<=as_of
      and (effective_to is null or effective_to>as_of)
    order by customer_tier,price_type,effective_from desc
  ), weeks as (
    select (saturday - n*7) start_date,(saturday - n*7 + 7) end_date
    from generate_series(0,7) n
  ), history as (
    select w.start_date,w.end_date-1 end_date,
      coalesce(s.sold_refill,0) sold_refill,coalesce(s.sold_package,0) sold_package,
      coalesce((select sum(l.quantity) from public.sale_bottle_receipt_lines l join public.sale_bottle_receipts r on r.tenant_id=t and r.receipt_id=l.receipt_id where l.tenant_id=t and l.received_item_id=p_item_id and r.created_at >= (w.start_date::timestamp at time zone 'Asia/Dhaka') and r.created_at < (w.end_date::timestamp at time zone 'Asia/Dhaka')),0) empty_return,
      coalesce(p.bought_package,0) bought_package,coalesce(p.bought_refill,0) bought_refill
    from weeks w
    cross join lateral (
      select sum(si.quantity) filter(where si.type='refill') sold_refill,
        sum(si.quantity) filter(where si.type='package') sold_package
      from public.sale_items si join public.sales s using(tenant_id,sale_id)
      where si.tenant_id=t and si.item_id=p_item_id and s.status='completed'
        and s.created_at >= (w.start_date::timestamp at time zone 'Asia/Dhaka')
        and s.created_at < (w.end_date::timestamp at time zone 'Asia/Dhaka')
    ) s
    cross join lateral (
      select sum(pi.received_quantity) filter(where pi.type='package') bought_package,
        sum(pi.received_quantity) filter(where pi.type='refill') bought_refill
      from public.purchase_items pi join public.purchases p using(tenant_id,purchase_id)
      where pi.tenant_id=t and pi.item_id=p_item_id and p.status='received'
        and p.received_at >= (w.start_date::timestamp at time zone 'Asia/Dhaka')
        and p.received_at < (w.end_date::timestamp at time zone 'Asia/Dhaka')
    ) p
  )
  select jsonb_build_object(
    'can_manage_prices',app_private.can_manage_inventory_prices(),
    'commission',(select to_jsonb(c) from current_commission c),
    'prices',coalesce((select jsonb_agg(to_jsonb(c) order by customer_tier,price_type) from current_prices c),'[]'::jsonb),
    'valuation',(select to_jsonb(c) from public.inventory_costs c where tenant_id=t and item_id=p_item_id),
    'weeks',(select jsonb_agg(to_jsonb(h) order by start_date desc) from history h)
  ) into result;
  return result;
end $$;
CREATE OR REPLACE FUNCTION app_private.wallet_accounting_date() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
 new.accounting_date:=coalesce(new.accounting_date,
 (select p.payment_date from public.operating_payments p where p.tenant_id=new.tenant_id and p.payment_id=new.operating_payment_id),
 (select p.payment_date from public.employee_payment_entries e join public.employee_payments p using(tenant_id,payment_id) where e.tenant_id=new.tenant_id and e.entry_id=new.employee_entry_id),
 (select s.spending_date from public.spendings s where s.tenant_id=new.tenant_id and s.spending_id=new.reference_id and new.type in ('business_spending','owner_withdrawal')),
 (new.created_at at time zone 'Asia/Dhaka')::date);return new;
end $$;
CREATE OR REPLACE FUNCTION app_private.initialize_spending_categories(t uuid) RETURNS void
    LANGUAGE sql
    SET search_path TO ''
    AS $$
 insert into public.spending_categories(tenant_id,name,classification) values(t,'Business','cost'),(t,'Logistics','cost'),(t,'Home','withdrawal'),(t,'Others','withdrawal'),(t,'Interest','cost') on conflict do nothing;
$$;
CREATE OR REPLACE FUNCTION app_private.vehicle_json(t uuid, id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
 select to_jsonb(v)||jsonb_build_object('asset',(select to_jsonb(a) from public.business_assets a where a.tenant_id=t and a.vehicle_id=id),'location',coalesce((select coalesce(nullif(tr.destination,''),'In transit') from public.transits tr where tr.tenant_id=t and tr.vehicle_id=id and tr.status='active' order by created_at desc,transit_id limit 1),'Home'),
 'driver_employee_id',d.employee_id,'driver_name',d.employee_name,'helper_employee_id',h.employee_id,'helper_name',h.employee_name)
 from public.vehicles v
 left join public.vehicle_assignments d on d.tenant_id=t and d.vehicle_id=id and d.role='driver' and d.ended_at is null
 left join public.vehicle_assignments h on h.tenant_id=t and h.vehicle_id=id and h.role='helper' and h.ended_at is null
 where v.tenant_id=t and v.vehicle_id=id;
$$;
CREATE OR REPLACE FUNCTION public.get_vehicle_directory(p_filters jsonb DEFAULT '{}'::jsonb, p_offset integer DEFAULT 0, p_limit integer DEFAULT 25) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare t uuid:=app_private.require_any_permission(array['logistics:view','logistics:manage']); result jsonb; begin
 if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 or length(coalesce(p_filters->>'search',''))>500 or coalesce(p_filters->>'status','all') not in ('all','home','away','unassigned','out_of_service','retired') then raise exception 'Invalid vehicle filters'; end if;
 with matching as materialized (select v.* from public.vehicles v where v.tenant_id=t
  and (coalesce(p_filters->>'status','all')='all' or p_filters->>'status'=v.availability or p_filters->>'status'='home' and v.status='idle' and v.availability='active' or p_filters->>'status'='away' and v.status<>'idle'
   or p_filters->>'status'='unassigned' and not exists(select 1 from public.vehicle_assignments a where a.tenant_id=t and a.vehicle_id=v.vehicle_id and a.role='driver' and a.ended_at is null))
  and app_private.finance_search(concat_ws(' ',v.name,v.serial_no,(select string_agg(a.employee_name,' ') from public.vehicle_assignments a where a.tenant_id=t and a.vehicle_id=v.vehicle_id and a.ended_at is null)),coalesce(p_filters->>'search',''))),
 page as (select * from matching order by name,vehicle_id offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(app_private.vehicle_json(t,p.vehicle_id) order by p.name,p.vehicle_id) from page p),'[]')) into result;
 return result;
end $$;
CREATE OR REPLACE FUNCTION public.save_vehicle(p_payload jsonb, p_request_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare t uuid:=app_private.require_permission('logistics:manage'); v public.vehicles; a public.vehicle_assignments;
 id uuid:=nullif(p_payload->>'vehicle_id','')::uuid; driver uuid:=nullif(p_payload->>'driver_employee_id','')::uuid;
 helper uuid:=nullif(p_payload->>'helper_employee_id','')::uuid; v_capacity numeric:=(p_payload->>'capacity')::numeric;
 prior public.finance_requests; body jsonb:=jsonb_build_object('action','save_vehicle','actor',auth.uid(),'body',p_payload); result jsonb; role_name text; eid uuid;
begin
 if p_request_id is null or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'Vehicle details and request ID are required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload<>body then raise exception 'Request ID was already used with different details'; end if; return prior.result; end if;
 if nullif(trim(p_payload->>'name'),'') is null or length(p_payload->>'name')>100 or nullif(trim(p_payload->>'serial_no'),'') is null or length(p_payload->>'serial_no')>100
  or v_capacity is null or v_capacity::text in ('NaN','Infinity','-Infinity') or v_capacity<0 or v_capacity>2147483647 or v_capacity<>trunc(v_capacity) then raise exception 'Name, serial number and a nonnegative whole capacity are required'; end if;
 if driver is not null and driver=helper then raise exception 'Choose different driver and helper employees'; end if;
 -- Serialize assignment changes per tenant before vehicle -> employee locks.
 perform pg_advisory_xact_lock(hashtextextended(t::text||':vehicle_assignments',0));
 if id is null then
  insert into public.vehicles(tenant_id,name,serial_no,capacity,status) values(t,trim(p_payload->>'name'),trim(p_payload->>'serial_no'),v_capacity,'idle') returning * into v;
  id:=v.vehicle_id;
  perform public.accounting_operation(jsonb_build_object('action','asset_register','kind','vehicles','vehicle_id',id,'name',v.name,'amount',(p_payload->>'book_value')::numeric,'funding',p_payload->>'funding','wallet_id',p_payload->>'wallet_id','date',(now() at time zone 'Asia/Dhaka')::date,'description','Vehicle acquisition: '||v.name),md5(p_request_id::text||':asset')::uuid);
 else
  select * into v from public.vehicles where tenant_id=t and vehicle_id=id for update;
  if not found or v.availability='retired' then raise exception 'Vehicle not found or retired'; end if;
  if v.revision is distinct from (p_payload->>'revision')::integer then raise exception 'Vehicle changed. Reload before saving.'; end if;
 end if;
 perform 1 from public.employees where tenant_id=t and employee_id in (driver,helper) order by employee_id for update;
 foreach role_name in array array['driver','helper'] loop
  eid:=case role_name when 'driver' then driver else helper end;
  select * into a from public.vehicle_assignments where tenant_id=t and vehicle_id=id and role=role_name and ended_at is null;
  if a.employee_id is not distinct from eid then continue; end if;
  perform app_private.validate_vehicle_employee(t,eid,role_name);
  if exists(select 1 from public.vehicle_assignments where tenant_id=t and employee_id=eid and ended_at is null and vehicle_id<>id) then raise exception 'Employee is assigned to another vehicle. Unlink that assignment first.'; end if;
  update public.vehicle_assignments set ended_at=clock_timestamp(),ended_by=auth.uid() where assignment_id=a.assignment_id;
  if eid is not null then insert into public.vehicle_assignments(tenant_id,vehicle_id,employee_id,role,employee_name,created_by)
   select t,id,eid,role_name,name,auth.uid() from public.employees where tenant_id=t and employee_id=eid; end if;
 end loop;
 update public.vehicles set name=trim(p_payload->>'name'),serial_no=trim(p_payload->>'serial_no'),capacity=v_capacity::integer,revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and vehicle_id=id;
 result:=jsonb_build_object('vehicle_id',id);
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());
 return result;
end $$;
-- Eliminate obsolete current implementations, without changing historical
-- migrations or erasing archived financial evidence.
drop function app_private.finance_facts(uuid[],date,date);
drop function public.set_product_buying_price(jsonb,uuid);
drop function public.get_buying_price_history(uuid,integer,integer);
drop function app_private.capture_sale_cost();
drop function app_private.purchase_buying_prices();
drop function app_private.commission_buying_prices();
drop function app_private.refresh_buying_price(uuid,uuid,text,text,timestamptz,uuid,boolean);
drop function app_private.buying_price_at(uuid,uuid,text,timestamptz);
drop function app_private.inventory_value_at(uuid,timestamptz);
drop function app_private.valuation_baseline_created();
drop table public.sale_cost_evidence;
drop table public.inventory_valuation_baselines;
drop table public.product_buying_price_history;
-- New internal helpers are not RPCs. Public operations explicitly authorize
-- trusted tenant/capability/owner before any privileged reads or mutations.
do $$declare r record;begin
 for r in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='app_private' and p.proname in
 ('require_owner','accounting_line','post_journal','check_journal_balance','sync_journal','source_accounting','account_wallet','accounting_business_created','inventory_cost_created','cost_inventory_movement','sync_payroll','account_employee_terms','seed_stove_types','stove_types_created','require_vehicle_available','guard_vehicle_retirement','reverse_purchase_commissions','accounting_position') loop
 execute format('revoke all on function %s from public,anon,authenticated',r.signature);end loop;end $$;

-- Match the existing application owner. Supabase's platform administrator runs
-- deployment; existing definer RPCs execute as postgres, a separate DB role.
do $$declare r record;begin
 for r in select c.oid::regclass relation from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname in ('public','app_private') and c.relkind='r' and pg_get_userbyid(c.relowner)<>'postgres' loop execute format('alter table %s owner to postgres',r.relation);end loop;
 for r in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','app_private') and pg_get_userbyid(p.proowner)<>'postgres' and p.prokind='f' loop execute format('alter function %s owner to postgres',r.signature);end loop;
end $$;
