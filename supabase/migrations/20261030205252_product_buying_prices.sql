-- The append-only price stream is the sole buying-price state. Automatic
-- recalculation updates its basis while preserving an explicit manual override.
create table public.product_buying_price_history(
 tenant_id uuid not null,item_id uuid not null,history_id uuid not null default gen_random_uuid(),
 entry_no bigint generated always as identity,price_type text not null check(price_type in ('refill','package')),
 previous_price numeric(14,2),new_price numeric(14,2),automatic_price numeric(14,2),
 is_manual boolean not null,external_cost numeric(14,2),bottle_cost numeric(14,4),overhead_per_unit numeric(14,4),transport_per_unit numeric(14,4),commission_per_unit numeric(14,2),
 purchase_id uuid,commission_id uuid,source text not null check(source in ('purchase','commission','manual','restore_automatic')),
 reason text not null check(length(trim(reason)) between 1 and 1000),effective_at timestamptz not null,
 recorded_at timestamptz not null default clock_timestamp(),created_by uuid,reconstructed boolean not null default false,
 primary key(tenant_id,history_id),unique(entry_no),
 check(new_price is null or new_price>=0 and new_price<10000000000),
 check(automatic_price is null or automatic_price>=0 and automatic_price<10000000000),
 check(external_cost is null or external_cost>=0),
 foreign key(tenant_id,item_id) references public.items(tenant_id,item_id),
 foreign key(tenant_id,purchase_id) references public.purchases(tenant_id,purchase_id),
 foreign key(tenant_id,commission_id) references public.product_commission_rates(tenant_id,rate_id),
 foreign key(created_by) references auth.users(id)
);
create index buying_price_as_of on public.product_buying_price_history(tenant_id,item_id,price_type,effective_at desc,entry_no desc);
create index buying_price_history_page on public.product_buying_price_history(tenant_id,item_id,recorded_at desc,entry_no desc);
create index buying_price_purchase on public.product_buying_price_history(tenant_id,purchase_id);
create index buying_price_commission on public.product_buying_price_history(tenant_id,commission_id);
alter table public.product_buying_price_history enable row level security;
revoke all on public.product_buying_price_history from public,anon,authenticated;
create trigger immutable_buying_price before update or delete on public.product_buying_price_history for each row execute function app_private.immutable_finance_record();
create function app_private.buying_price_at(t uuid,id uuid,kind text,as_of timestamptz) returns public.product_buying_price_history language sql stable set search_path='' as $$
 select h from public.product_buying_price_history h where tenant_id=t and item_id=id and price_type=kind and effective_at<=as_of order by effective_at desc,entry_no desc limit 1;
$$;
create function app_private.refresh_buying_price(t uuid,id uuid,kind text,source_name text,as_of timestamptz,actor uuid,reconstructed boolean default false) returns void language plpgsql set search_path='' as $$
declare prev public.product_buying_price_history;p public.purchases;c public.product_commission_rates;
 units numeric;shipment_units numeric;base numeric;overhead numeric;transport numeric;commission numeric;automatic numeric;effective numeric;external numeric;
