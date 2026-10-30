-- Run after attendance.sql inside the same outer rolled-back transaction.
set local role authenticated;
select set_config('request.jwt.claim.sub','a7222222-2222-4222-8222-222222222222',true);
do $$ declare e uuid; history jsonb; cash uuid; begin
 e:=(public.get_employee_directory('{"search":"Attendance fixture employee"}',0,25)->'entries'->0->>'employee_id')::uuid;
 history:=public.get_employee_activity(jsonb_build_object('employee_id',e,'kind','attendance'),0,100);
 perform pg_temp.attendance_assert((history->>'total')::integer=9,'all linked scans appear in the unified timeline');
 history:=public.get_employee_activity(jsonb_build_object('employee_id',e,'kind','attendance','from','2026-10-20','to','2026-10-20'),0,100);
 perform pg_temp.attendance_assert((history->>'total')::integer=3,'attendance date filters use device workday');
 perform pg_temp.attendance_assert(history->'entries'->0->>'description'='Clock out' and history->'entries'->2->>'description'='Clock in','scans sort by event time and identify first and last');
 perform pg_temp.attendance_assert(history->'entries'->0->>'occurred_at'='2026-10-20T10:30:00+00:00','late receipt never replaces activity event time');
 perform pg_temp.attendance_assert((public.get_employee_activity(jsonb_build_object('employee_id',e,'kind','terms'))->>'total')::integer=1,'employment revisions share the timeline');
 select wallet_id into cash from public.get_payment_wallets() where type='cash';
 perform public.employee_payment_operation(jsonb_build_object('action','pay','items',jsonb_build_array(jsonb_build_object(
  'employee_id',e,'kind','bonus','bonus_name','Unified timeline fixture bonus','payment_date',(now() at time zone 'Asia/Dhaka')::date,
  'payments',jsonb_build_array(jsonb_build_object('wallet_id',cash,'amount',100))))),gen_random_uuid());
 perform pg_temp.attendance_assert((public.get_employee_activity(jsonb_build_object('employee_id',e,'kind','payment'))->>'total')::integer=1,'financial activity remains visible to payroll capabilities');
 perform pg_temp.attendance_assert((public.get_employee_activity(jsonb_build_object('employee_id',e,'kind','attendance'),0,2)->'entries')::text not like '%Unified timeline fixture bonus%','attendance filtering excludes payments');
end $$;
reset role;
-- Exercise employee-only and payroll-only roles using these disposable fixtures.
delete from public.role_permissions where tenant_id='a7111111-1111-4111-8111-111111111111' and permission_id not in ('employees:view');
set local role authenticated;
select set_config('request.jwt.claim.sub','a7222222-2222-4222-8222-222222222222',true);
select pg_temp.attendance_assert((public.get_employee_activity('{"kind":"attendance"}')->>'total')::integer=9,'employee reader can see attendance');
select pg_temp.attendance_assert((public.get_employee_activity('{"kind":"payment"}')->>'total')::integer=0,'employee reader cannot see payments');
select pg_temp.attendance_assert(not exists(select 1 from jsonb_array_elements(public.get_employee_activity('{"kind":"terms"}')->'entries') x where x->>'amount' is not null or x->'details' ? 'monthly_salary'),'employee reader does not gain salary revision amounts');
reset role;
delete from public.role_permissions where tenant_id='a7111111-1111-4111-8111-111111111111';
insert into public.role_permissions(tenant_id,role_id,permission_id) values('a7111111-1111-4111-8111-111111111111','a7444444-4444-4444-8444-444444444444','payroll:view');
set local role authenticated;
select pg_temp.attendance_assert((public.get_employee_activity('{"kind":"attendance"}')->>'total')::integer=0,'payroll-only reader cannot see device scans');
select pg_temp.attendance_assert((public.get_employee_activity('{"kind":"payment"}')->>'total')::integer=1,'payroll-only reader retains financial history');
select set_config('request.jwt.claim.sub','a8222222-2222-4222-8222-222222222222',true);
select pg_temp.attendance_assert((public.get_employee_activity()->>'total')::integer=0,'foreign tenant receives no profile timeline evidence');
reset role;
select 'PASS: unified timeline sorting, attendance/payment filters, employee-only and payroll-only permissions, and tenant isolation';
