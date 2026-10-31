-- Operational reference prices only. No journal, cost pool, sale-cost trigger,
-- financial report or asset valuation reads this history or commission estimates.
create table public.product_buying_price_history (
 tenant_id uuid not null,item_id uuid not null,history_id uuid not null default gen_random_uuid(),
 entry_no bigint generated always as identity,price_type text not null check(price_type in ('refill','package')),
 previous_price numeric(14,2),new_price numeric(14,2),automatic_price numeric(14,2),is_manual boolean not null,
 bottle_cost numeric(14,4),overhead_per_unit numeric(14,4),commission_per_unit numeric(14,2),
 purchase_id uuid,commission_id uuid,source text not null check(source in ('purchase','commission','manual','restore_automatic')),
 reason text not null check(length(trim(reason)) between 1 and 1000),effective_at timestamptz not null default clock_timestamp(),
 created_by uuid,reconstructed boolean not null default false,
 primary key(tenant_id,history_id),unique(entry_no),
 foreign key(tenant_id,item_id) references public.items(tenant_id,item_id),
 foreign key(tenant_id,purchase_id) references public.purchases(tenant_id,purchase_id),
 foreign key(tenant_id,commission_id) references public.product_commission_rates(tenant_id,rate_id),
 check(new_price is null or new_price>=0 and new_price<10000000000),
 check(automatic_price is null or automatic_price>=0 and automatic_price<10000000000)
);
alter table public.product_buying_price_history owner to postgres;
alter table public.product_buying_price_history enable row level security;
revoke all on public.product_buying_price_history from public,anon,authenticated;
create index buying_price_current on public.product_buying_price_history(tenant_id,item_id,price_type,effective_at desc,entry_no desc);
create index buying_price_history_page on public.product_buying_price_history(tenant_id,item_id,effective_at desc,entry_no desc);
create index buying_price_purchase on public.product_buying_price_history(tenant_id,purchase_id);
create index buying_price_commission on public.product_buying_price_history(tenant_id,commission_id);
create trigger immutable_buying_price before update or delete on public.product_buying_price_history for each row execute function app_private.immutable_finance_record();

create function app_private.refresh_buying_price(t uuid,id uuid,kind text,source_name text,as_of timestamptz,actor uuid,reconstructed boolean default false) returns void language plpgsql set search_path='' as $$
declare prev public.product_buying_price_history;p public.purchases;c public.product_commission_rates;
 base numeric;overhead numeric;commission numeric;automatic numeric;effective numeric;begin
 if not exists(select 1 from public.items where tenant_id=t and item_id=id and business_category='lpg') then return;end if;
 select * into prev from public.product_buying_price_history where tenant_id=t and item_id=id and price_type=kind order by effective_at desc,entry_no desc limit 1;
 select p0.* into p from public.purchases p0 join public.purchase_items pi using(tenant_id,purchase_id)
 where p0.tenant_id=t and pi.item_id=id and pi.type::text=kind and p0.status='received' and pi.received_quantity>0 and p0.received_at<=as_of
 order by p0.received_at desc,p0.created_at desc,p0.purchase_id desc limit 1;
 select * into c from public.product_commission_rates where tenant_id=t and item_id=id and created_at<=as_of order by created_at desc,rate_id desc limit 1;
 select sum(line_total)/nullif(sum(received_quantity),0) into base from public.purchase_items where tenant_id=t and purchase_id=p.purchase_id and item_id=id and type::text=kind;
 select (p.transport_cost+p.labour_cost)/nullif(sum(received_quantity),0) into overhead from public.purchase_items where tenant_id=t and purchase_id=p.purchase_id;
 commission:=coalesce(case when kind='refill' then c.refill_commission_per_unit else c.package_commission_per_unit end,0);
 automatic:=case when base is not null then greatest(0,round(base+coalesce(overhead,0)-commission,2)) end;
 effective:=case when coalesce(prev.is_manual,false) then prev.new_price else automatic end;
 if prev.history_id is not null and prev.automatic_price is not distinct from automatic and prev.purchase_id is not distinct from p.purchase_id and prev.commission_id is not distinct from c.rate_id then return;end if;
 if prev.history_id is null and p.purchase_id is null and c.rate_id is null then return;end if;
 insert into public.product_buying_price_history(tenant_id,item_id,price_type,previous_price,new_price,automatic_price,is_manual,bottle_cost,overhead_per_unit,commission_per_unit,purchase_id,commission_id,source,reason,effective_at,created_by,reconstructed)
 values(t,id,kind,prev.new_price,effective,automatic,coalesce(prev.is_manual,false),base,overhead,commission,p.purchase_id,c.rate_id,source_name,
 case when source_name='purchase' then 'Latest received purchase calculation' else 'Commission estimate recalculation' end||case when coalesce(prev.is_manual,false) then '; manual override preserved' else '' end,as_of,actor,reconstructed);
