-- Run inside a rolled-back transaction, after replaying the new migration.
insert into public.tenants(tenant_id,business_name) values('a7111111-1111-4111-8111-111111111111','Attendance SQL fixture A'),('a8111111-1111-4111-8111-111111111111','Attendance SQL fixture B');
insert into auth.users(id,email,is_anonymous) values('a7222222-2222-4222-8222-222222222222','attendance-sql-a@example.invalid',false),('a8222222-2222-4222-8222-222222222222','attendance-sql-b@example.invalid',false);
insert into public.user_profiles(user_id,tenant_id,email) values('a7222222-2222-4222-8222-222222222222','a7111111-1111-4111-8111-111111111111','attendance-sql-a@example.invalid'),('a8222222-2222-4222-8222-222222222222','a8111111-1111-4111-8111-111111111111','attendance-sql-b@example.invalid');
insert into public.roles(tenant_id,role_id,name) values('a7111111-1111-4111-8111-111111111111','a7444444-4444-4444-8444-444444444444','OWNER'),('a8111111-1111-4111-8111-111111111111','a8444444-4444-4444-8444-444444444444','OWNER');
insert into public.role_permissions select r.tenant_id,r.role_id,p.permission_id from public.roles r cross join public.permissions p where r.tenant_id in ('a7111111-1111-4111-8111-111111111111','a8111111-1111-4111-8111-111111111111');
insert into public.user_roles values('a7111111-1111-4111-8111-111111111111','a7222222-2222-4222-8222-222222222222','a7444444-4444-4444-8444-444444444444'),('a8111111-1111-4111-8111-111111111111','a8222222-2222-4222-8222-222222222222','a8444444-4444-4444-8444-444444444444');
create function pg_temp.attendance_assert(ok boolean,msg text) returns void language plpgsql as $$ begin if ok is not true then raise exception 'FAIL: %',msg; end if; end $$;
create function pg_temp.attendance_reject(q text,expected text) returns void language plpgsql as $$ begin
 begin execute q; exception when others then if position(lower(expected) in lower(sqlerrm))=0 then raise exception 'Expected %; got %',expected,sqlerrm; end if; return; end;
 raise exception 'Expected rejection: %',expected; end $$;
