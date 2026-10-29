-- Monthly obligations and immutable disbursements share the existing Finance
-- request registry and wallet posting trigger. No historic money is reposted.
create temporary table employee_migration_preservation as select
 (select md5(coalesce(jsonb_agg(jsonb_build_array(tenant_id,payment_id,employee_id,amount,payment_date,description,trip_count,created_at,created_by) order by tenant_id,payment_id)::text,'')) from public.employee_payments) payments,
 (select md5(coalesce(jsonb_agg(to_jsonb(w) order by tenant_id,wallet_id)::text,'')) from public.wallets w) wallets,
 (select md5(coalesce(jsonb_agg(to_jsonb(w) order by tenant_id,transaction_id)::text,'')) from public.wallet_transactions w) ledger,
 (select md5(coalesce(jsonb_agg(to_jsonb(i) order by tenant_id,item_id)::text,'')) from public.items i) stock;
drop function public.create_employee(text,jsonb,text,numeric,text,text,text);
drop function public.update_employee(uuid,text,jsonb,text,numeric,text,text,text,boolean);
drop function public.deactivate_employee(uuid);
drop function public.create_employee_payment(uuid,uuid,numeric,date,text,integer,integer,integer);
drop function public.list_employee_payment_categories();
drop function public.list_employee_payments(uuid);
drop function public.list_employees();
drop function app_private.ensure_default_employee_payment_categories(uuid);

alter table public.employees add column revision integer not null default 1;
create table public.employee_terms (
 tenant_id uuid not null, term_id uuid not null default gen_random_uuid(), employee_id uuid not null,
 effective_from date not null, monthly_salary numeric(12,2) not null check(monthly_salary>=0 and monthly_salary<'Infinity'::numeric),
 is_active boolean not null, reason text not null check(length(trim(reason)) between 1 and 1000),
 created_at timestamptz not null default clock_timestamp(), created_by uuid,
 primary key(tenant_id,term_id), unique(tenant_id,employee_id,effective_from),
 foreign key(tenant_id,employee_id) references public.employees(tenant_id,employee_id),
 foreign key(tenant_id,created_by) references public.user_profiles(tenant_id,user_id)
);
-- Existing profiles have no historical salary-rate evidence. Establish an
-- explicit current-month baseline only; never manufacture earlier arrears.
insert into public.employee_terms(tenant_id,employee_id,effective_from,monthly_salary,is_active,reason,created_by)
 select tenant_id,employee_id,date_trunc('month',now() at time zone 'Asia/Dhaka')::date,current_salary,is_active,
 'Opening payroll terms; earlier salary entitlement was not recorded',created_by from public.employees;
alter table public.employees drop column current_salary, drop column is_active;

create table public.payroll_obligations (
 tenant_id uuid not null, obligation_id uuid not null default gen_random_uuid(), employee_id uuid not null,
 period date not null check(extract(day from period)=1 and period between '2000-01-01' and '2100-12-01'),
 base_amount numeric(12,2) not null check(base_amount>=0 and base_amount<'Infinity'::numeric),
 calculation jsonb not null, created_at timestamptz not null default clock_timestamp(), created_by uuid,
 primary key(tenant_id,obligation_id), unique(tenant_id,employee_id,period),
 unique(tenant_id,obligation_id,employee_id),
 foreign key(tenant_id,employee_id) references public.employees(tenant_id,employee_id),
 foreign key(tenant_id,created_by) references public.user_profiles(tenant_id,user_id)
);
insert into public.payroll_obligations(tenant_id,employee_id,period,base_amount,calculation,created_at,created_by)
 select tenant_id,employee_id,make_date(salary_year,salary_month,1),amount,
 jsonb_build_object('source','historical_payment','note','Recorded salary paid only; full historical entitlement is unknown'),created_at,created_by
 from public.employee_payments where category_code='salary';

alter table public.employee_payments add column obligation_id uuid, add column reversal_of uuid,
 add column operation_id uuid, add column transit_id uuid, add column trip_role text,
 add column source_snapshot jsonb;
alter table public.employee_payments disable trigger employee_payments_no_update;
update public.employee_payments p set obligation_id=o.obligation_id from public.payroll_obligations o
 where o.tenant_id=p.tenant_id and o.employee_id=p.employee_id and o.period=make_date(p.salary_year,p.salary_month,1) and p.category_code='salary';
update public.employee_payments p set source_snapshot=jsonb_build_object('category_id',p.category_id,'category_code',p.category_code,
 'category_name',c.name,'salary_year',p.salary_year,'salary_month',p.salary_month,'wallet_evidence','unattributed')
 from public.employee_payment_categories c where c.tenant_id=p.tenant_id and c.category_id=p.category_id;
alter table public.employee_payments enable trigger employee_payments_no_update;
drop index public.employee_payments_salary_once_per_month;
do $$ declare c record; begin
 for c in select conname from pg_constraint where conrelid='public.employee_payments'::regclass
 and pg_get_constraintdef(oid) ~ '(category_id|category_code|salary_year|salary_month)' loop
 execute format('alter table public.employee_payments drop constraint %I',c.conname); end loop;
end $$;
alter table public.employee_payments drop column category_id, drop column salary_year, drop column salary_month;
alter table public.employee_payments rename column category_code to kind;
alter table public.employee_payments add constraint employee_payment_kind check(kind in ('salary','bonus','commission','allowance','advance','reimbursement','trips','other')),
 add constraint employee_payment_period check((kind='salary')=(obligation_id is not null)),
 add constraint employee_payment_finite check(amount<'Infinity'::numeric),
 add constraint employee_payment_trip check((transit_id is null and trip_role is null) or (kind='trips' and transit_id is not null and trip_role in ('driver','helper'))),
 add constraint employee_payment_obligation_fk foreign key(tenant_id,obligation_id,employee_id) references public.payroll_obligations(tenant_id,obligation_id,employee_id),
 add constraint employee_payment_reversal_fk foreign key(tenant_id,reversal_of) references public.employee_payments(tenant_id,payment_id),
 add constraint employee_payment_transit_fk foreign key(tenant_id,transit_id) references public.transits(tenant_id,transit_id);
