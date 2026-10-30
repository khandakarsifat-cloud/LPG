-- Device events are evidence, independent of employee payments and salaries.
create role attendance_receiver nologin noinherit;
grant attendance_receiver to authenticator;
grant usage on schema public to attendance_receiver;

create table public.attendance_settings (
 tenant_id uuid primary key references public.tenants(tenant_id) on delete cascade,
 timezone text not null default 'Asia/Dhaka',
 cutoff time not null default '15:00',
 updated_at timestamptz not null default now()
);
create table public.attendance_devices (
 tenant_id uuid not null references public.tenants(tenant_id) on delete cascade,
 device_id uuid not null default gen_random_uuid(),
 serial text not null unique check(serial ~ '^[A-Za-z0-9_-]{1,40}$'),
 name text not null check(length(trim(name)) between 1 and 80),
 allowed_ip inet not null check(masklen(allowed_ip)=case family(allowed_ip) when 4 then 32 else 128 end),
 enabled boolean not null default true,
 last_seen_at timestamptz, last_upload_at timestamptz, last_event_at timestamptz,
 stamp text not null default '0', last_batch_count integer not null default 0,
 created_at timestamptz not null default now(),
 primary key(tenant_id,device_id)
);
create table public.attendance_cutoff_rules (
 tenant_id uuid not null references public.tenants(tenant_id) on delete cascade,
 effective_from date not null, cutoff time not null,
 primary key(tenant_id,effective_from)
);
create table public.attendance_users (
 tenant_id uuid not null, device_id uuid not null,
 pin text not null check(pin ~ '^[A-Za-z0-9_-]{1,24}$'),
 employee_id uuid,
 first_seen_at timestamptz not null default now(), last_seen_at timestamptz not null default now(),
 primary key(tenant_id,device_id,pin),
 foreign key(tenant_id,device_id) references public.attendance_devices on delete cascade,
 foreign key(tenant_id,employee_id) references public.employees(tenant_id,employee_id),
 unique(tenant_id,device_id,employee_id)
);
create index attendance_employee_users on public.attendance_users(tenant_id,employee_id) where employee_id is not null;
create table public.attendance_events (
 tenant_id uuid not null, device_id uuid not null, event_key text not null check(event_key ~ '^[a-f0-9]{64}$'),
 pin text not null, device_time timestamp not null, event_at timestamptz not null, work_date date not null,
 status text not null, verification text not null, workcode text not null,
 clock_warning boolean not null, received_at timestamptz not null default now(),
 primary key(tenant_id,device_id,event_key),
 foreign key(tenant_id,device_id,pin) references public.attendance_users on delete cascade
);
create index attendance_event_history on public.attendance_events(tenant_id,device_id,pin,work_date,event_at,event_key);
create table public.attendance_days (
 tenant_id uuid not null, device_id uuid not null, pin text not null, work_date date not null,
 timezone text not null, cutoff time not null,
 first_at timestamptz, last_at timestamptz, last_after_cutoff timestamptz,
 scan_count integer not null default 0, warning_count integer not null default 0,
 updated_at timestamptz not null default now(),
 primary key(tenant_id,device_id,pin,work_date),
 foreign key(tenant_id,device_id,pin) references public.attendance_users on delete cascade
);
create index attendance_today on public.attendance_days(tenant_id,work_date,device_id,pin);

-- Browser reads use gated, bounded RPCs. No direct writes or raw receiver reads.
alter table public.attendance_settings enable row level security;
alter table public.attendance_devices enable row level security;
alter table public.attendance_users enable row level security;
alter table public.attendance_events enable row level security;
alter table public.attendance_days enable row level security;
alter table public.attendance_cutoff_rules enable row level security;
revoke all on public.attendance_settings,public.attendance_devices,public.attendance_users,public.attendance_events,public.attendance_days,public.attendance_cutoff_rules from public,anon,authenticated,attendance_receiver;

