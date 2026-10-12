-- PostgREST UPSERT assigns every payload column in its ON CONFLICT UPDATE,
-- including the unchanged tenant key. Both USING and WITH CHECK still require
-- the same trusted tenant and printers:manage permission.
grant update (tenant_id) on public.receipt_printers to authenticated;
notify pgrst, 'reload schema';