create unique index employee_payment_reverse_once on public.employee_payments(tenant_id,reversal_of) where reversal_of is not null;
create index employee_payment_obligation on public.employee_payments(tenant_id,obligation_id);
create index employee_payment_transit on public.employee_payments(tenant_id,transit_id) where transit_id is not null;
drop table public.employee_payment_categories;

create table public.employee_payment_entries (
 tenant_id uuid not null, entry_id uuid not null default gen_random_uuid(), payment_id uuid not null,
 wallet_id uuid not null, wallet_name text not null, method text not null,
 amount numeric(12,2) not null check(amount>0 and amount<'Infinity'::numeric), reference text not null default '' check(length(reference)<=200),
 primary key(tenant_id,entry_id),
 foreign key(tenant_id,payment_id) references public.employee_payments(tenant_id,payment_id),
 foreign key(tenant_id,wallet_id) references public.wallets(tenant_id,wallet_id)
);
create index employee_entries_payment on public.employee_payment_entries(tenant_id,payment_id);
alter table public.wallet_transactions add column employee_entry_id uuid,
 add constraint wallet_employee_entry_fk foreign key(tenant_id,employee_entry_id) references public.employee_payment_entries(tenant_id,entry_id);
create unique index wallet_employee_entry_once on public.wallet_transactions(tenant_id,employee_entry_id) where employee_entry_id is not null;

create table public.payroll_adjustments (
 tenant_id uuid not null, adjustment_id uuid not null default gen_random_uuid(), obligation_id uuid not null,
 kind text not null check(kind in ('bonus','commission','allowance','deduction','advance_repayment','other')),
 amount numeric(12,2) not null check(amount<>0 and abs(amount)<'Infinity'::numeric),
 reason text not null check(length(trim(reason)) between 1 and 1000), advance_id uuid, reversal_of uuid,
 created_at timestamptz not null default clock_timestamp(), created_by uuid not null, operation_id uuid not null,
 primary key(tenant_id,adjustment_id),
 foreign key(tenant_id,obligation_id) references public.payroll_obligations(tenant_id,obligation_id),
 foreign key(tenant_id,advance_id) references public.employee_payments(tenant_id,payment_id),
 foreign key(tenant_id,reversal_of) references public.payroll_adjustments(tenant_id,adjustment_id),
 foreign key(tenant_id,created_by) references public.user_profiles(tenant_id,user_id),
 check((kind='advance_repayment')=(advance_id is not null)),
 check(reversal_of is not null or (kind in ('deduction','advance_repayment') and amount<0) or (kind not in ('deduction','advance_repayment') and amount>0))
);
create unique index payroll_adjustment_reverse_once on public.payroll_adjustments(tenant_id,reversal_of) where reversal_of is not null;
create index payroll_adjustment_obligation on public.payroll_adjustments(tenant_id,obligation_id);
create index payroll_adjustment_advance on public.payroll_adjustments(tenant_id,advance_id) where advance_id is not null;
create table public.employee_activity (
 tenant_id uuid not null, activity_id uuid not null default gen_random_uuid(), employee_id uuid not null,
 description text not null, details jsonb not null, created_by uuid not null,
 created_at timestamptz not null default clock_timestamp(),
 primary key(tenant_id,activity_id),
 foreign key(tenant_id,employee_id) references public.employees(tenant_id,employee_id),
 foreign key(tenant_id,created_by) references public.user_profiles(tenant_id,user_id)
);
create index employee_activity_date on public.employee_activity(tenant_id,employee_id,created_at desc,activity_id);
create index payroll_period_directory on public.payroll_obligations(tenant_id,period,employee_id);

-- All reads use bounded RPCs. Tables are private to the application owner.
do $$ declare n text; begin
 foreach n in array array['employee_terms','payroll_obligations','employee_payment_entries','payroll_adjustments','employee_activity'] loop
 execute format('alter table public.%I owner to postgres',n);
 execute format('alter table public.%I enable row level security',n);
 execute format('revoke all on public.%I from public,anon,authenticated',n);
 execute format('create trigger immutable_employee_record before update or delete on public.%I for each row execute function app_private.immutable_finance_record()',n);
 end loop;
end $$;
revoke all on public.employees,public.employee_phone_numbers,public.employee_types,public.employee_payments from public,anon,authenticated;
-- Replace the original unconditional rejection with the established trusted
-- root-tenant cleanup exception. Browser UPDATE/DELETE remain denied.
drop trigger employee_payments_no_update on public.employee_payments;
drop trigger employee_payments_no_delete on public.employee_payments;
create trigger immutable_employee_payment before update or delete on public.employee_payments for each row execute function app_private.immutable_finance_record();
drop function app_private.employee_payment_immutable();

create function app_private.payroll_month(p date) returns date language plpgsql immutable set search_path='' as $$
begin
 if p is null or extract(day from p)<>1 or p not between '2000-01-01' and '2100-12-01' then raise exception 'Select a payroll month between 2000 and 2100'; end if;
 return p;
end $$;
create function app_private.payroll_balance(t uuid, oid uuid) returns jsonb language sql stable set search_path='' as $$
 with a as (select coalesce(sum(amount) filter(where kind<>'advance_repayment'),0) adjustment,
 -coalesce(sum(amount) filter(where kind='advance_repayment'),0) advance_applied from public.payroll_adjustments where tenant_id=t and obligation_id=oid),
 p as (select coalesce(sum(case when reversal_of is null then amount else -amount end),0) paid from public.employee_payments where tenant_id=t and obligation_id=oid)
 select jsonb_build_object('base',o.base_amount,'adjustments',a.adjustment,'earned',o.base_amount+a.adjustment,
 'advance_applied',a.advance_applied,'payable',o.base_amount+a.adjustment-a.advance_applied,'paid',p.paid,
 'outstanding',o.base_amount+a.adjustment-a.advance_applied-p.paid,
 'status',case when o.base_amount+a.adjustment-a.advance_applied=p.paid then 'paid' when p.paid+a.advance_applied>0 then 'partial' else 'unpaid' end)
 from public.payroll_obligations o cross join a cross join p where o.tenant_id=t and o.obligation_id=oid;
