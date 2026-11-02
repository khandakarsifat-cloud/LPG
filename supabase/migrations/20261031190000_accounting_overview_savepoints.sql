-- Derived month-end savepoints. Journals remain authoritative; no opening
-- transactions, balances or operational evidence are changed by this migration.
create table app_private.accounting_snapshot_state (
 tenant_id uuid primary key references public.tenants(tenant_id), invalid_from date not null,
 changed_at timestamptz not null default clock_timestamp()
);
create table app_private.accounting_snapshots (
 tenant_id uuid not null references public.tenants(tenant_id), month_end date not null,
 built_at timestamptz not null default clock_timestamp(), revision bigint not null default 1,
 source_count bigint not null, checksum text not null,
 primary key(tenant_id,month_end), check(month_end=(date_trunc('month',month_end)+interval '1 month - 1 day')::date)
);
create table app_private.accounting_snapshot_lines (
 tenant_id uuid not null, month_end date not null, account text not null references public.accounting_accounts(code),
 business_category text not null, entity_id uuid, amount numeric(20,2) not null,
 unique nulls not distinct(tenant_id,month_end,account,business_category,entity_id),
 foreign key(tenant_id,month_end) references app_private.accounting_snapshots(tenant_id,month_end)
);
create table app_private.accounting_snapshot_audit (
 build_id bigint generated always as identity primary key,tenant_id uuid not null,month_end date not null,
 revision bigint not null, source_count bigint not null,checksum text not null,built_at timestamptz not null default clock_timestamp()
);
insert into app_private.accounting_snapshot_state(tenant_id,invalid_from)
 select tenant_id,min(occurred_on) from public.accounting_journals group by tenant_id;

-- Statement transition tables aggregate one journal's invalidation, never one
-- counter update per line. The state row serializes builders with source writes.
create function app_private.invalidate_accounting_snapshots() returns trigger language plpgsql security definer set search_path='' as $$begin
 insert into app_private.accounting_snapshot_state(tenant_id,invalid_from)
 select n.tenant_id,min(j.occurred_on) from new_lines n join public.accounting_journals j using(tenant_id,journal_id) group by n.tenant_id order by n.tenant_id
 on conflict(tenant_id) do update set invalid_from=excluded.invalid_from,changed_at=clock_timestamp()
 where accounting_snapshot_state.invalid_from>excluded.invalid_from;
 return null;end $$;
create trigger invalidate_accounting_snapshots after insert on public.accounting_lines referencing new table as new_lines for each statement execute function app_private.invalidate_accounting_snapshots();

create function app_private.accounting_balances(ids uuid[],as_of date,before_day boolean default false,original boolean default false)
returns table(tenant_id uuid,account text,business_category text,entity_id uuid,amount numeric) language sql stable set search_path='' as $$
 with cut as(select case when before_day then as_of-1 else as_of end d),
 preceding as materialized(select t.id,max(s.month_end) month_end from unnest(ids)t(id) cross join cut
 left join app_private.accounting_snapshot_state st on st.tenant_id=t.id
 left join app_private.accounting_snapshots s on s.tenant_id=t.id and s.month_end<=cut.d and s.month_end<st.invalid_from group by t.id),
 evidence as(
 select l.tenant_id,l.account,l.business_category,l.entity_id,l.amount from preceding p join app_private.accounting_snapshot_lines l on l.tenant_id=p.id and l.month_end=p.month_end
 union all
 select l.tenant_id,l.account,l.business_category,l.entity_id,l.amount from preceding p join public.accounting_journals j on j.tenant_id=p.id cross join cut
 join public.accounting_lines l on l.tenant_id=j.tenant_id and l.journal_id=j.journal_id
 where j.occurred_on>coalesce(p.month_end,'-infinity'::date) and (j.occurred_on<=cut.d or original and j.is_opening and j.occurred_on=as_of))
 select e.tenant_id,e.account,e.business_category,e.entity_id,sum(e.amount) from evidence e group by 1,2,3,4;
