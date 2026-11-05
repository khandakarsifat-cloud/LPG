-- Explicitly authorized development reset. Invoke only after a verified full
-- recovery point, with services quiesced, through the scoped maintenance tool.
begin;
do $$begin
 if current_database() !~ '^lpg_core_(rehearsal|acceptance)_[0-9a-f]{12}$'
 and (current_database()<>'postgres' or coalesce(current_setting('lpg.authorized_development_reset',true),'') !~ '^[0-9a-f]{64}$') then
  raise exception 'Refusing reset outside an owned disposable clone or verified primary maintenance session';
 end if;
end$$;
create temp table reset_admin_evidence as
select u.id,md5(u.id::text||u.email||u.encrypted_password||u.raw_app_meta_data::text||u.role||u.aud) fingerprint,
 to_jsonb(a) authority,to_jsonb(s) security
from auth.users u join app_private.platform_superadmins a on a.user_id=u.id
left join app_private.account_security s on s.user_id=u.id;
do $$begin if not exists(select 1 from reset_admin_evidence) then raise exception 'No preserved platform administrator';end if;end$$;
create temp table reset_tenants as select tenant_id from public.tenants;
create temp table reset_business_actors as
select distinct user_id from (select user_id from public.user_profiles union select user_id from app_private.tenant_actors) u;
create temp table reset_users as
select user_id from reset_business_actors u
where not exists(select 1 from reset_admin_evidence a where a.id=u.user_id)
 and not exists(select 1 from auth.users a where a.id=u.user_id and a.email='sifatsiam244@gmail.com');
set local session_replication_role=replica;
do $$declare r record;begin
 for r in select n.nspname,c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
 where n.nspname in ('public','app_private') and c.relkind='r' and c.oid<>'public.tenants'::regclass
 and exists(select 1 from pg_attribute a where a.attrelid=c.oid and a.attname='tenant_id' and not a.attisdropped)
 loop execute format('delete from %I.%I where tenant_id in (select tenant_id from reset_tenants)',r.nspname,r.relname);end loop;
end$$;
-- Keep system audit snapshots; remove foreign keys to deleted business users.
update app_private.access_audit set details=details||jsonb_build_object('removed_target_user_id',target_user_id),target_user_id=null where target_user_id in(select user_id from reset_users);
update app_private.access_audit set details=details||jsonb_build_object('removed_actor_user_id',actor_id),actor_id=null where actor_id in(select user_id from reset_users);
delete from app_private.account_operations where actor_id in(select user_id from reset_users) or target_user_id in(select user_id from reset_users);
delete from storage.objects where split_part(name,'/',1) in(select tenant_id::text from reset_tenants) or owner_id in(select user_id::text from reset_business_actors);
delete from public.tenants where tenant_id in(select tenant_id from reset_tenants);
set local session_replication_role=origin;
-- Auth's own cascades remove only these business users' sessions/identities.
delete from auth.users where id in(select user_id from reset_users);
do $$begin
 if exists(select 1 from reset_admin_evidence p left join auth.users u on u.id=p.id
 left join app_private.platform_superadmins a on a.user_id=p.id
 left join app_private.account_security s on s.user_id=p.id
 where u.id is null or p.fingerprint is distinct from md5(u.id::text||u.email||u.encrypted_password||u.raw_app_meta_data::text||u.role||u.aud)
 or p.authority is distinct from to_jsonb(a) or p.security is distinct from to_jsonb(s)) then
 raise exception 'Administrator preservation check failed';end if;
 if exists(select 1 from public.tenants) then raise exception 'Business baseline is not empty';end if;
end$$;
-- Replication-trigger bypass is limited to the authorized business deletion.
-- Recheck all real foreign keys before committing the clean baseline.
do $$declare r record;joined text;nonnull text;broken boolean;begin
 for r in select c.*,c.conrelid::regclass child,c.confrelid::regclass parent from pg_constraint c
  join pg_namespace n on n.oid=c.connamespace where c.contype='f' and n.nspname not in ('pg_catalog','information_schema') loop
  select string_agg(format('p.%I=c.%I',pa.attname,ca.attname),' and ' order by k.ord),
   string_agg(format('c.%I is not null',ca.attname),' and ' order by k.ord) into joined,nonnull
  from unnest(r.conkey,r.confkey) with ordinality k(ck,pk,ord)
  join pg_attribute ca on ca.attrelid=r.conrelid and ca.attnum=k.ck
  join pg_attribute pa on pa.attrelid=r.confrelid and pa.attnum=k.pk;
  execute format('select exists(select 1 from %s c where %s and not exists(select 1 from %s p where %s))',r.child,nonnull,r.parent,joined) into broken;
  if broken then raise exception 'Reset left an invalid foreign key: % on %',r.conname,r.child;end if;
 end loop;
end$$;
select jsonb_build_object('businesses_removed',(select count(*) from reset_tenants),'business_users_removed',(select count(*) from reset_users),'administrators_preserved',(select count(*) from reset_admin_evidence));
commit;
