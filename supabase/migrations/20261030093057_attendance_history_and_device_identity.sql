-- Canonical employee workdays, effective device links and immutable corrections.
create temporary table attendance_preservation as select
 (select md5(coalesce(jsonb_agg(to_jsonb(e) order by tenant_id,device_id,event_key)::text,'')) from public.attendance_events e) events,
 (select md5(coalesce(jsonb_agg(to_jsonb(e) order by tenant_id,transaction_id)::text,'')) from public.wallet_transactions e) ledger,
 (select md5(coalesce(jsonb_agg(to_jsonb(e) order by tenant_id,item_id)::text,'')) from public.items e) stock;

create table public.attendance_links (
 tenant_id uuid not null, link_id uuid not null default gen_random_uuid(), device_id uuid not null, pin text not null, employee_id uuid not null,
 linked_at timestamptz not null default clock_timestamp(), unlinked_at timestamptz,
 linked_by uuid, unlinked_by uuid,
 primary key(tenant_id,link_id),
 foreign key(tenant_id,device_id,pin) references public.attendance_users,
 foreign key(tenant_id,employee_id) references public.employees,
 foreign key(tenant_id,linked_by) references public.user_profiles(tenant_id,user_id),
 foreign key(tenant_id,unlinked_by) references public.user_profiles(tenant_id,user_id),
 check(unlinked_at is null or unlinked_at>=linked_at)
);
create unique index attendance_active_pin on public.attendance_links(tenant_id,device_id,pin) where unlinked_at is null;
create unique index attendance_active_employee on public.attendance_links(tenant_id,device_id,employee_id) where unlinked_at is null;
create index attendance_link_employee_history on public.attendance_links(tenant_id,employee_id,linked_at,device_id,pin);
create index attendance_link_event_lookup on public.attendance_links(tenant_id,device_id,pin,linked_at,unlinked_at);
-- Existing associations had adopted old scans. Preserve precisely that evidence;
-- every new association below starts at server time, without backdating.
insert into public.attendance_links(tenant_id,device_id,pin,employee_id,linked_at)
 select tenant_id,device_id,pin,employee_id,'-infinity' from public.attendance_users where employee_id is not null;
alter table public.attendance_users drop column employee_id;

-- The old cutoff meant a departure threshold. The new cutoff is the workday
-- boundary, initially midnight. Keep the prior configuration as audit evidence.
create table public.attendance_configuration_audit (
 tenant_id uuid not null references public.tenants, audit_id uuid not null default gen_random_uuid(),
 details jsonb not null, created_at timestamptz not null default clock_timestamp(), created_by uuid,
 primary key(tenant_id,audit_id), foreign key(tenant_id,created_by) references public.user_profiles(tenant_id,user_id)
);
insert into public.attendance_configuration_audit(tenant_id,details)
 select tenant_id,jsonb_build_object('normalization','Departure threshold replaced by midnight workday boundary','previous',to_jsonb(s)) from public.attendance_settings s;
alter table public.attendance_settings alter column cutoff set default '00:00';
update public.attendance_settings set cutoff='00:00';
delete from public.attendance_cutoff_rules;
insert into public.attendance_cutoff_rules select tenant_id,'2000-01-01','00:00' from public.tenants;
drop function app_private.attendance_summary(uuid,date,date,uuid);
drop table public.attendance_days;
create table public.attendance_days (
 tenant_id uuid not null,employee_id uuid not null,work_date date not null,
 timezone text not null,starts_at timestamptz not null,ends_at timestamptz not null,
 first_at timestamptz,last_at timestamptz,scan_count integer not null default 0,warning_count integer not null default 0,
 revision bigint not null default 1,updated_at timestamptz not null default clock_timestamp(),
 primary key(tenant_id,employee_id,work_date),foreign key(tenant_id,employee_id) references public.employees,
 check(ends_at>starts_at)
);
create index attendance_business_days on public.attendance_days(tenant_id,work_date desc,employee_id);
create table public.attendance_adjustments (
 tenant_id uuid not null, adjustment_id uuid not null default gen_random_uuid(), employee_id uuid not null,work_date date not null,
 clock_in timestamptz,clock_out timestamptz,reason text not null check(length(trim(reason)) between 1 and 1000),
 before_values jsonb not null,request_id uuid not null,created_at timestamptz not null default clock_timestamp(),created_by uuid not null,
 primary key(tenant_id,adjustment_id),unique(tenant_id,request_id),
 foreign key(tenant_id,employee_id,work_date) references public.attendance_days,
 foreign key(tenant_id,created_by) references public.user_profiles(tenant_id,user_id),
 check(clock_out is null or (clock_in is not null and clock_out>clock_in))
);
create index attendance_adjustment_day on public.attendance_adjustments(tenant_id,employee_id,work_date,created_at desc,adjustment_id desc);
create trigger immutable_attendance_adjustment before update or delete on public.attendance_adjustments for each row execute function app_private.immutable_finance_record();
create trigger immutable_attendance_event before update or delete on public.attendance_events for each row execute function app_private.immutable_finance_record();
create trigger immutable_attendance_config before update or delete on public.attendance_configuration_audit for each row execute function app_private.immutable_finance_record();