$$;
create function app_private.employee_advance_remaining(t uuid,pid uuid) returns numeric language sql stable set search_path='' as $$
 select p.amount+coalesce((select sum(a.amount) from public.payroll_adjustments a where a.tenant_id=t and a.advance_id=pid),0)
 from public.employee_payments p where p.tenant_id=t and p.payment_id=pid and p.kind='advance' and p.reversal_of is null
 and not exists(select 1 from public.employee_payments r where r.tenant_id=t and r.reversal_of=pid);
$$;
create function app_private.employee_summary(t uuid,eid uuid) returns jsonb language sql stable set search_path='' as $$
 select to_jsonb(e)||jsonb_build_object('employee_type_name',et.name,'current_salary',coalesce(tm.monthly_salary,0),'is_active',coalesce(tm.is_active,false),
 'effective_from',tm.effective_from,'phones',coalesce(ph.phones,'[]'),'primary_phone',ph.primary_phone,
 'payroll_start',(select min(effective_from) from public.employee_terms where tenant_id=t and employee_id=eid))
 from public.employees e left join public.employee_types et using(tenant_id,employee_type_id)
 left join lateral (select monthly_salary,is_active,effective_from from public.employee_terms where tenant_id=t and employee_id=eid
 and effective_from<=(now() at time zone 'Asia/Dhaka')::date order by effective_from desc limit 1) tm on true
 left join lateral (select jsonb_agg(jsonb_build_object('phone',phone,'is_primary',is_primary) order by is_primary desc,phone) phones,
 max(phone) filter(where is_primary) primary_phone from public.employee_phone_numbers where tenant_id=t and employee_id=eid) ph on true
 where e.tenant_id=t and e.employee_id=eid;
$$;
create function app_private.prepare_employee_payroll(t uuid,eid uuid,month date) returns uuid language plpgsql set search_path='' as $$
declare oid uuid; days integer:=extract(day from month+interval '1 month - 1 day'); calculation jsonb; base numeric;
begin
 select obligation_id into oid from public.payroll_obligations where tenant_id=t and employee_id=eid and period=month;
 if found then return oid; end if;
 with dates as (select month+d pay_day from generate_series(0,days-1) d), rates as (
 select pay_day,r.* from dates join lateral (select term_id,monthly_salary,is_active from public.employee_terms
 where tenant_id=t and employee_id=eid and effective_from<=pay_day order by effective_from desc limit 1) r on r.is_active),
 segments as (select term_id,monthly_salary,count(*) eligible_days,min(pay_day) starts,max(pay_day) ends from rates group by term_id,monthly_salary)
 select round(coalesce(sum(monthly_salary*eligible_days/days),0),2),jsonb_build_object('source','terms','days_in_month',days,
 'segments',coalesce(jsonb_agg(to_jsonb(segments)),'[]')) into base,calculation from segments;
 -- Inactive/unpaid months can be prepared explicitly at zero; retain the fact.
 insert into public.payroll_obligations(tenant_id,employee_id,period,base_amount,calculation,created_by)
 values(t,eid,month,base,calculation,auth.uid()) returning obligation_id into oid;
 return oid;
end $$;

