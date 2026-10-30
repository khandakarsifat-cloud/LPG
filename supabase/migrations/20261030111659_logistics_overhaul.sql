-- Canonical fleet naming; IDs, foreign keys, ledger evidence and stock are retained.
drop function public.list_trucks(boolean);
drop function public.create_truck(varchar,varchar,integer,public.truck_size,varchar);
drop function public.update_truck(uuid,varchar,varchar,integer,public.truck_size,public.truck_status,varchar);
alter table public.trucks rename to vehicles;
alter table public.vehicles rename column truck_id to vehicle_id;
alter table public.purchases rename column truck_id to vehicle_id;
alter table public.transits rename column truck_id to vehicle_id;
alter type public.truck_status rename to vehicle_status;
alter table public.vehicles drop column size, drop column location;
drop type public.truck_size;
alter table public.vehicles add column revision integer not null default 1;
alter table public.vehicles drop constraint trucks_capacity_check;
alter table public.vehicles add constraint vehicles_capacity_check check(capacity>=0);

-- Returned journeys can release a vehicle while employee earnings remain due.
-- Completed now has its literal meaning: paid crew and finalized expenses.
alter type public.transit_status rename to obsolete_transit_status;
create type public.transit_status as enum('active','returned','completed','cancelled');
alter table public.transits alter column status drop default;
alter table public.transits alter column status type public.transit_status using
 (case when status::text='completed' and closed_at is null then 'returned' else status::text end)::public.transit_status;
alter table public.transits alter column status set default 'active'::public.transit_status;
drop type public.obsolete_transit_status;

-- Rewrite the current contracts once, rather than leave parallel truck RPCs.
-- Function OIDs/grants/owners and trigger dependencies remain intact.
do $$ declare r record; definition text; begin
 for r in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname in ('public','app_private') and p.prosrc ~ 'trucks|truck_id|truck_name|truck_status' loop
  definition:=pg_get_functiondef(r.oid);
  definition:=replace(replace(replace(replace(definition,'public.trucks','public.vehicles'),'truck_id','vehicle_id'),'truck_name','vehicle_name'),'truck_status','vehicle_status');
  -- Keep trigger function identities while renaming their row fields and labels.
  definition:=replace(replace(definition,'''trucks''','''vehicles'''),'Truck','Vehicle');
  definition:=replace(definition,'FUNCTION app_private.guard_vehicle_idle(', 'FUNCTION app_private.guard_truck_idle(');
  execute definition;
 end loop;
end $$;

do $$ declare definition text; begin
 definition:=pg_get_functiondef('public.receive_purchase(uuid,integer)'::regprocedure);
 if position('set status=''completed''' in definition)=0 then raise exception 'Unexpected purchase receipt contract'; end if;
 definition:=replace(definition,'set status=''completed''','set status=''returned''');
 execute definition;
end $$;



create table public.vehicle_assignments (
 tenant_id uuid not null, assignment_id uuid primary key default gen_random_uuid(),
 vehicle_id uuid not null, employee_id uuid not null, role text not null check(role in ('driver','helper')),
 employee_name text not null, started_at timestamptz not null default clock_timestamp(), ended_at timestamptz,
 created_by uuid references auth.users(id), ended_by uuid references auth.users(id),
 foreign key(tenant_id,vehicle_id) references public.vehicles(tenant_id,vehicle_id),
 foreign key(tenant_id,employee_id) references public.employees(tenant_id,employee_id),
 check(ended_at is null or ended_at>=started_at)
);
create unique index vehicle_current_role on public.vehicle_assignments(tenant_id,vehicle_id,role) where ended_at is null;
create unique index employee_current_vehicle on public.vehicle_assignments(tenant_id,employee_id) where ended_at is null;
create index vehicle_assignment_history on public.vehicle_assignments(tenant_id,vehicle_id,started_at desc,assignment_id);
create index employee_assignment_history on public.vehicle_assignments(tenant_id,employee_id,started_at desc,assignment_id);
alter table public.vehicle_assignments enable row level security;
revoke all on public.vehicle_assignments from public,anon,authenticated;
grant select on public.vehicle_assignments to authenticated;
create policy assignments_read on public.vehicle_assignments for select to authenticated using (
 tenant_id=(select app_private.current_tenant_id()) and
 (select app_private.has_any_permission(array['logistics:view','logistics:manage','employees:view','employees:manage','payroll:view','payroll:pay'])));