create function app_private.attendance_boundary(t uuid,d date) returns time language sql stable set search_path='' as $$
 select coalesce((select cutoff from public.attendance_cutoff_rules where tenant_id=t and effective_from<=d order by effective_from desc limit 1),'00:00'::time)
$$;
create function app_private.attendance_date(t uuid,instant timestamptz,zone text) returns date language sql stable set search_path='' as $$
 select case when instant<((instant at time zone zone)::date+app_private.attendance_boundary(t,(instant at time zone zone)::date)) at time zone zone
 then (instant at time zone zone)::date-1 else (instant at time zone zone)::date end
$$;
create function app_private.ensure_attendance_day(t uuid,eid uuid,d date) returns void language sql set search_path='' as $$
 insert into public.attendance_days(tenant_id,employee_id,work_date,timezone,starts_at,ends_at)
 select t,eid,d,zone,(d+app_private.attendance_boundary(t,d)) at time zone zone,
 (d+1+app_private.attendance_boundary(t,d+1)) at time zone zone
 from (select coalesce((select timezone from public.attendance_settings where tenant_id=t),'Asia/Dhaka') zone) q on conflict do nothing
$$;

create function app_private.attendance_rows(t uuid,eid uuid,from_day date,to_day date)
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
 when d.last_at>d.first_at then d.last_at when d.first_at is not null and now()>=d.ends_at then d.ends_at end cout,
 a.adjustment_id is null and d.first_at is not null and d.last_at=d.first_at and now()>=d.ends_at auto,
 a.adjustment_id is not null is_manual
 from public.attendance_days d left join lateral(select * from public.attendance_adjustments a
 where a.tenant_id=t and a.employee_id=d.employee_id and a.work_date=d.work_date order by a.created_at desc,a.adjustment_id desc limit 1) a on true
 where d.tenant_id=t and (eid is null or d.employee_id=eid) and (from_day is null or d.work_date>=from_day) and (to_day is null or d.work_date<=to_day)) q
$$;

-- Rebuild only from preserved raw evidence and the original associations.
do $$ declare r record; zone text; d date; begin
 for r in select e.*,l.employee_id from public.attendance_events e join public.attendance_links l using(tenant_id,device_id,pin) loop
  select coalesce((select timezone from public.attendance_settings where tenant_id=r.tenant_id),'Asia/Dhaka') into zone;
  d:=app_private.attendance_date(r.tenant_id,r.event_at,zone);
  perform app_private.ensure_attendance_day(r.tenant_id,r.employee_id,d);
  update public.attendance_days set first_at=case when r.clock_warning then first_at else least(first_at,r.event_at) end,
  last_at=case when r.clock_warning then last_at else greatest(last_at,r.event_at) end,
  scan_count=scan_count+case when r.clock_warning then 0 else 1 end,warning_count=warning_count+case when r.clock_warning then 1 else 0 end
  where tenant_id=r.tenant_id and employee_id=r.employee_id and work_date=d;
 end loop;
end $$;

create function app_private.set_attendance_link(t uuid,eid uuid,device uuid,new_pin text,expected uuid) returns void language plpgsql set search_path='' as $$
declare old public.attendance_links; instant timestamptz:=clock_timestamp();
begin
 new_pin:=nullif(trim(new_pin),'');
 perform 1 from public.attendance_devices where tenant_id=t and device_id=device and removed_at is null for update;
 if not found then raise exception 'Device not found'; end if;
 perform 1 from public.employees where tenant_id=t and employee_id=eid for no key update;
 if not found then raise exception 'Employee not found'; end if;
 select * into old from public.attendance_links where tenant_id=t and device_id=device and employee_id=eid and unlinked_at is null;
 if old.link_id is distinct from expected then raise exception 'Device link changed. Reload before saving.'; end if;
 if old.pin is not distinct from new_pin then return; end if;
 if new_pin is not null then
  if new_pin !~ '^[A-Za-z0-9_-]{1,24}$' then raise exception 'Enter a valid machine User ID'; end if;
  if not exists(select 1 from public.attendance_devices where tenant_id=t and device_id=device and enabled and approved_at is not null and removed_at is null) then raise exception 'Choose an approved, enabled device'; end if;
  if exists(select 1 from public.attendance_links where tenant_id=t and device_id=device and pin=new_pin and unlinked_at is null) then raise exception 'This machine User ID is already linked'; end if;
 end if;
 if old.link_id is not null then update public.attendance_links set unlinked_at=instant,unlinked_by=auth.uid() where tenant_id=t and link_id=old.link_id; end if;
 if new_pin is not null then
  insert into public.attendance_users(tenant_id,device_id,pin) values(t,device,new_pin) on conflict do nothing;
  insert into public.attendance_links(tenant_id,employee_id,device_id,pin,linked_at,linked_by) values(t,eid,device,new_pin,instant,auth.uid());
 end if;