begin
 select * into prev from public.product_buying_price_history where tenant_id=t and item_id=id and price_type=kind order by effective_at desc,entry_no desc limit 1;
 select p0.* into p from public.purchases p0 join public.purchase_items pi using(tenant_id,purchase_id)
 where p0.tenant_id=t and pi.item_id=id and pi.type::text=kind and p0.status='received' and pi.received_quantity>0 and p0.received_at<=as_of
 order by p0.received_at desc,p0.created_at desc,p0.purchase_id desc limit 1;
 if not found then return;end if;
 select * into c from public.product_commission_rates where tenant_id=t and item_id=id and created_at<=as_of order by created_at desc,rate_id desc limit 1;
 select sum(line_total)/sum(received_quantity),sum(received_quantity) into base,units from public.purchase_items where tenant_id=t and purchase_id=p.purchase_id and item_id=id and type::text=kind and received_quantity>0;
 select sum(received_quantity) into shipment_units from public.purchase_items where tenant_id=t and purchase_id=p.purchase_id;
 if units<=0 or shipment_units<=0 then return;end if;
 overhead:=(coalesce(p.transport_cost,0)+coalesce(p.labour_cost,0))/shipment_units;transport:=coalesce(p.transport_cost,0)/shipment_units;
 commission:=coalesce(case when kind='refill' then c.refill_commission_per_unit else c.package_commission_per_unit end,0);
 automatic:=greatest(0,round(base+overhead-commission,2));effective:=case when coalesce(prev.is_manual,false) then prev.new_price else automatic end;
 external:=greatest(0,round(effective-transport,2));
 if prev.history_id is not null and prev.automatic_price is not distinct from automatic and prev.purchase_id is not distinct from p.purchase_id
 and prev.commission_id is not distinct from c.rate_id and prev.external_cost is not distinct from external and prev.overhead_per_unit is not distinct from round(overhead,4) then return;end if;
 insert into public.product_buying_price_history(tenant_id,item_id,price_type,previous_price,new_price,automatic_price,is_manual,external_cost,bottle_cost,overhead_per_unit,transport_per_unit,commission_per_unit,purchase_id,commission_id,source,reason,effective_at,created_by,reconstructed)
 values(t,id,kind,prev.new_price,effective,automatic,coalesce(prev.is_manual,false),external,base,overhead,transport,commission,p.purchase_id,c.rate_id,source_name,
 case when source_name='purchase' then 'Latest received purchase calculation' else 'Commission recalculation' end||case when coalesce(prev.is_manual,false) then '; manual override preserved' else '' end,as_of,actor,reconstructed);
end $$;
-- Reconstruct historical calculations only from available receipts and commission
-- evidence. No current manual value is applied retroactively; provenance is explicit.
do $$ declare e record;k text;begin
 for e in select * from (
 select distinct p.tenant_id,pi.item_id,p.received_at at_time,'purchase' source,
 (select a.created_by from public.purchase_activity a where a.tenant_id=p.tenant_id and a.purchase_id=p.purchase_id and a.action='received' order by a.created_at,a.activity_id limit 1) actor
 from public.purchases p join public.purchase_items pi using(tenant_id,purchase_id) where p.status='received' and p.received_at is not null and pi.received_quantity>0
 union all select tenant_id,item_id,created_at,'commission',created_by from public.product_commission_rates) events order by at_time,source,tenant_id,item_id loop
 foreach k in array array['refill','package'] loop perform app_private.refresh_buying_price(e.tenant_id,e.item_id,k,e.source,e.at_time,e.actor,true);end loop;
 end loop;
end $$;
create function app_private.purchase_buying_prices() returns trigger language plpgsql set search_path='' as $$
declare id uuid;k text;begin
 if new.status='received' then
 -- Receipt/edit already owns the purchase lock. Lock product IDs in one order.
 perform 1 from public.items where tenant_id=new.tenant_id and item_id in(select item_id from public.purchase_items where tenant_id=new.tenant_id and purchase_id=new.purchase_id) order by item_id for update;
 for id in select distinct item_id from public.purchase_items where tenant_id=new.tenant_id and purchase_id=new.purchase_id order by item_id loop
 foreach k in array array['refill','package'] loop perform app_private.refresh_buying_price(new.tenant_id,id,k,'purchase',clock_timestamp(),auth.uid());end loop;end loop;
 end if;return new;
end $$;
create trigger purchase_buying_prices after update of status,subtotal,transport_cost,labour_cost on public.purchases for each row execute function app_private.purchase_buying_prices();
create function app_private.commission_buying_prices() returns trigger language plpgsql set search_path='' as $$
declare k text;begin
 perform 1 from public.items where tenant_id=new.tenant_id and item_id=new.item_id for update;
 foreach k in array array['refill','package'] loop perform app_private.refresh_buying_price(new.tenant_id,new.item_id,k,'commission',clock_timestamp(),auth.uid());end loop;return new;
