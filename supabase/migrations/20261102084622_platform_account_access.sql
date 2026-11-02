-- Platform identity is independent of tenant membership and employee job roles.
-- Passwords are handled by GoTrue through the private account service, never SQL/RPC payloads.
create table app_private.platform_superadmins (
 user_id uuid primary key references auth.users(id), is_active boolean not null default true,
 created_at timestamptz not null default now()
);
create table app_private.platform_bootstrap (
 singleton boolean primary key default true check(singleton), user_id uuid not null references auth.users(id),
 consumed_at timestamptz not null default now()
);
create table app_private.account_security (
 user_id uuid primary key references auth.users(id) on delete cascade,
 must_change_password boolean not null default false, reset_pending boolean not null default false,
 reset_request_id uuid, last_reset_write_id uuid, self_change_nonce uuid, self_change_expires_at timestamptz,
 password_changed_at timestamptz, revision integer not null default 1
);
insert into app_private.account_security(user_id) select id from auth.users;
create table app_private.admin_workspace_sessions (
 session_id uuid primary key references auth.sessions(id) on delete cascade,
 user_id uuid not null references app_private.platform_superadmins(user_id),
 tenant_id uuid not null references public.tenants(tenant_id), entered_at timestamptz not null default now()
);
-- All actor foreign keys remain tenant-qualified. A platform actor is not a membership.
create table app_private.tenant_actors (
 tenant_id uuid not null references public.tenants(tenant_id), user_id uuid not null references auth.users(id),
 full_name varchar(255), email varchar(255), platform_actor boolean not null default false,
 primary key(tenant_id,user_id)
);
insert into app_private.tenant_actors(tenant_id,user_id,full_name,email)
 select tenant_id,user_id,full_name,email from public.user_profiles;
do $$ declare c record; begin
 for c in select conrelid::regclass as tbl,conname,pg_get_constraintdef(oid) as def
 from pg_constraint where contype='f' and confrelid='public.user_profiles'::regclass
 and conrelid<>'public.user_roles'::regclass loop
  execute format('alter table %s drop constraint %I',c.tbl,c.conname);
  execute format('alter table %s add constraint %I %s',c.tbl,c.conname,
   replace(replace(c.def,'REFERENCES public.user_profiles','REFERENCES app_private.tenant_actors'),'REFERENCES user_profiles','REFERENCES app_private.tenant_actors'));
 end loop;
end $$;
create function app_private.sync_profile_actor() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into app_private.tenant_actors(tenant_id,user_id,full_name,email) values(new.tenant_id,new.user_id,new.full_name,new.email)
 on conflict(tenant_id,user_id) do update set full_name=excluded.full_name,email=excluded.email;
 insert into app_private.account_security(user_id) values(new.user_id) on conflict do nothing;
 return new;
end $$;
create trigger profile_actor after insert or update on public.user_profiles for each row execute function app_private.sync_profile_actor();

alter table public.permissions add column module text not null default 'General',
 add column label text, add column owner_only boolean not null default false,
 add column dependencies text[] not null default '{}';
create table app_private.user_permission_sets (
 tenant_id uuid not null, user_id uuid not null, permissions text[] not null,
 primary key(tenant_id,user_id), foreign key(tenant_id,user_id) references public.user_profiles(tenant_id,user_id)
);
alter table public.user_profiles add column revision integer not null default 1;
create table app_private.access_audit (
 audit_id uuid primary key default gen_random_uuid(), tenant_id uuid references public.tenants(tenant_id),
 actor_id uuid references auth.users(id), target_user_id uuid references auth.users(id),
 action text not null, details jsonb not null default '{}', created_at timestamptz not null default now()
);
create index access_audit_tenant_created_idx on app_private.access_audit(tenant_id,created_at desc);
create index access_audit_created_idx on app_private.access_audit(created_at desc);
create table app_private.account_operations (
 request_id uuid primary key, actor_id uuid not null references auth.users(id),
 session_id uuid not null, kind text not null check(kind in ('business','user','reset')),
 tenant_id uuid references public.tenants(tenant_id), target_user_id uuid not null,
 payload jsonb not null, state text not null default 'pending' check(state in ('pending','complete','superseded')),
 result jsonb, created_at timestamptz not null default now()
);
create index account_operations_actor_idx on app_private.account_operations(actor_id,created_at desc);
create unique index account_operations_pending_reset_idx on app_private.account_operations(target_user_id)
 where kind='reset' and state='pending';
-- Private objects have no browser privileges even if an exposed schema is expanded later.
do $$ declare t text; begin
 foreach t in array array['platform_superadmins','platform_bootstrap','account_security','admin_workspace_sessions',
 'tenant_actors','user_permission_sets','access_audit','account_operations'] loop
  execute format('alter table app_private.%I enable row level security',t);
  execute format('revoke all on app_private.%I from public,anon,authenticated,service_role',t);
 end loop;
end $$;

create function app_private.session_valid(who uuid, sid uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from auth.users u join auth.sessions s on s.user_id=u.id
 where u.id=who and s.id=sid and u.is_anonymous is not true
 and (u.banned_until is null or u.banned_until<=now()) and (s.not_after is null or s.not_after>now()))
$$;
create function app_private.session_id() returns uuid language sql stable set search_path='' as $$
 select nullif(auth.jwt()->>'session_id','')::uuid
$$;
create function app_private.account_ready(who uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.account_security s where s.user_id=who and not s.must_change_password and not s.reset_pending)
$$;
create function app_private.is_superadmin() returns boolean language sql stable security definer set search_path='' as $$
 select app_private.session_valid(auth.uid(),app_private.session_id()) and app_private.account_ready(auth.uid())
 and exists(select 1 from app_private.platform_superadmins where user_id=auth.uid() and is_active)
$$;
create or replace function app_private.current_tenant_id() returns uuid language sql stable security definer set search_path='' as $$
 select case when app_private.session_valid(auth.uid(),app_private.session_id()) and app_private.account_ready(auth.uid()) then
 case when app_private.is_superadmin() then
  (select w.tenant_id from app_private.admin_workspace_sessions w join public.tenants t using(tenant_id)
   where w.session_id=app_private.session_id() and w.user_id=auth.uid() and t.status='active')
 else (select p.tenant_id from public.user_profiles p join public.tenants t using(tenant_id)
   where p.user_id=auth.uid() and p.is_active and t.status='active') end end
$$;
create function app_private.is_owner() returns boolean language sql stable security definer set search_path='' as $$
 select app_private.current_tenant_id() is not null and (app_private.is_superadmin() or exists(
 select 1 from public.user_roles u join public.roles r using(tenant_id,role_id)
 where u.tenant_id=app_private.current_tenant_id() and u.user_id=auth.uid() and r.name='OWNER'))
