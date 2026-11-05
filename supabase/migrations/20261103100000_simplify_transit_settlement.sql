-- Custom fees and completion costs use the canonical cash/employee ledgers atomically.
-- Historical records are not backfilled; open uncollected fees are confirmed at completion.
CREATE OR REPLACE FUNCTION public.create_custom_transit(p_payload jsonb, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('logistics:manage'); vehicle public.vehicles; id uuid; wid uuid;
 fee numeric:=app_private.purchase_money((p_payload->>'fee')::numeric); prior public.finance_requests;
 body jsonb:=jsonb_build_object('action','custom_transit','actor',auth.uid(),'body',p_payload); result jsonb;
begin perform app_private.require_permission('logistics:transits');
 if p_request_id is null or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'Transit details and request ID are required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload<>body then raise exception 'Request ID was already used with different details'; end if; return prior.result; end if;
 select * into vehicle from public.vehicles where tenant_id=t and vehicle_id=(p_payload->>'vehicle_id')::uuid for update;
 if not found or vehicle.status<>'idle' then raise exception 'Select a vehicle at Home'; end if;
 if nullif(trim(p_payload->>'client_name'),'') is null or length(p_payload->>'client_name')>200 or nullif(trim(p_payload->>'destination'),'') is null or length(p_payload->>'destination')>300 or length(p_payload->>'description')>1000 then raise exception 'Client and destination are required (up to 200 and 300 characters)'; end if;
 insert into public.transits(tenant_id,vehicle_id,status,transport_fee,client_name,destination,description)
  values(t,vehicle.vehicle_id,'active',fee,trim(p_payload->>'client_name'),trim(p_payload->>'destination'),p_payload->>'description') returning transit_id into id;
 if fee>0 then
  select wallet_id into wid from public.wallets where tenant_id=t and type='cash' and is_active;
  if wid is null then raise exception 'Activate Cash Register before starting this transit'; end if;
  perform public.record_operating_payment(jsonb_build_object('transit_id',id,'kind','client_receipt','payment_date',(now() at time zone 'Asia/Dhaka')::date,
   'payments',jsonb_build_array(jsonb_build_object('wallet_id',wid,'amount',fee))),gen_random_uuid());
 end if;
 update public.vehicles set status='going',updated_at=clock_timestamp() where tenant_id=t and vehicle_id=vehicle.vehicle_id;
 result:=jsonb_build_object('transit_id',id);
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid()); return result;
end $function$;

drop function public.transition_transit(uuid,text,integer);
CREATE FUNCTION public.transition_transit(p_transit_id uuid, p_action text, p_revision integer, p_costs jsonb default null)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('logistics:manage');tr public.transits;pid uuid;wid uuid;driver_due numeric;helper_due numeric;expense_due numeric;client_due numeric;
 today date:=(now() at time zone 'Asia/Dhaka')::date;
