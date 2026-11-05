-- Rebate journal activity always links back to its purchase, including pooled company-credit lines.
CREATE OR REPLACE FUNCTION app_private.financial_source_link(t uuid, src text, id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$declare
 k text;ref uuid:=id;x public.wallet_transactions;m public.inventory_movements;cost_event public.operating_cost_events;result_id uuid;begin
 if src in ('sale','sale_bottle_claim_reversal','sale_exchange_reversal') then k:='sale';
 elsif src in ('purchase','purchase_rebate','internal_transport') then k:='purchase';
 elsif src in ('inventory','bottle_obligation','internal_inventory','internal_cogs') then
  select * into m from public.inventory_movements where tenant_id=t and movement_id=id;
  ref:=m.reference_id;k:=case when m.reference_type in ('sale','sale_reversal') then 'sale' when m.reference_type like '%purchase%' then 'purchase' else 'product' end;if k='product' then ref:=m.item_id;end if;
 elsif src='transit_revenue' then k:='transit';
 elsif src='operating_cost' then select * into cost_event from public.operating_cost_events where tenant_id=t and event_id=id;ref:=cost_event.transit_id;k:='transit';
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
notify pgrst,'reload schema';
