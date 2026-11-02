-- One visible status contract includes cancelled sales without treating them as paid.
-- Bottle obligation/gain reversals are part of their original sale cancellation.
do $$declare s text;begin
 s:=pg_get_functiondef('app_private.source_type(uuid,text,uuid,text)'::regprocedure);
 if position('elsif src=''development_opening''' in s)=0 then raise exception 'Source classification contract changed';end if;
 s:=replace(s,'elsif src=''development_opening''','elsif src=''bottle_reversal'' then c:=''sale_reversal''; elsif src=''development_opening''');execute s;
 s:=pg_get_functiondef('app_private.financial_source_link(uuid,text,uuid)'::regprocedure);
 if position('src in (''sale'',''sale_reversal'')' in s)=0 then raise exception 'Sale source link contract changed';end if;
 s:=replace(s,'src in (''sale'',''sale_reversal'')','src in (''sale'',''sale_reversal'',''bottle_reversal'')');execute s;
end $$;

-- Normal issues use FIFO. A cancellation returns the exact received bottles:
-- consume only the original receipt layers, never an older unrelated layer.
-- Quantity/value and downstream-consumption checks remain transactional.
do $$declare s text;old text;replacement text;begin
 s:=pg_get_functiondef('app_private.fifo_cost_movement(public.inventory_movements)'::regprocedure);
 old:='if m.empty_quantity_change<0 then ec:=-app_private.fifo_take(m.tenant_id,m.item_id,m.movement_id,''empty'',-m.empty_quantity_change);end if;';
 if position(old in s)=0 then raise exception 'FIFO empty issue contract changed';end if;
 s:=replace(s,old,'if m.empty_quantity_change<0 and m.reference_type is distinct from ''sale_reversal'' then ec:=-app_private.fifo_take(m.tenant_id,m.item_id,m.movement_id,''empty'',-m.empty_quantity_change);end if;');
 old:=substring(s from 'elsif m.reference_type=''sale_reversal'' then[[:space:]]+issued_shell:=ec;');
 replacement:=$body$elsif m.reference_type='sale_reversal' then
  if m.empty_quantity_change<0 then
   for batch in
    select l.* from app_private.fifo_layers l join public.inventory_movements im using(tenant_id,movement_id)
    where l.tenant_id=m.tenant_id and l.item_id=m.item_id and l.component='empty'
     and im.reference_type='sale' and im.reference_id=m.reference_id and im.empty_quantity_change>0
    order by l.acquired_at,l.acquired_order for update of l
   loop
    if batch.remaining<>batch.quantity or batch.remaining_value<>batch.value then
     raise exception 'The received bottle batch has been consumed or changed; restore the original batch before cancelling this sale';
    end if;
    issued_shell:=issued_shell+batch.quantity;
    ec:=ec-batch.remaining_value;
    insert into app_private.fifo_consumptions(tenant_id,movement_id,layer_id,quantity,value,shell_value,internal_value)
     values(m.tenant_id,m.movement_id,batch.layer_id,batch.remaining,batch.remaining_value,batch.remaining_shell_value,batch.remaining_internal_value);
    update app_private.fifo_layers set remaining=0,remaining_value=0,remaining_shell_value=0,remaining_internal_value=0
     where tenant_id=m.tenant_id and layer_id=batch.layer_id;
   end loop;
   if issued_shell<>-m.empty_quantity_change then raise exception 'Received bottle quantity evidence does not reconcile; review this sale before cancellation';end if;
  end if;
  issued_shell:=ec;$body$;
 if old is null then raise exception 'FIFO sale reversal contract changed';end if;
 s:=replace(s,old,replacement);execute s;
end $$;

-- Acquire every affected SKU before any inventory trigger invalidates savepoints.
do $$declare s text;marker text:='for r in select item_id,-sum(filled_quantity_change)';begin
 s:=pg_get_functiondef('public.reverse_sale(uuid,text,text,uuid)'::regprocedure);
 if position(marker in s)=0 then raise exception 'Sale cancellation lock contract changed';end if;
 s:=replace(s,marker,'perform 1 from public.items where tenant_id=t and item_id in (select item_id from public.inventory_movements where tenant_id=t and reference_id=p_sale_id and reference_type=''sale'') order by item_id for update; '||marker);execute s;
end $$;

CREATE OR REPLACE FUNCTION public.get_sales_directory(p_filters jsonb DEFAULT '{}'::jsonb, p_offset integer DEFAULT 0, p_limit integer DEFAULT 25) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
declare t uuid:=app_private.require_permission('sales:view'); result jsonb; ordering text:=coalesce(p_filters->>'sort','date_desc');
 sale_filter text:=coalesce(p_filters->>'status','all'); bottles text:=coalesce(p_filters->>'bottles','all');
 from_day date:=nullif(p_filters->>'from','')::date; to_day date:=nullif(p_filters->>'to','')::date;
