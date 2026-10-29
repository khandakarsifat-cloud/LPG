-- Replace development payroll with employee salary months and named payments.
-- Preserve every wallet movement, payment identity and unrelated business fact.
create temporary table employee_redesign_preservation as select
 (select md5(coalesce(jsonb_agg(to_jsonb(w) order by tenant_id,wallet_id)::text,'')) from public.wallets w) wallets,
 (select md5(coalesce(jsonb_agg(to_jsonb(w) order by tenant_id,transaction_id)::text,'')) from public.wallet_transactions w) ledger,
 (select md5(coalesce(jsonb_agg(to_jsonb(i) order by tenant_id,item_id)::text,'')) from public.items i) stock;
drop function public.payroll_operation(jsonb,uuid);
drop function public.get_employee_directory(jsonb,date,integer,integer);
drop function public.get_employee_overview(date);
drop function public.get_employee_periods(uuid,integer,integer);
drop function app_private.prepare_employee_payroll(uuid,uuid,date);
drop function app_private.employee_advance_remaining(uuid,uuid);
drop function app_private.payroll_balance(uuid,uuid);

-- Retain retired adjustment evidence in the existing immutable activity stream.
insert into public.employee_activity(tenant_id,employee_id,description,details,created_by,created_at)
 select a.tenant_id,o.employee_id,'Previous salary correction · '||a.reason,to_jsonb(a),a.created_by,a.created_at
 from public.payroll_adjustments a join public.payroll_obligations o using(tenant_id,obligation_id);
alter table public.payroll_obligations disable trigger immutable_employee_record;
update public.payroll_obligations o set base_amount=base_amount+coalesce((select sum(amount) from public.payroll_adjustments a where a.tenant_id=o.tenant_id and a.obligation_id=o.obligation_id),0),
 calculation=calculation||jsonb_build_object('normalization','Previous net salary payable retained; obsolete adjustments archived in activity');
alter table public.payroll_obligations enable trigger immutable_employee_record;
drop table public.payroll_adjustments;
alter table public.payroll_obligations rename to employee_salary_months;
alter table public.employee_salary_months rename column obligation_id to salary_month_id;
alter table public.employee_salary_months rename column base_amount to salary_amount;
alter table public.employee_payments rename column obligation_id to salary_month_id;
alter table public.employee_payments add column bonus_name text;
alter table public.employee_payments drop constraint employee_payment_kind;
alter table public.employee_payments disable trigger immutable_employee_payment;
update public.employee_payments set bonus_name=coalesce(nullif(source_snapshot->>'category_name',''),initcap(kind)) where kind not in ('salary','trips');
update public.employee_payments set kind='bonus' where kind not in ('salary','bonus','trips');
alter table public.employee_payments enable trigger immutable_employee_payment;
alter table public.employee_payments add constraint employee_payment_kind check(kind in ('salary','bonus','trips')),
 add constraint employee_bonus_name check((kind='bonus' and length(trim(bonus_name)) between 1 and 120) or (kind<>'bonus' and bonus_name is null));
-- Same-day corrections append revisions, with the newest revision authoritative.
alter table public.employee_terms drop constraint employee_terms_tenant_id_employee_id_effective_from_key;
alter index public.payroll_period_directory rename to employee_salary_month_directory;
alter index public.employee_payment_obligation rename to employee_payment_salary_month;
alter table public.employee_payments rename constraint employee_payment_obligation_fk to employee_payment_salary_month_fk;
create index employee_terms_timeline on public.employee_terms(tenant_id,employee_id,effective_from desc,created_at desc,term_id desc);

