-- Cross-business analysis has a separate, trusted, read-only scope. Browser
-- callers cannot grant themselves access or supply an unchecked tenant ID.
create table public.business_analysis_access(
 tenant_id uuid not null references public.tenants(tenant_id),user_id uuid not null references auth.users(id),
 granted_by uuid not null references auth.users(id),granted_at timestamptz not null default clock_timestamp(),
 primary key(user_id,tenant_id)
);
create index business_analysis_tenant on public.business_analysis_access(tenant_id,user_id);
alter table public.business_analysis_access enable row level security;revoke all on public.business_analysis_access from public,anon,authenticated;
create function app_private.analysis_businesses() returns table(tenant_id uuid,business_name text) language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage']);begin
 return query select b.tenant_id,b.business_name::text from public.tenants b where b.status='active' and (b.tenant_id=t or exists(
 select 1 from public.business_analysis_access a where a.user_id=auth.uid() and a.tenant_id=b.tenant_id)) order by b.business_name,b.tenant_id;
end $$;
create function public.get_analysis_businesses() returns table(tenant_id uuid,business_name text) language sql stable security definer set search_path='' as $$select * from app_private.analysis_businesses();$$;
-- Permission to grant analytical access belongs to the target business OWNER.
-- The recipient must already be a trusted, active, nonanonymous application user.
create function public.grant_business_analysis_access(p_user_id uuid,p_grant boolean) returns void language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('finance:manage');begin
 if not exists(select 1 from public.user_roles ur join public.roles r using(tenant_id,role_id) where ur.tenant_id=t and ur.user_id=auth.uid() and r.name='OWNER') then raise exception 'Only the business owner can grant analysis access' using errcode='42501';end if;
 if not exists(select 1 from public.user_profiles p join auth.users u on u.id=p.user_id join public.tenants b using(tenant_id) where p.user_id=p_user_id and p.is_active and not coalesce(u.is_anonymous,false) and b.status='active') then raise exception 'Choose an active trusted application user';end if;
 if p_grant then insert into public.business_analysis_access(tenant_id,user_id,granted_by) values(t,p_user_id,auth.uid()) on conflict do nothing;
 else delete from public.business_analysis_access where tenant_id=t and user_id=p_user_id;end if;
 insert into public.audit_logs(tenant_id,table_name,record_id,action,new_data,performed_by) values(t,'business_analysis_access',p_user_id,case when p_grant then 'INSERT' else 'DELETE' end,jsonb_build_object('user_id',p_user_id,'grant',p_grant),auth.uid());
end $$;
create function app_private.analysis_scope(filters jsonb) returns uuid[] language plpgsql stable set search_path='' as $$
declare ids uuid[];requested uuid:=nullif(filters->>'business_id','')::uuid;begin
 select array_agg(b.tenant_id) into ids from app_private.analysis_businesses() b where requested is null or b.tenant_id=requested;
 if coalesce(cardinality(ids),0)=0 then raise exception 'Business is not authorized for financial analysis' using errcode='42501';end if;return ids;
end $$;
-- Payment business dates are persisted once, separate from ledger recording time.
alter table public.wallet_transactions add column accounting_date date;
alter table public.wallet_transactions disable trigger immutable_wallet_entry;
update public.wallet_transactions x set accounting_date=coalesce(
 (select p.payment_date from public.operating_payments p where p.tenant_id=x.tenant_id and p.payment_id=x.operating_payment_id),
 (select p.payment_date from public.employee_payment_entries e join public.employee_payments p using(tenant_id,payment_id) where e.tenant_id=x.tenant_id and e.entry_id=x.employee_entry_id),
 (select s.spending_date from public.spendings s where s.tenant_id=x.tenant_id and s.spending_id=x.reference_id and x.type in ('business_spending','owner_withdrawal')),
 (x.created_at at time zone 'Asia/Dhaka')::date);