begin perform app_private.require_permission('logistics:transits');
 select purchase_id into pid from public.transits where tenant_id=t and transit_id=p_transit_id;
 if pid is not null then perform 1 from public.purchases where tenant_id=t and purchase_id=pid for update;end if;
 select * into tr from public.transits where tenant_id=t and transit_id=p_transit_id;if not found then raise exception 'Transit not found';end if;
 perform 1 from public.vehicles where tenant_id=t and vehicle_id=tr.vehicle_id for update;
 select * into tr from public.transits where tenant_id=t and transit_id=p_transit_id for update;
 if p_action='return' then raise exception 'Use Complete transit to settle costs and return the vehicle Home'; end if;
 if p_action is null or p_action not in ('complete','cancel') then raise exception 'Invalid transit action';end if;
 if p_action='complete' and tr.closed_at is not null or p_action='cancel' and tr.status='cancelled' then return jsonb_build_object('already_applied',true);end if;
 if tr.closed_at is not null then raise exception 'Completed transit is locked';end if;
 if p_revision is distinct from tr.revision then raise exception 'Transit changed. Reload before continuing.';end if;
 if pid is not null and (p_action='cancel' or tr.status='active') then raise exception 'Receive or cancel this shipment in Purchases before completing its transit';end if;
 if p_action='complete' then
 if p_costs is not null then
  perform public.save_transit_costs(p_transit_id,p_costs,p_revision);
  select * into tr from public.transits where tenant_id=t and transit_id=p_transit_id;
 end if;
 -- Lock the complete source set before wallets; existing payments count at their net amount.
 if tr.status='cancelled' and app_private.transit_client_paid(t,p_transit_id)>0 then raise exception 'Refund outstanding client collections before completing';end if;
 driver_due:=greatest(0,tr.driver_cost-app_private.transit_employee_paid(t,p_transit_id,'driver'));
 helper_due:=greatest(0,tr.helper_cost-app_private.transit_employee_paid(t,p_transit_id,'helper'));
 expense_due:=greatest(0,tr.total_cost-tr.driver_cost-tr.helper_cost-app_private.transit_operating_paid(t,p_transit_id));
 client_due:=case when pid is null and tr.status<>'cancelled' then greatest(0,tr.transport_fee-app_private.transit_client_paid(t,p_transit_id)) else 0 end;
 if driver_due+helper_due>0 then perform app_private.require_permission('payroll:pay'); end if;
 if expense_due+client_due>0 then perform app_private.require_permission('logistics:pay'); end if;
 if driver_due+helper_due+expense_due+client_due>0 then
  perform 1 from public.employees where tenant_id=t and employee_id in (tr.driver_employee_id,tr.helper_employee_id) order by employee_id for update;
  select wallet_id into wid from public.wallets where tenant_id=t and type='cash' and is_active for update;
  if wid is null then raise exception 'Activate Cash Register before completing this transit'; end if;
 end if;
 if client_due>0 then
  perform public.record_operating_payment(jsonb_build_object('transit_id',p_transit_id,'kind','client_receipt','payment_date',today,
   'payments',jsonb_build_array(jsonb_build_object('wallet_id',wid,'amount',client_due))),gen_random_uuid());
 end if;
 if driver_due>0 then
  perform public.employee_payment_operation(jsonb_build_object('action','pay','items',jsonb_build_array(jsonb_build_object(
   'employee_id',tr.driver_employee_id,'kind','trips','trip_count',1,'transit_id',p_transit_id,'trip_role','driver','payment_date',today,
   'payments',jsonb_build_array(jsonb_build_object('wallet_id',wid,'amount',driver_due))))),gen_random_uuid());
 end if;
 if helper_due>0 then
  perform public.employee_payment_operation(jsonb_build_object('action','pay','items',jsonb_build_array(jsonb_build_object(
   'employee_id',tr.helper_employee_id,'kind','trips','trip_count',1,'transit_id',p_transit_id,'trip_role','helper','payment_date',today,
   'payments',jsonb_build_array(jsonb_build_object('wallet_id',wid,'amount',helper_due))))),gen_random_uuid());
 end if;
 if expense_due>0 then
  perform public.record_operating_payment(jsonb_build_object('transit_id',p_transit_id,'kind','expense','payment_date',today,
   'payments',jsonb_build_array(jsonb_build_object('wallet_id',wid,'amount',expense_due))),gen_random_uuid());
 end if;
 update public.transits set status=case when status='cancelled' then status else 'completed' end,closed_at=clock_timestamp(),revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and transit_id=p_transit_id;
 else update public.transits set status='cancelled',revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and transit_id=p_transit_id;end if;
 if not exists(select 1 from public.transits where tenant_id=t and vehicle_id=tr.vehicle_id and status='active') and not exists(select 1 from public.purchases where tenant_id=t and vehicle_id=tr.vehicle_id and status='in_transit') then update public.vehicles set status='idle',updated_at=clock_timestamp() where tenant_id=t and vehicle_id=tr.vehicle_id;end if;
 if pid is not null then insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,pid,'transit_closed',auth.uid(),jsonb_build_object('transit_id',p_transit_id,'operating_cost',tr.total_cost));end if;
 return jsonb_build_object('transit_id',p_transit_id);
end $function$;

revoke all on function public.transition_transit(uuid,text,integer,jsonb) from public,anon;
grant execute on function public.transition_transit(uuid,text,integer,jsonb) to authenticated,service_role;

