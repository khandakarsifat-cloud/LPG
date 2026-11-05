-- Calendar dates are canonical. Archive obsolete boundaries and projections
-- before regrouping maintained endpoints; retain raw punches and correction audit.
lock table public.attendance_settings,public.attendance_cutoff_rules,public.attendance_days,public.attendance_adjustments in share row exclusive mode;
create temporary table calendar_original_days on commit drop as select * from public.attendance_days;
insert into public.attendance_configuration_audit(tenant_id,details)
select t.tenant_id,jsonb_build_object('normalization','Calendar attendance dates; previous day boundaries retired',
 'settings',(select to_jsonb(s) from public.attendance_settings s where s.tenant_id=t.tenant_id),
 'rules',coalesce((select jsonb_agg(to_jsonb(r)) from public.attendance_cutoff_rules r where r.tenant_id=t.tenant_id),'[]'),
 'days',coalesce((select jsonb_agg(to_jsonb(d)) from calendar_original_days d where d.tenant_id=t.tenant_id),'[]'))
from public.tenants t where exists(select 1 from public.attendance_settings s where s.tenant_id=t.tenant_id);
-- A cross-date manual correction must never be silently split or reattributed.
-- This guard is checked on the disposable clone before deployment too.
do $$begin
 if exists(select 1 from public.attendance_adjustments a join public.attendance_days d using(tenant_id,employee_id,work_date)
 where (a.clock_in is not null and (a.clock_in at time zone d.timezone)::date<>a.work_date)
 or (a.clock_out is not null and (a.clock_out at time zone d.timezone)::date<>a.work_date)) then
 raise exception 'Cross-date manual attendance corrections require explicit reconciliation before calendar normalization';
 end if;
end $$;
create or replace function app_private.attendance_date(t uuid,instant timestamptz,zone text) returns date language sql stable set search_path='' as $$
 select (instant at time zone zone)::date
$$;
create or replace function app_private.attendance_departure(t uuid,d date,zone text) returns timestamptz language sql stable set search_path='' as $$
 select (d+coalesce((select clock_out_cutoff from public.attendance_cutoff_rules where tenant_id=t and effective_from<=d order by effective_from desc limit 1),'15:00'::time)) at time zone zone
$$;
create or replace function app_private.ensure_attendance_day(t uuid,eid uuid,d date) returns void language sql set search_path='' as $$
 insert into public.attendance_days(tenant_id,employee_id,work_date,timezone,starts_at,ends_at,clock_out_from)
 select t,eid,d,zone,d::timestamp at time zone zone,(d+1)::timestamp at time zone zone,app_private.attendance_departure(t,d,zone)
 from (select coalesce((select timezone from public.attendance_settings where tenant_id=t),'Asia/Dhaka') zone) q on conflict do nothing
$$;
-- Both reduced endpoints and old linked raw evidence are genuine inputs.
-- This includes uploads received after per-punch persistence was retired.
create temporary table calendar_source on commit drop as
select tenant_id,employee_id,timezone,instant from calendar_original_days d cross join lateral(values(d.first_at),(d.last_at)) v(instant) where instant is not null
union
select e.tenant_id,l.employee_id,coalesce(s.timezone,'Asia/Dhaka'),e.event_at
from public.attendance_events e join public.attendance_links l using(tenant_id,device_id,pin)
left join public.attendance_settings s on s.tenant_id=e.tenant_id
where not e.clock_warning and e.event_at>=l.linked_at and (l.unlinked_at is null or e.event_at<l.unlinked_at);
create temporary table calendar_reduced on commit drop as
select tenant_id,employee_id,timezone,(instant at time zone timezone)::date work_date,
 min(instant) filter(where instant<app_private.attendance_departure(tenant_id,(instant at time zone timezone)::date,timezone)) first_at,
 max(instant) filter(where instant>=app_private.attendance_departure(tenant_id,(instant at time zone timezone)::date,timezone)) last_at
from calendar_source group by tenant_id,employee_id,timezone,(instant at time zone timezone)::date;
insert into public.attendance_days(tenant_id,employee_id,work_date,timezone,starts_at,ends_at,clock_out_from,first_at,last_at,scan_count)
select tenant_id,employee_id,work_date,timezone,work_date::timestamp at time zone timezone,(work_date+1)::timestamp at time zone timezone,
 app_private.attendance_departure(tenant_id,work_date,timezone),first_at,last_at,(first_at is not null)::int+(last_at is not null)::int from calendar_reduced
on conflict(tenant_id,employee_id,work_date) do update set first_at=excluded.first_at,last_at=excluded.last_at,
 scan_count=excluded.scan_count,revision=attendance_days.revision+1,updated_at=clock_timestamp();
-- Remove only obsolete derived groupings. Immutable evidence remains archived.
delete from public.attendance_days d where not exists(select 1 from calendar_reduced r where r.tenant_id=d.tenant_id and r.employee_id=d.employee_id and r.work_date=d.work_date)
 and not exists(select 1 from public.attendance_adjustments a where a.tenant_id=d.tenant_id and a.employee_id=d.employee_id and a.work_date=d.work_date);
update public.attendance_days set starts_at=work_date::timestamp at time zone timezone,ends_at=(work_date+1)::timestamp at time zone timezone,
 clock_out_from=app_private.attendance_departure(tenant_id,work_date,timezone),revision=revision+1;