alter table public.wallet_transactions enable trigger immutable_wallet_entry;
alter table public.wallet_transactions alter column accounting_date set not null;
create index wallet_accounting_period on public.wallet_transactions(tenant_id,accounting_date,type);
create function app_private.wallet_accounting_date() returns trigger language plpgsql set search_path='' as $$
begin
 new.accounting_date:=coalesce(
 (select p.payment_date from public.operating_payments p where p.tenant_id=new.tenant_id and p.payment_id=new.operating_payment_id),
 (select p.payment_date from public.employee_payment_entries e join public.employee_payments p using(tenant_id,payment_id) where e.tenant_id=new.tenant_id and e.entry_id=new.employee_entry_id),
 (select s.spending_date from public.spendings s where s.tenant_id=new.tenant_id and s.spending_id=new.reference_id and new.type in ('business_spending','owner_withdrawal')),
 (new.created_at at time zone 'Asia/Dhaka')::date);return new;
end $$;
create trigger zz_wallet_accounting_date before insert on public.wallet_transactions for each row execute function app_private.wallet_accounting_date();
revoke all on function app_private.wallet_accounting_date() from public,anon,authenticated;
-- One indexed server-side fact stream supplies the dashboard, drill-down and PDF.
create function app_private.finance_facts(ids uuid[],f date,u date) returns table(tenant_id uuid,occurred_on date,metric text,category text,amount numeric,source text,source_id uuid,description text) language sql stable set search_path='' as $$
 select s.tenant_id,(s.created_at at time zone 'Asia/Dhaka')::date,'revenue','Product sales',s.total_amount,'sale',s.sale_id,'Sale #'||left(s.sale_id::text,8)
 from public.sales s where s.tenant_id=any(ids) and s.status='completed' and s.created_at>=f::timestamp at time zone 'Asia/Dhaka' and s.created_at<(u+1)::timestamp at time zone 'Asia/Dhaka'
 union all select r.tenant_id,(r.created_at at time zone 'Asia/Dhaka')::date,'revenue','Customer settlement charges',r.fee,'sale',r.sale_id,'Additional settlement charge'
 from public.sale_bottle_receipts r where r.tenant_id=any(ids) and r.fee>0 and r.created_at>=f::timestamp at time zone 'Asia/Dhaka' and r.created_at<(u+1)::timestamp at time zone 'Asia/Dhaka'
 union all select s.tenant_id,(s.created_at at time zone 'Asia/Dhaka')::date,'expense','Cost of goods sold',coalesce(c.external_unit_cost,0)*c.quantity,'sale',s.sale_id,'Cost of sold '||c.price_type||' cylinders'
 from public.sale_cost_evidence c join public.sales s using(tenant_id,sale_id) where s.tenant_id=any(ids) and s.status='completed' and s.created_at>=f::timestamp at time zone 'Asia/Dhaka' and s.created_at<(u+1)::timestamp at time zone 'Asia/Dhaka'
 union all select s.tenant_id,(s.created_at at time zone 'Asia/Dhaka')::date,'unvalued_units','Unknown sale cost',c.quantity,'sale',s.sale_id,'Sale has no transaction-time buying price'
 from public.sale_cost_evidence c join public.sales s using(tenant_id,sale_id) where s.tenant_id=any(ids) and c.external_unit_cost is null and s.status='completed' and s.created_at>=f::timestamp at time zone 'Asia/Dhaka' and s.created_at<(u+1)::timestamp at time zone 'Asia/Dhaka'
 union all select s.tenant_id,(s.created_at at time zone 'Asia/Dhaka')::date,'reconstructed_units','Reconstructed sale cost',c.quantity,'sale',s.sale_id,'Historical cost reconstructed from receipt and commission evidence'
 from public.sale_cost_evidence c join public.sales s using(tenant_id,sale_id) where s.tenant_id=any(ids) and c.reconstructed and c.external_unit_cost is not null and s.status='completed' and s.created_at>=f::timestamp at time zone 'Asia/Dhaka' and s.created_at<(u+1)::timestamp at time zone 'Asia/Dhaka'
 union all select tr.tenant_id,(tr.created_at at time zone 'Asia/Dhaka')::date,'revenue','Custom transport',tr.transport_fee,'transit',tr.transit_id,coalesce(tr.client_name,'Custom transit')
 from public.transits tr where tr.tenant_id=any(ids) and tr.purchase_id is null and tr.status<>'cancelled' and tr.created_at>=f::timestamp at time zone 'Asia/Dhaka' and tr.created_at<(u+1)::timestamp at time zone 'Asia/Dhaka'
 union all select e.tenant_id,e.incurred_on,'expense',case when e.service_trip_id is not null then 'Vehicle service: ' else 'Transit: ' end||e.category,e.amount,
 case when e.service_trip_id is not null then 'service_trip' else 'transit' end,coalesce(e.service_trip_id,e.transit_id),e.category
 from public.operating_cost_events e where e.tenant_id=any(ids) and e.incurred_on between f and u
 union all select ep.tenant_id,ep.payment_date,'expense','Employee bonuses',case when ep.reversal_of is null then ep.amount else -ep.amount end,'employee',ep.employee_id,coalesce(ep.bonus_name,ep.description,'Employee bonus')
 from public.employee_payments ep where ep.tenant_id=any(ids) and ep.kind='bonus' and ep.payment_date between f and u
 union all select e.tenant_id,m.month::date,'expense','Employee salaries',(app_private.employee_month_balance(e.tenant_id,e.employee_id,m.month::date)->>'salary_amount')::numeric,'employee',e.employee_id,e.name||' salary for '||to_char(m.month,'Mon YYYY')
 from public.employees e cross join generate_series(date_trunc('month',f::timestamp),date_trunc('month',least(u,(now() at time zone 'Asia/Dhaka')::date)::timestamp),'1 month') m(month)
 where e.tenant_id=any(ids) and m.month::date between f and u
 union all select s.tenant_id,s.spending_date,'expense','Spending: '||s.category_name,s.amount,'spending',s.spending_id,s.description from public.spendings s where s.tenant_id=any(ids) and s.classification='cost' and s.spending_date between f and u
 union all select p.tenant_id,(p.received_at at time zone 'Asia/Dhaka')::date,'purchases','Received purchases',p.payable_amount,'purchase',p.purchase_id,'Purchase #'||left(p.purchase_id::text,8)
 from public.purchases p where p.tenant_id=any(ids) and p.status='received' and p.received_at>=f::timestamp at time zone 'Asia/Dhaka' and p.received_at<(u+1)::timestamp at time zone 'Asia/Dhaka'
 union all select s.tenant_id,(s.created_at at time zone 'Asia/Dhaka')::date,'sales_count','Completed sales',1,'sale',s.sale_id,'Completed sale'
 from public.sales s where s.tenant_id=any(ids) and s.status='completed' and s.created_at>=f::timestamp at time zone 'Asia/Dhaka' and s.created_at<(u+1)::timestamp at time zone 'Asia/Dhaka'
 union all select x.tenant_id,x.accounting_date,
 case when x.amount>0 then 'cash_in' else 'cash_out' end,case when x.type='owner_withdrawal' then 'Owner withdrawals' else 'Actual wallet payments' end,abs(x.amount),
 'wallet',x.transaction_id,x.description from public.wallet_transactions x
 where x.tenant_id=any(ids) and x.type not in ('wallet_transfer','balance_adjustment','accounting_normalization','purchase_transport_funding','purchase_transport_refund')
 and x.accounting_date between f and u;

