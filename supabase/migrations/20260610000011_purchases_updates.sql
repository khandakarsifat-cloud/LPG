-- Migration: Purchase Updates and Completion

-- 1. RPC: Update Purchase (while in transit)
CREATE OR REPLACE FUNCTION update_purchase(
    p_purchase_id    UUID,
    p_transport_cost NUMERIC,
    p_labour_cost    NUMERIC,
    p_notes          TEXT,
    p_item_prices    JSONB  -- Array of {item_id, unit_price}
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id        UUID := auth.uid();
    v_tenant_id      UUID;
    v_purchase       RECORD;
    v_item           JSONB;
    v_item_total     NUMERIC(12,2);
    v_total_cost     NUMERIC(12,2) := 0.00;
    v_transport_diff NUMERIC(12,2);
    v_wallet_id      UUID;
BEGIN
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
    SELECT tenant_id INTO v_tenant_id FROM user_profiles WHERE user_id = v_user_id;

    -- Get current purchase
    SELECT * INTO v_purchase FROM purchases WHERE tenant_id = v_tenant_id AND purchase_id = p_purchase_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Purchase not found'; END IF;

    IF v_purchase.status <> 'in_transit' THEN
        RAISE EXCEPTION 'Purchase is no longer in transit and cannot be modified';
    END IF;

    -- Calculate transport cost difference
    v_transport_diff := COALESCE(p_transport_cost, 0) - COALESCE(v_purchase.transport_cost, 0);

    -- Base cost
    v_total_cost := COALESCE(p_transport_cost, 0) + COALESCE(p_labour_cost, 0);

    -- Update item prices and calculate new totals
    IF p_item_prices IS NOT NULL THEN
        FOR v_item IN SELECT * FROM jsonb_array_elements(p_item_prices)
        LOOP
            -- Update unit_price and line_total
            UPDATE purchase_items 
            SET unit_price = (v_item->>'unit_price')::NUMERIC,
                line_total = quantity * (v_item->>'unit_price')::NUMERIC
            WHERE tenant_id = v_tenant_id 
              AND purchase_id = p_purchase_id 
              AND item_id = (v_item->>'item_id')::UUID
            RETURNING line_total INTO v_item_total;

            IF FOUND THEN
                v_total_cost := v_total_cost + v_item_total;
            END IF;
        END LOOP;
    END IF;

    -- Now add remaining item totals that were NOT updated (just in case they didn't send all items)
    -- Actually, safer to just re-sum the whole purchase_items table for this purchase
    SELECT COALESCE(SUM(line_total), 0) INTO v_item_total
    FROM purchase_items
    WHERE tenant_id = v_tenant_id AND purchase_id = p_purchase_id;

    v_total_cost := COALESCE(p_transport_cost, 0) + COALESCE(p_labour_cost, 0) + v_item_total;

    -- Update purchase header
    UPDATE purchases 
    SET transport_cost = p_transport_cost,
        labour_cost = p_labour_cost,
        total_cost = v_total_cost,
        notes = p_notes,
        updated_at = NOW()
    WHERE tenant_id = v_tenant_id AND purchase_id = p_purchase_id;

    -- Adjust Logistics Wallet for transport cost change
    IF v_transport_diff <> 0 THEN
        SELECT wallet_id INTO v_wallet_id FROM wallets WHERE tenant_id = v_tenant_id AND type = 'logistics' FOR UPDATE;
        
        INSERT INTO wallet_transactions (tenant_id, wallet_id, amount, type, reference_id, description)
        VALUES (v_tenant_id, v_wallet_id, v_transport_diff, 'transport_income_adj', p_purchase_id, 'Transport fee adjustment for Purchase ' || p_purchase_id);

        UPDATE wallets SET balance = balance + v_transport_diff, updated_at = NOW() WHERE wallet_id = v_wallet_id;
    END IF;

    RETURN jsonb_build_object('purchase_id', p_purchase_id, 'total_cost', v_total_cost);
END;
$$;
GRANT EXECUTE ON FUNCTION update_purchase(UUID, NUMERIC, NUMERIC, TEXT, JSONB) TO authenticated;


-- 2. RPC: Complete Purchase
CREATE OR REPLACE FUNCTION complete_purchase(
    p_purchase_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id      UUID := auth.uid();
    v_tenant_id    UUID;
    v_purchase     RECORD;
    v_wallet_id    UUID;
    v_item         RECORD;
BEGIN
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
    SELECT tenant_id INTO v_tenant_id FROM user_profiles WHERE user_id = v_user_id;

    -- Get current purchase
    SELECT * INTO v_purchase FROM purchases WHERE tenant_id = v_tenant_id AND purchase_id = p_purchase_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Purchase not found'; END IF;

    IF v_purchase.status = 'received' THEN
        RAISE EXCEPTION 'Purchase is already completed';
    END IF;

    IF v_purchase.status = 'cancelled' THEN
        RAISE EXCEPTION 'Cannot complete a cancelled purchase';
    END IF;

    -- 1. Deduct total cost from Dealership Wallet
    IF v_purchase.total_cost > 0 THEN
        SELECT wallet_id INTO v_wallet_id FROM wallets WHERE tenant_id = v_tenant_id AND type = 'dealership' FOR UPDATE;
        
        INSERT INTO wallet_transactions (tenant_id, wallet_id, amount, type, reference_id, description)
        VALUES (v_tenant_id, v_wallet_id, -v_purchase.total_cost, 'purchase_expense', p_purchase_id, 'Payment for Purchase ' || p_purchase_id);

        UPDATE wallets SET balance = balance - v_purchase.total_cost, updated_at = NOW() WHERE wallet_id = v_wallet_id;
    END IF;

    -- 2. Add filled items to inventory
    FOR v_item IN SELECT * FROM purchase_items WHERE tenant_id = v_tenant_id AND purchase_id = p_purchase_id
    LOOP
        -- Add filled_quantity
        PERFORM create_inventory_movement(
            v_item.item_id,
            'purchase',
            v_item.quantity, -- filled_quantity_change
            0,               -- empty_quantity_change
            'Received goods from Purchase ' || p_purchase_id
        );
    END LOOP;

    -- 3. Update status
    UPDATE purchases SET status = 'received', updated_at = NOW() WHERE tenant_id = v_tenant_id AND purchase_id = p_purchase_id;

    RETURN jsonb_build_object('purchase_id', p_purchase_id, 'status', 'received');
END;
$$;
GRANT EXECUTE ON FUNCTION complete_purchase(UUID) TO authenticated;