create function public.save_employee(p_payload jsonb,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
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
 select * into term from public.employee_terms where tenant_id=t and employee_id=eid order by effective_from desc limit 1;
 if p_payload ? 'terms' then
 dt:=(p_payload->'terms'->>'effective_from')::date;
 salary:=app_private.purchase_money((p_payload->'terms'->>'monthly_salary')::numeric);
 active:=(p_payload->'terms'->>'is_active')::boolean;
 if dt is null or dt not between '2000-01-01' and '2100-12-31' or active is null or salary is null
 or salary<>(p_payload->'terms'->>'monthly_salary')::numeric then raise exception 'Provide valid salary, status and effective date'; end if;
 if term.term_id is not null and (term.monthly_salary,term.is_active) is not distinct from (salary,active) then raise exception 'Salary and status are unchanged'; end if;
 if term.term_id is not null and dt<=term.effective_from then raise exception 'New terms must start after the latest saved terms'; end if;
 if exists(select 1 from public.payroll_obligations where tenant_id=t and employee_id=eid and period+interval '1 month'>dt)
 and (dt<(now() at time zone 'Asia/Dhaka')::date or coalesce((p_payload->'terms'->>'preserve_prepared')::boolean,false) is not true) then
 raise exception 'Prepared payroll is preserved. Backdated terms cannot replace it. A current employment change requires acknowledgement; adjust the prepared month separately.'; end if;
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

-- Amount already paid to named employees is part of the saved trip cost, not
-- another expense on closure. Both workflows serialize on the transit row.
create function app_private.transit_employee_paid(t uuid,tid uuid,role_name text default null) returns numeric language sql stable set search_path='' as $$
 select coalesce(sum(case when reversal_of is null then amount else -amount end),0) from public.employee_payments
 where tenant_id=t and transit_id=tid and (role_name is null or trip_role=role_name);
$$;

create function public.payroll_operation(p_payload jsonb,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('payroll:pay'); action text:=p_payload->>'action'; prior public.finance_requests;
 payload jsonb:=jsonb_build_object('action','payroll','actor',auth.uid(),'body',p_payload); result jsonb;
 eid uuid; oid uuid; month date; pid uuid; aid uuid; tid uuid; tr public.transits; e public.employees;
 payment public.employee_payments; adj public.payroll_adjustments; ent public.employee_payment_entries; w public.wallets;
 item jsonb; x jsonb; balance jsonb; amount numeric; total numeric; kind text; reason text; advance uuid; entry uuid;
 items jsonb; ids jsonb:='[]'; role_name text; trip_count integer; prepared integer:=0;
begin
 if p_request_id is null or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'Request ID and operation are required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload<>payload then raise exception 'Request ID was already used with different details'; end if; return prior.result; end if;
 if action='prepare' then
 month:=app_private.payroll_month((p_payload->>'period')::date);
 if month>date_trunc('month',now() at time zone 'Asia/Dhaka')::date then raise exception 'Future payroll cannot be prepared'; end if;
 if p_payload->>'employee_id' is not null and not exists(select 1 from public.employees where tenant_id=t and employee_id=(p_payload->>'employee_id')::uuid) then raise exception 'Employee not found'; end if;
 for e in select * from public.employees where tenant_id=t and (p_payload->>'employee_id' is null or employee_id=(p_payload->>'employee_id')::uuid) order by employee_id for update loop
 if p_payload->>'employee_id' is not null or exists(select 1 from public.employee_terms tm where tm.tenant_id=t and tm.employee_id=e.employee_id and tm.is_active and tm.effective_from<month+interval '1 month'
 and coalesce((select min(n.effective_from) from public.employee_terms n where n.tenant_id=t and n.employee_id=e.employee_id and n.effective_from>tm.effective_from),'infinity'::date)>month) then
 if not exists(select 1 from public.payroll_obligations where tenant_id=t and employee_id=e.employee_id and period=month) then
 perform app_private.prepare_employee_payroll(t,e.employee_id,month); prepared:=prepared+1; end if; end if;
 end loop;
 result:=jsonb_build_object('prepared',prepared,'period',month);
 elsif action='pay' then
 items:=p_payload->'items';
 if jsonb_typeof(items) is distinct from 'array' or jsonb_array_length(items) not between 1 and 50 then raise exception 'Choose one to fifty employees for a payment'; end if;
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
 perform 1 from public.payroll_obligations where tenant_id=t and obligation_id in (select (value->>'obligation_id')::uuid from jsonb_array_elements(items)) order by employee_id,obligation_id for update;
 perform 1 from public.wallets where tenant_id=t and wallet_id in (select (v->>'wallet_id')::uuid from jsonb_array_elements(items) i cross join lateral jsonb_array_elements(i->'payments') v) order by wallet_id for update;
 for item in select value from jsonb_array_elements(items) loop
 eid:=(item->>'employee_id')::uuid; kind:=item->>'kind'; oid:=(item->>'obligation_id')::uuid; reason:=nullif(trim(item->>'description'),'');
 if not exists(select 1 from public.employees where tenant_id=t and employee_id=eid) then raise exception 'Employee not found'; end if;
 if kind is null or kind not in ('salary','bonus','commission','allowance','advance','reimbursement','trips','other') then raise exception 'Select a payment category'; end if;
 if (kind='salary') is distinct from (oid is not null) then raise exception 'Salary must be allocated to its payroll month'; end if;
 if (item->>'payment_date')::date is null or (item->>'payment_date')::date>(now() at time zone 'Asia/Dhaka')::date then raise exception 'Payment date is required and cannot be in the future'; end if;
 if kind<>'salary' and reason is null then raise exception 'Describe this employee payment'; end if;
 if length(reason)>1000 then raise exception 'Description is too long'; end if;
 if oid is not null then
 if not exists(select 1 from public.payroll_obligations where tenant_id=t and obligation_id=oid and employee_id=eid) then raise exception 'Payroll month not found for this employee'; end if;
 balance:=app_private.payroll_balance(t,oid);
 end if;
 if jsonb_typeof(item->'payments') is distinct from 'array' or jsonb_array_length(item->'payments') not between 1 and 20 then raise exception 'Use one to twenty payment entries'; end if;
 total:=0;
 for x in select value from jsonb_array_elements(item->'payments') loop
 if jsonb_typeof(x->'amount') is distinct from 'number' then raise exception 'Payment amounts must be numbers'; end if;
 amount:=app_private.purchase_money((x->>'amount')::numeric); if amount<=0 then raise exception 'Payment must be positive'; end if; total:=total+amount;
 if length(coalesce(x->>'reference',''))>200 then raise exception 'Payment reference is too long'; end if;
 if not exists(select 1 from public.wallets pw where pw.tenant_id=t and pw.wallet_id=(x->>'wallet_id')::uuid and pw.is_active and (pw.kind<>'logistics' or tid is not null)) then raise exception 'Select an active payment wallet belonging to this business'; end if;
 end loop;
 if oid is not null and total>(balance->>'outstanding')::numeric then raise exception 'Payment exceeds outstanding salary. Reload payroll before paying.'; end if;
 role_name:=item->>'trip_role'; trip_count:=(item->>'trip_count')::integer;
 if kind='trips' then
 if trip_count is null or trip_count<1 then raise exception 'Enter a positive trip count'; end if;
 if tid is not null then
 if role_name is null or role_name not in ('driver','helper') then raise exception 'Choose driver or helper'; end if;
 if total+app_private.transit_employee_paid(t,tid,role_name)>(case role_name when 'driver' then tr.driver_cost else tr.helper_cost end) then raise exception 'Employee payment exceeds the saved trip role cost'; end if;
 end if;
 elsif trip_count is not null or role_name is not null or tid is not null then raise exception 'Trip fields are only valid for trip payments'; end if;
 insert into public.employee_payments(tenant_id,employee_id,kind,amount,payment_date,description,obligation_id,trip_count,transit_id,trip_role,operation_id,created_by)
 values(t,eid,kind,total,(item->>'payment_date')::date,reason,oid,trip_count,tid,role_name,p_request_id,auth.uid()) returning payment_id into pid;
 for x in select value from jsonb_array_elements(item->'payments') loop
 select * into w from public.wallets where tenant_id=t and wallet_id=(x->>'wallet_id')::uuid;
 insert into public.employee_payment_entries(tenant_id,payment_id,wallet_id,wallet_name,method,amount,reference)
 values(t,pid,w.wallet_id,w.name,w.kind,(x->>'amount')::numeric,coalesce(x->>'reference','')) returning entry_id into entry;
 insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id,employee_entry_id)
 values(t,w.wallet_id,-(x->>'amount')::numeric,'payroll_'||kind,pid,
 (select name from public.employees where tenant_id=t and employee_id=eid)||' · '||kind||coalesce(' · '||reason,'')||coalesce(' · '||(x->>'reference'),''),p_request_id,entry);
 end loop;
 if tid is not null then update public.transits set revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and transit_id=tid; end if;
 ids:=ids||jsonb_build_array(pid);
 end loop;
 result:=jsonb_build_object('payment_ids',ids);
 elsif action in ('adjust','reverse_adjustment') then
 if action='reverse_adjustment' then
 select * into adj from public.payroll_adjustments where tenant_id=t and adjustment_id=(p_payload->>'adjustment_id')::uuid;
 if not found or adj.reversal_of is not null then raise exception 'Original adjustment not found'; end if;
 oid:=adj.obligation_id; kind:=adj.kind; amount:=-adj.amount; advance:=adj.advance_id;
 else
 oid:=(p_payload->>'obligation_id')::uuid; kind:=p_payload->>'kind'; amount:=app_private.purchase_money((p_payload->>'amount')::numeric); advance:=(p_payload->>'advance_id')::uuid;
 if amount<=0 or kind is null or kind not in ('bonus','commission','allowance','deduction','advance_repayment','other') then raise exception 'Choose a category and positive adjustment amount'; end if;
 if kind in ('deduction','advance_repayment') then amount:=-amount; end if;
 end if;
 select employee_id into eid from public.payroll_obligations where tenant_id=t and obligation_id=oid;
 perform 1 from public.employees where tenant_id=t and employee_id=eid for update;
 perform 1 from public.payroll_obligations where tenant_id=t and obligation_id=oid for update;
 if not found then raise exception 'Payroll month not found'; end if;
 if action='reverse_adjustment' and exists(select 1 from public.payroll_adjustments where tenant_id=t and reversal_of=adj.adjustment_id) then raise exception 'Adjustment has already been reversed'; end if;
 if (kind='advance_repayment') is distinct from (advance is not null) then raise exception 'Select an advance only for an advance repayment'; end if;
 if advance is not null then
 if not exists(select 1 from public.employee_payments ap where ap.tenant_id=t and ap.payment_id=advance and ap.employee_id=eid and ap.kind='advance') then raise exception 'Advance not found for this employee'; end if;
 if app_private.employee_advance_remaining(t,advance) is null or -amount>app_private.employee_advance_remaining(t,advance) then raise exception 'Repayment exceeds the outstanding advance'; end if;
 end if;
 reason:=nullif(trim(p_payload->>'reason'),''); if reason is null or length(reason)>1000 then raise exception 'A reason is required (up to 1000 characters)'; end if;
 balance:=app_private.payroll_balance(t,oid);
 if (balance->>'outstanding')::numeric+amount<0 then raise exception 'Adjustment would reduce salary below amounts already settled. Reverse the payment first.'; end if;
 insert into public.payroll_adjustments(tenant_id,obligation_id,kind,amount,reason,advance_id,reversal_of,operation_id,created_by)
 values(t,oid,kind,amount,reason,advance,case when action='reverse_adjustment' then adj.adjustment_id end,p_request_id,auth.uid()) returning adjustment_id into aid;
 result:=jsonb_build_object('adjustment_id',aid);
 elsif action='reverse_payment' then
 select * into payment from public.employee_payments where tenant_id=t and payment_id=(p_payload->>'payment_id')::uuid;
 if not found or payment.reversal_of is not null then raise exception 'Original payment not found'; end if;
 if payment.transit_id is not null then
 perform app_private.require_permission('logistics:manage');
 select * into tr from public.transits where tenant_id=t and transit_id=payment.transit_id for update;
 if tr.closed_at is not null then raise exception 'Closed trip payments are locked. Record a separately audited Finance correction.'; end if;
 end if;
 perform 1 from public.employees where tenant_id=t and employee_id=payment.employee_id for update;
 if payment.obligation_id is not null then perform 1 from public.payroll_obligations where tenant_id=t and obligation_id=payment.obligation_id for update; end if;
 if exists(select 1 from public.employee_payments where tenant_id=t and reversal_of=payment.payment_id) then raise exception 'Payment has already been reversed'; end if;
 if payment.kind='advance' and app_private.employee_advance_remaining(t,payment.payment_id)<>payment.amount then raise exception 'Reverse advance repayments before reversing this advance'; end if;
 if not exists(select 1 from public.employee_payment_entries where tenant_id=t and payment_id=payment.payment_id) then raise exception 'Historical payment has no wallet evidence and cannot create a wallet refund'; end if;
 reason:=nullif(trim(p_payload->>'reason'),''); if reason is null or length(reason)>1000 then raise exception 'A reversal reason is required'; end if;
 if (p_payload->>'payment_date')::date is null or (p_payload->>'payment_date')::date>(now() at time zone 'Asia/Dhaka')::date then raise exception 'Enter the date funds were returned'; end if;
 perform 1 from public.wallets where tenant_id=t and wallet_id in (select wallet_id from public.employee_payment_entries where tenant_id=t and payment_id=payment.payment_id) order by wallet_id for update;
 insert into public.employee_payments(tenant_id,employee_id,kind,amount,payment_date,description,obligation_id,trip_count,transit_id,trip_role,reversal_of,operation_id,created_by)
 values(t,payment.employee_id,payment.kind,payment.amount,(p_payload->>'payment_date')::date,reason,payment.obligation_id,payment.trip_count,payment.transit_id,payment.trip_role,payment.payment_id,p_request_id,auth.uid()) returning payment_id into pid;
 for ent in select * from public.employee_payment_entries where tenant_id=t and payment_id=payment.payment_id loop
 insert into public.employee_payment_entries(tenant_id,payment_id,wallet_id,wallet_name,method,amount,reference)
 values(t,pid,ent.wallet_id,ent.wallet_name,ent.method,ent.amount,ent.reference) returning entry_id into entry;
 insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id,employee_entry_id)
 values(t,ent.wallet_id,ent.amount,'payroll_reversal',pid,'Returned employee funds · '||reason,p_request_id,entry);
 end loop;
 if payment.transit_id is not null then update public.transits set revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and transit_id=payment.transit_id; end if;
 result:=jsonb_build_object('payment_id',pid);
 else raise exception 'Unknown payroll operation'; end if;
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,payload,result,auth.uid()); return result;
end $$;

