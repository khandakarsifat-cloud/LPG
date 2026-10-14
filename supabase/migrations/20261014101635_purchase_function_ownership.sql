-- The platform migration executor is supabase_admin; established application
-- SECURITY DEFINER routines run as postgres. Align ownership so existing
-- routines can invoke the private purchase helpers without browser grants.
-- Keep previous migration SQL/history intact and preserve all business rows.
alter type public.purchase_status owner to postgres;
alter table public.purchase_activity owner to postgres;

alter function app_private.purchase_activity_immutable() owner to postgres;
alter function app_private.purchase_money(numeric) owner to postgres;
alter function app_private.purchase_integer(jsonb) owner to postgres;
alter function app_private.recalculate_purchase(uuid,uuid) owner to postgres;
alter function app_private.save_purchase_lines(uuid,uuid,jsonb) owner to postgres;
alter function app_private.guard_purchase_transit() owner to postgres;
alter function app_private.guard_truck_idle() owner to postgres;
alter function app_private.guard_purchase_company() owner to postgres;

alter function public.create_purchase(jsonb) owner to postgres;
alter function public.update_purchase(uuid,jsonb,integer) owner to postgres;
alter function public.dispatch_purchase(uuid,integer) owner to postgres;
alter function public.receive_purchase(uuid,jsonb,text,integer) owner to postgres;
alter function public.pay_purchase(uuid,integer) owner to postgres;
alter function public.list_purchases() owner to postgres;
alter function public.get_purchase_activity(uuid) owner to postgres;
alter function public.list_transits() owner to postgres;
alter function public.update_transit_costs(uuid,numeric,numeric,numeric,jsonb,public.transit_status) owner to postgres;

-- Changing ownership does not open execution to anon/authenticated. Retain the
-- capability-gated public RPCs and unexposed private-helper boundary.
revoke all on function app_private.purchase_activity_immutable(),app_private.purchase_money(numeric),
  app_private.purchase_integer(jsonb),app_private.recalculate_purchase(uuid,uuid),
  app_private.save_purchase_lines(uuid,uuid,jsonb),app_private.guard_purchase_transit(),
  app_private.guard_truck_idle(),app_private.guard_purchase_company() from public,anon,authenticated;
notify pgrst,'reload schema';
