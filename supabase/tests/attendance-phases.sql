create function pg_temp.check_attendance(ok boolean,msg text) returns void language plpgsql as $$ begin if ok is not true then raise exception 'FAIL: %',msg; end if; end $$;
create function pg_temp.reject_attendance(q text,expected text) returns void language plpgsql as $$ begin
 begin execute q; exception when others then if position(lower(expected) in lower(sqlerrm))=0 then raise exception 'Expected %; got %',expected,sqlerrm; end if; return; end;
 raise exception 'Expected rejection: %',expected; end $$;
grant execute on function pg_temp.check_attendance(boolean,text),pg_temp.reject_attendance(text,text) to authenticated,attendance_receiver,anon;
insert into auth.users(id,email,is_anonymous) values('ab222222-2222-4222-8222-222222222222','attendance-history-fixture@example.invalid',false),('ac222222-2222-4222-8222-222222222222','attendance-history-foreign@example.invalid',false);
set local role authenticated;
select set_config('request.jwt.claim.sub','ab222222-2222-4222-8222-222222222222',true);
select public.setup_business('Attendance history SQL fixture','Fixture operator');
reset role;
create temporary table att_fixture as select tenant_id from public.user_profiles where user_id='ab222222-2222-4222-8222-222222222222';
alter table att_fixture add column employee uuid,add column device uuid,add column second_employee uuid;
set local role authenticated;
do $$ declare config jsonb;d uuid;e uuid;begin
 config:=public.get_business_catalogs();
 perform pg_temp.check_attendance(jsonb_array_length(config->'roles')=6,'six predefined roles seeded at business setup');
 perform public.save_business_catalog('role',null,'Technician',true,false);
 perform public.save_business_catalog('weight',null,'6.5',true,false);
 perform pg_temp.reject_attendance($q$select public.save_employee('{"name":"Bad role","employee_type_name":"Invented role","business_unit":"gas_business","phones":[{"phone":"01700000071","is_primary":true}],"terms":{"monthly_salary":100,"effective_from":"2026-01-01","is_active":true}}',gen_random_uuid())$q$,'Select an active');
 d:=(public.save_attendance_device(null,'ATT-HISTORY-SQL','Fixture terminal','register')->>'device_id')::uuid;
 perform public.save_attendance_device(d,null,null,'approve');
 e:=(public.save_employee(jsonb_build_object('name','Fixture employee','employee_type_name','Driver','business_unit','truck_business','phones',jsonb_build_array(jsonb_build_object('phone','01700000071','is_primary',true)),
 'terms',jsonb_build_object('monthly_salary',10000,'effective_from','2026-01-01','is_active',true),'attendance_links',jsonb_build_array(jsonb_build_object('device_id',d,'pin','001','expected',null))),gen_random_uuid())->>'employee_id')::uuid;
 perform pg_temp.check_attendance(jsonb_array_length(public.get_employee_attendance(e,'2026-10-01')->'links')=1,'creation and initial link saved together');
 perform pg_temp.reject_attendance(format('select public.save_employee(%L,gen_random_uuid())',jsonb_build_object('name','Atomic failure fixture','employee_type_name','Helper','business_unit','gas_business','phones',jsonb_build_array(jsonb_build_object('phone','01700000075','is_primary',true)),'terms',jsonb_build_object('monthly_salary',0,'effective_from','2026-01-01','is_active',true),'attendance_links',jsonb_build_array(jsonb_build_object('device_id',d,'pin','001','expected',null)))),'already linked');
 perform pg_temp.check_attendance((public.get_employee_directory('{"search":"Atomic failure fixture"}')->>'total')::int=0,'failed initial link rolls employee creation back');
 perform public.save_my_preferences('dark'); perform pg_temp.check_attendance(public.get_my_preferences()->>'theme'='dark','individual appearance saved');