create function app_private.employee_search(document text,search text) returns boolean language sql immutable set search_path='' as $$
 select coalesce(bool_or(matches),true) from (select bool_and(position(token in lower(coalesce(document,'')))>0) matches
 from regexp_split_to_table(lower(coalesce(search,'')),',') g
 cross join lateral regexp_split_to_table(trim(g),'\s+') token where token<>'' group by g) groups;
$$;
create function public.get_employee_directory(p_filters jsonb default '{}',p_period date default date_trunc('month',now() at time zone 'Asia/Dhaka')::date,p_offset integer default 0,p_limit integer default 25) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['employees:view','employees:manage','payroll:view','payroll:pay']); result jsonb;
 readable boolean:=app_private.has_any_permission(array['payroll:view','payroll:pay']); sorting text:=coalesce(p_filters->>'sort','name_asc');
begin
 perform app_private.payroll_month(p_period);
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 or length(coalesce(p_filters->>'search',''))>500
 or sorting not in ('name_asc','name_desc','salary_desc','salary_asc','due_desc','joined_desc')
 or coalesce(p_filters->>'status','all') not in ('all','active','inactive')
 or coalesce(p_filters->>'unit','all') not in ('all','gas_business','truck_business')
 or coalesce(p_filters->>'payment','all') not in ('all','unprepared','unpaid','partial','paid') then raise exception 'Invalid employee filters or page'; end if;
 if not readable and (sorting='due_desc' or coalesce(p_filters->>'payment','all')<>'all') then raise exception 'Payroll permission is required' using errcode='42501'; end if;
 if nullif(p_filters->>'salary_min','') is not null then perform app_private.purchase_money((p_filters->>'salary_min')::numeric); end if;
 if nullif(p_filters->>'salary_max','') is not null then perform app_private.purchase_money((p_filters->>'salary_max')::numeric); end if;
 if nullif(p_filters->>'salary_min','')::numeric>nullif(p_filters->>'salary_max','')::numeric then raise exception 'Minimum salary exceeds maximum'; end if;
 with profiles as materialized (select e.employee_id,app_private.employee_summary(t,e.employee_id) profile,
 case when readable then app_private.payroll_balance(t,o.obligation_id) end payroll,o.obligation_id
 from public.employees e left join public.payroll_obligations o on readable and o.tenant_id=t and o.employee_id=e.employee_id and o.period=p_period where e.tenant_id=t),
 matching as materialized (select profile||jsonb_build_object('obligation_id',obligation_id,'payroll',payroll) row from profiles
 where (coalesce(p_filters->>'status','all')='all' or (profile->>'is_active')::boolean=(p_filters->>'status'='active'))
 and (coalesce(p_filters->>'unit','all')='all' or profile->>'business_unit'=p_filters->>'unit')
 and (nullif(p_filters->>'type','') is null or profile->>'employee_type_name'=p_filters->>'type')
 and (nullif(p_filters->>'salary_min','') is null or (profile->>'current_salary')::numeric>=(p_filters->>'salary_min')::numeric)
 and (nullif(p_filters->>'salary_max','') is null or (profile->>'current_salary')::numeric<=(p_filters->>'salary_max')::numeric)
 and (coalesce(p_filters->>'payment','all')='all' or coalesce(payroll->>'status','unprepared')=p_filters->>'payment')
 and app_private.employee_search(concat_ws(' ',profile->>'name',profile->>'address',profile->>'employee_type_name',profile->'phones',profile->>'notes'),p_filters->>'search')),
 page as (select row from matching order by
 case when sorting='name_asc' then lower(row->>'name') end asc,
 case when sorting='name_desc' then lower(row->>'name') end desc,
 case when sorting='salary_desc' then (row->>'current_salary')::numeric end desc,
 case when sorting='salary_asc' then (row->>'current_salary')::numeric end asc,
 case when sorting='due_desc' then (row->'payroll'->>'outstanding')::numeric end desc nulls last,
 case when sorting='joined_desc' then row->>'payroll_start' end desc,row->>'name',row->>'employee_id' offset p_offset limit p_limit)
 select jsonb_build_object('entries',coalesce((select jsonb_agg(row) from page),'[]'),'total',(select count(*) from matching)) into result;
 return result;