begin
 if p_filters is null or jsonb_typeof(p_filters)<>'object' or length(coalesce(p_filters->>'search',''))>500 or p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid sales page'; end if;
 if ordering not in ('date_desc','date_asc','amount_desc','amount_asc','due_desc','due_asc','bottles_desc','bottles_asc','customer_asc','customer_desc') or sale_filter not in ('all','unpaid','partial','paid','outstanding','cancelled') or bottles not in ('all','outstanding','partial','none_received','received') or coalesce(p_filters->>'tier','all') not in ('all','retail','wholesale') or coalesce(p_filters->>'business_category','all') not in ('all','lpg','stove') or from_day>to_day then raise exception 'Invalid sales filter'; end if;
 with headers as materialized (
  select s.sale_id,s.status,s.business_category,s.created_at,s.customer_id,s.sale_tier,s.total_amount original_total,s.additional_charges,s.total_amount+s.additional_charges total_amount,s.paid_amount,case when s.status='voided' then 0 else s.total_amount+s.additional_charges-s.paid_amount end due,(case when s.status='voided' then s.paid_amount-coalesce((select sum(amount) from public.sale_refunds where tenant_id=t and sale_id=s.sale_id),0) else 0 end) refund_due,
   c.name,c.phone,c.shop_name,
   coalesce(q.expected,0) expected,case when s.status='voided' then 0 else greatest(0,coalesce(q.expected,0)-coalesce(q.received,0)) end outstanding_bottles,coalesce(q.received,0) received_bottles
  from public.sales s join public.customers c on c.tenant_id=t and c.customer_id=s.customer_id
  left join lateral (select
   (select coalesce(sum(quantity),0) from public.sale_items where type='empty_return' and tenant_id=t and sale_id=s.sale_id) expected,
   (select coalesce(sum(quantity),0) from public.sale_bottle_receipt_lines where tenant_id=t and sale_id=s.sale_id) received) q on true
  where s.tenant_id=t and (coalesce(p_filters->>'business_category','all')='all' or s.business_category=p_filters->>'business_category')
   and (from_day is null or s.created_at>=from_day::timestamp at time zone 'Asia/Dhaka') and (to_day is null or s.created_at<(to_day+1)::timestamp at time zone 'Asia/Dhaka')
   and (coalesce(p_filters->>'tier','all')='all' or s.sale_tier=p_filters->>'tier')
   and app_private.finance_search(concat_ws(' ',s.sale_id,c.name,c.phone,c.shop_name,s.sale_tier,s.notes,
    (select string_agg(concat_ws(' ',i.product_name,b.brand_name,case when i.business_category='lpg' then i.size_kg||'kg' end,i.mouth_size,si.type),' ') from public.sale_items si join public.items i on i.tenant_id=t and i.item_id=si.item_id left join public.lpg_brands b on b.tenant_id=t and b.brand_id=i.brand_id where si.tenant_id=t and si.sale_id=s.sale_id)),coalesce(p_filters->>'search',''))
 ), matching as materialized (
  select * from headers where (sale_filter='all' or sale_filter='cancelled' and status='voided' or status='completed' and (sale_filter='unpaid' and paid_amount=0 and due>0 or sale_filter='partial' and paid_amount>0 and due>0 or sale_filter='paid' and due=0 or sale_filter='outstanding' and due>0))
   and (bottles='all' or status='completed' and (bottles='outstanding' and outstanding_bottles>0 or bottles='partial' and received_bottles>0 and outstanding_bottles>0 or bottles='none_received' and received_bottles=0 and outstanding_bottles>0 or bottles='received' and outstanding_bottles=0))
 ), page as (
  select * from matching order by case when ordering='date_desc' then created_at end desc,case when ordering='date_asc' then created_at end asc,
   case when ordering='amount_desc' then total_amount end desc,case when ordering='amount_asc' then total_amount end asc,
   case when ordering='due_desc' then due end desc,case when ordering='due_asc' then due end asc,case when ordering='bottles_desc' then outstanding_bottles end desc,case when ordering='bottles_asc' then outstanding_bottles end asc,case when ordering='customer_asc' then lower(case when sale_tier='wholesale' then coalesce(nullif(shop_name,''),name) else name end) end asc,case when ordering='customer_desc' then lower(case when sale_tier='wholesale' then coalesce(nullif(shop_name,''),name) else name end) end desc,sale_id desc limit p_limit offset p_offset
 ), details as (
  select p.*,coalesce((select jsonb_agg(jsonb_build_object('item_id',si.item_id,'type',si.type,'quantity',si.quantity,'name',concat_ws(' ',i.product_name,b.brand_name,case when i.business_category='lpg' then i.size_kg||'kg' end,i.mouth_size)) order by si.type,si.item_id)
   from public.sale_items si join public.items i on i.tenant_id=t and i.item_id=si.item_id left join public.lpg_brands b on b.tenant_id=t and b.brand_id=i.brand_id where si.tenant_id=t and si.sale_id=p.sale_id),'[]') items
  from page p
 ) select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(to_jsonb(d) order by
  case when ordering='date_desc' then created_at end desc,case when ordering='date_asc' then created_at end asc,
  case when ordering='amount_desc' then total_amount end desc,case when ordering='amount_asc' then total_amount end asc,
  case when ordering='due_desc' then due end desc,case when ordering='due_asc' then due end asc,case when ordering='bottles_desc' then outstanding_bottles end desc,case when ordering='bottles_asc' then outstanding_bottles end asc,case when ordering='customer_asc' then lower(case when sale_tier='wholesale' then coalesce(nullif(shop_name,''),name) else name end) end asc,case when ordering='customer_desc' then lower(case when sale_tier='wholesale' then coalesce(nullif(shop_name,''),name) else name end) end desc,sale_id desc) from details d),'[]')) into result;
 return result;
end $$;

-- The sales count includes saved cancellations; billed/due totals continue to
-- describe completed business only, without resurrecting cancelled revenue.
do $$declare s text;begin
 s:=pg_get_functiondef('public.get_sales_overview()'::regprocedure);
 if position('''total'',count(*)' in s)=0 then raise exception 'Sales overview count contract changed';end if;
 s:=replace(s,'''total'',count(*)','''total'',(select count(*) from public.sales where tenant_id=t)');execute s;
end $$;