end $$;

-- Direct legacy ADMS remains serial-identified by explicit user decision.
-- Registration/approval gates tenancy, but serials do not prove device identity.
-- No source IP, shared authentication key or relay is required.
alter table public.attendance_devices drop column allowed_ip,
 add column approved_at timestamptz,add column removed_at timestamptz;
-- Previously authorized machines continue uploading without re-enrollment.
update public.attendance_devices set approved_at=created_at;
create table public.attendance_device_audit (
 tenant_id uuid not null,device_id uuid not null,audit_id uuid not null default gen_random_uuid(),action text not null,
 created_at timestamptz not null default clock_timestamp(),created_by uuid not null,
 primary key(tenant_id,audit_id),foreign key(tenant_id,device_id) references public.attendance_devices,
 foreign key(tenant_id,created_by) references public.user_profiles(tenant_id,user_id)
);
create index attendance_device_audit_history on public.attendance_device_audit(tenant_id,device_id,created_at desc);
create trigger immutable_attendance_device_audit before update or delete on public.attendance_device_audit for each row execute function app_private.immutable_finance_record();
drop function public.save_attendance_device(uuid,text,text,inet,boolean);
create function public.save_attendance_device(p_device_id uuid,p_serial text,p_name text,p_action text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('settings:manage'); d public.attendance_devices;
begin
 if p_action not in ('register','edit','approve','disable','enable','remove') or p_action is null then raise exception 'Invalid device action'; end if;
 if p_action='register' then
  insert into public.attendance_devices(tenant_id,serial,name,enabled)
  values(t,trim(p_serial),trim(p_name),false) returning * into d;
 else
  select * into d from public.attendance_devices where tenant_id=t and device_id=p_device_id and removed_at is null for update;
  if not found then raise exception 'Device not found'; end if;
  update public.attendance_devices set name=case when p_action='edit' then trim(p_name) else name end,
   approved_at=case when p_action='approve' then clock_timestamp() else approved_at end,
   enabled=case when p_action in ('approve','enable') then true when p_action in ('disable','remove') then false else enabled end,
   removed_at=case when p_action='remove' then clock_timestamp() else removed_at end
  where tenant_id=t and device_id=d.device_id;
  if p_action='remove' then
   update public.attendance_links set unlinked_at=clock_timestamp(),unlinked_by=auth.uid() where tenant_id=t and device_id=d.device_id and unlinked_at is null;
  end if;
 end if;
 insert into public.attendance_device_audit(tenant_id,device_id,action,created_by) values(t,d.device_id,p_action,auth.uid());
 return jsonb_build_object('device_id',d.device_id);
end $$;

drop function public.attendance_receive(text,inet,text,jsonb,text);
create function public.attendance_receive(p_serial text,p_action text,p_records jsonb,p_stamp text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.attendance_devices;s public.attendance_settings;r jsonb;dt timestamp;instant timestamptz;day date;
 warning boolean;inserted integer;total integer:=0;eid uuid;affected jsonb:='[]';pair jsonb;
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
  instant:=dt at time zone s.timezone;day:=app_private.attendance_date(d.tenant_id,instant,s.timezone);
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
 last_event_at=greatest(last_event_at,(select max((x->>'timestamp')::timestamp at time zone s.timezone) from jsonb_array_elements(p_records) x)),
 stamp=case when p_action='upload' then coalesce(p_stamp,stamp) else stamp end where tenant_id=d.tenant_id and device_id=d.device_id;
 return jsonb_build_object('stamp',coalesce(p_stamp,d.stamp),'inserted',total,'timezone',
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
 'next_cutoff',app_private.attendance_boundary(t,today+1),'can_correct',app_private.has_any_permission(array['employees:manage']) and exists(
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
 insert into public.attendance_configuration_audit(tenant_id,details,created_by)
 values(t,jsonb_build_object('before',to_jsonb(s),'timezone',p_timezone,'cutoff',p_cutoff,'effective_from',today+1),auth.uid());
end $$;

create or replace function public.get_attendance_users(p_device_id uuid,p_offset integer default 0) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['employees:manage','settings:manage']);result jsonb;
begin
 if p_offset is null or p_offset<0 or p_offset>1000000 then raise exception 'Invalid offset'; end if;
 with matching as materialized(select u.pin,u.first_seen_at,u.last_seen_at from public.attendance_users u
 where u.tenant_id=t and u.device_id=p_device_id and not exists(select 1 from public.attendance_links l where l.tenant_id=t and l.device_id=u.device_id and l.pin=u.pin and l.unlinked_at is null))
 select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(to_jsonb(p)) from (select * from matching order by pin limit 25 offset p_offset)p),'[]')) into result;
 return result;
