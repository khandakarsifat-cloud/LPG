-- Resolve journal-backed transit revenue only for the requested activity page.
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
 union all select tr.transit_id,'transit',tr.created_at,coalesce(tr.client_name,'Transit')||' · '||coalesce(tr.destination,''),tr.status::text,tr.total_cost,0::numeric,
 app_private.transit_employee_paid(t,tr.transit_id,null)+app_private.transit_operating_paid(t,tr.transit_id),case when tr.purchase_id is null then 0 else tr.transport_fee end,
 jsonb_build_object('Driver earnings',tr.driver_cost,'Helper earnings',tr.helper_cost,'Oil',tr.oil_cost,'Other costs',tr.others_cost,'Additional costs',tr.additional_costs)
 from public.transits tr where tr.tenant_id=t
 ),matching as materialized(select * from parents p where app_private.finance_search(concat_ws(' ',p.title,p.id,p.source,p.status),coalesce(p_filters->>'search',''))
 and (nullif(p_filters->>'source','') is null or source=p_filters->>'source')
 and (nullif(p_filters->>'from','') is null or created_at>=(p_filters->>'from')::date::timestamp at time zone 'Asia/Dhaka')
 and (nullif(p_filters->>'to','') is null or created_at<((p_filters->>'to')::date+1)::timestamp at time zone 'Asia/Dhaka')),
 page as(select * from matching order by created_at desc,id desc offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(to_jsonb(p)||case when p.source='transit' then jsonb_build_object('revenue',(app_private.logistics_result(t,array[p.id])->>'revenue')::numeric) else '{}'::jsonb end order by created_at desc,id desc) from page p),'[]')) into r;return r;
end $$;
