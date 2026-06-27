-- =============================================================================
-- NexusLPG: Sales / POS Schema
-- =============================================================================

-- 1. Alter customers table to include shop_name, phone, address
ALTER TABLE customers
    ADD COLUMN IF NOT EXISTS shop_name VARCHAR(255),
    ADD COLUMN IF NOT EXISTS phone VARCHAR(50),
    ADD COLUMN IF NOT EXISTS address TEXT;

-- 2. ENUM for sale status and sale item types
DO $$ BEGIN
    CREATE TYPE sale_status AS ENUM ('completed', 'voided');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE sale_item_type AS ENUM ('refill', 'package', 'empty_return');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- 3. TABLE: sales
CREATE TABLE IF NOT EXISTS sales (
    tenant_id       UUID            NOT NULL,
    sale_id         UUID            NOT NULL DEFAULT uuid_generate_v4(),
    customer_id     UUID            NOT NULL,
    status          sale_status     NOT NULL DEFAULT 'completed',
    subtotal        NUMERIC(12,2)   NOT NULL DEFAULT 0.00,
    discount_amount NUMERIC(12,2)   NOT NULL DEFAULT 0.00,
    exchange_fee    NUMERIC(12,2)   NOT NULL DEFAULT 0.00,
    total_amount    NUMERIC(12,2)   NOT NULL DEFAULT 0.00,
    notes           TEXT,
    created_by      UUID            REFERENCES user_profiles(user_id),
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, sale_id),
    FOREIGN KEY (tenant_id) REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, customer_id) REFERENCES customers(tenant_id, customer_id)
);

-- 4. TABLE: sale_items
CREATE TABLE IF NOT EXISTS sale_items (
    tenant_id       UUID            NOT NULL,
    sale_item_id    UUID            NOT NULL DEFAULT uuid_generate_v4(),
    sale_id         UUID            NOT NULL,
    item_id         UUID            NOT NULL,
    type            sale_item_type  NOT NULL,
    quantity        INT             NOT NULL CHECK (quantity > 0),
    unit_price      NUMERIC(12,2)   NOT NULL DEFAULT 0.00,
    line_total      NUMERIC(12,2)   NOT NULL DEFAULT 0.00,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, sale_item_id),
    FOREIGN KEY (tenant_id, sale_id) REFERENCES sales(tenant_id, sale_id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, item_id) REFERENCES items(tenant_id, item_id)
);