end $$;
drop function public.link_attendance_user(uuid,text,uuid);
create function public.set_employee_attendance_link(p_employee_id uuid,p_device_id uuid,p_pin text,p_expected uuid) returns void language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('employees:manage');begin perform app_private.set_attendance_link(t,p_employee_id,p_device_id,p_pin,p_expected);end $$;

create or replace function public.get_employee_attendance(p_employee_id uuid,p_month date) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['employees:view','employees:manage']);d date:=date_trunc('month',p_month)::date;
begin
 if p_month is null or p_month<'2000-01-01' or p_month>='2101-01-01' then raise exception 'Select a valid month'; end if;
 if not exists(select 1 from public.employees where tenant_id=t and employee_id=p_employee_id) then raise exception 'Employee not found'; end if;
 return jsonb_build_object('entries',coalesce((select jsonb_agg(to_jsonb(a) order by work_date desc) from app_private.attendance_rows(t,p_employee_id,d,(d+interval '1 month - 1 day')::date)a),'[]'),
 'links',coalesce((select jsonb_agg(jsonb_build_object('link_id',l.link_id,'device_id',l.device_id,'device_name',dv.name,'pin',l.pin,'linked_at',l.linked_at,'unlinked_at',l.unlinked_at) order by l.linked_at desc)
 from public.attendance_links l join public.attendance_devices dv using(tenant_id,device_id) where l.tenant_id=t and l.employee_id=p_employee_id),'[]'));
end $$;
create or replace function public.get_attendance_today() returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['employees:view','employees:manage']);zone text;d date;
begin
 select coalesce((select timezone from public.attendance_settings where tenant_id=t),'Asia/Dhaka') into zone;d:=app_private.attendance_date(t,now(),zone);
 return jsonb_build_object('today',d,'entries',coalesce((select jsonb_agg(to_jsonb(a)) from app_private.attendance_rows(t,null,d,d)a),'[]'));
end $$;

create function public.get_attendance_history(p_employee_id uuid,p_view text default 'daily',p_from date default null,p_to date default null,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['employees:view','employees:manage']);result jsonb;
begin
 if p_view not in ('daily','weekly','monthly') or p_view is null or p_offset is null or p_offset<0 or p_offset>1000000 or p_from>p_to then raise exception 'Invalid attendance filters'; end if;
 if not exists(select 1 from public.employees where tenant_id=t and employee_id=p_employee_id) then raise exception 'Employee not found'; end if;
 with rows as (select * from app_private.attendance_rows(t,p_employee_id,p_from,p_to)),
 periods as materialized(select case p_view when 'daily' then work_date when 'weekly' then date_trunc('week',work_date)::date else date_trunc('month',work_date)::date end period,
 sum(worked_seconds)::bigint worked_seconds,count(*) filter(where clock_in is not null)::integer attended_days,
 case when p_view='daily' then min(clock_in) end clock_in,case when p_view='daily' then max(clock_out) end clock_out,
 bool_or(automatic_close) automatic_close,bool_or(manual) manual
 from rows group by 1),page as(select * from periods order by period desc limit 12 offset p_offset)
 select jsonb_build_object('total',(select count(*) from periods),'entries',coalesce((select jsonb_agg(to_jsonb(p) order by period desc) from page p),'[]')) into result;
 return result;
end $$;

