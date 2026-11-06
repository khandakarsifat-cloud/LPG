-- Private administrative lifecycle; no browser/service-role execution grants.
create table app_private.business_deletions(
 job_id uuid primary key,business_id uuid not null unique,business_name text not null,actor_id uuid not null,
 status text not null check(status in('prepared','backed_up','data_removed','completed')),
 backup_id text,manifest jsonb not null,created_at timestamptz not null default clock_timestamp(),completed_at timestamptz
);
revoke all on app_private.business_deletions from public,anon,authenticated,service_role;

create function app_private.business_purge_allowed(t uuid) returns boolean language sql stable security definer set search_path='' as $$
 select session_user in('postgres','supabase_admin') and exists(select 1 from app_private.business_deletions j
 where j.business_id=t and j.job_id::text=current_setting('lpg.business_deletion',true) and j.status<>'completed')
$$;
revoke all on function app_private.business_purge_allowed(uuid) from public,anon,authenticated,service_role;

create function app_private.guard_business_deletion() returns trigger language plpgsql security definer set search_path='' as $$
declare t uuid;begin
 t:=case when tg_op='DELETE' then old.tenant_id else new.tenant_id end;
 if app_private.business_purge_allowed(t) then if tg_op='DELETE' then return old;else return new;end if;end if;
 -- Serialize every tenant write against the administrative fence. A suspended
 -- business without a deletion job still supports ordinary platform management.
 if tg_table_name<>'tenants' then perform 1 from public.tenants where tenant_id=t for share;end if;
 if exists(select 1 from app_private.business_deletions where business_id=t) then
  raise insufficient_privilege using message='Business deletion has started. Business writes are blocked.';
 end if;
 if tg_op='UPDATE' and old.tenant_id is distinct from new.tenant_id and exists(select 1 from app_private.business_deletions where business_id=old.tenant_id) then raise insufficient_privilege;end if;
 if tg_op='DELETE' then return old;else return new;end if;
end $$;
revoke all on function app_private.guard_business_deletion() from public,anon,authenticated,service_role;

do $$declare r record;s text;begin
 -- Permit only the exact root-authorized tenant purge through immutable DELETE
 -- guards. Constraints and every ordinary source-write guard remain enabled.
 for r in select distinct p.oid from pg_trigger tr join pg_proc p on p.oid=tr.tgfoid join pg_class c on c.oid=tr.tgrelid join pg_namespace n on n.oid=c.relnamespace
 where not tr.tgisinternal and tr.tgtype::int&8=8 and n.nspname in('public','app_private')
 and exists(select 1 from pg_attribute a where a.attrelid=c.oid and a.attname='tenant_id') loop
  s:=pg_get_functiondef(r.oid);
  s:=regexp_replace(s,'\mBEGIN\M', $guard$BEGIN
   if tg_op='DELETE' then if app_private.business_purge_allowed(old.tenant_id) then return old;end if;end if;
  $guard$,'i');execute s;
 end loop;
 for r in select n.nspname,c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace join pg_attribute a on a.attrelid=c.oid and a.attname='tenant_id'
 where c.relkind='r' and n.nspname in('public','app_private') loop
  execute format('create trigger a_business_deletion_guard before insert or update or delete on %I.%I for each row execute function app_private.guard_business_deletion()',r.nspname,r.relname);
 end loop;
end $$;