alter table public.transits add column driver_employee_id uuid, add column helper_employee_id uuid,
 add column driver_name text, add column helper_name text, add column crew_recorded_at timestamptz,
 add foreign key(tenant_id,driver_employee_id) references public.employees(tenant_id,employee_id),
 add foreign key(tenant_id,helper_employee_id) references public.employees(tenant_id,employee_id),
 add check(driver_employee_id is null or helper_employee_id is distinct from driver_employee_id);
create index transit_vehicle_history on public.transits(tenant_id,vehicle_id,created_at desc,transit_id);
create index transit_driver_history on public.transits(tenant_id,driver_employee_id,created_at desc,transit_id);
create index transit_helper_history on public.transits(tenant_id,helper_employee_id,created_at desc,transit_id);
create index transit_directory on public.transits(tenant_id,created_at desc,transit_id);
create index transit_payment_role on public.employee_payments(tenant_id,transit_id,trip_role);

-- Only known payment evidence may identify an earlier participant. Never use
-- today's vehicle assignment to attribute a historical trip.
update public.transits tr set driver_employee_id=q.employee_id,driver_name=q.name
from (select p.tenant_id,p.transit_id,min(p.employee_id::text)::uuid employee_id,min(e.name) name
 from public.employee_payments p join public.employees e using(tenant_id,employee_id)
 where p.trip_role='driver' group by p.tenant_id,p.transit_id having count(distinct p.employee_id)=1) q
where tr.tenant_id=q.tenant_id and tr.transit_id=q.transit_id;
update public.transits tr set helper_employee_id=q.employee_id,helper_name=q.name
from (select p.tenant_id,p.transit_id,min(p.employee_id::text)::uuid employee_id,min(e.name) name
 from public.employee_payments p join public.employees e using(tenant_id,employee_id)
 where p.trip_role='helper' group by p.tenant_id,p.transit_id having count(distinct p.employee_id)=1) q
where tr.tenant_id=q.tenant_id and tr.transit_id=q.transit_id;

create function app_private.validate_vehicle_employee(t uuid,eid uuid,role_name text) returns void
language plpgsql set search_path='' as $$ begin
 if eid is not null and not exists(select 1 from public.employees e join public.employee_types et using(tenant_id,employee_type_id)
  where e.tenant_id=t and e.employee_id=eid and lower(et.name)=role_name and et.is_active
  and coalesce((select r.is_active from public.employee_terms r where r.tenant_id=t and r.employee_id=eid
   and r.effective_from<=(now() at time zone 'Asia/Dhaka')::date order by r.effective_from desc,r.created_at desc,r.term_id desc limit 1),false)) then
  raise exception 'Select an active employee with the % role',role_name;
 end if;
end $$;