create or replace function app_private.employee_summary(t uuid,eid uuid) returns jsonb language sql stable set search_path='' as $$
 select to_jsonb(e)||jsonb_build_object('employee_type_name',et.name,'current_salary',coalesce(tm.monthly_salary,0),'is_active',coalesce(tm.is_active,false),
 'effective_from',tm.effective_from,'phones',coalesce(ph.phones,'[]'),'primary_phone',ph.primary_phone,
 'joining_date',(select min(effective_from) from public.employee_terms where tenant_id=t and employee_id=eid))
 from public.employees e left join public.employee_types et using(tenant_id,employee_type_id)
 left join lateral (select monthly_salary,is_active,effective_from from public.employee_terms where tenant_id=t and employee_id=eid
 and effective_from<=(now() at time zone 'Asia/Dhaka')::date order by effective_from desc,created_at desc,term_id desc limit 1) tm on true
 left join lateral (select jsonb_agg(jsonb_build_object('phone',phone,'is_primary',is_primary) order by is_primary desc,phone) phones,
 max(phone) filter(where is_primary) primary_phone from public.employee_phone_numbers where tenant_id=t and employee_id=eid) ph on true
 where e.tenant_id=t and e.employee_id=eid;
$$;
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
 if term.term_id is not null and salary<>term.monthly_salary and extract(day from dt)<>1 then raise exception 'Salary revisions start on the first day of a month'; end if;
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
-- A full monthly rate applies when employment overlaps the month. No daily payroll.
create function app_private.employee_month_rate(t uuid,eid uuid,month date) returns numeric
language sql stable set search_path='' as $$
 with revisions as (select distinct on(effective_from) effective_from,monthly_salary,is_active
 from public.employee_terms where tenant_id=t and employee_id=eid
 order by effective_from,created_at desc,term_id desc),
 segments as (select *,lead(effective_from,1,'infinity'::date) over(order by effective_from) ends from revisions)
 select coalesce((select monthly_salary from segments where is_active and effective_from<month+interval '1 month' and ends>month
 order by effective_from desc limit 1),0);
$$;
create function app_private.employee_month_balance(t uuid,eid uuid,month date) returns jsonb
language sql stable set search_path='' as $$
 with salary as (select coalesce((select salary_amount from public.employee_salary_months where tenant_id=t and employee_id=eid and period=month),
 app_private.employee_month_rate(t,eid,month)) amount),
 paid as (select coalesce(sum(case when p.reversal_of is null then p.amount else -p.amount end),0) amount
 from public.employee_payments p join public.employee_salary_months m using(tenant_id,salary_month_id)
 where p.tenant_id=t and p.employee_id=eid and m.period=month)
 select jsonb_build_object('period',month,'salary_amount',salary.amount,'paid',paid.amount,'outstanding',salary.amount-paid.amount,
 'established',exists(select 1 from public.employee_salary_months where tenant_id=t and employee_id=eid and period=month)) from salary cross join paid;
$$;
create function public.get_employee_salary_month(p_employee_id uuid,p_period date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['payroll:view','payroll:pay']);
begin
 perform app_private.payroll_month(p_period);
 if not exists(select 1 from public.employees where tenant_id=t and employee_id=p_employee_id) then raise exception 'Employee not found'; end if;
 return app_private.employee_month_balance(t,p_employee_id,p_period);
end $$;
create function public.get_employee_directory(p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 25) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['employees:view','employees:manage','payroll:view','payroll:pay']); result jsonb;
 sorting text:=coalesce(p_filters->>'sort','name_asc');
begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 or length(coalesce(p_filters->>'search',''))>500
 or sorting not in ('name_asc','name_desc','salary_desc','salary_asc','joined_desc')
 or coalesce(p_filters->>'status','all') not in ('all','active','inactive')
 or coalesce(p_filters->>'unit','all') not in ('all','gas_business','truck_business') then raise exception 'Invalid employee filters or page'; end if;
 with profiles as materialized(select app_private.employee_summary(t,employee_id) row from public.employees where tenant_id=t),
 matching as materialized(select row from profiles
 where (coalesce(p_filters->>'status','all')='all' or (row->>'is_active')::boolean=(p_filters->>'status'='active'))
 and (coalesce(p_filters->>'unit','all')='all' or row->>'business_unit'=p_filters->>'unit')
 and (nullif(p_filters->>'type','') is null or row->>'employee_type_name'=p_filters->>'type')
 and app_private.employee_search(concat_ws(' ',row->>'name',row->>'address',row->>'employee_type_name',row->'phones',row->>'notes'),p_filters->>'search')),
 page as(select row from matching order by
 case when sorting='name_asc' then lower(row->>'name') end asc,
 case when sorting='name_desc' then lower(row->>'name') end desc,
 case when sorting='salary_desc' then (row->>'current_salary')::numeric end desc,
 case when sorting='salary_asc' then (row->>'current_salary')::numeric end asc,
 case when sorting='joined_desc' then row->>'joining_date' end desc,row->>'name',row->>'employee_id' offset p_offset limit p_limit)
 select jsonb_build_object('entries',coalesce((select jsonb_agg(row) from page),'[]'),'total',(select count(*) from matching)) into result;
 return result;
end $$;
create function public.get_employee_overview() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['employees:view','employees:manage','payroll:view','payroll:pay']);
begin
 return jsonb_build_object('employees',(select count(*) from public.employees where tenant_id=t),
 'active',(select count(*) from public.employees where tenant_id=t and (app_private.employee_summary(t,employee_id)->>'is_active')::boolean),
 'types',(select coalesce(jsonb_agg(name order by name),'[]') from public.employee_types where tenant_id=t and is_active));
end $$;
create or replace function public.get_employee_profile(p_employee_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['employees:view','employees:manage','payroll:view','payroll:pay']); employee jsonb;
begin
 employee:=app_private.employee_summary(t,p_employee_id); if employee is null then raise exception 'Employee not found'; end if;
 return jsonb_build_object('employee',employee,'terms',(select coalesce(jsonb_agg(to_jsonb(tm) order by effective_from desc,created_at desc,term_id desc),'[]')
 from (select * from public.employee_terms where tenant_id=t and employee_id=p_employee_id order by effective_from desc,created_at desc,term_id desc limit 24) tm));
end $$;
create function public.get_employee_salary_history(p_employee_id uuid,p_offset integer default 0,p_limit integer default 6) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['payroll:view','payroll:pay']); result jsonb; first_month date; last_month date;
begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 50 then raise exception 'Invalid salary page'; end if;
 if not exists(select 1 from public.employees where tenant_id=t and employee_id=p_employee_id) then raise exception 'Employee not found'; end if;
 select least(min(date_trunc('month',effective_from)::date),(select min(period) from public.employee_salary_months where tenant_id=t and employee_id=p_employee_id)) into first_month from public.employee_terms where tenant_id=t and employee_id=p_employee_id;
 select greatest(date_trunc('month',now() at time zone 'Asia/Dhaka')::date,max(period)) into last_month from public.employee_salary_months where tenant_id=t and employee_id=p_employee_id;
 with months as(select d::date period from generate_series(first_month::timestamp,last_month::timestamp,interval '1 month') d),
 matching as materialized(select app_private.employee_month_balance(t,p_employee_id,period) row from months),
 page as(select row from matching order by row->>'period' desc offset p_offset limit p_limit)
 select jsonb_build_object('entries',coalesce((select jsonb_agg(row) from page),'[]'),'total',(select count(*) from matching)) into result;
 return result;
end $$;