$$;
create index sales_analysis_period on public.sales(tenant_id,created_at) where status='completed';
create index received_purchase_analysis on public.purchases(tenant_id,received_at) where status='received';
create index employee_bonus_analysis on public.employee_payments(tenant_id,payment_date) where kind='bonus';
create function public.get_finance_analysis(p_filters jsonb) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare ids uuid[]:=app_private.analysis_scope(p_filters);f date:=(p_filters->>'from')::date;u date:=(p_filters->>'to')::date;
 grain text:=coalesce(p_filters->>'grain','month');r jsonb;inventory jsonb;current_inventory jsonb;vehicle_rows jsonb;begin
 if f is null or u is null or not isfinite(f) or not isfinite(u) or f>u or u-f>3660 or f<'2000-01-01' or u>'2100-12-31' or grain not in ('day','month','year') or grain='day' and u-f>366 then raise exception 'Choose a valid reporting period (up to ten years; daily charts up to one year)';end if;
 with facts as materialized(select * from app_private.finance_facts(ids,f,u)),
 series as(select d::date period from generate_series(date_trunc(grain,f::timestamp),date_trunc(grain,u::timestamp),('1 '||grain)::interval)d),
 totals as(select coalesce(sum(amount) filter(where metric='revenue'),0) revenue,coalesce(sum(amount) filter(where metric='expense'),0) expenses,
 coalesce(sum(amount) filter(where metric='cash_in'),0) cash_in,coalesce(sum(amount) filter(where metric='cash_out'),0) cash_out,
 coalesce(sum(amount) filter(where metric='purchases'),0) purchases,coalesce(sum(amount) filter(where metric='sales_count'),0) sales_count,
 coalesce(sum(amount) filter(where metric='unvalued_units'),0) unvalued_units,coalesce(sum(amount) filter(where metric='reconstructed_units'),0) reconstructed_units from facts),
 trend as(select s.period,coalesce(sum(amount) filter(where metric='revenue'),0) revenue,coalesce(sum(amount) filter(where metric='expense'),0) expenses,
 coalesce(sum(amount) filter(where metric='cash_in'),0) cash_in,coalesce(sum(amount) filter(where metric='cash_out'),0) cash_out,coalesce(sum(amount) filter(where metric='purchases'),0) purchases,
 coalesce(sum(amount) filter(where metric='unvalued_units'),0) unvalued_units from series s left join facts on date_trunc(grain,occurred_on::timestamp)::date=s.period group by s.period),
 categories as(select category,sum(amount) amount from facts where metric='expense' group by category),
 businesses as(select b.tenant_id,b.business_name,coalesce(sum(amount) filter(where metric='revenue'),0) revenue,coalesce(sum(amount) filter(where metric='expense'),0) expenses,
 coalesce(sum(amount) filter(where metric='cash_in'),0)-coalesce(sum(amount) filter(where metric='cash_out'),0) cash_flow,coalesce(sum(amount) filter(where metric='unvalued_units'),0) unvalued_units
 from public.tenants b left join facts x using(tenant_id) where b.tenant_id=any(ids) group by b.tenant_id,b.business_name)
 select jsonb_build_object('generated_at',clock_timestamp(),'from',f,'to',u,'grain',grain,
 'totals',(select to_jsonb(t)||jsonb_build_object('profit',case when unvalued_units=0 then revenue-expenses end,'known_profit',revenue-expenses,'cash_flow',cash_in-cash_out,'margin',case when unvalued_units=0 and revenue>0 then round((revenue-expenses)/revenue*100,2) end) from totals t),
 'trend',coalesce((select jsonb_agg(to_jsonb(t)||jsonb_build_object('profit',case when unvalued_units=0 then revenue-expenses end,'cash_flow',cash_in-cash_out) order by period) from trend t),'[]'),
 'categories',coalesce((select jsonb_agg(to_jsonb(c) order by amount desc,category) from categories c),'[]'),
 'businesses',(select jsonb_agg(to_jsonb(b)||jsonb_build_object('profit',case when unvalued_units=0 then revenue-expenses end)) from businesses b),
 'cash_categories',coalesce((select jsonb_agg(to_jsonb(c)) from(select category,sum(amount) amount from facts where metric='cash_out' group by category)c),'[]')) into r;
 -- Quantities and prices both use the period end; future periods use now.
 select jsonb_build_object('known_value',sum((v->>'known_value')::numeric),'filled_value',sum((v->>'filled_value')::numeric),'empty_value',sum((v->>'empty_value')::numeric),
 'unvalued_units',sum((v->>'unvalued_units')::numeric),'inverted_products',sum((v->>'inverted_products')::numeric),'reconstructed_products',sum((v->>'reconstructed_products')::numeric)) into inventory
 from unnest(ids) t cross join lateral(select app_private.inventory_value_at(t,least(clock_timestamp(),(u+1)::timestamp at time zone 'Asia/Dhaka'-interval '1 microsecond')) v) q;
 select jsonb_build_object('known_value',sum((v->>'known_value')::numeric),'unvalued_units',sum((v->>'unvalued_units')::numeric)) into current_inventory
 from unnest(ids) t cross join lateral(select app_private.inventory_value_at(t,clock_timestamp()) v) q;
 select coalesce(jsonb_agg(to_jsonb(v) order by expenses desc,vehicle_name),'[]') into vehicle_rows from(
 select ve.tenant_id,ve.vehicle_id,ve.name vehicle_name,coalesce(sum(e.amount),0) expenses,
 coalesce(sum(e.amount) filter(where e.service_trip_id is not null),0) service_expenses,
 (select coalesce(sum(tr.transport_fee) filter(where tr.status<>'cancelled'),0) from public.transits tr where tr.tenant_id=ve.tenant_id and tr.vehicle_id=ve.vehicle_id and tr.created_at>=f::timestamp at time zone 'Asia/Dhaka' and tr.created_at<(u+1)::timestamp at time zone 'Asia/Dhaka') revenue
 from public.vehicles ve
 left join public.operating_cost_events e on e.tenant_id=ve.tenant_id and e.incurred_on between f and u and (
 exists(select 1 from public.transits tr where tr.tenant_id=ve.tenant_id and tr.transit_id=e.transit_id and tr.vehicle_id=ve.vehicle_id)
 or exists(select 1 from public.vehicle_service_trips st where st.tenant_id=ve.tenant_id and st.service_trip_id=e.service_trip_id and st.vehicle_id=ve.vehicle_id))
 where ve.tenant_id=any(ids) group by ve.tenant_id,ve.vehicle_id,ve.name)v;
 return r||jsonb_build_object('inventory',inventory,'current_inventory',current_inventory,'vehicles',vehicle_rows,
 'inventory_trend',(select jsonb_agg(jsonb_build_object('period',period,'known_value',value,'unvalued_units',missing) order by period) from(
 select d::date period,sum((v->>'known_value')::numeric) value,sum((v->>'unvalued_units')::numeric) missing from generate_series(date_trunc(grain,f::timestamp),date_trunc(grain,u::timestamp),('1 '||grain)::interval)d
 cross join unnest(ids)t cross join lateral(select app_private.inventory_value_at(t,least(clock_timestamp(),least((u+1)::timestamp,(d+('1 '||grain)::interval)) at time zone 'Asia/Dhaka'-interval '1 microsecond')) v)q where d::date<=(now() at time zone 'Asia/Dhaka')::date group by d)trend),
 'logistics',(select jsonb_build_object('revenue',coalesce(sum(tr.transport_fee) filter(where tr.status<>'cancelled'),0),'internal_revenue',coalesce(sum(tr.transport_fee) filter(where tr.purchase_id is not null and tr.status<>'cancelled'),0),
 'expenses',coalesce(sum(tr.total_cost),0),'outstanding',coalesce(sum((app_private.transit_json(tr.tenant_id,tr.transit_id)->>'outstanding')::numeric),0)) from public.transits tr where tr.tenant_id=any(ids) and tr.created_at>=f::timestamp at time zone 'Asia/Dhaka' and tr.created_at<(u+1)::timestamp at time zone 'Asia/Dhaka'));