create function public.save_vehicle(p_payload jsonb,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('logistics:manage'); v public.vehicles; a public.vehicle_assignments;
 id uuid:=nullif(p_payload->>'vehicle_id','')::uuid; driver uuid:=nullif(p_payload->>'driver_employee_id','')::uuid;
 helper uuid:=nullif(p_payload->>'helper_employee_id','')::uuid; v_capacity numeric:=(p_payload->>'capacity')::numeric;
 prior public.finance_requests; body jsonb:=jsonb_build_object('action','save_vehicle','actor',auth.uid(),'body',p_payload); result jsonb; role_name text; eid uuid;
begin
 if p_request_id is null or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'Vehicle details and request ID are required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload<>body then raise exception 'Request ID was already used with different details'; end if; return prior.result; end if;
 if nullif(trim(p_payload->>'name'),'') is null or length(p_payload->>'name')>100 or nullif(trim(p_payload->>'serial_no'),'') is null or length(p_payload->>'serial_no')>100
  or v_capacity is null or v_capacity::text in ('NaN','Infinity','-Infinity') or v_capacity<0 or v_capacity>2147483647 or v_capacity<>trunc(v_capacity) then raise exception 'Name, serial number and a nonnegative whole capacity are required'; end if;
 if driver is not null and driver=helper then raise exception 'Choose different driver and helper employees'; end if;
 -- Serialize assignment changes per tenant before vehicle -> employee locks.
 perform pg_advisory_xact_lock(hashtextextended(t::text||':vehicle_assignments',0));
 if id is null then
  insert into public.vehicles(tenant_id,name,serial_no,capacity,status) values(t,trim(p_payload->>'name'),trim(p_payload->>'serial_no'),v_capacity,'idle') returning * into v;
  id:=v.vehicle_id;
 else
  select * into v from public.vehicles where tenant_id=t and vehicle_id=id for update;
  if not found then raise exception 'Vehicle not found'; end if;
  if v.revision is distinct from (p_payload->>'revision')::integer then raise exception 'Vehicle changed. Reload before saving.'; end if;
 end if;
 perform 1 from public.employees where tenant_id=t and employee_id in (driver,helper) order by employee_id for update;
 foreach role_name in array array['driver','helper'] loop
  eid:=case role_name when 'driver' then driver else helper end;
  select * into a from public.vehicle_assignments where tenant_id=t and vehicle_id=id and role=role_name and ended_at is null;
  if a.employee_id is not distinct from eid then continue; end if;
  perform app_private.validate_vehicle_employee(t,eid,role_name);
  if exists(select 1 from public.vehicle_assignments where tenant_id=t and employee_id=eid and ended_at is null and vehicle_id<>id) then raise exception 'Employee is assigned to another vehicle. Unlink that assignment first.'; end if;
  update public.vehicle_assignments set ended_at=clock_timestamp(),ended_by=auth.uid() where assignment_id=a.assignment_id;
  if eid is not null then insert into public.vehicle_assignments(tenant_id,vehicle_id,employee_id,role,employee_name,created_by)
   select t,id,eid,role_name,name,auth.uid() from public.employees where tenant_id=t and employee_id=eid; end if;
 end loop;
 update public.vehicles set name=trim(p_payload->>'name'),serial_no=trim(p_payload->>'serial_no'),capacity=v_capacity::integer,revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and vehicle_id=id;
 result:=jsonb_build_object('vehicle_id',id);
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());
 return result;
end $$;

create function app_private.capture_transit_crew() returns trigger language plpgsql set search_path='' as $$
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
create trigger transit_crew before insert or update on public.transits for each row execute function app_private.capture_transit_crew();

