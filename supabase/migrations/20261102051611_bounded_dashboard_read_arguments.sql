-- NULL LIMIT means unbounded in PostgreSQL. Reject explicit NULL page arguments
-- as well as out-of-range values; keep the established trusted-tenant RPCs.
do $$declare signature regprocedure;source text;updated text;begin
 foreach signature in array array['public.get_dashboard_activity(integer,integer)'::regprocedure,'public.get_stock_alerts(boolean,text,integer,integer)'::regprocedure] loop
  source:=pg_get_functiondef(signature);
  updated:=replace(source,'if p_offset<0 or p_limit','if p_offset is null or p_limit is null or p_search is null or p_only_low is null or p_offset<0 or p_limit');
  updated:=replace(updated,'if p_offset<0 or p_offset>10000','if p_offset is null or p_limit is null or p_offset<0 or p_offset>10000');
  if updated=source then raise exception 'Dashboard page guard contract changed: %',signature;end if;
  execute updated;
 end loop;
end $$;
notify pgrst,'reload schema';
