-- Current source identities label action rows; no stored financial evidence is changed.
CREATE OR REPLACE FUNCTION app_private.financial_source_link(t uuid, src text, id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$declare
 k text;ref uuid:=id;x public.wallet_transactions;m public.inventory_movements;cost_event public.operating_cost_events;result_id uuid;label text;begin
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
 if k='sale' then select coalesce(nullif(c.shop_name,''),c.name) into label from public.sales s join public.customers c using(tenant_id,customer_id) where s.tenant_id=t and s.sale_id=ref;
 elsif k='purchase' then select coalesce(nullif(p.supplier_name,''),b.brand_name,'Supplier') into label from public.purchases p left join public.lpg_brands b using(tenant_id,brand_id) where p.tenant_id=t and p.purchase_id=ref;
 elsif k='employee' then select e.name into label from public.employees e where e.tenant_id=t and e.employee_id=ref;
 elsif k='loan' then select l.lender into label from public.loans l where l.tenant_id=t and l.loan_id=ref;
 elsif k='asset' then select a.name into label from public.business_assets a where a.tenant_id=t and a.asset_id=ref;
 elsif k='financial_entry' then select e.type_name into label from public.financial_entries e where e.tenant_id=t and e.entry_id=ref;
 elsif k='product' then select coalesce(i.product_name,concat_ws(' ',b.brand_name,i.size_kg||' kg',i.mouth_size)) into label from public.items i left join public.lpg_brands b using(tenant_id,brand_id) where i.tenant_id=t and i.item_id=ref;
 elsif k='service_trip' then select s.title into label from public.vehicle_service_trips s where s.tenant_id=t and s.service_trip_id=ref;
 elsif k='transit' then select concat_ws(' ',tr.client_name,tr.destination) into label from public.transits tr where tr.tenant_id=t and tr.transit_id=ref;
 end if;
 return case when k is not null and ref is not null then jsonb_strip_nulls(jsonb_build_object('record_kind',k,'record_id',ref,'entity_name',label)) else '{}'::jsonb end;
end $function$;