create function public.attendance_receive(p_serial text,p_source inet,p_action text,p_records jsonb,p_stamp text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.attendance_devices; s public.attendance_settings; r jsonb; dt timestamp; instant timestamptz; day date;
 warning boolean; inserted integer; total integer:=0;
begin
 -- The receiver role can invoke only this function; tenant is resolved from
 -- an explicitly registered serial + trusted Caddy peer address, never input.
 select * into d from public.attendance_devices where serial=p_serial and enabled and allowed_ip=p_source for update;
 if not found then raise insufficient_privilege using message='Unregistered device'; end if;
 if p_action not in ('heartbeat','upload') or p_action is null or jsonb_typeof(p_records) is distinct from 'array'
 or jsonb_array_length(p_records)>2000 then raise exception 'Invalid device operation'; end if;
 insert into public.attendance_settings(tenant_id) values(d.tenant_id) on conflict do nothing;
 select * into s from public.attendance_settings where tenant_id=d.tenant_id for share;
 if p_stamp is not null and p_stamp !~ '^[A-Za-z0-9_:.-]{1,64}$' then raise exception 'Invalid device stamp'; end if;
 for r in select value from jsonb_array_elements(p_records) loop
  if r->>'pin' is null or r->>'pin' !~ '^[A-Za-z0-9_-]{1,24}$' or r->>'key' is null or r->>'key' !~ '^[a-f0-9]{64}$'
  or r->>'timestamp' is null or r->>'timestamp' !~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
  or coalesce(r->>'status','') !~ '^[A-Za-z0-9_.-]{1,24}$' or coalesce(r->>'verify','') !~ '^[A-Za-z0-9_.-]{1,24}$'
  or coalesce(r->>'workcode','') !~ '^[A-Za-z0-9_.-]{1,24}$' then raise exception 'Invalid device record'; end if;
  dt:=(r->>'timestamp')::timestamp;
  if dt<'2000-01-01' or dt>='2101-01-01' then raise exception 'Device date outside supported range'; end if;
  instant:=dt at time zone s.timezone; day:=dt::date;
  warning:=instant>now()+interval '10 minutes';
  insert into public.attendance_users(tenant_id,device_id,pin) values(d.tenant_id,d.device_id,r->>'pin')
  on conflict(tenant_id,device_id,pin) do update set last_seen_at=now();
  insert into public.attendance_events(tenant_id,device_id,event_key,pin,device_time,event_at,work_date,status,verification,workcode,clock_warning)
  values(d.tenant_id,d.device_id,r->>'key',r->>'pin',dt,instant,day,r->>'status',r->>'verify',r->>'workcode',warning) on conflict do nothing;
  get diagnostics inserted=row_count;
  if inserted=1 then
   total:=total+1;
   insert into public.attendance_days(tenant_id,device_id,pin,work_date,timezone,cutoff)
   values(d.tenant_id,d.device_id,r->>'pin',day,s.timezone,coalesce((select cutoff from public.attendance_cutoff_rules where tenant_id=d.tenant_id and effective_from<=day order by effective_from desc limit 1),s.cutoff)) on conflict do nothing;
   update public.attendance_days set first_at=case when warning then first_at else least(first_at,instant) end,
    last_at=case when warning then last_at else greatest(last_at,instant) end,
    last_after_cutoff=case when not warning and dt::time>=cutoff then greatest(last_after_cutoff,instant) else last_after_cutoff end,
    scan_count=scan_count+case when warning then 0 else 1 end,warning_count=warning_count+case when warning then 1 else 0 end,updated_at=now()
    where tenant_id=d.tenant_id and device_id=d.device_id and pin=r->>'pin' and work_date=day;
  end if;
 end loop;
 update public.attendance_devices set last_seen_at=now(),last_upload_at=case when p_action='upload' then now() else last_upload_at end,
  last_batch_count=case when p_action='upload' then jsonb_array_length(p_records) else last_batch_count end,
  last_event_at=greatest(last_event_at,(select max((x->>'timestamp')::timestamp at time zone s.timezone) from jsonb_array_elements(p_records) x)),
  stamp=case when p_action='upload' then coalesce(p_stamp,stamp) else stamp end
  where tenant_id=d.tenant_id and device_id=d.device_id;
 return jsonb_build_object('stamp',coalesce(p_stamp,d.stamp),'inserted',total,'timezone',
  case when mod(extract(epoch from ((now() at time zone s.timezone)-(now() at time zone 'UTC')))::integer,3600)=0
   then extract(epoch from ((now() at time zone s.timezone)-(now() at time zone 'UTC')))::integer/3600
   else extract(epoch from ((now() at time zone s.timezone)-(now() at time zone 'UTC')))::integer/60 end);
end $$;
revoke all on function public.attendance_receive(text,inet,text,jsonb,text) from public,anon,authenticated,service_role;
grant execute on function public.attendance_receive(text,inet,text,jsonb,text) to attendance_receiver;

create function public.get_attendance_configuration() returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['employees:view','employees:manage','settings:manage']); s public.attendance_settings;
begin
 select * into s from public.attendance_settings where tenant_id=t;
 return jsonb_build_object('timezone',coalesce(s.timezone,'Asia/Dhaka'),'cutoff',coalesce(s.cutoff,'15:00'::time),
  'today',(now() at time zone coalesce(s.timezone,'Asia/Dhaka'))::date,
  'devices',coalesce((select jsonb_agg(jsonb_build_object('device_id',d.device_id,'serial',d.serial,'name',d.name,'enabled',d.enabled,
   'allowed_ip',case when app_private.has_any_permission(array['employees:manage','settings:manage']) then host(d.allowed_ip) end,
   'last_seen_at',d.last_seen_at,'last_upload_at',d.last_upload_at,'last_event_at',d.last_event_at,'last_batch_count',d.last_batch_count,
   'unmapped',(select count(*) from public.attendance_users u where u.tenant_id=t and u.device_id=d.device_id and u.employee_id is null)) order by d.name)
   from public.attendance_devices d where d.tenant_id=t),'[]'::jsonb));
