-- =============================================================================
-- NexusLPG Master Schema — Idempotent (safe to re-run)
-- Run this entire file in the Supabase SQL Editor.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ── Tenants ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tenants (
    tenant_id     UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_name VARCHAR(255) NOT NULL,
    status        VARCHAR(50)  NOT NULL DEFAULT 'active',
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ── Permissions (global seed, not tenant-scoped) ──────────────────────────────
CREATE TABLE IF NOT EXISTS permissions (
    permission_id VARCHAR(100) PRIMARY KEY,
    description   TEXT
);

INSERT INTO permissions (permission_id, description) VALUES
  ('pos:sell',           'Create sales invoice at POS'),
  ('pos:void',           'Void or cancel a sales invoice'),
  ('inventory:view',     'View inventory balances'),
  ('inventory:adjust',   'File manual inventory adjustments'),
  ('inventory:purchase', 'Log a purchase / replenishment'),
  ('customers:view',     'View customer list and details'),
  ('customers:manage',   'Create and edit customers'),
  ('finance:view',       'View financial ledger and statements'),
  ('finance:manage',     'Record payments and credits'),
  ('logistics:view',     'View trips and staff assignments'),
  ('logistics:manage',   'Create and complete delivery trips'),
  ('settings:view',      'View system settings'),
  ('settings:manage',    'Modify roles, users, and system config')
ON CONFLICT (permission_id) DO NOTHING;

-- ── Roles ─────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS roles (
    tenant_id UUID NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    role_id   UUID NOT NULL DEFAULT uuid_generate_v4(),
    name      VARCHAR(100) NOT NULL,
    PRIMARY KEY (tenant_id, role_id)
);

-- ── Role ↔ Permissions ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS role_permissions (
    tenant_id     UUID        NOT NULL,
    role_id       UUID        NOT NULL,
    permission_id VARCHAR(100) NOT NULL REFERENCES permissions(permission_id),
    PRIMARY KEY (tenant_id, role_id, permission_id),
    FOREIGN KEY (tenant_id, role_id) REFERENCES roles(tenant_id, role_id) ON DELETE CASCADE
);

-- ── User Profiles ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS user_profiles (
    user_id   UUID        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    tenant_id UUID        NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    full_name VARCHAR(255),
    email     VARCHAR(255) NOT NULL,
    is_active BOOLEAN     NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── User ↔ Roles ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS user_roles (
    tenant_id UUID NOT NULL,
    user_id   UUID NOT NULL REFERENCES user_profiles(user_id) ON DELETE CASCADE,
    role_id   UUID NOT NULL,
    PRIMARY KEY (tenant_id, user_id, role_id),
    FOREIGN KEY (tenant_id, role_id) REFERENCES roles(tenant_id, role_id) ON DELETE CASCADE
);

-- ── Items (Product Directory) ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS items (
    tenant_id UUID        NOT NULL,
    item_id   UUID        NOT NULL DEFAULT uuid_generate_v4(),
    brand     VARCHAR(100) NOT NULL,
    size_kg   NUMERIC(5,2) NOT NULL,
    type      VARCHAR(20)  NOT NULL CHECK (type IN ('gas_only', 'cylinder_only', 'package')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, item_id),
    FOREIGN KEY (tenant_id) REFERENCES tenants(tenant_id) ON DELETE CASCADE
);

-- ── Immutable Inventory Ledger ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS inventory_movements (
    tenant_id      UUID        NOT NULL,
    movement_id    UUID        NOT NULL DEFAULT uuid_generate_v4(),
    item_id        UUID        NOT NULL,
    movement_type  VARCHAR(50) NOT NULL
        CHECK (movement_type IN ('purchase','sale','exchange','refill','loss','adjust_gain','adjust_loss')),
    quantity_change INT         NOT NULL CHECK (quantity_change != 0),
    notes          TEXT,
    reference_type VARCHAR(50),
    reference_id   UUID,
    created_by     UUID        REFERENCES user_profiles(user_id),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, movement_id),
    FOREIGN KEY (tenant_id, item_id) REFERENCES items(tenant_id, item_id)
);

-- ── Inventory Balance Cache ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS inventory_balances (
    tenant_id        UUID NOT NULL,
    item_id          UUID NOT NULL,
    current_quantity INT  NOT NULL DEFAULT 0,
    last_updated     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, item_id),
    FOREIGN KEY (tenant_id, item_id) REFERENCES items(tenant_id, item_id)
);

