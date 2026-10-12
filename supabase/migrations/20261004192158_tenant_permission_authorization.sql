-- Permission-based tenant authorization. Apply as postgres in a transaction.
-- Role names are used only to seed mappings; policies and RPCs consult permissions.
create schema if not exists app_private;
revoke all on schema app_private from public, anon, authenticated;
grant usage on schema app_private to authenticated;
revoke create on schema public from public, anon, authenticated;

-- Identity and actor ownership are structural, in addition to API restrictions.
alter table public.user_profiles add constraint user_profiles_auth_user_fkey
  foreign key (user_id) references auth.users(id);
alter table public.user_profiles add constraint user_profiles_tenant_user_key unique (tenant_id, user_id);
alter table public.user_roles drop constraint user_roles_user_id_fkey;
alter table public.user_roles add constraint user_roles_user_id_fkey
  foreign key (tenant_id, user_id) references public.user_profiles(tenant_id, user_id);
alter table public.items add constraint items_tenant_fkey foreign key (tenant_id) references public.tenants;
alter table public.customers add constraint customers_tenant_fkey foreign key (tenant_id) references public.tenants;
alter table public.audit_logs add constraint audit_logs_tenant_fkey foreign key (tenant_id) references public.tenants;
alter table public.audit_logs add constraint audit_logs_actor_fkey
  foreign key (tenant_id, performed_by) references public.user_profiles(tenant_id, user_id);
alter table public.transits add constraint transits_purchase_fkey
  foreign key (tenant_id, purchase_id) references public.purchases(tenant_id, purchase_id);

do $constraints$
declare t text;
begin
  foreach t in array array['inventory_movements','sales','purchases','customer_transactions','employees','employee_payments']
  loop
    execute format('alter table public.%I drop constraint %I', t, t || '_created_by_fkey');
    execute format('alter table public.%I add constraint %I foreign key (tenant_id, created_by) references public.user_profiles(tenant_id, user_id)', t, t || '_created_by_fkey');
  end loop;
end $constraints$;

insert into public.permissions(permission_id, description) values
  ('dashboard:view', 'Read tenant dashboard totals and daily sales'),
  ('sales:view', 'Read tenant sales and receipt details'),
  ('receipts:print', 'Read saved receipts and printer configuration for printing'),
  ('printers:manage', 'Configure the tenant receipt printer'),
  ('employees:view', 'Read employee profiles, phones and payment counts'),
  ('employees:manage', 'Create, edit and deactivate employees'),
  ('payroll:view', 'Read employee payment history and categories'),
  ('payroll:pay', 'Record employee payments'),
  ('audit:view', 'Read tenant audit records')
on conflict (permission_id) do nothing;

update public.roles set name = upper(name) where upper(name) in ('OWNER','MANAGER','SALESMAN');
insert into public.role_permissions(tenant_id, role_id, permission_id)
select r.tenant_id, r.role_id, p.permission_id
from public.roles r cross join public.permissions p
where r.name in ('OWNER','MANAGER')
on conflict do nothing;
-- Replace the old Salesman mapping: POS never implies broad inventory/logistics management.
delete from public.role_permissions rp using public.roles r
where rp.tenant_id = r.tenant_id and rp.role_id = r.role_id and r.name = 'SALESMAN';
insert into public.role_permissions(tenant_id, role_id, permission_id)
select r.tenant_id, r.role_id, p.permission_id
from public.roles r cross join public.permissions p
where r.name = 'SALESMAN' and p.permission_id in ('dashboard:view','pos:sell','sales:view','receipts:print');

create function app_private.current_tenant_id()
returns uuid language sql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
  select p.tenant_id from public.user_profiles p
  join public.tenants t on t.tenant_id = p.tenant_id
  join auth.users u on u.id = p.user_id
  where p.user_id = auth.uid() and p.is_active is true and t.status = 'active'
    and u.is_anonymous is not true
$$;

create function app_private.has_any_permission(p_permissions text[])
returns boolean language sql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
  select exists (
    select 1 from public.user_roles ur
    join public.roles r on r.tenant_id = ur.tenant_id and r.role_id = ur.role_id
    join public.role_permissions rp on rp.tenant_id = r.tenant_id and rp.role_id = r.role_id
    join public.permissions p on p.permission_id = rp.permission_id
    where ur.user_id = auth.uid() and ur.tenant_id = app_private.current_tenant_id()
      and p.permission_id = any(p_permissions)
  )
$$;

create function app_private.has_permission(p_permission text)
returns boolean language sql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$ select app_private.has_any_permission(array[p_permission]) $$;

-- A permission gate also validates authentication, active membership and trusted tenancy.
create function app_private.require_any_permission(p_permissions text[])
returns uuid language plpgsql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare v_tenant uuid := app_private.current_tenant_id();
begin
  if v_tenant is null or not app_private.has_any_permission(p_permissions) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;
  return v_tenant;
end $$;

create function app_private.require_permission(p_permission text)
returns uuid language sql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$ select app_private.require_any_permission(array[p_permission]) $$;

-- Only the documented direct operations survive. Remove overlapping legacy policies.
do $policies$
declare p record;
begin
  for p in select tablename, policyname from pg_policies where schemaname = 'public'
  loop execute format('drop policy %I on public.%I', p.policyname, p.tablename); end loop;
end $policies$;
revoke all on all tables in schema public from public, anon, authenticated;
revoke all on all sequences in schema public from public, anon, authenticated;

grant select on public.tenants, public.user_profiles, public.items, public.lpg_brands,
  public.customers, public.price_books, public.sales, public.sale_items,
  public.inventory_movements, public.trucks, public.transits, public.wallets,
  public.customer_transactions, public.wallet_transactions, public.audit_logs,
  public.receipt_printers to authenticated;
-- Column grants prevent caller-chosen stock, timestamps and server-maintained fields.
grant insert (tenant_id, item_id, brand_id, brand, size_kg, cylinder_weight, mouth_size)
  on public.items to authenticated;
grant insert (tenant_id, customer_id, name, phone, shop_name, address, tier)
  on public.customers to authenticated;
grant insert (tenant_id, printer, paper_width_mm, printable_width_dots, auto_cut),
  update (printer, paper_width_mm, printable_width_dots, auto_cut)
  on public.receipt_printers to authenticated;

create policy tenant_read on public.tenants for select to authenticated
  using (tenant_id = (select app_private.current_tenant_id()));
create policy profile_read on public.user_profiles for select to authenticated
  using (tenant_id = (select app_private.current_tenant_id()) and
    (user_id = (select auth.uid()) or (select app_private.has_permission('inventory:view'))));
create policy items_read on public.items for select to authenticated
  using (tenant_id = (select app_private.current_tenant_id()) and
    (select app_private.has_any_permission(array['inventory:view','inventory:manage','pos:sell','purchases:view','purchases:manage','sales:view','receipts:print'])));

create policy lpg_brands_read on public.lpg_brands for select to authenticated
  using (tenant_id = (select app_private.current_tenant_id()) and
    (select app_private.has_any_permission(array['settings:manage','inventory:view','inventory:manage','pos:sell','purchases:view','purchases:manage','gas_plants:view','gas_plants:manage','sales:view','receipts:print'])));

create policy customers_read on public.customers for select to authenticated
  using (tenant_id = (select app_private.current_tenant_id()) and
    (select app_private.has_any_permission(array['customers:view','customers:manage','pos:sell','sales:view','receipts:print'])));

create policy price_books_read on public.price_books for select to authenticated
  using (tenant_id = (select app_private.current_tenant_id()) and
    (select app_private.has_any_permission(array['pos:sell'])));

create policy sales_read on public.sales for select to authenticated
  using (tenant_id = (select app_private.current_tenant_id()) and
    (select app_private.has_any_permission(array['sales:view','receipts:print','dashboard:view'])));

create policy sale_items_read on public.sale_items for select to authenticated
  using (tenant_id = (select app_private.current_tenant_id()) and
    (select app_private.has_any_permission(array['sales:view','receipts:print','dashboard:view'])));

create policy inventory_movements_read on public.inventory_movements for select to authenticated
  using (tenant_id = (select app_private.current_tenant_id()) and
    (select app_private.has_any_permission(array['inventory:view','inventory:manage'])));

create policy trucks_read on public.trucks for select to authenticated
  using (tenant_id = (select app_private.current_tenant_id()) and
    (select app_private.has_any_permission(array['logistics:view','logistics:manage','purchases:view','purchases:manage'])));

create policy transits_read on public.transits for select to authenticated
  using (tenant_id = (select app_private.current_tenant_id()) and
    (select app_private.has_any_permission(array['logistics:view','logistics:manage'])));

create policy wallets_read on public.wallets for select to authenticated
  using (tenant_id = (select app_private.current_tenant_id()) and
    (select app_private.has_any_permission(array['logistics:view','logistics:manage','finance:view','finance:manage'])));

create policy customer_transactions_read on public.customer_transactions for select to authenticated
  using (tenant_id = (select app_private.current_tenant_id()) and
    (select app_private.has_any_permission(array['finance:view','finance:manage'])));

create policy wallet_transactions_read on public.wallet_transactions for select to authenticated
  using (tenant_id = (select app_private.current_tenant_id()) and
    (select app_private.has_any_permission(array['finance:view','finance:manage'])));

