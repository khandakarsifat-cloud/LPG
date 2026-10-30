-- Earlier development journeys did not record participants. An operator may
-- identify their actual crew once, with a reason; current vehicle assignments
-- are never applied retroactively. Existing payment evidence must agree.
create function public.record_transit_crew(p_payload jsonb,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('logistics:manage'); tr public.transits;
 id uuid:=(p_payload->>'transit_id')::uuid; d uuid:=(p_payload->>'driver_employee_id')::uuid;
 h uuid:=nullif(p_payload->>'helper_employee_id','')::uuid; reason text:=trim(p_payload->>'reason');
 body jsonb:=jsonb_build_object('action','record_transit_crew','actor',auth.uid(),'body',p_payload);
 prior public.finance_requests; result jsonb; pid uuid;
begin
 if p_request_id is null or jsonb_typeof(p_payload) is distinct from 'object' or d is null or h=d or nullif(reason,'') is null or length(reason)>1000 then raise exception 'Identify the actual Driver, optional Helper and the source of this crew information'; end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload<>body then raise exception 'Request ID was already used with different details'; end if; return prior.result; end if;
 select purchase_id into pid from public.transits where tenant_id=t and transit_id=id;
 if pid is not null then perform 1 from public.purchases where tenant_id=t and purchase_id=pid for update; end if;
 select * into tr from public.transits where tenant_id=t and transit_id=id for update;
 if not found or tr.closed_at is not null or tr.crew_recorded_at is not null then raise exception 'Only an open journey with unrecorded crew can be attributed'; end if;
 if tr.helper_cost>0 and h is null then raise exception 'Identify the actual Helper for the saved helper earnings'; end if;
 if tr.revision is distinct from (p_payload->>'revision')::integer then raise exception 'Transit changed. Reload before recording crew.'; end if;
 perform 1 from public.employees where tenant_id=t and employee_id in (d,h) order by employee_id for update;
 if not exists(select 1 from public.employees where tenant_id=t and employee_id=d) or h is not null and not exists(select 1 from public.employees where tenant_id=t and employee_id=h) then raise exception 'Choose employees belonging to this business'; end if;
 if tr.driver_employee_id is not null and tr.driver_employee_id<>d or tr.helper_employee_id is not null and tr.helper_employee_id is distinct from h
  or exists(select 1 from public.employee_payments where tenant_id=t and transit_id=id and employee_id is distinct from case trip_role when 'driver' then d else h end) then raise exception 'Crew must agree with the existing employee payment evidence'; end if;
 insert into public.audit_logs(tenant_id,table_name,record_id,action,old_data,new_data,performed_by)
 values(t,'transits',id,'UPDATE',to_jsonb(tr),jsonb_build_object('driver_employee_id',d,'helper_employee_id',h,'attribution_reason',reason),auth.uid());
 update public.transits set driver_employee_id=d,helper_employee_id=h,
  driver_name=(select name from public.employees where tenant_id=t and employee_id=d),
  helper_name=(select name from public.employees where tenant_id=t and employee_id=h),
  crew_recorded_at=clock_timestamp(),revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and transit_id=id;
 if pid is not null then insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
  values(t,pid,'logistics_updated',auth.uid(),jsonb_build_object('transit_id',id,'crew_attribution_reason',reason,'driver_employee_id',d,'helper_employee_id',h)); end if;
 result:=jsonb_build_object('transit_id',id);
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid()); return result;
end $$;

-- Only this gated operation may fill the missing snapshot. Recorded snapshots
-- stay immutable, including after a role/status/vehicle reassignment.
do $$ declare definition text; marker text; begin
 definition:=pg_get_functiondef('app_private.capture_transit_crew()'::regprocedure);
 marker:='then raise exception ''Historical transit crew is locked'';';
 if position(marker in definition)=0 then raise exception 'Unexpected transit crew guard'; end if;
 definition:=replace(definition,marker,'then
  if old.crew_recorded_at is not null or new.crew_recorded_at is null or new.closed_at is not null or not exists(
   select 1 from public.audit_logs a where a.tenant_id=new.tenant_id and a.record_id=new.transit_id and a.table_name=''transits''
    and a.performed_by=auth.uid() and a.new_data->>''attribution_reason'' is not null
    and a.new_data->>''driver_employee_id''=new.driver_employee_id::text
    and (a.new_data->>''helper_employee_id'') is not distinct from new.helper_employee_id::text
    and a.created_at>=transaction_timestamp()) then raise exception ''Historical transit crew is locked''; end if;');
 execute definition;
end $$;
alter function public.record_transit_crew(jsonb,uuid) owner to postgres;
revoke all on function public.record_transit_crew(jsonb,uuid) from public,anon;
grant execute on function public.record_transit_crew(jsonb,uuid) to authenticated;
notify pgrst,'reload schema';
