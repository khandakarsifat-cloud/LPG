-- =============================================================================
-- NexusLPG: Gas Plants & Area Officers Schema
-- gas_plants: plant name, brand FK (company), location
-- area_officers: separate entity with FK → gas_plants (for future extensibility)
-- =============================================================================

-- ── TABLE: gas_plants ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS gas_plants (
    tenant_id    UUID          NOT NULL,
    plant_id     UUID          NOT NULL DEFAULT uuid_generate_v4(),
    plant_name   VARCHAR(200)  NOT NULL,
    brand_id     UUID,                              -- FK → lpg_brands (company)
    location     TEXT,
    is_active    BOOLEAN       NOT NULL DEFAULT true,
    created_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, plant_id),
    FOREIGN KEY (tenant_id) REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, brand_id) REFERENCES lpg_brands(tenant_id, brand_id) ON DELETE SET NULL,
    UNIQUE (tenant_id, plant_name)
);

-- ── TABLE: area_officers ──────────────────────────────────────────────────────
-- Kept separate from gas_plants with FK for future extensibility
CREATE TABLE IF NOT EXISTS area_officers (
    tenant_id      UUID          NOT NULL,
    officer_id     UUID          NOT NULL DEFAULT uuid_generate_v4(),
    plant_id       UUID          NOT NULL,          -- FK → gas_plants
    officer_name   VARCHAR(200)  NOT NULL,
    whatsapp_phone VARCHAR(30),
    email          VARCHAR(255),
    created_at     TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, officer_id),
    FOREIGN KEY (tenant_id) REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, plant_id) REFERENCES gas_plants(tenant_id, plant_id) ON DELETE CASCADE
);

-- ── INDEXES ───────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_gas_plants_tenant_active
    ON gas_plants(tenant_id, is_active);

CREATE INDEX IF NOT EXISTS idx_gas_plants_brand
    ON gas_plants(tenant_id, brand_id);

CREATE INDEX IF NOT EXISTS idx_area_officers_plant
    ON area_officers(tenant_id, plant_id);

-- ── ROW LEVEL SECURITY: gas_plants ───────────────────────────────────────────
ALTER TABLE gas_plants ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "gas_plants_tenant_select" ON gas_plants;
CREATE POLICY "gas_plants_tenant_select" ON gas_plants FOR SELECT
    USING (tenant_id = my_tenant_id());

DROP POLICY IF EXISTS "gas_plants_tenant_insert" ON gas_plants;
CREATE POLICY "gas_plants_tenant_insert" ON gas_plants FOR INSERT
    WITH CHECK (tenant_id = my_tenant_id());

DROP POLICY IF EXISTS "gas_plants_tenant_update" ON gas_plants;
CREATE POLICY "gas_plants_tenant_update" ON gas_plants FOR UPDATE
    USING (tenant_id = my_tenant_id())
    WITH CHECK (tenant_id = my_tenant_id());

DROP POLICY IF EXISTS "gas_plants_tenant_delete" ON gas_plants;
CREATE POLICY "gas_plants_tenant_delete" ON gas_plants FOR DELETE
    USING (tenant_id = my_tenant_id());

-- ── ROW LEVEL SECURITY: area_officers ────────────────────────────────────────
ALTER TABLE area_officers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "area_officers_tenant_select" ON area_officers;
CREATE POLICY "area_officers_tenant_select" ON area_officers FOR SELECT
    USING (tenant_id = my_tenant_id());

DROP POLICY IF EXISTS "area_officers_tenant_insert" ON area_officers;
CREATE POLICY "area_officers_tenant_insert" ON area_officers FOR INSERT
    WITH CHECK (tenant_id = my_tenant_id());

DROP POLICY IF EXISTS "area_officers_tenant_update" ON area_officers;
CREATE POLICY "area_officers_tenant_update" ON area_officers FOR UPDATE
    USING (tenant_id = my_tenant_id())
    WITH CHECK (tenant_id = my_tenant_id());

DROP POLICY IF EXISTS "area_officers_tenant_delete" ON area_officers;
CREATE POLICY "area_officers_tenant_delete" ON area_officers FOR DELETE
    USING (tenant_id = my_tenant_id());