create function public.get_attendance_edit(p_employee_id uuid,p_day date) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('employees:manage');result jsonb;
begin
 if not exists(select 1 from public.user_roles ur join public.roles r using(tenant_id,role_id) where ur.tenant_id=t and ur.user_id=auth.uid() and r.name in ('OWNER','MANAGER')) then raise insufficient_privilege using message='Owner or Manager authorization required'; end if;
 if not exists(select 1 from public.employees where tenant_id=t and employee_id=p_employee_id) then raise exception 'Employee not found'; end if;
 if p_day is null or p_day<'2000-01-01' or p_day>=(now() at time zone coalesce((select timezone from public.attendance_settings where tenant_id=t),'Asia/Dhaka'))::date+1 then raise exception 'Select today or a past date'; end if;
 select to_jsonb(a) into result from app_private.attendance_rows(t,p_employee_id,p_day,p_day)a;
 return jsonb_build_object('day',result,'adjustments',coalesce((select jsonb_agg(to_jsonb(q)) from (
 select a.adjustment_id,a.clock_in,a.clock_out,a.reason,a.created_at,p.full_name actor,a.before_values from public.attendance_adjustments a left join public.user_profiles p on p.tenant_id=t and p.user_id=a.created_by
 where a.tenant_id=t and a.employee_id=p_employee_id and a.work_date=p_day order by a.created_at desc,a.adjustment_id desc limit 12)q),'[]'));
end $$;

create function public.correct_employee_attendance(p_employee_id uuid,p_day date,p_clock_in text,p_clock_out text,p_reason text,p_revision bigint,p_request_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('employees:manage');old jsonb;d public.attendance_days;cin timestamptz;cout timestamptz;prior public.attendance_adjustments;
begin
 perform pg_advisory_xact_lock(hashtextextended(t::text||p_request_id::text,0));
 -- Gate even idempotent retries against current trusted membership/roles.
 old:=nullif(public.get_attendance_edit(p_employee_id,p_day)->'day','null'::jsonb);
 if p_request_id is null or nullif(trim(p_reason),'') is null then raise exception 'Request ID and correction reason are required'; end if;
 perform app_private.ensure_attendance_day(t,p_employee_id,p_day);
 select * into d from public.attendance_days where tenant_id=t and employee_id=p_employee_id and work_date=p_day for update;
 cin:=nullif(p_clock_in,'')::timestamp at time zone d.timezone;cout:=nullif(p_clock_out,'')::timestamp at time zone d.timezone;
 select * into prior from public.attendance_adjustments where tenant_id=t and request_id=p_request_id;
 if found then
  if (prior.employee_id,prior.work_date,prior.clock_in,prior.clock_out,prior.reason,prior.created_by) is distinct from (p_employee_id,p_day,cin,cout,trim(p_reason),auth.uid()) then raise exception 'Request ID already used with different details'; end if;
  return;
 end if;
 if coalesce((old->>'revision')::bigint,0)<>coalesce(p_revision,0) or d.revision<>(case when old is null then 1 else p_revision end) then raise exception 'Attendance changed. Reload before correcting.'; end if;
 if (cin is not null and (cin<d.starts_at or cin>=d.ends_at or cin>now())) or (cout is not null and (cin is null or cout<=cin or cout>d.ends_at or cout>now())) then raise exception 'Use ordered clock times inside this workday and not in the future'; end if;
 if (nullif(p_clock_in,'') is not null and cin at time zone d.timezone<>p_clock_in::timestamp) or (nullif(p_clock_out,'') is not null and cout at time zone d.timezone<>p_clock_out::timestamp) then raise exception 'The selected local time does not exist in this timezone'; end if;
 if (old->>'clock_in')::timestamptz is not distinct from cin and (old->>'clock_out')::timestamptz is not distinct from cout then raise exception 'Attendance values are unchanged'; end if;
 insert into public.attendance_adjustments(tenant_id,employee_id,work_date,clock_in,clock_out,reason,before_values,request_id,created_by)
 values(t,p_employee_id,p_day,cin,cout,trim(p_reason),coalesce(old,'{}'),p_request_id,auth.uid());
 update public.attendance_days set revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and employee_id=p_employee_id and work_date=p_day;
end $$;

create or replace function public.get_employee_attendance_events(p_employee_id uuid,p_day date,p_offset integer default 0) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['employees:view','employees:manage']);result jsonb;
begin
 if p_day is null or p_offset is null or p_offset<0 or p_offset>1000000 then raise exception 'Invalid event page'; end if;
 if not exists(select 1 from public.employees where tenant_id=t and employee_id=p_employee_id) then raise exception 'Employee not found'; end if;
 with matching as materialized(select e.event_key,e.event_at,e.device_time,e.received_at,e.status,e.verification,e.clock_warning,d.name device_name
 from public.attendance_links l join public.attendance_events e using(tenant_id,device_id,pin) join public.attendance_devices d using(tenant_id,device_id)
 where l.tenant_id=t and l.employee_id=p_employee_id and e.work_date=p_day and e.event_at>=l.linked_at and (l.unlinked_at is null or e.event_at<l.unlinked_at)),
 page as(select * from matching order by event_at,event_key limit 25 offset p_offset)
 select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(to_jsonb(p)) from page p),'[]')) into result;
 return result;
