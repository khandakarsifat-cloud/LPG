-- Each row is a business registration; historical rows retain all foreign keys.
alter table public.attendance_devices drop constraint attendance_devices_serial_key;
create unique index attendance_devices_active_serial on public.attendance_devices(serial) where removed_at is null;
-- Existing registrations predate this boundary contract. Preserve their accepted
-- history and delayed uploads; every subsequent registration starts at DB time.
alter table public.attendance_devices add column accept_events_from timestamptz not null default '-infinity';
alter table public.attendance_devices alter column accept_events_from set default clock_timestamp();
alter table public.attendance_devices add column last_ignored_count integer not null default 0 check(last_ignored_count>=0);
comment on column public.attendance_devices.accept_events_from is 'Inclusive punch-time boundary for this registration; existing pre-migration registrations are unbounded.';

create or replace function public.save_attendance_device(p_device_id uuid,p_serial text,p_name text,p_action text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('settings:manage'); d public.attendance_devices; instant timestamptz;
begin
 if p_action not in ('register','edit','approve','disable','enable','remove') or p_action is null then raise exception 'Invalid device action'; end if;
 if p_action='register' then
  if exists(select 1 from public.attendance_devices where serial=trim(p_serial) and removed_at is null) then
   raise exception 'This serial is already registered. Remove its current registration before adding it again.';
  end if;
  instant:=clock_timestamp();
  begin
   insert into public.attendance_devices(tenant_id,serial,name,enabled,created_at,accept_events_from)
   values(t,trim(p_serial),trim(p_name),false,instant,instant) returning * into d;
  exception when unique_violation then
   raise exception 'This serial is already registered. Remove its current registration before adding it again.';
  end;
 else
  select * into d from public.attendance_devices where tenant_id=t and device_id=p_device_id and removed_at is null for update;
  if not found then raise exception 'Device not found'; end if;
  instant:=clock_timestamp();
  update public.attendance_devices set name=case when p_action='edit' then trim(p_name) else name end,
   approved_at=case when p_action='approve' then instant else approved_at end,
   enabled=case when p_action in ('approve','enable') then true when p_action in ('disable','remove') then false else enabled end,
   removed_at=case when p_action='remove' then instant else removed_at end
  where tenant_id=t and device_id=d.device_id;
  if p_action='remove' then
   update public.attendance_links set unlinked_at=instant,unlinked_by=auth.uid() where tenant_id=t and device_id=d.device_id and unlinked_at is null;
  end if;
 end if;
 insert into public.attendance_device_audit(tenant_id,device_id,action,created_by) values(t,d.device_id,p_action,auth.uid());
 return jsonb_build_object('device_id',d.device_id);
end $$;

create or replace function public.attendance_receive(p_serial text,p_action text,p_records jsonb,p_stamp text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.attendance_devices;s public.attendance_settings;r jsonb;dt timestamp;instant timestamptz;day date;
 warning boolean;inserted integer;total integer:=0;ignored integer:=0;latest timestamptz;eid uuid;affected jsonb:='[]';pair jsonb;
begin
 select * into d from public.attendance_devices where serial=p_serial and enabled and approved_at is not null and removed_at is null
 for update;
 if not found then raise insufficient_privilege using message='Unauthorized device'; end if;
 if p_action not in ('heartbeat','upload') or p_action is null or jsonb_typeof(p_records) is distinct from 'array'
 or jsonb_array_length(p_records)>2000 or (p_action='heartbeat' and jsonb_array_length(p_records)>0) then raise exception 'Invalid device operation'; end if;
 insert into public.attendance_settings(tenant_id) values(d.tenant_id) on conflict do nothing;
 select * into s from public.attendance_settings where tenant_id=d.tenant_id for share;
 if p_stamp is not null and p_stamp !~ '^[A-Za-z0-9_:.-]{1,64}$' then raise exception 'Invalid device stamp'; end if;
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
  insert into public.attendance_events(tenant_id,device_id,event_key,pin,device_time,event_at,work_date,status,verification,workcode,clock_warning)
  values(d.tenant_id,d.device_id,r->>'key',r->>'pin',dt,instant,day,r->>'status',r->>'verify',r->>'workcode',warning) on conflict do nothing;
  get diagnostics inserted=row_count;
  if inserted=1 then
   total:=total+1;
   select employee_id into eid from public.attendance_links where tenant_id=d.tenant_id and device_id=d.device_id and pin=r->>'pin'
   and linked_at<=instant and (unlinked_at is null or instant<unlinked_at);
   if eid is not null then affected:=affected||jsonb_build_array(jsonb_build_object('employee',eid,'day',day)); end if;
  end if;
 end loop;
 -- Ordered employee/day locks avoid cross-device upload deadlocks. Recalculate
 -- affected indexed ranges once per packet, including delayed offline punches.
 for pair in select distinct value from jsonb_array_elements(affected) order by value loop
  eid:=(pair->>'employee')::uuid;day:=(pair->>'day')::date;
  perform app_private.ensure_attendance_day(d.tenant_id,eid,day);
  perform 1 from public.attendance_days where tenant_id=d.tenant_id and employee_id=eid and work_date=day for update;
  update public.attendance_days a set first_at=q.first_at,last_at=q.last_at,scan_count=q.scans,warning_count=q.warnings,revision=revision+1,updated_at=clock_timestamp()
  from (select min(e.event_at) filter(where not e.clock_warning) first_at,max(e.event_at) filter(where not e.clock_warning) last_at,
   count(*) filter(where not e.clock_warning)::integer scans,count(*) filter(where e.clock_warning)::integer warnings
   from public.attendance_links l join public.attendance_events e using(tenant_id,device_id,pin)
   where l.tenant_id=d.tenant_id and l.employee_id=eid and e.work_date=day and e.event_at>=l.linked_at and (l.unlinked_at is null or e.event_at<l.unlinked_at)) q
  where a.tenant_id=d.tenant_id and a.employee_id=eid and a.work_date=day;
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
 'next_cutoff',coalesce((select cutoff from public.attendance_settings where tenant_id=t),'00:00'::time),'can_correct',app_private.has_any_permission(array['employees:manage']) and app_private.has_permission('attendance:manage'),
 'devices',coalesce((select jsonb_agg(jsonb_build_object('device_id',d.device_id,'serial',d.serial,'name',d.name,'enabled',d.enabled,
 'approved',d.approved_at is not null,'registered_at',d.created_at,'last_ignored_count',d.last_ignored_count,
 'last_seen_at',d.last_seen_at,'last_upload_at',d.last_upload_at,'last_event_at',d.last_event_at,'last_batch_count',d.last_batch_count,
 'unmapped',(select count(*) from public.attendance_users u where u.tenant_id=t and u.device_id=d.device_id and not exists(
 select 1 from public.attendance_links l where l.tenant_id=t and l.device_id=d.device_id and l.pin=u.pin and l.unlinked_at is null))) order by d.name)
 from public.attendance_devices d where d.tenant_id=t and d.removed_at is null),'[]'));
end $$;