end $$;
create function public.get_analysis_details(p_filters jsonb,p_metric text,p_category text default null,p_offset integer default 0,p_limit integer default 12) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare ids uuid[]:=app_private.analysis_scope(p_filters);f date:=(p_filters->>'from')::date;u date:=(p_filters->>'to')::date;r jsonb;begin
 if f is null or u is null or not isfinite(f) or not isfinite(u) or f>u or u-f>3660 or p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 or p_metric not in ('revenue','expense','cash_in','cash_out','purchases','unvalued_units') then raise exception 'Invalid analysis detail filters';end if;
 with matching as materialized(select x.*,b.business_name from app_private.finance_facts(ids,f,u) x join public.tenants b using(tenant_id) where metric=p_metric and (p_category is null or category=p_category)),
 page as(select * from matching order by occurred_on desc,source_id,category offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(to_jsonb(p) order by occurred_on desc,source_id,category) from page p),'[]')) into r;return r;
end $$;
do $$ declare r record;begin
 for r in select p.oid,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','app_private') and p.proname in ('analysis_businesses','get_analysis_businesses','grant_business_analysis_access','analysis_scope','finance_facts','get_finance_analysis','get_analysis_details') loop
 execute format('alter function %s owner to postgres',r.oid::regprocedure);execute format('revoke all on function %s from public,anon,authenticated',r.oid::regprocedure);if r.nspname='public' then execute format('grant execute on function %s to authenticated',r.oid::regprocedure);end if;end loop;
