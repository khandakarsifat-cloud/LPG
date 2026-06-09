-- Migration: Custom Transit Fee & Cost Deduction on Completion

-- 1. Add transport_fee to transits
ALTER TABLE transits ADD COLUMN IF NOT EXISTS transport_fee NUMERIC(12,2) DEFAULT 0.00;

-- 2. Update create_custom_transit
CREATE OR REPLACE FUNCTION create_custom_transit(
    p_truck_id UUID,
    p_fee NUMERIC,
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
    v_wallet_id    UUID;
BEGIN
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
    SELECT tenant_id INTO v_tenant_id FROM user_profiles WHERE user_id = v_user_id;

    -- Ensure wallets exist
    PERFORM ensure_tenant_wallets(v_tenant_id);

    -- Create Transit
    INSERT INTO transits (tenant_id, truck_id, status, transport_fee)
    VALUES (v_tenant_id, p_truck_id, 'active', COALESCE(p_fee, 0))
    RETURNING transit_id INTO v_transit_id;
    
    -- Update truck status
    UPDATE trucks SET status = 'going' WHERE truck_id = p_truck_id AND tenant_id = v_tenant_id;

    -- Add fee to logistics wallet
    IF COALESCE(p_fee, 0) > 0 THEN
        SELECT wallet_id INTO v_wallet_id FROM wallets WHERE tenant_id = v_tenant_id AND type = 'logistics' FOR UPDATE;
        
        INSERT INTO wallet_transactions (tenant_id, wallet_id, amount, type, reference_id, description)
        VALUES (v_tenant_id, v_wallet_id, p_fee, 'transport_income', v_transit_id, 'Fee for custom transit');

        UPDATE wallets SET balance = balance + p_fee, updated_at = NOW() WHERE wallet_id = v_wallet_id;
    END IF;

    RETURN jsonb_build_object('transit_id', v_transit_id);
END;
$$;
GRANT EXECUTE ON FUNCTION create_custom_transit(UUID, NUMERIC, TEXT) TO authenticated;

-- Drop old function signature just in case
DROP FUNCTION IF EXISTS create_custom_transit(UUID, TEXT);


-- 3. Update update_transit_costs to deduct only on completion and lock if completed
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
    
    v_add_item     JSONB;
BEGIN
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
    SELECT tenant_id INTO v_tenant_id FROM user_profiles WHERE user_id = v_user_id;
    IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'No tenant found for user'; END IF;

    -- Get current transit
    SELECT * INTO v_transit FROM transits WHERE tenant_id = v_tenant_id AND transit_id = p_transit_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Transit not found'; END IF;

    -- Check if already completed
    IF v_transit.status = 'completed' THEN
        RAISE EXCEPTION 'Transit is already completed and locked. Costs cannot be updated.';
    END IF;

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

    -- IF transitioning to completed, deduct costs from logistics wallet
    IF p_status = 'completed' AND v_new_total > 0 THEN
        SELECT wallet_id INTO v_wallet_id FROM wallets WHERE tenant_id = v_tenant_id AND type = 'logistics' FOR UPDATE;
        
        -- Negative amount for expense
        INSERT INTO wallet_transactions (tenant_id, wallet_id, amount, type, reference_id, description)
        VALUES (v_tenant_id, v_wallet_id, -v_new_total, 'transit_cost', p_transit_id, 'Transit costs deduction upon completion');

        UPDATE wallets SET balance = balance - v_new_total, updated_at = NOW() WHERE wallet_id = v_wallet_id;
    END IF;
    
    -- If marked as completed, free the truck.
    IF p_status = 'completed' THEN
        UPDATE trucks SET status = 'idle' WHERE truck_id = v_transit.truck_id AND tenant_id = v_tenant_id;
    END IF;

    RETURN jsonb_build_object('transit_id', p_transit_id, 'total_cost', v_new_total);
END;
$$;
