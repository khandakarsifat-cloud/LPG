-- Independent attendance-day boundary and departure phase. Existing raw evidence
-- stays immutable; subsequent linked punches reduce directly into one daily row.
alter table public.attendance_settings add column clock_out_cutoff time not null default '15:00';
alter table public.attendance_cutoff_rules add column clock_out_cutoff time not null default '15:00';
alter table public.attendance_days add column clock_out_from timestamptz;
create function app_private.attendance_departure(t uuid,d date,zone text) returns timestamptz language sql stable set search_path='' as $$
 select (d+case when threshold<=app_private.attendance_boundary(t,d) then 1 else 0 end+threshold) at time zone zone
 from (select coalesce((select clock_out_cutoff from public.attendance_cutoff_rules where tenant_id=t and effective_from<=d order by effective_from desc limit 1),'15:00'::time) threshold) q
$$;
alter function app_private.attendance_departure(uuid,date,text) owner to postgres;
revoke all on function app_private.attendance_departure(uuid,date,text) from public,anon,authenticated;
update public.attendance_days set clock_out_from=app_private.attendance_departure(tenant_id,work_date,timezone);
alter table public.attendance_days alter column clock_out_from set not null;
create or replace function app_private.ensure_attendance_day(t uuid,eid uuid,d date) returns void language sql set search_path='' as $$
 insert into public.attendance_days(tenant_id,employee_id,work_date,timezone,starts_at,ends_at,clock_out_from)
 select t,eid,d,zone,(d+app_private.attendance_boundary(t,d)) at time zone zone,
 (d+1+app_private.attendance_boundary(t,d+1)) at time zone zone,app_private.attendance_departure(t,d,zone)
 from (select coalesce((select timezone from public.attendance_settings where tenant_id=t),'Asia/Dhaka') zone) q on conflict do nothing
$$;

create or replace function app_private.attendance_rows(t uuid,eid uuid,from_day date,to_day date)
returns table(employee_id uuid,work_date date,timezone text,clock_in timestamptz,clock_out timestamptz,
 worked_seconds bigint,scan_count integer,warning_count integer,automatic_close boolean,manual boolean,revision bigint,
 starts_at timestamptz,ends_at timestamptz,updated_at timestamptz)
language sql stable set search_path='' as $$
 select q.employee_id,q.work_date,q.timezone,q.cin,q.cout,
 case when q.cin is not null and q.cout is not null then greatest(0,extract(epoch from q.cout-q.cin))::bigint else 0 end,
 q.scan_count,q.warning_count,q.auto,q.is_manual,q.revision,q.starts_at,q.ends_at,q.updated_at
 from (select d.*,
 case when a.adjustment_id is not null then a.clock_in else d.first_at end cin,
 case when a.adjustment_id is not null then a.clock_out
 else d.last_at end cout,
 false auto,
 a.adjustment_id is not null is_manual
 from public.attendance_days d left join lateral(select * from public.attendance_adjustments a
 where a.tenant_id=t and a.employee_id=d.employee_id and a.work_date=d.work_date order by a.created_at desc,a.adjustment_id desc limit 1) a on true
 where d.tenant_id=t and (eid is null or d.employee_id=eid) and (from_day is null or d.work_date>=from_day) and (to_day is null or d.work_date<=to_day)) q
$$;

-- Normalize derived arrivals/departures from retained evidence; no source event
-- or manual adjustment is removed or rewritten.
update public.attendance_days d set first_at=q.arrival,last_at=q.departure,
 scan_count=(q.arrival is not null)::int+(q.departure is not null)::int,revision=revision+1
from (select a.tenant_id,a.employee_id,a.work_date,
 min(e.event_at) filter(where not e.clock_warning and e.event_at<a.clock_out_from) arrival,
 max(e.event_at) filter(where not e.clock_warning and e.event_at>=a.clock_out_from) departure
 from public.attendance_days a left join public.attendance_links l on l.tenant_id=a.tenant_id and l.employee_id=a.employee_id
 left join public.attendance_events e on e.tenant_id=l.tenant_id and e.device_id=l.device_id and e.pin=l.pin
 and e.event_at>=l.linked_at and (l.unlinked_at is null or e.event_at<l.unlinked_at)
 and e.event_at>=a.starts_at and e.event_at<a.ends_at
 group by a.tenant_id,a.employee_id,a.work_date) q