create function public.employee_payment_operation(p_payload jsonb,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('payroll:pay'); action text:=p_payload->>'action'; prior public.finance_requests;
 payload jsonb:=jsonb_build_object('action','employee_payment','actor',auth.uid(),'body',p_payload); result jsonb;
 eid uuid; oid uuid; month date; pid uuid; tid uuid; tr public.transits; e public.employees;
 payment public.employee_payments; ent public.employee_payment_entries; w public.wallets;
 item jsonb; x jsonb; balance jsonb; amount numeric; total numeric; kind text; reason text; entry uuid;
 items jsonb; ids jsonb:='[]'; role_name text; trip_count integer;
begin
 if p_request_id is null or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'Request ID and operation are required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload<>payload then raise exception 'Request ID was already used with different details'; end if; return prior.result; end if;
 if action='pay' then
 items:=p_payload->'items';
 if jsonb_typeof(items) is distinct from 'array' or jsonb_array_length(items)<>1 then raise exception 'Choose one employee per payment'; end if;
 if (select count(distinct value->>'employee_id') from jsonb_array_elements(items))<>jsonb_array_length(items) then raise exception 'Choose each employee once per payment'; end if;
 -- Trip payments are individual. Transit precedes employee/obligation/wallet.
 if exists(select 1 from jsonb_array_elements(items) j where nullif(j->>'transit_id','') is not null) then
 if jsonb_array_length(items)<>1 then raise exception 'Record linked trip payments individually'; end if;
 perform app_private.require_permission('logistics:manage');
 tid:=(items->0->>'transit_id')::uuid;
 select * into tr from public.transits where tenant_id=t and transit_id=tid for update;
 if not found or tr.closed_at is not null then raise exception 'Select a trip with open operating costs'; end if;
 end if;
 perform 1 from public.employees where tenant_id=t and employee_id in (select (value->>'employee_id')::uuid from jsonb_array_elements(items)) order by employee_id for update;
 for item in select value from jsonb_array_elements(items) loop
 eid:=(item->>'employee_id')::uuid; kind:=item->>'kind'; oid:=null; month:=null; reason:=nullif(trim(item->>'description'),'');
 if not exists(select 1 from public.employees where tenant_id=t and employee_id=eid) then raise exception 'Employee not found'; end if;
 if kind is null or kind not in ('salary','bonus','trips') then raise exception 'Select a payment category'; end if;
 if kind='salary' then month:=app_private.payroll_month((item->>'period')::date); elsif item ? 'period' then raise exception 'Only salary has a salary month'; end if;
 if (item->>'payment_date')::date is null or (item->>'payment_date')::date>(now() at time zone 'Asia/Dhaka')::date then raise exception 'Payment date is required and cannot be in the future'; end if;
 if kind='bonus' and (nullif(trim(item->>'bonus_name'),'') is null or length(item->>'bonus_name')>120) then raise exception 'Name this bonus (up to 120 characters)'; end if;
 if length(reason)>1000 then raise exception 'Description is too long'; end if;
 if kind='salary' then
 balance:=app_private.employee_month_balance(t,eid,month);
 if (balance->>'salary_amount')::numeric<=0 then raise exception 'No salary is due for this month'; end if;
 insert into public.employee_salary_months(tenant_id,employee_id,period,salary_amount,calculation,created_by)
 values(t,eid,month,(balance->>'salary_amount')::numeric,jsonb_build_object('source','salary_revision','monthly_salary',(balance->>'salary_amount')::numeric),auth.uid())
 on conflict(tenant_id,employee_id,period) do nothing;
 select salary_month_id into oid from public.employee_salary_months where tenant_id=t and employee_id=eid and period=month for update;
 end if;
 if jsonb_typeof(item->'payments') is distinct from 'array' or jsonb_array_length(item->'payments') not between 1 and 20 then raise exception 'Use one to twenty payment entries'; end if;
 total:=0;
 perform 1 from public.wallets where tenant_id=t and wallet_id in (select (v->>'wallet_id')::uuid from jsonb_array_elements(item->'payments') v) order by wallet_id for update;
 for x in select value from jsonb_array_elements(item->'payments') loop
 if jsonb_typeof(x->'amount') is distinct from 'number' then raise exception 'Payment amounts must be numbers'; end if;
 amount:=app_private.purchase_money((x->>'amount')::numeric); if amount<=0 or amount<>(x->>'amount')::numeric then raise exception 'Payment must be positive'; end if; total:=total+amount;
 if length(coalesce(x->>'reference',''))>200 then raise exception 'Payment reference is too long'; end if;
 if not exists(select 1 from public.wallets pw where pw.tenant_id=t and pw.wallet_id=(x->>'wallet_id')::uuid and pw.is_active and (pw.kind<>'logistics' or tid is not null)) then raise exception 'Select an active payment wallet belonging to this business'; end if;
 end loop;
 if oid is not null and total>(balance->>'outstanding')::numeric then raise exception 'Payment exceeds outstanding salary. Reload this month before paying.'; end if;
 role_name:=item->>'trip_role'; trip_count:=(item->>'trip_count')::integer;
 if kind='trips' then
 if tid is null then raise exception 'Trip payments require a saved Logistics trip'; end if;
 if trip_count is null or trip_count<1 then raise exception 'Enter a positive trip count'; end if;
 if tid is not null then
 if role_name is null or role_name not in ('driver','helper') then raise exception 'Choose driver or helper'; end if;
 if total+app_private.transit_employee_paid(t,tid,role_name)>(case role_name when 'driver' then tr.driver_cost else tr.helper_cost end) then raise exception 'Employee payment exceeds the saved trip role cost'; end if;
 end if;
 elsif trip_count is not null or role_name is not null or tid is not null then raise exception 'Trip fields are only valid for trip payments'; end if;
 insert into public.employee_payments(tenant_id,employee_id,kind,amount,payment_date,description,salary_month_id,trip_count,transit_id,trip_role,operation_id,created_by,bonus_name)
 values(t,eid,kind,total,(item->>'payment_date')::date,reason,oid,trip_count,tid,role_name,p_request_id,auth.uid(),case when kind='bonus' then trim(item->>'bonus_name') end) returning payment_id into pid;
 for x in select value from jsonb_array_elements(item->'payments') loop
 select * into w from public.wallets where tenant_id=t and wallet_id=(x->>'wallet_id')::uuid;
 insert into public.employee_payment_entries(tenant_id,payment_id,wallet_id,wallet_name,method,amount,reference)
 values(t,pid,w.wallet_id,w.name,w.kind,(x->>'amount')::numeric,coalesce(x->>'reference','')) returning entry_id into entry;
 insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id,employee_entry_id)
 values(t,w.wallet_id,-(x->>'amount')::numeric,'payroll_'||kind,pid,
 (select name from public.employees where tenant_id=t and employee_id=eid)||' · '||case when kind='bonus' then trim(item->>'bonus_name') when kind='salary' then 'Salary · '||to_char(month,'FMMonth YYYY') else 'Trip payment' end||coalesce(' · '||reason,'')||coalesce(' · '||(x->>'reference'),''),p_request_id,entry);
 end loop;
 if tid is not null then update public.transits set revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and transit_id=tid; end if;
 ids:=ids||jsonb_build_array(pid);
 end loop;
 result:=jsonb_build_object('payment_ids',ids);
 elsif action='reverse_payment' then
 select * into payment from public.employee_payments where tenant_id=t and payment_id=(p_payload->>'payment_id')::uuid;
 if not found or payment.reversal_of is not null then raise exception 'Original payment not found'; end if;
 if payment.transit_id is not null then
 perform app_private.require_permission('logistics:manage');
 select * into tr from public.transits where tenant_id=t and transit_id=payment.transit_id for update;
 if tr.closed_at is not null then raise exception 'Closed trip payments are locked. Record a separately audited Finance correction.'; end if;
 end if;
 perform 1 from public.employees where tenant_id=t and employee_id=payment.employee_id for update;
 if payment.salary_month_id is not null then perform 1 from public.employee_salary_months where tenant_id=t and salary_month_id=payment.salary_month_id for update; end if;
 if exists(select 1 from public.employee_payments where tenant_id=t and reversal_of=payment.payment_id) then raise exception 'Payment has already been reversed'; end if;
 if not exists(select 1 from public.employee_payment_entries where tenant_id=t and payment_id=payment.payment_id) then raise exception 'Historical payment has no wallet evidence and cannot create a wallet refund'; end if;
 reason:=nullif(trim(p_payload->>'reason'),''); if reason is null or length(reason)>1000 then raise exception 'A reversal reason is required'; end if;
 if (p_payload->>'payment_date')::date is null or (p_payload->>'payment_date')::date<payment.payment_date or (p_payload->>'payment_date')::date>(now() at time zone 'Asia/Dhaka')::date then raise exception 'Enter the date funds were returned'; end if;
 perform 1 from public.wallets where tenant_id=t and wallet_id in (select wallet_id from public.employee_payment_entries where tenant_id=t and payment_id=payment.payment_id) order by wallet_id for update;
 insert into public.employee_payments(tenant_id,employee_id,kind,amount,payment_date,description,salary_month_id,trip_count,transit_id,trip_role,reversal_of,operation_id,created_by,bonus_name)
 values(t,payment.employee_id,payment.kind,payment.amount,(p_payload->>'payment_date')::date,reason,payment.salary_month_id,payment.trip_count,payment.transit_id,payment.trip_role,payment.payment_id,p_request_id,auth.uid(),payment.bonus_name) returning payment_id into pid;
 for ent in select * from public.employee_payment_entries where tenant_id=t and payment_id=payment.payment_id loop
 insert into public.employee_payment_entries(tenant_id,payment_id,wallet_id,wallet_name,method,amount,reference)
 values(t,pid,ent.wallet_id,ent.wallet_name,ent.method,ent.amount,ent.reference) returning entry_id into entry;
 insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id,employee_entry_id)
 values(t,ent.wallet_id,ent.amount,'payroll_reversal',pid,'Returned employee funds · '||reason,p_request_id,entry);
 end loop;
 if payment.transit_id is not null then update public.transits set revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and transit_id=payment.transit_id; end if;
 result:=jsonb_build_object('payment_id',pid);
 else raise exception 'Unknown employee payment operation'; end if;
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,payload,result,auth.uid()); return result;
end $$;

