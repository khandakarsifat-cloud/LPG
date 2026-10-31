-- Reuse recognition journals in Logistics and activity projections. Purchase
-- transport allocations remain visible references, never external revenue.
create function app_private.logistics_result(t uuid,transit_ids uuid[],service_ids uuid[] default '{}') returns jsonb language sql stable set search_path='' as $$
 with sources as materialized(
  select 'transit_revenue' source,unnest(transit_ids) id,false service
  union all select 'operating_cost',e.event_id,e.service_trip_id is not null from public.operating_cost_events e where e.tenant_id=t and (e.transit_id=any(transit_ids) or e.service_trip_id=any(service_ids))
 ), facts as(select a.kind,l.amount,s.service from sources s join public.accounting_journals j on j.tenant_id=t and j.source=s.source and j.source_id=s.id
  join public.accounting_lines l on l.tenant_id=t and l.journal_id=j.journal_id join public.accounting_accounts a on a.code=l.account where not j.is_opening)
 select jsonb_build_object('revenue',coalesce(-sum(amount) filter(where kind='income'),0),'transit_expenses',coalesce(sum(amount) filter(where kind='expense' and not service),0),
 'service_expenses',coalesce(sum(amount) filter(where kind='expense' and service),0),'profit',coalesce(-sum(amount) filter(where kind in ('income','expense')),0)) from facts;
$$;
alter function app_private.logistics_result(uuid,uuid[],uuid[]) owner to postgres;
revoke all on function app_private.logistics_result(uuid,uuid[],uuid[]) from public,anon,authenticated;


CREATE OR REPLACE FUNCTION public.get_logistics_summary(p_vehicle_id uuid DEFAULT NULL::uuid, p_employee_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['logistics:view','logistics:manage','employees:view','employees:manage','payroll:view','payroll:pay']); result jsonb;
begin
 if not app_private.has_any_permission(array['logistics:view','logistics:manage']) and p_employee_id is null then raise exception 'Choose an employee'; end if;
 with trips as (select tr.*,case when p_employee_id is null then tr.driver_cost+tr.helper_cost
  when p_employee_id=tr.driver_employee_id then tr.driver_cost else tr.helper_cost end earnings,
  app_private.transit_employee_paid(t,tr.transit_id,case when p_employee_id is null then null when p_employee_id=tr.driver_employee_id then 'driver' else 'helper' end) paid
  from public.transits tr where tr.tenant_id=t and (p_vehicle_id is null or tr.vehicle_id=p_vehicle_id) and (p_employee_id is null or p_employee_id in (tr.driver_employee_id,tr.helper_employee_id)))
, financials as materialized(select app_private.logistics_result(t,array(select transit_id from trips),case when p_employee_id is null then array(select service_trip_id from public.vehicle_service_trips where tenant_id=t and (p_vehicle_id is null or vehicle_id=p_vehicle_id)) else '{}'::uuid[] end) r)
 select jsonb_build_object('transits',count(*),'active',count(*) filter(where status='active'),'awaiting_completion',count(*) filter(where closed_at is null),
  'earnings',coalesce(sum(earnings),0),'paid',coalesce(sum(paid),0),'outstanding',coalesce(sum(greatest(0,earnings-paid)) filter(where closed_at is null),0),
  'transport_fees',(select (r->>'revenue')::numeric from financials),'operating_costs',(select (r->>'transit_expenses')::numeric from financials),
  'profit',(select (r->>'profit')::numeric from financials),
  'expense_outstanding',coalesce(sum(greatest(0,total_cost-driver_cost-helper_cost-app_private.transit_operating_paid(t,transit_id))),0),
  'service_expenses',(select (r->>'service_expenses')::numeric from financials),

  'vehicles',(select count(*) from public.vehicles where tenant_id=t),'home',(select count(*) from public.vehicles where tenant_id=t and status='idle')) into result from trips;
 return result||jsonb_build_object('assignments',(select count(*) from public.vehicle_assignments where tenant_id=t and employee_id=p_employee_id),'current_vehicle',(select v.name from public.vehicle_assignments a join public.vehicles v using(tenant_id,vehicle_id) where a.tenant_id=t and a.employee_id=p_employee_id and a.ended_at is null));
end $function$;

create or replace function app_private.transit_json(t uuid,id uuid) returns jsonb language sql stable set search_path='' as $$
 select to_jsonb(tr)||jsonb_build_object('vehicle_name',v.name,'driver_paid',app_private.transit_employee_paid(t,id,'driver'),
 'helper_paid',app_private.transit_employee_paid(t,id,'helper'),'operating_paid',app_private.transit_operating_paid(t,id),
 'client_paid',app_private.transit_client_paid(t,id),'revenue',(financial.r->>'revenue')::numeric,
 'profit',(financial.r->>'profit')::numeric,
 'outstanding',greatest(0,tr.driver_cost-app_private.transit_employee_paid(t,id,'driver'))+greatest(0,tr.helper_cost-app_private.transit_employee_paid(t,id,'helper'))+
 greatest(0,tr.total_cost-tr.driver_cost-tr.helper_cost-app_private.transit_operating_paid(t,id)),
 'purchase_refund_due',p.refund_due,'purchase_financial_closed_at',p.financial_closed_at)
 from public.transits tr join public.vehicles v using(tenant_id,vehicle_id) left join public.purchases p on p.tenant_id=t and p.purchase_id=tr.purchase_id cross join lateral(select app_private.logistics_result(t,array[tr.transit_id]) r) financial where tr.tenant_id=t and tr.transit_id=id;
$$;

create or replace function public.get_financial_activity(p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 12) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage']);r jsonb;begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 or length(coalesce(p_filters->>'search',''))>500 or nullif(p_filters->>'from','')::date>nullif(p_filters->>'to','')::date then raise exception 'Invalid activity filters';end if;
 with parents as(
 select p.purchase_id id,'purchase' source,p.created_at,coalesce(p.supplier_name,b.brand_name,'Purchase')||' · '||coalesce(g.plant_name,'') title,
 p.status::text status,p.payable_amount cost,0::numeric revenue,p.paid_amount paid,p.transport_cost internal_allocation,
 jsonb_build_object('Company payable',p.company_payable,'Labour',p.labour_cost,'Transport allocation',p.transport_cost) breakdown
 from public.purchases p left join public.lpg_brands b on b.tenant_id=t and b.brand_id=p.brand_id left join public.gas_plants g on g.tenant_id=t and g.plant_id=p.plant_id where p.tenant_id=t and p.status<>'created'
 union all select s.service_trip_id,'service_trip',s.created_at,s.title,case when s.finalized_at is null then 'open' else 'finalized' end,s.total_cost,0,app_private.service_paid(t,s.service_trip_id),0,jsonb_build_object('Expenses',s.expenses)
 from public.vehicle_service_trips s where s.tenant_id=t
 union all select tr.transit_id,'transit',tr.created_at,coalesce(tr.client_name,'Transit')||' · '||coalesce(tr.destination,''),tr.status::text,tr.total_cost,(app_private.logistics_result(t,array[tr.transit_id])->>'revenue')::numeric,
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