$$;

create function app_private.build_accounting_snapshots(t uuid,max_months integer default 3) returns integer language plpgsql set search_path='' as $$
declare d date;last_month date:=(date_trunc('month',now() at time zone 'Asia/Dhaka')-interval '1 day')::date;n integer:=0;v bigint;c bigint;hash text;rows jsonb;begin
 if max_months not between 1 and 24 then raise exception 'Invalid snapshot batch';end if;
 select (date_trunc('month',invalid_from)+interval '1 month - 1 day')::date into d from app_private.accounting_snapshot_state where tenant_id=t for update;
 while d<=last_month and n<max_months loop
  -- Read valid earlier savepoints, then append only subsequent canonical lines.
  select coalesce(jsonb_agg(to_jsonb(b)),'[]') into rows from app_private.accounting_balances(array[t],d) b;
  select count(*) into c from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where j.tenant_id=t and j.occurred_on<=d;
  select md5(coalesce(string_agg(concat_ws(':',account,business_category,entity_id,amount),'|' order by account,business_category,entity_id),'')) into hash from jsonb_to_recordset(rows)b(account text,business_category text,entity_id uuid,amount numeric);
  insert into app_private.accounting_snapshots(tenant_id,month_end,source_count,checksum) values(t,d,c,hash)
   on conflict(tenant_id,month_end) do update set built_at=clock_timestamp(),revision=accounting_snapshots.revision+1,source_count=c,checksum=hash returning revision into v;
  delete from app_private.accounting_snapshot_lines where tenant_id=t and month_end=d;
  insert into app_private.accounting_snapshot_lines select t,d,account,business_category,entity_id,amount from jsonb_to_recordset(rows)b(account text,business_category text,entity_id uuid,amount numeric);
  insert into app_private.accounting_snapshot_audit(tenant_id,month_end,revision,source_count,checksum) values(t,d,v,c,hash);
  update app_private.accounting_snapshot_state set invalid_from=d+1 where tenant_id=t;
  d:=(d+interval '1 month')::date;d:=(date_trunc('month',d)+interval '1 month - 1 day')::date;n:=n+1;
 end loop;return n;end $$;

create function app_private.position_from_balances(balances jsonb) returns jsonb language sql stable set search_path='' as $$
 with b as(select x.tenant_id,x.account,x.entity_id,a.name,a.kind,sum(x.amount) balance from jsonb_to_recordset(balances)x(tenant_id uuid,account text,entity_id uuid,amount numeric) join public.accounting_accounts a on a.code=x.account group by 1,2,3,4,5),
 classified as(select *,case when kind='liability' and balance>0 then 'asset' when kind='asset' and balance<0 then 'liability' else kind end reported_kind from b),
 s as(select tenant_id,account,name,kind,reported_kind,case when account='cash' then entity_id end entity_id,sum(balance) balance from classified group by 1,2,3,4,5,6)
 select jsonb_build_object('assets',coalesce(sum(s.balance) filter(where reported_kind='asset'),0),'liabilities',coalesce(-sum(s.balance) filter(where reported_kind='liability'),0),
 'equity',coalesce(-sum(s.balance) filter(where s.kind in ('equity','income','expense')),0),'cash',coalesce(sum(s.balance) filter(where account='cash'),0),
 'capital',coalesce(-sum(s.balance) filter(where account in ('capital','opening_equity')),0),
 'revenue',coalesce(-sum(s.balance) filter(where s.kind='income'),0),'expenses',coalesce(sum(s.balance) filter(where s.kind='expense'),0),
 'withdrawals',coalesce(sum(s.balance) filter(where account='withdrawals'),0),'other_equity',coalesce(-sum(s.balance) filter(where account='equity_adjustment'),0),
 'accumulated_income',coalesce(-sum(s.balance) filter(where s.kind in ('income','expense')),0),
 'accounts',coalesce(jsonb_agg(jsonb_build_object('tenant_id',s.tenant_id,'account',account,'name',s.name,'kind',reported_kind,'entity_id',s.entity_id,'entity_name',w.name,
 'amount',case when reported_kind in ('asset','expense') then s.balance else -s.balance end) order by reported_kind,s.name,s.tenant_id,s.entity_id) filter(where s.balance<>0),'[]'))
 from s left join public.wallets w on w.tenant_id=s.tenant_id and w.wallet_id=s.entity_id and account='cash';$$;