-- Correction windows are calendar dates too, even when no attendance row exists.
do $$declare definition text;begin
 select pg_get_functiondef('public.get_attendance_edit(uuid,date)'::regprocedure) into definition;
 definition:=replace(definition,'(p_day+app_private.attendance_boundary(t,p_day)) at time zone zone','p_day::timestamp at time zone zone');
 definition:=replace(definition,'(p_day+1+app_private.attendance_boundary(t,p_day+1)) at time zone zone','(p_day+1)::timestamp at time zone zone');
 execute definition;
 select pg_get_functiondef('app_private.initialize_business_catalogs()'::regprocedure) into definition;
 definition:=replace(definition,$target$insert into public.attendance_settings(tenant_id,cutoff) values(new.tenant_id,'00:00');$target$,'insert into public.attendance_settings(tenant_id) values(new.tenant_id);');
 execute definition;
 -- Raw legacy audit reads filter by actual punch date, without rewriting evidence.
 select pg_get_functiondef('public.get_employee_attendance_events(uuid,date,integer)'::regprocedure) into definition;
 definition:=replace(definition,'e.work_date=p_day',$target$(e.event_at at time zone coalesce((select timezone from public.attendance_settings where tenant_id=t),'Asia/Dhaka'))::date=p_day$target$);
 execute definition;
end $$;
create or replace function public.get_attendance_configuration() returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['employees:view','employees:manage','settings:manage']);zone text;today date;
begin
 select coalesce((select timezone from public.attendance_settings where tenant_id=t),'Asia/Dhaka') into zone;
 today:=app_private.attendance_date(t,now(),zone);
 return jsonb_build_object('timezone',zone,'today',today,
 'clock_out_cutoff',coalesce((select clock_out_cutoff from public.attendance_cutoff_rules where tenant_id=t and effective_from<=today order by effective_from desc limit 1),'15:00'::time),
 'next_clock_out_cutoff',coalesce((select clock_out_cutoff from public.attendance_settings where tenant_id=t),'15:00'::time),
 'can_correct',app_private.has_any_permission(array['employees:manage']) and app_private.has_permission('attendance:manage'),
 'devices',coalesce((select jsonb_agg(jsonb_build_object('device_id',d.device_id,'serial',d.serial,'name',d.name,'enabled',d.enabled,
 'approved',d.approved_at is not null,'registered_at',d.created_at,'last_ignored_count',d.last_ignored_count,
 'last_seen_at',d.last_seen_at,'last_upload_at',d.last_upload_at,'last_event_at',d.last_event_at,'last_batch_count',d.last_batch_count,
 'unmapped',(select count(*) from public.attendance_users u where u.tenant_id=t and u.device_id=d.device_id and not exists(
 select 1 from public.attendance_links l where l.tenant_id=t and l.device_id=d.device_id and l.pin=u.pin and l.unlinked_at is null))) order by d.name)
 from public.attendance_devices d where d.tenant_id=t and d.removed_at is null),'[]'));
end $$;

drop function public.save_attendance_configuration(text,time,time);
create function public.save_attendance_configuration(p_timezone text,p_clock_out_cutoff time) returns void language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('settings:manage');s public.attendance_settings;effective date;
begin
 if p_timezone is null or not exists(select 1 from pg_catalog.pg_timezone_names where name=p_timezone)
 or p_clock_out_cutoff is null or p_clock_out_cutoff<='00:00'::time or p_clock_out_cutoff>='24:00'::time or extract(second from p_clock_out_cutoff)<>0 then
 raise exception 'Select a valid timezone and clock-out cutoff after midnight';end if;
 insert into public.attendance_settings(tenant_id) values(t) on conflict do nothing;
 select * into s from public.attendance_settings where tenant_id=t for update;
 if p_timezone<>s.timezone and (exists(select 1 from public.attendance_events where tenant_id=t) or exists(select 1 from public.attendance_days where tenant_id=t)) then
 raise exception 'Timezone is fixed after attendance starts to preserve history';end if;
 effective:=(clock_timestamp() at time zone p_timezone)::date+1;
 update public.attendance_settings set timezone=p_timezone,clock_out_cutoff=p_clock_out_cutoff,updated_at=clock_timestamp() where tenant_id=t;
 insert into public.attendance_cutoff_rules(tenant_id,effective_from,clock_out_cutoff) values(t,effective,p_clock_out_cutoff)
 on conflict(tenant_id,effective_from) do update set clock_out_cutoff=excluded.clock_out_cutoff;
 insert into public.attendance_configuration_audit(tenant_id,details,created_by)
 values(t,jsonb_build_object('before',to_jsonb(s),'timezone',p_timezone,'clock_out_cutoff',p_clock_out_cutoff,'effective_from',effective),auth.uid());
end $$;
revoke all on function public.save_attendance_configuration(text,time) from public,anon;
grant execute on function public.save_attendance_configuration(text,time) to authenticated;
-- Calendar correction times must belong to the selected date. The next midnight
-- belongs to the following date and is not selectable as this date's departure.
do $$declare definition text;begin
 select pg_get_functiondef('public.correct_employee_attendance(uuid,date,text,text,text,bigint,uuid)'::regprocedure) into definition;
 definition:=replace(definition,'cout>d.ends_at','cout>=d.ends_at');execute definition;
end $$;
alter table public.attendance_settings drop column cutoff;
alter table public.attendance_cutoff_rules drop column cutoff;
drop function app_private.attendance_boundary(uuid,date);