end $$;
reset role;
update att_fixture set employee=(select employee_id from public.employees where tenant_id=att_fixture.tenant_id),device=(select device_id from public.attendance_devices where tenant_id=att_fixture.tenant_id);
-- Test-only backdating on the isolated database lets old date/DST/late-upload
-- scenarios execute without altering the clock or any application records.
update public.attendance_links set linked_at='2026-10-20 00:00+06' where tenant_id=(select tenant_id from att_fixture);
update public.attendance_devices set accept_events_from='2026-10-01 00:00+06' where tenant_id=(select tenant_id from att_fixture);
set local role attendance_receiver;
select public.attendance_receive('ATT-HISTORY-SQL','upload','[
 {"pin":"001","timestamp":"2026-10-19 09:00:00","status":"0","verify":"1","workcode":"0","key":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
 {"pin":"001","timestamp":"2026-10-20 09:00:00","status":"0","verify":"1","workcode":"0","key":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
 {"pin":"001","timestamp":"2026-10-20 10:00:00","status":"0","verify":"1","workcode":"0","key":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},
 {"pin":"001","timestamp":"2026-10-20 15:00:00","status":"0","verify":"1","workcode":"0","key":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},
 {"pin":"001","timestamp":"2026-10-20 17:00:00","status":"0","verify":"1","workcode":"0","key":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"},
 {"pin":"001","timestamp":"2026-10-20 16:00:00","status":"0","verify":"1","workcode":"0","key":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"},
 {"pin":"001","timestamp":"2026-10-21 17:00:00","status":"0","verify":"1","workcode":"0","key":"1111111111111111111111111111111111111111111111111111111111111111"},
 {"pin":"001","timestamp":"2026-10-22 09:00:00","status":"0","verify":"1","workcode":"0","key":"2222222222222222222222222222222222222222222222222222222222222222"}
]','1');
reset role;
do $$declare t uuid;e uuid;r bigint;begin
 select tenant_id,employee into t,e from att_fixture;
 perform pg_temp.check_attendance((select first_at='2026-10-20 09:00+06' and last_at='2026-10-20 17:00+06' and scan_count=2 from public.attendance_days where tenant_id=t and employee_id=e and work_date='2026-10-20'),'earliest arrival, latest departure and two endpoints');
 perform pg_temp.check_attendance((select count(*)=0 from public.attendance_events where tenant_id=t),'no per-punch rows retained');
 perform pg_temp.check_attendance((select clock_in is null and clock_out='2026-10-21 17:00+06' and worked_seconds=0 from app_private.attendance_rows(t,e,'2026-10-21','2026-10-21')),'departure without arrival remains missing arrival');
 perform pg_temp.check_attendance((select clock_out is null and not automatic_close from app_private.attendance_rows(t,e,'2026-10-22','2026-10-22')),'missing departure never auto-closes');
 select revision into r from public.attendance_days where tenant_id=t and employee_id=e and work_date='2026-10-20';
 perform public.attendance_receive('ATT-HISTORY-SQL','upload','[{"pin":"001","timestamp":"2026-10-20 10:00:00","status":"0","verify":"1","workcode":"0","key":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}]','2');
 perform pg_temp.check_attendance((select revision=r from public.attendance_days where tenant_id=t and employee_id=e and work_date='2026-10-20'),'intermediate/replayed arrival is a no-op');
 perform public.attendance_receive('ATT-HISTORY-SQL','upload','[{"pin":"001","timestamp":"2026-10-20 08:00:00","status":"0","verify":"1","workcode":"0","key":"3333333333333333333333333333333333333333333333333333333333333333"}]','3');
 perform pg_temp.check_attendance((select first_at='2026-10-20 08:00+06' and last_at='2026-10-20 17:00+06' from public.attendance_days where tenant_id=t and employee_id=e and work_date='2026-10-20'),'offline earlier arrival corrects same row');
 perform pg_temp.check_attendance(app_private.attendance_departure(t,'2026-10-20','Asia/Dhaka')='2026-10-20 15:00+06','midnight workday has afternoon departure threshold');
end $$;
set local role authenticated;
do $$declare e uuid;v bigint;begin
 e:=(public.get_employee_directory()->'entries'->0->>'employee_id')::uuid;
 v:=(public.get_attendance_edit(e,'2026-10-20')->'day'->>'revision')::bigint;
 perform public.correct_employee_attendance(e,'2026-10-20','2026-10-20T07:00:00','2026-10-20T19:00:00','Reviewed fixture correction',v,gen_random_uuid());
 perform pg_temp.check_attendance((public.get_attendance_history(e)->'entries'->2->>'worked_seconds')::int=43200,'manual correction remains authoritative');
 perform public.save_attendance_configuration('Asia/Dhaka','15:00');
 perform pg_temp.check_attendance(public.get_attendance_configuration()->>'next_clock_out_cutoff'='15:00:00','independent schedule saved');
 perform pg_temp.reject_attendance($q$select public.save_attendance_configuration('Asia/Dhaka','00:00')$q$,'valid');
end $$;
reset role;
do $$declare t uuid;begin
 select tenant_id into t from att_fixture;
 insert into public.attendance_cutoff_rules(tenant_id,effective_from,clock_out_cutoff) values(t,'2026-10-23','15:00');
 perform pg_temp.check_attendance(app_private.attendance_date(t,'2026-10-24 03:00+06','Asia/Dhaka')='2026-10-24','after-midnight punch belongs to its actual date');
 perform pg_temp.check_attendance(app_private.attendance_departure(t,'2026-10-23','Asia/Dhaka')='2026-10-23 15:00+06','departure threshold stays on the calendar date');
end $$;
set local role authenticated;
do $$declare e uuid;bounds jsonb;begin
 e:=(public.get_employee_directory()->'entries'->0->>'employee_id')::uuid;
 bounds:=public.get_attendance_edit(e,'2026-10-25')->'window';
 perform pg_temp.check_attendance((bounds->>'starts_at')::timestamptz='2026-10-25 00:00+06' and (bounds->>'ends_at')::timestamptz='2026-10-26 00:00+06','blank correction day exposes midnight bounds');
 perform pg_temp.reject_attendance(format($q$select public.correct_employee_attendance(%L,'2026-10-25','2026-10-25T06:00:00','2026-10-25T05:00:00','Reverse times',0,gen_random_uuid())$q$,e),'ordered');
 perform pg_temp.reject_attendance(format($q$select public.correct_employee_attendance(%L,'2026-10-25','2026-10-25T06:00:00','2026-10-25T06:00:00','Equal times',0,gen_random_uuid())$q$,e),'ordered');
 perform pg_temp.reject_attendance(format($q$select public.correct_employee_attendance(%L,'2026-10-25','2026-10-24T23:59:00','2026-10-25T18:00:00','Before start',0,gen_random_uuid())$q$,e),'ordered');
 perform pg_temp.reject_attendance(format($q$select public.correct_employee_attendance(%L,'2026-10-25','2026-10-25T06:00:00','2026-10-26T00:00:00','Past end',0,gen_random_uuid())$q$,e),'ordered');
 perform public.correct_employee_attendance(e,'2026-10-25','2026-10-25T06:00:00','2026-10-25T23:59:00','Last selectable calendar minute',0,gen_random_uuid());
 perform pg_temp.check_attendance((public.get_attendance_edit(e,'2026-10-25')->'day'->>'clock_out')::timestamptz='2026-10-25 23:59+06','manual departure stays on the selected date');
end $$;
reset role;
select 'PASS: correction windows for empty and saved days, calendar date bounds, reversed/equal times and out-of-range rejection, exclusive next-midnight boundary';
set local role authenticated;
select set_config('request.jwt.claim.sub','ac222222-2222-4222-8222-222222222222',true);
select public.setup_business('Attendance foreign SQL fixture','Foreign operator');
select pg_temp.check_attendance(public.get_attendance_today()->'entries'='[]'::jsonb,'foreign tenant cannot read attendance');
reset role;
select 'PASS: calendar dates and departure settings, compact daily storage, earliest arrival/latest departure, exact threshold, duplicate no-ops, delayed uploads, missing punches, manual corrections and tenant isolation';
