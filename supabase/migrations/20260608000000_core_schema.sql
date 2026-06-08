-- NexusLPG Multi-Tenant ERP Core Schema

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE tenants (
    tenant_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_name VARCHAR(255) NOT NULL,
    status VARCHAR(50) DEFAULT 'active',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Granular Permissions mapping
CREATE TABLE permissions (
    permission_id VARCHAR(100) PRIMARY KEY, -- e.g., 'pos:sell', 'inventory:adjust'
    description TEXT
);

CREATE TABLE roles (
    tenant_id UUID REFERENCES tenants(tenant_id),
    role_id UUID DEFAULT uuid_generate_v4(),
    name VARCHAR(100) NOT NULL,
    PRIMARY KEY (tenant_id, role_id)
);

CREATE TABLE role_permissions (
    tenant_id UUID,
    role_id UUID,
    permission_id VARCHAR(100) REFERENCES permissions(permission_id),
    PRIMARY KEY (tenant_id, role_id, permission_id),
    FOREIGN KEY (tenant_id, role_id) REFERENCES roles(tenant_id, role_id)
);

CREATE TABLE user_profiles (
    user_id UUID PRIMARY KEY, -- Removed auth.users(id) reference for simplicity without auth schema present, or keeping it if auth schema exists.
    tenant_id UUID NOT NULL REFERENCES tenants(tenant_id),
    email VARCHAR(255) NOT NULL,
    is_active BOOLEAN DEFAULT true
);

CREATE TABLE user_roles (
    tenant_id UUID,
    user_id UUID REFERENCES user_profiles(user_id),
    role_id UUID,
    PRIMARY KEY (tenant_id, user_id, role_id),
    FOREIGN KEY (tenant_id, role_id) REFERENCES roles(tenant_id, role_id)
);

-- Products & Pricing Engine
CREATE TABLE items (
    tenant_id UUID,
    item_id UUID DEFAULT uuid_generate_v4(),
    brand VARCHAR(100) NOT NULL,
    size_kg NUMERIC(5,2) NOT NULL,
    type VARCHAR(20) CHECK (type IN ('gas_only', 'cylinder_only', 'package')),
    PRIMARY KEY (tenant_id, item_id)
);

CREATE TABLE price_books (
    tenant_id UUID,
    item_id UUID,
    customer_tier VARCHAR(50) DEFAULT 'retail', -- retail, wholesale, vip
    price NUMERIC(12,2) NOT NULL,
    effective_from TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    effective_to TIMESTAMPTZ, -- Null means currently active
    PRIMARY KEY (tenant_id, item_id, customer_tier, effective_from),
    FOREIGN KEY (tenant_id, item_id) REFERENCES items(tenant_id, item_id),
    CHECK (effective_to IS NULL OR effective_to > effective_from)
);

-- Immutable Inventory Ledger
CREATE TABLE inventory_movements (
    tenant_id UUID,
    movement_id UUID DEFAULT uuid_generate_v4(),
    item_id UUID NOT NULL,
    movement_type VARCHAR(50) NOT NULL, -- sale, purchase, refill, adjust_loss, adjust_gain
    quantity_change INT NOT NULL, -- positive or negative
    reference_type VARCHAR(50), -- invoice, trip, manual_audit
    reference_id UUID,
    created_by UUID REFERENCES user_profiles(user_id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (tenant_id, movement_id),
    FOREIGN KEY (tenant_id, item_id) REFERENCES items(tenant_id, item_id),
    CHECK (quantity_change != 0)
);

CREATE TABLE inventory_balances (
    tenant_id UUID,
    item_id UUID,
    current_quantity INT DEFAULT 0,
    last_updated TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (tenant_id, item_id),
    FOREIGN KEY (tenant_id, item_id) REFERENCES items(tenant_id, item_id)
);

-- Financial Ledger & Accounting
CREATE TABLE customers (
    tenant_id UUID,
    customer_id UUID DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,
    tier VARCHAR(50) DEFAULT 'retail',
    PRIMARY KEY (tenant_id, customer_id)
);

CREATE TABLE customer_transactions (
    tenant_id UUID,
    transaction_id UUID DEFAULT uuid_generate_v4(),
    customer_id UUID NOT NULL,
    type VARCHAR(50) NOT NULL, -- invoice_charge, payment_receipt, refund, opening_balance
    amount NUMERIC(12,2) NOT NULL, -- Positive = Credit, Negative = Debit
    reference_id UUID, -- Link to invoice or receipt
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (tenant_id, transaction_id),
    FOREIGN KEY (tenant_id, customer_id) REFERENCES customers(tenant_id, customer_id)
);

-- Flexible Logistics
CREATE TABLE trips (
    tenant_id UUID,
    trip_id UUID DEFAULT uuid_generate_v4(),
    truck_license VARCHAR(50) NOT NULL,
    plant_name VARCHAR(255),
    status VARCHAR(50) DEFAULT 'dispatched',
    dispatched_at TIMESTAMPTZ DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    PRIMARY KEY (tenant_id, trip_id)
);

CREATE TABLE trip_staff (
    tenant_id UUID,
    trip_id UUID,
    employee_id UUID NOT NULL,
    role VARCHAR(50), -- driver, primary_helper, secondary_helper
    allowance_amount NUMERIC(10,2) DEFAULT 0.00,
    PRIMARY KEY (tenant_id, trip_id, employee_id),
    FOREIGN KEY (tenant_id, trip_id) REFERENCES trips(tenant_id, trip_id)
);

-- Immutable Audit Trails
CREATE TABLE audit_logs (
    tenant_id UUID,
    log_id UUID DEFAULT uuid_generate_v4(),
    table_name VARCHAR(100) NOT NULL,
    record_id UUID NOT NULL,
    action VARCHAR(20) NOT NULL, -- INSERT, UPDATE, DELETE
    old_data JSONB,
    new_data JSONB,
    performed_by UUID,
    ip_address INET, -- Supabase maps INET
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (tenant_id, log_id)
);

-- Indexes for performance
CREATE INDEX idx_inventory_movements_tenant_item_date ON inventory_movements(tenant_id, item_id, created_at);
CREATE INDEX idx_customer_transactions_tenant_customer_date ON customer_transactions(tenant_id, customer_id, created_at);
CREATE INDEX idx_price_books_tenant_item_tier ON price_books(tenant_id, item_id, customer_tier);
CREATE INDEX idx_audit_logs_tenant_table_record ON audit_logs(tenant_id, table_name, record_id);

-- Inventory Trigger
CREATE OR REPLACE FUNCTION update_inventory_balance()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO inventory_balances (tenant_id, item_id, current_quantity)
    VALUES (NEW.tenant_id, NEW.item_id, NEW.quantity_change)
    ON CONFLICT (tenant_id, item_id)
    DO UPDATE SET 
        current_quantity = inventory_balances.current_quantity + NEW.quantity_change,
        last_updated = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_update_inventory
AFTER INSERT ON inventory_movements
FOR EACH ROW EXECUTE FUNCTION update_inventory_balance();

-- RLS setup (Example on inventory_movements, others follow similarly)
ALTER TABLE inventory_movements ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Strict Tenant Isolation for Movements"
ON inventory_movements
FOR ALL
USING (tenant_id = (auth.jwt() -> 'app_metadata' ->> 'tenant_id')::uuid)
WITH CHECK (tenant_id = (auth.jwt() -> 'app_metadata' ->> 'tenant_id')::uuid);