end $$;

do $$ declare n text;begin
 foreach n in array array['attendance_links','attendance_days','attendance_adjustments','attendance_device_audit','attendance_configuration_audit'] loop
 execute format('alter table public.%I enable row level security',n);
 execute format('revoke all on public.%I from public,anon,authenticated,attendance_receiver',n);
 end loop;
end $$;
revoke all on function app_private.attendance_boundary(uuid,date),app_private.attendance_date(uuid,timestamptz,text),app_private.ensure_attendance_day(uuid,uuid,date),app_private.attendance_rows(uuid,uuid,date,date),app_private.set_attendance_link(uuid,uuid,uuid,text,uuid) from public,anon,authenticated,attendance_receiver;
revoke all on function public.save_attendance_device(uuid,text,text,text),public.set_employee_attendance_link(uuid,uuid,text,uuid),public.get_attendance_history(uuid,text,date,date,integer),public.get_attendance_edit(uuid,date),public.correct_employee_attendance(uuid,date,text,text,text,bigint,uuid) from public,anon;
grant execute on function public.save_attendance_device(uuid,text,text,text),public.set_employee_attendance_link(uuid,uuid,text,uuid),public.get_attendance_history(uuid,text,date,date,integer),public.get_attendance_edit(uuid,date),public.correct_employee_attendance(uuid,date,text,text,text,bigint,uuid) to authenticated;
do $$ begin
 if (select events from attendance_preservation) is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(e) order by tenant_id,device_id,event_key)::text,'')) from public.attendance_events e)
 or (select ledger from attendance_preservation) is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(e) order by tenant_id,transaction_id)::text,'')) from public.wallet_transactions e)
 or (select stock from attendance_preservation) is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(e) order by tenant_id,item_id)::text,'')) from public.items e)
 then raise exception 'Attendance migration changed raw events, financial or stock evidence'; end if;
end $$;