$$;
create or replace function app_private.has_any_permission(p_permissions text[]) returns boolean
language sql stable security definer set search_path='' as $$
 select app_private.current_tenant_id() is not null and exists(
 select 1 from public.permissions p where p.permission_id=any(p_permissions) and (
 app_private.is_owner() or (not p.owner_only and case when exists(
 select 1 from app_private.user_permission_sets x where x.tenant_id=app_private.current_tenant_id() and x.user_id=auth.uid())
 then exists(select 1 from app_private.user_permission_sets x where x.tenant_id=app_private.current_tenant_id()
 and x.user_id=auth.uid() and p.permission_id=any(x.permissions))
 else exists(select 1 from public.user_roles u join public.roles r using(tenant_id,role_id)
 join public.role_permissions rp using(tenant_id,role_id) where u.tenant_id=app_private.current_tenant_id()
 and u.user_id=auth.uid() and rp.permission_id=p.permission_id) end)))
$$;
create or replace function app_private.require_owner(capability text) returns uuid language plpgsql set search_path='' as $$
declare t uuid:=app_private.require_permission(capability);begin
 if not app_private.is_owner() then raise insufficient_privilege using message='Only the owner can perform this operation';end if;return t;
end $$;
create or replace function public.get_my_permissions() returns text[] language sql stable security definer set search_path='' as $$
 select coalesce(array_agg(permission_id::text order by permission_id),'{}') from public.permissions where app_private.has_permission(permission_id)
$$;
create or replace function app_private.can_manage_inventory_prices() returns boolean language sql stable security definer set search_path='' as $$
 select app_private.is_owner() and app_private.has_permission('inventory:prices')
$$;
create or replace function public.can_cancel_purchases() returns boolean language sql stable security definer set search_path='' as $$
 select app_private.is_owner() and app_private.has_permission('purchases:cancel')
$$;
drop function public.setup_business(text,text);

create function app_private.manage_accounts(t uuid) returns void language plpgsql stable security definer set search_path='' as $$
begin
 if t is null or not(app_private.is_superadmin() or (t=app_private.current_tenant_id() and app_private.is_owner())) then
  raise insufficient_privilege using message='Owner or platform administrator access required';end if;
end $$;
create function app_private.actor_can_manage(who uuid,sid uuid,t uuid) returns boolean language sql stable security definer set search_path='' as $$
 select app_private.session_valid(who,sid) and app_private.account_ready(who) and (
 exists(select 1 from app_private.platform_superadmins where user_id=who and is_active)
 or exists(select 1 from public.user_profiles p join public.tenants b using(tenant_id)
 join public.user_roles u using(tenant_id,user_id) join public.roles r using(tenant_id,role_id)
 where p.user_id=who and p.tenant_id=t and p.is_active and b.status='active' and r.name='OWNER'))
$$;
create function app_private.validate_permission_set(perms text[]) returns void language plpgsql stable security definer set search_path='' as $$
begin
 if perms is null then return;end if;
 if cardinality(perms)>200 or exists(select 1 from unnest(perms) x left join public.permissions p on p.permission_id=x
 where p.permission_id is null or p.owner_only or not(p.dependencies<@perms)) then
 raise insufficient_privilege using message='Invalid, owner-only or missing dependent permissions';end if;
end $$;
create function public.get_access_context() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=auth.uid(); valid boolean:=app_private.session_valid(u,app_private.session_id());
 admin boolean; t uuid; p public.user_profiles; result jsonb;
begin
 if not valid then raise insufficient_privilege using message='Session expired. Sign in again.';end if;
 select exists(select 1 from app_private.platform_superadmins where user_id=u and is_active) into admin;
 select * into p from public.user_profiles where user_id=u;
 t:=app_private.current_tenant_id();
 select jsonb_build_object('is_superadmin',admin,'must_change_password',coalesce(s.must_change_password,false),
 'reset_pending',coalesce(s.reset_pending,false),'tenant_id',t,'business_name',(select business_name from public.tenants where tenant_id=t),
 'full_name',coalesce(p.full_name,case when admin then 'Platform administrator' else '' end),'email',a.email,
 'role',case when admin then 'SUPERADMIN' else (select r.name from public.user_roles ur join public.roles r using(tenant_id,role_id)
 where ur.user_id=u and ur.tenant_id=p.tenant_id order by case r.name when 'OWNER' then 0 when 'MANAGER' then 1 else 2 end limit 1) end,
 'access_status',case when admin then 'active' when p.user_id is null then 'unassigned' when not p.is_active then 'disabled'
 when (select status from public.tenants where tenant_id=p.tenant_id)<>'active' then 'suspended' else 'active' end,
 'permissions',public.get_my_permissions()) into result from auth.users a left join app_private.account_security s on s.user_id=a.id where a.id=u;
 return result;
end $$;
create function public.set_admin_workspace(p_tenant_id uuid default null) returns void language plpgsql security definer set search_path='' as $$
begin
 if not app_private.is_superadmin() then raise insufficient_privilege;end if;
 if p_tenant_id is null then delete from app_private.admin_workspace_sessions where session_id=app_private.session_id();
 else
  if not exists(select 1 from public.tenants where tenant_id=p_tenant_id and status='active') then raise exception 'Business is unavailable or suspended';end if;
  insert into app_private.tenant_actors(tenant_id,user_id,full_name,email,platform_actor)
  select p_tenant_id,u.id,'Platform administrator',u.email,true from auth.users u where u.id=auth.uid() on conflict do nothing;
  insert into app_private.admin_workspace_sessions(session_id,user_id,tenant_id) values(app_private.session_id(),auth.uid(),p_tenant_id)
  on conflict(session_id) do update set tenant_id=excluded.tenant_id,entered_at=now();
 end if;
 insert into app_private.access_audit(tenant_id,actor_id,action) values(p_tenant_id,auth.uid(),case when p_tenant_id is null then 'workspace_left' else 'workspace_entered' end);
end $$;
create function public.get_permission_catalog() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not (app_private.is_superadmin() or app_private.is_owner()) then raise insufficient_privilege;end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',permission_id,'module',module,'label',coalesce(label,permission_id),
 'description',description,'owner_only',owner_only,'dependencies',dependencies) order by module,permission_id) from public.permissions),'[]');
