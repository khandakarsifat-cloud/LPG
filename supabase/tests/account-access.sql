begin;
create function pg_temp.assert_access(ok boolean,note text) returns void language plpgsql as $$begin if ok is not true then raise exception 'FAIL: %',note;end if;end $$;
create function pg_temp.deny_access(statement text) returns void language plpgsql as $$begin
 begin execute statement;exception when insufficient_privilege then return;end;
 raise exception 'FAIL: unauthorized operation succeeded: %',statement;
end $$;
grant execute on function pg_temp.assert_access(boolean,text),pg_temp.deny_access(text) to authenticated,anon;
-- Fixture identities/memberships are trusted SQL setup, never public signup.
insert into auth.users(id,email,is_anonymous,email_confirmed_at) values
 ('ad010000-0000-4000-8000-000000000001','admin-access@example.invalid',false,now()),
 ('ad020000-0000-4000-8000-000000000001','owner-access-a@example.invalid',false,now()),
 ('ad030000-0000-4000-8000-000000000001','owner-access-b@example.invalid',false,now()),
 ('ad040000-0000-4000-8000-000000000001','manager-access@example.invalid',false,now()),
 ('ad050000-0000-4000-8000-000000000001','salesman-access@example.invalid',false,now());
insert into auth.sessions(id,user_id,aal) select id,id,'aal1' from auth.users where email like '%-access%@example.invalid';
create function pg_temp.access_login(who uuid) returns void language sql as $$
 select set_config('request.jwt.claims',jsonb_build_object('sub',who,'session_id',who,'role','authenticated')::text,true)::text::void
