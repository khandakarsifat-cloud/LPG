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
select pg_temp.reject_attendance($q$select public.attendance_receive('UNKNOWN','upload','[]',null)$q$,'Unauthorized');
select pg_temp.reject_attendance('select * from public.attendance_events','permission denied');
select public.attendance_receive('ATT-HISTORY-SQL','upload','[
 {"pin":"001","timestamp":"2026-10-19 08:00:00","status":"0","verify":"1","workcode":"0","key":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
 {"pin":"001","timestamp":"2026-10-20 09:00:00","status":"0","verify":"1","workcode":"0","key":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
 {"pin":"001","timestamp":"2026-10-20 17:00:00","status":"0","verify":"1","workcode":"0","key":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},
 {"pin":"001","timestamp":"2026-10-20 09:00:00","status":"0","verify":"1","workcode":"0","key":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},
 {"pin":"001","timestamp":"2026-10-21 10:00:00","status":"0","verify":"1","workcode":"0","key":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}
]','1');
select pg_temp.check_attendance((public.attendance_receive('ATT-HISTORY-SQL','upload','[{"pin":"001","timestamp":"2026-10-20 09:00:00","status":"0","verify":"1","workcode":"0","key":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]','1')->>'inserted')::int=0,'upload retry deduplicates raw event');
reset role;
set local role authenticated;
do $$ declare e uuid;h jsonb;v bigint;id uuid:=gen_random_uuid();roleid text;begin
 e:=(public.get_employee_directory()->'entries'->0->>'employee_id')::uuid;
 h:=public.get_attendance_history(e,'daily',null,null,0);
 perform pg_temp.check_attendance((h->>'total')::int=2,'punch before linking not adopted');
 perform pg_temp.check_attendance((h->'entries'->0->>'automatic_close')::boolean,'single punch automatically closes at midnight');
 perform pg_temp.check_attendance((h->'entries'->0->>'worked_seconds')::int=50400,'missing clock-out is fourteen hours to midnight');
 perform pg_temp.check_attendance((h->'entries'->1->>'worked_seconds')::int=28800,'duplicates do not inflate worked time');
 perform pg_temp.check_attendance((public.get_employee_activity(jsonb_build_object('employee_id',e,'kind','attendance'),0,12)->>'total')::int=4,'daily activity has exactly one clock-in and one clock-out');
 perform pg_temp.check_attendance((public.get_attendance_history(e,'weekly')->'entries'->0->>'attended_days')::int=2,'weekly attended-day summary');
 v:=(public.get_attendance_edit(e,'2026-10-20')->'day'->>'revision')::bigint;
 perform public.correct_employee_attendance(e,'2026-10-20','2026-10-20T08:00:00','2026-10-20T18:00:00','Correct missed times',v,id);
 perform public.correct_employee_attendance(e,'2026-10-20','2026-10-20T08:00:00','2026-10-20T18:00:00','Correct missed times',v,id);
 perform pg_temp.check_attendance((public.get_attendance_history(e,'daily')->'entries'->1->>'worked_seconds')::int=36000,'correction changes daily summary');
 perform pg_temp.check_attendance(jsonb_array_length(public.get_attendance_edit(e,'2026-10-20')->'adjustments')=1,'correction retry creates one immutable audit');
 perform pg_temp.reject_attendance(format('select public.correct_employee_attendance(%L,''2026-10-20'',''2026-10-20T07:00:00'',''2026-10-20T18:00:00'',''stale'',%s,gen_random_uuid())',e,v),'changed');
 perform public.correct_employee_attendance(e,'2026-10-22','2026-10-22T08:00:00','2026-10-22T16:00:00','Manual day without scans',0,gen_random_uuid());
 perform pg_temp.check_attendance((public.get_attendance_history(e,'monthly')->'entries'->0->>'attended_days')::int=3,'manual day included in monthly total');
 perform public.correct_employee_attendance(e,'2026-10-24','2026-10-24T08:00:00',null,'Missing manual departure',0,gen_random_uuid());
 perform pg_temp.check_attendance((public.get_attendance_history(e,'daily','2026-10-24','2026-10-24')->'entries'->0->>'worked_seconds')::int=57600,'manual missing departure also closes at midnight');
 perform public.correct_employee_attendance(e,'2026-10-24',null,null,'Clear non-attended day',(public.get_attendance_edit(e,'2026-10-24')->'day'->>'revision')::bigint,gen_random_uuid());
 perform pg_temp.check_attendance((public.get_attendance_history(e,'monthly')->'entries'->0->>'attended_days')::int=3,'clearing both times removes day from attendance total');
 roleid:=(select r->>'id' from jsonb_array_elements(public.get_business_catalogs()->'roles')r where r->>'name'='Driver');
 perform pg_temp.reject_attendance(format('select public.save_business_catalog(''role'',%L,''Driver'',false,true)',roleid),'Predefined');
end $$;
reset role;
do $$ declare t uuid;begin
 select tenant_id into t from att_fixture;
 perform pg_temp.check_attendance((select count(*)=5 from public.attendance_events where tenant_id=t),'raw machine records preserved after corrections');
 perform pg_temp.reject_attendance(format('update public.attendance_events set status=''1'' where tenant_id=%L',t),'immutable');
 perform pg_temp.reject_attendance(format('delete from public.attendance_adjustments where tenant_id=%L',t),'immutable');
end $$;
-- Unlinking ends attribution by punch time, not arrival time. Reuse starts a
-- new period while the former employee keeps their original attendance.
do $$ declare t uuid;e uuid;d uuid;begin
 select tenant_id,employee,device into t,e,d from att_fixture;
 update public.attendance_links set unlinked_at='2026-10-23 12:00+06',unlinked_by='ab222222-2222-4222-8222-222222222222' where tenant_id=t;
end $$;
set local role authenticated;
do $$ declare d uuid;e uuid;begin
 d:=(public.get_attendance_configuration()->'devices'->0->>'device_id')::uuid;
 e:=(public.save_employee(jsonb_build_object('name','Replacement employee','employee_type_name','Helper','business_unit','gas_business','phones',jsonb_build_array(jsonb_build_object('phone','01700000072','is_primary',true)),
 'terms',jsonb_build_object('monthly_salary',10000,'effective_from','2026-01-01','is_active',true),'attendance_links',jsonb_build_array(jsonb_build_object('device_id',d,'pin','001','expected',null))),gen_random_uuid())->>'employee_id')::uuid;
 perform pg_temp.check_attendance((public.get_attendance_history(e)->>'total')::int=0,'reused ID does not retroactively assign earlier punches');
end $$;
reset role;
update att_fixture set second_employee=(select employee_id from public.employees where tenant_id=att_fixture.tenant_id and name='Replacement employee');
update public.attendance_links set linked_at='2026-10-23 12:00+06' where tenant_id=(select tenant_id from att_fixture) and employee_id=(select second_employee from att_fixture);
set local role attendance_receiver;
select public.attendance_receive('ATT-HISTORY-SQL','upload','[
 {"pin":"001","timestamp":"2026-10-23 10:00:00","status":"0","verify":"1","workcode":"0","key":"1111111111111111111111111111111111111111111111111111111111111111"},
 {"pin":"001","timestamp":"2026-10-23 12:00:00","status":"0","verify":"1","workcode":"0","key":"2222222222222222222222222222222222222222222222222222222222222222"},
 {"pin":"001","timestamp":"2026-10-23 18:00:00","status":"0","verify":"1","workcode":"0","key":"3333333333333333333333333333333333333333333333333333333333333333"}
]','2');
reset role;
do $$ declare t uuid;e uuid;other_e uuid;begin
 select tenant_id,employee,second_employee into t,e,other_e from att_fixture;
 perform pg_temp.check_attendance((select first_at='2026-10-23 10:00+06' from public.attendance_days where tenant_id=t and employee_id=e and work_date='2026-10-23'),'delayed punch inside old period belongs to former employee');
 perform pg_temp.check_attendance((select first_at='2026-10-23 12:00+06' and last_at='2026-10-23 18:00+06' from public.attendance_days where tenant_id=t and employee_id=other_e and work_date='2026-10-23'),'half-open link boundary assigns punch exactly once');
 -- Synthesize many summaries only in the disposable DB to check SQL paging.
 for n in 1..30 loop perform app_private.ensure_attendance_day(t,other_e,'2026-08-01'::date+n);end loop;
end $$;
set local role authenticated;
do $$ declare e uuid;d uuid;l uuid;h jsonb;before_day jsonb;begin
 e:=(public.get_employee_directory('{"search":"Replacement employee"}')->'entries'->0->>'employee_id')::uuid;
 h:=public.get_attendance_history(e,'daily');
 perform pg_temp.check_attendance((h->>'total')::int=31 and jsonb_array_length(h->'entries')=12,'attendance history uses bounded server pages');
 perform pg_temp.check_attendance(jsonb_array_length(public.get_attendance_history(e,'daily',null,null,24)->'entries')=7,'last attendance history page');
 d:=(public.get_attendance_configuration()->'devices'->0->>'device_id')::uuid;
 l:=(public.get_employee_attendance(e,'2026-10-01')->'links'->0->>'link_id')::uuid;
 perform public.set_employee_attendance_link(e,d,null,l);
 perform public.set_employee_attendance_link(e,d,'009',null);
 perform pg_temp.check_attendance((select count(*) from jsonb_array_elements(public.get_employee_attendance(e,'2026-10-01')->'links')r where r->>'unlinked_at' is null)=1,'unlink then link new ID keeps one current association');
 before_day:=public.get_attendance_edit(e,'2026-10-23')->'day';
 perform public.save_attendance_configuration('Asia/Dhaka','04:00');
 perform pg_temp.check_attendance(public.get_attendance_edit(e,'2026-10-23')->'day'=before_day,'cutoff change preserves previous workday');
 perform public.save_attendance_configuration('Asia/Dhaka','06:00');
 perform pg_temp.check_attendance(public.get_attendance_configuration()->>'next_cutoff'='06:00:00','saved pending cutoff remains visible');
 perform public.save_attendance_device(d,null,null,'disable');
end $$;
reset role;
set local role attendance_receiver;
select pg_temp.reject_attendance($q$select public.attendance_receive('ATT-HISTORY-SQL','heartbeat','[]',null)$q$,'Unauthorized');
reset role;
-- A future cutoff is also the current open day's ending boundary.
do $$ declare t uuid;e uuid;today date:=(now() at time zone 'Asia/Dhaka')::date;begin
 select tenant_id,second_employee into t,e from att_fixture;
 perform app_private.ensure_attendance_day(t,e,today);
 perform set_config('role','authenticated',true);
 perform public.save_attendance_configuration('Asia/Dhaka','02:00');
 perform set_config('role','none',true);
 perform app_private.ensure_attendance_day(t,e,today+1);
 perform pg_temp.check_attendance((select ends_at=(today+1+'02:00'::time) at time zone 'Asia/Dhaka' from public.attendance_days where tenant_id=t and employee_id=e and work_date=today),'open day follows future cutoff');
 perform pg_temp.check_attendance((select a.ends_at=b.starts_at from public.attendance_days a join public.attendance_days b on b.tenant_id=a.tenant_id and b.employee_id=a.employee_id and b.work_date=a.work_date+1 where a.tenant_id=t and a.employee_id=e and a.work_date=today),'cutoff transition has no overlap or gap');
 perform pg_temp.check_attendance(app_private.attendance_date(t,(today+1+'01:59'::time) at time zone 'Asia/Dhaka','Asia/Dhaka')=today,'delayed punch before new cutoff belongs to matching interval');
end $$;
-- Business timezone/DST boundaries are actual instants, not assumed 24h days.
do $$ declare t uuid;begin
 select tenant_id into t from att_fixture;
 update public.attendance_settings set timezone='America/New_York' where tenant_id=t;
 delete from public.attendance_cutoff_rules where tenant_id=t;
 insert into public.attendance_cutoff_rules values(t,'2000-01-01','00:00');
 perform app_private.ensure_attendance_day(t,(select second_employee from att_fixture),'2026-03-08');
 perform pg_temp.check_attendance((select extract(epoch from ends_at-starts_at)=23*3600 from public.attendance_days where tenant_id=t and work_date='2026-03-08'),'spring DST day is 23 hours');
 insert into public.attendance_cutoff_rules values(t,'2026-10-24','04:00');
 perform pg_temp.check_attendance(app_private.attendance_date(t,'2026-10-25 03:59-04','America/New_York')='2026-10-24','early morning before cutoff belongs to previous day');
 perform pg_temp.check_attendance(app_private.attendance_date(t,'2026-10-25 04:00-04','America/New_York')='2026-10-25','exact cutoff begins next workday');
 -- Employee read/manage capabilities do not grant attendance management.
 update public.user_roles set role_id=(select role_id from public.roles where tenant_id=t and name='SALESMAN') where tenant_id=t;
 insert into app_private.user_permission_sets values(t,'ab222222-2222-4222-8222-222222222222',array['employees:view','employees:manage']);
end $$;
set local role authenticated;
do $$ declare e uuid;begin
 e:=(public.get_employee_directory()->'entries'->0->>'employee_id')::uuid;
 perform pg_temp.reject_attendance(format('select public.get_attendance_edit(%L,''2026-10-20'')',e),'Permission');
end $$;
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub','ac222222-2222-4222-8222-222222222222',true);
select public.setup_business('Attendance foreign SQL fixture','Foreign operator');
select pg_temp.check_attendance(public.get_attendance_today()->'entries'='[]'::jsonb,'foreign tenant cannot read attendance');
reset role;
do $$ declare e uuid;begin
 select employee into e from att_fixture;
 perform set_config('role','authenticated',true);
 perform pg_temp.reject_attendance(format('select public.get_attendance_history(%L)',e),'Employee not found');
 perform pg_temp.reject_attendance(format('select public.get_attendance_edit(%L,''2026-10-20'')',e),'Employee not found');
end $$;
reset role;
select 'PASS: catalog seeding, predefined role validation, atomic employee/link creation, effective link start, raw deduplication, midnight close, daily/weekly/monthly summaries, manual corrections, stale revision rejection, idempotency, immutable evidence, individual appearance and tenant isolation';
