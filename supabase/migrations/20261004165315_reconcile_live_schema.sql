-- Capture the existing local schema without rewriting the employee migration.
-- On the audited database these objects already exist: do not replay employees.sql.
-- Constraint renames also preserve/rename the existing unique backing index.
begin;

set local lock_timeout = '5s';

do $$
begin
  if exists (
    select 1 from pg_constraint
    where conrelid = 'public.employee_payment_categories'::regclass
      and conname = 'employee_payment_categories_tenant_id_category_id_code_key'
  ) then
    alter table public.employee_payment_categories
      rename constraint employee_payment_categories_tenant_id_category_id_code_key
      to employee_payment_categories_tenant_category_code_unique;
  end if;

  if exists (
    select 1 from pg_constraint
    where conrelid = 'public.employee_payments'::regclass
      and conname = 'employee_payments_tenant_id_category_id_category_code_fkey'
  ) then
    alter table public.employee_payments
      rename constraint employee_payments_tenant_id_category_id_category_code_fkey
      to employee_payments_tenant_category_consistent_fkey;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.employee_payments'::regclass
      and conname = 'employee_payments_tenant_id_category_id_fkey'
  ) then
    alter table public.employee_payments
      add constraint employee_payments_tenant_id_category_id_fkey
      foreign key (tenant_id, category_id)
      references public.employee_payment_categories (tenant_id, category_id);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.employee_payments'::regclass
      and conname = 'employee_payments_tenant_id_category_code_fkey'
  ) then
    alter table public.employee_payments
      add constraint employee_payments_tenant_id_category_code_fkey
      foreign key (tenant_id, category_code)
      references public.employee_payment_categories (tenant_id, code);
  end if;
end $$;

-- Preserve the platform administrator's existing public-schema defaults.
-- These broad defaults are recorded, not endorsed or hardened by this migration.
-- Supabase normally supplies them during bootstrap. If absent, creating them
-- requires a superuser / supabase_admin; ordinary postgres is not its member.
-- Skip already matching grants so the normal migration role works on Supabase.
do $$
begin
  if not exists (
    select 1 from pg_default_acl
    where defaclrole = 'supabase_admin'::regrole
      and defaclnamespace = 'public'::regnamespace and defaclobjtype = 'r'
      and defaclacl @> array[
        'postgres=arwdDxtm/supabase_admin', 'anon=arwdDxtm/supabase_admin',
        'authenticated=arwdDxtm/supabase_admin', 'service_role=arwdDxtm/supabase_admin'
      ]::aclitem[]
  ) then
    alter default privileges for role supabase_admin in schema public
      grant all on tables to postgres, anon, authenticated, service_role;
  end if;

  if not exists (
    select 1 from pg_default_acl
    where defaclrole = 'supabase_admin'::regrole
      and defaclnamespace = 'public'::regnamespace and defaclobjtype = 'S'
      and defaclacl @> array[
        'postgres=rwU/supabase_admin', 'anon=rwU/supabase_admin',
        'authenticated=rwU/supabase_admin', 'service_role=rwU/supabase_admin'
      ]::aclitem[]
  ) then
    alter default privileges for role supabase_admin in schema public
      grant all on sequences to postgres, anon, authenticated, service_role;
  end if;

  if not exists (
    select 1 from pg_default_acl
    where defaclrole = 'supabase_admin'::regrole
      and defaclnamespace = 'public'::regnamespace and defaclobjtype = 'f'
      and defaclacl @> array[
        'postgres=X/supabase_admin', 'anon=X/supabase_admin',
        'authenticated=X/supabase_admin', 'service_role=X/supabase_admin'
      ]::aclitem[]
  ) then
    alter default privileges for role supabase_admin in schema public
      grant all on functions to postgres, anon, authenticated, service_role;
  end if;
end $$;

commit;
