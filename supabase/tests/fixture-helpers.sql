-- Disposable/rolled-back test arrangement only. Never install in application schemas.
-- Legacy migration fixtures deliberately keep their original shapes.
create or replace function pg_temp.fixture_brand(t uuid, label text) returns uuid
language plpgsql security definer set search_path='' as $$
declare id uuid; subject text:=current_setting('request.jwt.claim.sub',true);
begin
 select brand_id into id from public.lpg_brands where tenant_id=t and brand_name=label;
 if id is null then
  perform set_config('request.jwt.claim.sub','',true);
  insert into public.lpg_brands(tenant_id,brand_name) values(t,label) returning brand_id into id;
  perform set_config('request.jwt.claim.sub',coalesce(subject,''),true);
 end if;
 return id;
end $$;
grant execute on function pg_temp.fixture_brand(uuid,text) to authenticated,anon;
