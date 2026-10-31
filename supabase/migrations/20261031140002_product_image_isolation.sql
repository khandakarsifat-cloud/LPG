-- Retain the existing bucket and item reference; enforce trusted tenant access.
-- References contain object paths, never arbitrary URLs or inline base64 images.
update public.items set image_url=split_part(image_url,'/storage/v1/object/public/product-images/',2)
 where image_url like '%/storage/v1/object/public/product-images/%';
do $$begin
 if exists(select 1 from public.items i where image_url is not null and (image_url not like tenant_id::text||'/%' or not exists(select 1 from storage.objects o where o.bucket_id='product-images' and o.name=i.image_url))) then
  raise exception 'Review unsupported product image references before migration';
 end if;
end $$;
update storage.buckets set public=false,file_size_limit=1048576,allowed_mime_types=array['image/jpeg','image/png','image/webp'] where id='product-images';
drop policy if exists "Public Access to Product Images" on storage.objects;
drop policy if exists "Authenticated Users Can Upload Product Images" on storage.objects;
drop policy if exists "Authenticated Users Can Update Product Images" on storage.objects;
drop policy if exists "Authenticated Users Can Delete Product Images" on storage.objects;

-- Private schema helper has no tenant parameter supplied by a browser.
create function app_private.product_image_access(object_name text,writing boolean default false) returns boolean language sql stable security definer set search_path='' as $$
 select split_part(object_name,'/',1)=app_private.current_tenant_id()::text and
 case when writing then app_private.has_permission('inventory:manage') else app_private.has_any_permission(array['inventory:view','inventory:manage','pos:sell','purchases:manage','sales:view','receipts:print','dashboard:view','customers:view']) end;
$$;
alter function app_private.product_image_access(text,boolean) owner to postgres;
revoke all on function app_private.product_image_access(text,boolean) from public,anon;
grant execute on function app_private.product_image_access(text,boolean) to authenticated;
create policy product_images_read on storage.objects for select to authenticated using(bucket_id='product-images' and app_private.product_image_access(name));
create policy product_images_upload on storage.objects for insert to authenticated with check(bucket_id='product-images' and app_private.product_image_access(name,true) and lower(storage.extension(name)) in ('jpg','jpeg','png','webp'));
-- Replacement uses a new object; existing files cannot be silently overwritten.
create function app_private.product_image_unused(object_name text) returns boolean language sql stable security definer set search_path='' as $$
 select not exists(select 1 from public.items where tenant_id=app_private.current_tenant_id() and image_url=object_name);
$$;
alter function app_private.product_image_unused(text) owner to postgres;
revoke all on function app_private.product_image_unused(text) from public,anon;
grant execute on function app_private.product_image_unused(text) to authenticated;
create policy product_images_remove on storage.objects for delete to authenticated using(bucket_id='product-images' and app_private.product_image_access(name,true) and app_private.product_image_unused(name));

create function app_private.validate_product_image() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.image_url is not null and (length(new.image_url)>250 or new.image_url not like new.tenant_id::text||'/%' or not exists(select 1 from storage.objects where bucket_id='product-images' and name=new.image_url and metadata->>'mimetype' in ('image/jpeg','image/png','image/webp') and (metadata->>'size')::bigint<=1048576)) then
  raise exception 'Choose an uploaded image belonging to this business';
 end if;return new;end $$;
alter function app_private.validate_product_image() owner to postgres;
revoke all on function app_private.validate_product_image() from public,anon,authenticated;
create trigger validate_product_image before insert or update of image_url on public.items for each row execute function app_private.validate_product_image();

create function public.set_product_image(p_item_id uuid,p_image_path text) returns void language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('inventory:manage');begin
 update public.items set image_url=nullif(trim(p_image_path),'') where tenant_id=t and item_id=p_item_id;
 if not found then raise exception 'Product not found';end if;
end $$;
alter function public.set_product_image(uuid,text) owner to postgres;
revoke all on function public.set_product_image(uuid,text) from public,anon;
grant execute on function public.set_product_image(uuid,text) to authenticated;

-- Product details already return catalog identity; add the same image reference
-- to the existing purchase and sale detail projections rather than new readers.
do $$declare s text;begin
 s:=pg_get_functiondef('app_private.purchase_rows(uuid,uuid[])'::regprocedure);
 if position('''product_name'',i.product_name' in s)>0 then
  execute replace(s,'''product_name'',i.product_name','''image_url'',i.image_url,''product_name'',i.product_name');
 end if;
end $$;
