create or replace function public.get_employee_activity(p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 12) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['employees:view','employees:manage','payroll:view','payroll:pay']); result jsonb;
 financial boolean:=app_private.has_any_permission(array['payroll:view','payroll:pay']);
 attendance boolean:=app_private.has_any_permission(array['employees:view','employees:manage']);
 eid uuid:=nullif(p_filters->>'employee_id','')::uuid;
 from_day date:=nullif(p_filters->>'from','')::date; to_day date:=nullif(p_filters->>'to','')::date;
begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100
 or length(coalesce(p_filters->>'search',''))>500 or from_day>to_day
 or coalesce(p_filters->>'kind','') not in ('','profile','terms','payment','reversal','attendance','transit','assignment') then raise exception 'Invalid activity filters or page'; end if;
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
 union all
 select tr.transit_id::text||':'||crew.role,crew.employee_id,'transit','Transit · '||coalesce(tr.client_name,'Journey')||' · '||coalesce(tr.destination,v.name),
 tr.created_at,tr.created_at,(tr.created_at at time zone 'Asia/Dhaka')::date,null::uuid,
 case when financial then crew.earning end,jsonb_build_object('transit_id',tr.transit_id,'trip_role',crew.role,'status',tr.status),'[]'::jsonb,false
 from public.transits tr join public.vehicles v using(tenant_id,vehicle_id)
 cross join lateral(values(tr.driver_employee_id,'driver',tr.driver_cost),(tr.helper_employee_id,'helper',tr.helper_cost)) crew(employee_id,role,earning)
 where tr.tenant_id=t and crew.employee_id is not null and (eid is null or crew.employee_id=eid) and coalesce(p_filters->>'kind','') in ('','transit')
 union all
 select a.assignment_id::text||':'||change.kind,a.employee_id,'assignment',v.name||' · '||a.role||' '||change.label,
 change.instant,change.instant,(change.instant at time zone 'Asia/Dhaka')::date,change.actor,null::numeric,
 jsonb_build_object('vehicle_id',a.vehicle_id,'trip_role',a.role),'[]'::jsonb,false
 from public.vehicle_assignments a join public.vehicles v using(tenant_id,vehicle_id)
 cross join lateral(values('start','assigned',a.started_at,a.created_by),('end','unlinked',a.ended_at,a.ended_by)) change(kind,label,instant,actor)
 where a.tenant_id=t and (eid is null or a.employee_id=eid) and change.instant is not null and coalesce(p_filters->>'kind','') in ('','assignment')
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
-- The ledger remains canonical; no dedicated per-transit payment projection.
drop function public.get_transit_payments(uuid,jsonb,integer,integer);
drop function public.record_transit_crew(jsonb,uuid);
-- Departure crew is immutable once captured. No historical attribution UI/API.
create or replace function app_private.capture_transit_crew() returns trigger language plpgsql set search_path='' as $$
begin
 if tg_op='INSERT' then
  -- guard_purchase_transit has already locked this vehicle.
  select employee_id,employee_name into new.driver_employee_id,new.driver_name from public.vehicle_assignments
   where tenant_id=new.tenant_id and vehicle_id=new.vehicle_id and role='driver' and ended_at is null;
  select employee_id,employee_name into new.helper_employee_id,new.helper_name from public.vehicle_assignments
   where tenant_id=new.tenant_id and vehicle_id=new.vehicle_id and role='helper' and ended_at is null;
  if new.driver_employee_id is null then raise exception 'Assign a Driver to this vehicle before starting a transit'; end if;
  perform 1 from public.employees where tenant_id=new.tenant_id and employee_id in (new.driver_employee_id,new.helper_employee_id) order by employee_id for update;
  perform app_private.validate_vehicle_employee(new.tenant_id,new.driver_employee_id,'driver');
  perform app_private.validate_vehicle_employee(new.tenant_id,new.helper_employee_id,'helper');
  new.crew_recorded_at:=clock_timestamp();
 elsif (new.driver_employee_id,new.helper_employee_id,new.driver_name,new.helper_name,new.crew_recorded_at)
  is distinct from (old.driver_employee_id,old.helper_employee_id,old.driver_name,old.helper_name,old.crew_recorded_at) then raise exception 'Historical transit crew is locked';
 end if;
 if (tg_op='INSERT' or new.driver_cost is distinct from old.driver_cost) and new.driver_cost>0 and new.driver_employee_id is null then raise exception 'A recorded Driver is required for driver earnings'; end if;
 if (tg_op='INSERT' or new.helper_cost is distinct from old.helper_cost) and new.helper_cost>0 and new.helper_employee_id is null then raise exception 'A recorded Helper is required for helper earnings'; end if;
 return new;