end $$;
create trigger commission_buying_prices after insert on public.product_commission_rates for each row execute function app_private.commission_buying_prices();
create function public.set_product_buying_price(p_payload jsonb,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('inventory:manage');prior public.finance_requests;body jsonb:=jsonb_build_object('action','buying_price','actor',auth.uid(),'body',p_payload);
 id uuid:=(p_payload->>'item_id')::uuid;kind text:=p_payload->>'price_type';manual boolean:=(p_payload->>'is_manual')::boolean;
 prev public.product_buying_price_history;price numeric;external numeric;r jsonb;hid uuid;begin
 if not app_private.can_manage_inventory_prices() then raise exception 'Only the owner can edit buying prices' using errcode='42501';end if;
 if p_request_id is null then raise exception 'Request ID is required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||p_request_id::text,0));select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload<>body then raise exception 'Request ID was already used with different details';end if;return prior.result;end if;
 if kind is null or kind not in ('refill','package') or manual is null or nullif(trim(p_payload->>'reason'),'') is null or length(p_payload->>'reason')>1000 then raise exception 'Choose a price type, mode and reason';end if;
 perform 1 from public.items where tenant_id=t and item_id=id for update;if not found then raise exception 'Product not found';end if;
 select * into prev from public.product_buying_price_history where tenant_id=t and item_id=id and price_type=kind order by effective_at desc,entry_no desc limit 1;
 if prev.history_id is distinct from nullif(p_payload->>'expected','')::uuid then raise exception 'Buying price changed. Reload before saving.';end if;
 price:=case when manual then app_private.purchase_money((p_payload->>'price')::numeric) else prev.automatic_price end;
 external:=greatest(0,round(price-coalesce(prev.transport_per_unit,0),2));
 insert into public.product_buying_price_history(tenant_id,item_id,price_type,previous_price,new_price,automatic_price,is_manual,external_cost,bottle_cost,overhead_per_unit,transport_per_unit,commission_per_unit,purchase_id,commission_id,source,reason,effective_at,created_by)
 values(t,id,kind,prev.new_price,price,prev.automatic_price,manual,external,prev.bottle_cost,prev.overhead_per_unit,prev.transport_per_unit,prev.commission_per_unit,prev.purchase_id,prev.commission_id,
 case when manual then 'manual' else 'restore_automatic' end,trim(p_payload->>'reason'),clock_timestamp(),auth.uid()) returning history_id into hid;
 r:=jsonb_build_object('history_id',hid);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,r,auth.uid());return r;
end $$;
create function public.get_buying_price_history(p_item_id uuid,p_offset integer default 0,p_limit integer default 10) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['inventory:view','inventory:manage']);r jsonb;begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid history page';end if;
 with page as(select h.*,coalesce(u.full_name,u.email) actor from public.product_buying_price_history h left join public.user_profiles u on u.user_id=h.created_by and u.tenant_id=t
 where h.tenant_id=t and h.item_id=p_item_id order by effective_at desc,entry_no desc offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from public.product_buying_price_history where tenant_id=t and item_id=p_item_id),
 'entries',coalesce((select jsonb_agg(to_jsonb(p) order by effective_at desc,entry_no desc) from page p),'[]')) into r;return r;
