-- One effective monthly record, with Package and Refill amounts. Source marks
-- its provenance; a manual save replaces this record and appends audit history.
alter table public.monthly_commission_rates add column package_rate numeric(18,6),add column refill_rate numeric(18,6);
alter table public.monthly_commission_history add column package_rate numeric(18,6),add column refill_rate numeric(18,6);
update public.monthly_commission_rates set package_rate=rate,refill_rate=rate;
alter table public.monthly_commission_history disable trigger immutable_monthly_commission_history;
update public.monthly_commission_history set package_rate=rate,refill_rate=rate;
alter table public.monthly_commission_history enable trigger immutable_monthly_commission_history;
alter table public.monthly_commission_rates alter column package_rate set not null,alter column refill_rate set not null,
 add check(package_rate>=0 and package_rate<10000000000),add check(refill_rate>=0 and refill_rate<10000000000),drop column rate;
alter table public.monthly_commission_history alter column package_rate set not null,alter column refill_rate set not null,drop column rate;

create or replace function app_private.infer_monthly_commissions(t uuid,brand uuid,period date) returns uuid[] language plpgsql set search_path='' as $$
declare deducted numeric;manual_total numeric;basis numeric;r record;next_package numeric;next_refill numeric;prev public.monthly_commission_rates;calculation jsonb;affected uuid[]:='{}';begin
 select coalesce(sum(d.amount),0) into deducted from public.monthly_commission_deductions d join public.purchases p using(tenant_id,purchase_id) where d.tenant_id=t and p.brand_id=brand and d.earned_month=period;
 select coalesce(sum(pi.received_quantity*case when pi.type='package' then mr.package_rate else mr.refill_rate end) filter(where mr.source='manual'),0),
 coalesce(sum(pi.received_quantity*pi.unit_price) filter(where mr.source is distinct from 'manual'),0) into manual_total,basis
 from public.purchases p join public.purchase_items pi using(tenant_id,purchase_id) join public.items i using(tenant_id,item_id)
 left join public.monthly_commission_rates mr on mr.tenant_id=i.tenant_id and mr.item_id=i.item_id and mr.month=period
 where p.tenant_id=t and p.brand_id=brand and p.business_category='lpg' and i.business_category='lpg' and p.status='received'
 and p.received_at>=period::timestamp at time zone 'Asia/Dhaka' and p.received_at<(period+interval '1 month')::timestamp at time zone 'Asia/Dhaka';
 for r in select i.item_id,
 coalesce(sum(pi.received_quantity*pi.unit_price) filter(where pi.type='package')/nullif(sum(pi.received_quantity) filter(where pi.type='package'),0),0) package_price,
 coalesce(sum(pi.received_quantity*pi.unit_price) filter(where pi.type='refill')/nullif(sum(pi.received_quantity) filter(where pi.type='refill'),0),0) refill_price
 from public.purchases p join public.purchase_items pi using(tenant_id,purchase_id) join public.items i using(tenant_id,item_id)
 where p.tenant_id=t and p.brand_id=brand and p.status='received' and p.business_category='lpg' and i.business_category='lpg' and pi.received_quantity>0
 and p.received_at>=period::timestamp at time zone 'Asia/Dhaka' and p.received_at<(period+interval '1 month')::timestamp at time zone 'Asia/Dhaka'
 group by i.item_id order by i.item_id loop
  select * into prev from public.monthly_commission_rates where tenant_id=t and item_id=r.item_id and month=period;
  if prev.source='manual' then continue;end if;
  next_package:=coalesce(round(greatest(0,deducted-manual_total)*r.package_price/nullif(basis,0),6),0);
  next_refill:=coalesce(round(greatest(0,deducted-manual_total)*r.refill_price/nullif(basis,0),6),0);
  calculation:=jsonb_build_object('deductions',deducted,'manual_earned',manual_total,'unrated_invoice_value',basis,
   'package_unit_price',r.package_price,'refill_unit_price',r.refill_price,'provisional',true,'basis','received quantity × invoice unit price');
  if prev.package_rate is not distinct from next_package and prev.refill_rate is not distinct from next_refill and prev.calculation=calculation then continue;end if;
  insert into public.monthly_commission_rates(tenant_id,item_id,month,package_rate,refill_rate,source,calculation,modified_by)
  values(t,r.item_id,period,next_package,next_refill,'inferred_partial',calculation,auth.uid())
  on conflict(tenant_id,item_id,month) do update set package_rate=excluded.package_rate,refill_rate=excluded.refill_rate,calculation=excluded.calculation,
   revision=monthly_commission_rates.revision+1,modified_by=excluded.modified_by,modified_at=clock_timestamp() where monthly_commission_rates.source<>'manual';
  if prev.package_rate is distinct from next_package or prev.refill_rate is distinct from next_refill then affected:=array_append(affected,r.item_id);end if;
  insert into public.monthly_commission_history(tenant_id,item_id,month,package_rate,refill_rate,source,calculation,revision,reason,modified_by)
  select mr.tenant_id,mr.item_id,mr.month,mr.package_rate,mr.refill_rate,mr.source,mr.calculation,mr.revision,'Automatic allocation by received invoice value',auth.uid()
  from public.monthly_commission_rates mr where mr.tenant_id=t and mr.item_id=r.item_id and mr.month=period;
 end loop;return affected;end $$;

