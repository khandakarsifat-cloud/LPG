-- Migration: Consolidate Filled and Empty items and track stock directly in items table

-- 1. Drop old inventory balances and triggers
DROP TRIGGER IF EXISTS trg_update_inventory ON inventory_movements;
DROP FUNCTION IF EXISTS update_inventory_balance();
DROP TABLE IF EXISTS inventory_balances CASCADE;

-- 2. Alter items table
ALTER TABLE items
    DROP COLUMN IF EXISTS type CASCADE,
    ADD COLUMN IF NOT EXISTS filled_quantity INT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS empty_quantity INT NOT NULL DEFAULT 0;

-- 3. Alter inventory_movements
ALTER TABLE inventory_movements
    DROP COLUMN IF EXISTS quantity_change CASCADE,
    ADD COLUMN IF NOT EXISTS filled_quantity_change INT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS empty_quantity_change INT NOT NULL DEFAULT 0;

-- 4. Create new trigger to update items stock directly
CREATE OR REPLACE FUNCTION update_item_inventory()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE items
    SET 
        filled_quantity = filled_quantity + NEW.filled_quantity_change,
        empty_quantity = empty_quantity + NEW.empty_quantity_change,
        updated_at = NOW()
    WHERE tenant_id = NEW.tenant_id AND item_id = NEW.item_id;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_update_item_inventory
AFTER INSERT ON inventory_movements
FOR EACH ROW EXECUTE FUNCTION update_item_inventory();

-- 5. Alter price_books to include price_type
ALTER TABLE price_books
    ADD COLUMN IF NOT EXISTS price_type VARCHAR(50) DEFAULT 'refill' CHECK (price_type IN ('refill', 'package'));

ALTER TABLE price_books DROP CONSTRAINT IF EXISTS price_books_pkey CASCADE;

ALTER TABLE price_books 
    ADD PRIMARY KEY (tenant_id, item_id, customer_tier, price_type, effective_from);

-- 6. Replace create_inventory_movement RPC
DROP FUNCTION IF EXISTS create_inventory_movement(UUID, TEXT, INT, TEXT);

CREATE OR REPLACE FUNCTION create_inventory_movement(
    p_item_id       UUID,
    p_movement_type TEXT,
    p_filled_quantity_change INT,
    p_empty_quantity_change INT,
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
    v_movement_id UUID;
BEGIN
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

    -- Derive tenant from user profile
    SELECT tenant_id INTO v_tenant_id FROM user_profiles WHERE user_id = v_user_id;
    IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'No tenant found for user'; END IF;

    INSERT INTO inventory_movements
        (tenant_id, item_id, movement_type, filled_quantity_change, empty_quantity_change, notes, created_by)
    VALUES
        (v_tenant_id, p_item_id, p_movement_type, p_filled_quantity_change, p_empty_quantity_change, p_notes, v_user_id)
    RETURNING movement_id INTO v_movement_id;

    RETURN jsonb_build_object('movement_id', v_movement_id, 'filled_quantity_change', p_filled_quantity_change, 'empty_quantity_change', p_empty_quantity_change);
END;
$$;

GRANT EXECUTE ON FUNCTION create_inventory_movement(UUID, TEXT, INT, INT, TEXT) TO authenticated;