create policy audit_logs_read on public.audit_logs for select to authenticated
  using (tenant_id = (select app_private.current_tenant_id()) and
    (select app_private.has_any_permission(array['audit:view'])));

create policy receipt_printers_read on public.receipt_printers for select to authenticated
  using (tenant_id = (select app_private.current_tenant_id()) and
    (select app_private.has_any_permission(array['receipts:print','printers:manage'])));
create policy items_register on public.items for insert to authenticated
  with check (tenant_id = (select app_private.current_tenant_id()) and
    (select app_private.has_permission('inventory:manage')) and
    filled_quantity = 0 and empty_quantity = 0);
create policy customers_create on public.customers for insert to authenticated
  with check (tenant_id = (select app_private.current_tenant_id()) and
    (select app_private.has_any_permission(array['customers:manage','pos:sell'])));
create policy receipt_printers_configure on public.receipt_printers for insert to authenticated
  with check (tenant_id = (select app_private.current_tenant_id()) and
    (select app_private.has_permission('printers:manage')));
create policy receipt_printers_reconfigure on public.receipt_printers for update to authenticated
  using (tenant_id = (select app_private.current_tenant_id()) and
    (select app_private.has_permission('printers:manage')))
  with check (tenant_id = (select app_private.current_tenant_id()) and
    (select app_private.has_permission('printers:manage')));

-- Internal routines live outside the PostgREST exposed schemas.
alter function public.ensure_tenant_wallets(uuid) set schema app_private;
alter function public.ensure_default_employee_payment_categories(uuid) set schema app_private;
alter function public.resolve_employee_type(uuid,text) set schema app_private;
alter function public.create_inventory_movement(uuid,text,integer,integer,text) set schema app_private;
alter function app_private.create_inventory_movement(uuid,text,integer,integer,text) rename to record_inventory_movement;
alter function public.audit_lpg_brands() set schema app_private;
alter function public.audit_trucks() set schema app_private;
alter function public.update_item_inventory() set schema app_private;
alter function public.employee_payment_immutable() set schema app_private;

-- These obsolete overloads are not used by current hooks. Keep only the current contracts.
drop function public.create_truck(character varying,character varying,integer,public.truck_size);
drop function public.update_truck(uuid,character varying,character varying,integer,public.truck_size,boolean);
drop function public.my_tenant_id();

CREATE OR REPLACE FUNCTION app_private.audit_lpg_brands()
 RETURNS trigger
 LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $function$
BEGIN
    INSERT INTO public.audit_logs (tenant_id, table_name, record_id, action, old_data, new_data, performed_by)
    VALUES (
        CASE WHEN TG_OP = 'DELETE' THEN OLD.tenant_id ELSE NEW.tenant_id END,
        'lpg_brands',
        CASE WHEN TG_OP = 'DELETE' THEN OLD.brand_id ELSE NEW.brand_id END,
        TG_OP,
        CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN row_to_json(OLD) ELSE NULL END,
        CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE row_to_json(NEW) END,
        auth.uid()
    );
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION app_private.audit_trucks()
 RETURNS trigger
 LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $function$
