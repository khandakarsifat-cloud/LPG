-- Aggregate entity balances before returning positions, keeping advances and
-- overdrafts on the correct side without returning every customer or purchase.
create or replace function app_private.accounting_position(ids uuid[],as_of date,before_day boolean default false) returns jsonb language sql stable set search_path='' as $$
 with balances as(select l.tenant_id,l.account,l.entity_id,a.name,a.kind,sum(l.amount) balance from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) join public.accounting_accounts a on a.code=l.account
 where l.tenant_id=any(ids) and (case when before_day then j.occurred_on<as_of or j.is_opening and j.occurred_on=as_of else j.occurred_on<=as_of end) group by l.tenant_id,l.account,l.entity_id,a.name,a.kind),
 classified as(select *,case when kind='liability' and balance>0 then 'asset' when kind='asset' and balance<0 then 'liability' else kind end reported_kind from balances),
 summary as(select tenant_id,account,name,kind,reported_kind,case when account='cash' then entity_id end entity_id,sum(balance) balance from classified group by tenant_id,account,name,kind,reported_kind,case when account='cash' then entity_id end)
 select jsonb_build_object('assets',coalesce(sum(s.balance) filter(where reported_kind='asset'),0),'liabilities',coalesce(-sum(s.balance) filter(where reported_kind='liability'),0),
 'equity',coalesce(-sum(s.balance) filter(where s.kind in ('equity','income','expense')),0),'cash',coalesce(sum(s.balance) filter(where account='cash'),0),
 'accounts',coalesce(jsonb_agg(jsonb_build_object('tenant_id',s.tenant_id,'account',account,'name',s.name,'kind',reported_kind,'entity_id',entity_id,'entity_name',w.name,
 'amount',case when reported_kind in ('asset','expense') then s.balance else -s.balance end) order by reported_kind,s.name,s.tenant_id,entity_id) filter(where s.balance<>0),'[]'))
 from summary s left join public.wallets w on w.tenant_id=s.tenant_id and w.wallet_id=s.entity_id and s.account='cash';$$;

-- Canonical report aggregates; empty earlier periods have a verified zero position.
create or replace function public.get_finance_analysis(p_filters jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare ids uuid[]:=app_private.analysis_scope(p_filters);f date:=(p_filters->>'from')::date;u date:=(p_filters->>'to')::date;cat text:=coalesce(p_filters->>'category','all');
 grain text:=coalesce(p_filters->>'grain','month');opening jsonb;closing jsonb;result jsonb;r record;coverage boolean;estimated boolean;missing bigint;begin
 if f is null or u is null or not isfinite(f) or not isfinite(u) or f>u or u>(now() at time zone 'Asia/Dhaka')::date or u-f>36525 or grain not in ('day','month','year') or grain='day' and u-f>730 or cat not in ('all','lpg','stove','logistics','shared') then raise exception 'Choose a valid reporting period and business activity';end if;
 for r in select unnest(ids) id loop perform app_private.sync_payroll(r.id);end loop;
 select bool_and(true),bool_or(a.estimated) into coverage,estimated from public.accounting_periods a where tenant_id=any(ids);
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
 coalesce(-sum(amount) filter(where account in ('opening_equity','equity_adjustment')),0)+coalesce((
 select -sum(l.amount) from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id)
 where j.tenant_id=any(ids) and j.is_opening and j.occurred_on>f and j.occurred_on<=u
 and l.account in ('opening_equity','equity_adjustment') and (cat='all' or l.business_category=cat)),0) equity_adjustments,
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
 position_trend as(select date_trunc(grain,j.occurred_on)::date period,sum(l.amount) change
 from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) join public.accounting_accounts a on a.code=l.account
 where j.tenant_id=any(ids) and j.occurred_on between f and u and not(j.is_opening and j.occurred_on=f) and a.kind in ('asset','liability') group by 1),
 trend as(select b.period,coalesce(a.revenue,0) revenue,coalesce(a.expenses,0) expenses,coalesce(a.revenue,0)-coalesce(a.expenses,0) profit,
 coalesce(c.cash_in,0) cash_in,coalesce(c.cash_out,0) cash_out,coalesce(c.cash_flow,0) cash_flow,
 (opening->>'equity')::numeric+sum(coalesce(p.change,0)) over(order by b.period) net_worth
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
 'invested_capital',coalesce((select sum(-l.amount) from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where l.tenant_id=any(ids) and l.account in ('capital','opening_equity') and j.occurred_on<=u),0),
 'retained_earnings',coalesce((select -sum(l.amount) from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) join public.accounting_accounts a on a.code=l.account where l.tenant_id=any(ids) and a.kind in ('income','expense') and j.occurred_on<=u),0),
 'capital_recorded',coalesce((select sum(-l.amount) from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where l.tenant_id=any(ids) and l.account='capital' and j.occurred_on<=u),0),
 'withdrawals_to_date',coalesce((select sum(l.amount) from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where l.tenant_id=any(ids) and l.account='withdrawals' and j.occurred_on<=u),0)) into result from totals;
 return result;end $$;