end $$;
-- Replace the obsolete calculated-on-read CTE, retaining selling prices and weeks.
do $$ declare s text;a integer;b integer;begin
 s:=pg_get_functiondef('public.get_product_inventory(uuid)'::regprocedure);
 a:=position('latest_receipts as (' in s);b:=position('weeks as (' in s);
 if a=0 or b<a then raise exception 'Unexpected product inventory contract';end if;
 s:=left(s,a-1)||$new$buying as (
 select k.type,h.history_id,h.purchase_id,h.new_price price,h.automatic_price,h.is_manual,h.source,h.reason,h.effective_at,h.bottle_cost,h.overhead_per_unit,h.transport_per_unit,h.commission_per_unit,p.received_at
 from (values('refill'),('package')) k(type) left join lateral(select * from app_private.buying_price_at(t,p_item_id,k.type,as_of)) h on true
 left join public.purchases p on p.tenant_id=t and p.purchase_id=h.purchase_id
 ), $new$||substring(s from b);
 execute replace(s,'''buying_costs''','''buying_prices''');
end $$;
-- Cost evidence is captured with each sale line, independently of later prices.
create table public.sale_cost_evidence(
 tenant_id uuid not null,sale_item_id uuid not null,sale_id uuid not null,item_id uuid not null,
 price_type text not null,quantity integer not null,unit_cost numeric(14,2),external_unit_cost numeric(14,2),
 buying_history_id uuid,reconstructed boolean not null,recorded_at timestamptz not null default clock_timestamp(),
 primary key(tenant_id,sale_item_id),foreign key(tenant_id,sale_item_id) references public.sale_items(tenant_id,sale_item_id),
 foreign key(tenant_id,buying_history_id) references public.product_buying_price_history(tenant_id,history_id)
);
create index sale_cost_parent on public.sale_cost_evidence(tenant_id,sale_id);
create function app_private.capture_sale_cost() returns trigger language plpgsql set search_path='' as $$
declare h public.product_buying_price_history;at_time timestamptz;begin
 if new.type::text not in ('refill','package') then return new;end if;
 select case when created_at=transaction_timestamp() then clock_timestamp() else created_at end into at_time from public.sales where tenant_id=new.tenant_id and sale_id=new.sale_id;
 h:=app_private.buying_price_at(new.tenant_id,new.item_id,new.type::text,at_time);
 insert into public.sale_cost_evidence(tenant_id,sale_item_id,sale_id,item_id,price_type,quantity,unit_cost,external_unit_cost,buying_history_id,reconstructed)
 values(new.tenant_id,new.sale_item_id,new.sale_id,new.item_id,new.type::text,new.quantity,h.new_price,h.external_cost,h.history_id,coalesce(h.reconstructed,false));return new;
