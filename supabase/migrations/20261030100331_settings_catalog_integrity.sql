-- Bound configuration to real clock times and IANA zones. The UI offers these
-- values, and API callers must observe the same contract.
alter table public.attendance_settings add constraint attendance_cutoff_clock_time check(cutoff<'24:00'::time),
 add constraint attendance_timezone_iana check((timezone='UTC' or timezone like '%/%') and timezone !~ '^(posix|right)/');
alter table public.attendance_cutoff_rules add constraint attendance_rule_clock_time check(cutoff<'24:00'::time);
-- Catalog assignment counts and safeguards use a tenant-qualified FK lookup.
create index employee_role_usage on public.employees(tenant_id,employee_type_id);

create or replace function public.get_my_preferences() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if app_private.current_tenant_id() is null then raise insufficient_privilege; end if;
 return jsonb_build_object('theme',(select theme from public.user_preferences where user_id=auth.uid()));
end $$;

-- A manually corrected arrival with no departure follows the same cutoff.
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
 case when a.adjustment_id is not null then coalesce(a.clock_out,case when a.clock_in is not null and now()>=d.ends_at then d.ends_at end)
 when d.last_at>d.first_at then d.last_at when d.first_at is not null and now()>=d.ends_at then d.ends_at end cout,
 ((a.adjustment_id is null and d.first_at is not null and d.last_at=d.first_at) or (a.adjustment_id is not null and a.clock_in is not null and a.clock_out is null)) and now()>=d.ends_at auto,
 a.adjustment_id is not null is_manual
 from public.attendance_days d left join lateral(select * from public.attendance_adjustments a
 where a.tenant_id=t and a.employee_id=d.employee_id and a.work_date=d.work_date order by a.created_at desc,a.adjustment_id desc limit 1) a on true
 where d.tenant_id=t and (eid is null or d.employee_id=eid) and (from_day is null or d.work_date>=from_day) and (to_day is null or d.work_date<=to_day)) q
$$;