where d.tenant_id=q.tenant_id and d.employee_id=q.employee_id and d.work_date=q.work_date;
create or replace function public.attendance_receive(p_serial text,p_action text,p_records jsonb,p_stamp text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.attendance_devices;s public.attendance_settings;r jsonb;dt timestamp;instant timestamptz;day date;
 warning boolean;inserted integer;total integer:=0;ignored integer:=0;latest timestamptz;eid uuid; a public.attendance_days; cin timestamptz;cout timestamptz;
begin
 select * into d from public.attendance_devices where serial=p_serial and enabled and approved_at is not null and removed_at is null
 for update;
 if not found then raise insufficient_privilege using message='Unauthorized device'; end if;
 if p_action not in ('heartbeat','upload') or p_action is null or jsonb_typeof(p_records) is distinct from 'array'
 or jsonb_array_length(p_records)>2000 or (p_action='heartbeat' and jsonb_array_length(p_records)>0) then raise exception 'Invalid device operation'; end if;
 insert into public.attendance_settings(tenant_id) values(d.tenant_id) on conflict do nothing;
 select * into s from public.attendance_settings where tenant_id=d.tenant_id for share;
 if p_stamp is not null and p_stamp !~ '^[A-Za-z0-9_:.-]{1,64}$' then raise exception 'Invalid device stamp'; end if;
 -- Serialize packet reduction within a tenant; device lock remains first.
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('attendance:'||d.tenant_id::text,0));
 for r in select value from jsonb_array_elements(p_records) loop
  if coalesce(r->>'pin','') !~ '^[A-Za-z0-9_-]{1,24}$' or coalesce(r->>'key','') !~ '^[a-f0-9]{64}$'
  or coalesce(r->>'timestamp','') !~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
  or coalesce(r->>'status','') !~ '^[A-Za-z0-9_.-]{1,24}$' or coalesce(r->>'verify','') !~ '^[A-Za-z0-9_.-]{1,24}$'
  or coalesce(r->>'workcode','') !~ '^[A-Za-z0-9_.-]{1,24}$' then raise exception 'Invalid device record'; end if;
  dt:=(r->>'timestamp')::timestamp;
  if dt<'2000-01-01' or dt>='2101-01-01' then raise exception 'Device date outside supported range'; end if;
  instant:=dt at time zone s.timezone;
  -- ACK stale machine backlog without importing another registration's users
  -- or evidence. Stamp advances only if this entire transaction commits.
  if instant<d.accept_events_from then ignored:=ignored+1;continue;end if;
  latest:=greatest(latest,instant);
  day:=app_private.attendance_date(d.tenant_id,instant,s.timezone);
  warning:=instant>now()+interval '10 minutes';
  insert into public.attendance_users(tenant_id,device_id,pin) values(d.tenant_id,d.device_id,r->>'pin')
  on conflict(tenant_id,device_id,pin) do update set last_seen_at=now();
  -- Unknown enrollments are discoverable, but punches before an employee's
  -- effective link never become that employee's attendance.
  select employee_id into eid from public.attendance_links where tenant_id=d.tenant_id and device_id=d.device_id and pin=r->>'pin'
   and linked_at<=instant and (unlinked_at is null or instant<unlinked_at);
  if eid is null or warning then continue;end if;
  perform app_private.ensure_attendance_day(d.tenant_id,eid,day);
  select * into a from public.attendance_days where tenant_id=d.tenant_id and employee_id=eid and work_date=day for update;
  cin:=a.first_at;cout:=a.last_at;
  if instant<a.clock_out_from then cin:=least(cin,instant);else cout:=greatest(cout,instant);end if;
  if cin is distinct from a.first_at or cout is distinct from a.last_at then
   update public.attendance_days set first_at=cin,last_at=cout,
    scan_count=(cin is not null)::int+(cout is not null)::int,revision=revision+1,updated_at=clock_timestamp()
    where tenant_id=d.tenant_id and employee_id=eid and work_date=day;
   total:=total+1;
  end if;
 end loop;
 update public.attendance_devices set last_seen_at=now(),last_upload_at=case when p_action='upload' then now() else last_upload_at end,
 last_batch_count=case when p_action='upload' then jsonb_array_length(p_records) else last_batch_count end,
 last_ignored_count=case when p_action='upload' then ignored else last_ignored_count end,
 last_event_at=greatest(last_event_at,latest),
 stamp=case when p_action='upload' then coalesce(p_stamp,stamp) else stamp end where tenant_id=d.tenant_id and device_id=d.device_id;
 return jsonb_build_object('stamp',coalesce(p_stamp,d.stamp),'inserted',total,'ignored_before_registration',ignored,'timezone',
 extract(epoch from ((now() at time zone s.timezone)-(now() at time zone 'UTC')))::integer/3600);
end $$;
revoke all on function public.attendance_receive(text,text,jsonb,text) from public,anon,authenticated,service_role;
grant execute on function public.attendance_receive(text,text,jsonb,text) to attendance_receiver;

