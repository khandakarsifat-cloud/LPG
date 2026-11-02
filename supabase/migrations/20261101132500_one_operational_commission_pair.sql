-- Operational references use one currently effective pair. Dated FIFO still
-- uses the original acquisition month's entitlement, never a present-day quote.
alter table public.product_buying_price_history add column commission_month date,add column commission_revision integer;

create function app_private.effective_commission(t uuid,id uuid,day date) returns public.monthly_commission_rates language sql stable set search_path='' as $$
 select r from public.monthly_commission_rates r where r.tenant_id=t and r.item_id=id and r.month<=date_trunc('month',day)::date order by r.month desc limit 1;$$;

create function app_private.buying_price_reference(t uuid,id uuid,kind text,as_of timestamptz) returns jsonb language plpgsql stable set search_path='' as $$declare
 purchase public.purchases;commission public.monthly_commission_rates;base numeric;overhead numeric;rebate numeric;begin
 select p.* into purchase from public.purchases p join public.purchase_items pi using(tenant_id,purchase_id)
 where p.tenant_id=t and pi.item_id=id and pi.type::text=kind and p.status='received' and pi.received_quantity>0 and p.received_at<=as_of
 order by p.received_at desc,p.created_at desc,p.purchase_id desc limit 1;
 commission:=app_private.effective_commission(t,id,(as_of at time zone 'Asia/Dhaka')::date);
 select sum(pi.line_total)/nullif(sum(pi.received_quantity),0) into base from public.purchase_items pi where pi.tenant_id=t and pi.purchase_id=purchase.purchase_id and pi.item_id=id and pi.type::text=kind;
 select (purchase.transport_cost+purchase.labour_cost)/nullif(sum(pi.received_quantity),0) into overhead from public.purchase_items pi where pi.tenant_id=t and pi.purchase_id=purchase.purchase_id;
 rebate:=coalesce(case when kind='refill' then commission.refill_rate else commission.package_rate end,0);
 return jsonb_build_object('bottle_cost',base,'overhead_per_unit',overhead,'commission_per_unit',rebate,'commission_month',commission.month,'commission_revision',commission.revision,
 'purchase_id',purchase.purchase_id,'automatic_price',case when base is not null then greatest(0,round(base+coalesce(overhead,0)-rebate,2)) end);
end $$;

create or replace function app_private.refresh_buying_price(t uuid,id uuid,kind text,source_name text,as_of timestamptz,actor uuid,reconstructed boolean default false) returns void language plpgsql set search_path='' as $$declare
 prev public.product_buying_price_history;reference jsonb;automatic numeric;effective numeric;begin
 if not exists(select 1 from public.items where tenant_id=t and item_id=id and business_category='lpg') then return;end if;
 select * into prev from public.product_buying_price_history where tenant_id=t and item_id=id and price_type=kind order by effective_at desc,entry_no desc limit 1;
 reference:=app_private.buying_price_reference(t,id,kind,as_of);automatic:=(reference->>'automatic_price')::numeric;
 effective:=case when coalesce(prev.is_manual,false) then prev.new_price else automatic end;
 if prev.history_id is not null and prev.automatic_price is not distinct from automatic and prev.bottle_cost is not distinct from (reference->>'bottle_cost')::numeric
 and prev.overhead_per_unit is not distinct from (reference->>'overhead_per_unit')::numeric and prev.commission_per_unit is not distinct from (reference->>'commission_per_unit')::numeric
 and prev.purchase_id is not distinct from (reference->>'purchase_id')::uuid and prev.commission_month is not distinct from (reference->>'commission_month')::date and prev.commission_revision is not distinct from (reference->>'commission_revision')::integer then return;end if;
 if prev.history_id is null and reference->>'purchase_id' is null then return;end if;
 insert into public.product_buying_price_history(tenant_id,item_id,price_type,previous_price,new_price,automatic_price,is_manual,bottle_cost,overhead_per_unit,commission_per_unit,purchase_id,source,reason,effective_at,created_by,reconstructed,commission_month,commission_revision)
 values(t,id,kind,prev.new_price,effective,automatic,coalesce(prev.is_manual,false),(reference->>'bottle_cost')::numeric,(reference->>'overhead_per_unit')::numeric,(reference->>'commission_per_unit')::numeric,(reference->>'purchase_id')::uuid,
 source_name,'Latest purchase with the active commission'||case when coalesce(prev.is_manual,false) then '; approximate price override preserved' else '' end,as_of,actor,reconstructed,(reference->>'commission_month')::date,(reference->>'commission_revision')::integer);
end $$;

