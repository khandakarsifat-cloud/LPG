-- =============================================================================
-- NexusLPG: Purchases Schema
-- =============================================================================

-- ── ENUMS ───────────────────────────────────────────────────────────────────
DO $$ BEGIN
    CREATE TYPE purchase_status AS ENUM ('in_transit', 'received', 'cancelled');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE purchase_type AS ENUM ('refill', 'package');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- ── TABLE: purchases ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS purchases (
    tenant_id      UUID            NOT NULL,
    purchase_id    UUID            NOT NULL DEFAULT uuid_generate_v4(),
    truck_id       UUID            NOT NULL,
    plant_id       UUID            NOT NULL,
    status         purchase_status NOT NULL DEFAULT 'in_transit',
    transport_cost NUMERIC(12,2)   DEFAULT 0.00,
    labour_cost    NUMERIC(12,2)   DEFAULT 0.00,
    total_cost     NUMERIC(12,2)   NOT NULL DEFAULT 0.00,
    notes          TEXT,
    created_by     UUID            REFERENCES user_profiles(user_id),
    created_at     TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, purchase_id),
    FOREIGN KEY (tenant_id) REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, truck_id) REFERENCES trucks(tenant_id, truck_id),
    FOREIGN KEY (tenant_id, plant_id) REFERENCES gas_plants(tenant_id, plant_id)
);

-- ── TABLE: purchase_items ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS purchase_items (
    tenant_id        UUID          NOT NULL,
    purchase_item_id UUID          NOT NULL DEFAULT uuid_generate_v4(),
    purchase_id      UUID          NOT NULL,
    item_id          UUID          NOT NULL,
    type             purchase_type NOT NULL,
    quantity         INT           NOT NULL CHECK (quantity > 0),
    unit_price       NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    line_total       NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    created_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, purchase_item_id),
    FOREIGN KEY (tenant_id, purchase_id) REFERENCES purchases(tenant_id, purchase_id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, item_id) REFERENCES items(tenant_id, item_id)
);

-- ── INDEXES ─────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_purchases_tenant_status ON purchases(tenant_id, status);
CREATE INDEX IF NOT EXISTS idx_purchases_tenant_date ON purchases(tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_purchase_items_purchase ON purchase_items(tenant_id, purchase_id);

-- ── ROW LEVEL SECURITY ──────────────────────────────────────────────────────
ALTER TABLE purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchase_items ENABLE ROW LEVEL SECURITY;

-- Purchases policies
DROP POLICY IF EXISTS "purchases_tenant_select" ON purchases;
CREATE POLICY "purchases_tenant_select" ON purchases FOR SELECT USING (tenant_id = my_tenant_id());

DROP POLICY IF EXISTS "purchases_tenant_insert" ON purchases;
CREATE POLICY "purchases_tenant_insert" ON purchases FOR INSERT WITH CHECK (tenant_id = my_tenant_id());

DROP POLICY IF EXISTS "purchases_tenant_update" ON purchases;
CREATE POLICY "purchases_tenant_update" ON purchases FOR UPDATE USING (tenant_id = my_tenant_id()) WITH CHECK (tenant_id = my_tenant_id());

-- Purchase Items policies
DROP POLICY IF EXISTS "purchase_items_tenant_select" ON purchase_items;
CREATE POLICY "purchase_items_tenant_select" ON purchase_items FOR SELECT USING (tenant_id = my_tenant_id());

DROP POLICY IF EXISTS "purchase_items_tenant_insert" ON purchase_items;
CREATE POLICY "purchase_items_tenant_insert" ON purchase_items FOR INSERT WITH CHECK (tenant_id = my_tenant_id());

-- ── RPC: Create Purchase ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION create_purchase(
    p_truck_id       UUID,
    p_plant_id       UUID,
    p_transport_cost NUMERIC,
    p_labour_cost    NUMERIC,
    p_notes          TEXT,
    p_items          JSONB  -- Array of {item_id, type, quantity, unit_price}
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id      UUID := auth.uid();
    v_tenant_id    UUID;
    v_purchase_id  UUID;
    v_item         JSONB;
    v_total_cost   NUMERIC(12,2) := 0.00;
    v_empty_stock  INT;
    v_item_total   NUMERIC(12,2);
BEGIN
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

    -- Derive tenant from user profile
    SELECT tenant_id INTO v_tenant_id FROM user_profiles WHERE user_id = v_user_id;
    IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'No tenant found for user'; END IF;

    -- 1. Create the purchase header
    INSERT INTO purchases (tenant_id, truck_id, plant_id, status, transport_cost, labour_cost, notes, created_by)
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
            FROM items 
            WHERE tenant_id = v_tenant_id AND item_id = (v_item->>'item_id')::UUID;

            IF v_empty_stock < (v_item->>'quantity')::INT THEN
                RAISE EXCEPTION 'Insufficient empty stock for item %', (v_item->>'item_id');
            END IF;

            -- Create inventory movement for empty deduction
            PERFORM create_inventory_movement(
                (v_item->>'item_id')::UUID,
                'purchase',
                0, -- filled_quantity_change (will be added when received)
                -((v_item->>'quantity')::INT), -- deduct empty
                'Empty bottles sent for refill (Purchase ' || v_purchase_id || ')'
            );
        END IF;

        -- Insert purchase item
        INSERT INTO purchase_items (tenant_id, purchase_id, item_id, type, quantity, unit_price, line_total)
        VALUES (v_tenant_id, v_purchase_id, (v_item->>'item_id')::UUID, (v_item->>'type')::purchase_type, (v_item->>'quantity')::INT, (v_item->>'unit_price')::NUMERIC, v_item_total);

    END LOOP;

    -- 3. Update purchase total cost
    UPDATE purchases SET total_cost = v_total_cost WHERE purchase_id = v_purchase_id;

    -- 4. Update truck status to 'going'
    UPDATE trucks SET status = 'going' WHERE truck_id = p_truck_id AND tenant_id = v_tenant_id;

    RETURN jsonb_build_object(
        'purchase_id', v_purchase_id,
        'total_cost', v_total_cost
    );
END;
$$;

GRANT EXECUTE ON FUNCTION create_purchase(UUID, UUID, NUMERIC, NUMERIC, TEXT, JSONB) TO authenticated;

-- ── RPC: List Purchases ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION list_purchases()
RETURNS TABLE (
    purchase_id    UUID,
    truck_id       UUID,
    truck_name     VARCHAR,
    plant_id       UUID,
    plant_name     VARCHAR,
    status         purchase_status,
    transport_cost NUMERIC,
    labour_cost    NUMERIC,
    total_cost     NUMERIC,
    notes          TEXT,
    created_at     TIMESTAMPTZ,
    items          JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
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
            FROM purchase_items pi
            JOIN items i ON pi.item_id = i.item_id
            LEFT JOIN lpg_brands b ON i.brand_id = b.brand_id
            WHERE pi.purchase_id = p.purchase_id
        ) AS items
    FROM purchases p
    LEFT JOIN trucks t ON p.truck_id = t.truck_id
    LEFT JOIN gas_plants gp ON p.plant_id = gp.plant_id
    WHERE p.tenant_id = my_tenant_id()
    ORDER BY p.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION list_purchases() TO authenticated;