end $$;
notify pgrst,'reload schema';

-- Unified parent activities. Individual wallet audit rows remain in Wallet ledger.
create function public.get_financial_activity(p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 12) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage']);r jsonb;begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 or length(coalesce(p_filters->>'search',''))>500 or nullif(p_filters->>'from','')::date>nullif(p_filters->>'to','')::date then raise exception 'Invalid activity filters';end if;
 with parents as(
 select p.purchase_id id,'purchase' source,p.created_at,coalesce(b.brand_name,'Purchase')||' · '||coalesce(g.plant_name,'') title,
 p.status::text status,p.payable_amount cost,0::numeric revenue,p.paid_amount paid,p.transport_cost internal_allocation,
 jsonb_build_object('Company payable',p.company_payable,'Labour',p.labour_cost,'Transport allocation',p.transport_cost) breakdown
 from public.purchases p left join public.lpg_brands b on b.tenant_id=t and b.brand_id=p.brand_id left join public.gas_plants g on g.tenant_id=t and g.plant_id=p.plant_id where p.tenant_id=t and p.status<>'created'
 union all select s.service_trip_id,'service_trip',s.created_at,s.title,case when s.finalized_at is null then 'open' else 'finalized' end,s.total_cost,0,app_private.service_paid(t,s.service_trip_id),0,jsonb_build_object('Expenses',s.expenses)
 from public.vehicle_service_trips s where s.tenant_id=t
 union all select tr.transit_id,'transit',tr.created_at,coalesce(tr.client_name,'Transit')||' · '||coalesce(tr.destination,''),tr.status::text,tr.total_cost,case when tr.status='cancelled' then 0 else tr.transport_fee end,
 app_private.transit_employee_paid(t,tr.transit_id,null)+app_private.transit_operating_paid(t,tr.transit_id),case when tr.purchase_id is null then 0 else tr.transport_fee end,
 jsonb_build_object('Driver earnings',tr.driver_cost,'Helper earnings',tr.helper_cost,'Oil',tr.oil_cost,'Other costs',tr.others_cost,'Additional costs',tr.additional_costs)
 from public.transits tr where tr.tenant_id=t
 ),matching as materialized(select * from parents p where app_private.finance_search(concat_ws(' ',p.title,p.id,p.source,p.status),coalesce(p_filters->>'search',''))
 and (nullif(p_filters->>'source','') is null or source=p_filters->>'source')
 and (nullif(p_filters->>'from','') is null or created_at>=(p_filters->>'from')::date::timestamp at time zone 'Asia/Dhaka')
 and (nullif(p_filters->>'to','') is null or created_at<((p_filters->>'to')::date+1)::timestamp at time zone 'Asia/Dhaka')),
 page as(select * from matching order by created_at desc,id desc offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(to_jsonb(p) order by created_at desc,id desc) from page p),'[]')) into r;return r;
