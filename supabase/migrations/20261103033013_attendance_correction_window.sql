-- Read-only correction bounds also exist for days without a saved attendance row.
do $$declare definition text;begin
 select pg_get_functiondef('public.get_attendance_edit(uuid,date)'::regprocedure) into definition;
 definition:=replace(definition,'result jsonb;','result jsonb; zone text; starts timestamptz; ends timestamptz;');
 definition:=replace(definition,$target$ return jsonb_build_object('day',result,$target$,$replacement$
 select coalesce((select timezone from public.attendance_settings where tenant_id=t),'Asia/Dhaka') into zone;
 starts:=coalesce((result->>'starts_at')::timestamptz,(p_day+app_private.attendance_boundary(t,p_day)) at time zone zone);
 ends:=coalesce((result->>'ends_at')::timestamptz,(p_day+1+app_private.attendance_boundary(t,p_day+1)) at time zone zone);
 return jsonb_build_object('window',jsonb_build_object('starts_at',starts,'ends_at',ends,'latest_at',least(ends,clock_timestamp())),'day',result,$replacement$);

 if definition not like '%latest_at%' then raise exception 'Attendance bounds function contract changed';end if;
 execute definition;
end $$;
