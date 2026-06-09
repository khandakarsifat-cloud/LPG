-- =============================================================================
-- NexusLPG: LPG Brands & Cylinder Specifications Schema
-- Adds support for brand management and cylinder specifications (weight & mouth size)
-- =============================================================================

-- ── ENUMS: Cylinder Specifications ─────────────────────────────────────────
CREATE TYPE cylinder_weight AS ENUM ('5kg', '12kg', '25kg', '35kg');
CREATE TYPE mouth_size AS ENUM ('20mm', '22mm');

-- ── TABLE: LPG Brands ──────────────────────────────────────────────────────
-- Stores LPG brands that a business is associated with
CREATE TABLE IF NOT EXISTS lpg_brands (
    tenant_id    UUID        NOT NULL,
    brand_id     UUID        NOT NULL DEFAULT uuid_generate_v4(),
    brand_name   VARCHAR(100) NOT NULL,
    description  TEXT,
    is_active    BOOLEAN     NOT NULL DEFAULT true,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, brand_id),
    FOREIGN KEY (tenant_id) REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    UNIQUE (tenant_id, brand_name)
);

-- ── MIGRATION: Extend items table with specs ───────────────────────────────
-- Add new columns to items table:
-- - brand_id: FK to lpg_brands (nullable for backward compatibility during migration)
-- - cylinder_weight: enum for cylinder weight
-- - mouth_size: enum for mouth/valve size
-- - removed original brand VARCHAR column

-- Step 1: Add new columns
ALTER TABLE items
ADD COLUMN IF NOT EXISTS brand_id UUID,
ADD COLUMN IF NOT EXISTS cylinder_weight cylinder_weight,
ADD COLUMN IF NOT EXISTS mouth_size mouth_size,
ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

-- Step 2: Add FK constraint for brand_id
ALTER TABLE items
ADD CONSTRAINT IF NOT EXISTS fk_items_brand_id
FOREIGN KEY (tenant_id, brand_id) REFERENCES lpg_brands(tenant_id, brand_id) ON DELETE SET NULL;

-- ── INDEXES ────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_lpg_brands_tenant_active
    ON lpg_brands(tenant_id, is_active);

CREATE INDEX IF NOT EXISTS idx_items_brand_id
    ON items(tenant_id, brand_id);

CREATE INDEX IF NOT EXISTS idx_items_cylinder_weight
    ON items(tenant_id, cylinder_weight);

CREATE INDEX IF NOT EXISTS idx_items_mouth_size
    ON items(tenant_id, mouth_size);

-- ── ROW LEVEL SECURITY ─────────────────────────────────────────────────────
ALTER TABLE lpg_brands ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "lpg_brands_tenant_select" ON lpg_brands;
CREATE POLICY "lpg_brands_tenant_select" ON lpg_brands FOR SELECT
    USING (tenant_id = my_tenant_id());

DROP POLICY IF EXISTS "lpg_brands_tenant_insert" ON lpg_brands;
CREATE POLICY "lpg_brands_tenant_insert" ON lpg_brands FOR INSERT
    WITH CHECK (tenant_id = my_tenant_id());

DROP POLICY IF EXISTS "lpg_brands_tenant_update" ON lpg_brands;
CREATE POLICY "lpg_brands_tenant_update" ON lpg_brands FOR UPDATE
    USING (tenant_id = my_tenant_id())
    WITH CHECK (tenant_id = my_tenant_id());

DROP POLICY IF EXISTS "lpg_brands_tenant_delete" ON lpg_brands;
CREATE POLICY "lpg_brands_tenant_delete" ON lpg_brands FOR DELETE
    USING (tenant_id = my_tenant_id());

-- ── AUDIT TRIGGER for lpg_brands ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION audit_lpg_brands()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_logs (tenant_id, table_name, record_id, action, old_data, new_data, performed_by)
    VALUES (
        NEW.tenant_id,
        'lpg_brands',
        NEW.brand_id,
        TG_OP,
        CASE WHEN TG_OP = 'UPDATE' THEN row_to_json(OLD) ELSE NULL END,
        row_to_json(NEW),
        auth.uid()
    );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_lpg_brands ON lpg_brands;
CREATE TRIGGER trg_audit_lpg_brands
    AFTER INSERT OR UPDATE OR DELETE ON lpg_brands
    FOR EACH ROW EXECUTE FUNCTION audit_lpg_brands();

-- ── RPC: Create/Update Brand ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION create_lpg_brand(
    p_brand_name TEXT,
    p_description TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tenant_id UUID;
    v_brand_id UUID;
BEGIN
    v_tenant_id := my_tenant_id();
    IF v_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated or no tenant found';
    END IF;

    INSERT INTO lpg_brands (tenant_id, brand_name, description)
    VALUES (v_tenant_id, p_brand_name, p_description)
    RETURNING brand_id INTO v_brand_id;

    RETURN jsonb_build_object(
        'brand_id', v_brand_id,
        'brand_name', p_brand_name,
        'description', p_description
    );
END;
$$;

GRANT EXECUTE ON FUNCTION create_lpg_brand(TEXT, TEXT) TO authenticated;

-- ── RPC: Update Brand ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION update_lpg_brand(
    p_brand_id UUID,
    p_brand_name TEXT DEFAULT NULL,
    p_description TEXT DEFAULT NULL,
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

    UPDATE lpg_brands
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
$$;

GRANT EXECUTE ON FUNCTION update_lpg_brand(UUID, TEXT, TEXT, BOOLEAN) TO authenticated;

-- ── RPC: List Brands ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION list_lpg_brands(p_active_only BOOLEAN DEFAULT true)
RETURNS TABLE (
    brand_id UUID,
    brand_name VARCHAR,
    description TEXT,
    is_active BOOLEAN,
    created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT
        b.brand_id,
        b.brand_name,
        b.description,
        b.is_active,
        b.created_at
    FROM lpg_brands b
    WHERE b.tenant_id = my_tenant_id()
      AND (NOT p_active_only OR b.is_active = true)
    ORDER BY b.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION list_lpg_brands(BOOLEAN) TO authenticated;
