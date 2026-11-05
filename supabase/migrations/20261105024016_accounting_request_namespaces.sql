-- Existing POS and Finance request registries have separate namespaces. Preserve
-- them in the derived, transaction-local journal identity without another store.
create or replace function app_private.begin_accounting_action(action text, request_id uuid default null)
returns void language plpgsql set search_path='' as $$
declare c jsonb:=nullif(current_setting('lpg.accounting_action',true),'')::jsonb;
begin
 if c is null then
  c:=jsonb_build_object('action',action,'id',case when request_id is null then gen_random_uuid() else md5(action||':'||request_id::text)::uuid end,'depth',1,'posts','[]'::jsonb);
 else c:=jsonb_set(c,'{depth}',to_jsonb((c->>'depth')::integer+1));end if;
 perform set_config('lpg.accounting_action',c::text,true);
end $$;
