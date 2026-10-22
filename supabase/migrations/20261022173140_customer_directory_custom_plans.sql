-- Name pages, broad monetary sorts and selective product/date scopes need different
-- plans. A reused generic plan can underestimate the full sales scope after repeated
-- filter changes. Replan this bounded reporting RPC with its actual parameters;
-- the setting is local to the function and retains the hardened search_path/grants.
alter function public.get_customer_directory(jsonb,integer,integer,uuid)
  set plan_cache_mode=force_custom_plan;
