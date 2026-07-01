alter table public.customers
  alter column phone set not null;

alter table public.customers
  drop constraint if exists customers_phone_bd_format_check;

alter table public.customers
  add constraint customers_phone_bd_format_check
  check (phone ~ '^(01[3-9][0-9]{8}|\+8801[3-9][0-9]{8})$');
