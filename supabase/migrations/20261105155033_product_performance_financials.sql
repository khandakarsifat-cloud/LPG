-- Read-only product economics from original sale lines and linked FIFO issues.
-- Return events reverse their original price/discount/cost on the return date.
create function public.get_product_performance(p_business text,p_from date default null,p_to date default null,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('finance:stock');begin
 if p_business not in('lpg','stove') or p_business is null or p_offset is null or p_offset<0 or p_offset>1000000
 or (p_from is not null and not isfinite(p_from)) or (p_to is not null and not isfinite(p_to)) or p_from>p_to then raise exception 'Invalid reporting range';end if;
 return (with sale_lines as materialized(
  select si.tenant_id,si.sale_item_id,si.sale_id,si.item_id,si.type::text type,si.quantity,si.line_total,s.created_at sold_at,s.discount_amount,s.subtotal,
   sum(si.line_total) over(partition by si.sale_id order by si.item_id,si.type,si.sale_item_id) cumulative,
   r.created_at reversed_at
  from public.sale_items si join public.sales s using(tenant_id,sale_id)
  left join public.sale_reversals r using(tenant_id,sale_id)
  where si.tenant_id=t and s.business_category=p_business and s.status in('completed','voided') and si.type in('refill','package')
  and (((p_from is null or s.created_at>=p_from::timestamp at time zone 'Asia/Dhaka') and (p_to is null or s.created_at<(p_to+1)::timestamp at time zone 'Asia/Dhaka'))
   or (r.created_at is not null and (p_from is null or r.created_at>=p_from::timestamp at time zone 'Asia/Dhaka') and (p_to is null or r.created_at<(p_to+1)::timestamp at time zone 'Asia/Dhaka')))
 ), priced as materialized(
  select sl.*,sl.line_total-case when sl.subtotal>0 then
   round(sl.discount_amount*sl.cumulative/sl.subtotal,2)-round(sl.discount_amount*(sl.cumulative-sl.line_total)/sl.subtotal,2) else 0 end revenue,
   c.cost,c.qty,coalesce(c.estimated,false) estimated
  from sale_lines sl left join lateral(
   select sum(fc.quantity) qty,
    sum(fc.value+fc.internal_value-case when sl.type='refill' then fc.shell_value+fc.internal_shell_value else 0 end) cost,
    bool_or(coalesce(ce.estimated,true)) estimated
   from public.inventory_movements m join app_private.fifo_consumptions fc using(tenant_id,movement_id)
   join app_private.fifo_layers l using(tenant_id,layer_id)
   left join public.inventory_cost_entries ce on ce.tenant_id=l.tenant_id and ce.movement_id=l.movement_id
   where m.tenant_id=t and m.reference_type='sale' and m.reference_id=sl.sale_id and m.item_id=sl.item_id
    and m.filled_quantity_change<0 and m.valuation->>'sale_type'=sl.type
  ) c on true
 ), events as materialized(
  select p.item_id,p.type,e.at,e.sign*p.quantity sold,e.sign*p.revenue revenue,e.sign*p.cost cogs,
   case when p.qty is distinct from p.quantity then p.quantity else 0 end missing_units,
   case when p.estimated then p.quantity else 0 end estimated_units
  from priced p cross join lateral(values(p.sold_at,1),(p.reversed_at,-1)) e(at,sign)
  where e.at is not null and (p_from is null or e.at>=p_from::timestamp at time zone 'Asia/Dhaka')
   and (p_to is null or e.at<(p_to+1)::timestamp at time zone 'Asia/Dhaka')
 ), sold as materialized(
  select item_id,type,sum(sold) sold,sum(revenue) revenue,sum(cogs) cogs,sum(missing_units) missing_units,sum(estimated_units) estimated_units
  from events group by item_id,type
 ), bought as materialized(
  select pi.item_id,ty.type,sum(e.sign*case when p_business='stove' then pi.quantity when ty.type='refill' then pi.quantity-pi.bottle_quantity else pi.bottle_quantity end) bought
  from public.purchase_items pi join public.purchases p using(tenant_id,purchase_id)
  cross join lateral(values(p.received_at,1),(case when p.status='cancelled' and p.received_at is not null then p.cancelled_at end,-1)) e(at,sign)
  cross join lateral(select 'package'::text type union all select 'refill' where p_business='lpg') ty
  where pi.tenant_id=t and p.business_category=p_business and p.received_at is not null and e.at is not null
   and (p_from is null or e.at>=p_from::timestamp at time zone 'Asia/Dhaka') and (p_to is null or e.at<(p_to+1)::timestamp at time zone 'Asia/Dhaka')
  group by pi.item_id,ty.type
 ), entries as materialized(
  select i.item_id,ty.type,coalesce(b.brand_name,st.name) category,
   case when p_business='lpg' then i.size_kg::text||' kg · '||i.mouth_size::text else i.product_name end product_name,
   coalesce(s.sold,0) sold,coalesce(p.bought,0) bought,coalesce(s.revenue,0) revenue,
   case when coalesce(s.missing_units,0)=0 then coalesce(s.cogs,0) end cogs,
   case when coalesce(s.missing_units,0)=0 then coalesce(s.revenue,0)-coalesce(s.cogs,0) end margin,
   case when coalesce(s.missing_units,0)=0 and s.sold>0 then round((s.revenue-coalesce(s.cogs,0))/s.sold,2) end average_margin,
   coalesce(s.missing_units,0) missing_units,coalesce(s.estimated_units,0) estimated_units
  from public.items i left join public.lpg_brands b using(tenant_id,brand_id)
  left join public.stove_product_types st on st.tenant_id=i.tenant_id and st.type_id=i.product_type_id
  cross join lateral(select 'package'::text type union all select 'refill' where p_business='lpg') ty
  left join sold s on s.item_id=i.item_id and s.type=ty.type left join bought p on p.item_id=i.item_id and p.type=ty.type
  where i.tenant_id=t and i.business_category=p_business
 ), page as(select * from entries order by category,product_name,item_id,type desc limit 25 offset p_offset),
 totals as(select coalesce(sum(sold),0) sold,coalesce(sum(bought),0) bought,coalesce(sum(revenue),0) revenue,
  case when coalesce(sum(missing_units),0)=0 then coalesce(sum(cogs),0) end cogs,
  case when coalesce(sum(missing_units),0)=0 then coalesce(sum(margin),0) end margin,
  case when coalesce(sum(missing_units),0)=0 and sum(sold)>0 then round(sum(margin)/sum(sold),2) end average_margin,
  coalesce(sum(missing_units),0) missing_units,coalesce(sum(estimated_units),0) estimated_units from entries)
 select jsonb_build_object('total',(select count(*) from entries),'generated_at',now(),'business',p_business,
  'rows',coalesce((select jsonb_agg(to_jsonb(p) order by category,product_name,item_id,type desc) from page p),'[]'),
  'totals',(select to_jsonb(totals) from totals)));
end $$;
revoke all on function public.get_product_performance(text,date,date,integer) from public,anon;
grant execute on function public.get_product_performance(text,date,date,integer) to authenticated;
-- Obsolete quantity-only public contracts are replaced by this business-aware API.
drop function public.get_lpg_performance(date,date,integer);
drop function public.get_stove_performance(date,date,integer);