create or replace function public.get_monthly_commissions(p_item_id uuid,p_month date,p_offset integer default 0) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['inventory:view','inventory:manage']);r jsonb;package_qty bigint;refill_qty bigint;begin
 if p_month is null or not isfinite(p_month) or p_month<>date_trunc('month',p_month)::date or p_offset is null or p_offset<0 then raise exception 'Invalid commission month or history page';end if;
 if not exists(select 1 from public.items where tenant_id=t and item_id=p_item_id and business_category='lpg') then raise exception 'Eligible LPG product not found';end if;
 select coalesce(sum(pi.received_quantity) filter(where pi.type='package'),0),coalesce(sum(pi.received_quantity) filter(where pi.type='refill'),0) into package_qty,refill_qty
 from public.purchase_items pi join public.purchases p using(tenant_id,purchase_id) where pi.tenant_id=t and pi.item_id=p_item_id and p.status='received'
 and p.received_at>=p_month::timestamp at time zone 'Asia/Dhaka' and p.received_at<(p_month+interval '1 month')::timestamp at time zone 'Asia/Dhaka';
 select jsonb_build_object('current',(select to_jsonb(c) from public.monthly_commission_rates c where tenant_id=t and item_id=p_item_id and month=p_month),
 'quantity',package_qty+refill_qty,'quantities',jsonb_build_object('package',package_qty,'refill',refill_qty),
 'earned',coalesce((select round(package_qty*c.package_rate+refill_qty*c.refill_rate,2) from public.monthly_commission_rates c where tenant_id=t and item_id=p_item_id and month=p_month),0),
 'total',(select count(*) from public.monthly_commission_history where tenant_id=t and item_id=p_item_id and month=p_month),
 'entries',coalesce((select jsonb_agg(to_jsonb(h)) from(select h.*,coalesce(u.full_name,'System') actor from public.monthly_commission_history h left join public.user_profiles u on u.user_id=h.modified_by
 where h.tenant_id=t and h.item_id=p_item_id and h.month=p_month order by h.revision desc offset p_offset limit 10)h),'[]')) into r;return r;end $$;

