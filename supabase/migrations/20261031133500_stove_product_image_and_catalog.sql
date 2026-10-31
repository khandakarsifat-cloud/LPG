-- Add image_url to items table for product photos
alter table public.items add column if not exists image_url text;

-- Create product-images storage bucket
insert into storage.buckets (id, name, public)
values ('product-images', 'product-images', true)
on conflict (id) do update set public = true;

-- RLS policies for product-images bucket
do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'Public Access to Product Images') then
    create policy "Public Access to Product Images" on storage.objects for select using (bucket_id = 'product-images');
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'Authenticated Users Can Upload Product Images') then
    create policy "Authenticated Users Can Upload Product Images" on storage.objects for insert to authenticated with check (bucket_id = 'product-images');
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'Authenticated Users Can Update Product Images') then
    create policy "Authenticated Users Can Update Product Images" on storage.objects for update to authenticated using (bucket_id = 'product-images');
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'Authenticated Users Can Delete Product Images') then
    create policy "Authenticated Users Can Delete Product Images" on storage.objects for delete to authenticated using (bucket_id = 'product-images');
  end if;
end $$;

-- Update save_stove_product to store image_url
create or replace function public.save_stove_product(p_payload jsonb, p_request_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  t uuid := app_private.require_permission('inventory:manage');
  id uuid := (p_payload->>'item_id')::uuid;
  prior public.finance_requests;
  body jsonb := jsonb_build_object('action', 'stove_product', 'actor', auth.uid(), 'body', p_payload);
  result jsonb;
  img_url text := nullif(trim(p_payload->>'image_url'), '');
begin
  if p_request_id is null then raise exception 'Request ID is required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(t::text || ':finance:' || p_request_id::text, 0));
  select * into prior from public.finance_requests where tenant_id = t and request_id = p_request_id;
  if found then
    if prior.payload is distinct from body then raise exception 'Request ID already used'; end if;
    return prior.result;
  end if;
  if nullif(trim(p_payload->>'name'), '') is null or length(p_payload->>'name') > 150
     or not exists(select 1 from public.stove_product_types where tenant_id = t and type_id = (p_payload->>'type_id')::uuid and is_active) then
    raise exception 'Enter a name and active product type';
  end if;
  if id is null then
    insert into public.items(tenant_id, business_category, product_name, product_type_id, image_url)
    values(t, 'stove', trim(p_payload->>'name'), (p_payload->>'type_id')::uuid, img_url)
    returning item_id into id;
  else
    update public.items
    set product_name = trim(p_payload->>'name'),
        product_type_id = (p_payload->>'type_id')::uuid,
        image_url = img_url
    where tenant_id = t and item_id = id and business_category = 'stove';
    if not found then raise exception 'Stove product not found'; end if;
  end if;
  result := jsonb_build_object('item_id', id);
  insert into public.finance_requests(tenant_id, request_id, payload, result, created_by)
  values(t, p_request_id, body, result, auth.uid());
  return result;
end $$;

revoke all on function public.save_stove_product(jsonb, uuid) from public, anon;
grant execute on function public.save_stove_product(jsonb, uuid) to authenticated;