-- Page headers before fetching any lines. Expanded entries use their own
-- bounded server page, including opening journals with thousands of lines.
create or replace function public.get_analysis_details(p_filters jsonb,p_metric text,p_category text default null,p_offset integer default 0,p_limit integer default 12) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare ids uuid[]:=app_private.analysis_scope(p_filters);r jsonb;f date:=(p_filters->>'from')::date;u date:=(p_filters->>'to')::date;begin
 if p_metric is distinct from 'journal' or p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 or f is null or u is null or not isfinite(f) or not isfinite(u) or f>u or length(coalesce(p_filters->>'search',''))>500 then raise exception 'Invalid journal filters';end if;
 with matching as materialized(select j.* from public.accounting_journals j where j.tenant_id=any(ids) and j.occurred_on between f and u
 and (nullif(p_filters->>'source','') is null or j.source=p_filters->>'source')
 and app_private.finance_search(concat_ws(' ',j.description,j.source,j.source_id,j.entry_no),coalesce(p_filters->>'search',''))
 and (coalesce(p_filters->>'category','all')='all' or exists(select 1 from public.accounting_lines l where l.tenant_id=j.tenant_id and l.journal_id=j.journal_id and l.business_category=p_filters->>'category'))
 and (p_category is null or exists(select 1 from public.accounting_lines l where l.tenant_id=j.tenant_id and l.journal_id=j.journal_id and l.account=p_category))),
 page as materialized(select * from matching order by occurred_on desc,entry_no desc offset p_offset limit p_limit),
 details as(select p.*,(select count(*) from public.accounting_lines l where l.tenant_id=p.tenant_id and l.journal_id=p.journal_id) line_count,
 coalesce((select sum(greatest(0,l.amount)) from public.accounting_lines l where l.tenant_id=p.tenant_id and l.journal_id=p.journal_id),0) total_debit,
 case p.source when 'wallet' then (select x.reference_id from public.wallet_transactions x where x.tenant_id=p.tenant_id and x.transaction_id=p.source_id)
 when 'inventory' then (select m.reference_id from public.inventory_movements m where m.tenant_id=p.tenant_id and m.movement_id=p.source_id) else p.source_id end transaction_reference from page p)
 select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(to_jsonb(p) order by occurred_on desc,entry_no desc) from details p),'[]'),
 'sources',coalesce((select jsonb_agg(source order by source) from(select distinct source from public.accounting_journals where tenant_id=any(ids) and occurred_on between f and u)s),'[]')) into r;return r;end $$;

create function public.get_journal_lines(p_filters jsonb,p_journal_id uuid,p_offset integer default 0,p_limit integer default 25) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare ids uuid[]:=app_private.analysis_scope(p_filters);t uuid;r jsonb;begin
 if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid line page';end if;
 select tenant_id into t from public.accounting_journals where tenant_id=any(ids) and journal_id=p_journal_id;
 if t is null then raise exception 'Journal not found' using errcode='42501';end if;
 with page as materialized(select l.* from public.accounting_lines l where tenant_id=t and journal_id=p_journal_id order by line_no offset p_offset limit p_limit),
 described as(select l.line_no,a.name account,l.account account_code,l.amount,l.business_category,l.entity_id,l.details,
 coalesce(w.name,i.product_name,case when i.item_id is not null then concat_ws(' ',b.brand_name,i.size_kg||' kg',i.mouth_size) end,
 c.shop_name,c.name,ba.name,lo.lender,sc.supplier_name,
 case when p.purchase_id is not null then coalesce(p.supplier_name,pb.brand_name,'Supplier')||' · Purchase #'||left(p.purchase_id::text,8) end,
 case when tr.transit_id is not null then concat_ws(' · ',v.name,tr.destination,'Journey #'||left(tr.transit_id::text,8)) end,em.name,o.description,
 nullif(l.details->>'description',''),a.name) entity_name
 from page l join public.accounting_accounts a on a.code=l.account
 left join public.wallets w on l.account='cash' and w.tenant_id=t and w.wallet_id=l.entity_id
 left join public.items i on l.account in ('inventory_lpg','inventory_stove') and i.tenant_id=t and i.item_id=l.entity_id
 left join public.lpg_brands b on b.tenant_id=t and b.brand_id=i.brand_id
 left join public.customers c on l.account='customer_receivable' and c.tenant_id=t and c.customer_id=l.entity_id
 left join public.business_assets ba on l.account in ('vehicles','equipment','other_assets') and ba.tenant_id=t and ba.asset_id=l.entity_id
 left join public.loans lo on l.account='loan_payable' and lo.tenant_id=t and lo.loan_id=l.entity_id
 left join public.supplier_commissions sc on l.account='supplier_receivable' and sc.tenant_id=t and sc.commission_id=l.entity_id
 left join public.purchases p on l.account in ('supplier_payable','inventory_transit') and p.tenant_id=t and p.purchase_id=l.entity_id
 left join public.lpg_brands pb on pb.tenant_id=t and pb.brand_id=p.brand_id
 left join public.transits tr on l.account in ('transport_receivable','operating_payable','employee_payable') and tr.tenant_id=t and tr.transit_id=l.entity_id
 left join public.vehicles v on v.tenant_id=t and v.vehicle_id=tr.vehicle_id
 left join public.employees em on l.account='employee_payable' and em.tenant_id=t and em.employee_id=l.entity_id
 left join public.finance_obligations o on o.tenant_id=t and o.entity_id=l.entity_id and o.obligation_id=l.entity_id)
 select jsonb_build_object('total',(select count(*) from public.accounting_lines where tenant_id=t and journal_id=p_journal_id),'entries',coalesce((select jsonb_agg(to_jsonb(d) order by line_no) from described d),'[]')) into r;return r;end $$;
alter function public.get_journal_lines(jsonb,uuid,integer,integer) owner to postgres;
revoke all on function public.get_journal_lines(jsonb,uuid,integer,integer) from public,anon;
grant execute on function public.get_journal_lines(jsonb,uuid,integer,integer) to authenticated;
