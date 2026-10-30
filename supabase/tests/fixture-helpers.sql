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

-- Current departure fixtures must identify real role-matching crew.
create or replace function pg_temp.fixture_vehicle_crew(t uuid,vid uuid) returns void
language plpgsql security definer set search_path='' as $$
declare subject text:=current_setting('request.jwt.claim.sub',true); actor uuid; d uuid; h uuid; v public.vehicles; role_name text; eid uuid;
begin
 select ur.user_id into actor from public.user_roles ur join public.roles r using(tenant_id,role_id) where ur.tenant_id=t and r.name='OWNER' limit 1;
 perform set_config('request.jwt.claim.sub',actor::text,true);
 select * into v from public.vehicles where tenant_id=t and vehicle_id=vid;
 foreach role_name in array array['Driver','Helper'] loop
  eid:=(public.save_employee(jsonb_build_object('name','Fixture '||role_name||' '||vid,'employee_type_name',role_name,'business_unit','truck_business',
   'phones',jsonb_build_array(jsonb_build_object('phone','017'||lpad(floor(random()*100000000)::text,8,'0'),'is_primary',true)),
   'terms',jsonb_build_object('monthly_salary',1000,'effective_from','2025-01-01','is_active',true)),gen_random_uuid())->>'employee_id')::uuid;
  if role_name='Driver' then d:=eid; else h:=eid; end if;
 end loop;
 perform public.save_vehicle(jsonb_build_object('vehicle_id',vid,'revision',v.revision,'name',v.name,'serial_no',v.serial_no,'capacity',v.capacity,'driver_employee_id',d,'helper_employee_id',h),gen_random_uuid());
 perform set_config('request.jwt.claim.sub',coalesce(subject,''),true);
end $$;
grant execute on function pg_temp.fixture_vehicle_crew(uuid,uuid) to authenticated;