end $$;
create function public.get_business_users(p_tenant_id uuid default null,p_offset integer default 0,p_search text default '') returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=coalesce(p_tenant_id,app_private.current_tenant_id());result jsonb;
begin
 perform app_private.manage_accounts(t);
 if p_offset is null or p_offset<0 or p_offset>1000000 or length(p_search)>200 then raise exception 'Invalid user filters';end if;
 with matched as materialized(select p.*,u.last_sign_in_at,u.created_at,
 (select r.name from public.user_roles ur join public.roles r using(tenant_id,role_id) where ur.tenant_id=t and ur.user_id=p.user_id
 order by case r.name when 'OWNER' then 0 when 'MANAGER' then 1 else 2 end limit 1) role,
 coalesce(s.must_change_password,false) must_change_password,coalesce(s.reset_pending,false) reset_pending,
 x.permissions custom_permissions
 from public.user_profiles p join auth.users u on u.id=p.user_id
 left join app_private.account_security s on s.user_id=p.user_id left join app_private.user_permission_sets x on x.tenant_id=t and x.user_id=p.user_id
 where p.tenant_id=t and (p_search='' or p.full_name ilike '%'||p_search||'%' or p.email ilike '%'||p_search||'%')),
 page as(select m.*,case when m.role='OWNER' then (select array_agg(permission_id::text) from public.permissions)
 else coalesce(m.custom_permissions,(select array_agg(rp.permission_id::text) from public.user_roles ur join public.role_permissions rp using(tenant_id,role_id)
 join public.permissions c on c.permission_id=rp.permission_id where ur.tenant_id=t and ur.user_id=m.user_id and not c.owner_only)) end permissions
 from matched m order by full_name,user_id limit 25 offset p_offset)
 select jsonb_build_object('total',(select count(*) from matched),'entries',coalesce((select jsonb_agg(to_jsonb(page)) from page),'[]'),
 'role_defaults',(select jsonb_object_agg(r.name,coalesce((select jsonb_agg(p.permission_id order by p.permission_id)
 from public.role_permissions rp join public.permissions p using(permission_id) where rp.tenant_id=t and rp.role_id=r.role_id and not p.owner_only),'[]'::jsonb))
 from public.roles r where r.tenant_id=t and r.name in ('MANAGER','SALESMAN'))) into result;
 return result;
end $$;
create function public.manage_business_user(p_user_id uuid,p_name text,p_role text,p_active boolean,p_expected_revision integer,p_permissions text[] default null,p_tenant_id uuid default null)
returns void language plpgsql security definer set search_path='' as $$
declare t uuid:=coalesce(p_tenant_id,app_private.current_tenant_id());p public.user_profiles;old_role text;
begin
 perform app_private.manage_accounts(t);
 perform 1 from public.tenants where tenant_id=t for update;
 select * into p from public.user_profiles where tenant_id=t and user_id=p_user_id for update;
 if not found or p.revision is distinct from p_expected_revision then raise exception 'Account changed. Reload before saving.';end if;
 select r.name into old_role from public.user_roles u join public.roles r using(tenant_id,role_id) where u.tenant_id=t and u.user_id=p_user_id order by case r.name when 'OWNER' then 0 else 1 end limit 1;
 if p_user_id=auth.uid() or old_role='OWNER' and (not app_private.is_superadmin() or p_role<>'OWNER' or p_permissions is not null)
 or old_role<>'OWNER' and p_role not in ('MANAGER','SALESMAN') then raise insufficient_privilege using message='This account or role is protected';end if;
 if nullif(trim(p_name),'') is null or length(trim(p_name))>255 or p_active is null or p_role is null then raise exception 'Enter a valid account name, role and status';end if;
 if old_role='OWNER' and not p_active and not exists(select 1 from public.user_profiles q join public.user_roles ur using(tenant_id,user_id) join public.roles r using(tenant_id,role_id)
 where q.tenant_id=t and q.user_id<>p_user_id and q.is_active and r.name='OWNER') then raise exception 'Keep at least one active OWNER. Suspend the business to block all access.';end if;
 perform app_private.validate_permission_set(p_permissions);
 update public.user_profiles set full_name=trim(p_name),is_active=p_active,revision=revision+1 where user_id=p_user_id;
 delete from public.user_roles where tenant_id=t and user_id=p_user_id;
 insert into public.user_roles(tenant_id,user_id,role_id) select t,p_user_id,role_id from public.roles where tenant_id=t and name=p_role;
 delete from app_private.user_permission_sets where tenant_id=t and user_id=p_user_id;
 if p_permissions is not null then insert into app_private.user_permission_sets values(t,p_user_id,p_permissions);end if;
 if not p_active then delete from auth.sessions where user_id=p_user_id;end if;
 insert into app_private.access_audit(tenant_id,actor_id,target_user_id,action,details)
 values(t,auth.uid(),p_user_id,'user_updated',jsonb_build_object('previous_role',old_role,'role',p_role,'active',p_active,'permissions',p_permissions,'name',trim(p_name)));
end $$;
create function public.set_business_status(p_tenant_id uuid,p_status text,p_confirmation text,p_reason text) returns void language plpgsql security definer set search_path='' as $$
declare previous text;begin
 if not app_private.is_superadmin() then raise insufficient_privilege;end if;
 if p_status not in ('active','suspended') or p_status is null or length(trim(coalesce(p_reason,''))) not between 3 and 500 then raise exception 'Choose a status and enter a reason';end if;
 select status into previous from public.tenants where tenant_id=p_tenant_id and business_name=p_confirmation for update;
 if not found then raise exception 'Type the exact business name to confirm';end if;
 update public.tenants set status=p_status where tenant_id=p_tenant_id;
 if p_status='suspended' then
  delete from auth.sessions where user_id in(select user_id from public.user_profiles where tenant_id=p_tenant_id);
  delete from app_private.admin_workspace_sessions where tenant_id=p_tenant_id;
 end if;
 insert into app_private.access_audit(tenant_id,actor_id,action,details) values(p_tenant_id,auth.uid(),'business_status_changed',jsonb_build_object('from',previous,'to',p_status,'reason',trim(p_reason)));
end $$;
create function public.get_platform_businesses(p_offset integer default 0,p_search text default '') returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;begin
 if not app_private.is_superadmin() then raise insufficient_privilege;end if;
 if p_offset is null or p_offset<0 or p_offset>1000000 or length(p_search)>200 then raise exception 'Invalid business filters';end if;
 with matched as materialized(select t.*,(select count(*) from public.user_profiles p where p.tenant_id=t.tenant_id) users from public.tenants t where p_search='' or t.business_name ilike '%'||p_search||'%'),
 page as(select * from matched order by created_at desc,tenant_id limit 25 offset p_offset)
 select jsonb_build_object('total',(select count(*) from matched),'entries',coalesce((select jsonb_agg(to_jsonb(page)) from page),'[]')) into result;return result;