end $$;

create function public.get_employee_overview(p_period date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['employees:view','employees:manage','payroll:view','payroll:pay']); result jsonb; readable boolean:=app_private.has_any_permission(array['payroll:view','payroll:pay']);
begin
 perform app_private.payroll_month(p_period);
 with employees as (select app_private.employee_summary(t,employee_id) e from public.employees where tenant_id=t),
 payroll as (select app_private.payroll_balance(t,obligation_id) b from public.payroll_obligations where readable and tenant_id=t and period=p_period)
 select jsonb_build_object('employees',(select count(*) from employees),'active',(select count(*) from employees where (e->>'is_active')::boolean),
 'types',(select coalesce(jsonb_agg(name order by name),'[]') from public.employee_types where tenant_id=t and is_active),
 'prepared',case when readable then (select count(*) from payroll) end,
 'earned',case when readable then (select coalesce(sum((b->>'earned')::numeric),0) from payroll) end,
 'paid',case when readable then (select coalesce(sum((b->>'paid')::numeric),0) from payroll) end,
 'advance_applied',case when readable then (select coalesce(sum((b->>'advance_applied')::numeric),0) from payroll) end,
 'outstanding',case when readable then (select coalesce(sum((b->>'outstanding')::numeric),0) from payroll) end) into result;
 return result;