create or replace function app_private.accounting_position(ids uuid[],as_of date,before_day boolean default false) returns jsonb language sql stable set search_path='' as $$
 select app_private.position_from_balances(coalesce(jsonb_agg(to_jsonb(b)),'[]')) from app_private.accounting_balances(ids,as_of,before_day) b;$$;

-- One definition maps accounts to the Overview, drill-downs and exported report.
create function app_private.analysis_group(code text,kind text) returns text language sql immutable set search_path='' as $$select
 case when kind='asset' then case when code='cash' then 'cash' when code in ('inventory_lpg','inventory_stove','inventory_transit','bottle_receivable') then 'inventory' when code in ('vehicles','equipment','other_assets') then 'fixed_assets' when code in ('customer_receivable','supplier_receivable','transport_receivable') then 'receivables' else 'other_assets' end
 when kind='liability' then case when code in ('loan_payable','supplier_payable') then 'dues' when code='employee_payable' then 'employees' else 'other_liabilities' end
 when kind='income' then 'revenue' when kind='expense' then 'expenses' when code in ('capital','opening_equity') then 'capital' when code='withdrawals' then 'withdrawals' else 'other_equity' end;$$;

create function app_private.finance_analysis_report(p_filters jsonb) returns jsonb language plpgsql stable set search_path='' as $$
declare ids uuid[]:=app_private.analysis_scope(p_filters);f date:=(p_filters->>'from')::date;u date:=(p_filters->>'to')::date;cat text:=coalesce(p_filters->>'category','all');
 grain text:=coalesce(p_filters->>'grain','month');opening jsonb;closing jsonb;result jsonb;r record;coverage boolean;estimated boolean;missing bigint;original boolean:=coalesce((p_filters->>'all_time')::boolean,false);begin

 if f is null or u is null or not isfinite(f) or not isfinite(u) or f>u or u>(now() at time zone 'Asia/Dhaka')::date or u-f>36525 or grain not in ('day','month','year') or grain='day' and u-f>730 or cat not in ('all','lpg','stove','logistics','shared') then raise exception 'Choose a valid reporting period and business activity';end if;
 if original then select min((started_at at time zone 'Asia/Dhaka')::date) into f from public.accounting_periods where tenant_id=any(ids);f:=least(f,u);if grain='day' and u-f>730 then grain:='month';end if;end if;
 select bool_and(true),bool_or(a.estimated) into coverage,estimated from public.accounting_periods a where tenant_id=any(ids);
 select count(*) into missing from public.vehicles v where v.tenant_id=any(ids) and v.availability<>'retired' and not exists(select 1 from public.business_assets a where a.tenant_id=v.tenant_id and a.vehicle_id=v.vehicle_id);
 coverage:=coalesce(coverage,false) and missing=0;
 select app_private.position_from_balances(coalesce(jsonb_agg(to_jsonb(b)),'[]')) into opening from app_private.accounting_balances(ids,f,true,original)b;closing:=app_private.accounting_position(ids,u);
 with period_lines as materialized(
 select j.tenant_id,j.journal_id,j.occurred_on,j.source,j.source_id,j.description,l.account,l.amount,l.business_category,l.entity_id,a.kind,a.name
 from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) join public.accounting_accounts a on a.code=l.account
 where j.tenant_id=any(ids) and j.occurred_on between f and u and not j.is_opening),
 attributed as materialized(select * from period_lines where cat='all' or business_category=cat),
 totals as(select coalesce(-sum(amount) filter(where kind='income'),0) revenue,coalesce(sum(amount) filter(where kind='expense'),0) expenses,
 coalesce(-sum(amount) filter(where account='capital'),0) contributions,coalesce(sum(amount) filter(where account='withdrawals'),0) withdrawals,
 coalesce(-sum(amount) filter(where account in ('opening_equity','equity_adjustment')),0)+coalesce((
 select -sum(l.amount) from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id)
 where j.tenant_id=any(ids) and j.is_opening and j.occurred_on>=f and j.occurred_on<=u and not(original and j.occurred_on=f)
 and l.account in ('opening_equity','equity_adjustment','capital') and (cat='all' or l.business_category=cat)),0) equity_adjustments,
 coalesce(sum(amount) filter(where account='cash' and amount>0 and description is not null and source='wallet'),0) gross_cash_in,
 coalesce(-sum(amount) filter(where account='cash' and amount<0 and source='wallet'),0) gross_cash_out from attributed),
 cash as materialized(select l.*,x.type,
 case when x.type='obligation_settlement' then coalesce((select o.cash_activity from public.finance_obligations o where o.tenant_id=x.tenant_id and o.obligation_id=x.reference_id),'unclassified') when x.type='wallet_transfer' then 'transfer' when x.type in ('loan_receipt','loan_repayment','owner_capital','balance_adjustment','owner_withdrawal') then 'financing'
 when x.type in ('asset_purchase','asset_proceeds','asset_disposal_expense') then 'investing' else 'operating' end cash_category
 from attributed l join public.wallet_transactions x on x.tenant_id=l.tenant_id and x.transaction_id=l.source_id where l.account='cash' and l.source='wallet'),
 buckets as(select d::date period from generate_series(date_trunc(grain,f::timestamp),date_trunc(grain,u::timestamp),('1 '||grain)::interval)d),
 activity_trend as(select date_trunc(grain,occurred_on)::date period,coalesce(-sum(amount) filter(where kind='income'),0) revenue,coalesce(sum(amount) filter(where kind='expense'),0) expenses
 from attributed group by 1),
 cash_trend as(select date_trunc(grain,occurred_on)::date period,sum(greatest(0,amount)) cash_in,-sum(least(0,amount)) cash_out,sum(amount) cash_flow from cash where cash_category<>'transfer' group by 1),
 position_events as (
 select b.tenant_id,b.account,b.entity_id,date_trunc(grain,f::timestamp)::date period,b.amount
 from app_private.accounting_balances(ids,f,true,original)b join public.accounting_accounts a on a.code=b.account where a.kind in ('asset','liability')
 union all
 select l.tenant_id,l.account,l.entity_id,date_trunc(grain,j.occurred_on)::date,l.amount
 from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) join public.accounting_accounts a on a.code=l.account
 where j.tenant_id=any(ids) and j.occurred_on between f and u and not(original and j.is_opening and j.occurred_on=f) and a.kind in ('asset','liability')),
 position_deltas as(select tenant_id,account,entity_id,period,sum(amount) amount from position_events group by 1,2,3,4),
 position_running as(select *,sum(amount) over(partition by tenant_id,account,entity_id order by period) balance from position_deltas),
 position_changes as(select *,greatest(balance,0)-greatest(lag(balance,1,0::numeric) over(partition by tenant_id,account,entity_id order by period),0) asset_change,
 -least(balance,0)+least(lag(balance,1,0::numeric) over(partition by tenant_id,account,entity_id order by period),0) liability_change from position_running),
 position_trend as(select period,sum(asset_change) asset_change,sum(liability_change) liability_change from position_changes group by period),
 trend as(select b.period,greatest(f,b.period) period_start,least(u,(b.period+('1 '||grain)::interval-interval '1 day')::date) period_end,
 coalesce(a.revenue,0) revenue,coalesce(a.expenses,0) expenses,coalesce(a.revenue,0)-coalesce(a.expenses,0) profit,
 coalesce(c.cash_in,0) cash_in,coalesce(c.cash_out,0) cash_out,coalesce(c.cash_flow,0) cash_flow,
 sum(coalesce(p.asset_change,0)) over(order by b.period) assets,sum(coalesce(p.liability_change,0)) over(order by b.period) liabilities,
 sum(coalesce(p.asset_change,0)-coalesce(p.liability_change,0)) over(order by b.period) net_worth
 from buckets b left join activity_trend a using(period) left join cash_trend c using(period) left join position_trend p using(period)),
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
 'all_time',original,'period_income',(closing->>'accumulated_income')::numeric-(opening->>'accumulated_income')::numeric,
 'invested_capital',closing->'capital','retained_earnings',closing->'accumulated_income','capital_recorded',closing->'capital','withdrawals_to_date',closing->'withdrawals') into result from totals;
 return result;end $$;
