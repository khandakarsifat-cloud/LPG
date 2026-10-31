-- LPG registration already uses column-scoped INSERT and tenant/capability RLS.
-- Allow its optional validated photo reference without granting stock writes.
grant insert (image_url) on public.items to authenticated;
