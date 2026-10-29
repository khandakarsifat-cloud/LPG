-- Payment history must remain representable as an actual calendar date.
-- Future-date validation remains in the payment RPC; this also rejects -infinity.
alter table public.employee_payments add constraint employee_payment_date_finite check(isfinite(payment_date));
-- Global month payroll was removed. Employee/month uniqueness already supplies
-- the index needed by employee salary history and direct month allocation.
drop index public.employee_salary_month_directory;

-- Salary corrections may start today, including an employee's joining day.
-- The latest active rate in a month applies to that month unless already fixed.
create or replace function public.save_employee(p_payload jsonb,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('employees:manage'); e public.employees; eid uuid:=(p_payload->>'employee_id')::uuid;
 prior public.finance_requests; payload jsonb:=jsonb_build_object('action','employee_profile','actor',auth.uid(),'body',p_payload);
 ph jsonb; cnt integer:=0; primary_count integer:=0; term public.employee_terms; dt date; salary numeric; active boolean; result jsonb;
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
 select * into e from public.employees where tenant_id=t and employee_id=eid for update;
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
 if term.term_id is not null and active<>term.is_active and dt<(now() at time zone 'Asia/Dhaka')::date then raise exception 'Employment status changes start today or later'; end if;
 insert into public.employee_terms(tenant_id,employee_id,effective_from,monthly_salary,is_active,reason,created_by)
 values(t,eid,dt,salary,active,coalesce(nullif(trim(p_payload->'terms'->>'reason'),''),'Initial employment terms'),auth.uid());
 elsif term.term_id is null then raise exception 'Initial employment terms are required'; end if;
 update public.employees set name=trim(p_payload->>'name'),address=nullif(trim(p_payload->>'address'),''),
 employee_type_id=app_private.resolve_employee_type(t,p_payload->>'employee_type_name'),business_unit=p_payload->>'business_unit',notes=nullif(trim(p_payload->>'notes'),''),
 revision=case when e.employee_id is null then 1 else revision+1 end,updated_at=clock_timestamp() where tenant_id=t and employee_id=eid;
 delete from public.employee_phone_numbers where tenant_id=t and employee_id=eid;
 for ph in select value from jsonb_array_elements(p_payload->'phones') loop
 cnt:=cnt+1; if coalesce((ph->>'is_primary')::boolean,false) then primary_count:=primary_count+1; end if;
 insert into public.employee_phone_numbers(tenant_id,employee_id,phone,is_primary) values(t,eid,trim(ph->>'phone'),coalesce((ph->>'is_primary')::boolean,false)); end loop;
 if primary_count<>1 then raise exception 'Choose exactly one primary phone number'; end if;
 insert into public.employee_activity(tenant_id,employee_id,description,details,created_by) values(t,eid,case when e.employee_id is null then 'Employee created' else 'Profile updated' end,
 jsonb_build_object('before',case when e.employee_id is null then null else to_jsonb(e) end,'after',app_private.employee_summary(t,eid)),auth.uid());
 result:=jsonb_build_object('employee_id',eid);
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,payload,result,auth.uid()); return result;
end $$;

-- A scheduled employee still has a configured salary before their joining day.
create or replace function app_private.employee_summary(t uuid,eid uuid) returns jsonb language sql stable set search_path='' as $$
 select to_jsonb(e)||jsonb_build_object('employee_type_name',et.name,'current_salary',coalesce(tm.monthly_salary,(select monthly_salary from public.employee_terms where tenant_id=t and employee_id=eid order by effective_from,created_at desc,term_id desc limit 1),0),'is_active',coalesce(tm.is_active,false),
 'effective_from',tm.effective_from,'phones',coalesce(ph.phones,'[]'),'primary_phone',ph.primary_phone,
 'joining_date',(select min(effective_from) from public.employee_terms where tenant_id=t and employee_id=eid))
 from public.employees e left join public.employee_types et using(tenant_id,employee_type_id)
 left join lateral (select monthly_salary,is_active,effective_from from public.employee_terms where tenant_id=t and employee_id=eid
 and effective_from<=(now() at time zone 'Asia/Dhaka')::date order by effective_from desc,created_at desc,term_id desc limit 1) tm on true
 left join lateral (select jsonb_agg(jsonb_build_object('phone',phone,'is_primary',is_primary) order by is_primary desc,phone) phones,
 max(phone) filter(where is_primary) primary_phone from public.employee_phone_numbers where tenant_id=t and employee_id=eid) ph on true
 where e.tenant_id=t and e.employee_id=eid;
$$;
