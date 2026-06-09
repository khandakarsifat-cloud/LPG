-- =============================================================================
-- NexusLPG: Wallets and Transits Schema
-- =============================================================================

-- ── ENUMS ───────────────────────────────────────────────────────────────────
DO $$ BEGIN
    CREATE TYPE wallet_type AS ENUM ('dealership', 'logistics');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE transit_status AS ENUM ('active', 'completed', 'cancelled');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- ── TABLE: wallets ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS wallets (
    tenant_id    UUID        NOT NULL,
    wallet_id    UUID        NOT NULL DEFAULT uuid_generate_v4(),
    type         wallet_type NOT NULL,
    balance      NUMERIC(15,2) NOT NULL DEFAULT 0.00,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, wallet_id),
    UNIQUE (tenant_id, type),
    FOREIGN KEY (tenant_id) REFERENCES tenants(tenant_id) ON DELETE CASCADE
);

-- ── TABLE: wallet_transactions ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS wallet_transactions (
    tenant_id      UUID        NOT NULL,
    transaction_id UUID        NOT NULL DEFAULT uuid_generate_v4(),
    wallet_id      UUID        NOT NULL,
    amount         NUMERIC(15,2) NOT NULL,
    type           VARCHAR(50) NOT NULL, -- e.g., 'transport_fee', 'driver_cost', 'oil_cost'
    reference_id   UUID,                 -- transit_id, purchase_id, etc.
    description    TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, transaction_id),
    FOREIGN KEY (tenant_id, wallet_id) REFERENCES wallets(tenant_id, wallet_id) ON DELETE CASCADE
);

-- ── TABLE: transits ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS transits (
    tenant_id        UUID           NOT NULL,
    transit_id       UUID           NOT NULL DEFAULT uuid_generate_v4(),
    truck_id         UUID           NOT NULL,
    purchase_id      UUID,          -- NULL for custom transits
    status           transit_status NOT NULL DEFAULT 'active',
    driver_cost      NUMERIC(12,2)  DEFAULT 0.00,
    helper_cost      NUMERIC(12,2)  DEFAULT 0.00,
    oil_cost         NUMERIC(12,2)  DEFAULT 0.00,
    additional_costs JSONB          DEFAULT '[]'::jsonb, -- Array of {name, amount}
    total_cost       NUMERIC(12,2)  DEFAULT 0.00,
    created_at       TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, transit_id),
    FOREIGN KEY (tenant_id) REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, truck_id) REFERENCES trucks(tenant_id, truck_id) ON DELETE CASCADE
    -- Explicitly NOT enforcing foreign key to purchases here to allow custom transits and avoid cyclic issues
);

-- ── INDEXES ─────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_wallets_tenant ON wallets(tenant_id);
CREATE INDEX IF NOT EXISTS idx_wallet_transactions_wallet ON wallet_transactions(tenant_id, wallet_id);
CREATE INDEX IF NOT EXISTS idx_transits_tenant_truck ON transits(tenant_id, truck_id);
CREATE INDEX IF NOT EXISTS idx_transits_purchase ON transits(tenant_id, purchase_id);

-- ── ROW LEVEL SECURITY ──────────────────────────────────────────────────────
ALTER TABLE wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallet_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE transits ENABLE ROW LEVEL SECURITY;

-- Wallets
DROP POLICY IF EXISTS "wallets_select" ON wallets;
CREATE POLICY "wallets_select" ON wallets FOR SELECT USING (tenant_id = my_tenant_id());

-- Transactions
DROP POLICY IF EXISTS "wallet_transactions_select" ON wallet_transactions;
CREATE POLICY "wallet_transactions_select" ON wallet_transactions FOR SELECT USING (tenant_id = my_tenant_id());

-- Transits
DROP POLICY IF EXISTS "transits_select" ON transits;
CREATE POLICY "transits_select" ON transits FOR SELECT USING (tenant_id = my_tenant_id());
DROP POLICY IF EXISTS "transits_insert" ON transits;
CREATE POLICY "transits_insert" ON transits FOR INSERT WITH CHECK (tenant_id = my_tenant_id());
DROP POLICY IF EXISTS "transits_update" ON transits;
CREATE POLICY "transits_update" ON transits FOR UPDATE USING (tenant_id = my_tenant_id()) WITH CHECK (tenant_id = my_tenant_id());


-- ── HELPER: Ensure Wallets Exist ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION ensure_tenant_wallets(p_tenant_id UUID)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO wallets (tenant_id, type, balance)
    VALUES (p_tenant_id, 'dealership', 0.00)
    ON CONFLICT (tenant_id, type) DO NOTHING;

    INSERT INTO wallets (tenant_id, type, balance)
    VALUES (p_tenant_id, 'logistics', 0.00)
    ON CONFLICT (tenant_id, type) DO NOTHING;
END;
$$;


