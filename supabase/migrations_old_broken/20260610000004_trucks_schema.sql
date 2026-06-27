-- =============================================================================
-- NexusLPG: Trucks & Fleet Management Schema
-- Adds support for managing the vehicle fleet for logistics operations
-- =============================================================================

-- ── ENUM: Truck Size ───────────────────────────────────────────────────────
CREATE TYPE truck_size AS ENUM ('big', 'medium', 'small');

-- ── TABLE: Trucks ──────────────────────────────────────────────────────────
-- Stores truck/vehicle information for the logistics fleet
CREATE TABLE IF NOT EXISTS trucks (
    tenant_id       UUID        NOT NULL,
    truck_id        UUID        NOT NULL DEFAULT uuid_generate_v4(),
    name            VARCHAR(100) NOT NULL,           -- e.g., "JAC", "Ashok Leyland"
    serial_no       VARCHAR(100) NOT NULL,           -- Unique identifier/registration
    capacity        INT         NOT NULL CHECK (capacity > 0),   -- Number of units
    size            truck_size  NOT NULL,            -- big, medium, small
    is_active       BOOLEAN     NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, truck_id),
    FOREIGN KEY (tenant_id) REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    UNIQUE (tenant_id, serial_no)
);

-- ── INDEXES ────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_trucks_tenant_active
    ON trucks(tenant_id, is_active);

CREATE INDEX IF NOT EXISTS idx_trucks_size
    ON trucks(tenant_id, size);

-- ── ROW LEVEL SECURITY ─────────────────────────────────────────────────────
ALTER TABLE trucks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "trucks_tenant_select" ON trucks;
CREATE POLICY "trucks_tenant_select" ON trucks FOR SELECT
    USING (tenant_id = my_tenant_id());

DROP POLICY IF EXISTS "trucks_tenant_insert" ON trucks;
CREATE POLICY "trucks_tenant_insert" ON trucks FOR INSERT
    WITH CHECK (tenant_id = my_tenant_id());

DROP POLICY IF EXISTS "trucks_tenant_update" ON trucks;
CREATE POLICY "trucks_tenant_update" ON trucks FOR UPDATE
    USING (tenant_id = my_tenant_id())
    WITH CHECK (tenant_id = my_tenant_id());

DROP POLICY IF EXISTS "trucks_tenant_delete" ON trucks;
CREATE POLICY "trucks_tenant_delete" ON trucks FOR DELETE
    USING (tenant_id = my_tenant_id());

-- ── AUDIT TRIGGER for trucks ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION audit_trucks()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_logs (tenant_id, table_name, record_id, action, old_data, new_data, performed_by)
    VALUES (
        NEW.tenant_id,
        'trucks',
        NEW.truck_id,
        TG_OP,
        CASE WHEN TG_OP = 'UPDATE' THEN row_to_json(OLD) ELSE NULL END,
        row_to_json(NEW),
        auth.uid()
    );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_trucks ON trucks;
CREATE TRIGGER trg_audit_trucks
    AFTER INSERT OR UPDATE OR DELETE ON trucks
    FOR EACH ROW EXECUTE FUNCTION audit_trucks();

-- ── RPC: Create Truck ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION create_truck(
    p_name VARCHAR,
    p_serial_no VARCHAR,
    p_capacity INT,
    p_size truck_size
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tenant_id UUID;
    v_truck_id UUID;
BEGIN
    v_tenant_id := my_tenant_id();
    IF v_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated or no tenant found';
    END IF;

    INSERT INTO trucks (tenant_id, name, serial_no, capacity, size)
    VALUES (v_tenant_id, p_name, p_serial_no, p_capacity, p_size)
    RETURNING truck_id INTO v_truck_id;

    RETURN jsonb_build_object(
        'truck_id', v_truck_id,
        'name', p_name,
        'serial_no', p_serial_no,
        'capacity', p_capacity,
        'size', p_size
    );
END;
$$;

GRANT EXECUTE ON FUNCTION create_truck(VARCHAR, VARCHAR, INT, truck_size) TO authenticated;

-- ── RPC: Update Truck ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION update_truck(
    p_truck_id UUID,
    p_name VARCHAR DEFAULT NULL,
    p_serial_no VARCHAR DEFAULT NULL,
    p_capacity INT DEFAULT NULL,
    p_size truck_size DEFAULT NULL,
    p_is_active BOOLEAN DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tenant_id UUID;
BEGIN
    v_tenant_id := my_tenant_id();
    IF v_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated or no tenant found';
    END IF;

    UPDATE trucks
    SET
        name = COALESCE(p_name, name),
        serial_no = COALESCE(p_serial_no, serial_no),
        capacity = COALESCE(p_capacity, capacity),
        size = COALESCE(p_size, size),
        is_active = COALESCE(p_is_active, is_active),
        updated_at = NOW()
    WHERE tenant_id = v_tenant_id AND truck_id = p_truck_id;

    RETURN jsonb_build_object(
        'truck_id', p_truck_id,
        'message', 'Truck updated successfully'
    );
END;
$$;

GRANT EXECUTE ON FUNCTION update_truck(UUID, VARCHAR, VARCHAR, INT, truck_size, BOOLEAN) TO authenticated;

-- ── RPC: List Trucks ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION list_trucks(p_active_only BOOLEAN DEFAULT true)
RETURNS TABLE (
    truck_id UUID,
    name VARCHAR,
    serial_no VARCHAR,
    capacity INT,
    size truck_size,
    is_active BOOLEAN,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT
        t.truck_id,
        t.name,
        t.serial_no,
        t.capacity,
        t.size,
        t.is_active,
        t.created_at,
        t.updated_at
    FROM trucks t
    WHERE t.tenant_id = my_tenant_id()
      AND (NOT p_active_only OR t.is_active = true)
    ORDER BY t.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION list_trucks(BOOLEAN) TO authenticated;
