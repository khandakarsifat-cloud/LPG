-- Combined is additive business reporting. Historical journals and FIFO evidence remain immutable.
CREATE OR REPLACE FUNCTION app_private.scoped_position(ids uuid[], d date, business text, before_day boolean DEFAULT false, original boolean DEFAULT false)
RETURNS jsonb LANGUAGE sql STABLE SET search_path='' AS $function$
with positions as (
 select app_private.position_from_balances(coalesce(jsonb_agg(jsonb_build_object('tenant_id',b.tenant_id,'account',b.account,'entity_id',b.entity_id,'amount',b.amount)),'[]')) value
 from unnest(case when business='all' then array['lpg','stove','logistics'] else array[business] end) category
 left join lateral(select * from app_private.dimensional_balances(ids,d,before_day,original) x where x.business_category=category)b on true
 group by category
), numbers as(select k,sum(v::numeric) value from positions cross join lateral jsonb_each_text(value-'accounts') e(k,v) group by k), accounts as(select a from positions cross join lateral jsonb_array_elements(value->'accounts') a)
select (select jsonb_object_agg(k,value) from numbers)||jsonb_build_object('accounts',coalesce((select jsonb_agg(a) from accounts),'[]'));
$function$;
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
 coalesce(sum(amount) filter(where account='cash' and amount>0 and description is not null and source='wallet'),0) gross_cash_in,
 coalesce(-sum(amount) filter(where account='cash' and amount<0 and source='wallet'),0) gross_cash_out from attributed),
 cash as materialized(select l.*,x.type,
 case when x.type='custom_entry' then (select case when e.account in ('capital','withdrawals') then 'financing' when e.account in ('equipment','other_assets') then 'investing' else 'operating' end from public.financial_entries e where e.tenant_id=x.tenant_id and e.entry_id=x.reference_id) when x.type='obligation_settlement' then coalesce((select o.cash_activity from public.finance_obligations o where o.tenant_id=x.tenant_id and o.obligation_id=x.reference_id),'unclassified') when x.type in ('loan_lend','loan_collect') then 'investing' when x.type in ('loan_receipt','loan_repayment','owner_capital','balance_adjustment','owner_withdrawal') then 'financing'
 when x.type in ('asset_purchase','asset_proceeds','asset_disposal_expense') then 'investing' else 'operating' end cash_category
 from attributed l join public.wallet_transactions x on x.tenant_id=l.tenant_id and x.transaction_id=l.source_id where l.account='cash' and l.source='wallet'),
 buckets as(select d::date period from generate_series(date_trunc(grain,f::timestamp),date_trunc(grain,u::timestamp),('1 '||grain)::interval)d),
 activity_trend as(select date_trunc(grain,occurred_on)::date period,coalesce(-sum(amount) filter(where kind='income'),0) revenue,coalesce(sum(amount) filter(where kind='expense'),0) expenses
 from attributed group by 1),
 cash_trend as(select date_trunc(grain,occurred_on)::date period,sum(greatest(0,amount)) cash_in,-sum(least(0,amount)) cash_out,sum(amount) cash_flow from cash group by 1),
 position_events as (
 select b.tenant_id,b.account,case when b.account='cash' then null::uuid else b.entity_id end entity_id,b.business_category,date_trunc(grain,f::timestamp)::date period,b.amount amount
 from app_private.dimensional_balances(ids,f,true,original)b join public.accounting_accounts a on a.code=b.account where (cat='all' or b.business_category=cat) and a.kind in ('asset','liability')
 union all
 select l.tenant_id,l.account,case when l.account='cash' then null::uuid else l.entity_id end,l.business_category,date_trunc(grain,j.occurred_on)::date,l.amount
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
 'stock_acquisitions',coalesce(sum(case when account='inventory_transit' and code in ('purchase','internal_transport') then amount when account in ('inventory_lpg','inventory_stove') and code in ('inventory_capital','inventory_gain') then amount else 0 end),0),
 'stock_change',coalesce(sum(amount) filter(where account in ('inventory_lpg','inventory_stove','inventory_transit','bottle_receivable')),0),
 'equipment_acquisitions',coalesce(sum(amount) filter(where account in ('equipment','vehicles','other_assets') and (code in ('asset_register','asset_improve') or origin='custom') and amount>0),0),
 'receivable_change',coalesce(sum(amount) filter(where account in ('customer_receivable','transport_receivable','supplier_receivable')),0),
 'payable_change',coalesce(-sum(amount) filter(where account in ('supplier_payable','employee_payable','operating_payable','other_liability')),0),
 'loan_movement',coalesce(-sum(amount) filter(where account='loan_payable'),0),
 'wallet_movement',coalesce(sum(amount) filter(where account='cash'),0)) into r from lines;return r;end $function$;
