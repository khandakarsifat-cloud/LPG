-- Read-only run-length grouping. Original acquisitions, consumption and journals remain unchanged.
create function public.get_fifo_cost_groups(p_item_id uuid,p_component text,p_state text,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('finance:stock');cat text;begin
 if p_component is null or p_component not in ('gas','bottle','product') or p_state is null or p_state not in ('filled','empty') or p_offset is null or p_offset<0 or p_offset>1000000 then raise exception 'Invalid stock cost filters';end if;
 select business_category into cat from public.items where tenant_id=t and item_id=p_item_id;
 if cat is null then raise insufficient_privilege using message='Product unavailable';end if;
 if (cat='stove' and (p_component<>'product' or p_state<>'filled')) or (cat='lpg' and (p_component='product' or (p_component='gas' and p_state<>'filled'))) then raise exception 'Invalid product component';end if;
 return (with basis as materialized(
 select l.layer_id,l.acquired_at,l.acquired_order,l.slice_no,l.remaining,
 case p_component when 'gas' then l.remaining_value-l.remaining_shell_value+l.remaining_internal_value-l.remaining_internal_shell_value
 when 'bottle' then l.remaining_shell_value+l.remaining_internal_shell_value else l.remaining_value+l.remaining_internal_value end v,
 coalesce(c.estimated,true) estimated
 from app_private.fifo_layers l left join public.inventory_costs c using(tenant_id,item_id)
 where l.tenant_id=t and l.item_id=p_item_id and l.component=p_state and l.remaining>0
 ), preceding as(
 select *,lag(v) over w prior_value,lag(remaining) over w prior_quantity,lag(estimated) over w prior_estimated
 from basis window w as(order by acquired_at,acquired_order,slice_no,layer_id)
 ), runs as(
 select *,sum(case when prior_quantity is null or v*prior_quantity<>prior_value*remaining or estimated is distinct from prior_estimated then 1 else 0 end)
 over(order by acquired_at,acquired_order,slice_no,layer_id) group_id from preceding
 ), groups as materialized(
 select group_id,sum(remaining) quantity,sum(v) value,case when bool_or(estimated) then null else sum(v)/sum(remaining) end unit_cost,bool_or(estimated) estimated
 from runs group by group_id
 ), page as(select * from groups order by group_id limit 25 offset p_offset)
 select jsonb_build_object('total',(select count(*) from groups),'quantity',coalesce((select sum(quantity) from groups),0),'value',coalesce((select sum(value) from groups),0),
 'rows',coalesce((select jsonb_agg(to_jsonb(p) order by group_id) from page p),'[]')));
end$$;
revoke all on function public.get_fifo_cost_groups(uuid,text,text,integer) from public,anon;
grant execute on function public.get_fifo_cost_groups(uuid,text,text,integer) to authenticated;

create function public.get_fifo_products(p_business text,p_search text default '',p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('finance:stock');begin
 if p_business is null or p_business not in ('lpg','stove') or p_search is null or length(p_search)>200 or p_offset is null or p_offset<0 or p_offset>1000000 then raise exception 'Invalid product filters';end if;
 return (with matching as materialized(select i.item_id,case when i.business_category='lpg' then concat(b.brand_name,' · ',i.size_kg,' kg · ',i.mouth_size) else concat(st.name,' · ',i.product_name) end label
 from public.items i left join public.lpg_brands b using(tenant_id,brand_id) left join public.stove_product_types st on st.tenant_id=i.tenant_id and st.type_id=i.product_type_id
 where i.tenant_id=t and i.business_category=p_business), filtered as materialized(select * from matching where position(lower(trim(p_search)) in lower(label))>0),
 page as(select * from filtered order by label,item_id limit 25 offset p_offset)
 select jsonb_build_object('total',(select count(*) from filtered),'entries',coalesce((select jsonb_agg(to_jsonb(p) order by label,item_id) from page p),'[]')));
end$$;
revoke all on function public.get_fifo_products(text,text,integer) from public,anon;
grant execute on function public.get_fifo_products(text,text,integer) to authenticated;

create function public.get_stove_performance(p_from date default null,p_to date default null,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('finance:stock');begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or (p_from is not null and not isfinite(p_from)) or (p_to is not null and not isfinite(p_to)) or p_from>p_to then raise exception 'Invalid reporting range';end if;
 return (with sold as materialized(
 select si.item_id,sum(si.quantity) qty from public.sale_items si join public.sales s using(tenant_id,sale_id)
 where si.tenant_id=t and s.status='completed' and s.business_category='stove' and si.type='package'
 and (p_from is null or s.created_at>=p_from::timestamp at time zone 'Asia/Dhaka') and (p_to is null or s.created_at<(p_to+1)::timestamp at time zone 'Asia/Dhaka') group by si.item_id
 ), bought as materialized(
 select pi.item_id,sum(pi.quantity) qty from public.purchase_items pi join public.purchases p using(tenant_id,purchase_id)
 where pi.tenant_id=t and p.status='received' and p.business_category='stove'
 and (p_from is null or p.received_at>=p_from::timestamp at time zone 'Asia/Dhaka') and (p_to is null or p.received_at<(p_to+1)::timestamp at time zone 'Asia/Dhaka') group by pi.item_id
 ), entries as materialized(
 select i.item_id,i.product_name,st.type_id,st.name category,coalesce(s.qty,0) sold,coalesce(b.qty,0) bought from public.items i
 join public.stove_product_types st on st.tenant_id=i.tenant_id and st.type_id=i.product_type_id
 left join sold s using(item_id) left join bought b using(item_id) where i.tenant_id=t and i.business_category='stove'
 ), page as(select * from entries order by category,type_id,product_name,item_id limit 25 offset p_offset)
 select jsonb_build_object('total',(select count(*) from entries),'totals',jsonb_build_object('sold',coalesce((select sum(sold) from entries),0),'bought',coalesce((select sum(bought) from entries),0)),
 'rows',coalesce((select jsonb_agg(to_jsonb(p) order by category,type_id,product_name,item_id) from page p),'[]')));
end$$;
revoke all on function public.get_stove_performance(date,date,integer) from public,anon;
grant execute on function public.get_stove_performance(date,date,integer) to authenticated;

-- Owner is a full-access role; individual business actions are delegable capabilities.
-- Existing role mappings are deliberately not expanded by this migration.
insert into public.permissions(permission_id,module,label,description,owner_only,dependencies) values
 ('inventory:mrp','Inventory','Set product MRP','Change displayed maximum retail prices independently of selling prices.',false,array['inventory:manage']),
 ('inventory:buying_prices','Inventory','Override approximate buying prices','Change Gas/Bottle references without rewriting existing FIFO costs.',false,array['inventory:manage']),
 ('sales:backdate','Sales','Backdate sales','Record a sale on an earlier business date.',false,array['pos:sell']),
 ('purchases:rebates','Purchases','Manage manual purchase rebates','Apply and correct supplier rebate credit without changing acquisition costs.',false,array['purchases:manage'])
 on conflict(permission_id) do nothing;
update public.permissions set owner_only=false where permission_id in ('inventory:prices','inventory:adjust','sales:cancel','sales:refund','purchases:cancel','logistics:retire','wallets:adjust','finance:owner');
update public.permissions set label='Set product selling prices',description='Change Retail and Wholesale selling prices; MRP and buying references have independent controls.' where permission_id='inventory:prices';
update public.permissions set label='Manage capital, loans, assets and obligations' where permission_id='finance:owner';
-- Replace only known action bodies, preserving their locks, request namespaces and collector wrappers.
do $$declare r record;body text;cap text;begin
 for r in select p.oid,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','app_private') and p.prosrc like '%require_owner(%' loop
 cap:=case r.proname
 when 'action_adjust_inventory' then 'inventory:adjust'
 when 'action_create_pos_sale' then 'sales:backdate'
 when 'action_create_purchase' then 'purchases:rebates'
 when 'action_update_purchase' then 'purchases:rebates'
 when 'action_set_purchase_rebate' then 'purchases:rebates'
 when 'action_set_product_buying_price' then 'inventory:buying_prices'
 when 'action_reverse_sale' then 'sales:cancel'
 when 'action_refund_sale' then 'sales:refund'
 when 'action_accounting_operation' then 'finance:owner'
 when 'action_record_financial_entry' then 'finance:owner'
 when 'action_move_wallet_money' then 'finance:owner'
 when 'set_vehicle_availability' then 'logistics:retire'
 when 'get_accounting_history' then 'finance:owner'
 when 'get_accounting_register' then 'finance:owner'
 else null end;
 if cap is not null then
  body:=pg_get_functiondef(r.oid);
  body:=regexp_replace(body,'app_private.require_owner\(''[^'']+''\)','app_private.require_permission('''||cap||''')','g');
  if r.proname='action_set_product_buying_price' then body:=replace(body,'app_private.require_permission(''inventory:prices'')','app_private.require_permission(''inventory:buying_prices'')');end if;
  execute body;
 end if;
 end loop;
end$$;
create or replace function public.can_cancel_purchases() returns boolean language sql stable security definer set search_path='' as $$select app_private.has_permission('purchases:cancel')$$;
create or replace function app_private.can_manage_inventory_prices() returns boolean language sql stable security definer set search_path='' as $$select app_private.has_any_permission(array['inventory:prices','inventory:mrp'])$$;
-- Price-field checks run under the existing product lock and version checks.
do $$declare body text;begin
 body:=pg_get_functiondef('public.save_product_prices(uuid,text,jsonb,jsonb)'::regprocedure);
 body:=replace(body,'begin perform app_private.require_permission(''inventory:prices'');','begin');
 body:=replace(body,'Only the owner can edit product prices','Price editing permission required');
 body:=replace(body,'    update public.price_books set effective_to=saved_at',
 $patch$
    if not app_private.has_permission('inventory:prices') and selling is distinct from (
      select price from public.price_books where tenant_id=t and item_id=p_item_id and price_type=kind and customer_tier in (p_customer_tier,'retail')
      and effective_from<=saved_at and (effective_to is null or effective_to>saved_at) order by case when customer_tier=p_customer_tier then 0 else 1 end,effective_from desc limit 1
    ) then raise insufficient_privilege using message='Selling price permission required';end if;
    if not app_private.has_permission('inventory:mrp') and display_mrp is distinct from (
      select mrp from public.price_books where tenant_id=t and item_id=p_item_id and price_type=kind and customer_tier in (p_customer_tier,'retail')
      and effective_from<=saved_at and (effective_to is null or effective_to>saved_at) order by case when customer_tier=p_customer_tier then 0 else 1 end,effective_from desc limit 1
    ) then raise insufficient_privilege using message='MRP permission required';end if;
    update public.price_books set effective_to=saved_at$patch$);
 execute body;
end$$;
-- Effective-permission fingerprints invalidate cached access; individual grants retain existing revision updates.
