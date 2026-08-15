alter table public.customers
  drop constraint if exists customers_phone_bd_format_check;

with normalized_customers as (
  select
    tenant_id,
    customer_id,
    case
      when regexp_replace(phone, '\D', '', 'g') ~ '^8801[3-9][0-9]{8}$'
        then '0' || regexp_replace(phone, '\D', '', 'g')
      else regexp_replace(phone, '\D', '', 'g')
    end as next_phone
  from public.customers
  where phone ~ '\D'
     or phone ~ '^8801[3-9][0-9]{8}$'
)
update public.customers c
set phone = n.next_phone
from normalized_customers n
where c.tenant_id = n.tenant_id
  and c.customer_id = n.customer_id;

alter table public.customers
  add constraint customers_phone_bd_format_check
  check (phone ~ '^(01[3-9][0-9]{8}|08801[3-9][0-9]{8})$');
