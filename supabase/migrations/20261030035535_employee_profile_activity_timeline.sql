-- One employee timeline. Capability checks apply separately to attendance and
-- financial branches; employee-only readers never receive payment evidence.
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
 with attendance_context as (
  select u.employee_id,d.work_date,min(d.first_at) first_at,max(d.last_after_cutoff) last_after_cutoff,max(d.timezone) timezone
  from public.attendance_users u join public.attendance_days d using(tenant_id,device_id,pin)
  where attendance and u.tenant_id=t and u.employee_id is not null and (eid is null or u.employee_id=eid)
   and (from_day is null or d.work_date>=from_day) and (to_day is null or d.work_date<=to_day)
   and coalesce(p_filters->>'kind','') in ('','attendance')
  group by u.employee_id,d.work_date
 ), events as (
 select a.activity_id::text id,a.employee_id,'profile'::text kind,a.description,a.created_at,a.created_at occurred_at,
 (a.created_at at time zone 'Asia/Dhaka')::date date,a.created_by,null::numeric amount,
 case when financial then a.details else '{}'::jsonb end details,'[]'::jsonb wallets,false reversible
 from public.employee_activity a where a.tenant_id=t and (eid is null or a.employee_id=eid)
  and (financial or a.description in ('Employee created','Profile updated'))
 union all
 select tm.term_id::text,tm.employee_id,'terms',case when tm.is_active then 'Salary & employment updated' else 'Employment paused / ended' end,
 tm.created_at,tm.created_at,tm.effective_from,tm.created_by,case when financial then tm.monthly_salary end,
 case when financial then to_jsonb(tm) else jsonb_build_object('effective_from',tm.effective_from,'is_active',tm.is_active,'reason',tm.reason) end,'[]'::jsonb,false
 from public.employee_terms tm where tm.tenant_id=t and (eid is null or tm.employee_id=eid)
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
 where financial and p.tenant_id=t and (eid is null or p.employee_id=eid)
 union all
 select ae.device_id::text||':'||ae.event_key,u.employee_id,'attendance',
 case when ae.clock_warning then 'Device clock warning'
  when ae.event_at=c.first_at then 'Clock in'
  when ae.event_at=c.last_after_cutoff and c.last_after_cutoff>c.first_at
   then case when ae.work_date<(now() at time zone c.timezone)::date then 'Clock out' else 'Clock-out candidate' end
  else 'Attendance scan' end,
 ae.received_at,ae.event_at,ae.work_date,null::uuid,null::numeric,
 jsonb_build_object('device_name',d.name,'pin',ae.pin,'timezone',c.timezone,'received_at',ae.received_at,
  'clock_warning',ae.clock_warning,'status',ae.status,'verification',ae.verification,
  'finalized',ae.work_date<(now() at time zone c.timezone)::date),'[]'::jsonb,false
 from public.attendance_users u join public.attendance_events ae using(tenant_id,device_id,pin)
 join public.attendance_devices d using(tenant_id,device_id)
 join attendance_context c on c.employee_id=u.employee_id and c.work_date=ae.work_date
 where attendance and u.tenant_id=t and (eid is null or u.employee_id=eid)
  and (from_day is null or ae.work_date>=from_day) and (to_day is null or ae.work_date<=to_day)
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