-- Purchase receipt marks the journey returned and releases the vehicle. Final
-- completion (closed_at) is shared with custom journeys and requires paid crew.
create or replace function public.transition_transit(p_transit_id uuid,p_action text,p_revision integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('logistics:manage'); tr public.transits; pid uuid; wid uuid; refund numeric; other_cost numeric;
begin
 select purchase_id into pid from public.transits where tenant_id=t and transit_id=p_transit_id;
 if pid is not null then perform 1 from public.purchases where tenant_id=t and purchase_id=pid for update; end if;
 select * into tr from public.transits where tenant_id=t and transit_id=p_transit_id;
 if not found then raise exception 'Transit not found'; end if;
 perform 1 from public.vehicles where tenant_id=t and vehicle_id=tr.vehicle_id for update;
 select * into tr from public.transits where tenant_id=t and transit_id=p_transit_id for update;
 if p_action is null or p_action not in ('complete','return','cancel') then raise exception 'Invalid transit action'; end if;
 if p_action='complete' and tr.closed_at is not null or p_action='cancel' and tr.status='cancelled' or p_action='return' and tr.status='returned' then return jsonb_build_object('already_applied',true); end if;
 if tr.closed_at is not null then raise exception 'Completed transit is locked'; end if;
 if p_revision is distinct from tr.revision then raise exception 'Transit changed. Reload before continuing.'; end if;
 if pid is not null and (p_action in ('return','cancel') or tr.status='active') then raise exception 'Receive or cancel this shipment in Purchases before completing its transit'; end if;
 if p_action='return' and tr.status<>'active' then raise exception 'Only an active journey can return'; end if;
 if p_action='complete' then
  if tr.driver_cost>app_private.transit_employee_paid(t,p_transit_id,'driver') or tr.helper_cost>app_private.transit_employee_paid(t,p_transit_id,'helper') then raise exception 'Pay all outstanding driver and helper earnings before completing this transit'; end if;
 end if;
 perform app_private.ensure_tenant_wallets(t);
 select wallet_id into wid from public.wallets where tenant_id=t and type='logistics' for update;
 if p_action='cancel' then
  select coalesce(sum(amount),0) into refund from public.wallet_transactions where tenant_id=t and wallet_id=wid and reference_id=p_transit_id and type='transport_income';
  if refund>0 then insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description)
   values(t,wid,-refund,'transit_client_refund',p_transit_id,'Full transport fee refunded to client'); end if;
  update public.transits set status='cancelled',revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and transit_id=p_transit_id;
 elsif p_action='return' then
  update public.transits set status='returned',revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and transit_id=p_transit_id;
 else
  -- Employee earnings have already been posted through canonical payroll.
  -- Only non-employee operating expenses are posted here, exactly once.
  other_cost:=tr.total_cost-tr.driver_cost-tr.helper_cost;
  if other_cost>0 then insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description)
   values(t,wid,-other_cost,'transit_close_cost',p_transit_id,'Non-employee transit operating costs on completion'); end if;
  update public.transits set status=case when status='cancelled' then status else 'completed' end,closed_at=clock_timestamp(),revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and transit_id=p_transit_id;
 end if;
 if not exists(select 1 from public.transits where tenant_id=t and vehicle_id=tr.vehicle_id and status='active')
  and not exists(select 1 from public.purchases where tenant_id=t and vehicle_id=tr.vehicle_id and status='in_transit') then
  update public.vehicles set status='idle',updated_at=clock_timestamp() where tenant_id=t and vehicle_id=tr.vehicle_id;
 end if;
 if pid is not null then insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
  values(t,pid,'transit_closed',auth.uid(),jsonb_build_object('transit_id',p_transit_id,'operating_cost',tr.total_cost,'employee_earnings',tr.driver_cost+tr.helper_cost)); end if;
 return jsonb_build_object('transit_id',p_transit_id);
end $$;

-- Retain the canonical, idempotent employee payment/reversal operation. Enforce
-- payment to the participant captured at departure, independent of reassignment.
do $$ declare definition text; marker text:='if total+app_private.transit_employee_paid(t,tid,role_name)>'; begin
 definition:=pg_get_functiondef('public.employee_payment_operation(jsonb,uuid)'::regprocedure);
 if position(marker in definition)=0 then raise exception 'Unexpected employee payment contract'; end if;
 definition:=replace(definition,marker,'if eid is distinct from (case role_name when ''driver'' then tr.driver_employee_id else tr.helper_employee_id end) then raise exception ''Pay the employee recorded on this transit''; end if;'||E'\n '||marker);
 execute definition;
end $$;