-- 5. INDEXES
CREATE INDEX IF NOT EXISTS idx_sales_tenant_date ON sales(tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sale_items_sale ON sale_items(tenant_id, sale_id);

-- 6. ROW LEVEL SECURITY
ALTER TABLE sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE sale_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "sales_tenant_select" ON sales;
CREATE POLICY "sales_tenant_select" ON sales FOR SELECT USING (tenant_id = my_tenant_id());

DROP POLICY IF EXISTS "sales_tenant_insert" ON sales;
CREATE POLICY "sales_tenant_insert" ON sales FOR INSERT WITH CHECK (tenant_id = my_tenant_id());

DROP POLICY IF EXISTS "sales_tenant_update" ON sales;
CREATE POLICY "sales_tenant_update" ON sales FOR UPDATE USING (tenant_id = my_tenant_id()) WITH CHECK (tenant_id = my_tenant_id());

DROP POLICY IF EXISTS "sale_items_tenant_select" ON sale_items;
CREATE POLICY "sale_items_tenant_select" ON sale_items FOR SELECT USING (tenant_id = my_tenant_id());

DROP POLICY IF EXISTS "sale_items_tenant_insert" ON sale_items;
CREATE POLICY "sale_items_tenant_insert" ON sale_items FOR INSERT WITH CHECK (tenant_id = my_tenant_id());


-- 7. RPC: Create POS Sale
CREATE OR REPLACE FUNCTION create_pos_sale(
    p_customer_phone VARCHAR,
    p_customer_name VARCHAR,
    p_customer_shop_name VARCHAR,
    p_customer_address TEXT,
    p_customer_tier VARCHAR, -- 'retail' or 'wholesale'
    p_discount_amount NUMERIC,
    p_exchange_fee NUMERIC,
    p_notes TEXT,
    p_items JSONB -- Array of {item_id, type, quantity, unit_price}
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id      UUID := auth.uid();
    v_tenant_id    UUID;
    v_customer_id  UUID;
    v_sale_id      UUID;
    v_item         JSONB;
    v_subtotal     NUMERIC(12,2) := 0.00;
    v_total_amount NUMERIC(12,2) := 0.00;
    v_item_total   NUMERIC(12,2);
    v_total_refills INT := 0;
    v_total_empties INT := 0;
    v_filled_qty_change INT;
    v_empty_qty_change INT;
    v_filled_stock INT;
BEGIN
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

    -- Derive tenant
    SELECT tenant_id INTO v_tenant_id FROM user_profiles WHERE user_id = v_user_id;
    IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'No tenant found for user'; END IF;

    -- Customer resolution logic
    IF p_customer_phone IS NOT NULL AND TRIM(p_customer_phone) != '' THEN
        -- Try to find existing customer by phone
        SELECT customer_id INTO v_customer_id 
        FROM customers 
        WHERE tenant_id = v_tenant_id AND phone = p_customer_phone 
        LIMIT 1;

        -- If not found, create one
        IF v_customer_id IS NULL THEN
            INSERT INTO customers (tenant_id, name, phone, shop_name, address, tier)
            VALUES (v_tenant_id, COALESCE(p_customer_name, 'Unknown'), p_customer_phone, p_customer_shop_name, p_customer_address, COALESCE(p_customer_tier, 'retail'))
            RETURNING customer_id INTO v_customer_id;
        END IF;
    ELSE
        -- No phone provided, create a generic walk-in or anonymous customer for this transaction
        INSERT INTO customers (tenant_id, name, shop_name, address, tier)
        VALUES (v_tenant_id, COALESCE(p_customer_name, 'Walk-in Customer'), p_customer_shop_name, p_customer_address, COALESCE(p_customer_tier, 'retail'))
        RETURNING customer_id INTO v_customer_id;
    END IF;

    -- Pre-calculate refills and empties for validation
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        IF (v_item->>'type') = 'refill' THEN
            v_total_refills := v_total_refills + (v_item->>'quantity')::INT;
        ELSIF (v_item->>'type') = 'empty_return' THEN
            v_total_empties := v_total_empties + (v_item->>'quantity')::INT;
        END IF;
    END LOOP;

    -- Validate equal empty bottles for refills
    IF v_total_refills != v_total_empties THEN
        RAISE EXCEPTION 'Total refills (%) must equal total empty bottles returned (%)', v_total_refills, v_total_empties;
    END IF;

    -- Create sale header
    INSERT INTO sales (tenant_id, customer_id, status, discount_amount, exchange_fee, notes, created_by)
    VALUES (v_tenant_id, v_customer_id, 'completed', COALESCE(p_discount_amount, 0), COALESCE(p_exchange_fee, 0), p_notes, v_user_id)
    RETURNING sale_id INTO v_sale_id;

    -- Process items
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        v_item_total := (v_item->>'quantity')::INT * (v_item->>'unit_price')::NUMERIC;
        v_subtotal := v_subtotal + v_item_total;

        v_filled_qty_change := 0;
        v_empty_qty_change := 0;

        IF (v_item->>'type') = 'refill' THEN
            -- Deduct filled gas
            v_filled_qty_change := -((v_item->>'quantity')::INT);
        ELSIF (v_item->>'type') = 'package' THEN
            -- Deduct both filled gas and empty cylinder
            v_filled_qty_change := -((v_item->>'quantity')::INT);
            v_empty_qty_change := -((v_item->>'quantity')::INT);
        ELSIF (v_item->>'type') = 'empty_return' THEN
            -- Add to empty cylinders
            v_empty_qty_change := (v_item->>'quantity')::INT;
        END IF;

        -- Check stock before sale
        IF v_filled_qty_change < 0 THEN
            SELECT filled_quantity INTO v_filled_stock 
            FROM items 
            WHERE tenant_id = v_tenant_id AND item_id = (v_item->>'item_id')::UUID;

            IF v_filled_stock < ABS(v_filled_qty_change) THEN
                RAISE EXCEPTION 'Insufficient filled stock for item %', (v_item->>'item_id');
            END IF;
        END IF;

        -- Create inventory movement
        IF v_filled_qty_change != 0 OR v_empty_qty_change != 0 THEN
            PERFORM create_inventory_movement(
                (v_item->>'item_id')::UUID,
                'sale',
                v_filled_qty_change,
                v_empty_qty_change,
                'POS Sale ' || v_sale_id
            );
        END IF;

        -- Insert sale item
        INSERT INTO sale_items (tenant_id, sale_id, item_id, type, quantity, unit_price, line_total)
        VALUES (v_tenant_id, v_sale_id, (v_item->>'item_id')::UUID, (v_item->>'type')::sale_item_type, (v_item->>'quantity')::INT, (v_item->>'unit_price')::NUMERIC, v_item_total);

    END LOOP;

    -- Finalize totals
    v_total_amount := v_subtotal - COALESCE(p_discount_amount, 0) + COALESCE(p_exchange_fee, 0);

    UPDATE sales 
    SET subtotal = v_subtotal, total_amount = v_total_amount 
    WHERE sale_id = v_sale_id;

    -- Record in customer_transactions ledger
    INSERT INTO customer_transactions (tenant_id, customer_id, type, amount, reference_id, created_by)
    VALUES (v_tenant_id, v_customer_id, 'invoice_charge', -v_total_amount, v_sale_id, v_user_id);
    
    INSERT INTO customer_transactions (tenant_id, customer_id, type, amount, reference_id, created_by)
    VALUES (v_tenant_id, v_customer_id, 'payment_receipt', v_total_amount, v_sale_id, v_user_id);

    -- Update Dealership Wallet
    PERFORM ensure_tenant_wallets(v_tenant_id);
    UPDATE wallets 
    SET balance = balance + v_total_amount, updated_at = NOW() 
    WHERE tenant_id = v_tenant_id AND type = 'dealership';

    RETURN jsonb_build_object(
        'sale_id', v_sale_id,
        'customer_id', v_customer_id,
        'subtotal', v_subtotal,
        'total_amount', v_total_amount
    );
END;
$$;

GRANT EXECUTE ON FUNCTION create_pos_sale(VARCHAR, VARCHAR, VARCHAR, TEXT, VARCHAR, NUMERIC, NUMERIC, TEXT, JSONB) TO authenticated;