create or replace function public.get_attendance_configuration() returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['employees:view','employees:manage','settings:manage']);zone text;today date;
begin
 select coalesce((select timezone from public.attendance_settings where tenant_id=t),'Asia/Dhaka') into zone;
 today:=app_private.attendance_date(t,now(),zone);
 return jsonb_build_object('timezone',zone,'cutoff',app_private.attendance_boundary(t,today),'today',today,
 'clock_out_cutoff',coalesce((select clock_out_cutoff from public.attendance_cutoff_rules where tenant_id=t and effective_from<=today order by effective_from desc limit 1),'15:00'::time),
 'next_clock_out_cutoff',coalesce((select clock_out_cutoff from public.attendance_settings where tenant_id=t),'15:00'::time),
 'next_cutoff',coalesce((select cutoff from public.attendance_settings where tenant_id=t),'00:00'::time),'can_correct',app_private.has_any_permission(array['employees:manage']) and app_private.has_permission('attendance:manage'),
 'devices',coalesce((select jsonb_agg(jsonb_build_object('device_id',d.device_id,'serial',d.serial,'name',d.name,'enabled',d.enabled,
 'approved',d.approved_at is not null,'registered_at',d.created_at,'last_ignored_count',d.last_ignored_count,
 'last_seen_at',d.last_seen_at,'last_upload_at',d.last_upload_at,'last_event_at',d.last_event_at,'last_batch_count',d.last_batch_count,
 'unmapped',(select count(*) from public.attendance_users u where u.tenant_id=t and u.device_id=d.device_id and not exists(
 select 1 from public.attendance_links l where l.tenant_id=t and l.device_id=d.device_id and l.pin=u.pin and l.unlinked_at is null))) order by d.name)
 from public.attendance_devices d where d.tenant_id=t and d.removed_at is null),'[]'));
end $$;

drop function public.save_attendance_configuration(text,time);
create function public.save_attendance_configuration(p_timezone text,p_day_end time,p_clock_out_cutoff time) returns void language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('settings:manage');s public.attendance_settings;today date;effective date;
begin
 if p_timezone is null or p_timezone not like '%/%' and p_timezone<>'UTC' or not exists(select 1 from pg_catalog.pg_timezone_names where name=p_timezone)
 or p_clock_out_cutoff is null or extract(second from p_clock_out_cutoff)<>0 or p_clock_out_cutoff=p_day_end or p_clock_out_cutoff>='24:00'::time or p_day_end>='24:00'::time
 or p_day_end is null or extract(second from p_day_end)<>0 then raise exception 'Select a valid IANA timezone and cutoff'; end if;
 insert into public.attendance_settings(tenant_id) values(t) on conflict do nothing;
 select * into s from public.attendance_settings where tenant_id=t for update;
 if p_timezone<>s.timezone and (exists(select 1 from public.attendance_events where tenant_id=t) or exists(select 1 from public.attendance_days where tenant_id=t)) then raise exception 'Timezone is fixed after attendance starts to preserve history'; end if;
 today:=app_private.attendance_date(t,now(),p_timezone);
 effective:=today+1;
 if (effective+p_day_end) at time zone p_timezone<=clock_timestamp() then effective:=effective+1;end if;
 update public.attendance_settings set timezone=p_timezone,cutoff=p_day_end,clock_out_cutoff=p_clock_out_cutoff,updated_at=now() where tenant_id=t;
 insert into public.attendance_cutoff_rules(tenant_id,effective_from,cutoff,clock_out_cutoff) values(t,effective,p_day_end,p_clock_out_cutoff)
 on conflict(tenant_id,effective_from) do update set cutoff=excluded.cutoff,clock_out_cutoff=excluded.clock_out_cutoff;
 -- A changed future boundary is also the end of the still-open preceding
 -- workday. Keep adjacent intervals contiguous; completed days never change.
 update public.attendance_days d set
  starts_at=(d.work_date+app_private.attendance_boundary(t,d.work_date)) at time zone p_timezone,
  ends_at=(d.work_date+1+app_private.attendance_boundary(t,d.work_date+1)) at time zone p_timezone,
  clock_out_from=app_private.attendance_departure(t,d.work_date,p_timezone),
  revision=revision+1,updated_at=clock_timestamp()
 where d.tenant_id=t and d.work_date>=today and d.ends_at>now();
 insert into public.attendance_configuration_audit(tenant_id,details,created_by)
 values(t,jsonb_build_object('before',to_jsonb(s),'timezone',p_timezone,'day_end',p_day_end,'clock_out_cutoff',p_clock_out_cutoff,'effective_from',effective),auth.uid());
end $$;


revoke all on function public.save_attendance_configuration(text,time,time) from public,anon;
grant execute on function public.save_attendance_configuration(text,time,time) to authenticated;