end $$;
create function public.get_platform_dashboard() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not app_private.is_superadmin() then raise insufficient_privilege;end if;
 return jsonb_build_object('businesses',(select count(*) from public.tenants),'active',(select count(*) from public.tenants where status='active'),
 'suspended',(select count(*) from public.tenants where status='suspended'),'users',(select count(*) from auth.users),
 'database_bytes',pg_database_size(current_database()),'uploaded_bytes',(select coalesce(sum((metadata->>'size')::bigint),0) from storage.objects),'files',(select count(*) from storage.objects));
end $$;
create function public.get_platform_storage() returns jsonb language plpgsql security definer set search_path='' set statement_timeout='20s' as $$
declare tbl record;r record;totals jsonb:='{}';result jsonb;begin
 if not app_private.is_superadmin() then raise insufficient_privilege;end if;
 for tbl in select c.table_schema,c.table_name from information_schema.columns c join information_schema.tables t using(table_catalog,table_schema,table_name)
 where c.table_schema in ('public','app_private') and c.column_name='tenant_id' and t.table_type='BASE TABLE' loop
  for r in execute format('select tenant_id,sum(pg_column_size(r))::bigint bytes from %I.%I r group by tenant_id',tbl.table_schema,tbl.table_name) loop
   if r.tenant_id is not null then totals:=jsonb_set(totals,array[r.tenant_id::text],to_jsonb(coalesce((totals->>r.tenant_id::text)::bigint,0)+r.bytes));end if;
  end loop;
 end loop;
 select coalesce(jsonb_agg(jsonb_build_object('tenant_id',t.tenant_id,'business_name',t.business_name,'database_estimate_bytes',coalesce((totals->>t.tenant_id::text)::bigint,0),
 'uploaded_bytes',coalesce(f.bytes,0),'files',coalesce(f.files,0)) order by t.business_name),'[]') into result
 from public.tenants t left join lateral(select sum((o.metadata->>'size')::bigint) bytes,count(*) files from storage.objects o where split_part(o.name,'/',1)=t.tenant_id::text) f on true;
 return jsonb_build_object('measured_at',now(),'businesses',result,'database_bytes',pg_database_size(current_database()),'uploaded_bytes',(select coalesce(sum((metadata->>'size')::bigint),0) from storage.objects));
end $$;
create function public.get_access_audit(p_tenant_id uuid default null,p_offset integer default 0) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=p_tenant_id;result jsonb;begin
 if not app_private.is_superadmin() then t:=coalesce(t,app_private.current_tenant_id());perform app_private.manage_accounts(t);end if;
 if p_offset is null or p_offset<0 or p_offset>1000000 then raise exception 'Invalid activity page';end if;
 select jsonb_build_object('entries',coalesce(jsonb_agg(to_jsonb(q)),'[]')) into result from (
 select a.*,u.email actor_email,v.email target_email,b.business_name from app_private.access_audit a left join auth.users u on u.id=a.actor_id
 left join auth.users v on v.id=a.target_user_id left join public.tenants b using(tenant_id)
 where t is null or a.tenant_id=t order by a.created_at desc,a.audit_id desc limit 25 offset p_offset) q;
 return result;
end $$;