-- ── Customers ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS customers (
    tenant_id   UUID        NOT NULL,
    customer_id UUID        NOT NULL DEFAULT uuid_generate_v4(),
    name        VARCHAR(255) NOT NULL,
    phone       VARCHAR(50),
    address     TEXT,
    tier        VARCHAR(50) NOT NULL DEFAULT 'retail',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, customer_id),
    FOREIGN KEY (tenant_id) REFERENCES tenants(tenant_id) ON DELETE CASCADE
);

-- ── Customer Transactions (Financial Ledger) ──────────────────────────────────
CREATE TABLE IF NOT EXISTS customer_transactions (
    tenant_id      UUID        NOT NULL,
    transaction_id UUID        NOT NULL DEFAULT uuid_generate_v4(),
    customer_id    UUID        NOT NULL,
    type           VARCHAR(50) NOT NULL
        CHECK (type IN ('invoice_charge','payment_receipt','refund','opening_balance')),
    amount         NUMERIC(12,2) NOT NULL,
    notes          TEXT,
    reference_id   UUID,
    created_by     UUID REFERENCES user_profiles(user_id),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, transaction_id),
    FOREIGN KEY (tenant_id, customer_id) REFERENCES customers(tenant_id, customer_id)
);

-- ── Trips ─────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS trips (
    tenant_id     UUID        NOT NULL,
    trip_id       UUID        NOT NULL DEFAULT uuid_generate_v4(),
    truck_license VARCHAR(50) NOT NULL,
    plant_name    VARCHAR(255),
    status        VARCHAR(50) NOT NULL DEFAULT 'dispatched',
    dispatched_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at  TIMESTAMPTZ,
    PRIMARY KEY (tenant_id, trip_id),
    FOREIGN KEY (tenant_id) REFERENCES tenants(tenant_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS trip_staff (
    tenant_id        UUID        NOT NULL,
    trip_id          UUID        NOT NULL,
    employee_id      UUID        NOT NULL,
    role             VARCHAR(50),
    allowance_amount NUMERIC(10,2) NOT NULL DEFAULT 0.00,
    PRIMARY KEY (tenant_id, trip_id, employee_id),
    FOREIGN KEY (tenant_id, trip_id) REFERENCES trips(tenant_id, trip_id) ON DELETE CASCADE
);

-- ── Audit Logs ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS audit_logs (
    tenant_id    UUID        NOT NULL,
    log_id       UUID        NOT NULL DEFAULT uuid_generate_v4(),
    table_name   VARCHAR(100) NOT NULL,
    record_id    UUID        NOT NULL,
    action       VARCHAR(20) NOT NULL CHECK (action IN ('INSERT','UPDATE','DELETE')),
    old_data     JSONB,
    new_data     JSONB,
    performed_by UUID,
    ip_address   INET,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, log_id)
);

-- =============================================================================
-- INDEXES
-- =============================================================================
CREATE INDEX IF NOT EXISTS idx_inventory_movements_tenant_item_date
    ON inventory_movements(tenant_id, item_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_inventory_movements_tenant_date
    ON inventory_movements(tenant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_customer_transactions_tenant_customer_date
    ON customer_transactions(tenant_id, customer_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_items_tenant
    ON items(tenant_id);

CREATE INDEX IF NOT EXISTS idx_user_profiles_tenant
    ON user_profiles(tenant_id);

-- =============================================================================
-- TRIGGER: Keep inventory_balances in sync after each movement INSERT
-- =============================================================================
CREATE OR REPLACE FUNCTION update_inventory_balance()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO inventory_balances (tenant_id, item_id, current_quantity, last_updated)
    VALUES (NEW.tenant_id, NEW.item_id, NEW.quantity_change, NOW())
    ON CONFLICT (tenant_id, item_id)
    DO UPDATE SET
        current_quantity = inventory_balances.current_quantity + NEW.quantity_change,
        last_updated     = NOW();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_update_inventory ON inventory_movements;
CREATE TRIGGER trg_update_inventory
    AFTER INSERT ON inventory_movements
    FOR EACH ROW EXECUTE FUNCTION update_inventory_balance();

-- =============================================================================
-- RPC: setup_business — atomic tenant + role bootstrap on first registration
-- =============================================================================
CREATE OR REPLACE FUNCTION setup_business(
    p_business_name TEXT,
    p_owner_name    TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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

    SELECT email INTO v_user_email FROM auth.users WHERE id = v_user_id;

    -- 1. Create the Tenant
    INSERT INTO tenants (business_name, status)
    VALUES (p_business_name, 'active')
    RETURNING tenant_id INTO v_tenant_id;

    -- 2. Create User Profile
    INSERT INTO user_profiles (user_id, tenant_id, full_name, email)
    VALUES (v_user_id, v_tenant_id, p_owner_name, v_user_email);

    -- 3. Create default roles: Owner, Manager, Salesman
    INSERT INTO roles (tenant_id, name) VALUES (v_tenant_id, 'Owner')   RETURNING role_id INTO v_owner_role;
    INSERT INTO roles (tenant_id, name) VALUES (v_tenant_id, 'Manager') RETURNING role_id INTO v_mgr_role;
    INSERT INTO roles (tenant_id, name) VALUES (v_tenant_id, 'Salesman') RETURNING role_id INTO v_sales_role;

    -- 4. Owner gets ALL permissions
    INSERT INTO role_permissions (tenant_id, role_id, permission_id)
    SELECT v_tenant_id, v_owner_role, permission_id FROM permissions;

    -- 5. Manager gets most permissions (not settings:manage)
    INSERT INTO role_permissions (tenant_id, role_id, permission_id)
    SELECT v_tenant_id, v_mgr_role, permission_id
    FROM permissions
    WHERE permission_id NOT IN ('settings:manage');

    -- 6. Salesman gets POS + view permissions
    INSERT INTO role_permissions (tenant_id, role_id, permission_id)
    SELECT v_tenant_id, v_sales_role, permission_id
    FROM permissions
    WHERE permission_id IN ('pos:sell','inventory:view','customers:view','logistics:view');

    -- 7. Assign Owner role to registering user
    INSERT INTO user_roles (tenant_id, user_id, role_id)
    VALUES (v_tenant_id, v_user_id, v_owner_role);

    -- 8. Store tenant_id in user metadata for quick JWT reads
    UPDATE auth.users
    SET raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object(
        'full_name', p_owner_name,
        'tenant_id', v_tenant_id::text
    )
    WHERE id = v_user_id;

    RETURN jsonb_build_object(
        'tenant_id', v_tenant_id,
        'user_id',   v_user_id,
        'role',      'Owner'
    );
END;
$$;

GRANT EXECUTE ON FUNCTION setup_business(TEXT, TEXT) TO authenticated;

-- =============================================================================
-- RPC: create_inventory_movement — validates and inserts a ledger entry
-- =============================================================================
CREATE OR REPLACE FUNCTION create_inventory_movement(
    p_item_id       UUID,
    p_movement_type TEXT,
    p_quantity      INT,
    p_notes         TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id   UUID := auth.uid();
    v_tenant_id UUID;
    v_qty_signed INT;
    v_movement_id UUID;
BEGIN
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

    -- Derive tenant from user profile
    SELECT tenant_id INTO v_tenant_id FROM user_profiles WHERE user_id = v_user_id;
    IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'No tenant found for user'; END IF;

    -- Sign the quantity correctly based on movement type
    v_qty_signed := CASE
        WHEN p_movement_type IN ('purchase','refill','exchange','adjust_gain') THEN ABS(p_quantity)
        WHEN p_movement_type IN ('sale','loss','adjust_loss')                  THEN -ABS(p_quantity)
        ELSE p_quantity
    END;

    INSERT INTO inventory_movements
        (tenant_id, item_id, movement_type, quantity_change, notes, created_by)
    VALUES
        (v_tenant_id, p_item_id, p_movement_type, v_qty_signed, p_notes, v_user_id)
    RETURNING movement_id INTO v_movement_id;

    RETURN jsonb_build_object('movement_id', v_movement_id, 'quantity_change', v_qty_signed);
END;
$$;

GRANT EXECUTE ON FUNCTION create_inventory_movement(UUID, TEXT, INT, TEXT) TO authenticated;

-- =============================================================================
-- ROW LEVEL SECURITY
-- All policies use a subquery against user_profiles to derive tenant_id.
-- This avoids the need to set app_metadata on the JWT (requires service role).
-- =============================================================================

-- Helper: get calling user's tenant_id
CREATE OR REPLACE FUNCTION my_tenant_id()
RETURNS UUID LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT tenant_id FROM user_profiles WHERE user_id = auth.uid() LIMIT 1;
$$;

-- tenants
ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "tenant_select" ON tenants;
CREATE POLICY "tenant_select" ON tenants FOR SELECT
    USING (tenant_id = my_tenant_id());

-- user_profiles
ALTER TABLE user_profiles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "profile_select" ON user_profiles;
CREATE POLICY "profile_select" ON user_profiles FOR SELECT
    USING (tenant_id = my_tenant_id());
DROP POLICY IF EXISTS "profile_own_update" ON user_profiles;
CREATE POLICY "profile_own_update" ON user_profiles FOR UPDATE
    USING (user_id = auth.uid());

-- roles
ALTER TABLE roles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "roles_tenant" ON roles;
CREATE POLICY "roles_tenant" ON roles FOR ALL
    USING (tenant_id = my_tenant_id());

-- role_permissions
ALTER TABLE role_permissions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "rp_tenant" ON role_permissions;
CREATE POLICY "rp_tenant" ON role_permissions FOR ALL
    USING (tenant_id = my_tenant_id());

-- user_roles
ALTER TABLE user_roles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "ur_tenant" ON user_roles;
CREATE POLICY "ur_tenant" ON user_roles FOR ALL
    USING (tenant_id = my_tenant_id());

-- items
ALTER TABLE items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "items_tenant_select" ON items;
CREATE POLICY "items_tenant_select" ON items FOR SELECT
    USING (tenant_id = my_tenant_id());
DROP POLICY IF EXISTS "items_tenant_insert" ON items;
CREATE POLICY "items_tenant_insert" ON items FOR INSERT
    WITH CHECK (tenant_id = my_tenant_id());

-- inventory_movements (insert-only from client, no deletes)
ALTER TABLE inventory_movements ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "movements_tenant_select" ON inventory_movements;
CREATE POLICY "movements_tenant_select" ON inventory_movements FOR SELECT
    USING (tenant_id = my_tenant_id());
DROP POLICY IF EXISTS "movements_tenant_insert" ON inventory_movements;
CREATE POLICY "movements_tenant_insert" ON inventory_movements FOR INSERT
    WITH CHECK (tenant_id = my_tenant_id());

-- inventory_balances
ALTER TABLE inventory_balances ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "balances_tenant_select" ON inventory_balances;
CREATE POLICY "balances_tenant_select" ON inventory_balances FOR SELECT
    USING (tenant_id = my_tenant_id());
DROP POLICY IF EXISTS "balances_tenant_upsert" ON inventory_balances;
CREATE POLICY "balances_tenant_upsert" ON inventory_balances FOR ALL
    USING (tenant_id = my_tenant_id());

-- customers
ALTER TABLE customers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "customers_tenant" ON customers;
CREATE POLICY "customers_tenant" ON customers FOR ALL
    USING (tenant_id = my_tenant_id())
    WITH CHECK (tenant_id = my_tenant_id());

-- customer_transactions
ALTER TABLE customer_transactions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "ct_tenant" ON customer_transactions;
CREATE POLICY "ct_tenant" ON customer_transactions FOR ALL
    USING (tenant_id = my_tenant_id())
    WITH CHECK (tenant_id = my_tenant_id());

-- trips
ALTER TABLE trips ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "trips_tenant" ON trips;
CREATE POLICY "trips_tenant" ON trips FOR ALL
    USING (tenant_id = my_tenant_id())
    WITH CHECK (tenant_id = my_tenant_id());

-- audit_logs (select only from client)
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "audit_tenant_select" ON audit_logs;
CREATE POLICY "audit_tenant_select" ON audit_logs FOR SELECT
    USING (tenant_id = my_tenant_id());