create or replace function public.set_monthly_commission(p_payload jsonb,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_owner('inventory:manage');id uuid:=(p_payload->>'item_id')::uuid;period date:=(p_payload->>'month')::date;
 package_rate numeric:=(p_payload->>'package_rate')::numeric;refill_rate numeric:=(p_payload->>'refill_rate')::numeric;prev public.monthly_commission_rates;prior public.finance_requests;brand uuid;r record;result jsonb;
 affected uuid[];body jsonb:=jsonb_build_object('action','monthly_commission','actor',auth.uid(),'body',p_payload);reason text:=coalesce(nullif(trim(p_payload->>'reason'),''),'Custom monthly commission');begin
 if p_request_id is null or period is null or not isfinite(period) or period<>date_trunc('month',period)::date or period>date_trunc('month',now() at time zone 'Asia/Dhaka')::date
 or package_rate is null or refill_rate is null or package_rate<0 or refill_rate<0 or package_rate>=10000000000 or refill_rate>=10000000000
 or package_rate::text in ('NaN','Infinity','-Infinity') or refill_rate::text in ('NaN','Infinity','-Infinity') or package_rate<>round(package_rate,6) or refill_rate<>round(refill_rate,6) or length(reason)>1000
 then raise exception 'Enter a valid month and Package and Refill rates';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used with different details';end if;return prior.result;end if;
 select brand_id into brand from public.items where tenant_id=t and item_id=id and business_category='lpg';if not found then raise exception 'Eligible LPG product not found';end if;
 perform 1 from public.items where tenant_id=t and brand_id=brand order by item_id for update;
 select * into prev from public.monthly_commission_rates where tenant_id=t and item_id=id and month=period;
 if coalesce(prev.revision,0) is distinct from (p_payload->>'expected_revision')::integer then raise exception 'Monthly commission changed. Reload before saving.';end if;
 insert into public.monthly_commission_rates(tenant_id,item_id,month,package_rate,refill_rate,source,calculation,modified_by) values(t,id,period,package_rate,refill_rate,'manual',jsonb_build_object('reason',reason),auth.uid())
 on conflict(tenant_id,item_id,month) do update set package_rate=excluded.package_rate,refill_rate=excluded.refill_rate,source='manual',calculation=excluded.calculation,
 revision=monthly_commission_rates.revision+1,modified_by=auth.uid(),modified_at=clock_timestamp();
 insert into public.monthly_commission_history(tenant_id,item_id,month,package_rate,refill_rate,source,calculation,revision,reason,modified_by)
 select mr.tenant_id,mr.item_id,mr.month,mr.package_rate,mr.refill_rate,mr.source,mr.calculation,mr.revision,reason,auth.uid() from public.monthly_commission_rates mr where mr.tenant_id=t and mr.item_id=id and mr.month=period;
 affected:=app_private.infer_monthly_commissions(t,brand,period)||array[id];
 for r in select distinct unnest(affected) item_id order by item_id loop perform app_private.rebuild_fifo(t,r.item_id);end loop;
 result:=jsonb_build_object('saved',true);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());return result;end $$;

-- All consumers choose the original receipt type's amount. Keep one FIFO model,
-- original-layer returns, original receipt month, and dated invalidation.
do $$declare s text;begin
 s:=pg_get_functiondef('app_private.fifo_cost_movement(public.inventory_movements)'::regprocedure);
 s:=replace(s,'coalesce(rate,0)*m.filled_quantity_change','coalesce(case when m.reference_type=''purchase_receipt_refill'' then refill_rate else package_rate end,0)*m.filled_quantity_change');execute s;
 s:=pg_get_functiondef('app_private.refresh_buying_price(uuid,uuid,text,text,timestamptz,uuid,boolean)'::regprocedure);
 s:=replace(s,'rate refill_commission_per_unit,rate package_commission_per_unit','refill_rate refill_commission_per_unit,package_rate package_commission_per_unit');execute s;
 s:=pg_get_functiondef('public.get_product_inventory(uuid)'::regprocedure);
 s:=replace(s,'rate refill_commission_per_unit,rate package_commission_per_unit','refill_rate refill_commission_per_unit,package_rate package_commission_per_unit');execute s;
 s:=pg_get_functiondef('app_private.reconcile_record(uuid,text,uuid)'::regprocedure);
 s:=replace(s,'h.rate=r.rate','h.package_rate=r.package_rate and h.refill_rate=r.refill_rate');execute s;
end $$;

-- Recompute only inferred months under original ordered SKU locks. Explicit
-- historical amounts are copied into both fields above and stay authoritative.
do $$declare b record;i uuid;affected uuid[];begin
 for b in select distinct r.tenant_id,i.brand_id,r.month from public.monthly_commission_rates r join public.items i using(tenant_id,item_id) where r.source<>'manual' order by r.tenant_id,i.brand_id,r.month loop
  perform 1 from public.items where tenant_id=b.tenant_id and brand_id=b.brand_id order by item_id for update;
  affected:=app_private.infer_monthly_commissions(b.tenant_id,b.brand_id,b.month);
  for i in select distinct unnest(affected) order by 1 loop perform app_private.rebuild_fifo(b.tenant_id,i);end loop;
 end loop;
end $$;