CREATE OR REPLACE FUNCTION public.get_accounting_breakdown(p_filters jsonb, p_group text, p_side text, p_mode text DEFAULT 'components'::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$declare
 ids uuid[]:=app_private.analysis_scope(p_filters);d date:=(p_filters->>'to')::date;f date:=(p_filters->>'from')::date;
 cat text:=coalesce(p_filters->>'category','all');original boolean:=false;before_day boolean:=false;r jsonb;begin
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
 case when a.kind in ('income','expense','equity') or b.account='cash' then null else b.entity_id end entity_id,a.kind,a.name,
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
 movements as materialized(select j.tenant_id,j.journal_id,j.entry_no,j.occurred_on,j.description,j.source,j.source_id,j.source_id transaction_reference,j.estimated,l.line_no,l.account,s.name,l.type_id,s.type_name,l.business_category,l.entity_id,
 (l.amount)*s.sign amount,app_private.analysis_entity(l.tenant_id,l.account,l.entity_id)||app_private.financial_source_link(j.tenant_id,j.source,j.source_id) entity
 from described s join public.accounting_lines l on l.tenant_id=s.tenant_id and l.account=s.account and l.type_id=s.type_id and l.business_category=s.business_category
 and (s.kind in ('income','expense','equity') or s.account='cash' or l.entity_id is not distinct from s.entity_id)
 join public.accounting_journals j on j.tenant_id=l.tenant_id and j.journal_id=l.journal_id
 where p_mode='history' and (p_side<>'period' or j.occurred_on>=f) and (case when before_day then j.occurred_on<d or original and j.is_opening and j.occurred_on=d else j.occurred_on<=d end)
 and (nullif(p_filters->>'history_from','') is null or j.occurred_on>=(p_filters->>'history_from')::date)
 and (nullif(p_filters->>'source','') is null or j.source=p_filters->>'source')
 and app_private.finance_search(concat_ws(' ',j.description,s.name,s.type_name,s.business_category,s.entity->>'entity_name',j.source,j.source_id),coalesce(p_filters->>'search',''))),
 filtered_movements as materialized(select * from movements where
 (nullif(p_filters->>'min','') is null or abs(amount)>=(p_filters->>'min')::numeric)
 and (nullif(p_filters->>'max','') is null or abs(amount)<=(p_filters->>'max')::numeric)
 and (coalesce(p_filters->>'direction','all')='all' or p_filters->>'direction'='increase' and amount>0 or p_filters->>'direction'='decrease' and amount<0)),
 history_page as(select * from filtered_movements order by
 case when p_filters->>'sort'='oldest' then occurred_on end asc,
 case when p_filters->>'sort'='largest' then abs(amount) end desc,
 case when p_filters->>'sort'='smallest' then abs(amount) end asc,
 occurred_on desc,entry_no desc,line_no offset p_offset limit p_limit)
 select jsonb_build_object('cutoff',case when before_day and not original then d-1 else d end,'original_opening',original,'accounts',(select jsonb_agg(jsonb_build_object('code',code,'name',name) order by name) from public.accounting_accounts),'sources',coalesce((select jsonb_agg(source order by source) from(select distinct source from public.accounting_journals where tenant_id=any(ids)) sources),'[]'::jsonb),
 'balance',coalesce((select sum(amount*sign) from selected),0),
 'total',case when p_mode='components' then (select count(*) from components) else (select count(*) from filtered_movements) end,
 'filtered_movement',case when p_mode='history' then (select coalesce(sum(amount),0) from filtered_movements) end,
 'entries',case when p_mode='components' then coalesce((select jsonb_agg(jsonb_build_object('tenant_id',tenant_id,'account',account,'name',name,'kind',reported_kind,'entity_id',entity_id,'type_id',type_id,'type_name',type_name,'business_category',business_category,'amount',amount*sign)||entity order by abs(amount) desc,tenant_id,account,type_id,business_category,entity_id nulls first) from component_page),'[]')
 else coalesce((select jsonb_agg((to_jsonb(p)-'entity')||entity order by case when p_filters->>'sort'='oldest' then occurred_on end asc,case when p_filters->>'sort'='largest' then abs(amount) end desc,case when p_filters->>'sort'='smallest' then abs(amount) end asc,occurred_on desc,entry_no desc,line_no) from history_page p),'[]') end) into r;return r;end $function$;
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
 with page as(select l.line_no,l.account account_code,a.name account,l.amount,l.consolidated_amount,l.business_category,l.type_id,case ft.code when 'internal_inventory' then 'Transport in Supplies' when 'internal_cogs' then 'Transport COGS' when 'internal_transport' then 'Purchase transport' else ft.name end type_name,l.entity_id,
 app_private.analysis_entity(l.tenant_id,l.account,l.entity_id)->>'entity_name' entity_name
 from public.accounting_lines l join public.accounting_accounts a on a.code=l.account join public.financial_types ft using(type_id)
 where l.tenant_id=t and l.journal_id=p_journal_id order by l.line_no offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from public.accounting_lines where tenant_id=t and journal_id=p_journal_id),'entries',coalesce((select jsonb_agg(to_jsonb(p) order by line_no) from page p),'[]')) into r;return r;end $function$;