BEGIN
    INSERT INTO public.audit_logs (tenant_id, table_name, record_id, action, old_data, new_data, performed_by)
    VALUES (
        CASE WHEN TG_OP = 'DELETE' THEN OLD.tenant_id ELSE NEW.tenant_id END,
        'trucks',
        CASE WHEN TG_OP = 'DELETE' THEN OLD.truck_id ELSE NEW.truck_id END,
        TG_OP,
        CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN row_to_json(OLD) ELSE NULL END,
        CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE row_to_json(NEW) END,
        auth.uid()
    );
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.complete_purchase(p_purchase_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
    v_user_id      UUID := auth.uid();
    v_tenant_id    UUID;
    v_purchase     RECORD;
    v_wallet_id    UUID;
    v_item         RECORD;
BEGIN
    PERFORM app_private.require_any_permission(array['purchases:manage']);
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
    v_tenant_id := app_private.current_tenant_id();

    -- Get current purchase
    SELECT * INTO v_purchase FROM public.purchases WHERE tenant_id = v_tenant_id AND purchase_id = p_purchase_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Purchase not found'; END IF;

    IF v_purchase.status = 'received' THEN
        RAISE EXCEPTION 'Purchase is already completed';
    END IF;

    IF v_purchase.status = 'cancelled' THEN
        RAISE EXCEPTION 'Cannot complete a cancelled purchase';
    END IF;

    -- 1. Deduct total cost from Dealership Wallet
    IF v_purchase.total_cost > 0 THEN
        SELECT wallet_id INTO v_wallet_id FROM public.wallets WHERE tenant_id = v_tenant_id AND type = 'dealership' FOR UPDATE;
        
        INSERT INTO public.wallet_transactions (tenant_id, wallet_id, amount, type, reference_id, description)
        VALUES (v_tenant_id, v_wallet_id, -v_purchase.total_cost, 'purchase_expense', p_purchase_id, 'Payment for Purchase ' || p_purchase_id);

        UPDATE public.wallets SET balance = balance - v_purchase.total_cost, updated_at = NOW() WHERE tenant_id = v_tenant_id AND wallet_id = v_wallet_id;
    END IF;

    -- 2. Add filled items to inventory
    FOR v_item IN SELECT * FROM public.purchase_items WHERE tenant_id = v_tenant_id AND purchase_id = p_purchase_id
    LOOP
        -- Add filled_quantity
        PERFORM app_private.record_inventory_movement(
            v_item.item_id,
            'purchase',
            v_item.quantity, -- filled_quantity_change
            0,               -- empty_quantity_change
            'Received goods from Purchase ' || p_purchase_id
        );
    END LOOP;

    -- 3. Update status
    UPDATE public.purchases SET status = 'received', updated_at = NOW() WHERE tenant_id = v_tenant_id AND purchase_id = p_purchase_id;

    RETURN jsonb_build_object('purchase_id', p_purchase_id, 'status', 'received');
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_area_officer(p_plant_id uuid, p_officer_name text, p_whatsapp_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
    v_tenant_id UUID;
    v_officer_id UUID;
BEGIN
    PERFORM app_private.require_any_permission(array['gas_plants:manage']);
    v_tenant_id := app_private.current_tenant_id();
    IF v_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated or no tenant found';
    END IF;

    -- Verify the plant belongs to this tenant
    IF NOT EXISTS (
        SELECT 1 FROM public.gas_plants
        WHERE tenant_id = v_tenant_id AND plant_id = p_plant_id
    ) THEN
        RAISE EXCEPTION 'Gas plant not found';
    END IF;

    INSERT INTO public.area_officers (tenant_id, plant_id, officer_name, whatsapp_phone, email)
    VALUES (v_tenant_id, p_plant_id, p_officer_name, p_whatsapp_phone, p_email)
    RETURNING officer_id INTO v_officer_id;

    RETURN jsonb_build_object(
        'officer_id',   v_officer_id,
        'officer_name', p_officer_name
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_custom_transit(p_truck_id uuid, p_fee numeric, p_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
    v_user_id      UUID := auth.uid();
    v_tenant_id    UUID;
    v_transit_id   UUID;
    v_wallet_id    UUID;
BEGIN
    PERFORM app_private.require_any_permission(array['logistics:manage']);
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
    v_tenant_id := app_private.current_tenant_id();

    -- Ensure wallets exist
    PERFORM app_private.ensure_tenant_wallets(v_tenant_id);

    -- Create Transit
    INSERT INTO public.transits (tenant_id, truck_id, status, transport_fee)
    VALUES (v_tenant_id, p_truck_id, 'active', COALESCE(p_fee, 0))
    RETURNING transit_id INTO v_transit_id;
    
    -- Update truck status
    UPDATE public.trucks SET status = 'going' WHERE truck_id = p_truck_id AND tenant_id = v_tenant_id;

    -- Add fee to logistics wallet
    IF COALESCE(p_fee, 0) > 0 THEN
        SELECT wallet_id INTO v_wallet_id FROM public.wallets WHERE tenant_id = v_tenant_id AND type = 'logistics' FOR UPDATE;
        
        INSERT INTO public.wallet_transactions (tenant_id, wallet_id, amount, type, reference_id, description)
        VALUES (v_tenant_id, v_wallet_id, p_fee, 'transport_income', v_transit_id, 'Fee for custom transit');

        UPDATE public.wallets SET balance = balance + p_fee, updated_at = NOW() WHERE tenant_id = v_tenant_id AND wallet_id = v_wallet_id;
    END IF;

    RETURN jsonb_build_object('transit_id', v_transit_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_employee(p_name text, p_phones jsonb, p_address text, p_current_salary numeric, p_employee_type_name text, p_business_unit text, p_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
declare
  v_user_id uuid := auth.uid();
  v_tenant_id uuid;
  v_employee_id uuid;
  v_employee_type_id uuid;
  v_phone jsonb;
  v_phone_count integer := 0;
  v_primary_count integer := 0;
begin
    PERFORM app_private.require_any_permission(array['employees:manage']);
  if v_user_id is null then raise exception 'Not authenticated'; end if;
  v_tenant_id := app_private.current_tenant_id();
  if v_tenant_id is null then raise exception 'No tenant found for user'; end if;
  if nullif(trim(p_name), '') is null then raise exception 'Employee name is required'; end if;
  if p_business_unit not in ('gas_business', 'truck_business') then raise exception 'Invalid business unit'; end if;
  if jsonb_typeof(p_phones) <> 'array' or jsonb_array_length(p_phones) = 0 then
    raise exception 'At least one phone number is required';
  end if;

  v_employee_type_id := app_private.resolve_employee_type(v_tenant_id, p_employee_type_name);

  insert into public.employees (
    tenant_id, name, address, current_salary, employee_type_id, business_unit, notes, created_by
  ) values (
    v_tenant_id,
    trim(p_name),
    nullif(trim(p_address), ''),
    coalesce(p_current_salary, 0),
    v_employee_type_id,
    p_business_unit,
    nullif(trim(p_notes), ''),
    v_user_id
  ) returning employee_id into v_employee_id;

  for v_phone in select * from jsonb_array_elements(p_phones)
  loop
    v_phone_count := v_phone_count + 1;
    if coalesce((v_phone->>'is_primary')::boolean, false) then
      v_primary_count := v_primary_count + 1;
    end if;

    insert into public.employee_phone_numbers (tenant_id, employee_id, phone, is_primary)
    values (
      v_tenant_id,
      v_employee_id,
      trim(v_phone->>'phone'),
      coalesce((v_phone->>'is_primary')::boolean, false)
    );
  end loop;

  if v_phone_count = 0 or v_primary_count <> 1 then
    raise exception 'Exactly one primary phone number is required';
  end if;

  perform app_private.ensure_default_employee_payment_categories(v_tenant_id);

  return jsonb_build_object('employee_id', v_employee_id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.create_employee_payment(p_employee_id uuid, p_category_id uuid, p_amount numeric, p_payment_date date, p_description text, p_salary_year integer, p_salary_month integer, p_trip_count integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
declare
  v_user_id uuid := auth.uid();
  v_tenant_id uuid;
  v_category record;
  v_employee record;
  v_payment_id uuid;
begin
    PERFORM app_private.require_any_permission(array['payroll:pay']);
  if v_user_id is null then raise exception 'Not authenticated'; end if;
  v_tenant_id := app_private.current_tenant_id();
  if v_tenant_id is null then raise exception 'No tenant found for user'; end if;

  perform app_private.ensure_default_employee_payment_categories(v_tenant_id);

  select * into v_employee
  from public.employees
  where tenant_id = v_tenant_id and employee_id = p_employee_id and is_active = true;
  if v_employee.employee_id is null then raise exception 'Active employee not found'; end if;

  select * into v_category
  from public.employee_payment_categories
  where tenant_id = v_tenant_id and category_id = p_category_id and is_active = true;
  if v_category.category_id is null then raise exception 'Payment category not found'; end if;

  if coalesce(p_amount, 0) <= 0 then raise exception 'Payment amount must be greater than zero'; end if;
  if v_category.code = 'salary' and (p_salary_year is null or p_salary_month is null) then
    raise exception 'Salary month and year are required for salary payments';
  end if;
  if v_category.code <> 'salary' and (p_salary_year is not null or p_salary_month is not null) then
    raise exception 'Salary month and year can only be used for salary payments';
  end if;
  if v_category.code = 'trips' and coalesce(p_trip_count, 0) <= 0 then
    raise exception 'Trip count is required for trips payments';
  end if;
  if v_category.code <> 'trips' and p_trip_count is not null then
    raise exception 'Trip count can only be used for trips payments';
  end if;

  insert into public.employee_payments (
    tenant_id,
    employee_id,
    category_id,
    category_code,
    amount,
    payment_date,
    description,
    salary_year,
    salary_month,
    trip_count,
    created_by
  ) values (
    v_tenant_id,
    p_employee_id,
    p_category_id,
    v_category.code,
    p_amount,
    p_payment_date,
    nullif(trim(p_description), ''),
    p_salary_year,
    p_salary_month,
    p_trip_count,
    v_user_id
  ) returning payment_id into v_payment_id;

  return jsonb_build_object('payment_id', v_payment_id);
exception
  when unique_violation then
    raise exception 'Salary payment already exists for this employee and month';
end;
$function$;

CREATE OR REPLACE FUNCTION public.create_gas_plant(p_plant_name text, p_brand_id uuid DEFAULT NULL::uuid, p_location text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
    v_tenant_id UUID;
    v_plant_id  UUID;
BEGIN
    PERFORM app_private.require_any_permission(array['gas_plants:manage']);
    v_tenant_id := app_private.current_tenant_id();
    IF v_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated or no tenant found';
    END IF;

    INSERT INTO public.gas_plants (tenant_id, plant_name, brand_id, location)
    VALUES (v_tenant_id, p_plant_name, p_brand_id, p_location)
    RETURNING plant_id INTO v_plant_id;

    RETURN jsonb_build_object(
        'plant_id',   v_plant_id,
        'plant_name', p_plant_name
    );
END;
$function$;

CREATE OR REPLACE FUNCTION app_private.record_inventory_movement(p_item_id uuid, p_movement_type text, p_filled_quantity_change integer, p_empty_quantity_change integer, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
    v_user_id   UUID := auth.uid();
    v_tenant_id UUID;
    v_movement_id UUID;
BEGIN
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

    -- Derive tenant from user profile
    v_tenant_id := app_private.current_tenant_id();
    IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'No tenant found for user'; END IF;

    -- Serialize stock changes for this tenant/item, including calls from purchases.
    PERFORM 1 FROM public.items
    WHERE tenant_id = v_tenant_id AND item_id = p_item_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Item not found'; END IF;
    IF EXISTS (SELECT 1 FROM public.items WHERE tenant_id = v_tenant_id AND item_id = p_item_id
        AND (filled_quantity + p_filled_quantity_change < 0 OR empty_quantity + p_empty_quantity_change < 0)) THEN
        RAISE EXCEPTION 'Insufficient stock';
    END IF;
    IF p_filled_quantity_change IS NULL OR p_empty_quantity_change IS NULL THEN
        RAISE EXCEPTION 'Stock changes are required';
    END IF;

    INSERT INTO public.inventory_movements
        (tenant_id, item_id, movement_type, filled_quantity_change, empty_quantity_change, notes, created_by)
    VALUES
        (v_tenant_id, p_item_id, p_movement_type, p_filled_quantity_change, p_empty_quantity_change, p_notes, v_user_id)
    RETURNING movement_id INTO v_movement_id;

    RETURN jsonb_build_object('movement_id', v_movement_id, 'filled_quantity_change', p_filled_quantity_change, 'empty_quantity_change', p_empty_quantity_change);
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_lpg_brand(p_brand_name text, p_description text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
    v_tenant_id UUID;
    v_brand_id UUID;
BEGIN
    PERFORM app_private.require_any_permission(array['settings:manage']);
    v_tenant_id := app_private.current_tenant_id();
    IF v_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated or no tenant found';
    END IF;

    INSERT INTO public.lpg_brands (tenant_id, brand_name, description)
    VALUES (v_tenant_id, p_brand_name, p_description)
    RETURNING brand_id INTO v_brand_id;

    RETURN jsonb_build_object(
        'brand_id', v_brand_id,
        'brand_name', p_brand_name,
        'description', p_description
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_pos_sale(p_customer_phone character varying, p_customer_name character varying, p_customer_shop_name character varying, p_customer_address text, p_customer_tier character varying, p_discount_amount numeric, p_exchange_fee numeric, p_notes text, p_items jsonb, p_customer_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
    v_user_id        UUID := auth.uid();
    v_tenant_id      UUID;
    v_customer_id    UUID;
    v_customer_phone VARCHAR;
    v_customer_name  VARCHAR;
    v_existing_id    UUID;
    v_sale_id        UUID;
    v_item           JSONB;
    v_subtotal       NUMERIC(12,2) := 0.00;
    v_total_amount   NUMERIC(12,2);
    v_item_total     NUMERIC(12,2);
    v_total_refills  INT := 0;
    v_total_empties  INT := 0;
    v_filled_qty_change INT;
    v_empty_qty_change  INT;
    v_filled_stock      INT;
BEGIN
    PERFORM app_private.require_any_permission(array['pos:sell']);
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

    v_tenant_id := app_private.current_tenant_id();
    IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'No tenant found for user'; END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
        RAISE EXCEPTION 'Cart must be an array';
    END IF;
    IF COALESCE(p_discount_amount, 0) < 0 OR COALESCE(p_exchange_fee, 0) < 0 THEN
        RAISE EXCEPTION 'Discount and exchange fee cannot be negative';
    END IF;

    IF p_customer_phone IS NULL OR TRIM(p_customer_phone) = '' THEN
        RAISE EXCEPTION 'Customer phone number is required to complete a sale';
    END IF;

    IF p_customer_id IS NOT NULL THEN
        SELECT customer_id, phone, name
        INTO v_customer_id, v_customer_phone, v_customer_name
        FROM public.customers
        WHERE tenant_id = v_tenant_id
          AND customer_id = p_customer_id;

        IF v_customer_id IS NULL THEN
            RAISE EXCEPTION 'Selected customer was not found';
        END IF;
    ELSE
        SELECT customer_id INTO v_existing_id
        FROM public.customers
        WHERE tenant_id = v_tenant_id
          AND phone = TRIM(p_customer_phone);

        IF v_existing_id IS NOT NULL THEN
            RAISE EXCEPTION 'This phone number belongs to a saved customer. Select the saved customer before completing the sale.';
        END IF;

        INSERT INTO public.customers (tenant_id, name, phone, shop_name, address, tier)
        VALUES (
            v_tenant_id,
            COALESCE(NULLIF(TRIM(p_customer_name), ''), 'Unknown'),
            TRIM(p_customer_phone),
            NULLIF(TRIM(COALESCE(p_customer_shop_name, '')), ''),
            NULLIF(TRIM(COALESCE(p_customer_address, '')), ''),
            COALESCE(p_customer_tier, 'retail')
        )
        RETURNING customer_id, phone, name
        INTO v_customer_id, v_customer_phone, v_customer_name;
    END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        IF (v_item->>'type') = 'refill' THEN
            v_total_refills := v_total_refills + (v_item->>'quantity')::INT;
        ELSIF (v_item->>'type') = 'empty_return' THEN
            v_total_empties := v_total_empties + (v_item->>'quantity')::INT;
        END IF;
    END LOOP;

    IF v_total_refills != v_total_empties THEN
        RAISE EXCEPTION 'Refill count (%) must equal empty bottle return count (%)', v_total_refills, v_total_empties;
    END IF;

    IF jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'Cart cannot be empty';
    END IF;

    INSERT INTO public.sales (tenant_id, customer_id, status, discount_amount, exchange_fee, notes, created_by)
    VALUES (v_tenant_id, v_customer_id, 'completed',
            COALESCE(p_discount_amount, 0), COALESCE(p_exchange_fee, 0), p_notes, v_user_id)
    RETURNING sale_id INTO v_sale_id;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        IF v_item->>'type' IS NULL OR v_item->>'type' NOT IN ('refill','package','empty_return')
            OR (v_item->>'quantity')::INT IS NULL OR (v_item->>'quantity')::INT <= 0
            OR (v_item->>'unit_price')::NUMERIC IS NULL OR (v_item->>'unit_price')::NUMERIC < 0 THEN
            RAISE EXCEPTION 'Invalid sale line';
        END IF;
        SELECT filled_quantity INTO v_filled_stock FROM public.items
        WHERE tenant_id = v_tenant_id AND item_id = (v_item->>'item_id')::UUID FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Item not found'; END IF;
        v_item_total := (v_item->>'quantity')::INT * (v_item->>'unit_price')::NUMERIC;
        v_subtotal   := v_subtotal + v_item_total;

        v_filled_qty_change := 0;
        v_empty_qty_change  := 0;

        IF (v_item->>'type') = 'refill' THEN
            v_filled_qty_change := -((v_item->>'quantity')::INT);
        ELSIF (v_item->>'type') = 'package' THEN
            v_filled_qty_change := -((v_item->>'quantity')::INT);
            v_empty_qty_change  := -((v_item->>'quantity')::INT);
        ELSIF (v_item->>'type') = 'empty_return' THEN
            v_empty_qty_change := (v_item->>'quantity')::INT;
        END IF;

        IF v_filled_qty_change < 0 THEN
            SELECT filled_quantity INTO v_filled_stock
            FROM public.items
            WHERE tenant_id = v_tenant_id AND item_id = (v_item->>'item_id')::UUID;

            IF v_filled_stock < ABS(v_filled_qty_change) THEN
                RAISE EXCEPTION 'Insufficient filled stock for item %', (v_item->>'item_id');
            END IF;
        END IF;

        IF v_filled_qty_change != 0 OR v_empty_qty_change != 0 THEN
            INSERT INTO public.inventory_movements
                (tenant_id, item_id, movement_type, reference_type, reference_id,
                 filled_quantity_change, empty_quantity_change, notes, created_by)
            VALUES
                (v_tenant_id, (v_item->>'item_id')::UUID, 'sale', 'sale', v_sale_id,
                 v_filled_qty_change, v_empty_qty_change,
                 'POS Sale #' || LEFT(v_sale_id::TEXT, 8),
                 v_user_id);

            -- The movement trigger applies this stock delta exactly once.
        END IF;

        INSERT INTO public.sale_items (tenant_id, sale_id, item_id, type, quantity, unit_price, line_total)
        VALUES (
            v_tenant_id, v_sale_id,
            (v_item->>'item_id')::UUID,
            (v_item->>'type')::public.sale_item_type,
            (v_item->>'quantity')::INT,
            (v_item->>'unit_price')::NUMERIC,
            v_item_total
        );
    END LOOP;

    v_total_amount := v_subtotal - COALESCE(p_discount_amount, 0) + COALESCE(p_exchange_fee, 0);
    IF v_total_amount < 0 THEN RAISE EXCEPTION 'Sale total cannot be negative'; END IF;
    IF EXISTS (SELECT 1 FROM public.items i WHERE i.tenant_id = v_tenant_id
        AND i.item_id IN (SELECT (x->>'item_id')::UUID FROM jsonb_array_elements(p_items) x)
        AND (i.filled_quantity < 0 OR i.empty_quantity < 0)) THEN
        RAISE EXCEPTION 'Insufficient stock';
    END IF;
    UPDATE public.sales SET subtotal = v_subtotal, total_amount = v_total_amount WHERE tenant_id = v_tenant_id AND sale_id = v_sale_id;

    INSERT INTO public.customer_transactions (tenant_id, customer_id, type, amount, reference_id, created_by)
    VALUES
        (v_tenant_id, v_customer_id, 'invoice_charge',  -v_total_amount, v_sale_id, v_user_id),
        (v_tenant_id, v_customer_id, 'payment_receipt',  v_total_amount, v_sale_id, v_user_id);

    PERFORM app_private.ensure_tenant_wallets(v_tenant_id);
    UPDATE public.wallets SET balance = balance + v_total_amount, updated_at = NOW()
    WHERE tenant_id = v_tenant_id AND type = 'dealership';

    RETURN jsonb_build_object(
        'sale_id',        v_sale_id,
        'customer_id',    v_customer_id,
        'subtotal',       v_subtotal,
        'total_amount',   v_total_amount,
        'customer_phone', v_customer_phone,
        'customer_name',  COALESCE(NULLIF(TRIM(v_customer_name), ''), 'Unknown')
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_purchase(p_truck_id uuid, p_plant_id uuid, p_transport_cost numeric, p_labour_cost numeric, p_notes text, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
    v_user_id      UUID := auth.uid();
    v_tenant_id    UUID;
    v_purchase_id  UUID;
    v_transit_id   UUID;
    v_wallet_id    UUID;
    v_item         JSONB;
    v_total_cost   NUMERIC(12,2) := 0.00;
    v_empty_stock  INT;
    v_item_total   NUMERIC(12,2);
BEGIN
    PERFORM app_private.require_any_permission(array['purchases:manage']);
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

    -- Derive tenant from user profile
    v_tenant_id := app_private.current_tenant_id();
    IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'No tenant found for user'; END IF;

    -- Ensure wallets exist
    PERFORM app_private.ensure_tenant_wallets(v_tenant_id);

    -- 1. Create the purchase header
    INSERT INTO public.purchases (tenant_id, truck_id, plant_id, status, transport_cost, labour_cost, notes, created_by)
    VALUES (v_tenant_id, p_truck_id, p_plant_id, 'in_transit', COALESCE(p_transport_cost, 0), COALESCE(p_labour_cost, 0), p_notes, v_user_id)
    RETURNING purchase_id INTO v_purchase_id;

    v_total_cost := COALESCE(p_transport_cost, 0) + COALESCE(p_labour_cost, 0);

    -- 2. Process each line item
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        v_item_total := (v_item->>'quantity')::INT * (v_item->>'unit_price')::NUMERIC;
        v_total_cost := v_total_cost + v_item_total;

        -- If refill, check empty stock and deduct
        IF (v_item->>'type') = 'refill' THEN
            SELECT empty_quantity INTO v_empty_stock 
            FROM public.items 
            WHERE tenant_id = v_tenant_id AND item_id = (v_item->>'item_id')::UUID;

            IF v_empty_stock < (v_item->>'quantity')::INT THEN
                RAISE EXCEPTION 'Insufficient empty stock for item %', (v_item->>'item_id');
            END IF;

            -- Create inventory movement for empty deduction
            PERFORM app_private.record_inventory_movement(
                (v_item->>'item_id')::UUID,
                'purchase',
                0, -- filled_quantity_change (will be added when received)
                -((v_item->>'quantity')::INT), -- deduct empty
                'Empty bottles sent for refill (Purchase ' || v_purchase_id || ')'
            );
        END IF;

        -- Insert purchase item
        INSERT INTO public.purchase_items (tenant_id, purchase_id, item_id, type, quantity, unit_price, line_total)
        VALUES (v_tenant_id, v_purchase_id, (v_item->>'item_id')::UUID, (v_item->>'type')::public.purchase_type, (v_item->>'quantity')::INT, (v_item->>'unit_price')::NUMERIC, v_item_total);

    END LOOP;

    -- 3. Update purchase total cost
    UPDATE public.purchases SET total_cost = v_total_cost WHERE tenant_id = v_tenant_id AND purchase_id = v_purchase_id;

    -- 4. Update truck status to 'going'
    UPDATE public.trucks SET status = 'going' WHERE truck_id = p_truck_id AND tenant_id = v_tenant_id;

    -- 5. Create Transit
    INSERT INTO public.transits (tenant_id, truck_id, purchase_id, status)
    VALUES (v_tenant_id, p_truck_id, v_purchase_id, 'active')
    RETURNING transit_id INTO v_transit_id;

    -- 6. Credit transport cost to Logistics Wallet
    IF COALESCE(p_transport_cost, 0) > 0 THEN
        SELECT wallet_id INTO v_wallet_id FROM public.wallets WHERE tenant_id = v_tenant_id AND type = 'logistics' FOR UPDATE;
        
        INSERT INTO public.wallet_transactions (tenant_id, wallet_id, amount, type, reference_id, description)
        VALUES (v_tenant_id, v_wallet_id, p_transport_cost, 'transport_income', v_purchase_id, 'Transport fee for Purchase ' || v_purchase_id);

        UPDATE public.wallets SET balance = balance + p_transport_cost, updated_at = NOW() WHERE tenant_id = v_tenant_id AND wallet_id = v_wallet_id;
    END IF;

    -- Dealership wallet expense could be recorded here, but for now we only process the logistics transport_fee

    RETURN jsonb_build_object(
        'purchase_id', v_purchase_id,
        'transit_id', v_transit_id,
        'total_cost', v_total_cost
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_truck(p_name character varying, p_serial_no character varying, p_capacity integer, p_size public.truck_size, p_location character varying DEFAULT NULL::character varying)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
    v_tenant_id UUID;
    v_truck_id UUID;
BEGIN
    PERFORM app_private.require_any_permission(array['logistics:manage']);
    v_tenant_id := app_private.current_tenant_id();
    IF v_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated or no tenant found';
    END IF;

    INSERT INTO public.trucks (tenant_id, name, serial_no, capacity, size, status, location)
    VALUES (v_tenant_id, p_name, p_serial_no, p_capacity, p_size, 'idle', p_location)
    RETURNING truck_id INTO v_truck_id;

    RETURN jsonb_build_object(
        'truck_id', v_truck_id,
        'name', p_name,
        'serial_no', p_serial_no,
        'capacity', p_capacity,
        'size', p_size,
        'status', 'idle',
        'location', p_location
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.deactivate_employee(p_employee_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
declare
  v_user_id uuid := auth.uid();
  v_tenant_id uuid;
begin
    PERFORM app_private.require_any_permission(array['employees:manage']);
  if v_user_id is null then raise exception 'Not authenticated'; end if;
  v_tenant_id := app_private.current_tenant_id();
  if v_tenant_id is null then raise exception 'No tenant found for user'; end if;

  if exists (
    select 1 from public.employee_payments
    where tenant_id = v_tenant_id and employee_id = p_employee_id
  ) then
    update public.employees
    set is_active = false,
        updated_at = now()
    where tenant_id = v_tenant_id and employee_id = p_employee_id;
  else
    delete from public.employees
    where tenant_id = v_tenant_id and employee_id = p_employee_id;
  end if;

  return jsonb_build_object('employee_id', p_employee_id);
end;
$function$;

CREATE OR REPLACE FUNCTION app_private.employee_payment_immutable()
 RETURNS trigger
 LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $function$
begin
  raise exception 'Employee payment records are immutable';
end;
$function$;

CREATE OR REPLACE FUNCTION app_private.ensure_default_employee_payment_categories(p_tenant_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
begin
  if p_tenant_id is distinct from app_private.current_tenant_id() then
    raise exception 'Invalid tenant' using errcode = '42501';
  end if;
  if p_tenant_id is null then
    raise exception 'Tenant is required';
  end if;

  insert into public.employee_payment_categories (tenant_id, code, name, category_kind)
  values
    (p_tenant_id, 'salary', 'Monthly Salary', 'salary'),
    (p_tenant_id, 'bonus', 'Bonus', 'bonus'),
    (p_tenant_id, 'commission', 'Commission', 'commission'),
    (p_tenant_id, 'trips', 'Trips', 'trips'),
    (p_tenant_id, 'other', 'Other Payment', 'other')
  on conflict (tenant_id, code) do update
  set name = excluded.name,
      category_kind = excluded.category_kind,
      is_active = true;
end;
$function$;

CREATE OR REPLACE FUNCTION app_private.ensure_tenant_wallets(p_tenant_id uuid)
 RETURNS void
 LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $function$
BEGIN
  if p_tenant_id is distinct from app_private.current_tenant_id() then
    raise exception 'Invalid tenant' using errcode = '42501';
  end if;
    INSERT INTO public.wallets (tenant_id, type, balance)
    VALUES (p_tenant_id, 'dealership', 0.00)
    ON CONFLICT (tenant_id, type) DO NOTHING;

    INSERT INTO public.wallets (tenant_id, type, balance)
    VALUES (p_tenant_id, 'logistics', 0.00)
    ON CONFLICT (tenant_id, type) DO NOTHING;
END;
$function$;

CREATE OR REPLACE FUNCTION public.list_employee_payment_categories()
 RETURNS TABLE(category_id uuid, code character varying, name character varying, category_kind character varying, is_active boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
declare
  v_tenant_id uuid;
begin
    PERFORM app_private.require_any_permission(array['payroll:view','payroll:pay']);
  v_tenant_id := app_private.current_tenant_id();
  if v_tenant_id is null then
    raise exception 'No tenant found for user';
  end if;

  perform app_private.ensure_default_employee_payment_categories(v_tenant_id);

  return query
    select c.category_id, c.code, c.name, c.category_kind, c.is_active
    from public.employee_payment_categories c
    where c.tenant_id = v_tenant_id
    order by
      case c.code
        when 'salary' then 1
        when 'bonus' then 2
        when 'commission' then 3
        when 'trips' then 4
        else 5
      end,
      c.name;
end;
$function$;

CREATE OR REPLACE FUNCTION public.list_employee_payments(p_employee_id uuid)
 RETURNS TABLE(payment_id uuid, employee_id uuid, employee_name character varying, category_id uuid, category_code character varying, category_name character varying, category_kind character varying, amount numeric, payment_date date, description text, salary_year integer, salary_month integer, trip_count integer, created_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
BEGIN
  PERFORM app_private.require_any_permission(array['payroll:view','payroll:pay']);
  RETURN QUERY select
    p.payment_id,
    p.employee_id,
    e.name as employee_name,
    p.category_id,
    p.category_code,
    c.name as category_name,
    c.category_kind,
    p.amount,
    p.payment_date,
    p.description,
    p.salary_year,
    p.salary_month,
    p.trip_count,
    p.created_at
  from public.employee_payments p
  join public.employees e
    on e.tenant_id = p.tenant_id and e.employee_id = p.employee_id
  join public.employee_payment_categories c
    on c.tenant_id = p.tenant_id and c.category_id = p.category_id
  where p.tenant_id = app_private.current_tenant_id()
    and p.employee_id = p_employee_id
  order by p.payment_date desc, p.created_at desc;
END;
$function$;

CREATE OR REPLACE FUNCTION public.list_employees()
 RETURNS TABLE(employee_id uuid, name character varying, address text, current_salary numeric, business_unit character varying, notes text, is_active boolean, created_at timestamp with time zone, updated_at timestamp with time zone, employee_type_id uuid, employee_type_name character varying, phones jsonb, primary_phone character varying, payment_count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
BEGIN
  PERFORM app_private.require_any_permission(array['employees:view','employees:manage']);
  RETURN QUERY select
    e.employee_id,
    e.name,
    e.address,
    e.current_salary,
    e.business_unit,
    e.notes,
    e.is_active,
    e.created_at,
    e.updated_at,
    e.employee_type_id,
    et.name as employee_type_name,
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'employee_phone_id', ep.employee_phone_id,
          'phone', ep.phone,
          'is_primary', ep.is_primary
        )
        order by ep.is_primary desc, ep.created_at asc
      ) filter (where ep.employee_phone_id is not null),
      '[]'::jsonb
    ) as phones,
    (max(ep.phone) filter (where ep.is_primary))::varchar as primary_phone,
    count(distinct pay.payment_id) as payment_count
  from public.employees e
  left join public.employee_types et
    on et.tenant_id = e.tenant_id and et.employee_type_id = e.employee_type_id
  left join public.employee_phone_numbers ep
    on ep.tenant_id = e.tenant_id and ep.employee_id = e.employee_id
  left join public.employee_payments pay
    on pay.tenant_id = e.tenant_id and pay.employee_id = e.employee_id
  where e.tenant_id = app_private.current_tenant_id()
  group by e.employee_id, e.name, e.address, e.current_salary, e.business_unit,
    e.notes, e.is_active, e.created_at, e.updated_at, e.employee_type_id, et.name
  order by e.is_active desc, e.name asc;
END;
$function$;

CREATE OR REPLACE FUNCTION public.list_gas_plants(p_active_only boolean DEFAULT false)
 RETURNS TABLE(plant_id uuid, plant_name character varying, brand_id uuid, brand_name character varying, location text, is_active boolean, created_at timestamp with time zone, updated_at timestamp with time zone, officer_id uuid, officer_name character varying, whatsapp_phone character varying, email character varying)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
BEGIN
    PERFORM app_private.require_any_permission(array['gas_plants:view','gas_plants:manage','purchases:view','purchases:manage']);
    RETURN QUERY
    SELECT
        gp.plant_id,
        gp.plant_name,
        gp.brand_id,
        lb.brand_name,
        gp.location,
        gp.is_active,
        gp.created_at,
        gp.updated_at,
        ao.officer_id,
        ao.officer_name,
        ao.whatsapp_phone,
        ao.email
    FROM public.gas_plants gp
    LEFT JOIN public.lpg_brands lb
        ON lb.tenant_id = gp.tenant_id AND lb.brand_id = gp.brand_id
    LEFT JOIN public.area_officers ao
        ON ao.tenant_id = gp.tenant_id AND ao.plant_id = gp.plant_id
    WHERE gp.tenant_id = app_private.current_tenant_id()
      AND (NOT p_active_only OR gp.is_active = true)
    ORDER BY gp.created_at DESC;
END;
$function$;

CREATE OR REPLACE FUNCTION public.list_lpg_brands(p_active_only boolean DEFAULT true)
 RETURNS TABLE(brand_id uuid, brand_name character varying, description text, is_active boolean, created_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
BEGIN
    PERFORM app_private.require_any_permission(array['settings:manage','inventory:view','inventory:manage','pos:sell','purchases:view','purchases:manage','gas_plants:view','gas_plants:manage']);
    RETURN QUERY
    SELECT
        b.brand_id,
        b.brand_name,
        b.description,
        b.is_active,
        b.created_at
    FROM public.lpg_brands b
    WHERE b.tenant_id = app_private.current_tenant_id()
      AND (NOT p_active_only OR b.is_active = true)
    ORDER BY b.created_at DESC;
END;
$function$;

CREATE OR REPLACE FUNCTION public.list_purchases()
 RETURNS TABLE(purchase_id uuid, truck_id uuid, truck_name character varying, plant_id uuid, plant_name character varying, status public.purchase_status, transport_cost numeric, labour_cost numeric, total_cost numeric, notes text, created_at timestamp with time zone, items jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
BEGIN
    PERFORM app_private.require_any_permission(array['purchases:view','purchases:manage']);
    RETURN QUERY
    SELECT
        p.purchase_id,
        p.truck_id,
        t.name AS truck_name,
        p.plant_id,
        gp.plant_name,
        p.status,
        p.transport_cost,
        p.labour_cost,
        p.total_cost,
        p.notes,
        p.created_at,
        (
            SELECT jsonb_agg(jsonb_build_object(
                'purchase_item_id', pi.purchase_item_id,
                'item_id', pi.item_id,
                'brand_name', b.brand_name,
                'size_kg', i.size_kg,
                'type', pi.type,
                'quantity', pi.quantity,
                'unit_price', pi.unit_price,
                'line_total', pi.line_total
            ))
            FROM public.purchase_items pi
            JOIN public.items i ON pi.tenant_id = i.tenant_id AND pi.item_id = i.item_id
            LEFT JOIN public.lpg_brands b ON i.tenant_id = b.tenant_id AND i.brand_id = b.brand_id
            WHERE pi.tenant_id = p.tenant_id AND pi.purchase_id = p.purchase_id
        ) AS items
    FROM public.purchases p
    LEFT JOIN public.trucks t ON p.tenant_id = t.tenant_id AND p.truck_id = t.truck_id
    LEFT JOIN public.gas_plants gp ON p.tenant_id = gp.tenant_id AND p.plant_id = gp.plant_id
    WHERE p.tenant_id = app_private.current_tenant_id()
    ORDER BY p.created_at DESC;
END;
$function$;

CREATE OR REPLACE FUNCTION public.list_trucks(p_active_only boolean DEFAULT true)
 RETURNS TABLE(truck_id uuid, name character varying, serial_no character varying, capacity integer, size public.truck_size, status public.truck_status, location character varying, created_at timestamp with time zone, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
BEGIN
    PERFORM app_private.require_any_permission(array['logistics:view','logistics:manage','purchases:view','purchases:manage']);
    RETURN QUERY
    SELECT
        t.truck_id,
        t.name,
        t.serial_no,
        t.capacity,
        t.size,
        t.status,
        t.location,
        t.created_at,
        t.updated_at
    FROM public.trucks t
    WHERE t.tenant_id = app_private.current_tenant_id()
    ORDER BY t.created_at DESC;
END;
$function$;

CREATE OR REPLACE FUNCTION app_private.resolve_employee_type(p_tenant_id uuid, p_employee_type_name text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
declare
  v_employee_type_id uuid;
  v_name text := nullif(trim(p_employee_type_name), '');
begin
  if p_tenant_id is distinct from app_private.current_tenant_id() then
    raise exception 'Invalid tenant' using errcode = '42501';
  end if;
  if v_name is null then
    return null;
  end if;

  insert into public.employee_types (tenant_id, name)
  values (p_tenant_id, v_name)
  on conflict (tenant_id, name) do update
  set is_active = true
  returning employee_type_id into v_employee_type_id;

  return v_employee_type_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.setup_business(p_business_name text, p_owner_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
    v_user_id    UUID := auth.uid();
    v_user_email TEXT;
    v_tenant_id  UUID;
    v_owner_role UUID;
    v_mgr_role   UUID;
    v_sales_role UUID;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    -- Lock the identity so concurrent setup cannot create a second membership.
    SELECT email INTO v_user_email FROM auth.users
    WHERE id = v_user_id AND is_anonymous IS NOT TRUE FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501'; END IF;
    IF EXISTS (SELECT 1 FROM public.user_profiles WHERE user_id = v_user_id) THEN
        RAISE EXCEPTION 'Business membership already exists' USING ERRCODE = '42501';
    END IF;
    IF NULLIF(TRIM(p_business_name), '') IS NULL OR NULLIF(TRIM(p_owner_name), '') IS NULL THEN
        RAISE EXCEPTION 'Business and owner names are required';
    END IF;

    -- 1. Create the Tenant
    INSERT INTO public.tenants (business_name, status)
    VALUES (p_business_name, 'active')
    RETURNING tenant_id INTO v_tenant_id;

    -- 2. Create User Profile
    INSERT INTO public.user_profiles (user_id, tenant_id, full_name, email)
    VALUES (v_user_id, v_tenant_id, p_owner_name, v_user_email);

    -- 3. Create default roles: Owner, Manager, Salesman
    INSERT INTO public.roles (tenant_id, name) VALUES (v_tenant_id, 'OWNER')   RETURNING role_id INTO v_owner_role;
    INSERT INTO public.roles (tenant_id, name) VALUES (v_tenant_id, 'MANAGER') RETURNING role_id INTO v_mgr_role;
    INSERT INTO public.roles (tenant_id, name) VALUES (v_tenant_id, 'SALESMAN') RETURNING role_id INTO v_sales_role;

    -- 4. Owner gets ALL permissions
    INSERT INTO public.role_permissions (tenant_id, role_id, permission_id)
    SELECT v_tenant_id, v_owner_role, permission_id FROM public.permissions;

    -- 5. Manager currently gets the same complete tenant permission set
    INSERT INTO public.role_permissions (tenant_id, role_id, permission_id)
    SELECT v_tenant_id, v_mgr_role, permission_id
    FROM public.permissions
    ;

    -- 6. Salesman gets only Dashboard, POS and receipt capabilities
    INSERT INTO public.role_permissions (tenant_id, role_id, permission_id)
    SELECT v_tenant_id, v_sales_role, permission_id
    FROM public.permissions
    WHERE permission_id IN ('dashboard:view','pos:sell','sales:view','receipts:print');

    -- 7. Assign Owner role to registering user
    INSERT INTO public.user_roles (tenant_id, user_id, role_id)
    VALUES (v_tenant_id, v_user_id, v_owner_role);

    -- 8. Display metadata only; authorization never trusts user metadata
    UPDATE auth.users
    SET raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object(
        'full_name', p_owner_name,
        'tenant_id', v_tenant_id::text
    )
    WHERE id = v_user_id;

    RETURN jsonb_build_object(
        'tenant_id', v_tenant_id,
        'user_id',   v_user_id,
        'role',      'OWNER'
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_area_officer(p_officer_id uuid, p_officer_name text DEFAULT NULL::text, p_whatsapp_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
    v_tenant_id UUID;
BEGIN
    PERFORM app_private.require_any_permission(array['gas_plants:manage']);
    v_tenant_id := app_private.current_tenant_id();
    IF v_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated or no tenant found';
    END IF;

    UPDATE public.area_officers
    SET
        officer_name   = COALESCE(p_officer_name,   officer_name),
        whatsapp_phone = COALESCE(p_whatsapp_phone, whatsapp_phone),
        email          = COALESCE(p_email,           email),
        updated_at     = NOW()
    WHERE tenant_id = v_tenant_id AND officer_id = p_officer_id;

    RETURN jsonb_build_object(
        'officer_id', p_officer_id,
        'message',    'Area officer updated successfully'
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_employee(p_employee_id uuid, p_name text, p_phones jsonb, p_address text, p_current_salary numeric, p_employee_type_name text, p_business_unit text, p_notes text, p_is_active boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
declare
  v_user_id uuid := auth.uid();
  v_tenant_id uuid;
  v_employee_type_id uuid;
  v_phone jsonb;
  v_phone_count integer := 0;
  v_primary_count integer := 0;
begin
    PERFORM app_private.require_any_permission(array['employees:manage']);
  if v_user_id is null then raise exception 'Not authenticated'; end if;
  v_tenant_id := app_private.current_tenant_id();
  if v_tenant_id is null then raise exception 'No tenant found for user'; end if;
  if nullif(trim(p_name), '') is null then raise exception 'Employee name is required'; end if;
  if p_business_unit not in ('gas_business', 'truck_business') then raise exception 'Invalid business unit'; end if;
  if jsonb_typeof(p_phones) <> 'array' or jsonb_array_length(p_phones) = 0 then
    raise exception 'At least one phone number is required';
  end if;

  if not exists (
    select 1 from public.employees
    where tenant_id = v_tenant_id and employee_id = p_employee_id
  ) then
    raise exception 'Employee not found';
  end if;

  v_employee_type_id := app_private.resolve_employee_type(v_tenant_id, p_employee_type_name);

  update public.employees
  set name = trim(p_name),
      address = nullif(trim(p_address), ''),
      current_salary = coalesce(p_current_salary, 0),
      employee_type_id = v_employee_type_id,
      business_unit = p_business_unit,
      notes = nullif(trim(p_notes), ''),
      is_active = coalesce(p_is_active, true),
      updated_at = now()
  where tenant_id = v_tenant_id and employee_id = p_employee_id;

  delete from public.employee_phone_numbers
  where tenant_id = v_tenant_id and employee_id = p_employee_id;

  for v_phone in select * from jsonb_array_elements(p_phones)
  loop
    v_phone_count := v_phone_count + 1;
    if coalesce((v_phone->>'is_primary')::boolean, false) then
      v_primary_count := v_primary_count + 1;
    end if;

    insert into public.employee_phone_numbers (tenant_id, employee_id, phone, is_primary)
    values (
      v_tenant_id,
      p_employee_id,
      trim(v_phone->>'phone'),
      coalesce((v_phone->>'is_primary')::boolean, false)
    );
  end loop;

  if v_phone_count = 0 or v_primary_count <> 1 then
    raise exception 'Exactly one primary phone number is required';
  end if;

  return jsonb_build_object('employee_id', p_employee_id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.update_gas_plant(p_plant_id uuid, p_plant_name text DEFAULT NULL::text, p_brand_id uuid DEFAULT NULL::uuid, p_location text DEFAULT NULL::text, p_is_active boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
    v_tenant_id UUID;
BEGIN
    PERFORM app_private.require_any_permission(array['gas_plants:manage']);
    v_tenant_id := app_private.current_tenant_id();
    IF v_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated or no tenant found';
    END IF;

    UPDATE public.gas_plants
    SET
        plant_name = COALESCE(p_plant_name, plant_name),
        brand_id   = COALESCE(p_brand_id,   brand_id),
        location   = COALESCE(p_location,   location),
        is_active  = COALESCE(p_is_active,  is_active),
        updated_at = NOW()
    WHERE tenant_id = v_tenant_id AND plant_id = p_plant_id;

    RETURN jsonb_build_object(
        'plant_id', p_plant_id,
        'message',  'Gas plant updated successfully'
    );
END;
$function$;

CREATE OR REPLACE FUNCTION app_private.update_item_inventory()
 RETURNS trigger
 LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $function$
BEGIN
    UPDATE public.items
    SET 
        filled_quantity = filled_quantity + NEW.filled_quantity_change,
        empty_quantity = empty_quantity + NEW.empty_quantity_change,
        updated_at = NOW()
    WHERE tenant_id = NEW.tenant_id AND item_id = NEW.item_id;
    
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_lpg_brand(p_brand_id uuid, p_brand_name text DEFAULT NULL::text, p_description text DEFAULT NULL::text, p_is_active boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
    v_tenant_id UUID;
BEGIN
    PERFORM app_private.require_any_permission(array['settings:manage']);
    v_tenant_id := app_private.current_tenant_id();
    IF v_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated or no tenant found';
    END IF;

    UPDATE public.lpg_brands
    SET
        brand_name = COALESCE(p_brand_name, brand_name),
        description = COALESCE(p_description, description),
        is_active = COALESCE(p_is_active, is_active),
        updated_at = NOW()
    WHERE tenant_id = v_tenant_id AND brand_id = p_brand_id;

    RETURN jsonb_build_object(
        'brand_id', p_brand_id,
        'message', 'Brand updated successfully'
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_purchase(p_purchase_id uuid, p_transport_cost numeric, p_labour_cost numeric, p_notes text, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
    v_user_id        UUID := auth.uid();
    v_tenant_id      UUID;
    v_purchase       RECORD;
    v_item           JSONB;
    v_item_total     NUMERIC(12,2);
    v_total_cost     NUMERIC(12,2) := 0.00;
    v_transport_diff NUMERIC(12,2);
    v_wallet_id      UUID;
    
    v_old_qty        INT;
    v_new_qty        INT;
    v_qty_diff       INT;
BEGIN
    PERFORM app_private.require_any_permission(array['purchases:manage']);
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
    v_tenant_id := app_private.current_tenant_id();

    -- Get current purchase
    SELECT * INTO v_purchase FROM public.purchases WHERE tenant_id = v_tenant_id AND purchase_id = p_purchase_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Purchase not found'; END IF;

    IF v_purchase.status <> 'in_transit' THEN
        RAISE EXCEPTION 'Purchase is no longer in transit and cannot be modified';
    END IF;

    -- Calculate transport cost difference
    v_transport_diff := COALESCE(p_transport_cost, 0) - COALESCE(v_purchase.transport_cost, 0);

    -- Base cost
    v_total_cost := COALESCE(p_transport_cost, 0) + COALESCE(p_labour_cost, 0);

    -- Update item prices/quantities and calculate new totals
    IF p_items IS NOT NULL THEN
        FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
        LOOP
            v_new_qty := (v_item->>'quantity')::INT;
            
            -- Get old quantity
            SELECT quantity INTO v_old_qty 
            FROM public.purchase_items 
            WHERE tenant_id = v_tenant_id 
              AND purchase_id = p_purchase_id 
              AND item_id = (v_item->>'item_id')::UUID;
              
            IF FOUND THEN
                v_qty_diff := v_new_qty - v_old_qty;
                
                -- Update unit_price, quantity and line_total
                UPDATE public.purchase_items 
                SET unit_price = (v_item->>'unit_price')::NUMERIC,
                    quantity = v_new_qty,
                    line_total = v_new_qty * (v_item->>'unit_price')::NUMERIC
                WHERE tenant_id = v_tenant_id 
                  AND purchase_id = p_purchase_id 
                  AND item_id = (v_item->>'item_id')::UUID
                RETURNING line_total INTO v_item_total;

                v_total_cost := v_total_cost + v_item_total;
                
                -- If quantity changed, adjust empty bottles in inventory
                IF v_qty_diff <> 0 THEN
                    -- We sent empty bottles. If qty increases, we send MORE empty bottles (negative change).
                    -- If qty decreases, we send FEWER empty bottles (positive change / refund).
                    PERFORM app_private.record_inventory_movement(
                        (v_item->>'item_id')::UUID,
                        'purchase_adjustment',
                        0, -- filled_quantity_change
                        -v_qty_diff, -- empty_quantity_change
                        'Quantity adjustment for Purchase ' || p_purchase_id
                    );
                END IF;
            END IF;
        END LOOP;
    END IF;

    -- Now add remaining item totals that were NOT updated (just in case they didn't send all items)
    -- Actually, since we process all items, we can just use v_total_cost as is.
    -- But to be safe, let's just re-sum everything from public.purchase_items
    SELECT COALESCE(SUM(line_total), 0) INTO v_item_total
    FROM public.purchase_items
    WHERE tenant_id = v_tenant_id AND purchase_id = p_purchase_id;

    v_total_cost := COALESCE(p_transport_cost, 0) + COALESCE(p_labour_cost, 0) + v_item_total;

    -- Update purchase header
    UPDATE public.purchases 
    SET transport_cost = p_transport_cost,
        labour_cost = p_labour_cost,
        total_cost = v_total_cost,
        notes = p_notes,
        updated_at = NOW()
    WHERE tenant_id = v_tenant_id AND purchase_id = p_purchase_id;

    -- Adjust Logistics Wallet for transport cost change
    IF v_transport_diff <> 0 THEN
        SELECT wallet_id INTO v_wallet_id FROM public.wallets WHERE tenant_id = v_tenant_id AND type = 'logistics' FOR UPDATE;
        
        IF FOUND THEN
            INSERT INTO public.wallet_transactions (tenant_id, wallet_id, amount, type, reference_id, description)
            VALUES (v_tenant_id, v_wallet_id, v_transport_diff, 'transport_income_adj', p_purchase_id, 'Transport fee adjustment for Purchase ' || p_purchase_id);

            UPDATE public.wallets SET balance = balance + v_transport_diff, updated_at = NOW() WHERE tenant_id = v_tenant_id AND wallet_id = v_wallet_id;
        END IF;
    END IF;

    RETURN jsonb_build_object('purchase_id', p_purchase_id, 'total_cost', v_total_cost);
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_transit_costs(p_transit_id uuid, p_driver_cost numeric, p_helper_cost numeric, p_oil_cost numeric, p_additional_costs jsonb, p_status public.transit_status)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
    v_user_id      UUID := auth.uid();
    v_tenant_id    UUID;
    v_transit      RECORD;
    v_wallet_id    UUID;
    
    v_new_total    NUMERIC(12,2) := 0;
    
    v_add_item     JSONB;
BEGIN
    PERFORM app_private.require_any_permission(array['logistics:manage']);
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
    v_tenant_id := app_private.current_tenant_id();
    IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'No tenant found for user'; END IF;

    -- Get current transit
    SELECT * INTO v_transit FROM public.transits WHERE tenant_id = v_tenant_id AND transit_id = p_transit_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Transit not found'; END IF;

    -- Check if already completed
    IF v_transit.status = 'completed' THEN
        RAISE EXCEPTION 'Transit is already completed and locked. Costs cannot be updated.';
    END IF;

    -- Calculate new total cost
    v_new_total := COALESCE(p_driver_cost, 0) + COALESCE(p_helper_cost, 0) + COALESCE(p_oil_cost, 0);
    
    IF p_additional_costs IS NOT NULL THEN
        FOR v_add_item IN SELECT * FROM jsonb_array_elements(p_additional_costs)
        LOOP
            v_new_total := v_new_total + COALESCE((v_add_item->>'amount')::NUMERIC, 0);
        END LOOP;
    ELSE
        p_additional_costs := '[]'::jsonb;
    END IF;

    -- Update Transit record
    UPDATE public.transits 
    SET 
        driver_cost = p_driver_cost,
        helper_cost = p_helper_cost,
        oil_cost = p_oil_cost,
        additional_costs = p_additional_costs,
        total_cost = v_new_total,
        status = p_status,
        updated_at = NOW()
    WHERE tenant_id = v_tenant_id AND transit_id = p_transit_id;

    -- IF transitioning to completed, deduct costs from logistics wallet
    IF p_status = 'completed' AND v_new_total > 0 THEN
        SELECT wallet_id INTO v_wallet_id FROM public.wallets WHERE tenant_id = v_tenant_id AND type = 'logistics' FOR UPDATE;
        
        -- Negative amount for expense
        INSERT INTO public.wallet_transactions (tenant_id, wallet_id, amount, type, reference_id, description)
        VALUES (v_tenant_id, v_wallet_id, -v_new_total, 'transit_cost', p_transit_id, 'Transit costs deduction upon completion');

        UPDATE public.wallets SET balance = balance - v_new_total, updated_at = NOW() WHERE tenant_id = v_tenant_id AND wallet_id = v_wallet_id;
    END IF;
    
    -- If marked as completed, free the truck.
    IF p_status = 'completed' THEN
        UPDATE public.trucks SET status = 'idle' WHERE truck_id = v_transit.truck_id AND tenant_id = v_tenant_id;
    END IF;

    RETURN jsonb_build_object('transit_id', p_transit_id, 'total_cost', v_new_total);
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_truck(p_truck_id uuid, p_name character varying DEFAULT NULL::character varying, p_serial_no character varying DEFAULT NULL::character varying, p_capacity integer DEFAULT NULL::integer, p_size public.truck_size DEFAULT NULL::public.truck_size, p_status public.truck_status DEFAULT NULL::public.truck_status, p_location character varying DEFAULT NULL::character varying)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
    v_tenant_id UUID;
BEGIN
    PERFORM app_private.require_any_permission(array['logistics:manage']);
    v_tenant_id := app_private.current_tenant_id();
    IF v_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated or no tenant found';
    END IF;

    UPDATE public.trucks
    SET
        name       = COALESCE(p_name, name),
        serial_no  = COALESCE(p_serial_no, serial_no),
        capacity   = COALESCE(p_capacity, capacity),
        size       = COALESCE(p_size, size),
        status     = COALESCE(p_status, status),
        location   = CASE WHEN p_location IS NOT NULL THEN p_location ELSE location END,
        updated_at = NOW()
    WHERE tenant_id = v_tenant_id AND truck_id = p_truck_id;

    RETURN jsonb_build_object(
        'truck_id', p_truck_id,
        'message', 'Truck updated successfully'
    );
END;
$function$;

-- A public inventory adjustment checks its own capability; purchases use the
-- unexposed recorder under their purchase capability, without inventory:manage.
create function public.create_inventory_movement(
  p_item_id uuid, p_movement_type text, p_filled_quantity_change integer,
  p_empty_quantity_change integer, p_notes text default null
) returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
  perform app_private.require_permission('inventory:manage');
  return app_private.record_inventory_movement(p_item_id, p_movement_type,
    p_filled_quantity_change, p_empty_quantity_change, p_notes);
end $$;

create function public.get_my_permissions()
returns text[] language sql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
  select coalesce(array_agg(distinct rp.permission_id::text), array[]::text[])
  from public.user_roles ur
  join public.roles r on r.tenant_id = ur.tenant_id and r.role_id = ur.role_id
  join public.role_permissions rp on rp.tenant_id = r.tenant_id and rp.role_id = r.role_id
  join public.permissions p on p.permission_id = rp.permission_id
  where ur.user_id = auth.uid() and ur.tenant_id = app_private.current_tenant_id()
$$;

-- Dashboard counts do not grant the cashier inventory-history or finance access.
create function public.get_dashboard_stats(p_since timestamptz)
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare v_tenant uuid := app_private.require_permission('dashboard:view');
begin
  return jsonb_build_object(
    'todayRevenue', (select coalesce(sum(total_amount), 0) from public.sales
      where tenant_id = v_tenant and status = 'completed' and created_at >= p_since),
    'todayMovements', (select count(*) from public.inventory_movements
      where tenant_id = v_tenant and created_at >= p_since),
    'totalCustomers', (select count(*) from public.customers where tenant_id = v_tenant)
  );
end $$;

-- Execute allowlist: trigger functions and arbitrary-tenant helpers stay private.
revoke all on all functions in schema public from public, anon, authenticated;
revoke all on all functions in schema app_private from public, anon, authenticated;
grant execute on function app_private.current_tenant_id(),
  app_private.has_permission(text), app_private.has_any_permission(text[]) to authenticated;
grant execute on function public.complete_purchase(uuid) to authenticated;
grant execute on function public.create_area_officer(uuid,text,text,text) to authenticated;
grant execute on function public.create_custom_transit(uuid,numeric,text) to authenticated;
grant execute on function public.create_employee(text,jsonb,text,numeric,text,text,text) to authenticated;
grant execute on function public.create_employee_payment(uuid,uuid,numeric,date,text,integer,integer,integer) to authenticated;
grant execute on function public.create_gas_plant(text,uuid,text) to authenticated;
grant execute on function public.create_inventory_movement(uuid,text,integer,integer,text) to authenticated;
grant execute on function public.create_lpg_brand(text,text) to authenticated;
grant execute on function public.create_pos_sale(character varying,character varying,character varying,text,character varying,numeric,numeric,text,jsonb,uuid) to authenticated;
grant execute on function public.create_purchase(uuid,uuid,numeric,numeric,text,jsonb) to authenticated;
grant execute on function public.create_truck(character varying,character varying,integer,public.truck_size,character varying) to authenticated;
grant execute on function public.deactivate_employee(uuid) to authenticated;
grant execute on function public.list_employee_payment_categories() to authenticated;
grant execute on function public.list_employee_payments(uuid) to authenticated;
grant execute on function public.list_employees() to authenticated;
grant execute on function public.list_gas_plants(boolean) to authenticated;
grant execute on function public.list_lpg_brands(boolean) to authenticated;
grant execute on function public.list_purchases() to authenticated;
grant execute on function public.list_trucks(boolean) to authenticated;
grant execute on function public.setup_business(text,text) to authenticated;
grant execute on function public.update_area_officer(uuid,text,text,text) to authenticated;
grant execute on function public.update_employee(uuid,text,jsonb,text,numeric,text,text,text,boolean) to authenticated;
grant execute on function public.update_gas_plant(uuid,text,uuid,text,boolean) to authenticated;
grant execute on function public.update_lpg_brand(uuid,text,text,boolean) to authenticated;
grant execute on function public.update_purchase(uuid,numeric,numeric,text,jsonb) to authenticated;
grant execute on function public.update_transit_costs(uuid,numeric,numeric,numeric,jsonb,public.transit_status) to authenticated;
grant execute on function public.update_truck(uuid,character varying,character varying,integer,public.truck_size,public.truck_status,character varying) to authenticated;
grant execute on function public.get_my_permissions(), public.get_dashboard_stats(timestamptz) to authenticated;

-- Deploy with the platform superuser for its defaults, while retaining the
-- application function owner used by the established migrations.
do $owners$
declare f record;
begin
  for f in select p.oid::regprocedure as signature from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public','app_private')
  loop execute format('alter function %s owner to postgres', f.signature); end loop;
end $owners$;
alter schema app_private owner to postgres;

-- Revoke creator-specific defaults, including the global PUBLIC function default.
-- IN SCHEMA alone cannot revoke a privilege supplied by the global defaults.
alter default privileges for role postgres revoke execute on functions from public, anon, authenticated;
alter default privileges for role postgres in schema public revoke all on tables from public, anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from public, anon, authenticated;
alter default privileges for role postgres in schema public revoke execute on functions from public, anon, authenticated;
alter default privileges for role postgres in schema app_private revoke execute on functions from public, anon, authenticated;
alter default privileges for role supabase_admin revoke execute on functions from public, anon, authenticated;
alter default privileges for role supabase_admin in schema public revoke all on tables from public, anon, authenticated;
alter default privileges for role supabase_admin in schema public revoke all on sequences from public, anon, authenticated;
alter default privileges for role supabase_admin in schema public revoke execute on functions from public, anon, authenticated;
alter default privileges for role supabase_admin in schema app_private revoke execute on functions from public, anon, authenticated;
notify pgrst, 'reload schema';
