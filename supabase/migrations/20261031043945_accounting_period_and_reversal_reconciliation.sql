-- Opening entries on the first reporting day already belong to its opening
-- position. Later supplemental opening evidence changes net assets within the
-- period, so deduct its equity movement when reconciling period profit. Neither
-- case creates revenue, expense or operating cash flow.
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
alter function public.get_finance_analysis(jsonb) owner to postgres;
revoke all on function public.get_finance_analysis(jsonb) from public,anon;
grant execute on function public.get_finance_analysis(jsonb) to authenticated;

-- Keep cancelled physical bottle receipts and their income classification aligned.
create or replace function public.reverse_sale(p_sale_id uuid,p_reason text,p_confirmation text,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_owner('finance:manage');s public.sales;prior public.finance_requests;body jsonb:=jsonb_build_object('action','sale_reversal','actor',auth.uid(),'sale',p_sale_id,'reason',p_reason,'confirmation',p_confirmation);r record;value numeric;gain numeric;result jsonb;begin
 if p_request_id is null or p_confirmation is distinct from 'CANCEL' or nullif(trim(p_reason),'') is null or length(p_reason)>1000 then raise exception 'Reason, request ID and CANCEL confirmation are required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used';end if;return prior.result;end if;
 select * into s from public.sales where tenant_id=t and sale_id=p_sale_id for update;
 if not found or s.status<>'completed' then raise exception 'Completed sale not found';end if;
 if not exists(select 1 from public.inventory_cost_entries e join public.inventory_movements m using(tenant_id,movement_id) where e.tenant_id=t and m.reference_id=p_sale_id and m.reference_type='sale' and e.filled_change<0) or exists(select 1 from public.inventory_movements m where m.tenant_id=t and m.reference_id=p_sale_id and m.reference_type='sale' and not exists(select 1 from public.inventory_cost_entries e where e.tenant_id=t and e.movement_id=m.movement_id)) then raise exception 'Pre-opening sale has no recorded carrying costs; it cannot be reversed automatically';end if;
 for r in select item_id,-sum(filled_quantity_change) filled,-sum(empty_quantity_change) empties from public.inventory_movements where tenant_id=t and reference_id=p_sale_id and reference_type='sale' group by item_id order by item_id loop
  perform 1 from public.items where tenant_id=t and item_id=r.item_id for update;
  insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,filled_quantity_change,empty_quantity_change,notes,created_by)
  values(t,r.item_id,'adjust_gain','sale_reversal',p_sale_id,r.filled,r.empties,'Sale cancellation: '||trim(p_reason),auth.uid());
 end loop;
 select coalesce(sum(amount),0) into value from public.accounting_lines where tenant_id=t and account='bottle_receivable' and entity_id=p_sale_id;
 perform app_private.post_journal(t,'bottle_reversal',p_sale_id,'cancel',(now() at time zone 'Asia/Dhaka')::date,'Cancel remaining bottle obligation',jsonb_build_array(
 app_private.accounting_line('bottle_receivable',-value,'lpg',p_sale_id),app_private.accounting_line('cogs',value,'lpg')));
 -- Exact stock reversal already offsets the carrying value through COGS.
 -- Reclassify the original excess-bottle gain as well, so cancellation does not
 -- leave fictitious other income offset by negative COGS.
 select coalesce(-sum(l.amount),0) into gain from public.accounting_lines l
 join public.accounting_journals j using(tenant_id,journal_id)
 join public.inventory_movements m on m.tenant_id=j.tenant_id and m.movement_id=j.source_id
 where l.tenant_id=t and j.source='inventory' and l.account='other_income' and m.reference_type='sale' and m.reference_id=p_sale_id;
 perform app_private.post_journal(t,'bottle_reversal',p_sale_id,'stock_gain',(now() at time zone 'Asia/Dhaka')::date,'Reverse cancelled excess-bottle gain',jsonb_build_array(
 app_private.accounting_line('other_income',gain,'lpg'),app_private.accounting_line('cogs',-gain,'lpg')));
 insert into public.customer_transactions(tenant_id,customer_id,type,amount,reference_id,created_by) values(t,s.customer_id,'invoice_charge',s.total_amount+s.additional_charges,p_sale_id,auth.uid());
 insert into public.sale_reversals(tenant_id,sale_id,reason,created_by) values(t,p_sale_id,trim(p_reason),auth.uid());
 update public.sales set status='voided',updated_at=clock_timestamp() where tenant_id=t and sale_id=p_sale_id;
 result:=jsonb_build_object('sale_id',p_sale_id,'refund_due',s.paid_amount);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());return result;end $$;
alter function public.reverse_sale(uuid,text,text,uuid) owner to postgres;
revoke all on function public.reverse_sale(uuid,text,text,uuid) from public,anon;
grant execute on function public.reverse_sale(uuid,text,text,uuid) to authenticated;
