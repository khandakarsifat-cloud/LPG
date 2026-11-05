-- Replayed around the calendar migration only on the disposable database.
create function pg_temp.calendar_check(ok boolean,note text) returns void language plpgsql as $$
begin if ok is not true then raise exception 'FAIL: %',note;end if;end $$;
insert into auth.users(id,email,is_anonymous) values('ca111111-1111-4111-8111-111111111111','calendar-migration@example.invalid',false);
select pg_temp.fixture_identity('ca111111-1111-4111-8111-111111111111');
select pg_temp.fixture_business('Calendar migration disposable fixture','Fixture owner');
create temporary table calendar_fixture(t uuid,e uuid,d uuid,manual jsonb);
do $$declare t uuid;e uuid;d uuid;begin
 select tenant_id into t from public.user_profiles where user_id=auth.uid();
 update public.attendance_settings set cutoff='16:00' where tenant_id=t;
 insert into public.attendance_cutoff_rules(tenant_id,effective_from,cutoff,clock_out_cutoff) values(t,'2000-01-01','16:00','15:00');
 d:=(public.save_attendance_device(null,'CALENDAR-MIGRATION','Fixture terminal','register')->>'device_id')::uuid;
 perform public.save_attendance_device(d,null,null,'approve');
 e:=(public.save_employee(jsonb_build_object('name','Calendar fixture employee','employee_type_name','Driver','business_unit','gas_business',
 'phones',jsonb_build_array(jsonb_build_object('phone','01700000089','is_primary',true)),
 'terms',jsonb_build_object('monthly_salary',100,'effective_from','2026-01-01','is_active',true)),gen_random_uuid())->>'employee_id')::uuid;
 perform public.set_employee_attendance_link(e,d,'001',null);
 update public.attendance_devices set accept_events_from='2026-01-01' where device_id=d;
 update public.attendance_links set linked_at='2026-01-01' where device_id=d;
 perform public.attendance_receive('CALENDAR-MIGRATION','upload','[
 {"pin":"001","timestamp":"2026-11-01 20:43:09","status":"0","verify":"1","workcode":"0","key":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
 {"pin":"001","timestamp":"2026-11-03 00:10:22","status":"0","verify":"1","workcode":"0","key":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
 ]','1');
 perform pg_temp.calendar_check((select first_at='2026-11-03 00:10:22+06' from public.attendance_days where tenant_id=t and employee_id=e and work_date='2026-11-02'),'fixture captures obsolete shifted date');
 perform public.correct_employee_attendance(e,'2026-11-01','2026-11-01T18:00:00','2026-11-01T22:00:00','Preserved manual correction',
 (public.get_attendance_edit(e,'2026-11-01')->'day'->>'revision')::bigint,gen_random_uuid());
 insert into calendar_fixture values(t,e,d,(select jsonb_agg(to_jsonb(a)) from public.attendance_adjustments a where a.tenant_id=t));
end $$;
-- AFTER CALENDAR MIGRATION
do $$declare f record;begin
 select * into f from calendar_fixture;
 perform pg_temp.calendar_check((select first_at='2026-11-03 00:10:22+06' from public.attendance_days where tenant_id=f.t and employee_id=f.e and work_date='2026-11-03'),'endpoint without raw punch survives and moves to actual calendar date');
 perform pg_temp.calendar_check(not exists(select 1 from public.attendance_days where tenant_id=f.t and employee_id=f.e and work_date='2026-11-02'),'obsolete empty grouping is removed');
 perform pg_temp.calendar_check((select last_at='2026-11-01 20:43:09+06' and first_at is null from public.attendance_days where tenant_id=f.t and employee_id=f.e and work_date='2026-11-01'),'evening endpoint is classified as departure on its true date');
 perform pg_temp.calendar_check((select jsonb_agg(to_jsonb(a))=f.manual from public.attendance_adjustments a where a.tenant_id=f.t),'manual correction evidence remains byte-for-byte unchanged');
 perform pg_temp.calendar_check((public.get_attendance_edit(f.e,'2026-11-01')->'day'->>'clock_in')::timestamptz='2026-11-01 18:00+06','manual override remains authoritative');
 perform pg_temp.calendar_check(exists(select 1 from public.attendance_configuration_audit where tenant_id=f.t and details->>'normalization' like 'Calendar attendance%'),'previous grouping archived for audit');
 perform pg_temp.calendar_check((select bool_and(starts_at=work_date::timestamp at time zone timezone and ends_at=(work_date+1)::timestamp at time zone timezone) from public.attendance_days where tenant_id=f.t),'all new boundaries are actual midnights');
end $$;
