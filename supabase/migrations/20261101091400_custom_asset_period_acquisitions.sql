-- Custom equipment uses its retained type, rather than a system acquisition
-- code. Include those original asset debits in gross period acquisitions.
create or replace function app_private.period_financial_values(p_filters jsonb) returns jsonb language plpgsql stable set search_path='' as $$declare
 ids uuid[]:=app_private.analysis_scope(p_filters);cat text:=coalesce(p_filters->>'category','all');r jsonb;begin
 with lines as(select j.source,l.account,case when cat='all' then l.consolidated_amount else l.amount end amount,t.code,t.origin
 from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) join public.financial_types t using(type_id)
 where j.tenant_id=any(ids) and j.occurred_on between (p_filters->>'from')::date and (p_filters->>'to')::date and not j.is_opening and (cat='all' or l.business_category=cat))
 select jsonb_build_object(
 'stock_acquisitions',coalesce(sum(case when account='inventory_transit' and code in ('purchase','internal_transport') then amount when account='supplier_receivable' and code='monthly_commission' then -amount when account in ('inventory_lpg','inventory_stove') and code in ('inventory_capital','inventory_gain') then amount else 0 end),0),
 'stock_change',coalesce(sum(amount) filter(where account in ('inventory_lpg','inventory_stove','inventory_transit','bottle_receivable')),0),
 'equipment_acquisitions',coalesce(sum(amount) filter(where account in ('equipment','vehicles','other_assets') and (code in ('asset_register','asset_improve') or origin='custom') and amount>0),0),
 'receivable_change',coalesce(sum(amount) filter(where account in ('customer_receivable','transport_receivable','supplier_receivable')),0),
 'payable_change',coalesce(-sum(amount) filter(where account in ('supplier_payable','employee_payable','operating_payable','other_liability','commission_pending')),0),
 'loan_movement',coalesce(-sum(amount) filter(where account='loan_payable'),0),
 'wallet_movement',coalesce(sum(amount) filter(where account='cash'),0)) into r from lines;return r;end $$;
