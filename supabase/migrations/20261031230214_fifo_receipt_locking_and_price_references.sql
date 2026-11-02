-- Direct stove receipts must lock their complete SKU set before their first
-- recognition journal, just like LPG receipts and POS. Default business times
-- are sampled only after those locks, preserving chronological FIFO order.
do $$declare s text;begin
 s:=pg_get_functiondef('public.receive_purchase(uuid,integer,date,date)'::regprocedure);
 s:=replace(s,'if p_received_on is null or p_received_on=(now() at time zone ''Asia/Dhaka'')::date then received_time:=clock_timestamp();end if;perform app_private.snapshot_purchase_shells',
 'perform 1 from public.items where tenant_id=t and item_id in(select item_id from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id) order by item_id for update;
 if p_received_on is null or p_received_on=(now() at time zone ''Asia/Dhaka'')::date then received_time:=clock_timestamp();end if;perform app_private.snapshot_purchase_shells');execute s;
 -- Suggestions use the latest received invoice's month, even when entered later.
 s:=pg_get_functiondef('app_private.refresh_buying_price(uuid,uuid,text,text,timestamptz,uuid,boolean)'::regprocedure);
 s:=replace(s,'month=date_trunc(''month'',as_of at time zone ''Asia/Dhaka'')::date','month=date_trunc(''month'',coalesce(p.received_at,as_of) at time zone ''Asia/Dhaka'')::date');
 s:=replace(s,'Commission estimate recalculation','Monthly commission recalculation');execute s;
 s:=pg_get_functiondef('public.get_monthly_commissions(uuid,date,integer)'::regprocedure);
 s:=replace(s,'p_offset<0 then','(p_offset<0 or p_offset>1000000) then');
 s:=replace(s,'on u.user_id=h.modified_by','on u.tenant_id=h.tenant_id and u.user_id=h.modified_by');execute s;
end $$;
create or replace function app_private.monthly_buying_prices() returns trigger language plpgsql set search_path='' as $$declare k text;begin
 foreach k in array array['refill','package'] loop perform app_private.refresh_buying_price(new.tenant_id,new.item_id,k,'commission',clock_timestamp(),auth.uid());end loop;return new;end $$;
-- Re-establish automatic suggestions through the existing history. Overrides
-- remain protected by refresh_buying_price; no operational price enters FIFO.
do $$declare r record;k text;begin
 for r in select i.tenant_id,i.item_id from public.items i where i.business_category='lpg' and exists(select 1 from public.purchase_items pi join public.purchases p using(tenant_id,purchase_id) where pi.tenant_id=i.tenant_id and pi.item_id=i.item_id and p.status='received') order by tenant_id,item_id loop
  perform 1 from public.items where tenant_id=r.tenant_id and item_id=r.item_id for update;
  foreach k in array array['refill','package'] loop perform app_private.refresh_buying_price(r.tenant_id,r.item_id,k,'commission',clock_timestamp(),null);end loop;
 end loop;
end $$;
-- Extend the existing bounded reconciliation worker; no new worker/counter.
do $$declare s text;begin
 s:=pg_get_functiondef('app_private.reconcile_record(uuid,text,uuid)'::regprocedure);
 s:=replace(s,'elsif k=''loan'' then',
 'observed:=observed||jsonb_build_object(''fifo_consistent'',
  not exists(select 1 from app_private.fifo_layers l left join lateral(select coalesce(sum(x.quantity),0) q,coalesce(sum(x.value),0) v,coalesce(sum(x.shell_value),0) s from app_private.fifo_consumptions x where x.tenant_id=t and x.layer_id=l.layer_id)x on true where l.tenant_id=t and l.item_id=id and (l.quantity<>l.remaining+x.q or l.value<>l.remaining_value+x.v or l.shell_value<>l.remaining_shell_value+x.s))
  and coalesce((select c.filled_quantity=x.f and c.empty_quantity=x.e and c.filled_value=x.fv and c.empty_value=x.ev from public.inventory_costs c cross join lateral(select coalesce(sum(remaining) filter(where component=''filled''),0) f,coalesce(sum(remaining) filter(where component=''empty''),0) e,coalesce(sum(remaining_value) filter(where component=''filled''),0) fv,coalesce(sum(remaining_value) filter(where component=''empty''),0) ev from app_private.fifo_layers where tenant_id=t and item_id=id and remaining>0)x where c.tenant_id=t and c.item_id=id),true),
  ''monthly_rates_consistent'',not exists(select 1 from public.monthly_commission_rates r where r.tenant_id=t and r.item_id=id and not exists(select 1 from public.monthly_commission_history h where h.tenant_id=t and h.item_id=id and h.month=r.month and h.revision=r.revision and h.rate=r.rate and h.source=r.source and h.calculation=r.calculation)));
 expected:=expected||jsonb_build_object(''fifo_consistent'',true,''monthly_rates_consistent'',true);
 elsif k=''loan'' then');
 s:=replace(s,'elsif k=''transit'' then',
 'observed:=observed||jsonb_build_object(''monthly_deduction_consistent'',not exists(select 1 from public.purchases p left join public.monthly_commission_deductions d using(tenant_id,purchase_id) where p.tenant_id=t and p.purchase_id=id and p.status=''received'' and p.business_category=''lpg'' and (p.commission<>coalesce(d.amount,0) or d.purchase_id is not null and (d.received_on<>(p.received_at at time zone ''Asia/Dhaka'')::date or d.earned_month is distinct from p.commission_month))));
 expected:=expected||jsonb_build_object(''monthly_deduction_consistent'',true);
 elsif k=''transit'' then');execute s;
end $$;
notify pgrst,'reload schema';