-- Custom creation uses the same recoverable request registry as financial writes.
drop function public.create_custom_transit(jsonb);
create function public.create_custom_transit(p_payload jsonb,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('logistics:manage'); vehicle public.vehicles; id uuid; wid uuid;
 fee numeric:=app_private.purchase_money((p_payload->>'fee')::numeric); prior public.finance_requests;
 body jsonb:=jsonb_build_object('action','custom_transit','actor',auth.uid(),'body',p_payload); result jsonb;
begin
 if p_request_id is null or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'Transit details and request ID are required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload<>body then raise exception 'Request ID was already used with different details'; end if; return prior.result; end if;
 select * into vehicle from public.vehicles where tenant_id=t and vehicle_id=(p_payload->>'vehicle_id')::uuid for update;
 if not found or vehicle.status<>'idle' then raise exception 'Select a vehicle at Home'; end if;
 if nullif(trim(p_payload->>'client_name'),'') is null or length(p_payload->>'client_name')>200 or nullif(trim(p_payload->>'destination'),'') is null or length(p_payload->>'destination')>300 or length(p_payload->>'description')>1000 then raise exception 'Client and destination are required (up to 200 and 300 characters)'; end if;
 insert into public.transits(tenant_id,vehicle_id,status,transport_fee,client_name,destination,description)
  values(t,vehicle.vehicle_id,'active',fee,trim(p_payload->>'client_name'),trim(p_payload->>'destination'),p_payload->>'description') returning transit_id into id;
 update public.vehicles set status='going',updated_at=clock_timestamp() where tenant_id=t and vehicle_id=vehicle.vehicle_id;
 perform app_private.ensure_tenant_wallets(t);
 select wallet_id into wid from public.wallets where tenant_id=t and type='logistics' for update;
 if fee>0 then insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description) values(t,wid,fee,'transport_income',id,'Custom transit client fee'); end if;
 result:=jsonb_build_object('transit_id',id);
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid()); return result;
end $$;

create function app_private.vehicle_json(t uuid,id uuid) returns jsonb language sql stable set search_path='' as $$
 select to_jsonb(v)||jsonb_build_object('location',coalesce((select coalesce(nullif(tr.destination,''),'In transit') from public.transits tr where tr.tenant_id=t and tr.vehicle_id=id and tr.status='active' order by created_at desc,transit_id limit 1),'Home'),
 'driver_employee_id',d.employee_id,'driver_name',d.employee_name,'helper_employee_id',h.employee_id,'helper_name',h.employee_name)
 from public.vehicles v
 left join public.vehicle_assignments d on d.tenant_id=t and d.vehicle_id=id and d.role='driver' and d.ended_at is null
 left join public.vehicle_assignments h on h.tenant_id=t and h.vehicle_id=id and h.role='helper' and h.ended_at is null
 where v.tenant_id=t and v.vehicle_id=id;
$$;

create function public.list_vehicles() returns setof jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['logistics:view','logistics:manage','purchases:view','purchases:manage']); begin
 return query select app_private.vehicle_json(t,v.vehicle_id) from public.vehicles v where v.tenant_id=t order by v.name,v.vehicle_id;
end $$;
create function public.get_vehicle_directory(p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 25) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['logistics:view','logistics:manage']); result jsonb; begin
 if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 or length(coalesce(p_filters->>'search',''))>500 or coalesce(p_filters->>'status','all') not in ('all','home','away','unassigned') then raise exception 'Invalid vehicle filters'; end if;
 with matching as materialized (select v.* from public.vehicles v where v.tenant_id=t
  and (coalesce(p_filters->>'status','all')='all' or p_filters->>'status'='home' and v.status='idle' or p_filters->>'status'='away' and v.status<>'idle'
   or p_filters->>'status'='unassigned' and not exists(select 1 from public.vehicle_assignments a where a.tenant_id=t and a.vehicle_id=v.vehicle_id and a.role='driver' and a.ended_at is null))
  and app_private.finance_search(concat_ws(' ',v.name,v.serial_no,(select string_agg(a.employee_name,' ') from public.vehicle_assignments a where a.tenant_id=t and a.vehicle_id=v.vehicle_id and a.ended_at is null)),coalesce(p_filters->>'search',''))),
 page as (select * from matching order by name,vehicle_id offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(app_private.vehicle_json(t,p.vehicle_id) order by p.name,p.vehicle_id) from page p),'[]')) into result;
 return result;