end $$;
create function app_private.purchase_buying_prices() returns trigger language plpgsql set search_path='' as $$
declare id uuid;k text;begin
 if new.business_category='lpg' and (new.status='received' or old.status='received') then
  perform 1 from public.items where tenant_id=new.tenant_id and item_id in(select item_id from public.purchase_items where tenant_id=new.tenant_id and purchase_id=new.purchase_id) order by item_id for update;
  for id in select distinct item_id from public.purchase_items where tenant_id=new.tenant_id and purchase_id=new.purchase_id order by item_id loop
   foreach k in array array['refill','package'] loop perform app_private.refresh_buying_price(new.tenant_id,id,k,'purchase',clock_timestamp(),auth.uid());end loop;
  end loop;
 end if;return new;end $$;
create trigger purchase_buying_prices after update of status,subtotal,transport_cost,labour_cost on public.purchases for each row execute function app_private.purchase_buying_prices();
create function app_private.commission_buying_prices() returns trigger language plpgsql set search_path='' as $$declare k text;begin
 perform 1 from public.items where tenant_id=new.tenant_id and item_id=new.item_id for update;
 foreach k in array array['refill','package'] loop perform app_private.refresh_buying_price(new.tenant_id,new.item_id,k,'commission',clock_timestamp(),auth.uid());end loop;return new;end $$;
create trigger commission_buying_prices after insert on public.product_commission_rates for each row execute function app_private.commission_buying_prices();
do $$declare e record;k text;begin
 for e in select * from (
  select distinct p.tenant_id,pi.item_id,p.received_at at_time,'purchase' source from public.purchases p join public.purchase_items pi using(tenant_id,purchase_id) where p.status='received' and p.received_at is not null
  union all select tenant_id,item_id,created_at,'commission' from public.product_commission_rates
 ) events order by at_time,source,tenant_id,item_id loop
  foreach k in array array['refill','package'] loop perform app_private.refresh_buying_price(e.tenant_id,e.item_id,k,e.source,e.at_time,null,true);end loop;
 end loop;
end $$;