create or replace function public.get_employee_activity(p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 12) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['payroll:view','payroll:pay']); result jsonb;
begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 or length(coalesce(p_filters->>'search',''))>500
 or nullif(p_filters->>'from','')::date>nullif(p_filters->>'to','')::date then raise exception 'Invalid activity filters or page'; end if;
 with events as (
 select a.activity_id id,a.employee_id,'profile'::text kind,a.description,a.created_at,(a.created_at at time zone 'Asia/Dhaka')::date date,a.created_by,null::numeric amount,a.details,'[]'::jsonb wallets,false reversible
 from public.employee_activity a where a.tenant_id=t and (nullif(p_filters->>'employee_id','') is null or a.employee_id=(p_filters->>'employee_id')::uuid)
 union all
 select tm.term_id,tm.employee_id,'terms',case when tm.is_active then 'Salary terms' else 'Employment paused / ended' end,tm.created_at,tm.effective_from,tm.created_by,tm.monthly_salary,to_jsonb(tm),'[]'::jsonb,false
 from public.employee_terms tm where tm.tenant_id=t and (nullif(p_filters->>'employee_id','') is null or tm.employee_id=(p_filters->>'employee_id')::uuid)
 union all
 select p.payment_id,p.employee_id,case when p.reversal_of is null then 'payment' else 'reversal' end,case when p.kind='bonus' then p.bonus_name when p.kind='salary' then 'Salary · '||to_char(o.period,'FMMonth YYYY') else 'Trip payment' end||coalesce(' · '||p.description,''),p.created_at,p.payment_date,p.created_by,
 case when p.reversal_of is null then p.amount else -p.amount end,to_jsonb(p)||jsonb_build_object('period',o.period),
 coalesce((select jsonb_agg(to_jsonb(en)||jsonb_build_object('transaction_id',wt.transaction_id) order by en.entry_id) from public.employee_payment_entries en left join public.wallet_transactions wt on wt.tenant_id=t and wt.employee_entry_id=en.entry_id where en.tenant_id=t and en.payment_id=p.payment_id),'[]'),
 p.reversal_of is null and p.source_snapshot is null and not exists(select 1 from public.employee_payments r where r.tenant_id=t and r.reversal_of=p.payment_id)
 and (p.transit_id is null or exists(select 1 from public.transits tr where tr.tenant_id=t and tr.transit_id=p.transit_id and tr.closed_at is null))
 from public.employee_payments p left join public.employee_salary_months o using(tenant_id,salary_month_id) where p.tenant_id=t and (nullif(p_filters->>'employee_id','') is null or p.employee_id=(p_filters->>'employee_id')::uuid)
 ), matching as materialized (
 select ev.*,e.name employee_name,u.full_name actor from events ev join public.employees e on e.tenant_id=t and e.employee_id=ev.employee_id
 left join public.user_profiles u on u.tenant_id=t and u.user_id=ev.created_by
 where (nullif(p_filters->>'kind','') is null or ev.kind=p_filters->>'kind')
 and (nullif(p_filters->>'from','') is null or ev.date>=(p_filters->>'from')::date)
 and (nullif(p_filters->>'to','') is null or ev.date<=(p_filters->>'to')::date)
 and app_private.employee_search(concat_ws(' ',e.name,ev.description,ev.kind,ev.id,ev.wallets,ev.details),p_filters->>'search')),
 page as (select * from matching order by date desc,created_at desc,id desc offset p_offset limit p_limit)
 select jsonb_build_object('entries',coalesce((select jsonb_agg(to_jsonb(p)) from page p),'[]'),'total',(select count(*) from matching)) into result;
 return result;
