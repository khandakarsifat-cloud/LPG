-- Only runs inside the disposable database created by run-attendance.mjs.
begin;
create function pg_temp.registration_check(ok boolean,note text) returns void language plpgsql as $$
begin if ok is not true then raise exception 'FAIL: %',note;end if;end $$;
create function pg_temp.registration_reject(statement text,expected text) returns void language plpgsql as $$
begin
 begin execute statement;exception when others then
  if position(lower(expected) in lower(sqlerrm))=0 then raise exception 'Expected %; got %',expected,sqlerrm;end if;
  return;
 end;
 raise exception 'FAIL: expected rejection';
end $$;
grant execute on function pg_temp.registration_reject(text,text) to authenticated,attendance_receiver;
grant execute on function pg_temp.registration_check(boolean,text) to authenticated,attendance_receiver;
insert into auth.users(id,email,is_anonymous) values
 ('dd111111-1111-4111-8111-111111111111','device-transfer-a@example.invalid',false),
 ('dd222222-2222-4222-8222-222222222222','device-transfer-b@example.invalid',false);
select pg_temp.fixture_identity('dd111111-1111-4111-8111-111111111111');
select pg_temp.fixture_business('Device registration fixture A','Fixture A');
select pg_temp.fixture_identity('dd222222-2222-4222-8222-222222222222');
select pg_temp.fixture_business('Device registration fixture B','Fixture B');
create temporary table registration_fixture(a uuid,b uuid,old_device uuid,new_device uuid,employee_a uuid,employee_b uuid,old_history jsonb);
insert into registration_fixture(a,b) select
 (select tenant_id from public.user_profiles where user_id='dd111111-1111-4111-8111-111111111111'),
 (select tenant_id from public.user_profiles where user_id='dd222222-2222-4222-8222-222222222222');
grant select,update on registration_fixture to authenticated;
set local role authenticated;
select pg_temp.fixture_identity('dd111111-1111-4111-8111-111111111111');
do $$declare d uuid;e uuid;begin
 d:=(public.save_attendance_device(null,'ATT-TRANSFER-SQL','Original machine','register')->>'device_id')::uuid;
 perform public.save_attendance_device(d,null,null,'approve');
 e:=(public.save_employee('{"name":"Original employee","employee_type_name":"Driver","business_unit":"gas_business","phones":[{"phone":"01700000081","is_primary":true}],"terms":{"monthly_salary":100,"effective_from":"2026-01-01","is_active":true}}',gen_random_uuid())->>'employee_id')::uuid;
 perform public.set_employee_attendance_link(e,d,'001',null);
 update registration_fixture set old_device=d,employee_a=e;
end $$;
reset role;
-- Arrange historical/offline evidence without changing machine or server clocks.
update public.attendance_devices set accept_events_from='2026-01-01' where device_id=(select old_device from registration_fixture);
update public.attendance_links set linked_at='2026-01-01' where device_id=(select old_device from registration_fixture);
set local role attendance_receiver;
select public.attendance_receive('ATT-TRANSFER-SQL','upload','[{"pin":"001","timestamp":"2026-10-01 08:00:00","status":"0","verify":"1","workcode":"0","key":"1111111111111111111111111111111111111111111111111111111111111111"}]','10');
reset role;
set local role authenticated;
select pg_temp.fixture_identity('dd222222-2222-4222-8222-222222222222');
select pg_temp.registration_reject($q$select public.save_attendance_device(null,'ATT-TRANSFER-SQL','Duplicate','register')$q$,'already registered');
select pg_temp.registration_reject(format('select public.save_attendance_device(%L,null,null,''remove'')',old_device),'Device not found') from registration_fixture;
select pg_temp.fixture_identity('dd111111-1111-4111-8111-111111111111');
update registration_fixture set old_history=public.get_attendance_history(employee_a);
select public.save_attendance_device(old_device,null,null,'remove') from registration_fixture;
select pg_temp.registration_check(public.get_attendance_history(employee_a)=old_history,'removal preserves original employee history') from registration_fixture;
reset role;
select pg_temp.registration_check((select bool_and(l.unlinked_at=d.removed_at) from public.attendance_links l join public.attendance_devices d using(tenant_id,device_id) where d.device_id=f.old_device),'all links close at exact removal instant') from registration_fixture f;
set local role attendance_receiver;
select pg_temp.registration_reject($q$select public.attendance_receive('ATT-TRANSFER-SQL','upload','[]','11')$q$,'Unauthorized');
reset role;
set local role authenticated;
select pg_temp.fixture_identity('dd222222-2222-4222-8222-222222222222');
do $$declare d uuid;begin
 d:=(public.save_attendance_device(null,'ATT-TRANSFER-SQL','Moved machine','register')->>'device_id')::uuid;
 update registration_fixture set new_device=d;
 perform pg_temp.registration_check(d<>(select old_device from registration_fixture),'reuse creates a separate registration');