-- Two-phase provisioning is retryable. GoTrue owns credentials; database completion revalidates
-- the original actor/session and never accepts caller-supplied membership or role metadata.
create function public.prepare_account_operation(p_request_id uuid,p_payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare kind text:=p_payload->>'kind';t uuid:=nullif(p_payload->>'tenant_id','')::uuid;target uuid;existing app_private.account_operations;p public.user_profiles;previous_reset uuid;
begin
 if not app_private.session_valid(auth.uid(),app_private.session_id()) or not app_private.account_ready(auth.uid()) then raise insufficient_privilege;end if;
 if p_request_id is null or kind not in ('business','user','reset') or kind is null then raise exception 'Invalid account operation';end if;
 if jsonb_typeof(p_payload) is distinct from 'object' or length(p_payload::text)>16384 then raise exception 'Invalid account details';end if;
 if exists(select 1 from jsonb_object_keys(p_payload) k where k<>all(case kind
 when 'business' then array['kind','business_name','name','email'] when 'user' then array['kind','tenant_id','name','email','role'] else array['kind','tenant_id','user_id'] end)) then
 raise exception 'Unknown account fields; credentials belong only in the Auth service';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
 select * into existing from app_private.account_operations where request_id=p_request_id;
 if found then
  if existing.actor_id<>auth.uid() or existing.payload<>p_payload or not app_private.actor_can_manage(existing.actor_id,app_private.session_id(),existing.tenant_id) then raise insufficient_privilege;end if;
  if existing.state='pending' then update app_private.account_operations set session_id=app_private.session_id() where request_id=p_request_id;end if;
  if existing.state='superseded' then raise exception 'This reset was superseded. Start a new reset request.';end if;
  return jsonb_build_object('target_user_id',existing.target_user_id,'state',existing.state,'result',existing.result);
 end if;
 if kind='business' then if not app_private.is_superadmin() or t is not null then raise insufficient_privilege;end if;
  if nullif(trim(p_payload->>'business_name'),'') is null or length(p_payload->>'business_name')>255 then raise exception 'Enter a business name';end if;
 else t:=coalesce(t,app_private.current_tenant_id());perform app_private.manage_accounts(t);end if;
 if kind='reset' then
  target:=(p_payload->>'user_id')::uuid;
  select * into p from public.user_profiles where tenant_id=t and user_id=target for update;
  if not found or target=auth.uid() or (not app_private.is_superadmin() and exists(select 1 from public.user_roles u join public.roles r using(tenant_id,role_id) where u.tenant_id=t and u.user_id=target and r.name='OWNER')) then
   raise insufficient_privilege using message='This password cannot be reset by this account';end if;
  perform pg_advisory_xact_lock(hashtextextended('account-reset:'||target::text,0));
  -- A fresh authorized reset supersedes an interrupted one. The Auth trigger fences
  -- delayed writes from the older generation, including after the new one completes.
  select o.request_id into previous_reset from app_private.account_operations o where o.target_user_id=target and o.kind='reset' and o.state='pending' for update;
  if found then
   update app_private.account_operations set state='superseded' where request_id=previous_reset;
   insert into app_private.access_audit(tenant_id,actor_id,target_user_id,action,details)
   values(t,auth.uid(),target,'password_reset_superseded',jsonb_build_object('previous_request_id',previous_reset,'request_id',p_request_id));
  end if;
  insert into app_private.account_security(user_id,must_change_password,reset_pending,reset_request_id) values(target,true,true,p_request_id)
  on conflict(user_id) do update set must_change_password=true,reset_pending=true,reset_request_id=p_request_id,
   last_reset_write_id=null,self_change_nonce=null,self_change_expires_at=null,revision=app_private.account_security.revision+1;
  delete from auth.sessions where user_id=target;
 else
  target:=gen_random_uuid();
  if nullif(trim(p_payload->>'name'),'') is null or length(p_payload->>'name')>255 or length(p_payload->>'email')>255
  or coalesce(p_payload->>'email','')!~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Enter a valid name and email';end if;
  if kind='user' and coalesce(p_payload->>'role','') not in ('MANAGER','SALESMAN') then raise insufficient_privilege using message='Only MANAGER and SALESMAN accounts may be created';end if;
 end if;
 insert into app_private.account_operations(request_id,actor_id,session_id,kind,tenant_id,target_user_id,payload)
 values(p_request_id,auth.uid(),app_private.session_id(),kind,t,target,p_payload);
 insert into app_private.access_audit(tenant_id,actor_id,target_user_id,action,details)
 values(t,auth.uid(),case when kind='reset' then target end,'account_'||kind||'_requested',jsonb_build_object('request_id',p_request_id));
 return jsonb_build_object('target_user_id',target,'state','pending');
end $$;
create function public.complete_account_operation(p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare op app_private.account_operations;u auth.users;t uuid;role_name text;v_result jsonb;
begin
 select * into op from app_private.account_operations where request_id=p_request_id for update;
 if not found or not app_private.actor_can_manage(op.actor_id,op.session_id,op.tenant_id) then raise insufficient_privilege;end if;
 if op.state='complete' then return op.result;end if;
 if op.state<>'pending' then raise exception 'This reset was superseded. Start a new reset request.';end if;
 select * into u from auth.users where id=op.target_user_id for update;
 if not found or u.is_anonymous is true then raise exception 'Auth provisioning has not completed';end if;
 t:=op.tenant_id;
 if op.kind<>'reset' then
  if lower(u.email)<>lower(trim(op.payload->>'email')) or exists(select 1 from public.user_profiles where user_id=u.id)
  or exists(select 1 from app_private.platform_superadmins where user_id=u.id)
  or u.raw_app_meta_data->>'lpg_provisioning_request' is distinct from p_request_id::text then raise insufficient_privilege;end if;
  if op.kind='business' then
   if not exists(select 1 from app_private.platform_superadmins where user_id=op.actor_id and is_active) then raise insufficient_privilege;end if;
   insert into public.tenants(business_name,status) values(trim(op.payload->>'business_name'),'active') returning tenant_id into t;
   insert into public.roles(tenant_id,name) values(t,'OWNER'),(t,'MANAGER'),(t,'SALESMAN');
   insert into public.role_permissions(tenant_id,role_id,permission_id)
   select t,r.role_id,p.permission_id from public.roles r cross join public.permissions p where r.tenant_id=t
   and (r.name='OWNER' or r.name='MANAGER' and not p.owner_only or r.name='SALESMAN' and p.permission_id in ('dashboard:view','pos:sell','sales:view','receipts:print','preferences:manage'));
   role_name:='OWNER';
  else role_name:=op.payload->>'role';end if;
  insert into public.user_profiles(user_id,tenant_id,email,full_name) values(u.id,t,u.email,trim(op.payload->>'name'));
  insert into public.user_roles(tenant_id,user_id,role_id) select t,u.id,role_id from public.roles where tenant_id=t and name=role_name;
 else
  if not exists(select 1 from public.user_profiles where user_id=u.id and tenant_id=t)
  or not exists(select 1 from app_private.account_security where user_id=u.id and reset_pending and reset_request_id=p_request_id and last_reset_write_id=p_request_id) then raise insufficient_privilege;end if;
 end if;
 insert into app_private.account_security(user_id,must_change_password,reset_pending) values(u.id,true,false)
 on conflict(user_id) do update set must_change_password=true,reset_pending=false,reset_request_id=null,
  self_change_nonce=null,self_change_expires_at=null,revision=app_private.account_security.revision+1;
 delete from auth.sessions where user_id=u.id;
 v_result:=jsonb_build_object('user_id',u.id,'tenant_id',t,'must_change_password',true);
 update app_private.account_operations set state='complete',tenant_id=t,result=v_result where request_id=p_request_id;
 insert into app_private.access_audit(tenant_id,actor_id,target_user_id,action,details)
 values(t,op.actor_id,u.id,'account_'||op.kind||'_completed',jsonb_build_object('request_id',p_request_id,'role',role_name));
 return v_result;
end $$;
create function public.bootstrap_platform_superadmin(p_user_id uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(hashtextextended('platform-superadmin-bootstrap',0));
 if exists(select 1 from app_private.platform_bootstrap) or exists(select 1 from app_private.platform_superadmins)
 or exists(select 1 from public.user_profiles where user_id=p_user_id) or not exists(select 1 from auth.users where id=p_user_id and is_anonymous is not true and email_confirmed_at is not null) then
 raise exception 'One-time platform bootstrap is unavailable';end if;
 insert into app_private.platform_superadmins(user_id) values(p_user_id);
 insert into app_private.platform_bootstrap(user_id) values(p_user_id);
 insert into app_private.account_security(user_id,must_change_password) values(p_user_id,true) on conflict(user_id) do update set must_change_password=true;
 delete from auth.sessions where user_id=p_user_id;
 insert into app_private.access_audit(actor_id,target_user_id,action) values(p_user_id,p_user_id,'platform_bootstrapped');
end $$;
create function public.platform_bootstrap_available() returns boolean language sql stable security definer set search_path='' as $$
 select not exists(select 1 from app_private.platform_bootstrap) and not exists(select 1 from app_private.platform_superadmins)
$$;
revoke all on function public.platform_bootstrap_available() from public,anon,authenticated;
grant execute on function public.platform_bootstrap_available() to service_role;
-- Pinned GoTrue adminUserUpdate calls SetRole and UpdatePassword in one transaction,
-- in that order (supabase/auth v2.196.0 internal/api/admin.go). The server-only role
-- parameter transports a one-use transaction marker. This BEFORE trigger always
-- preserves the actual Auth role; no nonce role is stored, granted or used in JWTs.
create function app_private.auth_password_context() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.role like 'lpg_password:%' then
  if new.role !~ '^lpg_password:(self|reset):[a-f0-9-]{36}$' or old.role<>'authenticated' then raise insufficient_privilege;end if;
  perform set_config('app_private.password_write',substring(new.role from 14),true);
  new.role:=old.role;
 end if;
 return new;
end $$;
create trigger account_password_context before update of role on auth.users for each row execute function app_private.auth_password_context();
create function app_private.password_changed() returns trigger language plpgsql security definer set search_path='' as $$
declare sec app_private.account_security;marker text:=current_setting('app_private.password_write',true);actor uuid;
begin
 if old.encrypted_password is distinct from new.encrypted_password then
  select * into sec from app_private.account_security where user_id=new.id for update;
  if found then
   if sec.reset_pending then
    if sec.reset_request_id is null or marker is distinct from 'reset:'||sec.reset_request_id::text then
     raise insufficient_privilege using message='Password reset was superseded or is not authorized';end if;
    select o.actor_id into actor from app_private.account_operations o where o.request_id=sec.reset_request_id and o.target_user_id=new.id and o.state='pending';
    if not found then raise insufficient_privilege using message='Password reset is not authorized';end if;
   elsif sec.self_change_nonce is null or sec.self_change_expires_at is null or sec.self_change_expires_at<=now()
    or marker is distinct from 'self:'||sec.self_change_nonce::text then
    raise insufficient_privilege using message='Use the account password service';
   else actor:=new.id;end if;
  else raise insufficient_privilege using message='Account password management is unavailable';end if;
  update app_private.account_security set must_change_password=case when reset_pending then true else false end,
   last_reset_write_id=case when reset_pending then reset_request_id else last_reset_write_id end,
   password_changed_at=now(),self_change_nonce=null,self_change_expires_at=null,revision=revision+1 where user_id=new.id;
  delete from auth.sessions where user_id=new.id;
  insert into app_private.access_audit(tenant_id,actor_id,target_user_id,action)
  values((select tenant_id from public.user_profiles where user_id=new.id),actor,new.id,case when sec.reset_pending then 'password_reset' else 'password_changed' end);
 end if;
 return new;
end $$;
create trigger account_password_changed after update of encrypted_password on auth.users for each row execute function app_private.password_changed();

create function public.prepare_own_password_change() returns uuid language plpgsql security definer set search_path='' as $$
declare nonce uuid:=gen_random_uuid();u uuid:=auth.uid();begin
 if not app_private.session_valid(u,app_private.session_id()) or not (
 exists(select 1 from app_private.platform_superadmins where user_id=u and is_active) or
 exists(select 1 from public.user_profiles p join public.tenants t using(tenant_id) where p.user_id=u and p.is_active and t.status='active')) then raise insufficient_privilege;end if;
 insert into app_private.account_security(user_id) values(u) on conflict do nothing;
 perform 1 from app_private.account_security where user_id=u and not reset_pending for update;
 if not found then raise insufficient_privilege using message='Administrative password reset is pending';end if;
 update app_private.account_security set self_change_nonce=nonce,self_change_expires_at=now()+interval '5 minutes' where user_id=u;
 return nonce;
end $$;
grant execute on function public.prepare_own_password_change() to authenticated;

-- An existing account changing its email must not desynchronize the trusted directory.
create function app_private.auth_email_changed() returns trigger language plpgsql security definer set search_path='' as $$
begin
 update public.user_profiles set email=new.email,revision=revision+1 where user_id=new.id;
 insert into app_private.access_audit(tenant_id,actor_id,target_user_id,action,details)
 values((select tenant_id from public.user_profiles where user_id=new.id),new.id,new.id,'email_changed',jsonb_build_object('from',old.email,'to',new.email));
 return new;
end $$;
create trigger account_email_changed after update of email on auth.users for each row when(old.email is distinct from new.email) execute function app_private.auth_email_changed();

revoke all on function public.complete_account_operation(uuid),public.bootstrap_platform_superadmin(uuid) from public,anon,authenticated;
grant execute on function public.complete_account_operation(uuid),public.bootstrap_platform_superadmin(uuid) to service_role;
grant execute on function public.get_access_context(),public.set_admin_workspace(uuid),public.get_permission_catalog(),
 public.get_business_users(uuid,integer,text),public.manage_business_user(uuid,text,text,boolean,integer,text[],uuid),
 public.set_business_status(uuid,text,text,text),public.get_platform_businesses(integer,text),public.get_platform_dashboard(),
 public.get_platform_storage(),public.get_access_audit(uuid,integer),public.prepare_account_operation(uuid,jsonb) to authenticated;

-- Capability catalog: broad management is a dependency, never a substitute for action gates.
insert into public.permissions(permission_id,description,module,label,owner_only,dependencies) values
('inventory:manage','Manage product details','Inventory','Manage product details',false,array['inventory:view']::text[]),
('customers:manage','Edit customer details','Customers','Edit customer details',false,array['customers:view']::text[]),
('purchases:manage','Manage purchases','Purchases','Manage purchases',false,array['purchases:view']::text[]),
('logistics:manage','Manage logistics','Logistics','Manage logistics',false,array['logistics:view']::text[]),
('finance:manage','Manage financial operations','Finance','Manage financial operations',false,array['finance:view']::text[]),
('employees:manage','Manage employee profiles','Employees','Manage employee profiles',false,array['employees:view']::text[]),
('settings:manage','Manage business settings','Settings','Manage business settings',false,array[]::text[]),
('gas_plants:manage','Manage plants and officers','Gas plants','Manage plants and officers',false,array['gas_plants:view']::text[]),
('inventory:create','Register products','Inventory','Register products',false,array['inventory:manage']::text[]),
('inventory:edit','Edit products and photos','Inventory','Edit products and photos',false,array['inventory:manage']::text[]),
('inventory:alerts','Configure stock alerts','Inventory','Configure stock alerts',false,array['inventory:manage']::text[]),
('inventory:prices','Set selling/buying prices and commissions','Inventory','Set selling/buying prices and commissions',true,array['inventory:manage']::text[]),
('inventory:adjust','Adjust stock and carrying value','Inventory','Adjust stock and carrying value',true,array['inventory:manage']::text[]),
('customers:create','Create customers','Customers','Create customers',false,array['customers:view']::text[]),
('purchases:create','Create purchases','Purchases','Create purchases',false,array['purchases:manage']::text[]),
('purchases:edit','Edit purchases','Purchases','Edit purchases',false,array['purchases:manage']::text[]),
('purchases:dispatch','Dispatch purchases','Purchases','Dispatch purchases',false,array['purchases:manage']::text[]),
('purchases:receive','Receive stock','Purchases','Receive stock',false,array['purchases:manage']::text[]),
('purchases:pay','Record purchase payments','Purchases','Record purchase payments',false,array['purchases:manage']::text[]),
('purchases:refund','Record supplier refunds','Purchases','Record supplier refunds',false,array['purchases:manage']::text[]),
('purchases:cancel','Cancel purchases','Purchases','Cancel purchases',true,array['purchases:manage']::text[]),
('purchases:commission','Correct commission receipts','Purchases','Correct commission receipts',true,array['purchases:manage']::text[]),
('sales:collect_money','Collect sale payments and customer charges','Sales','Collect sale payments and customer charges',false,array['finance:manage','sales:view']::text[]),
('sales:cancel','Cancel sales','Sales','Cancel sales',true,array['finance:manage','sales:view']::text[]),
('sales:refund','Refund cancelled sales','Sales','Refund cancelled sales',true,array['finance:manage','sales:view']::text[]),
('logistics:vehicles','Create and edit vehicles','Logistics','Create and edit vehicles',false,array['logistics:manage']::text[]),
('logistics:transits','Create and transition transits','Logistics','Create and transition transits',false,array['logistics:manage']::text[]),
('logistics:costs','Record incurred operating costs','Logistics','Record incurred operating costs',false,array['logistics:manage']::text[]),
('logistics:pay','Pay and return operating costs','Logistics','Pay and return operating costs',false,array['logistics:manage']::text[]),
('logistics:services','Manage vehicle service trips','Logistics','Manage vehicle service trips',false,array['logistics:manage']::text[]),
('logistics:retire','Availability and vehicle retirement','Logistics','Availability and vehicle retirement',true,array['logistics:manage']::text[]),
('employees:create','Create employee profiles','Employees','Create employee profiles',false,array['employees:manage']::text[]),
('employees:edit','Edit employment and salary terms','Employees','Edit employment and salary terms',false,array['employees:manage']::text[]),
('attendance:manage','Link devices and correct attendance','Employees','Link devices and correct attendance',false,array['employees:manage']::text[]),
('payroll:return','Return or correct payroll payments','Payroll','Return or correct payroll payments',false,array['payroll:pay']::text[]),
('finance:entries','Record expenses, withdrawals and revenue','Finance','Record expenses, withdrawals and revenue',false,array['finance:manage']::text[]),
('finance:returns','Record returned financial entries','Finance','Record returned financial entries',false,array['finance:manage']::text[]),
('wallets:manage','Create, edit and deactivate wallets','Wallets','Create, edit and deactivate wallets',false,array['finance:manage']::text[]),
('wallets:transfer','Transfer cash or business portions','Wallets','Transfer cash or business portions',false,array['finance:manage']::text[]),
('wallets:adjust','Correct wallet balances','Wallets','Correct wallet balances',true,array['finance:manage']::text[]),
('finance:owner','Loans, assets, capital and obligations','Finance','Loans, assets, capital and obligations',true,array['finance:manage']::text[]),
('reports:view','Financial Analysis and reports','Reports','Financial Analysis and reports',false,array['finance:view']::text[]),
('users:manage','Manage business login accounts','Access','Manage business login accounts',true,array[]::text[])
on conflict(permission_id) do update set description=excluded.description,module=excluded.module,label=excluded.label,
 owner_only=excluded.owner_only,dependencies=excluded.dependencies;
update public.permissions set module=case split_part(permission_id,':',1)
 when 'dashboard' then 'Dashboard' when 'pos' then 'Sales' when 'sales' then 'Sales' when 'receipts' then 'Sales'
 when 'printers' then 'Settings' when 'inventory' then 'Inventory' when 'customers' then 'Customers' when 'purchases' then 'Purchases'
 when 'logistics' then 'Logistics' when 'employees' then 'Employees' when 'payroll' then 'Payroll' when 'gas_plants' then 'Gas plants'
 when 'finance' then 'Finance' when 'audit' then 'Activity' when 'preferences' then 'Account' else module end,
 label=coalesce(label,initcap(replace(replace(permission_id,':',' — '),'_',' ')));
update public.permissions set dependencies=array['payroll:view'] where permission_id='payroll:pay';
update public.permissions set dependencies=array['sales:view'] where permission_id='sales:collect_bottles';
insert into public.role_permissions(tenant_id,role_id,permission_id)
 select r.tenant_id,r.role_id,p.permission_id from public.roles r cross join public.permissions p
 where r.name='OWNER' or r.name='MANAGER' and not p.owner_only on conflict do nothing;
-- Owners have the entire catalog regardless of stale or incomplete mappings.
-- Do not invent ownership for unassigned identities; the deployed membership audit found three valid OWNER accounts.
alter table public.user_roles add constraint one_authorization_role_per_member unique(tenant_id,user_id);
alter table public.roles add constraint authorization_role_names check(name in ('OWNER','MANAGER','SALESMAN'));

-- Append action checks to each existing canonical workflow. Original tenancy, stock,
-- journal locks, validation, owner checks and recovery contracts remain in place.
do $gates$ declare r record;definition text; begin
 for r in select * from (values
 ('set_stock_threshold','inventory:alerts'),
 ('set_product_image','inventory:edit'),
 ('save_product_prices','inventory:prices'),
 ('set_product_buying_price','inventory:prices'),
 ('set_monthly_commission','inventory:prices'),
 ('adjust_inventory','inventory:adjust'),
 ('create_purchase','purchases:create'),
 ('update_purchase','purchases:edit'),
 ('dispatch_purchase','purchases:dispatch'),
 ('receive_purchase','purchases:receive'),
 ('record_purchase_payment','purchases:pay'),
 ('refund_purchase','purchases:refund'),
 ('initiate_purchase_cancellation','purchases:cancel'),
 ('correct_commission_deduction','purchases:commission'),
 ('collect_sale_payment','sales:collect_money'),
 ('reverse_sale','sales:cancel'),
 ('refund_sale','sales:refund'),
 ('save_vehicle','logistics:vehicles'),
 ('create_custom_transit','logistics:transits'),
 ('transition_transit','logistics:transits'),
 ('save_transit_costs','logistics:costs'),
 ('record_operating_payment','logistics:pay'),
 ('save_service_trip','logistics:services'),
 ('finalize_service_trip','logistics:services'),
 ('set_vehicle_availability','logistics:retire'),
 ('set_employee_attendance_link','attendance:manage'),
 ('get_attendance_edit','attendance:manage'),
 ('correct_employee_attendance','attendance:manage'),
 ('save_finance_wallet','wallets:manage'),
 ('accounting_operation','finance:owner')
 ) gates(name,capability) loop
  select pg_get_functiondef(p.oid) into strict definition from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname=r.name;
  definition:=regexp_replace(definition,'\mbegin\M','begin perform app_private.require_permission('||quote_literal(r.capability)||');','i');
  execute definition;
 end loop;
end $gates$;
-- Dynamic form actions share one transaction but retain separate capabilities.
do $$ declare d text;begin
 select pg_get_functiondef('public.save_stove_product(jsonb,uuid)'::regprocedure) into d;
 d:=replace(d,'if id is null then','perform app_private.require_permission(case when id is null then ''inventory:create'' else ''inventory:edit'' end); if id is null then');execute d;
 select pg_get_functiondef('public.save_employee(jsonb,uuid)'::regprocedure) into d;
 d:=regexp_replace(d,'\mbegin\M','begin perform app_private.require_permission(case when eid is null then ''employees:create'' else ''employees:edit'' end); if jsonb_typeof(p_payload->''attendance_links'')=''array'' and jsonb_array_length(p_payload->''attendance_links'')>0 then perform app_private.require_permission(''attendance:manage'');end if;','i');execute d;
 select pg_get_functiondef('public.employee_payment_operation(jsonb,uuid)'::regprocedure) into d;
 d:=regexp_replace(d,'\mbegin\M','begin if action=''reverse_payment'' then perform app_private.require_permission(''payroll:return'');end if;','i');execute d;
 select pg_get_functiondef('public.record_financial_entry(jsonb,uuid)'::regprocedure) into d;
 d:=regexp_replace(d,'\mbegin\M','begin perform app_private.require_permission(case when p_payload->>''reversal_of'' is not null then ''finance:returns'' else ''finance:entries'' end);','i');execute d;
 select pg_get_functiondef('public.move_wallet_money(jsonb,uuid)'::regprocedure) into d;
 d:=regexp_replace(d,'\mbegin\M','begin perform app_private.require_permission(case when action=''transfer'' then ''wallets:transfer'' else ''wallets:adjust'' end);','i');execute d;
 select pg_get_functiondef('public.collect_sale_bottles(uuid,jsonb,uuid)'::regprocedure) into d;
 d:=replace(d,'app_private.require_permission(''finance:manage'')','app_private.require_permission(''sales:collect_money'')');execute d;
 select pg_get_functiondef('app_private.analysis_scope(jsonb)'::regprocedure) into d;
 d:=replace(d,'begin','begin perform app_private.require_permission(''reports:view'');');execute d;
end $$;
 -- Explicit attendance capabilities replace obsolete role-name-only checks.
do $$ declare f record;d text;begin
 for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
 and p.proname in ('get_attendance_configuration','get_attendance_edit','correct_employee_attendance') loop
  d:=pg_get_functiondef(f.oid);
  d:=replace(d,'exists('||chr(10)||' select 1 from public.user_roles','exists(select 1 from public.user_roles');
  d:=replace(d,'exists(select 1 from public.user_roles ur join public.roles r using(tenant_id,role_id) where ur.tenant_id=t and ur.user_id=auth.uid() and r.name in (''OWNER'',''MANAGER''))','app_private.has_permission(''attendance:manage'')');
  execute d;
 end loop;
 -- Attribution reads use the immutable tenant actor registry, including real platform identities.
 for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','app_private')
 and p.prokind='f' and p.prosrc ilike '%left join public.user_profiles%' loop
  d:=pg_get_functiondef(f.oid);
  -- Membership and administration functions must always read actual profiles.
  if d not like '%get_access_context%' and d not like '%get_business_users%' then
   d:=replace(d,'left join public.user_profiles','left join app_private.tenant_actors');execute d;
  end if;
 end loop;
end $$;

alter policy items_register on public.items with check(tenant_id=(select app_private.current_tenant_id())
 and (select app_private.has_permission('inventory:create')) and filled_quantity=0 and empty_quantity=0);
alter policy customers_create on public.customers with check(tenant_id=(select app_private.current_tenant_id())
 and (select app_private.has_any_permission(array['customers:create','pos:sell'])));
-- Aggregate dashboard access does not grant the full sales directory or wallet balances.
alter policy sales_read on public.sales using(tenant_id=(select app_private.current_tenant_id())
 and (select app_private.has_any_permission(array['sales:view','receipts:print'])));
alter policy sale_items_read on public.sale_items using(tenant_id=(select app_private.current_tenant_id())
 and (select app_private.has_any_permission(array['sales:view','receipts:print'])));
alter policy wallets_read on public.wallets using(tenant_id=(select app_private.current_tenant_id())
 and (select app_private.has_any_permission(array['finance:view','finance:manage'])));
alter policy sale_payments_read on public.sale_payments using(tenant_id=(select app_private.current_tenant_id())
 and (select app_private.has_any_permission(array['finance:view','finance:manage','sales:view','receipts:print'])));
do $$ declare f record;d text;begin
 for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
 and p.proname in ('get_customer_transactions','get_sale_bottles','get_sale_settlement') loop
  d:=pg_get_functiondef(f.oid);d:=replace(d,',''dashboard:view''','');execute d;
 end loop;
 select pg_get_functiondef('public.get_payment_wallets()'::regprocedure) into d;
 d:=replace(d,'''payroll:pay''','''payroll:pay'',''logistics:manage''');execute d;
end $$;
-- Existing private-image policy uses this helper for both metadata and byte authorization.
create or replace function app_private.product_image_access(object_name text,writing boolean default false)
returns boolean language sql stable security definer set search_path='' as $$
 select split_part(object_name,'/',1)=app_private.current_tenant_id()::text and
 case when writing then app_private.has_any_permission(array['inventory:create','inventory:edit'])
 else app_private.has_any_permission(array['inventory:view','inventory:manage','pos:sell','purchases:manage','sales:view','receipts:print','dashboard:view','customers:view']) end
$$;

-- Defense in depth: all newly authored routines have explicit paths/default-deny grants.
revoke all on function app_private.session_valid(uuid,uuid),app_private.session_id(),app_private.account_ready(uuid),
 app_private.is_superadmin(),app_private.is_owner(),app_private.manage_accounts(uuid),app_private.actor_can_manage(uuid,uuid,uuid),
 app_private.validate_permission_set(text[]),app_private.sync_profile_actor(),app_private.password_changed(),app_private.auth_email_changed(),app_private.auth_password_context()
 from public,anon,authenticated,service_role;

-- Match the established application ownership, including functions replaced in place.
do $$ declare r record;begin
 for r in select c.oid::regclass tbl from pg_class c join pg_namespace n on n.oid=c.relnamespace
 where n.nspname='app_private' and c.relname in ('platform_superadmins','platform_bootstrap','account_security','admin_workspace_sessions','tenant_actors','user_permission_sets','access_audit','account_operations') loop
  execute format('alter table %s owner to postgres',r.tbl);
 end loop;
 for r in select p.oid::regprocedure fn from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname in ('public','app_private') and p.proowner=(select oid from pg_roles where rolname=current_user)
 and p.proname in ('session_valid','session_id','account_ready','is_superadmin','is_owner','manage_accounts','actor_can_manage','validate_permission_set',
 'sync_profile_actor','password_changed','auth_email_changed','auth_password_context','get_access_context','set_admin_workspace','get_permission_catalog','get_business_users','manage_business_user',
 'set_business_status','get_platform_businesses','get_platform_dashboard','get_platform_storage','get_access_audit','prepare_account_operation','complete_account_operation','bootstrap_platform_superadmin','platform_bootstrap_available','prepare_own_password_change') loop
  execute format('alter function %s owner to postgres',r.fn);
 end loop;
end $$;