grant execute on function pg_temp.attendance_assert(boolean,text),pg_temp.attendance_reject(text,text) to authenticated,attendance_receiver,anon;
set local role authenticated;
select set_config('request.jwt.claim.sub','a7222222-2222-4222-8222-222222222222',true);
select public.save_attendance_device(null,'ATTENDANCE-SQL-TEST','SQL device','203.0.113.10',true);
select public.save_employee('{"name":"Attendance fixture employee","phones":[{"phone":"01700000071","is_primary":true}],"business_unit":"gas_business","terms":{"monthly_salary":10000,"effective_from":"2025-01-01","is_active":true}}',gen_random_uuid());
select pg_temp.attendance_reject('select public.attendance_receive(''ATTENDANCE-SQL-TEST'',''203.0.113.10'',''heartbeat'',''[]'',null)','permission denied');
reset role;
set local role attendance_receiver;
select pg_temp.attendance_reject('select * from public.wallets','permission denied');
select pg_temp.attendance_reject('select * from public.attendance_devices','permission denied');
select pg_temp.attendance_reject('select public.attendance_receive(''ATTENDANCE-SQL-TEST'',''203.0.113.11'',''heartbeat'',''[]'',null)','Unregistered');
select public.attendance_receive('ATTENDANCE-SQL-TEST','203.0.113.10','upload','[
 {"pin":"001","timestamp":"2026-10-20 16:30:00","status":"0","verify":"1","workcode":"0","key":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
 {"pin":"001","timestamp":"2026-10-20 09:00:00","status":"0","verify":"1","workcode":"0","key":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
 {"pin":"001","timestamp":"2026-10-20 14:30:00","status":"0","verify":"1","workcode":"0","key":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},
 {"pin":"001","timestamp":"2026-10-21 16:30:00","status":"0","verify":"1","workcode":"0","key":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},
 {"pin":"002","timestamp":"2026-10-20 08:00:00","status":"0","verify":"1","workcode":"0","key":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"},
 {"pin":"001","timestamp":"2099-10-20 08:00:00","status":"0","verify":"1","workcode":"0","key":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"}
]','10');
select pg_temp.attendance_assert((public.attendance_receive('ATTENDANCE-SQL-TEST','203.0.113.10','upload','[{"pin":"001","timestamp":"2026-10-20 16:30:00","status":"0","verify":"1","workcode":"0","key":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]','10')->>'inserted')::integer=0,'upload retry is idempotent');
reset role;
do $$ declare t uuid:='a7111111-1111-4111-8111-111111111111'; d public.attendance_days; begin
 select * into d from public.attendance_days where tenant_id=t and pin='001' and work_date='2026-10-20';
 perform pg_temp.attendance_assert(d.first_at='2026-10-20 03:00:00+00' and d.last_after_cutoff='2026-10-20 10:30:00+00' and d.scan_count=3,'device time, Dhaka conversion, out-of-order and repeated scans');
 perform pg_temp.attendance_assert((select scan_count=0 and warning_count=1 from public.attendance_days where tenant_id=t and work_date='2099-10-20'),'future device time retained and quarantined');
 perform pg_temp.attendance_assert((select count(*)=6 from public.attendance_events where tenant_id=t),'all events retained, retry deduplicated');
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','a7222222-2222-4222-8222-222222222222',true);
do $$ declare t uuid:='a7111111-1111-4111-8111-111111111111'; d uuid; e uuid; other_e uuid; history jsonb; begin
 d:=(public.get_attendance_configuration()->'devices'->0->>'device_id')::uuid;
 e:=(public.get_employee_directory('{}',0,25)->'entries'->0->>'employee_id')::uuid;
 perform pg_temp.attendance_assert((public.get_attendance_users(d)->>'total')::integer=2,'unmapped users retained');
 perform public.link_attendance_user(d,'001',e);
 other_e:=(public.save_employee('{"name":"Other attendance fixture employee","phones":[{"phone":"01700000073","is_primary":true}],"business_unit":"gas_business","terms":{"monthly_salary":10000,"effective_from":"2025-01-01","is_active":true}}',gen_random_uuid())->>'employee_id')::uuid;
 perform pg_temp.attendance_reject(format('select public.link_attendance_user(%L,'' 001 '',%L)',d,other_e),'already belongs');
 history:=public.get_employee_attendance(e,'2026-10-01');
 perform pg_temp.attendance_assert(jsonb_array_length(history->'entries')=2,'link adopts unmapped history');
 perform pg_temp.attendance_assert(history->'entries'->0->>'clock_out' is null,'single after-cutoff scan is only clock-in');
 perform pg_temp.attendance_assert((history->'entries'->1->>'finalized')::boolean,'past days finalized');
 perform pg_temp.attendance_assert((public.get_employee_attendance_events(e,'2026-10-20')->>'total')::integer=3,'underlying scans returned');
 perform public.save_attendance_configuration('Asia/Dhaka','16:45');
 perform pg_temp.attendance_assert(public.get_employee_attendance(e,'2026-10-01')->'entries'->1->>'cutoff'='15:00:00','past cutoff preserved');
 perform pg_temp.attendance_reject('select public.save_attendance_configuration(''UTC'',''15:00'')','Timezone is fixed');
end $$;
select set_config('request.jwt.claim.sub','a8222222-2222-4222-8222-222222222222',true);
select pg_temp.attendance_assert(public.get_attendance_configuration()->'devices'='[]'::jsonb,'tenant isolation');
select pg_temp.attendance_assert(public.get_attendance_today()->'entries'='[]'::jsonb,'tenant presence isolation');
reset role;
do $$ declare eid uuid; device uuid; begin
 select employee_id into eid from public.employees where tenant_id='a7111111-1111-4111-8111-111111111111';
 select device_id into device from public.attendance_devices where serial='ATTENDANCE-SQL-TEST';
 perform set_config('role','authenticated',true);
 perform pg_temp.attendance_reject(format('select public.get_employee_attendance(%L,''2026-10-01'')',eid),'Employee not found');
 perform pg_temp.attendance_reject(format('select public.link_attendance_user(%L,''001'',%L)',device,eid),'Device or employee not found');
end $$;
reset role;
set local role attendance_receiver;
-- A newly received old workday must use its historical cutoff, even when no
-- attendance_days row existed before the owner changed today's settings.
select public.attendance_receive('ATTENDANCE-SQL-TEST','203.0.113.10','upload','[
 {"pin":"001","timestamp":"2026-10-19 09:00:00","status":"0","verify":"1","workcode":"0","key":"1111111111111111111111111111111111111111111111111111111111111111"},
 {"pin":"001","timestamp":"2026-10-19 16:00:00","status":"0","verify":"1","workcode":"0","key":"2222222222222222222222222222222222222222222222222222222222222222"}
]','9');
reset role;
select pg_temp.attendance_assert((select cutoff='15:00' and last_after_cutoff is not null from public.attendance_days where tenant_id='a7111111-1111-4111-8111-111111111111' and pin='001' and work_date='2026-10-19'),'newly arriving past day uses cutoff history');
set local role attendance_receiver;
select public.attendance_receive('ATTENDANCE-SQL-TEST','203.0.113.10','upload',jsonb_build_array(
 jsonb_build_object('pin','001','timestamp',to_char((now() at time zone 'Asia/Dhaka')::date,'YYYY-MM-DD')||' 00:01:00','status','0','verify','1','workcode','0','key',repeat('3',64)),
 jsonb_build_object('pin','001','timestamp',to_char((now() at time zone 'Asia/Dhaka')::date,'YYYY-MM-DD')||' 00:02:00','status','0','verify','1','workcode','0','key',repeat('4',64))),null);
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub','a7222222-2222-4222-8222-222222222222',true);
select public.save_attendance_configuration('Asia/Dhaka','00:01:30');
select pg_temp.attendance_assert((public.get_attendance_today()->'entries'->0->>'finalized')::boolean=false,'today remains provisional');
select pg_temp.attendance_assert(public.get_attendance_today()->'entries'->0->>'clock_out' is not null,'today cutoff recalculated from retained events');
reset role;
set local role anon;
select pg_temp.attendance_reject('select public.get_attendance_today()','permission denied');
select pg_temp.attendance_reject('select public.attendance_receive(''ATTENDANCE-SQL-TEST'',''203.0.113.10'',''heartbeat'',''[]'',null)','permission denied');
reset role;
select 'PASS: attendance event integrity, replay, timezone, clock warnings, mapping, cutoff snapshots, permissions and tenant isolation';