end $$;
create function public.get_vehicle(p_vehicle_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['logistics:view','logistics:manage']); result jsonb; begin
 result:=app_private.vehicle_json(t,p_vehicle_id); if result is null then raise exception 'Vehicle not found'; end if; return result;
end $$;

create function app_private.transit_json(t uuid,id uuid) returns jsonb language sql stable set search_path='' as $$
 select to_jsonb(tr)||jsonb_build_object('vehicle_name',v.name,'driver_paid',app_private.transit_employee_paid(t,id,'driver'),
 'helper_paid',app_private.transit_employee_paid(t,id,'helper'),
 'outstanding',case when tr.closed_at is not null then 0 else greatest(0,tr.driver_cost-app_private.transit_employee_paid(t,id,'driver'))+greatest(0,tr.helper_cost-app_private.transit_employee_paid(t,id,'helper')) end,
 'purchase_refund_due',p.refund_due,'purchase_financial_closed_at',p.financial_closed_at)
 from public.transits tr join public.vehicles v using(tenant_id,vehicle_id)
 left join public.purchases p on p.tenant_id=t and p.purchase_id=tr.purchase_id where tr.tenant_id=t and tr.transit_id=id;
$$;
drop function public.list_transits();
create function public.get_transit(p_transit_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['logistics:view','logistics:manage']); result jsonb; begin
 result:=app_private.transit_json(t,p_transit_id); if result is null then raise exception 'Transit not found'; end if; return result;
end $$;
create function public.get_transit_directory(p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 25) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['logistics:view','logistics:manage','employees:view','employees:manage','payroll:view','payroll:pay']);
 eid uuid:=nullif(p_filters->>'employee_id','')::uuid; vid uuid:=nullif(p_filters->>'vehicle_id','')::uuid;
 state text:=coalesce(p_filters->>'status','all'); ordering text:=coalesce(p_filters->>'sort','date_desc');
 f date:=nullif(p_filters->>'from','')::date; until date:=nullif(p_filters->>'to','')::date; result jsonb;
begin
 if not app_private.has_any_permission(array['logistics:view','logistics:manage']) and eid is null then raise exception 'Choose an employee'; end if;
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 or length(coalesce(p_filters->>'search',''))>500 or f>until
  or state not in ('all','active','returned','completed','cancelled','outstanding') or ordering not in ('date_desc','date_asc') or coalesce(p_filters->>'type','all') not in ('all','purchase','custom') then raise exception 'Invalid transit filters'; end if;
 with matching as materialized (select tr.transit_id,tr.created_at from public.transits tr join public.vehicles v using(tenant_id,vehicle_id)
  where tr.tenant_id=t and (vid is null or tr.vehicle_id=vid) and (eid is null or eid in (tr.driver_employee_id,tr.helper_employee_id))
   and (f is null or tr.created_at>=f::timestamp at time zone 'Asia/Dhaka') and (until is null or tr.created_at<(until+1)::timestamp at time zone 'Asia/Dhaka')
   and (coalesce(p_filters->>'type','all')='all' or p_filters->>'type'='purchase' and tr.purchase_id is not null or p_filters->>'type'='custom' and tr.purchase_id is null)
   and (state='all' or state='active' and tr.status='active' or state='returned' and tr.status='returned'
    or state='completed' and tr.closed_at is not null or state='cancelled' and tr.status='cancelled'
    or state='outstanding' and tr.closed_at is null and (tr.driver_cost>app_private.transit_employee_paid(t,tr.transit_id,'driver') or tr.helper_cost>app_private.transit_employee_paid(t,tr.transit_id,'helper')))
   and app_private.finance_search(concat_ws(' ',v.name,v.serial_no,tr.transit_id,tr.client_name,tr.destination,tr.description,tr.driver_name,tr.helper_name),coalesce(p_filters->>'search',''))),
 page as (select * from matching order by case when ordering='date_desc' then created_at end desc,case when ordering='date_asc' then created_at end,transit_id desc offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(app_private.transit_json(t,p.transit_id) order by case when ordering='date_desc' then p.created_at end desc,case when ordering='date_asc' then p.created_at end,p.transit_id desc) from page p),'[]')) into result;
 return result;