-- Recognition runs first. Every subsequent figure is then read through one
-- STABLE function's MVCC snapshot, including both positions and trend windows.
create or replace function public.get_finance_analysis(p_filters jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare ids uuid[]:=app_private.analysis_scope(p_filters);r record;f date:=(p_filters->>'from')::date;u date:=(p_filters->>'to')::date;begin
 if f is null or u is null or not isfinite(f) or not isfinite(u) or f>u or u>(now() at time zone 'Asia/Dhaka')::date then raise exception 'Choose a valid reporting period';end if;
 for r in select unnest(ids) id loop perform app_private.sync_payroll(r.id);end loop;
 return app_private.finance_analysis_report(p_filters);end $$;
revoke all on function app_private.finance_analysis_report(jsonb) from public,anon,authenticated;
alter function app_private.finance_analysis_report(jsonb) owner to postgres;


create function app_private.analysis_entity(t uuid,code text,id uuid) returns jsonb language plpgsql stable set search_path='' as $$
declare label text;k text;ref uuid:=id;begin
 if id is null then select a.name into label from public.accounting_accounts a where a.code=analysis_entity.code;
 elsif code='cash' then select name,'wallet' into label,k from public.wallets where tenant_id=t and wallet_id=id;
 elsif code in ('inventory_lpg','inventory_stove') then
  select coalesce(i.product_name,concat_ws(' ',b.brand_name,i.size_kg||' kg',i.mouth_size)),'product' into label,k from public.items i left join public.lpg_brands b using(tenant_id,brand_id) where i.tenant_id=t and i.item_id=id;
 elsif code='customer_receivable' then select coalesce(nullif(shop_name,''),name),'customer' into label,k from public.customers where tenant_id=t and customer_id=id;
 elsif code='loan_payable' then select lender,'loan' into label,k from public.loans where tenant_id=t and loan_id=id;
 elsif code in ('vehicles','equipment','other_assets') then select name,'asset' into label,k from public.business_assets where tenant_id=t and asset_id=id;
 elsif code in ('supplier_payable','inventory_transit') then select coalesce(supplier_name,'Supplier')||' · Purchase #'||left(id::text,8),'purchase' into label,k from public.purchases where tenant_id=t and purchase_id=id;
 elsif code='bottle_receivable' then select 'Cylinders · Sale #'||left(id::text,8),'sale' into label,k from public.sales where tenant_id=t and sale_id=id;
 elsif code='supplier_receivable' then select supplier_name,'commission' into label,k from public.supplier_commissions where tenant_id=t and commission_id=id;
 elsif code='employee_payable' then select name,'employee' into label,k from public.employees where tenant_id=t and employee_id=id;
 end if;
 if label is null then select description,'obligation' into label,k from public.finance_obligations where tenant_id=t and obligation_id=id;end if;
 if label is null then select 'Journey · '||destination||' #'||left(id::text,8),'transit' into label,k from public.transits where tenant_id=t and transit_id=id;end if;
 if label is null then select a.name into label from public.accounting_accounts a where a.code=analysis_entity.code;end if;
 return jsonb_build_object('entity_name',label,'record_kind',k,'record_id',ref);end $$;

create function app_private.analysis_matches(g text,code text,kind text) returns boolean language sql immutable set search_path='' as $$select
 case g when 'assets' then kind='asset' when 'liabilities' then kind='liability' when 'equity' then kind in ('equity','income','expense') when 'accumulated_income' then kind in ('income','expense')
 else app_private.analysis_group(code,kind)=g end;$$;

-- Component and movement pages share exactly the same historical cutoff and
-- net control-account classification, including supplier/payroll advances.
create function public.get_accounting_breakdown(p_filters jsonb,p_group text,p_side text,p_mode text default 'components',p_offset integer default 0,p_limit integer default 20) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare ids uuid[]:=app_private.analysis_scope(p_filters);d date:=(p_filters->>'to')::date;f date:=(p_filters->>'from')::date;original boolean:=false;before_day boolean:=false;r jsonb;begin
 if p_side not in ('opening','closing','period') or p_mode not in ('components','history') or p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100
 or p_group not in ('assets','liabilities','equity','accumulated_income','cash','inventory','receivables','fixed_assets','other_assets','dues','employees','other_liabilities','capital','revenue','expenses','withdrawals','other_equity')
 or f is null or d is null or not isfinite(f) or not isfinite(d) or f>d or d>(now() at time zone 'Asia/Dhaka')::date or length(coalesce(p_filters->>'search',''))>500 then raise exception 'Invalid breakdown filters';end if;
 if coalesce((p_filters->>'all_time')::boolean,false) then select min((started_at at time zone 'Asia/Dhaka')::date) into f from public.accounting_periods where tenant_id=any(ids);f:=least(f,d);end if;
 if p_side='opening' then
  before_day:=true;d:=f;original:=coalesce((p_filters->>'all_time')::boolean,false);
 end if;
 with evidence as (select * from app_private.accounting_balances(ids,d,before_day,original) union all select tenant_id,account,business_category,entity_id,-amount from app_private.accounting_balances(ids,f,true,coalesce((p_filters->>'all_time')::boolean,false)) where p_side='period'),
 balances as materialized(select b.tenant_id,b.account,b.entity_id,a.kind,a.name,sum(b.amount) amount
 from evidence b join public.accounting_accounts a on a.code=b.account group by 1,2,3,4,5),
 classified as(select *,case when kind='liability' and amount>0 then 'asset' when kind='asset' and amount<0 then 'liability' else kind end reported_kind from balances),
 selected as materialized(select *,case when p_group='withdrawals' then 1 when p_group in ('equity','accumulated_income') or reported_kind in ('liability','income','equity') then -1 else 1 end sign
 from classified where app_private.analysis_matches(p_group,account,reported_kind)
 and (nullif(p_filters->>'account','') is null or account=p_filters->>'account') and (nullif(p_filters->>'entity_id','') is null or p_filters->>'entity_id'='none' and entity_id is null or entity_id=nullif(nullif(p_filters->>'entity_id',''),'none')::uuid)),
 described as materialized(select s.*,app_private.analysis_entity(tenant_id,account,entity_id) entity from selected s),
 components as materialized(select * from described where amount<>0 and app_private.finance_search(concat_ws(' ',name,entity->>'entity_name'),coalesce(p_filters->>'search',''))),
 component_page as(select * from components order by abs(amount) desc,tenant_id,account,entity_id nulls first offset p_offset limit p_limit),
 movements as materialized(select j.tenant_id,j.journal_id,j.entry_no,j.occurred_on,j.description,j.source,j.source_id,j.estimated,l.line_no,l.account,s.name,l.entity_id,l.amount*s.sign amount,s.entity,
 case j.source when 'wallet' then (select x.reference_id from public.wallet_transactions x where x.tenant_id=j.tenant_id and x.transaction_id=j.source_id)
 when 'inventory' then (select x.reference_id from public.inventory_movements x where x.tenant_id=j.tenant_id and x.movement_id=j.source_id) else j.source_id end transaction_reference
 from described s join public.accounting_lines l on l.tenant_id=s.tenant_id and l.account=s.account and l.entity_id is not distinct from s.entity_id
 join public.accounting_journals j on j.tenant_id=l.tenant_id and j.journal_id=l.journal_id
 where p_mode='history' and (p_side<>'period' or j.occurred_on>=f) and (case when before_day then j.occurred_on<d or original and j.is_opening and j.occurred_on=d else j.occurred_on<=d end)
 and (nullif(p_filters->>'history_from','') is null or j.occurred_on>=(p_filters->>'history_from')::date)
 and (nullif(p_filters->>'source','') is null or j.source=p_filters->>'source')
 and app_private.finance_search(concat_ws(' ',j.description,s.name,s.entity->>'entity_name',j.source,j.source_id),coalesce(p_filters->>'search',''))),
 history_page as(select * from movements order by occurred_on desc,entry_no desc,line_no offset p_offset limit p_limit)
 select jsonb_build_object('cutoff',case when before_day and not original then d-1 else d end,'original_opening',original,
 'balance',coalesce((select sum(amount*sign) from selected),0),
 'total',case when p_mode='components' then (select count(*) from components) else (select count(*) from movements) end,
 'filtered_movement',case when p_mode='history' then (select coalesce(sum(amount),0) from movements) end,
 'entries',case when p_mode='components' then coalesce((select jsonb_agg(jsonb_build_object('tenant_id',tenant_id,'account',account,'name',name,'kind',reported_kind,'entity_id',entity_id,'amount',amount*sign)||entity order by abs(amount) desc,tenant_id,account,entity_id nulls first) from component_page),'[]')
 else coalesce((select jsonb_agg((to_jsonb(p)-'entity')||entity order by occurred_on desc,entry_no desc,line_no) from history_page p),'[]') end) into r;return r;end $$;
revoke all on function public.get_accounting_breakdown(jsonb,text,text,text,integer,integer) from public,anon;
grant execute on function public.get_accounting_breakdown(jsonb,text,text,text,integer,integer) to authenticated;

do $$declare n text;begin
 foreach n in array array['accounting_snapshot_state','accounting_snapshots','accounting_snapshot_lines','accounting_snapshot_audit'] loop
 execute format('alter table app_private.%I enable row level security',n);
 execute format('revoke all on app_private.%I from public,anon,authenticated',n);end loop;
end $$;
revoke all on function app_private.invalidate_accounting_snapshots(),app_private.accounting_balances(uuid[],date,boolean,boolean),app_private.build_accounting_snapshots(uuid,integer),app_private.position_from_balances(jsonb),app_private.analysis_group(text,text),app_private.analysis_entity(uuid,text,uuid),app_private.analysis_matches(text,text,text) from public,anon,authenticated;


do $$declare f record;begin
 alter table app_private.accounting_snapshot_state owner to postgres;
 alter table app_private.accounting_snapshots owner to postgres;
 alter table app_private.accounting_snapshot_lines owner to postgres;
 alter table app_private.accounting_snapshot_audit owner to postgres;
 for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace where ns.nspname in ('app_private','public') and p.proname in ('invalidate_accounting_snapshots','accounting_balances','build_accounting_snapshots','position_from_balances','analysis_group','analysis_entity','analysis_matches','get_accounting_breakdown') loop execute format('alter function %s owner to postgres',f.signature);end loop;
end $$;
