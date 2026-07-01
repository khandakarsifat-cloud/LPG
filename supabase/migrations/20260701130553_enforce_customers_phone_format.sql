begin;

-- Normalize existing customer phone values before enforcing NOT NULL and format.
-- Bangladesh phone formats allowed:
--   local:         01xxxxxxxxx
--   international: +8801xxxxxxxxx
--
-- This migration intentionally checks for duplicate fallback values first because
-- public.customers has a unique index on (tenant_id, phone). If more than one
-- invalid phone exists for a tenant, setting each to 01000000000 would violate
-- that index and should be resolved explicitly before applying.
do $$
begin
  if exists (
    select 1
    from public.customers
    where phone is null
      or btrim(phone) = ''
      or not (btrim(phone) ~ '^(01[0-9]{9}|\+8801[0-9]{9})$')
    group by tenant_id
    having count(*) > 1
  ) then
    raise exception
      'Cannot set all invalid customer phone values to 01000000000 because multiple invalid rows exist for at least one tenant and customers_tenant_phone_unique would be violated.';
  end if;
end $$;

update public.customers
set phone = '01000000000'
where phone is null
  or btrim(phone) = ''
  or not (btrim(phone) ~ '^(01[0-9]{9}|\+8801[0-9]{9})$');

alter table public.customers
  alter column phone set not null;

alter table public.customers
  drop constraint if exists customers_phone_bd_format_check;

alter table public.customers
  add constraint customers_phone_bd_format_check
  check (btrim(phone) ~ '^(01[0-9]{9}|\+8801[0-9]{9})$');

commit;