end $$;

create function public.get_vehicle_assignments(p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 12) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['logistics:view','logistics:manage','employees:view','employees:manage','payroll:view','payroll:pay']);
 eid uuid:=nullif(p_filters->>'employee_id','')::uuid; vid uuid:=nullif(p_filters->>'vehicle_id','')::uuid; result jsonb;
 f date:=nullif(p_filters->>'from','')::date; until date:=nullif(p_filters->>'to','')::date;
begin
 if not app_private.has_any_permission(array['logistics:view','logistics:manage']) and eid is null then raise exception 'Choose an employee'; end if;
 if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 or f>until or length(coalesce(p_filters->>'search',''))>500 or coalesce(p_filters->>'status','all') not in ('all','current','ended') then raise exception 'Invalid assignment filters'; end if;
 with matching as materialized (select a.*,v.name vehicle_name from public.vehicle_assignments a join public.vehicles v using(tenant_id,vehicle_id)
  where a.tenant_id=t and (eid is null or a.employee_id=eid) and (vid is null or a.vehicle_id=vid)
   and (f is null or a.started_at>=f::timestamp at time zone 'Asia/Dhaka') and (until is null or a.started_at<(until+1)::timestamp at time zone 'Asia/Dhaka')
   and (coalesce(p_filters->>'status','all')='all' or p_filters->>'status'='current' and a.ended_at is null or p_filters->>'status'='ended' and a.ended_at is not null)
   and app_private.finance_search(concat_ws(' ',a.employee_name,a.role,v.name),coalesce(p_filters->>'search',''))),
 page as (select * from matching order by started_at desc,assignment_id desc offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(to_jsonb(p) order by started_at desc,assignment_id desc) from page p),'[]')) into result; return result;
end $$;

create function public.get_logistics_summary(p_vehicle_id uuid default null,p_employee_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['logistics:view','logistics:manage','employees:view','employees:manage','payroll:view','payroll:pay']); result jsonb;
begin
 if not app_private.has_any_permission(array['logistics:view','logistics:manage']) and p_employee_id is null then raise exception 'Choose an employee'; end if;
 with trips as (select tr.*,case when p_employee_id is null then tr.driver_cost+tr.helper_cost
  when p_employee_id=tr.driver_employee_id then tr.driver_cost else tr.helper_cost end earnings,
  app_private.transit_employee_paid(t,tr.transit_id,case when p_employee_id is null then null when p_employee_id=tr.driver_employee_id then 'driver' else 'helper' end) paid
  from public.transits tr where tr.tenant_id=t and (p_vehicle_id is null or tr.vehicle_id=p_vehicle_id) and (p_employee_id is null or p_employee_id in (tr.driver_employee_id,tr.helper_employee_id)))
 select jsonb_build_object('transits',count(*),'active',count(*) filter(where status='active'),'awaiting_completion',count(*) filter(where closed_at is null),
  'earnings',coalesce(sum(earnings),0),'paid',coalesce(sum(paid),0),'outstanding',coalesce(sum(greatest(0,earnings-paid)) filter(where closed_at is null),0),
  'transport_fees',coalesce(sum(transport_fee),0),'operating_costs',coalesce(sum(total_cost),0),
  'vehicles',(select count(*) from public.vehicles where tenant_id=t),'home',(select count(*) from public.vehicles where tenant_id=t and status='idle')) into result from trips;
 return result||jsonb_build_object('assignments',(select count(*) from public.vehicle_assignments where tenant_id=t and employee_id=p_employee_id),'current_vehicle',(select v.name from public.vehicle_assignments a join public.vehicles v using(tenant_id,vehicle_id) where a.tenant_id=t and a.employee_id=p_employee_id and a.ended_at is null));