end $$;

create function public.get_employee_profile(p_employee_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['employees:view','employees:manage','payroll:view','payroll:pay']); employee jsonb; financial jsonb; readable boolean:=app_private.has_any_permission(array['payroll:view','payroll:pay']);
begin
 employee:=app_private.employee_summary(t,p_employee_id); if employee is null then raise exception 'Employee not found'; end if;
 if readable then
 select jsonb_build_object('outstanding',coalesce(sum((b->>'outstanding')::numeric),0),'paid',coalesce(sum((b->>'paid')::numeric),0)) into financial
 from (select app_private.payroll_balance(t,obligation_id) b from public.payroll_obligations where tenant_id=t and employee_id=p_employee_id) p;
 end if;
 return jsonb_build_object('employee',employee,'financial',financial,
 'prepared_through',(select (max(period)+interval '1 month - 1 day')::date from public.payroll_obligations where tenant_id=t and employee_id=p_employee_id),
 'terms',(select coalesce(jsonb_agg(to_jsonb(tm) order by effective_from desc),'[]') from (select * from public.employee_terms where tenant_id=t and employee_id=p_employee_id order by effective_from desc limit 24) tm),
 'advances',case when readable then (select coalesce(jsonb_agg(to_jsonb(p)||jsonb_build_object('remaining',app_private.employee_advance_remaining(t,p.payment_id)) order by p.payment_date,p.payment_id),'[]') from public.employee_payments p
 where p.tenant_id=t and p.employee_id=p_employee_id and p.kind='advance' and p.reversal_of is null and app_private.employee_advance_remaining(t,p.payment_id)>0) else '[]'::jsonb end);
end $$;
create function public.get_employee_periods(p_employee_id uuid,p_offset integer default 0,p_limit integer default 12) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['payroll:view','payroll:pay']); result jsonb;
begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 50 then raise exception 'Invalid payroll page'; end if;
 with matching as materialized (select * from public.payroll_obligations where tenant_id=t and employee_id=p_employee_id),
 page as (select to_jsonb(o)||jsonb_build_object('balance',app_private.payroll_balance(t,o.obligation_id)) row from matching o order by period desc offset p_offset limit p_limit)
 select jsonb_build_object('entries',coalesce((select jsonb_agg(row) from page),'[]'),'total',(select count(*) from matching)) into result;
 return result;
end $$;

create function public.get_employee_activity(p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 12) returns jsonb language plpgsql stable security definer set search_path='' as $$
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
 select o.obligation_id,o.employee_id,'payroll','Monthly payroll prepared',o.created_at,o.period,o.created_by,o.base_amount,to_jsonb(o),'[]'::jsonb,false
 from public.payroll_obligations o where o.tenant_id=t and (nullif(p_filters->>'employee_id','') is null or o.employee_id=(p_filters->>'employee_id')::uuid)
 union all
 select a.adjustment_id,o.employee_id,'adjustment',a.kind||' · '||a.reason,a.created_at,o.period,a.created_by,a.amount,to_jsonb(a),'[]'::jsonb,
 a.reversal_of is null and not exists(select 1 from public.payroll_adjustments r where r.tenant_id=t and r.reversal_of=a.adjustment_id)
 from public.payroll_adjustments a join public.payroll_obligations o using(tenant_id,obligation_id) where a.tenant_id=t and (nullif(p_filters->>'employee_id','') is null or o.employee_id=(p_filters->>'employee_id')::uuid)
 union all
 select p.payment_id,p.employee_id,case when p.reversal_of is null then 'payment' else 'reversal' end,p.kind||coalesce(' · '||p.description,''),p.created_at,p.payment_date,p.created_by,
 case when p.reversal_of is null then p.amount else -p.amount end,to_jsonb(p)||jsonb_build_object('period',o.period),
 coalesce((select jsonb_agg(to_jsonb(en)||jsonb_build_object('transaction_id',wt.transaction_id) order by en.entry_id) from public.employee_payment_entries en left join public.wallet_transactions wt on wt.tenant_id=t and wt.employee_entry_id=en.entry_id where en.tenant_id=t and en.payment_id=p.payment_id),'[]'),
 p.reversal_of is null and p.source_snapshot is null and not exists(select 1 from public.employee_payments r where r.tenant_id=t and r.reversal_of=p.payment_id)
 and (p.transit_id is null or exists(select 1 from public.transits tr where tr.tenant_id=t and tr.transit_id=p.transit_id and tr.closed_at is null))
 from public.employee_payments p left join public.payroll_obligations o using(tenant_id,obligation_id) where p.tenant_id=t and (nullif(p_filters->>'employee_id','') is null or p.employee_id=(p_filters->>'employee_id')::uuid)
 ), matching as materialized (
 select ev.*,e.name employee_name,u.full_name actor from events ev join public.employees e on e.tenant_id=t and e.employee_id=ev.employee_id
 left join public.user_profiles u on u.tenant_id=t and u.user_id=ev.created_by
 where (nullif(p_filters->>'kind','') is null or ev.kind=p_filters->>'kind')
 and (nullif(p_filters->>'from','') is null or ev.date>=(p_filters->>'from')::date)
 and (nullif(p_filters->>'to','') is null or ev.date<=(p_filters->>'to')::date)
 and app_private.employee_search(concat_ws(' ',e.name,ev.description,ev.kind,ev.id,ev.wallets,ev.details),p_filters->>'search')),
 page as (select * from matching order by created_at desc,id desc offset p_offset limit p_limit)
 select jsonb_build_object('entries',coalesce((select jsonb_agg(to_jsonb(p)) from page p),'[]'),'total',(select count(*) from matching)) into result;
 return result;
