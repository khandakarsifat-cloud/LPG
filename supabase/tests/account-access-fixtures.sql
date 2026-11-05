-- Current-state SQL fixtures use trusted setup and real session rows. These helpers
-- exist only in pg_temp and must never be installed as application RPCs.
create or replace function pg_temp.fixture_identity(who text) returns text language plpgsql security definer set search_path='' as $$
begin
 if nullif(who,'') is not null then
  insert into auth.sessions(id,user_id,aal) values(who::uuid,who::uuid,'aal1') on conflict(id) do nothing;
 end if;
 perform set_config('request.jwt.claim.sub',coalesce(who,''),true);
 perform set_config('request.jwt.claims',case when nullif(who,'') is null then '{}' else jsonb_build_object('sub',who,'session_id',who,'role','authenticated')::text end,true);
 return who;
end $$;
create or replace function pg_temp.fixture_business(business text,owner_name text) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid;who uuid:=auth.uid();email text;begin
 select u.email into email from auth.users u where u.id=who;
 if email is null or exists(select 1 from public.user_profiles where user_id=who) then raise exception 'Invalid fixture identity';end if;
 insert into public.tenants(business_name,status) values(business,'active') returning tenant_id into t;
 insert into public.user_profiles(user_id,tenant_id,email,full_name) values(who,t,email,owner_name);
 insert into public.roles(tenant_id,name) values(t,'OWNER'),(t,'MANAGER'),(t,'SALESMAN');
 insert into public.role_permissions(tenant_id,role_id,permission_id) select t,r.role_id,p.permission_id from public.roles r cross join public.permissions p
 where r.tenant_id=t and (r.name='OWNER' or r.name='MANAGER' and not p.owner_only or r.name='SALESMAN' and p.permission_id in ('dashboard:view','pos:sell','sales:view','receipts:print','preferences:manage','wallets:use'));
 insert into public.user_roles(tenant_id,user_id,role_id) select t,who,role_id from public.roles where tenant_id=t and name='OWNER';
 return jsonb_build_object('tenant_id',t,'user_id',who,'role','OWNER');
end $$;
grant execute on function pg_temp.fixture_identity(text),pg_temp.fixture_business(text,text) to authenticated,anon;