end $$;

-- New routines use the established owner and explicit grants. Internal helpers
-- remain inaccessible to browsers; all externally callable reads derive tenancy.
do $$ declare r record; begin
 for r in select p.oid,n.nspname,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname in ('public','app_private') and p.proname in ('save_vehicle','list_vehicles','get_vehicle_directory','get_vehicle','get_transit','get_transit_directory','get_vehicle_assignments','get_logistics_summary','vehicle_json','transit_json','validate_vehicle_employee','capture_transit_crew','create_custom_transit') loop
  execute format('alter function %s owner to postgres',r.oid::regprocedure);
  execute format('revoke all on function %s from public,anon,authenticated',r.oid::regprocedure);
  if r.nspname='public' then execute format('grant execute on function %s to authenticated',r.oid::regprocedure); end if;
 end loop;
end $$;
alter table public.vehicle_assignments owner to postgres;

create or replace function public.get_transit_payroll(p_transit_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['logistics:view','logistics:manage']); begin
 if not exists(select 1 from public.transits where tenant_id=t and transit_id=p_transit_id) then raise exception 'Transit not found'; end if;
 return jsonb_build_object('driver_paid',app_private.transit_employee_paid(t,p_transit_id,'driver'),'helper_paid',app_private.transit_employee_paid(t,p_transit_id,'helper'),'paid',app_private.transit_employee_paid(t,p_transit_id));
end $$;
create function public.get_transit_payments(p_transit_id uuid,p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 8) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['payroll:view','payroll:pay']); result jsonb;
begin
 if not exists(select 1 from public.transits where tenant_id=t and transit_id=p_transit_id) then raise exception 'Transit not found'; end if;
 if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 or length(coalesce(p_filters->>'search',''))>500 or coalesce(p_filters->>'role','all') not in ('all','driver','helper') then raise exception 'Invalid payment filters'; end if;
 with matching as materialized (select p.payment_id,p.employee_id,e.name,p.trip_role role,p.payment_date date,p.created_at,p.description,
  case when p.reversal_of is null then p.amount else -p.amount end amount,p.reversal_of,
  (select jsonb_agg(jsonb_build_object('wallet_name',pe.wallet_name,'method',pe.method,'amount',pe.amount,'reference',pe.reference) order by pe.entry_id) from public.employee_payment_entries pe where pe.tenant_id=t and pe.payment_id=p.payment_id) wallets
  from public.employee_payments p join public.employees e using(tenant_id,employee_id) where p.tenant_id=t and p.transit_id=p_transit_id
   and (coalesce(p_filters->>'role','all')='all' or p.trip_role=p_filters->>'role')
   and (nullif(p_filters->>'from','') is null or p.payment_date>=(p_filters->>'from')::date)
   and (nullif(p_filters->>'to','') is null or p.payment_date<=(p_filters->>'to')::date)
   and app_private.finance_search(concat_ws(' ',e.name,p.description,p.payment_id,p.trip_role),coalesce(p_filters->>'search',''))),
 page as (select * from matching order by created_at desc,payment_id desc offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(to_jsonb(p) order by created_at desc,payment_id desc) from page p),'[]')) into result; return result;
end $$;
alter function public.get_transit_payments(uuid,jsonb,integer,integer) owner to postgres;
revoke all on function public.get_transit_payments(uuid,jsonb,integer,integer) from public,anon;
grant execute on function public.get_transit_payments(uuid,jsonb,integer,integer) to authenticated;
alter function app_private.audit_trucks() rename to audit_vehicles;
alter function app_private.guard_truck_idle() rename to guard_vehicle_idle;
alter trigger trg_audit_trucks on public.vehicles rename to trg_audit_vehicles;
alter trigger guard_truck_idle on public.vehicles rename to guard_vehicle_idle;
notify pgrst,'reload schema';