-- =============================================================================
-- RPC: list_gas_plants — returns plants joined with brand name and officer info
-- =============================================================================
CREATE OR REPLACE FUNCTION list_gas_plants(p_active_only BOOLEAN DEFAULT false)
RETURNS TABLE (
    plant_id       UUID,
    plant_name     VARCHAR,
    brand_id       UUID,
    brand_name     VARCHAR,
    location       TEXT,
    is_active      BOOLEAN,
    created_at     TIMESTAMPTZ,
    updated_at     TIMESTAMPTZ,
    officer_id     UUID,
    officer_name   VARCHAR,
    whatsapp_phone VARCHAR,
    email          VARCHAR
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
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
    FROM gas_plants gp
    LEFT JOIN lpg_brands lb
        ON lb.tenant_id = gp.tenant_id AND lb.brand_id = gp.brand_id
    LEFT JOIN area_officers ao
        ON ao.tenant_id = gp.tenant_id AND ao.plant_id = gp.plant_id
    WHERE gp.tenant_id = my_tenant_id()
      AND (NOT p_active_only OR gp.is_active = true)
    ORDER BY gp.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION list_gas_plants(BOOLEAN) TO authenticated;

-- =============================================================================
-- RPC: create_gas_plant
-- =============================================================================
CREATE OR REPLACE FUNCTION create_gas_plant(
    p_plant_name TEXT,
    p_brand_id   UUID    DEFAULT NULL,
    p_location   TEXT    DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tenant_id UUID;
    v_plant_id  UUID;
BEGIN
    v_tenant_id := my_tenant_id();
    IF v_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated or no tenant found';
    END IF;

    INSERT INTO gas_plants (tenant_id, plant_name, brand_id, location)
    VALUES (v_tenant_id, p_plant_name, p_brand_id, p_location)
    RETURNING plant_id INTO v_plant_id;

    RETURN jsonb_build_object(
        'plant_id',   v_plant_id,
        'plant_name', p_plant_name
    );
END;
$$;

GRANT EXECUTE ON FUNCTION create_gas_plant(TEXT, UUID, TEXT) TO authenticated;

-- =============================================================================
-- RPC: update_gas_plant
-- =============================================================================
CREATE OR REPLACE FUNCTION update_gas_plant(
    p_plant_id   UUID,
    p_plant_name TEXT    DEFAULT NULL,
    p_brand_id   UUID    DEFAULT NULL,
    p_location   TEXT    DEFAULT NULL,
    p_is_active  BOOLEAN DEFAULT NULL
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

    UPDATE gas_plants
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
$$;

GRANT EXECUTE ON FUNCTION update_gas_plant(UUID, TEXT, UUID, TEXT, BOOLEAN) TO authenticated;

-- =============================================================================
-- RPC: create_area_officer
-- =============================================================================
CREATE OR REPLACE FUNCTION create_area_officer(
    p_plant_id       UUID,
    p_officer_name   TEXT,
    p_whatsapp_phone TEXT DEFAULT NULL,
    p_email          TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tenant_id UUID;
    v_officer_id UUID;
BEGIN
    v_tenant_id := my_tenant_id();
    IF v_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated or no tenant found';
    END IF;

    -- Verify the plant belongs to this tenant
    IF NOT EXISTS (
        SELECT 1 FROM gas_plants
        WHERE tenant_id = v_tenant_id AND plant_id = p_plant_id
    ) THEN
        RAISE EXCEPTION 'Gas plant not found';
    END IF;

    INSERT INTO area_officers (tenant_id, plant_id, officer_name, whatsapp_phone, email)
    VALUES (v_tenant_id, p_plant_id, p_officer_name, p_whatsapp_phone, p_email)
    RETURNING officer_id INTO v_officer_id;

    RETURN jsonb_build_object(
        'officer_id',   v_officer_id,
        'officer_name', p_officer_name
    );
END;
$$;

GRANT EXECUTE ON FUNCTION create_area_officer(UUID, TEXT, TEXT, TEXT) TO authenticated;

-- =============================================================================
-- RPC: update_area_officer
-- =============================================================================
CREATE OR REPLACE FUNCTION update_area_officer(
    p_officer_id     UUID,
    p_officer_name   TEXT DEFAULT NULL,
    p_whatsapp_phone TEXT DEFAULT NULL,
    p_email          TEXT DEFAULT NULL
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

    UPDATE area_officers
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
$$;

GRANT EXECUTE ON FUNCTION update_area_officer(UUID, TEXT, TEXT, TEXT) TO authenticated;