end $$;
reset role;
select pg_temp.registration_check(not d.enabled and d.approved_at is null and d.accept_events_from=d.created_at and d.accept_events_from>old.removed_at and d.stamp='0','fresh approval, timestamp boundary and sync stamp')
 from registration_fixture f join public.attendance_devices d on d.device_id=f.new_device join public.attendance_devices old on old.device_id=f.old_device;
set local role attendance_receiver;
select pg_temp.registration_reject($q$select public.attendance_receive('ATT-TRANSFER-SQL','heartbeat','[]',null)$q$,'Unauthorized');
reset role;
set local role authenticated;
select public.save_attendance_device(new_device,null,null,'approve') from registration_fixture;
select pg_temp.registration_check((public.get_attendance_configuration()->'devices'->0->>'unmapped')::int=0,'no inherited machine users');
reset role;
set local role attendance_receiver;
-- Old PINs, including an unknown PIN, must not appear in the new business.
select pg_temp.registration_check((public.attendance_receive('ATT-TRANSFER-SQL','upload','[
 {"pin":"001","timestamp":"2026-10-01 08:00:00","status":"0","verify":"1","workcode":"0","key":"1111111111111111111111111111111111111111111111111111111111111111"},
 {"pin":"OLD-PRIVATE-PIN","timestamp":"2026-10-02 08:00:00","status":"0","verify":"1","workcode":"0","key":"2222222222222222222222222222222222222222222222222222222222222222"}
 ]','12')->>'ignored_before_registration')::int=2,'old backlog is acknowledged and skipped');
reset role;
select pg_temp.registration_check(not exists(select 1 from public.attendance_events where device_id=f.new_device) and not exists(select 1 from public.attendance_users where device_id=f.new_device),'old raw events and identities never cross tenants') from registration_fixture f;
select pg_temp.registration_check(d.stamp='12' and d.last_event_at is null and d.last_ignored_count=2,'committed stamp and skipped-count diagnostics without false last event') from registration_fixture f join public.attendance_devices d on d.device_id=f.new_device;
set local role authenticated;
do $$declare e uuid;d uuid;begin
 select new_device into d from registration_fixture;
 e:=(public.save_employee('{"name":"New employee","employee_type_name":"Driver","business_unit":"gas_business","phones":[{"phone":"01700000082","is_primary":true}],"terms":{"monthly_salary":100,"effective_from":"2026-01-01","is_active":true}}',gen_random_uuid())->>'employee_id')::uuid;
 perform pg_temp.registration_check((public.get_attendance_history(e)->>'total')::int=0,'new employee has no old attendance');
 perform public.set_employee_attendance_link(e,d,'001',null);
 update registration_fixture set employee_b=e;
end $$;
reset role;
set local role attendance_receiver;
do $$declare batch jsonb;result jsonb;begin
 batch:=jsonb_build_array(jsonb_build_object('pin','001','timestamp',to_char((clock_timestamp()+interval '2 seconds') at time zone 'Asia/Dhaka','YYYY-MM-DD HH24:MI:SS'),'status','0','verify','1','workcode','0','key',repeat('3',64)),
 jsonb_build_object('pin','OLD-PRIVATE-PIN','timestamp','2026-10-02 08:00:00','status','0','verify','1','workcode','0','key',repeat('2',64)));
 result:=public.attendance_receive('ATT-TRANSFER-SQL','upload',batch,'13');
 perform pg_temp.registration_check((result->>'inserted')::int=1 and (result->>'ignored_before_registration')::int=1,'mixed packet keeps only new registration evidence');
 result:=public.attendance_receive('ATT-TRANSFER-SQL','upload',batch,'13');
 perform pg_temp.registration_check((result->>'inserted')::int=0,'interrupted transfer replay is idempotent');
end $$;
reset role;
set local role authenticated;
select pg_temp.registration_check((public.get_attendance_history(employee_b)->>'total')::int=1,'fresh employee link attributes only new punches') from registration_fixture;
select pg_temp.fixture_identity('dd111111-1111-4111-8111-111111111111');
select pg_temp.registration_check(public.get_attendance_history(employee_a)=old_history,'old business history unchanged after new-business uploads') from registration_fixture;
select pg_temp.registration_reject(format('select public.get_attendance_history(%L)',employee_b),'Employee not found') from registration_fixture;
select pg_temp.registration_reject(format('select public.save_attendance_device(%L,null,null,''remove'')',new_device),'Device not found') from registration_fixture;
select pg_temp.registration_reject($q$select public.save_attendance_device(null,'ATT-TRANSFER-SQL','Duplicate','register')$q$,'already registered');
reset role;
select 'PASS: cross-business device reuse, exact link closure, fresh approval and links, old-backlog privacy, mixed uploads, stamp continuation, replay deduplication and historical tenant isolation';
rollback;