create or replace function public.get_transit_directory(p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 25)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['logistics:view','logistics:manage','employees:view','employees:manage','payroll:view','payroll:pay']);
 eid uuid:=nullif(p_filters->>'employee_id','')::uuid;vid uuid:=nullif(p_filters->>'vehicle_id','')::uuid;
 state text:=coalesce(p_filters->>'status','all');ordering text:=coalesce(p_filters->>'sort','date_desc');kind text:=coalesce(p_filters->>'type','all');
 f date:=nullif(p_filters->>'from','')::date;until date:=nullif(p_filters->>'to','')::date;result jsonb;
begin
 if not app_private.has_any_permission(array['logistics:view','logistics:manage']) and eid is null then raise exception 'Choose an employee';end if;
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 or length(coalesce(p_filters->>'search',''))>500 or f>until
 or state not in ('all','active','returned','completed','cancelled','outstanding','open','finalized') or ordering not in ('date_desc','date_asc') or kind not in ('all','purchase','custom','service') then raise exception 'Invalid transit filters';end if;
 with matching as materialized(
 select tr.transit_id id,tr.created_at date,'transit' entry_kind from public.transits tr join public.vehicles v using(tenant_id,vehicle_id)
 where tr.tenant_id=t and (vid is null or tr.vehicle_id=vid) and (eid is null or eid in(tr.driver_employee_id,tr.helper_employee_id))
 and (f is null or tr.created_at>=f::timestamp at time zone 'Asia/Dhaka') and (until is null or tr.created_at<(until+1)::timestamp at time zone 'Asia/Dhaka')
 and (kind='all' or kind='purchase' and tr.purchase_id is not null or kind='custom' and tr.purchase_id is null)
 and (state='all' or state='active' and tr.status='active' or state='returned' and tr.status='returned' and tr.closed_at is null
 or state='completed' and tr.closed_at is not null or state='cancelled' and tr.status='cancelled'
 or state='outstanding' and tr.closed_at is null and (tr.driver_cost>app_private.transit_employee_paid(t,tr.transit_id,'driver') or tr.helper_cost>app_private.transit_employee_paid(t,tr.transit_id,'helper') or tr.total_cost-tr.driver_cost-tr.helper_cost>app_private.transit_operating_paid(t,tr.transit_id)))
 and (nullif(p_filters->>'expense_category','') is null or exists(select 1 from app_private.transit_expense_breakdown(tr) c where c.category=p_filters->>'expense_category' and c.amount>0))
 and app_private.finance_search(concat_ws(' ',v.name,v.serial_no,tr.transit_id,tr.client_name,tr.destination,tr.description,tr.driver_name,tr.helper_name),coalesce(p_filters->>'search',''))
 union all
 select s.service_trip_id,s.service_date::timestamp at time zone 'Asia/Dhaka','service' from public.vehicle_service_trips s join public.vehicles v using(tenant_id,vehicle_id)
 where s.tenant_id=t and eid is null and app_private.has_any_permission(array['logistics:view','logistics:manage']) and kind in('all','service')
 and (vid is null or s.vehicle_id=vid) and (f is null or s.service_date>=f) and (until is null or s.service_date<=until)
 and (state='all' or state in('completed','finalized') and s.finalized_at is not null or state='open' and s.finalized_at is null
 or state='outstanding' and s.total_cost>app_private.service_paid(t,s.service_trip_id))
 and (nullif(p_filters->>'expense_category','') is null or exists(select 1 from jsonb_array_elements(s.expenses) e where e->>'category_name'=p_filters->>'expense_category' and (e->>'amount')::numeric>0))
 and app_private.finance_search(concat_ws(' ',v.name,v.serial_no,s.service_trip_id,s.title,s.expenses::text),coalesce(p_filters->>'search',''))),
 page as(select * from matching order by case when ordering='date_desc' then date end desc,case when ordering='date_asc' then date end,id desc,entry_kind offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(
 case when p.entry_kind='service' then app_private.service_json(t,p.id) else app_private.transit_json(t,p.id) end||jsonb_build_object('entry_kind',p.entry_kind)
 order by case when ordering='date_desc' then p.date end desc,case when ordering='date_asc' then p.date end,p.id desc,p.entry_kind) from page p),'[]')) into result;
 return result;
end $$;

notify pgrst,'reload schema';