-- Employee creation and initial linking commit or roll back together.
create or replace function public.save_employee(p_payload jsonb,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('employees:manage'); e public.employees; eid uuid:=(p_payload->>'employee_id')::uuid;
 prior public.finance_requests; payload jsonb:=jsonb_build_object('action','employee_profile','actor',auth.uid(),'body',p_payload);
 ph jsonb; cnt integer:=0; primary_count integer:=0; term public.employee_terms; dt date; salary numeric; active boolean; result jsonb; link jsonb;
begin
 if p_request_id is null then raise exception 'Request ID is required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload<>payload then raise exception 'Request ID was already used with different details'; end if; return prior.result; end if;
 if nullif(trim(p_payload->>'name'),'') is null or length(p_payload->>'name')>255 then raise exception 'Employee name is required (up to 255 characters)'; end if;
 if p_payload->>'business_unit' not in ('gas_business','truck_business') or p_payload->>'business_unit' is null then raise exception 'Select a business unit'; end if;
 if jsonb_typeof(p_payload->'phones') is distinct from 'array' or jsonb_array_length(p_payload->'phones') not between 1 and 10 then raise exception 'Use one to ten phone numbers'; end if;
 if eid is null then
 insert into public.employees(tenant_id,name,address,employee_type_id,business_unit,notes,created_by)
 values(t,trim(p_payload->>'name'),nullif(trim(p_payload->>'address'),''),app_private.resolve_employee_type(t,p_payload->>'employee_type_name'),p_payload->>'business_unit',nullif(trim(p_payload->>'notes'),''),auth.uid()) returning employee_id into eid;
 else
 select * into e from public.employees where tenant_id=t and employee_id=eid for no key update;
 if not found then raise exception 'Employee not found'; end if;
 if e.revision is distinct from (p_payload->>'revision')::integer then raise exception 'Employee changed. Reload before saving.'; end if;
 end if;
 select * into term from public.employee_terms where tenant_id=t and employee_id=eid order by effective_from desc,created_at desc,term_id desc limit 1;
 if p_payload ? 'terms' then
 dt:=(p_payload->'terms'->>'effective_from')::date;
 salary:=app_private.purchase_money((p_payload->'terms'->>'monthly_salary')::numeric);
 active:=(p_payload->'terms'->>'is_active')::boolean;
 if dt is null or dt not between '2000-01-01' and '2100-12-31' or active is null or salary is null
 or salary<>(p_payload->'terms'->>'monthly_salary')::numeric then raise exception 'Provide valid salary, status and effective date'; end if;
 if term.term_id is not null and (term.monthly_salary,term.is_active) is not distinct from (salary,active) then raise exception 'Salary and status are unchanged'; end if;
 if term.term_id is not null and dt<term.effective_from then raise exception 'Choose a date on or after the latest revision'; end if;
 if term.term_id is not null and dt<date_trunc('month',now() at time zone 'Asia/Dhaka')::date then raise exception 'Past salary terms cannot be changed'; end if;
 if term.term_id is not null and salary<>term.monthly_salary and extract(day from dt)<>1 then raise exception 'Salary revisions start on the first day of a month'; end if;
 if term.term_id is not null and active<>term.is_active and dt<(now() at time zone 'Asia/Dhaka')::date then raise exception 'Employment status changes start today or later'; end if;
 insert into public.employee_terms(tenant_id,employee_id,effective_from,monthly_salary,is_active,reason,created_by)
 values(t,eid,dt,salary,active,coalesce(nullif(trim(p_payload->'terms'->>'reason'),''),'Initial employment terms'),auth.uid());
 elsif term.term_id is null then raise exception 'Initial employment terms are required'; end if;
 update public.employees set name=trim(p_payload->>'name'),address=nullif(trim(p_payload->>'address'),''),
 employee_type_id=case when e.employee_id is not null and exists(select 1 from public.employee_types r where r.tenant_id=t and r.employee_type_id=e.employee_type_id and lower(r.name)=lower(p_payload->>'employee_type_name')) then e.employee_type_id else app_private.resolve_employee_type(t,p_payload->>'employee_type_name') end,business_unit=p_payload->>'business_unit',notes=nullif(trim(p_payload->>'notes'),''),
 revision=case when e.employee_id is null then 1 else revision+1 end,updated_at=clock_timestamp() where tenant_id=t and employee_id=eid;
 delete from public.employee_phone_numbers where tenant_id=t and employee_id=eid;
 for ph in select value from jsonb_array_elements(p_payload->'phones') loop
 cnt:=cnt+1; if coalesce((ph->>'is_primary')::boolean,false) then primary_count:=primary_count+1; end if;
 insert into public.employee_phone_numbers(tenant_id,employee_id,phone,is_primary) values(t,eid,trim(ph->>'phone'),coalesce((ph->>'is_primary')::boolean,false)); end loop;
 if primary_count<>1 then raise exception 'Choose exactly one primary phone number'; end if;
 insert into public.employee_activity(tenant_id,employee_id,description,details,created_by) values(t,eid,case when e.employee_id is null then 'Employee created' else 'Profile updated' end,
 jsonb_build_object('before',case when e.employee_id is null then null else to_jsonb(e) end,'after',app_private.employee_summary(t,eid)),auth.uid());
 if p_payload ? 'attendance_links' then
  if jsonb_typeof(p_payload->'attendance_links') is distinct from 'array' or jsonb_array_length(p_payload->'attendance_links')>20 then raise exception 'Invalid device links'; end if;
  for link in select value from jsonb_array_elements(p_payload->'attendance_links') order by value->>'device_id' loop
   perform app_private.set_attendance_link(t,eid,(link->>'device_id')::uuid,link->>'pin',nullif(link->>'expected','')::uuid);
  end loop;
 end if;
 result:=jsonb_build_object('employee_id',eid);
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,payload,result,auth.uid()); return result;
end $$;

-- Stable daily activity identities replace individual scan entries.
create or replace function public.get_employee_activity(p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 12) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['employees:view','employees:manage','payroll:view','payroll:pay']); result jsonb;
 financial boolean:=app_private.has_any_permission(array['payroll:view','payroll:pay']);
 attendance boolean:=app_private.has_any_permission(array['employees:view','employees:manage']);
 eid uuid:=nullif(p_filters->>'employee_id','')::uuid;
 from_day date:=nullif(p_filters->>'from','')::date; to_day date:=nullif(p_filters->>'to','')::date;
begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100
 or length(coalesce(p_filters->>'search',''))>500 or from_day>to_day
 or coalesce(p_filters->>'kind','') not in ('','profile','terms','payment','reversal','attendance') then raise exception 'Invalid activity filters or page'; end if;
 with events as (
 select a.activity_id::text id,a.employee_id,'profile'::text kind,a.description,a.created_at,a.created_at occurred_at,
 (a.created_at at time zone 'Asia/Dhaka')::date date,a.created_by,null::numeric amount,
 case when financial then a.details else '{}'::jsonb end details,'[]'::jsonb wallets,false reversible
 from public.employee_activity a where coalesce(p_filters->>'kind','') in ('','profile') and a.tenant_id=t and (eid is null or a.employee_id=eid)
  and (financial or a.description in ('Employee created','Profile updated'))
 union all
 select tm.term_id::text,tm.employee_id,'terms',case when tm.is_active then 'Salary & employment updated' else 'Employment paused / ended' end,
 tm.created_at,tm.created_at,tm.effective_from,tm.created_by,case when financial then tm.monthly_salary end,
 case when financial then to_jsonb(tm) else jsonb_build_object('effective_from',tm.effective_from,'is_active',tm.is_active,'reason',tm.reason) end,'[]'::jsonb,false
 from public.employee_terms tm where coalesce(p_filters->>'kind','') in ('','terms') and tm.tenant_id=t and (eid is null or tm.employee_id=eid)
 union all
 select p.payment_id::text,p.employee_id,case when p.reversal_of is null then 'payment' else 'reversal' end,
 case when p.kind='bonus' then p.bonus_name when p.kind='salary' then 'Salary · '||to_char(o.period,'FMMonth YYYY') else 'Trip payment' end||coalesce(' · '||p.description,''),
 p.created_at,p.created_at,p.payment_date,p.created_by,case when p.reversal_of is null then p.amount else -p.amount end,
 to_jsonb(p)||jsonb_build_object('period',o.period),
 coalesce((select jsonb_agg(to_jsonb(en)||jsonb_build_object('transaction_id',wt.transaction_id) order by en.entry_id) from public.employee_payment_entries en
 left join public.wallet_transactions wt on wt.tenant_id=t and wt.employee_entry_id=en.entry_id where en.tenant_id=t and en.payment_id=p.payment_id),'[]'),
 p.reversal_of is null and p.source_snapshot is null and not exists(select 1 from public.employee_payments r where r.tenant_id=t and r.reversal_of=p.payment_id)
 and (p.transit_id is null or exists(select 1 from public.transits tr where tr.tenant_id=t and tr.transit_id=p.transit_id and tr.closed_at is null))
 from public.employee_payments p left join public.employee_salary_months o using(tenant_id,salary_month_id)
 where financial and coalesce(p_filters->>'kind','') in ('','payment','reversal') and p.tenant_id=t and (eid is null or p.employee_id=eid)
 union all
 select ad.employee_id::text||':'||ad.work_date::text||':'||v.kind,ad.employee_id,'attendance',v.description,
 ad.updated_at,v.instant,ad.work_date,null::uuid,null::numeric,
 jsonb_build_object('timezone',ad.timezone,'manual',ad.manual,'automatic_close',ad.automatic_close,
 'worked_seconds',ad.worked_seconds,'warning_count',ad.warning_count),'[]'::jsonb,false
 from app_private.attendance_rows(t,eid,from_day,to_day) ad
 cross join lateral(values ('in','Clock in',ad.clock_in),('out','Clock out',ad.clock_out)) v(kind,description,instant)
 where attendance and v.instant is not null and coalesce(p_filters->>'kind','') in ('','attendance')
 ), matching as materialized (
 select ev.*,e.name employee_name,up.full_name actor from events ev join public.employees e on e.tenant_id=t and e.employee_id=ev.employee_id
 left join public.user_profiles up on up.tenant_id=t and up.user_id=ev.created_by
 where (nullif(p_filters->>'kind','') is null or ev.kind=p_filters->>'kind')
 and (from_day is null or ev.date>=from_day) and (to_day is null or ev.date<=to_day)
 and app_private.employee_search(concat_ws(' ',e.name,ev.description,ev.kind,ev.id,ev.wallets,ev.details),p_filters->>'search')),
 page as (select * from matching order by date desc,occurred_at desc,id desc offset p_offset limit p_limit)
 select jsonb_build_object('entries',coalesce((select jsonb_agg(to_jsonb(p) order by date desc,occurred_at desc,id desc) from page p),'[]'),'total',(select count(*) from matching)) into result;
 return result;
end $$;

alter table public.attendance_links owner to postgres;
alter table public.attendance_days owner to postgres;
alter table public.attendance_adjustments owner to postgres;
alter table public.attendance_configuration_audit owner to postgres;
alter table public.attendance_device_audit owner to postgres;
alter function app_private.attendance_boundary(uuid,date) owner to postgres;
alter function app_private.attendance_date(uuid,timestamptz,text) owner to postgres;
alter function app_private.ensure_attendance_day(uuid,uuid,date) owner to postgres;
alter function app_private.attendance_rows(uuid,uuid,date,date) owner to postgres;
alter function app_private.set_attendance_link(uuid,uuid,uuid,text,uuid) owner to postgres;