end $$;

create function public.get_employee_presence(p_ids uuid[]) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['employees:view','employees:manage']); zone text; today date;
begin
 if p_ids is null or cardinality(p_ids)>100 then raise exception 'Choose up to 100 employees'; end if;
 select coalesce((select timezone from public.attendance_settings where tenant_id=t),'Asia/Dhaka') into zone;
 today:=app_private.attendance_date(t,now(),zone);
 return jsonb_build_object('timezone',zone,'entries',coalesce((select jsonb_agg(to_jsonb(a)) from public.employees e cross join lateral app_private.attendance_rows(t,e.employee_id,today,today) a where e.tenant_id=t and e.employee_id=any(p_ids)),'[]'));
end $$;
alter function public.get_employee_presence(uuid[]) owner to postgres;
revoke all on function public.get_employee_presence(uuid[]) from public,anon;
grant execute on function public.get_employee_presence(uuid[]) to authenticated;
notify pgrst,'reload schema';

-- Explicitly requested normalization of the disposable burner demo fleet only.
alter table public.transits disable trigger transit_crew;
do $$ declare t uuid; actor uuid; previous text:=current_setting('request.jwt.claim.sub',true); v public.vehicles; d uuid; h uuid; n integer:=0; role_name text; eid uuid;
begin
 select tenant_id,user_id into t,actor from public.user_profiles where email='sifatsiam244@gmail.com';
 if t is null then return; end if;
 if exists(select 1 from public.transits where tenant_id=t and (driver_cost<>0 or helper_cost<>0)) or exists(select 1 from public.employee_payments where tenant_id=t and transit_id is not null) then raise exception 'Review demo crew financial evidence before normalization'; end if;
 perform set_config('request.jwt.claim.sub',actor::text,true);
 for v in select * from public.vehicles where tenant_id=t and name like 'Demo %' order by name loop
  n:=n+1;
  foreach role_name in array array['Driver','Helper'] loop
   eid:=(public.save_employee(jsonb_build_object('name',v.name||' '||role_name,'employee_type_name',role_name,'business_unit','truck_business',
    'phones',jsonb_build_array(jsonb_build_object('phone','01890000'||lpad((n*2+case role_name when 'Driver' then 0 else 1 end)::text,3,'0'),'is_primary',true)),
    'terms',jsonb_build_object('monthly_salary',case role_name when 'Driver' then 18000 else 10000 end,'effective_from','2026-10-01','is_active',true)),gen_random_uuid())->>'employee_id')::uuid;
   if role_name='Driver' then d:=eid; else h:=eid; end if;
  end loop;
  perform public.save_vehicle(jsonb_build_object('vehicle_id',v.vehicle_id,'revision',v.revision,'name',v.name,'serial_no',v.serial_no,'capacity',v.capacity,'driver_employee_id',d,'helper_employee_id',h),gen_random_uuid());
  update public.transits set driver_employee_id=d,helper_employee_id=h,driver_name=(select name from public.employees where tenant_id=t and employee_id=d),helper_name=(select name from public.employees where tenant_id=t and employee_id=h),crew_recorded_at=clock_timestamp(),revision=revision+1 where tenant_id=t and vehicle_id=v.vehicle_id and crew_recorded_at is null;
 end loop;
 perform set_config('request.jwt.claim.sub',coalesce(previous,''),true);
end $$;
alter table public.transits enable trigger transit_crew;