end $$;
insert into public.sale_cost_evidence(tenant_id,sale_item_id,sale_id,item_id,price_type,quantity,unit_cost,external_unit_cost,buying_history_id,reconstructed)
select si.tenant_id,si.sale_item_id,si.sale_id,si.item_id,si.type::text,si.quantity,h.new_price,h.external_cost,h.history_id,true
from public.sale_items si join public.sales s using(tenant_id,sale_id) left join lateral app_private.buying_price_at(si.tenant_id,si.item_id,si.type::text,s.created_at) h on true where si.type::text in ('refill','package');
create trigger capture_sale_cost after insert on public.sale_items for each row execute function app_private.capture_sale_cost();
alter table public.sale_cost_evidence enable row level security;revoke all on public.sale_cost_evidence from public,anon,authenticated;
create trigger immutable_sale_cost before update or delete on public.sale_cost_evidence for each row execute function app_private.immutable_finance_record();
-- A stable physical baseline plus movements reconstructs quantities, never prices.
create table public.inventory_valuation_baselines(
 tenant_id uuid not null,item_id uuid not null,filled_quantity integer not null,empty_quantity integer not null,
 captured_at timestamptz not null default clock_timestamp(),primary key(tenant_id,item_id),
 foreign key(tenant_id,item_id) references public.items(tenant_id,item_id)
);
insert into public.inventory_valuation_baselines(tenant_id,item_id,filled_quantity,empty_quantity) select tenant_id,item_id,filled_quantity,empty_quantity from public.items;
create function app_private.valuation_baseline_created() returns trigger language plpgsql security definer set search_path='' as $$
begin insert into public.inventory_valuation_baselines(tenant_id,item_id,filled_quantity,empty_quantity,captured_at) values(new.tenant_id,new.item_id,new.filled_quantity,new.empty_quantity,new.created_at-interval '1 microsecond');return new;end $$;
create trigger valuation_baseline_created after insert on public.items for each row execute function app_private.valuation_baseline_created();
alter table public.inventory_valuation_baselines enable row level security;revoke all on public.inventory_valuation_baselines from public,anon,authenticated;
create trigger immutable_valuation_baseline before update or delete on public.inventory_valuation_baselines for each row execute function app_private.immutable_finance_record();
create function app_private.inventory_value_at(t uuid,as_of timestamptz) returns jsonb language sql stable set search_path='' as $$
 with quantities as(select i.item_id,
 b.filled_quantity+coalesce((select sum(case when m.created_at>b.captured_at and m.created_at<=as_of then m.filled_quantity_change when m.created_at>b.captured_at and as_of>=b.captured_at then 0 when m.created_at>as_of and m.created_at<=b.captured_at then -m.filled_quantity_change else 0 end) from public.inventory_movements m where m.tenant_id=t and m.item_id=i.item_id),0) filled,
 b.empty_quantity+coalesce((select sum(case when m.created_at>b.captured_at and m.created_at<=as_of then m.empty_quantity_change when m.created_at>b.captured_at and as_of>=b.captured_at then 0 when m.created_at>as_of and m.created_at<=b.captured_at then -m.empty_quantity_change else 0 end) from public.inventory_movements m where m.tenant_id=t and m.item_id=i.item_id),0) empty
 from public.items i join public.inventory_valuation_baselines b using(tenant_id,item_id) where i.tenant_id=t and i.created_at<=as_of),
 values as(select q.*,p.new_price package,r.new_price refill,case when p.new_price is not null and r.new_price is not null then greatest(0,p.new_price-r.new_price) end empty_price,
 coalesce(p.reconstructed,false) or coalesce(r.reconstructed,false) reconstructed from quantities q
 left join lateral app_private.buying_price_at(t,q.item_id,'package',as_of) p on true left join lateral app_private.buying_price_at(t,q.item_id,'refill',as_of) r on true)
 select jsonb_build_object('known_value',coalesce(sum(greatest(0,filled)*package),0)+coalesce(sum(greatest(0,empty)*empty_price),0),
 'filled_value',coalesce(sum(greatest(0,filled)*package),0),'empty_value',coalesce(sum(greatest(0,empty)*empty_price),0),
 'unvalued_units',coalesce(sum(case when package is null then greatest(0,filled) else 0 end+case when empty_price is null then greatest(0,empty) else 0 end),0),
 'inverted_products',count(*) filter(where package<refill),'negative_stock_products',count(*) filter(where filled<0 or empty<0),
 'reconstructed_products',count(*) filter(where reconstructed),'filled_units',coalesce(sum(filled),0),'empty_units',coalesce(sum(empty),0)) from values;
$$;
create function public.get_inventory_valuation() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['inventory:view','inventory:manage','finance:view','finance:manage']);begin return app_private.inventory_value_at(t,clock_timestamp());end $$;
do $$ declare r record;begin
 for r in select p.oid,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','app_private') and p.proname in ('buying_price_at','refresh_buying_price','purchase_buying_prices','commission_buying_prices','set_product_buying_price','get_buying_price_history','capture_sale_cost','valuation_baseline_created','inventory_value_at','get_inventory_valuation') loop
 execute format('alter function %s owner to postgres',r.oid::regprocedure);execute format('revoke all on function %s from public,anon,authenticated',r.oid::regprocedure);if r.nspname='public' then execute format('grant execute on function %s to authenticated',r.oid::regprocedure);end if;end loop;
end $$;
notify pgrst,'reload schema';