$$;
grant execute on function pg_temp.access_login(uuid) to authenticated;
-- A permanent bootstrap cannot be invoked twice or by a business owner.
delete from app_private.admin_workspace_sessions;delete from app_private.platform_bootstrap;delete from app_private.platform_superadmins;
select public.bootstrap_platform_superadmin('ad010000-0000-4000-8000-000000000001');
insert into auth.sessions(id,user_id,aal) values('ad010000-0000-4000-8000-000000000001','ad010000-0000-4000-8000-000000000001','aal1');
set local role authenticated;
select pg_temp.access_login('ad010000-0000-4000-8000-000000000001');
select pg_temp.assert_access((public.get_access_context()->>'must_change_password')::boolean,'Bootstrap forces first password change');
select pg_temp.deny_access('select public.get_platform_dashboard()');
reset role;
update app_private.account_security set must_change_password=false where user_id='ad010000-0000-4000-8000-000000000001';
set local role authenticated;
select public.prepare_account_operation('ad110000-0000-4000-8000-000000000001','{"kind":"business","business_name":"Access Test A","name":"Owner A","email":"owner-access-a@example.invalid"}');
reset role;
update app_private.account_operations set target_user_id='ad020000-0000-4000-8000-000000000001' where request_id='ad110000-0000-4000-8000-000000000001';
update auth.users set raw_app_meta_data='{"lpg_provisioning_request":"ad110000-0000-4000-8000-000000000001"}' where id='ad020000-0000-4000-8000-000000000001';
select public.complete_account_operation('ad110000-0000-4000-8000-000000000001');
set local role authenticated;
select public.prepare_account_operation('ad120000-0000-4000-8000-000000000001','{"kind":"business","business_name":"Access Test B","name":"Owner B","email":"owner-access-b@example.invalid"}');
reset role;
update app_private.account_operations set target_user_id='ad030000-0000-4000-8000-000000000001' where request_id='ad120000-0000-4000-8000-000000000001';
update auth.users set raw_app_meta_data='{"lpg_provisioning_request":"ad120000-0000-4000-8000-000000000001"}' where id='ad030000-0000-4000-8000-000000000001';
select public.complete_account_operation('ad120000-0000-4000-8000-000000000001');
update app_private.account_security set must_change_password=false where user_id in ('ad020000-0000-4000-8000-000000000001','ad030000-0000-4000-8000-000000000001');
insert into auth.sessions(id,user_id,aal) values('ad020000-0000-4000-8000-000000000001','ad020000-0000-4000-8000-000000000001','aal1'),('ad030000-0000-4000-8000-000000000001','ad030000-0000-4000-8000-000000000001','aal1');
create temp table access_fixture as select tenant_id t from public.user_profiles where user_id='ad020000-0000-4000-8000-000000000001';
grant select on access_fixture to authenticated;
insert into public.user_profiles(user_id,tenant_id,email,full_name) select id,t,email,'Access staff' from auth.users cross join access_fixture where id in ('ad040000-0000-4000-8000-000000000001','ad050000-0000-4000-8000-000000000001');
insert into public.user_roles(tenant_id,user_id,role_id) select p.tenant_id,p.user_id,r.role_id from public.user_profiles p join public.roles r on r.tenant_id=p.tenant_id and r.name=case p.user_id when 'ad040000-0000-4000-8000-000000000001'::uuid then 'MANAGER' else 'SALESMAN' end where p.user_id in ('ad040000-0000-4000-8000-000000000001','ad050000-0000-4000-8000-000000000001');
set local role authenticated;
select pg_temp.access_login('ad020000-0000-4000-8000-000000000001');
select pg_temp.assert_access(cardinality(public.get_my_permissions())=(select jsonb_array_length(public.get_permission_catalog())),'OWNER always receives full catalog');
select pg_temp.deny_access('select public.get_platform_dashboard()');
select pg_temp.deny_access('select public.set_admin_workspace((select t from access_fixture))');
select pg_temp.deny_access('update public.user_profiles set is_active=false');
select pg_temp.deny_access('insert into public.user_roles select * from public.user_roles');
select pg_temp.deny_access('select public.complete_account_operation(gen_random_uuid())');
select pg_temp.deny_access('select public.bootstrap_platform_superadmin(gen_random_uuid())');
select pg_temp.deny_access('select * from app_private.account_security');
select pg_temp.deny_access('select * from auth.users');
select pg_temp.deny_access('select public.manage_business_user(''ad040000-0000-4000-8000-000000000001'',''Escalation'',''OWNER'',true,1)');
select pg_temp.deny_access('select public.manage_business_user(''ad040000-0000-4000-8000-000000000001'',''Escalation'',''MANAGER'',true,1,array[''users:manage''])');
select pg_temp.deny_access('select public.manage_business_user(''ad040000-0000-4000-8000-000000000001'',''Missing dependencies'',''MANAGER'',true,1,array[''purchases:pay''])');
select public.manage_business_user('ad040000-0000-4000-8000-000000000001','Restricted manager','MANAGER',true,1,array['dashboard:view','purchases:view','purchases:manage','purchases:create']);
select pg_temp.access_login('ad040000-0000-4000-8000-000000000001');
select pg_temp.assert_access(public.get_my_permissions()@>array['purchases:create'] and not(public.get_my_permissions()@>array['purchases:pay']),'Individual allowlist replaces role default');
select pg_temp.deny_access('select public.record_purchase_payment(gen_random_uuid(),''[]'',gen_random_uuid())');
select pg_temp.deny_access('select public.get_business_users()');
select pg_temp.deny_access('select public.prepare_account_operation(gen_random_uuid(),''{"kind":"business","business_name":"Unauthorized","name":"Attacker","email":"attacker@example.invalid"}'')');
select pg_temp.assert_access((select count(*)=0 from public.tenants where business_name='Access Test B'),'Foreign business identity hidden');
select pg_temp.access_login('ad050000-0000-4000-8000-000000000001');
select pg_temp.assert_access(public.get_my_permissions()@>array['pos:sell'] and not(public.get_my_permissions()@>array['finance:manage']),'SALESMAN operational default preserved');
select pg_temp.deny_access('select public.get_finance_analysis(''{}'')');
select pg_temp.deny_access('select public.manage_business_user(''ad050000-0000-4000-8000-000000000001'',''Me'',''OWNER'',true,1)');
select pg_temp.access_login('ad020000-0000-4000-8000-000000000001');
select public.manage_business_user('ad040000-0000-4000-8000-000000000001','Disabled manager','MANAGER',false,2,array['dashboard:view']);
select pg_temp.access_login('ad040000-0000-4000-8000-000000000001');
select pg_temp.assert_access(cardinality(public.get_my_permissions())=0,'Disabled user existing JWT loses access immediately');
select pg_temp.deny_access('select public.get_dashboard_snapshot()');
-- Probe every exposed authenticated RPC under a revoked identity, not only new endpoints.
do $$ declare f record;args text;result jsonb;begin
 for f in select p.oid,p.proname,p.proargtypes from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.prokind='f' and has_function_privilege('authenticated',p.oid,'execute') loop
  select string_agg('null::'||format_type(a,null),',' order by ord) into args from unnest(f.proargtypes::oid[]) with ordinality as arg(a,ord);
  begin
   execute format('select to_jsonb(public.%I(%s))',f.proname,coalesce(args,'')) into result;
   if result is not null and result not in ('false'::jsonb,'[]'::jsonb,'null'::jsonb) then raise exception 'Revoked identity read data through %',f.proname;end if;
  exception when insufficient_privilege then null;
  end;
 end loop;
