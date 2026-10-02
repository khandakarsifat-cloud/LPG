-- Run on the local LPG database through execute_sql/psql. All fixtures roll back.
begin;

insert into public.tenants(tenant_id, business_name) values
  ('a1111111-1111-4111-8111-111111111111', 'Printer integration test A'),
  ('b1111111-1111-4111-8111-111111111111', 'Printer integration test B');
insert into public.user_profiles(user_id, tenant_id, email) values
  ('a2222222-2222-4222-8222-222222222222', 'a1111111-1111-4111-8111-111111111111', 'printer-a@example.invalid'),
  ('b2222222-2222-4222-8222-222222222222', 'b1111111-1111-4111-8111-111111111111', 'printer-b@example.invalid');
insert into public.items(tenant_id, item_id, brand, size_kg, filled_quantity, empty_quantity)
  values ('a1111111-1111-4111-8111-111111111111', 'a3333333-3333-4333-8333-333333333333', 'Print test item', 12, 10, 10);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'a2222222-2222-4222-8222-222222222222', true);

insert into public.receipt_printers(tenant_id, printer) values
  ('a1111111-1111-4111-8111-111111111111', '{"transport":"windows_usb","queue_id":"test","host_id":"test","queue_name":"Disconnected test printer","port_name":"USB001"}');
insert into public.receipt_printers(tenant_id, printer, paper_width_mm, printable_width_dots) values
  ('a1111111-1111-4111-8111-111111111111', '{"transport":"windows_usb","queue_id":"test","host_id":"test","queue_name":"Disconnected test printer","port_name":"USB001"}', 58, 384)
  on conflict(tenant_id) do update set paper_width_mm = excluded.paper_width_mm, printable_width_dots = excluded.printable_width_dots;

do $$
declare result jsonb;
begin
  if (select count(*) from public.receipt_printers) <> 1 then raise exception 'Upsert duplicated configuration'; end if;
  if (select printable_width_dots from public.receipt_printers limit 1) <> 384 then raise exception 'Upsert did not update settings'; end if;
  begin
    insert into public.receipt_printers(tenant_id, printer) values
      ('b1111111-1111-4111-8111-111111111111', '{"transport":"windows_usb","queue_id":"test","host_id":"test","queue_name":"test","port_name":"USB001"}');
    raise exception 'Cross-tenant insert allowed';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.receipt_printers set tenant_id = 'b1111111-1111-4111-8111-111111111111';
    raise exception 'Tenant reassignment allowed';
  exception when insufficient_privilege then null;
  end;
  if has_table_privilege('authenticated', 'public.receipt_printers', 'TRUNCATE') then
    raise exception 'Authenticated role has truncate access';
  end if;

  result := public.create_pos_sale('01700000000', 'Print integration customer', null, null, 'retail', 100, 50,
    'Integration test - rollback', '[{"item_id":"a3333333-3333-4333-8333-333333333333","type":"refill","quantity":1,"unit_price":1200},{"item_id":"a3333333-3333-4333-8333-333333333333","type":"empty_return","quantity":1,"unit_price":0}]'::jsonb);
  if (select count(*) from public.sales) <> 1 then raise exception 'Expected one saved sale'; end if;
  if (select status::text from public.sales limit 1) <> 'completed' then raise exception 'Sale not completed'; end if;
  if (result->>'total_amount')::numeric <> 1150 then raise exception 'Incorrect saved totals'; end if;
  if (select count(*) from public.sale_items) <> 2 then raise exception 'Missing receipt items'; end if;
  if (select count(*) from public.inventory_movements) <> 2 then raise exception 'Wrong movement count'; end if;
end $$;

select set_config('request.jwt.claim.sub', 'b2222222-2222-4222-8222-222222222222', true);
do $$ begin
  if exists(select 1 from public.receipt_printers) then raise exception 'Cross-tenant printer read allowed'; end if;
  if exists(select 1 from public.sales) then raise exception 'Cross-tenant receipt read allowed'; end if;
end $$;

set local role anon;
do $$ begin
  begin
    perform 1 from public.receipt_printers;
    raise exception 'Anonymous configuration read allowed';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
select 'PASS: tenant isolation, configuration upsert, privilege boundaries, and real checkout RPC; all test fixtures rolled back' as verification;
rollback;
