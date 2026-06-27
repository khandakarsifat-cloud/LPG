-- =============================================================================
-- NexusLPG: Trucks — Replace is_active with status enum + add location
-- =============================================================================

-- ── ENUM: Truck Status ────────────────────────────────────────────────────────
CREATE TYPE truck_status AS ENUM ('idle', 'coming', 'going');

-- ── ALTER: trucks table ───────────────────────────────────────────────────────
ALTER TABLE trucks
    ADD COLUMN IF NOT EXISTS status   truck_status NOT NULL DEFAULT 'idle',
    ADD COLUMN IF NOT EXISTS location VARCHAR(200);

-- Migrate existing is_active data: active → idle, inactive → idle (best effort)
UPDATE trucks SET status = 'idle';

-- Drop is_active column
ALTER TABLE trucks DROP COLUMN IF EXISTS is_active;

-- ── INDEX ─────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_trucks_status
    ON trucks(tenant_id, status);

-- ── RPC: Create Truck (updated) ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION create_truck(
    p_name VARCHAR,
    p_serial_no VARCHAR,
    p_capacity INT,
    p_size truck_size,
    p_location VARCHAR DEFAULT NULL
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

    INSERT INTO trucks (tenant_id, name, serial_no, capacity, size, status, location)
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
$$;

GRANT EXECUTE ON FUNCTION create_truck(VARCHAR, VARCHAR, INT, truck_size, VARCHAR) TO authenticated;

-- ── RPC: Update Truck (updated) ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION update_truck(
    p_truck_id UUID,
    p_name VARCHAR DEFAULT NULL,
    p_serial_no VARCHAR DEFAULT NULL,
    p_capacity INT DEFAULT NULL,
    p_size truck_size DEFAULT NULL,
    p_status truck_status DEFAULT NULL,
    p_location VARCHAR DEFAULT NULL
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
$$;

GRANT EXECUTE ON FUNCTION update_truck(UUID, VARCHAR, VARCHAR, INT, truck_size, truck_status, VARCHAR) TO authenticated;

-- ── RPC: List Trucks (updated) ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION list_trucks(p_active_only BOOLEAN DEFAULT true)
RETURNS TABLE (
    truck_id   UUID,
    name       VARCHAR,
    serial_no  VARCHAR,
    capacity   INT,
    size       truck_size,
    status     truck_status,
    location   VARCHAR,
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
        t.status,
        t.location,
        t.created_at,
        t.updated_at
    FROM trucks t
    WHERE t.tenant_id = my_tenant_id()
    ORDER BY t.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION list_trucks(BOOLEAN) TO authenticated;
