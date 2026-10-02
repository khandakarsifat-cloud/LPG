-- Supabase default table privileges include TRUNCATE, which is not protected by RLS.
-- Limit this table to the three operations used by tenant configuration upserts.
revoke all on public.receipt_printers from public, anon, authenticated;
grant select, insert, update on public.receipt_printers to authenticated;
