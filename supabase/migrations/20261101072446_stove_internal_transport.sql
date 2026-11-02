-- Stove orders retain direct receipt by default. Optional internal delivery uses
-- the same dispatch, crew, wallet, transit and FIFO foundation as LPG purchases.
alter table public.purchases add constraint stove_has_no_lpg_commission check(business_category<>'stove' or commission=0);
alter table public.purchases drop constraint purchase_business_shape;
alter table public.purchases add constraint purchase_business_shape check(
 (business_category='lpg' and plant_id is not null) or
 (business_category='stove' and plant_id is null and brand_id is null and length(trim(supplier_name)) between 1 and 150 and commission=0));
do $$declare s text;begin
 s:=pg_get_functiondef('public.create_purchase(jsonb)'::regprocedure);
 s:=replace(s,'business_category,supplier_name,status,transport_cost,labour_cost,commission,notes,created_by,request_id,request_payload)',
 'business_category,supplier_name,vehicle_id,status,transport_cost,labour_cost,commission,notes,created_by,request_id,request_payload)');
 s:=replace(s,'values(t,''stove'',trim(p_payload->>''supplier_name''),''created'',0,0,0,',
 'values(t,''stove'',trim(p_payload->>''supplier_name''),(p_payload->>''vehicle_id'')::uuid,''created'',app_private.purchase_money(coalesce((p_payload->>''transport_cost'')::numeric,0)),app_private.purchase_money(coalesce((p_payload->>''labour_cost'')::numeric,0)),0,');execute s;
 s:=pg_get_functiondef('public.dispatch_purchase(uuid,integer,date)'::regprocedure);
 s:=replace(s,'if p.business_category=''stove'' then raise exception ''Stove purchases are received directly'';end if;',
 'if p.business_category=''stove'' and p.transport_cost=0 then raise exception ''Stove orders without internal transport are received directly'';end if;');
 s:=replace(s,'perform 1 from public.gas_plants gp join', 'if p.business_category=''lpg'' then perform 1 from public.gas_plants gp join');
 s:=replace(s,'perform app_private.check_purchase_empties(t,(select jsonb_agg(to_jsonb(pi)) from public.purchase_items pi where tenant_id=t and purchase_id=p_purchase_id));',
 'perform app_private.check_purchase_empties(t,(select jsonb_agg(to_jsonb(pi)) from public.purchase_items pi where tenant_id=t and purchase_id=p_purchase_id));end if;');
 s:=replace(s,'status,transport_fee,created_at)', 'status,transport_fee,created_at,client_name,destination)');
 s:=replace(s,'''active'',p.transport_cost,dispatch_time);', '''active'',p.transport_cost,dispatch_time,case when p.business_category=''stove'' then p.supplier_name end,case when p.business_category=''stove'' then ''Stove supplier collection'' end);');execute s;
 s:=pg_get_functiondef('public.receive_purchase(uuid,integer,date,date)'::regprocedure);
 s:=replace(s,'p.business_category=''lpg'' and p_received_on<', 'p.dispatched_at is not null and p_received_on<');
 s:=replace(s,'update public.purchases set commission_month=', 'perform 1 from public.vehicles where tenant_id=t and vehicle_id=p.vehicle_id for update;perform 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id order by transit_id for update; update public.purchases set commission_month=');
 s:=replace(s,'if p.status<>''created'' or p_revision is distinct from p.revision then', 'if p.status not in (''created'',''in_transit'') or p.status=''created'' and p.transport_cost>0 or p_revision is distinct from p.revision then');
 s:=replace(s,'dispatched_at=received_time where', 'dispatched_at=coalesce(dispatched_at,received_time) where');
 s:=replace(s,'insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p_purchase_id,''received'',auth.uid(),jsonb_build_object(''direct_receipt'',true));',
 'update public.transits set status=''returned'',revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and purchase_id=p_purchase_id and status=''active'';
 if p.vehicle_id is not null and not exists(select 1 from public.transits where tenant_id=t and vehicle_id=p.vehicle_id and status=''active'') and not exists(select 1 from public.purchases where tenant_id=t and vehicle_id=p.vehicle_id and status=''in_transit'') then update public.vehicles set status=''idle'',updated_at=clock_timestamp() where tenant_id=t and vehicle_id=p.vehicle_id;end if;
 insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p_purchase_id,''received'',auth.uid(),jsonb_build_object(''direct_receipt'',p.transport_cost=0));');execute s;
 -- Completed transportation remains earned when intact received goods return
 -- to the supplier. It becomes a return cost, not a fictional transport refund.
 s:=pg_get_functiondef('public.initiate_purchase_cancellation(uuid,integer,text,uuid)'::regprocedure);
 s:=replace(s,'perform app_private.settle_internal_transport(t,p_purchase_id,(now() at time zone ''Asia/Dhaka'')::date,true);',
 'if p.status<>''received'' then perform app_private.settle_internal_transport(t,p_purchase_id,(now() at time zone ''Asia/Dhaka'')::date,true);end if;');
 s:=replace(s,'update public.transits set status=''cancelled'',revision=revision+1,updated_at=now() where tenant_id=t and purchase_id=p_purchase_id;',
 'if p.status<>''received'' then update public.transits set status=''cancelled'',revision=revision+1,updated_at=now() where tenant_id=t and purchase_id=p_purchase_id;end if;');
 execute s;
 s:=pg_get_functiondef('app_private.fifo_cost_movement(public.inventory_movements)'::regprocedure);
 s:=replace(s,'insert into app_private.fifo_consumptions values(m.tenant_id,m.movement_id,batch.layer_id,batch.remaining,batch.remaining_value,batch.remaining_shell_value);',
 'insert into app_private.fifo_consumptions(tenant_id,movement_id,layer_id,quantity,value,shell_value,internal_value) values(m.tenant_id,m.movement_id,batch.layer_id,batch.remaining,batch.remaining_value,batch.remaining_shell_value,batch.remaining_internal_value);');
 s:=replace(s,'set remaining=0,remaining_value=0,remaining_shell_value=0', 'set remaining=0,remaining_value=0,remaining_shell_value=0,remaining_internal_value=0');execute s;
end $$;