end $$;

create function public.save_attendance_configuration(p_timezone text,p_cutoff time) returns void language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('settings:manage'); old_zone text; old_cutoff time; today date;
begin
 if p_timezone is null or not exists(select 1 from pg_catalog.pg_timezone_names where name=p_timezone)
 or p_cutoff is null then raise exception 'Select a valid timezone and cutoff'; end if;
 insert into public.attendance_settings(tenant_id) values(t) on conflict do nothing;
 select timezone,cutoff into old_zone,old_cutoff from public.attendance_settings where tenant_id=t for update;
 if p_timezone<>old_zone and exists(select 1 from public.attendance_days where tenant_id=t) then raise exception 'Timezone is fixed after the first upload to preserve device history'; end if;
 update public.attendance_settings set timezone=p_timezone,cutoff=p_cutoff,updated_at=now() where tenant_id=t;
 today:=(now() at time zone p_timezone)::date;
 insert into public.attendance_cutoff_rules(tenant_id,effective_from,cutoff) values(t,'2000-01-01',old_cutoff) on conflict do nothing;
 insert into public.attendance_cutoff_rules(tenant_id,effective_from,cutoff) values(t,today,p_cutoff)
 on conflict(tenant_id,effective_from) do update set cutoff=excluded.cutoff;
 -- Past days retain the rule recorded for that workday. Only today's indexed
 -- events need reaggregation when the owner changes the cutoff mid-day.
 update public.attendance_days d set cutoff=p_cutoff,last_after_cutoff=(select max(e.event_at) from public.attendance_events e
  where e.tenant_id=t and e.device_id=d.device_id and e.pin=d.pin and e.work_date=d.work_date and not e.clock_warning and e.device_time::time>=p_cutoff),updated_at=now()
  where d.tenant_id=t and d.work_date>=today;
end $$;

create function public.save_attendance_device(p_device_id uuid,p_serial text,p_name text,p_allowed_ip inet,p_enabled boolean) returns uuid language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('settings:manage'); result uuid;
begin
 if p_allowed_ip is null or p_enabled is null or p_serial is null or p_name is null then raise exception 'Serial, name and exact public source IP are required'; end if;
 if p_device_id is null then
  insert into public.attendance_devices(tenant_id,serial,name,allowed_ip,enabled) values(t,trim(p_serial),trim(p_name),p_allowed_ip,p_enabled) returning device_id into result;
 else
  update public.attendance_devices set name=trim(p_name),allowed_ip=p_allowed_ip,enabled=p_enabled where tenant_id=t and device_id=p_device_id and serial=p_serial returning device_id into result;
  if not found then raise exception 'Device not found or serial changed'; end if;
 end if;
 return result;
end $$;

create function public.link_attendance_user(p_device_id uuid,p_pin text,p_employee_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('employees:manage'); prior uuid;
begin
 if not exists(select 1 from public.attendance_devices where tenant_id=t and device_id=p_device_id)
 or not exists(select 1 from public.employees where tenant_id=t and employee_id=p_employee_id) then raise exception 'Device or employee not found'; end if;
 -- Serialize linking with ingestion and prohibit silently moving saved scans
 -- from one employee to another when a device enrollment number is reused.
 perform 1 from public.attendance_devices where tenant_id=t and device_id=p_device_id for update;
 select employee_id into prior from public.attendance_users where tenant_id=t and device_id=p_device_id and pin=p_pin;
 if prior is not null and prior<>p_employee_id then raise exception 'This enrollment already belongs to another employee. Use a new enrollment ID on the device'; end if;
 insert into public.attendance_users(tenant_id,device_id,pin,employee_id) values(t,p_device_id,trim(p_pin),p_employee_id)
 on conflict(tenant_id,device_id,pin) do update set employee_id=excluded.employee_id;
end $$;

create function public.get_attendance_users(p_device_id uuid,p_offset integer default 0) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['employees:manage','settings:manage']); result jsonb;
begin
 if p_offset is null or p_offset<0 then raise exception 'Invalid offset'; end if;
 select jsonb_build_object('total',(select count(*) from public.attendance_users where tenant_id=t and device_id=p_device_id and employee_id is null),
 'entries',coalesce(jsonb_agg(to_jsonb(u)),'[]')) into result from (select pin,first_seen_at,last_seen_at from public.attendance_users
 where tenant_id=t and device_id=p_device_id and employee_id is null order by pin limit 25 offset p_offset) u;
 return result;
