-- Deployment applies pending migrations in one transaction. ALTER TYPE ADD
-- VALUE cannot be consumed in that transaction; replace the enum instead.
-- Existing status values/rows and the old read contract remain intact here.
drop function public.list_purchases();
alter table public.purchases alter column status drop default;
alter type public.purchase_status rename to purchase_status_previous;
create type public.purchase_status as enum ('created','in_transit','received','cancelled');
alter table public.purchases alter column status type public.purchase_status
  using status::text::public.purchase_status;
alter table public.purchases alter column status set default 'in_transit';
drop type public.purchase_status_previous;

create function public.list_purchases()
returns table(purchase_id uuid,truck_id uuid,truck_name varchar,plant_id uuid,plant_name varchar,
  status public.purchase_status,transport_cost numeric,labour_cost numeric,total_cost numeric,
  notes text,created_at timestamptz,items jsonb)
language plpgsql security definer set search_path='' as $$
begin
  perform app_private.require_any_permission(array['purchases:view','purchases:manage']);
  return query select p.purchase_id,p.truck_id,tr.name,p.plant_id,gp.plant_name,p.status,
    p.transport_cost,p.labour_cost,p.total_cost,p.notes,p.created_at,
    (select jsonb_agg(jsonb_build_object('purchase_item_id',pi.purchase_item_id,'item_id',pi.item_id,
      'brand_name',b.brand_name,'size_kg',i.size_kg,'type',pi.type,'quantity',pi.quantity,
      'unit_price',pi.unit_price,'line_total',pi.line_total))
      from public.purchase_items pi join public.items i on i.tenant_id=pi.tenant_id and i.item_id=pi.item_id
      left join public.lpg_brands b on b.tenant_id=i.tenant_id and b.brand_id=i.brand_id
      where pi.tenant_id=p.tenant_id and pi.purchase_id=p.purchase_id)
    from public.purchases p left join public.trucks tr on tr.tenant_id=p.tenant_id and tr.truck_id=p.truck_id
    left join public.gas_plants gp on gp.tenant_id=p.tenant_id and gp.plant_id=p.plant_id
    where p.tenant_id=app_private.current_tenant_id() order by p.created_at desc;
end $$;
revoke all on function public.list_purchases() from public,anon,authenticated;
grant execute on function public.list_purchases() to authenticated;