create function public.set_product_buying_price(p_payload jsonb,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_owner('inventory:manage');prior public.finance_requests;body jsonb:=jsonb_build_object('action','buying_price','actor',auth.uid(),'body',p_payload);
 id uuid:=(p_payload->>'item_id')::uuid;kind text:=p_payload->>'price_type';manual boolean:=(p_payload->>'is_manual')::boolean;
 prev public.product_buying_price_history;price numeric;r jsonb;hid uuid;begin
 if p_request_id is null then raise exception 'Request ID is required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used with different details';end if;return prior.result;end if;
 if kind is null or kind not in ('refill','package') or manual is null or nullif(trim(p_payload->>'reason'),'') is null or length(p_payload->>'reason')>1000 then raise exception 'Choose a price type, mode and reason';end if;
 perform 1 from public.items where tenant_id=t and item_id=id and business_category='lpg' for update;if not found then raise exception 'LPG product not found';end if;
 select * into prev from public.product_buying_price_history where tenant_id=t and item_id=id and price_type=kind order by effective_at desc,entry_no desc limit 1;
 if prev.history_id is distinct from nullif(p_payload->>'expected','')::uuid then raise exception 'Buying price changed. Reload before saving.';end if;
 if not manual and prev.automatic_price is null then raise exception 'Receive a purchase before restoring automatic pricing';end if;
 if manual and p_payload->>'price' is null then raise exception 'Enter an approximate buying price';end if;
 price:=case when manual then app_private.purchase_money((p_payload->>'price')::numeric) else prev.automatic_price end;
 insert into public.product_buying_price_history(tenant_id,item_id,price_type,previous_price,new_price,automatic_price,is_manual,bottle_cost,overhead_per_unit,commission_per_unit,purchase_id,commission_id,source,reason,created_by)
 values(t,id,kind,prev.new_price,price,prev.automatic_price,manual,prev.bottle_cost,prev.overhead_per_unit,prev.commission_per_unit,prev.purchase_id,prev.commission_id,case when manual then 'manual' else 'restore_automatic' end,trim(p_payload->>'reason'),auth.uid()) returning history_id into hid;
 r:=jsonb_build_object('history_id',hid);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,r,auth.uid());return r;end $$;

create function public.get_buying_price_history(p_item_id uuid,p_offset integer default 0,p_limit integer default 10) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['inventory:view','inventory:manage']);r jsonb;begin
 if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid history page';end if;
 with page as(select h.*,coalesce(u.full_name,u.email,'Reconstructed from records') actor from public.product_buying_price_history h left join public.user_profiles u on u.user_id=h.created_by and u.tenant_id=h.tenant_id where h.tenant_id=t and h.item_id=p_item_id order by h.effective_at desc,h.entry_no desc offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from public.product_buying_price_history where tenant_id=t and item_id=p_item_id),'entries',coalesce((select jsonb_agg(to_jsonb(p) order by effective_at desc,entry_no desc) from page p),'[]')) into r;return r;end $$;
create function public.get_product_commission_history(p_item_id uuid,p_offset integer default 0,p_limit integer default 10) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['inventory:view','inventory:manage']);r jsonb;begin
 if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid history page';end if;
 with page as(select c.*,coalesce(u.full_name,u.email,'Historical record') actor from public.product_commission_rates c left join public.user_profiles u on u.user_id=c.created_by and u.tenant_id=c.tenant_id where c.tenant_id=t and c.item_id=p_item_id order by c.created_at desc,c.rate_id desc offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from public.product_commission_rates where tenant_id=t and item_id=p_item_id),'entries',coalesce((select jsonb_agg(to_jsonb(p) order by created_at desc,rate_id desc) from page p),'[]')) into r;return r;end $$;

-- Extend the existing product read; keep stock valuation and weekly history.
do $$declare s text;begin
 s:=pg_get_functiondef('public.get_product_inventory(uuid)'::regprocedure);
 if position('''valuation''' in s)=0 then raise exception 'Unexpected product detail contract';end if;
 s:=replace(s,'''valuation'',', $new$'buying_prices',coalesce((select jsonb_agg(to_jsonb(h)) from (select distinct on(price_type) * from public.product_buying_price_history where tenant_id=t and item_id=p_item_id order by price_type,effective_at desc,entry_no desc)h),'[]'),
    'valuation',$new$);
 execute s;
end $$;
do $$declare r record;begin
 for r in select p.oid::regprocedure signature,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.proname in ('refresh_buying_price','purchase_buying_prices','commission_buying_prices','set_product_buying_price','get_buying_price_history','get_product_commission_history') and n.nspname in ('public','app_private') loop
  execute format('alter function %s owner to postgres',r.signature);execute format('revoke all on function %s from public,anon,authenticated',r.signature);
  if r.nspname='public' then execute format('grant execute on function %s to authenticated',r.signature);end if;
 end loop;
end $$;
