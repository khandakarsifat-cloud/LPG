-- Migration: Fix schema inconsistencies between frontend and local database
-- Created: 2026-06-27
-- Purpose: Add missing columns, fix conflicting RLS, seed permissions

-- ============================================================================
-- 1. Add missing "full_name" column to user_profiles
--    The setup_business() RPC inserts full_name, but the column was missing.
-- ============================================================================
ALTER TABLE public.user_profiles
    ADD COLUMN IF NOT EXISTS full_name VARCHAR(255) DEFAULT '';

-- ============================================================================
-- 2. Add missing "created_at" column to customers
--    Frontend Customer type expects created_at: string.
-- ============================================================================
ALTER TABLE public.customers
    ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- ============================================================================
-- 3. Add missing "created_at" column to items
--    Frontend Item type expects created_at: string.
-- ============================================================================
ALTER TABLE public.items
    ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- ============================================================================
-- 4. Add missing "price_type" column to price_books
--    Frontend PriceBook interface expects price_type: 'refill' | 'package'.
-- ============================================================================
ALTER TABLE public.price_books
    ADD COLUMN IF NOT EXISTS price_type VARCHAR(20) NOT NULL DEFAULT 'refill';

-- ============================================================================
-- 5. Drop conflicting JWT-based RLS policy on inventory_movements
--    The policy "Strict Tenant Isolation for Movements" uses
--    auth.jwt()->'app_metadata'->>'tenant_id' which doesn't work with local
--    Supabase. The my_tenant_id() based policies are correct and sufficient.
-- ============================================================================
DROP POLICY IF EXISTS "Strict Tenant Isolation for Movements" ON public.inventory_movements;

-- ============================================================================
-- 6. Seed the permissions table if empty
--    The setup_business() RPC copies permissions into role_permissions.
--    Without seed data, the Owner role would get zero permissions.
--    The baseline migration already seeds these, so this is a safety net.
-- ============================================================================
INSERT INTO public.permissions (permission_id)
SELECT p FROM unnest(ARRAY[
    'settings:manage',
    'pos:sell',
    'inventory:view',
    'inventory:manage',
    'customers:view',
    'customers:manage',
    'logistics:view',
    'logistics:manage',
    'purchases:view',
    'purchases:manage',
    'gas_plants:view',
    'gas_plants:manage',
    'finance:view',
    'finance:manage'
]) AS p
WHERE NOT EXISTS (SELECT 1 FROM public.permissions WHERE permission_id = p);

-- ============================================================================
-- 7. Ensure wallets RLS policy allows insert (for ensure_tenant_wallets)
-- ============================================================================
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'wallets'
          AND policyname = 'wallets_insert'
    ) THEN
        CREATE POLICY wallets_insert ON public.wallets
            FOR INSERT TO authenticated
            WITH CHECK (tenant_id = public.my_tenant_id());
    END IF;
END $$;

-- ============================================================================
-- 8. Ensure price_books has tenant-isolation RLS policies
-- ============================================================================
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'price_books'
          AND policyname = 'price_books_tenant_select'
    ) THEN
        CREATE POLICY price_books_tenant_select ON public.price_books
            FOR SELECT TO authenticated
            USING (tenant_id = public.my_tenant_id());
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'price_books'
          AND policyname = 'price_books_tenant_insert'
    ) THEN
        CREATE POLICY price_books_tenant_insert ON public.price_books
            FOR INSERT TO authenticated
            WITH CHECK (tenant_id = public.my_tenant_id());
    END IF;
END $$;