-- Read the live reference as well as its retained override. This also handles
-- calendar rollover without a mutating GET, a new counter, or a scheduled job.
do $$declare s text;begin
 s:=pg_get_functiondef('public.get_product_inventory(uuid)'::regprocedure);
 s:=substring(s,1,strpos(s,'with current_commission as (')-1)||'with current_prices as ('||substring(s,strpos(s,'), current_prices as (')+length('), current_prices as ('));
 s:=replace(s,'''commission'',(select to_jsonb(c) from current_commission c)',
 '''commission'',(select to_jsonb(c) from app_private.effective_commission(t,p_item_id,local_today)c where c.item_id is not null)');
 s:=replace(s,'''buying_prices'',coalesce((select jsonb_agg(to_jsonb(h)) from (select distinct on(price_type) * from public.product_buying_price_history where tenant_id=t and item_id=p_item_id order by price_type,effective_at desc,entry_no desc)h),''[]'')',
 '''buying_prices'',coalesce((select jsonb_agg(coalesce(to_jsonb(h),''{}''::jsonb)||ref.value||jsonb_build_object(''price_type'',kind,''is_manual'',coalesce(h.is_manual,false),''new_price'',case when coalesce(h.is_manual,false) then h.new_price else (ref.value->>''automatic_price'')::numeric end) order by kind)
 from unnest(array[''refill'',''package''])k(kind)
 cross join lateral(select app_private.buying_price_reference(t,p_item_id,kind,as_of) value)ref
 left join lateral(select * from public.product_buying_price_history where tenant_id=t and item_id=p_item_id and price_type=kind order by effective_at desc,entry_no desc limit 1)h on true
 where exists(select 1 from public.items where tenant_id=t and item_id=p_item_id and business_category=''lpg'')),''[]'')');
 execute s;
end $$;

create or replace function public.set_product_buying_price(p_payload jsonb,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$declare
 t uuid:=app_private.require_owner('inventory:manage');prior public.finance_requests;body jsonb:=jsonb_build_object('action','buying_price','actor',auth.uid(),'body',p_payload);
 id uuid:=(p_payload->>'item_id')::uuid;kind text:=p_payload->>'price_type';manual boolean:=(p_payload->>'is_manual')::boolean;
 prev public.product_buying_price_history;price numeric;r jsonb;hid uuid;reference jsonb;begin
 if p_request_id is null then raise exception 'Request ID is required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used with different details';end if;return prior.result;end if;
 if kind is null or kind not in ('refill','package') or manual is null or nullif(trim(p_payload->>'reason'),'') is null or length(p_payload->>'reason')>1000 then raise exception 'Choose a price type, mode and reason';end if;
 perform 1 from public.items where tenant_id=t and item_id=id and business_category='lpg' for update;if not found then raise exception 'LPG product not found';end if;
 select * into prev from public.product_buying_price_history where tenant_id=t and item_id=id and price_type=kind order by effective_at desc,entry_no desc limit 1;
 if prev.history_id is distinct from nullif(p_payload->>'expected','')::uuid then raise exception 'Buying price changed. Reload before saving.';end if;
 reference:=app_private.buying_price_reference(t,id,kind,clock_timestamp());
 if not manual and reference->>'automatic_price' is null then raise exception 'Receive a purchase before restoring automatic pricing';end if;
 if manual and p_payload->>'price' is null then raise exception 'Enter an approximate buying price';end if;
 price:=case when manual then app_private.purchase_money((p_payload->>'price')::numeric) else (reference->>'automatic_price')::numeric end;
 insert into public.product_buying_price_history(tenant_id,item_id,price_type,previous_price,new_price,automatic_price,is_manual,bottle_cost,overhead_per_unit,commission_per_unit,purchase_id,source,reason,created_by,commission_month,commission_revision)
 values(t,id,kind,prev.new_price,price,(reference->>'automatic_price')::numeric,manual,(reference->>'bottle_cost')::numeric,(reference->>'overhead_per_unit')::numeric,(reference->>'commission_per_unit')::numeric,(reference->>'purchase_id')::uuid,
 case when manual then 'manual' else 'restore_automatic' end,trim(p_payload->>'reason'),auth.uid(),(reference->>'commission_month')::date,(reference->>'commission_revision')::integer) returning history_id into hid;
 r:=jsonb_build_object('history_id',hid);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,r,auth.uid());return r;end $$;

alter function app_private.effective_commission(uuid,uuid,date) owner to postgres;
alter function app_private.buying_price_reference(uuid,uuid,text,timestamptz) owner to postgres;
revoke all on function app_private.effective_commission(uuid,uuid,date),app_private.buying_price_reference(uuid,uuid,text,timestamptz) from public,anon,authenticated;

-- Only operational-reference history is refreshed. No inventory, journal,
-- commission entitlement, payment, or wallet record is rewritten here.
do $$declare i record;k text;begin
 for i in select tenant_id,item_id from public.items where business_category='lpg' order by tenant_id,item_id loop
  perform 1 from public.items where tenant_id=i.tenant_id and item_id=i.item_id for update;
  foreach k in array array['refill','package'] loop perform app_private.refresh_buying_price(i.tenant_id,i.item_id,k,'commission',clock_timestamp(),null);end loop;
 end loop;
end $$;