end $$;
revoke all on function public.get_financial_activity(jsonb,integer,integer) from public,anon,authenticated;
grant execute on function public.get_financial_activity(jsonb,integer,integer) to authenticated;
create function public.get_financial_activity_wallets(p_source text,p_id uuid,p_offset integer default 0,p_limit integer default 10) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage']);r jsonb;begin
 if p_source not in ('purchase','transit','service_trip') or p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid wallet audit page';end if;
 with entries as materialized(select x.transaction_id,x.wallet_name_snapshot wallet_name,x.amount,x.description,x.created_at,x.entry_no
 from public.wallet_transactions x where x.tenant_id=t and (x.reference_id=p_id or p_source='transit' and exists(select 1 from public.employee_payments ep where ep.tenant_id=t and ep.transit_id=p_id and ep.payment_id=x.reference_id))),
 page as(select * from entries order by entry_no desc offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from entries),'entries',coalesce((select jsonb_agg(to_jsonb(p) order by entry_no desc) from page p),'[]')) into r;return r;
end $$;
revoke all on function public.get_financial_activity_wallets(text,uuid,integer,integer) from public,anon,authenticated;
grant execute on function public.get_financial_activity_wallets(text,uuid,integer,integer) to authenticated;
alter function public.get_financial_activity(jsonb,integer,integer) owner to postgres;
alter function public.get_financial_activity_wallets(text,uuid,integer,integer) owner to postgres;
alter function app_private.wallet_accounting_date() owner to postgres;
alter table public.business_analysis_access owner to postgres;
alter table public.financial_source_archive owner to postgres;
alter table public.product_buying_price_history owner to postgres;
alter table public.sale_cost_evidence owner to postgres;
alter table public.inventory_valuation_baselines owner to postgres;
