-- Stale business revisions are permanent validation failures, not transaction
-- serialization failures. PostgREST 14 retries custom 40001 errors indefinitely.
-- Preserve the latest function bodies, settings, ownership and execution grants;
-- change only the error code in this explicit set of revision-guard routines.
do $$
declare routine record; changed integer := 0;
begin
  for routine in
    select p.oid, pg_get_functiondef(p.oid) definition
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = any(array[
        'dispatch_purchase', 'initiate_purchase_cancellation', 'receive_purchase',
        'save_finance_wallet', 'save_product_prices', 'save_transit_costs',
        'set_lpg_brand_order', 'set_product_commission', 'set_product_commissions',
        'transition_transit', 'update_purchase'
      ])
      and position('errcode=''40001''' in p.prosrc) > 0
  loop
    execute replace(routine.definition, 'errcode=''40001''', 'errcode=''P0001''');
    changed := changed + 1;
  end loop;
  if changed <> 11 then
    raise exception 'Expected 11 stale-edit routines, found %; review migration baseline', changed;
  end if;
end $$;
