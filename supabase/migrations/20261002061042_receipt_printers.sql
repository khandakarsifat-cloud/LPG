-- One receipt printer per business. Device identity survives disconnection.
create table public.receipt_printers (
  tenant_id uuid primary key references public.tenants(tenant_id) on delete cascade,
  printer jsonb not null,
  paper_width_mm integer not null default 80 check (paper_width_mm in (58, 80)),
  printable_width_dots integer not null default 576,
  auto_cut boolean not null default false,
  constraint receipt_printer_width check (
    printable_width_dots >= 240 and printable_width_dots % 8 = 0 and
    printable_width_dots <= case paper_width_mm when 58 then 464 else 640 end
  ),
  constraint receipt_printer_identity check (
    jsonb_typeof(printer) = 'object' and
    coalesce(printer->>'transport' = 'windows_usb', false) and
    coalesce(length(printer->>'queue_id') between 1 and 200, false) and
    coalesce(length(printer->>'host_id') between 1 and 200, false) and
    coalesce(length(printer->>'queue_name') between 1 and 500, false) and
    coalesce(length(printer->>'port_name') between 1 and 500, false)
  )
);

alter table public.receipt_printers enable row level security;
revoke all on public.receipt_printers from anon;
grant select, insert, update on public.receipt_printers to authenticated;

create policy receipt_printers_select on public.receipt_printers
  for select to authenticated using (tenant_id = (select public.my_tenant_id()));
create policy receipt_printers_insert on public.receipt_printers
  for insert to authenticated with check (tenant_id = (select public.my_tenant_id()));
create policy receipt_printers_update on public.receipt_printers
  for update to authenticated using (tenant_id = (select public.my_tenant_id()))
  with check (tenant_id = (select public.my_tenant_id()));

notify pgrst, 'reload schema';