create function app_private.business_deletion_preview(t uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare r record;n bigint;counts jsonb:='{}';files jsonb;users uuid[];keep uuid[]:='{}';u uuid;other_ref boolean;business_label text;begin
 if session_user not in('postgres','supabase_admin') then raise insufficient_privilege;end if;
 select business_name into business_label from public.tenants where tenant_id=t;if not found then raise exception 'Business not found';end if;
 for r in select n.nspname,c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace join pg_attribute a on a.attrelid=c.oid and a.attname='tenant_id'
 where c.relkind='r' and n.nspname in('public','app_private') and c.oid<>'public.tenants'::regclass order by 1,2 loop
  if not exists(select 1 from pg_trigger tr where tr.tgrelid=format('%I.%I',r.nspname,r.relname)::regclass and tr.tgname='a_business_deletion_guard' and tr.tgenabled='O') then raise exception 'Tenant write fence missing on %.%',r.nspname,r.relname;end if;
  execute format('select count(*) from %I.%I where tenant_id=$1',r.nspname,r.relname) into n using t;
  if n>0 then counts:=counts||jsonb_build_object(r.nspname||'.'||r.relname,n);end if;
 end loop;
 select coalesce(array_agg(distinct user_id),'{}') into users from(select user_id from public.user_profiles where tenant_id=t union select user_id from app_private.tenant_actors where tenant_id=t) x;
 foreach u in array users loop
  -- Preserve platform identities and any identity still referenced outside this
  -- tenant. Foreign keys are inspected rather than guessing a shared account.
  if exists(select 1 from app_private.platform_superadmins where user_id=u) or exists(select 1 from auth.users where id=u and lower(email)='sifatsiam244@gmail.com') then keep:=array_append(keep,u);continue;end if;
  for r in select c.conrelid::regclass tab,a.attname col,exists(select 1 from pg_attribute ta where ta.attrelid=c.conrelid and ta.attname='tenant_id' and not ta.attisdropped) tenant_scoped
   from pg_constraint c join pg_namespace ns on ns.oid=c.connamespace cross join lateral unnest(c.conkey) k
   join pg_attribute a on a.attrelid=c.conrelid and a.attnum=k
   where c.contype='f' and c.confrelid='auth.users'::regclass and ns.nspname in('public','app_private')
   and c.conrelid<>'app_private.account_security'::regclass loop
   if r.tenant_scoped then execute format('select exists(select 1 from %s where %I=$1 and tenant_id is distinct from $2)',r.tab,r.col) into other_ref using u,t;
   else execute format('select exists(select 1 from %s where %I=$1)',r.tab,r.col) into other_ref using u;end if;
   if other_ref then keep:=array_append(keep,u);exit;end if;
  end loop;
 end loop;
 -- Storage ownership alone is insufficient: delete only the canonical tenant
 -- prefix. Unexpected references fail closed in the worker before destruction.
 select coalesce(jsonb_agg(jsonb_build_object('bucket',bucket_id,'name',name,'owner',owner_id)),'[]') into files
 from storage.objects where split_part(name,'/',1)=t::text or owner_id=any(array(select x::text from unnest(users)x where not(x=any(keep))));
 return jsonb_build_object('business_id',t,'business_name',business_label,'tables',counts,'files',files,
  'users',to_jsonb(array(select x from unnest(users)x where not(x=any(keep)))),'preserved_users',to_jsonb(keep));
end $$;

create function app_private.guard_deleting_business_files() returns trigger language plpgsql security definer set search_path='' as $$
declare t uuid;old_prefix text;begin
 if tg_op='UPDATE' then old_prefix:=split_part(old.name,'/',1);end if;
 for t in select tenant_id from public.tenants where tenant_id::text in(split_part(new.name,'/',1),old_prefix)
  or tenant_id in(select tenant_id from public.user_profiles where user_id::text=new.owner_id) order by tenant_id loop
  perform 1 from public.tenants where tenant_id=t for share;
  if exists(select 1 from app_private.business_deletions where business_id=t) then raise insufficient_privilege using message='Business deletion blocks file changes';end if;
 end loop;
 return new;
end $$;
revoke all on function app_private.guard_deleting_business_files() from public,anon,authenticated,service_role;
create trigger a_business_deletion_guard before insert or update on storage.objects for each row execute function app_private.guard_deleting_business_files();

create function app_private.prepare_business_deletion(t uuid,j uuid,actor uuid,expected_name text) returns jsonb language plpgsql security definer set search_path='' as $$
declare prior app_private.business_deletions;name text;m jsonb;begin
 if session_user not in('postgres','supabase_admin') or not exists(select 1 from app_private.platform_superadmins where user_id=actor and is_active) then raise insufficient_privilege;end if;
 perform pg_advisory_xact_lock(hashtextextended('business-deletion:'||t::text,0));
 select * into prior from app_private.business_deletions where business_id=t;
 if found then if prior.job_id<>j or prior.actor_id<>actor then raise exception 'Business already has a deletion job';end if;return to_jsonb(prior);end if;
 select business_name into name from public.tenants where tenant_id=t for update;
 if not found or name is distinct from expected_name then raise exception 'Business identity changed; review again';end if;
 m:=app_private.business_deletion_preview(t);
 insert into app_private.business_deletions(job_id,business_id,business_name,actor_id,status,manifest) values(j,t,name,actor,'prepared',m);
 perform set_config('lpg.business_deletion',j::text,true);
 update public.tenants set status='suspended' where tenant_id=t;
 delete from auth.sessions where user_id in(select user_id from public.user_profiles where tenant_id=t) and user_id not in(select user_id from app_private.platform_superadmins);
 delete from app_private.admin_workspace_sessions where tenant_id=t;
 return (select to_jsonb(x) from app_private.business_deletions x where job_id=j);
end $$;

create function app_private.purge_business_data(j uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare job app_private.business_deletions;todo oid[];tab oid;r record;n bigint;begin
 if session_user not in('postgres','supabase_admin') then raise insufficient_privilege;end if;
 select * into job from app_private.business_deletions where job_id=j for update;
 if not found or job.status='prepared' or job.backup_id is null then raise exception 'Verified fresh backup required';end if;
 if job.status in('data_removed','completed') then return to_jsonb(job);end if;
 if exists(select 1 from storage.objects where split_part(name,'/',1)=job.business_id::text or owner_id in(select jsonb_array_elements_text(job.manifest->'users'))) then raise exception 'Remove business files through Storage before deleting records';end if;
 perform set_config('lpg.business_deletion',j::text,true);
 select array_agg(c.oid order by c.oid) into todo from pg_class c join pg_namespace n on n.oid=c.relnamespace join pg_attribute a on a.attrelid=c.oid and a.attname='tenant_id'
 where c.relkind='r' and n.nspname in('public','app_private') and c.oid<>'public.tenants'::regclass;
 -- Child-first DELETE keeps every FK active, including self references. A new
 -- cross-table cycle fails closed instead of disabling database integrity.
 while cardinality(todo)>0 loop
  select x into tab from unnest(todo)x where not exists(select 1 from pg_constraint c where c.contype='f' and c.confrelid=x and c.conrelid=any(todo) and c.conrelid<>x) order by x limit 1;
  if tab is null then raise exception 'Tenant deletion dependency cycle requires review';end if;
  execute format('delete from %s where tenant_id=$1',tab::regclass) using job.business_id;
  todo:=array_remove(todo,tab);
 end loop;
 delete from public.tenants where tenant_id=job.business_id;
 update app_private.business_deletions set status='data_removed' where job_id=j;
 return (select to_jsonb(x) from app_private.business_deletions x where job_id=j);
end $$;

do $$declare r record;begin
 for r in select oid::regprocedure sig from pg_proc where pronamespace='app_private'::regnamespace and proname in('business_deletion_preview','prepare_business_deletion','purge_business_data') loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role',r.sig);
 end loop;
end $$;