end $$;

create function app_private.attendance_summary(t uuid,start_day date,end_day date,eid uuid default null) returns jsonb language sql stable set search_path='' as $$
 select coalesce(jsonb_agg(to_jsonb(q) order by work_date desc,name),'[]') from (
 select u.employee_id,e.name,d.work_date,min(d.first_at) clock_in,max(d.last_at) last_scan,
 case when max(d.last_after_cutoff)>min(d.first_at) then max(d.last_after_cutoff) end clock_out,
 sum(d.scan_count)::integer scan_count,sum(d.warning_count)::integer warning_count,
 max(d.cutoff) cutoff,max(d.timezone) timezone,max(d.updated_at) updated_at,
 d.work_date<(now() at time zone max(d.timezone))::date finalized
 from public.attendance_days d join public.attendance_users u using(tenant_id,device_id,pin)
 join public.employees e on e.tenant_id=u.tenant_id and e.employee_id=u.employee_id
 where d.tenant_id=t and d.work_date between start_day and end_day and (eid is null or u.employee_id=eid)
 group by u.employee_id,e.name,d.work_date
 ) q;
$$;
revoke all on function app_private.attendance_summary(uuid,date,date,uuid) from public,anon,authenticated,service_role,attendance_receiver;

create function public.get_attendance_today() returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['employees:view','employees:manage']); zone text; today date;
begin
 select timezone into zone from public.attendance_settings where tenant_id=t;
 today:=(now() at time zone coalesce(zone,'Asia/Dhaka'))::date;
 return jsonb_build_object('today',today,'entries',app_private.attendance_summary(t,today,today));
end $$;

create function public.get_employee_attendance(p_employee_id uuid,p_month date) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['employees:view','employees:manage']); start_day date:=date_trunc('month',p_month)::date;
begin
 if p_month is null or p_month<'2000-01-01' or p_month>='2101-01-01' then raise exception 'Select a valid month'; end if;
 if not exists(select 1 from public.employees where tenant_id=t and employee_id=p_employee_id) then raise exception 'Employee not found'; end if;
 return jsonb_build_object('entries',app_private.attendance_summary(t,start_day,(start_day+interval '1 month - 1 day')::date,p_employee_id),
 'links',coalesce((select jsonb_agg(jsonb_build_object('device_id',u.device_id,'device_name',d.name,'pin',u.pin)) from public.attendance_users u
 join public.attendance_devices d using(tenant_id,device_id) where u.tenant_id=t and u.employee_id=p_employee_id),'[]'));
end $$;

create function public.get_employee_attendance_events(p_employee_id uuid,p_day date,p_offset integer default 0) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['employees:view','employees:manage']); result jsonb;
begin
 if p_day is null or p_offset is null or p_offset<0 then raise exception 'Select a date and valid offset'; end if;
 if not exists(select 1 from public.employees where tenant_id=t and employee_id=p_employee_id) then raise exception 'Employee not found'; end if;
 select jsonb_build_object('total',(select count(*) from public.attendance_events e join public.attendance_users u using(tenant_id,device_id,pin)
 where e.tenant_id=t and u.employee_id=p_employee_id and e.work_date=p_day), 'entries',coalesce(jsonb_agg(to_jsonb(q)),'[]')) into result
 from (select e.event_key,e.event_at,e.device_time,e.received_at,e.status,e.verification,e.clock_warning,d.name device_name
 from public.attendance_events e join public.attendance_users u using(tenant_id,device_id,pin) join public.attendance_devices d using(tenant_id,device_id)
 where e.tenant_id=t and u.employee_id=p_employee_id and e.work_date=p_day order by e.event_at,e.device_id,e.event_key limit 25 offset p_offset) q;
 return result;
end $$;

revoke all on function public.get_attendance_configuration(),public.save_attendance_configuration(text,time),public.save_attendance_device(uuid,text,text,inet,boolean),
 public.link_attendance_user(uuid,text,uuid),public.get_attendance_users(uuid,integer),public.get_attendance_today(),public.get_employee_attendance(uuid,date),public.get_employee_attendance_events(uuid,date,integer) from public,anon;
grant execute on function public.get_attendance_configuration(),public.save_attendance_configuration(text,time),public.save_attendance_device(uuid,text,text,inet,boolean),
 public.link_attendance_user(uuid,text,uuid),public.get_attendance_users(uuid,integer),public.get_attendance_today(),public.get_employee_attendance(uuid,date),public.get_employee_attendance_events(uuid,date,integer) to authenticated;