CREATE OR REPLACE FUNCTION app_private.dashboard_snapshot(t uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare d date:=(now() at time zone 'Asia/Dhaka')::date;r jsonb;
 finance boolean:=app_private.has_any_permission(array['finance:view','finance:manage']);
 customers boolean:=app_private.has_any_permission(array['customers:view','customers:manage']);
 inventory boolean:=app_private.has_any_permission(array['inventory:view','inventory:manage']);
begin
 with days as (select generate_series(d-6,d,interval '1 day')::date business_day),
 recognition as materialized(
  select j.occurred_on business_day,
   coalesce(-sum(l.amount) filter(where case when finance then a.kind='income' else l.account='sales_revenue' end),0) revenue,
   case when finance then coalesce(sum(l.amount) filter(where a.kind='expense'),0) end expense
  from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) join public.accounting_accounts a on a.code=l.account
  where j.tenant_id=t and j.occurred_on between d-6 and d and not j.is_opening group by j.occurred_on),
 collections as (select (p.created_at at time zone 'Asia/Dhaka')::date business_day,sum(p.amount) collected
  from public.sale_payments p where p.tenant_id=t and p.created_at >= (d-6)::timestamp at time zone 'Asia/Dhaka'
  and p.created_at < (d+1)::timestamp at time zone 'Asia/Dhaka' group by 1),
 sale_counts as (select (s.created_at at time zone 'Asia/Dhaka')::date business_day,count(*) sales
  from public.sales s where s.tenant_id=t and s.status='completed' and s.created_at >= (d-6)::timestamp at time zone 'Asia/Dhaka'
  and s.created_at < (d+1)::timestamp at time zone 'Asia/Dhaka' group by 1),
 today_sales as materialized(select s.* from public.sales s where s.tenant_id=t and s.status='completed'
  and s.created_at>=d::timestamp at time zone 'Asia/Dhaka' and s.created_at<(d+1)::timestamp at time zone 'Asia/Dhaka'),
 sold as materialized(select i.item_id,i.size_kg,i.business_category,i.product_name,i.image_url,sum(si.quantity) quantity
  from today_sales s join public.sale_items si using(tenant_id,sale_id) join public.items i using(tenant_id,item_id)
  where si.type in ('refill','package') group by i.item_id,i.size_kg,i.business_category,i.product_name,i.image_url),
 expected as (select si.sale_id,sum(si.quantity) quantity from public.sale_items si where customers and si.tenant_id=t and si.type='empty_return' group by si.sale_id),
 received as (select b.sale_id,sum(b.quantity) quantity from public.sale_bottle_receipt_lines b where customers and b.tenant_id=t group by b.sale_id),
 bottle_due as materialized(select s.customer_id,greatest(0,e.quantity-coalesce(b.quantity,0)) quantity
  from expected e join public.sales s on s.tenant_id=t and s.sale_id=e.sale_id left join received b on b.sale_id=e.sale_id where s.status='completed'),
 weights as (select size_kg from public.business_weights where tenant_id=t and is_active
  union select size_kg from sold where business_category='lpg')
 select jsonb_build_object('date',d,'generated_at',now(),'finance_visible',finance,
 'days',(select jsonb_agg(jsonb_build_object('date',days.business_day,'revenue',coalesce(x.revenue,0),'expense',case when finance then coalesce(x.expense,0) end,
  'collected',coalesce(c.collected,0),'sales',coalesce(s.sales,0)) order by days.business_day) from days left join recognition x using(business_day) left join collections c using(business_day) left join sale_counts s using(business_day)),
 'bottles',coalesce((select jsonb_agg(jsonb_build_object('size_kg',w.size_kg,'quantity',coalesce((select sum(quantity) from sold where business_category='lpg' and size_kg=w.size_kg),0)) order by w.size_kg) from weights w),'[]'),
 'stove_types',app_private.dashboard_stove_types(t),
 'attention',jsonb_build_object(
  'customer_due',case when customers then (select coalesce(sum(total_due),0) from app_private.customer_metrics where tenant_id=t and total_due>0) end,
  'customers',case when customers then (select count(*) from app_private.customer_metrics where tenant_id=t and total_due>0) end,
  'bottles',case when customers then (select coalesce(sum(quantity),0) from bottle_due) end,
  'bottle_customers',case when customers then (select count(distinct customer_id) from bottle_due where quantity>0) end,
  'low_stock',case when inventory then (select count(*) from public.items where tenant_id=t and filled_quantity<low_stock_threshold) end),
 'sales',coalesce((select jsonb_agg(x order by x.created_at desc,x.sale_id desc) from (
  select s.sale_id,s.created_at,s.total_amount+s.additional_charges amount,coalesce(c.shop_name,c.name,'Customer') customer,
   (select string_agg(coalesce(i.product_name,'LPG '||i.size_kg||' kg')||' × '||si.quantity||case when si.type='package' then ' (Package)' else '' end,', ' order by si.item_id,si.type)
    from public.sale_items si join public.items i using(tenant_id,item_id) where si.tenant_id=t and si.sale_id=s.sale_id and si.type<>'empty_return') items
  from today_sales s left join public.customers c using(tenant_id,customer_id) order by s.created_at desc,s.sale_id desc limit 5)x),'[]'),
 'activity',public.get_dashboard_activity(0,6)) into r;
 return r;
end $function$;
notify pgrst,'reload schema';