end $$;
select pg_temp.access_login('ad010000-0000-4000-8000-000000000001');
select public.set_admin_workspace((select t from access_fixture));
select pg_temp.assert_access(cardinality(public.get_my_permissions())=jsonb_array_length(public.get_permission_catalog()),'Superadmin effective permissions equal OWNER');
select pg_temp.assert_access((public.get_access_context()->>'role')='SUPERADMIN','Superadmin retains actual identity');
select pg_temp.assert_access((public.get_attendance_configuration()->>'can_correct')::boolean,'Superadmin receives the same attendance correction control as OWNER');
select public.create_lpg_brand('Access admin audit brand',null);
select pg_temp.assert_access((public.get_platform_dashboard()->>'businesses')::integer>=2,'Platform dashboard works');
select pg_temp.assert_access(jsonb_array_length(public.get_platform_storage()->'businesses')>=2,'Storage breakdown measures businesses');
select public.set_business_status((select t from access_fixture),'suspended','Access Test A','Security acceptance suspension');
select pg_temp.assert_access(cardinality(public.get_my_permissions())=0,'Suspended workspace immediately closes even for admin');
select pg_temp.access_login('ad020000-0000-4000-8000-000000000001');
select pg_temp.assert_access((select count(*)=0 from public.tenants),'Suspended business session cannot read tenant data');
select pg_temp.deny_access('select public.get_dashboard_snapshot()');
select pg_temp.access_login('ad010000-0000-4000-8000-000000000001');
select public.set_business_status((select t from access_fixture),'active','Access Test A','Security acceptance reactivation');
select public.set_admin_workspace(null);
select pg_temp.assert_access(cardinality(public.get_my_permissions())=0,'Returning to admin removes business permissions');
reset role;
select pg_temp.assert_access(exists(select 1 from public.audit_logs a join access_fixture f on f.t=a.tenant_id where a.performed_by='ad010000-0000-4000-8000-000000000001'),'Business audit records actual superadmin actor');
select pg_temp.assert_access(not exists(select 1 from public.user_profiles where user_id='ad010000-0000-4000-8000-000000000001'),'Platform admin has no fabricated business membership');
select pg_temp.assert_access(not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname in ('public','app_private') and c.relkind='r' and not c.relrowsecurity),'Every application table has RLS');
select pg_temp.assert_access(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','app_private') and has_function_privilege('anon',p.oid,'execute')),'No anonymous application function execution');
select pg_temp.assert_access(to_regprocedure('public.setup_business(text,text)') is null,'Public provisioning contract removed');
select 'PASS: bootstrap, first-login restriction, OWNER completeness, individual MANAGER capabilities, SALESMAN defaults, session revocation, tenant suspension, platform switching, real actor attribution, direct-write/escalation denial, storage and complete RLS/function grant audit';
rollback;