-- ── RPC: Update Transit Costs ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION update_transit_costs(
    p_transit_id UUID,
    p_driver_cost NUMERIC,
    p_helper_cost NUMERIC,
    p_oil_cost NUMERIC,
    p_additional_costs JSONB,
    p_status transit_status
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id      UUID := auth.uid();
    v_tenant_id    UUID;
    v_transit      RECORD;
    v_wallet_id    UUID;
    
    v_new_total    NUMERIC(12,2) := 0;
    v_cost_delta   NUMERIC(12,2) := 0;
    
    v_add_item     JSONB;
BEGIN
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
    SELECT tenant_id INTO v_tenant_id FROM user_profiles WHERE user_id = v_user_id;
    IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'No tenant found for user'; END IF;

    -- Ensure wallets exist
    PERFORM ensure_tenant_wallets(v_tenant_id);

    -- Get current transit
    SELECT * INTO v_transit FROM transits WHERE tenant_id = v_tenant_id AND transit_id = p_transit_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Transit not found'; END IF;

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

    v_cost_delta := v_new_total - COALESCE(v_transit.total_cost, 0);

    -- Update Transit record
    UPDATE transits 
    SET 
        driver_cost = p_driver_cost,
        helper_cost = p_helper_cost,
        oil_cost = p_oil_cost,
        additional_costs = p_additional_costs,
        total_cost = v_new_total,
        status = p_status,
        updated_at = NOW()
    WHERE transit_id = p_transit_id;

    -- Deduct from Logistics wallet if cost changed
    IF v_cost_delta <> 0 THEN
        SELECT wallet_id INTO v_wallet_id FROM wallets WHERE tenant_id = v_tenant_id AND type = 'logistics' FOR UPDATE;
        
        -- Negative amount for expense
        INSERT INTO wallet_transactions (tenant_id, wallet_id, amount, type, reference_id, description)
        VALUES (v_tenant_id, v_wallet_id, -v_cost_delta, 'transit_cost', p_transit_id, 'Transit cost adjustment');

        UPDATE wallets SET balance = balance - v_cost_delta, updated_at = NOW() WHERE wallet_id = v_wallet_id;
    END IF;
    
    -- If marked as completed and no linked purchase, we might want to free the truck.
    IF p_status = 'completed' AND v_transit.status <> 'completed' THEN
        -- Check if it's a standalone transit, or we can just make the truck idle.
        -- We make it idle.
        UPDATE trucks SET status = 'idle' WHERE truck_id = v_transit.truck_id AND tenant_id = v_tenant_id;
    END IF;

    RETURN jsonb_build_object('transit_id', p_transit_id, 'total_cost', v_new_total);
END;
$$;
GRANT EXECUTE ON FUNCTION update_transit_costs(UUID, NUMERIC, NUMERIC, NUMERIC, JSONB, transit_status) TO authenticated;


-- ── RPC: Create Custom Transit ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION create_custom_transit(
    p_truck_id UUID,
    p_notes TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id      UUID := auth.uid();
    v_tenant_id    UUID;
    v_transit_id   UUID;
BEGIN
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
    SELECT tenant_id INTO v_tenant_id FROM user_profiles WHERE user_id = v_user_id;

    -- Create Transit
    INSERT INTO transits (tenant_id, truck_id, status)
    VALUES (v_tenant_id, p_truck_id, 'active')
    RETURNING transit_id INTO v_transit_id;
    
    -- Update truck status
    UPDATE trucks SET status = 'going' WHERE truck_id = p_truck_id AND tenant_id = v_tenant_id;

    RETURN jsonb_build_object('transit_id', v_transit_id);
END;
$$;
GRANT EXECUTE ON FUNCTION create_custom_transit(UUID, TEXT) TO authenticated;


-- ── OVERRIDE: create_purchase (To integrate Transits & Wallets) ──────────────
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
    v_transit_id   UUID;
    v_wallet_id    UUID;
    v_item         JSONB;
    v_total_cost   NUMERIC(12,2) := 0.00;
    v_empty_stock  INT;
    v_item_total   NUMERIC(12,2);
BEGIN
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

    -- Derive tenant from user profile
    SELECT tenant_id INTO v_tenant_id FROM user_profiles WHERE user_id = v_user_id;
    IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'No tenant found for user'; END IF;

    -- Ensure wallets exist
    PERFORM ensure_tenant_wallets(v_tenant_id);

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

    -- 5. Create Transit
    INSERT INTO transits (tenant_id, truck_id, purchase_id, status)
    VALUES (v_tenant_id, p_truck_id, v_purchase_id, 'active')
    RETURNING transit_id INTO v_transit_id;

    -- 6. Credit transport cost to Logistics Wallet
    IF COALESCE(p_transport_cost, 0) > 0 THEN
        SELECT wallet_id INTO v_wallet_id FROM wallets WHERE tenant_id = v_tenant_id AND type = 'logistics' FOR UPDATE;
        
        INSERT INTO wallet_transactions (tenant_id, wallet_id, amount, type, reference_id, description)
        VALUES (v_tenant_id, v_wallet_id, p_transport_cost, 'transport_income', v_purchase_id, 'Transport fee for Purchase ' || v_purchase_id);

        UPDATE wallets SET balance = balance + p_transport_cost, updated_at = NOW() WHERE wallet_id = v_wallet_id;
    END IF;

    -- Dealership wallet expense could be recorded here, but for now we only process the logistics transport_fee

    RETURN jsonb_build_object(
        'purchase_id', v_purchase_id,
        'transit_id', v_transit_id,
        'total_cost', v_total_cost
    );
END;
$$;

-- Initialize wallets for any existing tenants safely
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT tenant_id FROM tenants LOOP
        PERFORM ensure_tenant_wallets(r.tenant_id);
    END LOOP;
END;
$$;