end $$;

create function public.get_transit_payroll(p_transit_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['logistics:view','logistics:manage']);
begin
 if not exists(select 1 from public.transits where tenant_id=t and transit_id=p_transit_id) then raise exception 'Transit not found'; end if;
 return jsonb_build_object('driver_paid',app_private.transit_employee_paid(t,p_transit_id,'driver'),'helper_paid',app_private.transit_employee_paid(t,p_transit_id,'helper'),
 'paid',app_private.transit_employee_paid(t,p_transit_id),
 'payments',case when app_private.has_any_permission(array['payroll:view','payroll:pay']) then (select coalesce(jsonb_agg(jsonb_build_object('payment_id',p.payment_id,'name',e.name,'role',p.trip_role,'amount',case when p.reversal_of is null then p.amount else -p.amount end,'date',p.payment_date) order by p.created_at),'[]') from public.employee_payments p join public.employees e using(tenant_id,employee_id) where p.tenant_id=t and p.transit_id=p_transit_id) else '[]'::jsonb end);
end $$;
create function public.get_employee_for_payment(p_payment_id uuid) returns uuid language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['employees:view','employees:manage','payroll:view','payroll:pay']); eid uuid;
begin
 select employee_id into eid from public.employee_payments where tenant_id=t and payment_id=p_payment_id;
 if not found then raise exception 'Employee payment not found'; end if; return eid;
end $$;
create function public.get_trip_payment_wallets(p_transit_id uuid) returns table(wallet_id uuid,name text,kind text,type text) language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('payroll:pay');
begin
 perform app_private.require_permission('logistics:manage');
 if not exists(select 1 from public.transits where tenant_id=t and transit_id=p_transit_id and closed_at is null) then raise exception 'Select a trip with open costs'; end if;
 return query select w.wallet_id,w.name,w.kind,w.type from public.wallets w where w.tenant_id=t and w.is_active order by (w.kind='logistics') desc,w.name,w.wallet_id;
end $$;
create or replace function public.get_payment_wallets() returns table(wallet_id uuid,name text,kind text,type text)
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['pos:sell','finance:view','finance:manage','purchases:manage','payroll:pay']);
begin return query select w.wallet_id,w.name,w.kind,w.type from public.wallets w where w.tenant_id=t and w.is_active and w.kind<>'logistics'
 order by case w.type when 'cash' then 0 when 'bkash' then 1 when 'nagad' then 2 when 'dealership' then 3 else 4 end,w.name,w.wallet_id; end $$;

-- Preserve existing transit workflow/revision checks, replacing only the cost
-- amount with the unpaid portion. Guard the source replacement during replay.
do $$ declare definition text; begin
 definition:=pg_get_functiondef('public.transition_transit(uuid,text,integer)'::regprocedure);
 if position('if tr.total_cost>0 then' in definition)=0 or position('wid,-tr.total_cost,' in definition)=0 then raise exception 'Unexpected transit closure definition'; end if;
 definition:=replace(definition,'if tr.total_cost>0 then','if tr.total_cost>app_private.transit_employee_paid(t,p_transit_id) then');
 definition:=replace(definition,'wid,-tr.total_cost,','wid,-(tr.total_cost-app_private.transit_employee_paid(t,p_transit_id)),');
 execute definition;
end $$;
create function app_private.guard_employee_trip_costs() returns trigger language plpgsql set search_path='' as $$
begin
 if new.driver_cost<app_private.transit_employee_paid(new.tenant_id,new.transit_id,'driver') or new.helper_cost<app_private.transit_employee_paid(new.tenant_id,new.transit_id,'helper') then
 raise exception 'Trip costs cannot be reduced below employee payments. Reverse those payments first.'; end if;
 return new;
end $$;
create trigger guard_employee_trip_costs before update on public.transits for each row execute function app_private.guard_employee_trip_costs();

-- Explicitly own/grant only the new contracts. No private helper is callable.
do $$ declare r record; begin
 for r in select oid::regprocedure f from pg_proc where pronamespace='app_private'::regnamespace and proname=any(array[
 'payroll_month','payroll_balance','employee_advance_remaining','employee_summary','prepare_employee_payroll','transit_employee_paid','employee_search','guard_employee_trip_costs']) loop
 execute format('alter function %s owner to postgres',r.f); execute format('revoke all on function %s from public,anon,authenticated',r.f); end loop;
 for r in select oid::regprocedure f from pg_proc where pronamespace='public'::regnamespace and proname=any(array[
 'save_employee','payroll_operation','get_employee_directory','get_employee_overview','get_employee_profile','get_employee_periods','get_employee_activity','get_transit_payroll','get_trip_payment_wallets','get_employee_for_payment']) loop
 execute format('alter function %s owner to postgres',r.f); execute format('revoke all on function %s from public,anon,authenticated',r.f);
 execute format('grant execute on function %s to authenticated',r.f); end loop;
end $$;
do $$ begin
 if exists(select 1 from employee_migration_preservation s where
 s.payments is distinct from (select md5(coalesce(jsonb_agg(jsonb_build_array(tenant_id,payment_id,employee_id,amount,payment_date,description,trip_count,created_at,created_by) order by tenant_id,payment_id)::text,'')) from public.employee_payments)
 or s.wallets is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(w) order by tenant_id,wallet_id)::text,'')) from public.wallets w)
 or s.ledger is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(w)-'employee_entry_id' order by tenant_id,transaction_id)::text,'')) from public.wallet_transactions w)
 or s.stock is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(i) order by tenant_id,item_id)::text,'')) from public.items i))
 then raise exception 'Payroll migration changed historical payments, wallets, ledger or stock'; end if;
end $$;
drop table employee_migration_preservation;
notify pgrst,'reload schema';