end $$;

-- Existing trip payout helpers and closure guards use payment records only.
-- Rename the remaining month validator; no payroll implementation remains callable.
alter function app_private.payroll_month(date) rename to employee_month;
do $$ declare r record; definition text; begin
 for r in select oid from pg_proc where pronamespace in ('public'::regnamespace,'app_private'::regnamespace)
 and prosrc like '%app_private.payroll_month(%' loop
 definition:=replace(pg_get_functiondef(r.oid),'app_private.payroll_month(','app_private.employee_month('); execute definition;
 end loop;
end $$;
do $$ declare r record; begin
 for r in select oid::regprocedure f from pg_proc where pronamespace='app_private'::regnamespace and proname=any(array['employee_month','employee_month_rate','employee_month_balance']) loop
 execute format('alter function %s owner to postgres',r.f); execute format('revoke all on function %s from public,anon,authenticated',r.f); end loop;
 for r in select oid::regprocedure f from pg_proc where pronamespace='public'::regnamespace and proname=any(array['employee_payment_operation','get_employee_directory','get_employee_overview','get_employee_salary_month','get_employee_salary_history']) loop
 execute format('alter function %s owner to postgres',r.f); execute format('revoke all on function %s from public,anon,authenticated',r.f); execute format('grant execute on function %s to authenticated',r.f); end loop;
end $$;
do $$ begin
 if exists(select 1 from employee_redesign_preservation s where
 s.wallets is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(w) order by tenant_id,wallet_id)::text,'')) from public.wallets w)
 or s.ledger is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(w) order by tenant_id,transaction_id)::text,'')) from public.wallet_transactions w)
 or s.stock is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(i) order by tenant_id,item_id)::text,'')) from public.items i)) then raise exception 'Employee redesign changed wallets, ledger or stock'; end if;
end $$;
drop table employee_redesign_preservation;
notify pgrst,'reload schema';
