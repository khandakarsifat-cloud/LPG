-- Keep default type identity independent of its editable display name.
alter table public.stove_product_types add column system_key text
 check (system_key in ('single_stove','double_stove','regulator','pipe','others'));
create unique index stove_default_type_identity on public.stove_product_types(tenant_id,system_key) where system_key is not null;
update public.stove_product_types set system_key=case name
 when 'Single Stove' then 'single_stove' when 'Double Stove' then 'double_stove'
 when 'Regulator' then 'regulator' when 'Pipe' then 'pipe' when 'Others' then 'others' end
where name in ('Single Stove','Double Stove','Regulator','Pipe','Others');

create or replace function app_private.seed_stove_types(t uuid) returns void language sql set search_path='' as $$
 insert into public.stove_product_types(tenant_id,name,system_key)
 select t,name,system_key from (values
  ('Single Stove','single_stove'),('Double Stove','double_stove'),('Regulator','regulator'),('Pipe','pipe'),('Others','others'))d(name,system_key)
 on conflict do nothing;
$$;

create function app_private.dashboard_stove_types(t uuid) returns jsonb language sql stable set search_path='' as $$
 with sold as (
  select i.product_type_id,sum(si.quantity) quantity
  from public.sales s join public.sale_items si using(tenant_id,sale_id) join public.items i using(tenant_id,item_id)
  where s.tenant_id=t and s.status='completed' and i.business_category='stove' and si.type in ('refill','package')
   and s.created_at >= ((now() at time zone 'Asia/Dhaka')::date)::timestamp at time zone 'Asia/Dhaka'
   and s.created_at < ((now() at time zone 'Asia/Dhaka')::date+1)::timestamp at time zone 'Asia/Dhaka'
  group by i.product_type_id
 )
 select coalesce(jsonb_agg(jsonb_build_object('type_id',pt.type_id,'name',pt.name,'system_key',pt.system_key,'quantity',coalesce(s.quantity,0))
  order by coalesce(array_position(array['single_stove','double_stove','regulator','pipe','others'],pt.system_key),6),lower(pt.name),pt.type_id),'[]')
 from public.stove_product_types pt left join sold s on s.product_type_id=pt.type_id
 where pt.tenant_id=t and (pt.is_active or coalesce(s.quantity,0)>0);
$$;
revoke all on function app_private.dashboard_stove_types(uuid) from public,anon,authenticated;

-- Replace only the dashboard's old product presentation contract. Accounting,
-- sales, payments and stock source records are untouched.
do $$declare source text;updated text;old text:=$old$'products',coalesce((select jsonb_agg(jsonb_build_object('item_id',item_id,'name',product_name,'image_url',image_url,'quantity',quantity) order by quantity desc,product_name,item_id) from sold where business_category='stove'),'[]'),$old$;begin
 source:=pg_get_functiondef('app_private.dashboard_snapshot(uuid)'::regprocedure);
 updated:=replace(source,old,'''stove_types'',app_private.dashboard_stove_types(t),');
 if updated=source then raise exception 'Dashboard stove product contract changed';end if;
 execute updated;
end $$;
notify pgrst,'reload schema';
