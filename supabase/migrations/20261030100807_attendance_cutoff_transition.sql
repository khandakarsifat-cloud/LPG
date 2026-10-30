-- Preserve completed days while future cutoff changes keep adjacent intervals contiguous.
create or replace function public.get_attendance_configuration() returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['employees:view','employees:manage','settings:manage']);zone text;today date;
begin
 select coalesce((select timezone from public.attendance_settings where tenant_id=t),'Asia/Dhaka') into zone;
 today:=app_private.attendance_date(t,now(),zone);
 return jsonb_build_object('timezone',zone,'cutoff',app_private.attendance_boundary(t,today),'today',today,
 'next_cutoff',coalesce((select cutoff from public.attendance_settings where tenant_id=t),'00:00'::time),'can_correct',app_private.has_any_permission(array['employees:manage']) and exists(
 select 1 from public.user_roles ur join public.roles r using(tenant_id,role_id) where ur.tenant_id=t and ur.user_id=auth.uid() and r.name in ('OWNER','MANAGER')),
 'devices',coalesce((select jsonb_agg(jsonb_build_object('device_id',d.device_id,'serial',d.serial,'name',d.name,'enabled',d.enabled,
 'approved',d.approved_at is not null,
 'last_seen_at',d.last_seen_at,'last_upload_at',d.last_upload_at,'last_event_at',d.last_event_at,'last_batch_count',d.last_batch_count,
 'unmapped',(select count(*) from public.attendance_users u where u.tenant_id=t and u.device_id=d.device_id and not exists(
 select 1 from public.attendance_links l where l.tenant_id=t and l.device_id=d.device_id and l.pin=u.pin and l.unlinked_at is null))) order by d.name)
 from public.attendance_devices d where d.tenant_id=t and d.removed_at is null),'[]'));
end $$;

create or replace function public.save_attendance_configuration(p_timezone text,p_cutoff time) returns void language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('settings:manage');s public.attendance_settings;today date;
begin
 if p_timezone is null or p_timezone not like '%/%' and p_timezone<>'UTC' or not exists(select 1 from pg_catalog.pg_timezone_names where name=p_timezone)
 or p_cutoff is null or extract(second from p_cutoff)<>0 then raise exception 'Select a valid IANA timezone and cutoff'; end if;
 insert into public.attendance_settings(tenant_id) values(t) on conflict do nothing;
 select * into s from public.attendance_settings where tenant_id=t for update;
 if p_timezone<>s.timezone and (exists(select 1 from public.attendance_events where tenant_id=t) or exists(select 1 from public.attendance_days where tenant_id=t)) then raise exception 'Timezone is fixed after attendance starts to preserve history'; end if;
 today:=(now() at time zone p_timezone)::date;
 update public.attendance_settings set timezone=p_timezone,cutoff=p_cutoff,updated_at=now() where tenant_id=t;
 insert into public.attendance_cutoff_rules(tenant_id,effective_from,cutoff) values(t,today+1,p_cutoff)
 on conflict(tenant_id,effective_from) do update set cutoff=excluded.cutoff;
 -- A changed future boundary is also the end of the still-open preceding
 -- workday. Keep adjacent intervals contiguous; completed days never change.
 update public.attendance_days d set
  starts_at=(d.work_date+app_private.attendance_boundary(t,d.work_date)) at time zone p_timezone,
  ends_at=(d.work_date+1+app_private.attendance_boundary(t,d.work_date+1)) at time zone p_timezone,
  revision=revision+1,updated_at=clock_timestamp()
 where d.tenant_id=t and d.work_date>=today and d.ends_at>now();
 insert into public.attendance_configuration_audit(tenant_id,details,created_by)
 values(t,jsonb_build_object('before',to_jsonb(s),'timezone',p_timezone,'cutoff',p_cutoff,'effective_from',today+1),auth.uid());
end $$;

