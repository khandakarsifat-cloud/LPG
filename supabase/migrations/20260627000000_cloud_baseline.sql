


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE TYPE "public"."cylinder_weight" AS ENUM (
    '5kg',
    '12kg',
    '25kg',
    '35kg'
);


ALTER TYPE "public"."cylinder_weight" OWNER TO "postgres";


CREATE TYPE "public"."mouth_size" AS ENUM (
    '20mm',
    '22mm'
);


ALTER TYPE "public"."mouth_size" OWNER TO "postgres";


CREATE TYPE "public"."purchase_status" AS ENUM (
    'in_transit',
    'received',
    'cancelled'
);


ALTER TYPE "public"."purchase_status" OWNER TO "postgres";


CREATE TYPE "public"."purchase_type" AS ENUM (
    'refill',
    'package'
);


ALTER TYPE "public"."purchase_type" OWNER TO "postgres";


CREATE TYPE "public"."sale_item_type" AS ENUM (
    'refill',
    'package',
    'empty_return'
);


ALTER TYPE "public"."sale_item_type" OWNER TO "postgres";


CREATE TYPE "public"."sale_status" AS ENUM (
    'completed',
    'voided'
);


ALTER TYPE "public"."sale_status" OWNER TO "postgres";


CREATE TYPE "public"."transit_status" AS ENUM (
    'active',
    'completed',
    'cancelled'
);


ALTER TYPE "public"."transit_status" OWNER TO "postgres";


CREATE TYPE "public"."truck_size" AS ENUM (
    'big',
    'medium',
    'small'
);


ALTER TYPE "public"."truck_size" OWNER TO "postgres";


CREATE TYPE "public"."truck_status" AS ENUM (
    'idle',
    'coming',
    'going'
);


ALTER TYPE "public"."truck_status" OWNER TO "postgres";


CREATE TYPE "public"."wallet_type" AS ENUM (
    'dealership',
    'logistics'
);


ALTER TYPE "public"."wallet_type" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."audit_lpg_brands"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
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


ALTER FUNCTION "public"."audit_lpg_brands"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."audit_trucks"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
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


ALTER FUNCTION "public"."audit_trucks"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."complete_purchase"("p_purchase_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."complete_purchase"("p_purchase_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_area_officer"("p_plant_id" "uuid", "p_officer_name" "text", "p_whatsapp_phone" "text" DEFAULT NULL::"text", "p_email" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."create_area_officer"("p_plant_id" "uuid", "p_officer_name" "text", "p_whatsapp_phone" "text", "p_email" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_custom_transit"("p_truck_id" "uuid", "p_fee" numeric, "p_notes" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."create_custom_transit"("p_truck_id" "uuid", "p_fee" numeric, "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_gas_plant"("p_plant_name" "text", "p_brand_id" "uuid" DEFAULT NULL::"uuid", "p_location" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."create_gas_plant"("p_plant_name" "text", "p_brand_id" "uuid", "p_location" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_inventory_movement"("p_item_id" "uuid", "p_movement_type" "text", "p_filled_quantity_change" integer, "p_empty_quantity_change" integer, "p_notes" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."create_inventory_movement"("p_item_id" "uuid", "p_movement_type" "text", "p_filled_quantity_change" integer, "p_empty_quantity_change" integer, "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_lpg_brand"("p_brand_name" "text", "p_description" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."create_lpg_brand"("p_brand_name" "text", "p_description" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_pos_sale"("p_customer_phone" character varying, "p_customer_name" character varying, "p_customer_shop_name" character varying, "p_customer_address" "text", "p_customer_tier" character varying, "p_discount_amount" numeric, "p_exchange_fee" numeric, "p_notes" "text", "p_items" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_user_id      UUID := auth.uid();
    v_tenant_id    UUID;
    v_customer_id  UUID;
    v_sale_id      UUID;
    v_item         JSONB;
    v_subtotal     NUMERIC(12,2) := 0.00;
    v_total_amount NUMERIC(12,2);
    v_item_total   NUMERIC(12,2);
    v_total_refills INT := 0;
    v_total_empties INT := 0;
    v_filled_qty_change INT;
    v_empty_qty_change  INT;
    v_filled_stock      INT;
BEGIN
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

    SELECT tenant_id INTO v_tenant_id FROM user_profiles WHERE user_id = v_user_id;
    IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'No tenant found for user'; END IF;

    -- REQUIRE customer phone
    IF p_customer_phone IS NULL OR TRIM(p_customer_phone) = '' THEN
        RAISE EXCEPTION 'Customer phone number is required to complete a sale';
    END IF;

    -- Upsert customer (ON CONFLICT on plain unique index)
    INSERT INTO customers (tenant_id, name, phone, shop_name, address, tier)
    VALUES (
        v_tenant_id,
        COALESCE(NULLIF(TRIM(p_customer_name), ''), 'Unknown'),
        TRIM(p_customer_phone),
        NULLIF(TRIM(COALESCE(p_customer_shop_name, '')), ''),
        NULLIF(TRIM(COALESCE(p_customer_address, '')), ''),
        COALESCE(p_customer_tier, 'retail')
    )
    ON CONFLICT (tenant_id, phone)
    DO UPDATE SET
        name      = CASE WHEN NULLIF(TRIM(EXCLUDED.name), '') IS NOT NULL AND EXCLUDED.name != 'Unknown'
                         THEN EXCLUDED.name ELSE customers.name END,
        shop_name = COALESCE(EXCLUDED.shop_name, customers.shop_name),
        address   = COALESCE(EXCLUDED.address, customers.address),
        tier      = EXCLUDED.tier
    RETURNING customer_id INTO v_customer_id;

    -- Validate refills = empties
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        IF (v_item->>'type') = 'refill' THEN
            v_total_refills := v_total_refills + (v_item->>'quantity')::INT;
        ELSIF (v_item->>'type') = 'empty_return' THEN
            v_total_empties := v_total_empties + (v_item->>'quantity')::INT;
        END IF;
    END LOOP;

    IF v_total_refills != v_total_empties THEN
        RAISE EXCEPTION 'Refill count (%) must equal empty bottle return count (%)', v_total_refills, v_total_empties;
    END IF;

    IF jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'Cart cannot be empty';
    END IF;

    -- Create sale header
    INSERT INTO sales (tenant_id, customer_id, status, discount_amount, exchange_fee, notes, created_by)
    VALUES (v_tenant_id, v_customer_id, 'completed',
            COALESCE(p_discount_amount, 0), COALESCE(p_exchange_fee, 0), p_notes, v_user_id)
    RETURNING sale_id INTO v_sale_id;

    -- Process line items
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        v_item_total := (v_item->>'quantity')::INT * (v_item->>'unit_price')::NUMERIC;
        v_subtotal   := v_subtotal + v_item_total;

        v_filled_qty_change := 0;
        v_empty_qty_change  := 0;

        IF (v_item->>'type') = 'refill' THEN
            v_filled_qty_change := -((v_item->>'quantity')::INT);
        ELSIF (v_item->>'type') = 'package' THEN
            v_filled_qty_change := -((v_item->>'quantity')::INT);
            v_empty_qty_change  := -((v_item->>'quantity')::INT);
        ELSIF (v_item->>'type') = 'empty_return' THEN
            v_empty_qty_change := (v_item->>'quantity')::INT;
        END IF;

        -- Stock check
        IF v_filled_qty_change < 0 THEN
            SELECT filled_quantity INTO v_filled_stock
            FROM items
            WHERE tenant_id = v_tenant_id AND item_id = (v_item->>'item_id')::UUID;

            IF v_filled_stock < ABS(v_filled_qty_change) THEN
                RAISE EXCEPTION 'Insufficient filled stock for item %', (v_item->>'item_id');
            END IF;
        END IF;

        -- Write inventory movement directly (inline, no nested function call)
        IF v_filled_qty_change != 0 OR v_empty_qty_change != 0 THEN
            INSERT INTO inventory_movements
                (tenant_id, item_id, movement_type, reference_type, reference_id,
                 filled_quantity_change, empty_quantity_change, notes, created_by)
            VALUES
                (v_tenant_id, (v_item->>'item_id')::UUID, 'sale', 'sale', v_sale_id,
                 v_filled_qty_change, v_empty_qty_change,
                 'POS Sale #' || LEFT(v_sale_id::TEXT, 8),
                 v_user_id);

            -- Update item stock
            UPDATE items
            SET
                filled_quantity = filled_quantity + v_filled_qty_change,
                empty_quantity  = empty_quantity  + v_empty_qty_change,
                updated_at      = NOW()
            WHERE tenant_id = v_tenant_id
              AND item_id   = (v_item->>'item_id')::UUID;
        END IF;

        -- Insert sale line item
        INSERT INTO sale_items (tenant_id, sale_id, item_id, type, quantity, unit_price, line_total)
        VALUES (
            v_tenant_id, v_sale_id,
            (v_item->>'item_id')::UUID,
            (v_item->>'type')::sale_item_type,
            (v_item->>'quantity')::INT,
            (v_item->>'unit_price')::NUMERIC,
            v_item_total
        );
    END LOOP;

    -- Finalise totals
    v_total_amount := v_subtotal - COALESCE(p_discount_amount, 0) + COALESCE(p_exchange_fee, 0);
    UPDATE sales SET subtotal = v_subtotal, total_amount = v_total_amount WHERE sale_id = v_sale_id;

    -- Customer ledger
    INSERT INTO customer_transactions (tenant_id, customer_id, type, amount, reference_id, created_by)
    VALUES
        (v_tenant_id, v_customer_id, 'invoice_charge',  -v_total_amount, v_sale_id, v_user_id),
        (v_tenant_id, v_customer_id, 'payment_receipt',  v_total_amount, v_sale_id, v_user_id);

    -- Wallet
    PERFORM ensure_tenant_wallets(v_tenant_id);
    UPDATE wallets SET balance = balance + v_total_amount, updated_at = NOW()
    WHERE tenant_id = v_tenant_id AND type = 'dealership';

    RETURN jsonb_build_object(
        'sale_id',        v_sale_id,
        'customer_id',    v_customer_id,
        'subtotal',       v_subtotal,
        'total_amount',   v_total_amount,
        'customer_phone', TRIM(p_customer_phone),
        'customer_name',  COALESCE(NULLIF(TRIM(p_customer_name), ''), 'Unknown')
    );
END;
$$;


ALTER FUNCTION "public"."create_pos_sale"("p_customer_phone" character varying, "p_customer_name" character varying, "p_customer_shop_name" character varying, "p_customer_address" "text", "p_customer_tier" character varying, "p_discount_amount" numeric, "p_exchange_fee" numeric, "p_notes" "text", "p_items" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_purchase"("p_truck_id" "uuid", "p_plant_id" "uuid", "p_transport_cost" numeric, "p_labour_cost" numeric, "p_notes" "text", "p_items" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."create_purchase"("p_truck_id" "uuid", "p_plant_id" "uuid", "p_transport_cost" numeric, "p_labour_cost" numeric, "p_notes" "text", "p_items" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_truck"("p_name" character varying, "p_serial_no" character varying, "p_capacity" integer, "p_size" "public"."truck_size") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."create_truck"("p_name" character varying, "p_serial_no" character varying, "p_capacity" integer, "p_size" "public"."truck_size") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_truck"("p_name" character varying, "p_serial_no" character varying, "p_capacity" integer, "p_size" "public"."truck_size", "p_location" character varying DEFAULT NULL::character varying) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."create_truck"("p_name" character varying, "p_serial_no" character varying, "p_capacity" integer, "p_size" "public"."truck_size", "p_location" character varying) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ensure_tenant_wallets"("p_tenant_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
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


ALTER FUNCTION "public"."ensure_tenant_wallets"("p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_gas_plants"("p_active_only" boolean DEFAULT false) RETURNS TABLE("plant_id" "uuid", "plant_name" character varying, "brand_id" "uuid", "brand_name" character varying, "location" "text", "is_active" boolean, "created_at" timestamp with time zone, "updated_at" timestamp with time zone, "officer_id" "uuid", "officer_name" character varying, "whatsapp_phone" character varying, "email" character varying)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."list_gas_plants"("p_active_only" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_lpg_brands"("p_active_only" boolean DEFAULT true) RETURNS TABLE("brand_id" "uuid", "brand_name" character varying, "description" "text", "is_active" boolean, "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."list_lpg_brands"("p_active_only" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_purchases"() RETURNS TABLE("purchase_id" "uuid", "truck_id" "uuid", "truck_name" character varying, "plant_id" "uuid", "plant_name" character varying, "status" "public"."purchase_status", "transport_cost" numeric, "labour_cost" numeric, "total_cost" numeric, "notes" "text", "created_at" timestamp with time zone, "items" "jsonb")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."list_purchases"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_trucks"("p_active_only" boolean DEFAULT true) RETURNS TABLE("truck_id" "uuid", "name" character varying, "serial_no" character varying, "capacity" integer, "size" "public"."truck_size", "status" "public"."truck_status", "location" character varying, "created_at" timestamp with time zone, "updated_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."list_trucks"("p_active_only" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."my_tenant_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    AS $$
    SELECT tenant_id FROM user_profiles WHERE user_id = auth.uid() LIMIT 1;
$$;


ALTER FUNCTION "public"."my_tenant_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."setup_business"("p_business_name" "text", "p_owner_name" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_user_id    UUID := auth.uid();
    v_user_email TEXT;
    v_tenant_id  UUID;
    v_owner_role UUID;
    v_mgr_role   UUID;
    v_sales_role UUID;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    SELECT email INTO v_user_email FROM auth.users WHERE id = v_user_id;

    -- 1. Create the Tenant
    INSERT INTO tenants (business_name, status)
    VALUES (p_business_name, 'active')
    RETURNING tenant_id INTO v_tenant_id;

    -- 2. Create User Profile
    INSERT INTO user_profiles (user_id, tenant_id, full_name, email)
    VALUES (v_user_id, v_tenant_id, p_owner_name, v_user_email);

    -- 3. Create default roles: Owner, Manager, Salesman
    INSERT INTO roles (tenant_id, name) VALUES (v_tenant_id, 'Owner')   RETURNING role_id INTO v_owner_role;
    INSERT INTO roles (tenant_id, name) VALUES (v_tenant_id, 'Manager') RETURNING role_id INTO v_mgr_role;
    INSERT INTO roles (tenant_id, name) VALUES (v_tenant_id, 'Salesman') RETURNING role_id INTO v_sales_role;

    -- 4. Owner gets ALL permissions
    INSERT INTO role_permissions (tenant_id, role_id, permission_id)
    SELECT v_tenant_id, v_owner_role, permission_id FROM permissions;

    -- 5. Manager gets most permissions (not settings:manage)
    INSERT INTO role_permissions (tenant_id, role_id, permission_id)
    SELECT v_tenant_id, v_mgr_role, permission_id
    FROM permissions
    WHERE permission_id NOT IN ('settings:manage');

    -- 6. Salesman gets POS + view permissions
    INSERT INTO role_permissions (tenant_id, role_id, permission_id)
    SELECT v_tenant_id, v_sales_role, permission_id
    FROM permissions
    WHERE permission_id IN ('pos:sell','inventory:view','customers:view','logistics:view');

    -- 7. Assign Owner role to registering user
    INSERT INTO user_roles (tenant_id, user_id, role_id)
    VALUES (v_tenant_id, v_user_id, v_owner_role);

    -- 8. Store tenant_id in user metadata for quick JWT reads
    UPDATE auth.users
    SET raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object(
        'full_name', p_owner_name,
        'tenant_id', v_tenant_id::text
    )
    WHERE id = v_user_id;

    RETURN jsonb_build_object(
        'tenant_id', v_tenant_id,
        'user_id',   v_user_id,
        'role',      'Owner'
    );
END;
$$;


ALTER FUNCTION "public"."setup_business"("p_business_name" "text", "p_owner_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_area_officer"("p_officer_id" "uuid", "p_officer_name" "text" DEFAULT NULL::"text", "p_whatsapp_phone" "text" DEFAULT NULL::"text", "p_email" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."update_area_officer"("p_officer_id" "uuid", "p_officer_name" "text", "p_whatsapp_phone" "text", "p_email" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_gas_plant"("p_plant_id" "uuid", "p_plant_name" "text" DEFAULT NULL::"text", "p_brand_id" "uuid" DEFAULT NULL::"uuid", "p_location" "text" DEFAULT NULL::"text", "p_is_active" boolean DEFAULT NULL::boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."update_gas_plant"("p_plant_id" "uuid", "p_plant_name" "text", "p_brand_id" "uuid", "p_location" "text", "p_is_active" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_item_inventory"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    UPDATE items
    SET 
        filled_quantity = filled_quantity + NEW.filled_quantity_change,
        empty_quantity = empty_quantity + NEW.empty_quantity_change,
        updated_at = NOW()
    WHERE tenant_id = NEW.tenant_id AND item_id = NEW.item_id;
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_item_inventory"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_lpg_brand"("p_brand_id" "uuid", "p_brand_name" "text" DEFAULT NULL::"text", "p_description" "text" DEFAULT NULL::"text", "p_is_active" boolean DEFAULT NULL::boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."update_lpg_brand"("p_brand_id" "uuid", "p_brand_name" "text", "p_description" "text", "p_is_active" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_purchase"("p_purchase_id" "uuid", "p_transport_cost" numeric, "p_labour_cost" numeric, "p_notes" "text", "p_items" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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
    
    v_old_qty        INT;
    v_new_qty        INT;
    v_qty_diff       INT;
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

    -- Update item prices/quantities and calculate new totals
    IF p_items IS NOT NULL THEN
        FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
        LOOP
            v_new_qty := (v_item->>'quantity')::INT;
            
            -- Get old quantity
            SELECT quantity INTO v_old_qty 
            FROM purchase_items 
            WHERE tenant_id = v_tenant_id 
              AND purchase_id = p_purchase_id 
              AND item_id = (v_item->>'item_id')::UUID;
              
            IF FOUND THEN
                v_qty_diff := v_new_qty - v_old_qty;
                
                -- Update unit_price, quantity and line_total
                UPDATE purchase_items 
                SET unit_price = (v_item->>'unit_price')::NUMERIC,
                    quantity = v_new_qty,
                    line_total = v_new_qty * (v_item->>'unit_price')::NUMERIC
                WHERE tenant_id = v_tenant_id 
                  AND purchase_id = p_purchase_id 
                  AND item_id = (v_item->>'item_id')::UUID
                RETURNING line_total INTO v_item_total;

                v_total_cost := v_total_cost + v_item_total;
                
                -- If quantity changed, adjust empty bottles in inventory
                IF v_qty_diff <> 0 THEN
                    -- We sent empty bottles. If qty increases, we send MORE empty bottles (negative change).
                    -- If qty decreases, we send FEWER empty bottles (positive change / refund).
                    PERFORM create_inventory_movement(
                        (v_item->>'item_id')::UUID,
                        'purchase_adjustment',
                        0, -- filled_quantity_change
                        -v_qty_diff, -- empty_quantity_change
                        'Quantity adjustment for Purchase ' || p_purchase_id
                    );
                END IF;
            END IF;
        END LOOP;
    END IF;

    -- Now add remaining item totals that were NOT updated (just in case they didn't send all items)
    -- Actually, since we process all items, we can just use v_total_cost as is.
    -- But to be safe, let's just re-sum everything from purchase_items
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
        
        IF FOUND THEN
            INSERT INTO wallet_transactions (tenant_id, wallet_id, amount, type, reference_id, description)
            VALUES (v_tenant_id, v_wallet_id, v_transport_diff, 'transport_income_adj', p_purchase_id, 'Transport fee adjustment for Purchase ' || p_purchase_id);

            UPDATE wallets SET balance = balance + v_transport_diff, updated_at = NOW() WHERE wallet_id = v_wallet_id;
        END IF;
    END IF;

    RETURN jsonb_build_object('purchase_id', p_purchase_id, 'total_cost', v_total_cost);
END;
$$;


ALTER FUNCTION "public"."update_purchase"("p_purchase_id" "uuid", "p_transport_cost" numeric, "p_labour_cost" numeric, "p_notes" "text", "p_items" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_transit_costs"("p_transit_id" "uuid", "p_driver_cost" numeric, "p_helper_cost" numeric, "p_oil_cost" numeric, "p_additional_costs" "jsonb", "p_status" "public"."transit_status") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."update_transit_costs"("p_transit_id" "uuid", "p_driver_cost" numeric, "p_helper_cost" numeric, "p_oil_cost" numeric, "p_additional_costs" "jsonb", "p_status" "public"."transit_status") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_truck"("p_truck_id" "uuid", "p_name" character varying DEFAULT NULL::character varying, "p_serial_no" character varying DEFAULT NULL::character varying, "p_capacity" integer DEFAULT NULL::integer, "p_size" "public"."truck_size" DEFAULT NULL::"public"."truck_size", "p_is_active" boolean DEFAULT NULL::boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."update_truck"("p_truck_id" "uuid", "p_name" character varying, "p_serial_no" character varying, "p_capacity" integer, "p_size" "public"."truck_size", "p_is_active" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_truck"("p_truck_id" "uuid", "p_name" character varying DEFAULT NULL::character varying, "p_serial_no" character varying DEFAULT NULL::character varying, "p_capacity" integer DEFAULT NULL::integer, "p_size" "public"."truck_size" DEFAULT NULL::"public"."truck_size", "p_status" "public"."truck_status" DEFAULT NULL::"public"."truck_status", "p_location" character varying DEFAULT NULL::character varying) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."update_truck"("p_truck_id" "uuid", "p_name" character varying, "p_serial_no" character varying, "p_capacity" integer, "p_size" "public"."truck_size", "p_status" "public"."truck_status", "p_location" character varying) OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."area_officers" (
    "tenant_id" "uuid" NOT NULL,
    "officer_id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "plant_id" "uuid" NOT NULL,
    "officer_name" character varying(200) NOT NULL,
    "whatsapp_phone" character varying(30),
    "email" character varying(255),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."area_officers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."audit_logs" (
    "tenant_id" "uuid" NOT NULL,
    "log_id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "table_name" character varying(100) NOT NULL,
    "record_id" "uuid" NOT NULL,
    "action" character varying(20) NOT NULL,
    "old_data" "jsonb",
    "new_data" "jsonb",
    "performed_by" "uuid",
    "ip_address" "inet",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."audit_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."customer_transactions" (
    "tenant_id" "uuid" NOT NULL,
    "transaction_id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "customer_id" "uuid" NOT NULL,
    "type" character varying(50) NOT NULL,
    "amount" numeric(12,2) NOT NULL,
    "reference_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "created_by" "uuid"
);


ALTER TABLE "public"."customer_transactions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."customers" (
    "tenant_id" "uuid" NOT NULL,
    "customer_id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "name" character varying(255) NOT NULL,
    "tier" character varying(50) DEFAULT 'retail'::character varying,
    "shop_name" character varying(255),
    "phone" character varying(50),
    "address" "text"
);


ALTER TABLE "public"."customers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."gas_plants" (
    "tenant_id" "uuid" NOT NULL,
    "plant_id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "plant_name" character varying(200) NOT NULL,
    "brand_id" "uuid",
    "location" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."gas_plants" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_movements" (
    "tenant_id" "uuid" NOT NULL,
    "movement_id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "item_id" "uuid" NOT NULL,
    "movement_type" character varying(50) NOT NULL,
    "reference_type" character varying(50),
    "reference_id" "uuid",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "notes" "text",
    "filled_quantity_change" integer DEFAULT 0 NOT NULL,
    "empty_quantity_change" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."inventory_movements" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."items" (
    "tenant_id" "uuid" NOT NULL,
    "item_id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "brand" character varying(100) NOT NULL,
    "size_kg" numeric(5,2) NOT NULL,
    "brand_id" "uuid",
    "cylinder_weight" "public"."cylinder_weight",
    "mouth_size" "public"."mouth_size",
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "filled_quantity" integer DEFAULT 0 NOT NULL,
    "empty_quantity" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."lpg_brands" (
    "tenant_id" "uuid" NOT NULL,
    "brand_id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "brand_name" character varying(100) NOT NULL,
    "description" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."lpg_brands" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."permissions" (
    "permission_id" character varying(100) NOT NULL,
    "description" "text"
);


ALTER TABLE "public"."permissions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."price_books" (
    "tenant_id" "uuid" NOT NULL,
    "item_id" "uuid" NOT NULL,
    "customer_tier" character varying(50) DEFAULT 'retail'::character varying NOT NULL,
    "price" numeric(12,2) NOT NULL,
    "effective_from" timestamp with time zone DEFAULT "now"() NOT NULL,
    "effective_to" timestamp with time zone,
    CONSTRAINT "price_books_check" CHECK ((("effective_to" IS NULL) OR ("effective_to" > "effective_from")))
);


ALTER TABLE "public"."price_books" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."purchase_items" (
    "tenant_id" "uuid" NOT NULL,
    "purchase_item_id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "purchase_id" "uuid" NOT NULL,
    "item_id" "uuid" NOT NULL,
    "type" "public"."purchase_type" NOT NULL,
    "quantity" integer NOT NULL,
    "unit_price" numeric(12,2) DEFAULT 0.00 NOT NULL,
    "line_total" numeric(12,2) DEFAULT 0.00 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "purchase_items_quantity_check" CHECK (("quantity" > 0))
);


ALTER TABLE "public"."purchase_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."purchases" (
    "tenant_id" "uuid" NOT NULL,
    "purchase_id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "truck_id" "uuid" NOT NULL,
    "plant_id" "uuid" NOT NULL,
    "status" "public"."purchase_status" DEFAULT 'in_transit'::"public"."purchase_status" NOT NULL,
    "transport_cost" numeric(12,2) DEFAULT 0.00,
    "labour_cost" numeric(12,2) DEFAULT 0.00,
    "total_cost" numeric(12,2) DEFAULT 0.00 NOT NULL,
    "notes" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."purchases" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."role_permissions" (
    "tenant_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL,
    "permission_id" character varying(100) NOT NULL
);


ALTER TABLE "public"."role_permissions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."roles" (
    "tenant_id" "uuid" NOT NULL,
    "role_id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "name" character varying(100) NOT NULL
);


ALTER TABLE "public"."roles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sale_items" (
    "tenant_id" "uuid" NOT NULL,
    "sale_item_id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "sale_id" "uuid" NOT NULL,
    "item_id" "uuid" NOT NULL,
    "type" "public"."sale_item_type" NOT NULL,
    "quantity" integer NOT NULL,
    "unit_price" numeric(12,2) DEFAULT 0.00 NOT NULL,
    "line_total" numeric(12,2) DEFAULT 0.00 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "sale_items_quantity_check" CHECK (("quantity" > 0))
);


ALTER TABLE "public"."sale_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sales" (
    "tenant_id" "uuid" NOT NULL,
    "sale_id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "customer_id" "uuid" NOT NULL,
    "status" "public"."sale_status" DEFAULT 'completed'::"public"."sale_status" NOT NULL,
    "subtotal" numeric(12,2) DEFAULT 0.00 NOT NULL,
    "discount_amount" numeric(12,2) DEFAULT 0.00 NOT NULL,
    "exchange_fee" numeric(12,2) DEFAULT 0.00 NOT NULL,
    "total_amount" numeric(12,2) DEFAULT 0.00 NOT NULL,
    "notes" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."sales" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tenants" (
    "tenant_id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "business_name" character varying(255) NOT NULL,
    "status" character varying(50) DEFAULT 'active'::character varying,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."tenants" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."transits" (
    "tenant_id" "uuid" NOT NULL,
    "transit_id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "truck_id" "uuid" NOT NULL,
    "purchase_id" "uuid",
    "status" "public"."transit_status" DEFAULT 'active'::"public"."transit_status" NOT NULL,
    "driver_cost" numeric(12,2) DEFAULT 0.00,
    "helper_cost" numeric(12,2) DEFAULT 0.00,
    "oil_cost" numeric(12,2) DEFAULT 0.00,
    "additional_costs" "jsonb" DEFAULT '[]'::"jsonb",
    "total_cost" numeric(12,2) DEFAULT 0.00,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "transport_fee" numeric(12,2) DEFAULT 0.00
);


ALTER TABLE "public"."transits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trucks" (
    "tenant_id" "uuid" NOT NULL,
    "truck_id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "name" character varying(100) NOT NULL,
    "serial_no" character varying(100) NOT NULL,
    "capacity" integer NOT NULL,
    "size" "public"."truck_size" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" "public"."truck_status" DEFAULT 'idle'::"public"."truck_status" NOT NULL,
    "location" character varying(200),
    CONSTRAINT "trucks_capacity_check" CHECK (("capacity" > 0))
);


ALTER TABLE "public"."trucks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_profiles" (
    "user_id" "uuid" NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "email" character varying(255) NOT NULL,
    "is_active" boolean DEFAULT true
);


ALTER TABLE "public"."user_profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_roles" (
    "tenant_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL
);


ALTER TABLE "public"."user_roles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."wallet_transactions" (
    "tenant_id" "uuid" NOT NULL,
    "transaction_id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "wallet_id" "uuid" NOT NULL,
    "amount" numeric(15,2) NOT NULL,
    "type" character varying(50) NOT NULL,
    "reference_id" "uuid",
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."wallet_transactions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."wallets" (
    "tenant_id" "uuid" NOT NULL,
    "wallet_id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "type" "public"."wallet_type" NOT NULL,
    "balance" numeric(15,2) DEFAULT 0.00 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."wallets" OWNER TO "postgres";


ALTER TABLE ONLY "public"."area_officers"
    ADD CONSTRAINT "area_officers_pkey" PRIMARY KEY ("tenant_id", "officer_id");



ALTER TABLE ONLY "public"."audit_logs"
    ADD CONSTRAINT "audit_logs_pkey" PRIMARY KEY ("tenant_id", "log_id");



ALTER TABLE ONLY "public"."customer_transactions"
    ADD CONSTRAINT "customer_transactions_pkey" PRIMARY KEY ("tenant_id", "transaction_id");



ALTER TABLE ONLY "public"."customers"
    ADD CONSTRAINT "customers_pkey" PRIMARY KEY ("tenant_id", "customer_id");



ALTER TABLE ONLY "public"."gas_plants"
    ADD CONSTRAINT "gas_plants_pkey" PRIMARY KEY ("tenant_id", "plant_id");



ALTER TABLE ONLY "public"."gas_plants"
    ADD CONSTRAINT "gas_plants_tenant_id_plant_name_key" UNIQUE ("tenant_id", "plant_name");



ALTER TABLE ONLY "public"."inventory_movements"
    ADD CONSTRAINT "inventory_movements_pkey" PRIMARY KEY ("tenant_id", "movement_id");



ALTER TABLE ONLY "public"."items"
    ADD CONSTRAINT "items_pkey" PRIMARY KEY ("tenant_id", "item_id");



ALTER TABLE ONLY "public"."items"
    ADD CONSTRAINT "items_unique_sku" UNIQUE ("tenant_id", "brand_id", "size_kg", "mouth_size");



ALTER TABLE ONLY "public"."lpg_brands"
    ADD CONSTRAINT "lpg_brands_pkey" PRIMARY KEY ("tenant_id", "brand_id");



ALTER TABLE ONLY "public"."lpg_brands"
    ADD CONSTRAINT "lpg_brands_tenant_id_brand_name_key" UNIQUE ("tenant_id", "brand_name");



ALTER TABLE ONLY "public"."permissions"
    ADD CONSTRAINT "permissions_pkey" PRIMARY KEY ("permission_id");



ALTER TABLE ONLY "public"."price_books"
    ADD CONSTRAINT "price_books_pkey" PRIMARY KEY ("tenant_id", "item_id", "customer_tier", "effective_from");



ALTER TABLE ONLY "public"."purchase_items"
    ADD CONSTRAINT "purchase_items_pkey" PRIMARY KEY ("tenant_id", "purchase_item_id");



ALTER TABLE ONLY "public"."purchases"
    ADD CONSTRAINT "purchases_pkey" PRIMARY KEY ("tenant_id", "purchase_id");



ALTER TABLE ONLY "public"."role_permissions"
    ADD CONSTRAINT "role_permissions_pkey" PRIMARY KEY ("tenant_id", "role_id", "permission_id");



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_pkey" PRIMARY KEY ("tenant_id", "role_id");



ALTER TABLE ONLY "public"."sale_items"
    ADD CONSTRAINT "sale_items_pkey" PRIMARY KEY ("tenant_id", "sale_item_id");



ALTER TABLE ONLY "public"."sales"
    ADD CONSTRAINT "sales_pkey" PRIMARY KEY ("tenant_id", "sale_id");



ALTER TABLE ONLY "public"."tenants"
    ADD CONSTRAINT "tenants_pkey" PRIMARY KEY ("tenant_id");



ALTER TABLE ONLY "public"."transits"
    ADD CONSTRAINT "transits_pkey" PRIMARY KEY ("tenant_id", "transit_id");



ALTER TABLE ONLY "public"."trucks"
    ADD CONSTRAINT "trucks_pkey" PRIMARY KEY ("tenant_id", "truck_id");



ALTER TABLE ONLY "public"."trucks"
    ADD CONSTRAINT "trucks_tenant_id_serial_no_key" UNIQUE ("tenant_id", "serial_no");



ALTER TABLE ONLY "public"."user_profiles"
    ADD CONSTRAINT "user_profiles_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_pkey" PRIMARY KEY ("tenant_id", "user_id", "role_id");



ALTER TABLE ONLY "public"."wallet_transactions"
    ADD CONSTRAINT "wallet_transactions_pkey" PRIMARY KEY ("tenant_id", "transaction_id");



ALTER TABLE ONLY "public"."wallets"
    ADD CONSTRAINT "wallets_pkey" PRIMARY KEY ("tenant_id", "wallet_id");



ALTER TABLE ONLY "public"."wallets"
    ADD CONSTRAINT "wallets_tenant_id_type_key" UNIQUE ("tenant_id", "type");



CREATE UNIQUE INDEX "customers_tenant_phone_unique" ON "public"."customers" USING "btree" ("tenant_id", "phone");



CREATE INDEX "idx_area_officers_plant" ON "public"."area_officers" USING "btree" ("tenant_id", "plant_id");



CREATE INDEX "idx_audit_logs_tenant_table_record" ON "public"."audit_logs" USING "btree" ("tenant_id", "table_name", "record_id");



CREATE INDEX "idx_customer_transactions_tenant_customer_date" ON "public"."customer_transactions" USING "btree" ("tenant_id", "customer_id", "created_at");



CREATE INDEX "idx_gas_plants_brand" ON "public"."gas_plants" USING "btree" ("tenant_id", "brand_id");



CREATE INDEX "idx_gas_plants_tenant_active" ON "public"."gas_plants" USING "btree" ("tenant_id", "is_active");



CREATE INDEX "idx_inventory_movements_tenant_date" ON "public"."inventory_movements" USING "btree" ("tenant_id", "created_at" DESC);



CREATE INDEX "idx_inventory_movements_tenant_item_date" ON "public"."inventory_movements" USING "btree" ("tenant_id", "item_id", "created_at");



CREATE INDEX "idx_items_brand_id" ON "public"."items" USING "btree" ("tenant_id", "brand_id");



CREATE INDEX "idx_items_cylinder_weight" ON "public"."items" USING "btree" ("tenant_id", "cylinder_weight");



CREATE INDEX "idx_items_mouth_size" ON "public"."items" USING "btree" ("tenant_id", "mouth_size");



CREATE INDEX "idx_items_tenant" ON "public"."items" USING "btree" ("tenant_id");



CREATE INDEX "idx_lpg_brands_tenant_active" ON "public"."lpg_brands" USING "btree" ("tenant_id", "is_active");



CREATE INDEX "idx_price_books_tenant_item_tier" ON "public"."price_books" USING "btree" ("tenant_id", "item_id", "customer_tier");



CREATE INDEX "idx_purchase_items_purchase" ON "public"."purchase_items" USING "btree" ("tenant_id", "purchase_id");



CREATE INDEX "idx_purchases_tenant_date" ON "public"."purchases" USING "btree" ("tenant_id", "created_at" DESC);



CREATE INDEX "idx_purchases_tenant_status" ON "public"."purchases" USING "btree" ("tenant_id", "status");



CREATE INDEX "idx_sale_items_sale" ON "public"."sale_items" USING "btree" ("tenant_id", "sale_id");



CREATE INDEX "idx_sales_tenant_date" ON "public"."sales" USING "btree" ("tenant_id", "created_at" DESC);



CREATE INDEX "idx_transits_purchase" ON "public"."transits" USING "btree" ("tenant_id", "purchase_id");



CREATE INDEX "idx_transits_tenant_truck" ON "public"."transits" USING "btree" ("tenant_id", "truck_id");



CREATE INDEX "idx_trucks_size" ON "public"."trucks" USING "btree" ("tenant_id", "size");



CREATE INDEX "idx_trucks_status" ON "public"."trucks" USING "btree" ("tenant_id", "status");



CREATE INDEX "idx_user_profiles_tenant" ON "public"."user_profiles" USING "btree" ("tenant_id");



CREATE INDEX "idx_wallet_transactions_wallet" ON "public"."wallet_transactions" USING "btree" ("tenant_id", "wallet_id");



CREATE INDEX "idx_wallets_tenant" ON "public"."wallets" USING "btree" ("tenant_id");



CREATE OR REPLACE TRIGGER "trg_audit_lpg_brands" AFTER INSERT OR DELETE OR UPDATE ON "public"."lpg_brands" FOR EACH ROW EXECUTE FUNCTION "public"."audit_lpg_brands"();



CREATE OR REPLACE TRIGGER "trg_audit_trucks" AFTER INSERT OR DELETE OR UPDATE ON "public"."trucks" FOR EACH ROW EXECUTE FUNCTION "public"."audit_trucks"();



CREATE OR REPLACE TRIGGER "trg_update_item_inventory" AFTER INSERT ON "public"."inventory_movements" FOR EACH ROW EXECUTE FUNCTION "public"."update_item_inventory"();



ALTER TABLE ONLY "public"."area_officers"
    ADD CONSTRAINT "area_officers_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("tenant_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."area_officers"
    ADD CONSTRAINT "area_officers_tenant_id_plant_id_fkey" FOREIGN KEY ("tenant_id", "plant_id") REFERENCES "public"."gas_plants"("tenant_id", "plant_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."customer_transactions"
    ADD CONSTRAINT "customer_transactions_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."user_profiles"("user_id");



ALTER TABLE ONLY "public"."customer_transactions"
    ADD CONSTRAINT "customer_transactions_tenant_id_customer_id_fkey" FOREIGN KEY ("tenant_id", "customer_id") REFERENCES "public"."customers"("tenant_id", "customer_id");



ALTER TABLE ONLY "public"."items"
    ADD CONSTRAINT "fk_items_brand_id" FOREIGN KEY ("tenant_id", "brand_id") REFERENCES "public"."lpg_brands"("tenant_id", "brand_id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."gas_plants"
    ADD CONSTRAINT "gas_plants_tenant_id_brand_id_fkey" FOREIGN KEY ("tenant_id", "brand_id") REFERENCES "public"."lpg_brands"("tenant_id", "brand_id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."gas_plants"
    ADD CONSTRAINT "gas_plants_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("tenant_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inventory_movements"
    ADD CONSTRAINT "inventory_movements_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."user_profiles"("user_id");



ALTER TABLE ONLY "public"."inventory_movements"
    ADD CONSTRAINT "inventory_movements_tenant_id_item_id_fkey" FOREIGN KEY ("tenant_id", "item_id") REFERENCES "public"."items"("tenant_id", "item_id");



ALTER TABLE ONLY "public"."lpg_brands"
    ADD CONSTRAINT "lpg_brands_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("tenant_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."price_books"
    ADD CONSTRAINT "price_books_tenant_id_item_id_fkey" FOREIGN KEY ("tenant_id", "item_id") REFERENCES "public"."items"("tenant_id", "item_id");



ALTER TABLE ONLY "public"."purchase_items"
    ADD CONSTRAINT "purchase_items_tenant_id_item_id_fkey" FOREIGN KEY ("tenant_id", "item_id") REFERENCES "public"."items"("tenant_id", "item_id");



ALTER TABLE ONLY "public"."purchase_items"
    ADD CONSTRAINT "purchase_items_tenant_id_purchase_id_fkey" FOREIGN KEY ("tenant_id", "purchase_id") REFERENCES "public"."purchases"("tenant_id", "purchase_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."purchases"
    ADD CONSTRAINT "purchases_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."user_profiles"("user_id");



ALTER TABLE ONLY "public"."purchases"
    ADD CONSTRAINT "purchases_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("tenant_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."purchases"
    ADD CONSTRAINT "purchases_tenant_id_plant_id_fkey" FOREIGN KEY ("tenant_id", "plant_id") REFERENCES "public"."gas_plants"("tenant_id", "plant_id");



ALTER TABLE ONLY "public"."purchases"
    ADD CONSTRAINT "purchases_tenant_id_truck_id_fkey" FOREIGN KEY ("tenant_id", "truck_id") REFERENCES "public"."trucks"("tenant_id", "truck_id");



ALTER TABLE ONLY "public"."role_permissions"
    ADD CONSTRAINT "role_permissions_permission_id_fkey" FOREIGN KEY ("permission_id") REFERENCES "public"."permissions"("permission_id");



ALTER TABLE ONLY "public"."role_permissions"
    ADD CONSTRAINT "role_permissions_tenant_id_role_id_fkey" FOREIGN KEY ("tenant_id", "role_id") REFERENCES "public"."roles"("tenant_id", "role_id");



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("tenant_id");



ALTER TABLE ONLY "public"."sale_items"
    ADD CONSTRAINT "sale_items_tenant_id_item_id_fkey" FOREIGN KEY ("tenant_id", "item_id") REFERENCES "public"."items"("tenant_id", "item_id");



ALTER TABLE ONLY "public"."sale_items"
    ADD CONSTRAINT "sale_items_tenant_id_sale_id_fkey" FOREIGN KEY ("tenant_id", "sale_id") REFERENCES "public"."sales"("tenant_id", "sale_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sales"
    ADD CONSTRAINT "sales_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."user_profiles"("user_id");



ALTER TABLE ONLY "public"."sales"
    ADD CONSTRAINT "sales_tenant_id_customer_id_fkey" FOREIGN KEY ("tenant_id", "customer_id") REFERENCES "public"."customers"("tenant_id", "customer_id");



ALTER TABLE ONLY "public"."sales"
    ADD CONSTRAINT "sales_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("tenant_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."transits"
    ADD CONSTRAINT "transits_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("tenant_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."transits"
    ADD CONSTRAINT "transits_tenant_id_truck_id_fkey" FOREIGN KEY ("tenant_id", "truck_id") REFERENCES "public"."trucks"("tenant_id", "truck_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trucks"
    ADD CONSTRAINT "trucks_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("tenant_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_profiles"
    ADD CONSTRAINT "user_profiles_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("tenant_id");



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_tenant_id_role_id_fkey" FOREIGN KEY ("tenant_id", "role_id") REFERENCES "public"."roles"("tenant_id", "role_id");



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user_profiles"("user_id");



ALTER TABLE ONLY "public"."wallet_transactions"
    ADD CONSTRAINT "wallet_transactions_tenant_id_wallet_id_fkey" FOREIGN KEY ("tenant_id", "wallet_id") REFERENCES "public"."wallets"("tenant_id", "wallet_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."wallets"
    ADD CONSTRAINT "wallets_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("tenant_id") ON DELETE CASCADE;



CREATE POLICY "Strict Tenant Isolation for Movements" ON "public"."inventory_movements" USING (("tenant_id" = ((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'tenant_id'::"text"))::"uuid")) WITH CHECK (("tenant_id" = ((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'tenant_id'::"text"))::"uuid"));



CREATE POLICY "Tenant isolation on role_permissions" ON "public"."role_permissions" USING (("tenant_id" IN ( SELECT "user_profiles"."tenant_id"
   FROM "public"."user_profiles"
  WHERE ("user_profiles"."user_id" = "auth"."uid"()))));



CREATE POLICY "Tenant isolation on roles" ON "public"."roles" USING (("tenant_id" IN ( SELECT "user_profiles"."tenant_id"
   FROM "public"."user_profiles"
  WHERE ("user_profiles"."user_id" = "auth"."uid"()))));



CREATE POLICY "Tenant isolation on user_roles" ON "public"."user_roles" USING (("tenant_id" IN ( SELECT "user_profiles"."tenant_id"
   FROM "public"."user_profiles"
  WHERE ("user_profiles"."user_id" = "auth"."uid"()))));



CREATE POLICY "Tenant members can view their tenant" ON "public"."tenants" FOR SELECT USING (("tenant_id" IN ( SELECT "user_profiles"."tenant_id"
   FROM "public"."user_profiles"
  WHERE ("user_profiles"."user_id" = "auth"."uid"()))));



CREATE POLICY "Users can update their own profile" ON "public"."user_profiles" FOR UPDATE USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can view their own profile" ON "public"."user_profiles" FOR SELECT USING (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."area_officers" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "area_officers_tenant_delete" ON "public"."area_officers" FOR DELETE USING (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "area_officers_tenant_insert" ON "public"."area_officers" FOR INSERT WITH CHECK (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "area_officers_tenant_select" ON "public"."area_officers" FOR SELECT USING (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "area_officers_tenant_update" ON "public"."area_officers" FOR UPDATE USING (("tenant_id" = "public"."my_tenant_id"())) WITH CHECK (("tenant_id" = "public"."my_tenant_id"()));



ALTER TABLE "public"."audit_logs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "audit_tenant_select" ON "public"."audit_logs" FOR SELECT USING (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "ct_tenant" ON "public"."customer_transactions" USING (("tenant_id" = "public"."my_tenant_id"())) WITH CHECK (("tenant_id" = "public"."my_tenant_id"()));



ALTER TABLE "public"."customer_transactions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."customers" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "customers_tenant" ON "public"."customers" USING (("tenant_id" = "public"."my_tenant_id"())) WITH CHECK (("tenant_id" = "public"."my_tenant_id"()));



ALTER TABLE "public"."gas_plants" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "gas_plants_tenant_delete" ON "public"."gas_plants" FOR DELETE USING (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "gas_plants_tenant_insert" ON "public"."gas_plants" FOR INSERT WITH CHECK (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "gas_plants_tenant_select" ON "public"."gas_plants" FOR SELECT USING (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "gas_plants_tenant_update" ON "public"."gas_plants" FOR UPDATE USING (("tenant_id" = "public"."my_tenant_id"())) WITH CHECK (("tenant_id" = "public"."my_tenant_id"()));



ALTER TABLE "public"."inventory_movements" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "items_tenant_insert" ON "public"."items" FOR INSERT WITH CHECK (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "items_tenant_select" ON "public"."items" FOR SELECT USING (("tenant_id" = "public"."my_tenant_id"()));



ALTER TABLE "public"."lpg_brands" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "lpg_brands_tenant_delete" ON "public"."lpg_brands" FOR DELETE USING (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "lpg_brands_tenant_insert" ON "public"."lpg_brands" FOR INSERT WITH CHECK (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "lpg_brands_tenant_select" ON "public"."lpg_brands" FOR SELECT USING (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "lpg_brands_tenant_update" ON "public"."lpg_brands" FOR UPDATE USING (("tenant_id" = "public"."my_tenant_id"())) WITH CHECK (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "movements_tenant_insert" ON "public"."inventory_movements" FOR INSERT WITH CHECK (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "movements_tenant_select" ON "public"."inventory_movements" FOR SELECT USING (("tenant_id" = "public"."my_tenant_id"()));



ALTER TABLE "public"."permissions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."price_books" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profile_own_update" ON "public"."user_profiles" FOR UPDATE USING (("user_id" = "auth"."uid"()));



CREATE POLICY "profile_select" ON "public"."user_profiles" FOR SELECT USING (("tenant_id" = "public"."my_tenant_id"()));



ALTER TABLE "public"."purchase_items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "purchase_items_tenant_insert" ON "public"."purchase_items" FOR INSERT WITH CHECK (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "purchase_items_tenant_select" ON "public"."purchase_items" FOR SELECT USING (("tenant_id" = "public"."my_tenant_id"()));



ALTER TABLE "public"."purchases" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "purchases_tenant_insert" ON "public"."purchases" FOR INSERT WITH CHECK (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "purchases_tenant_select" ON "public"."purchases" FOR SELECT USING (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "purchases_tenant_update" ON "public"."purchases" FOR UPDATE USING (("tenant_id" = "public"."my_tenant_id"())) WITH CHECK (("tenant_id" = "public"."my_tenant_id"()));



ALTER TABLE "public"."role_permissions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."roles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "roles_tenant" ON "public"."roles" USING (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "rp_tenant" ON "public"."role_permissions" USING (("tenant_id" = "public"."my_tenant_id"()));



ALTER TABLE "public"."sale_items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sale_items_tenant_insert" ON "public"."sale_items" FOR INSERT WITH CHECK (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "sale_items_tenant_select" ON "public"."sale_items" FOR SELECT USING (("tenant_id" = "public"."my_tenant_id"()));



ALTER TABLE "public"."sales" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sales_tenant_insert" ON "public"."sales" FOR INSERT WITH CHECK (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "sales_tenant_select" ON "public"."sales" FOR SELECT USING (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "sales_tenant_update" ON "public"."sales" FOR UPDATE USING (("tenant_id" = "public"."my_tenant_id"())) WITH CHECK (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "tenant_select" ON "public"."tenants" FOR SELECT USING (("tenant_id" = "public"."my_tenant_id"()));



ALTER TABLE "public"."tenants" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."transits" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "transits_insert" ON "public"."transits" FOR INSERT WITH CHECK (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "transits_select" ON "public"."transits" FOR SELECT USING (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "transits_update" ON "public"."transits" FOR UPDATE USING (("tenant_id" = "public"."my_tenant_id"())) WITH CHECK (("tenant_id" = "public"."my_tenant_id"()));



ALTER TABLE "public"."trucks" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "trucks_tenant_delete" ON "public"."trucks" FOR DELETE USING (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "trucks_tenant_insert" ON "public"."trucks" FOR INSERT WITH CHECK (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "trucks_tenant_select" ON "public"."trucks" FOR SELECT USING (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "trucks_tenant_update" ON "public"."trucks" FOR UPDATE USING (("tenant_id" = "public"."my_tenant_id"())) WITH CHECK (("tenant_id" = "public"."my_tenant_id"()));



CREATE POLICY "ur_tenant" ON "public"."user_roles" USING (("tenant_id" = "public"."my_tenant_id"()));



ALTER TABLE "public"."user_profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_roles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."wallet_transactions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "wallet_transactions_select" ON "public"."wallet_transactions" FOR SELECT USING (("tenant_id" = "public"."my_tenant_id"()));



ALTER TABLE "public"."wallets" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "wallets_select" ON "public"."wallets" FOR SELECT USING (("tenant_id" = "public"."my_tenant_id"()));



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."audit_lpg_brands"() TO "anon";
GRANT ALL ON FUNCTION "public"."audit_lpg_brands"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."audit_lpg_brands"() TO "service_role";



GRANT ALL ON FUNCTION "public"."audit_trucks"() TO "anon";
GRANT ALL ON FUNCTION "public"."audit_trucks"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."audit_trucks"() TO "service_role";



GRANT ALL ON FUNCTION "public"."complete_purchase"("p_purchase_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."complete_purchase"("p_purchase_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."complete_purchase"("p_purchase_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_area_officer"("p_plant_id" "uuid", "p_officer_name" "text", "p_whatsapp_phone" "text", "p_email" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_area_officer"("p_plant_id" "uuid", "p_officer_name" "text", "p_whatsapp_phone" "text", "p_email" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_area_officer"("p_plant_id" "uuid", "p_officer_name" "text", "p_whatsapp_phone" "text", "p_email" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_custom_transit"("p_truck_id" "uuid", "p_fee" numeric, "p_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_custom_transit"("p_truck_id" "uuid", "p_fee" numeric, "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_custom_transit"("p_truck_id" "uuid", "p_fee" numeric, "p_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_gas_plant"("p_plant_name" "text", "p_brand_id" "uuid", "p_location" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_gas_plant"("p_plant_name" "text", "p_brand_id" "uuid", "p_location" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_gas_plant"("p_plant_name" "text", "p_brand_id" "uuid", "p_location" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_inventory_movement"("p_item_id" "uuid", "p_movement_type" "text", "p_filled_quantity_change" integer, "p_empty_quantity_change" integer, "p_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_inventory_movement"("p_item_id" "uuid", "p_movement_type" "text", "p_filled_quantity_change" integer, "p_empty_quantity_change" integer, "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_inventory_movement"("p_item_id" "uuid", "p_movement_type" "text", "p_filled_quantity_change" integer, "p_empty_quantity_change" integer, "p_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_lpg_brand"("p_brand_name" "text", "p_description" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_lpg_brand"("p_brand_name" "text", "p_description" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_lpg_brand"("p_brand_name" "text", "p_description" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_pos_sale"("p_customer_phone" character varying, "p_customer_name" character varying, "p_customer_shop_name" character varying, "p_customer_address" "text", "p_customer_tier" character varying, "p_discount_amount" numeric, "p_exchange_fee" numeric, "p_notes" "text", "p_items" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."create_pos_sale"("p_customer_phone" character varying, "p_customer_name" character varying, "p_customer_shop_name" character varying, "p_customer_address" "text", "p_customer_tier" character varying, "p_discount_amount" numeric, "p_exchange_fee" numeric, "p_notes" "text", "p_items" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_pos_sale"("p_customer_phone" character varying, "p_customer_name" character varying, "p_customer_shop_name" character varying, "p_customer_address" "text", "p_customer_tier" character varying, "p_discount_amount" numeric, "p_exchange_fee" numeric, "p_notes" "text", "p_items" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_purchase"("p_truck_id" "uuid", "p_plant_id" "uuid", "p_transport_cost" numeric, "p_labour_cost" numeric, "p_notes" "text", "p_items" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."create_purchase"("p_truck_id" "uuid", "p_plant_id" "uuid", "p_transport_cost" numeric, "p_labour_cost" numeric, "p_notes" "text", "p_items" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_purchase"("p_truck_id" "uuid", "p_plant_id" "uuid", "p_transport_cost" numeric, "p_labour_cost" numeric, "p_notes" "text", "p_items" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_truck"("p_name" character varying, "p_serial_no" character varying, "p_capacity" integer, "p_size" "public"."truck_size") TO "anon";
GRANT ALL ON FUNCTION "public"."create_truck"("p_name" character varying, "p_serial_no" character varying, "p_capacity" integer, "p_size" "public"."truck_size") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_truck"("p_name" character varying, "p_serial_no" character varying, "p_capacity" integer, "p_size" "public"."truck_size") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_truck"("p_name" character varying, "p_serial_no" character varying, "p_capacity" integer, "p_size" "public"."truck_size", "p_location" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."create_truck"("p_name" character varying, "p_serial_no" character varying, "p_capacity" integer, "p_size" "public"."truck_size", "p_location" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_truck"("p_name" character varying, "p_serial_no" character varying, "p_capacity" integer, "p_size" "public"."truck_size", "p_location" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."ensure_tenant_wallets"("p_tenant_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."ensure_tenant_wallets"("p_tenant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ensure_tenant_wallets"("p_tenant_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."list_gas_plants"("p_active_only" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."list_gas_plants"("p_active_only" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."list_gas_plants"("p_active_only" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."list_lpg_brands"("p_active_only" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."list_lpg_brands"("p_active_only" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."list_lpg_brands"("p_active_only" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."list_purchases"() TO "anon";
GRANT ALL ON FUNCTION "public"."list_purchases"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."list_purchases"() TO "service_role";



GRANT ALL ON FUNCTION "public"."list_trucks"("p_active_only" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."list_trucks"("p_active_only" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."list_trucks"("p_active_only" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."my_tenant_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."my_tenant_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."my_tenant_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."setup_business"("p_business_name" "text", "p_owner_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."setup_business"("p_business_name" "text", "p_owner_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."setup_business"("p_business_name" "text", "p_owner_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_area_officer"("p_officer_id" "uuid", "p_officer_name" "text", "p_whatsapp_phone" "text", "p_email" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."update_area_officer"("p_officer_id" "uuid", "p_officer_name" "text", "p_whatsapp_phone" "text", "p_email" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_area_officer"("p_officer_id" "uuid", "p_officer_name" "text", "p_whatsapp_phone" "text", "p_email" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_gas_plant"("p_plant_id" "uuid", "p_plant_name" "text", "p_brand_id" "uuid", "p_location" "text", "p_is_active" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."update_gas_plant"("p_plant_id" "uuid", "p_plant_name" "text", "p_brand_id" "uuid", "p_location" "text", "p_is_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_gas_plant"("p_plant_id" "uuid", "p_plant_name" "text", "p_brand_id" "uuid", "p_location" "text", "p_is_active" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."update_item_inventory"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_item_inventory"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_item_inventory"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_lpg_brand"("p_brand_id" "uuid", "p_brand_name" "text", "p_description" "text", "p_is_active" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."update_lpg_brand"("p_brand_id" "uuid", "p_brand_name" "text", "p_description" "text", "p_is_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_lpg_brand"("p_brand_id" "uuid", "p_brand_name" "text", "p_description" "text", "p_is_active" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."update_purchase"("p_purchase_id" "uuid", "p_transport_cost" numeric, "p_labour_cost" numeric, "p_notes" "text", "p_items" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."update_purchase"("p_purchase_id" "uuid", "p_transport_cost" numeric, "p_labour_cost" numeric, "p_notes" "text", "p_items" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_purchase"("p_purchase_id" "uuid", "p_transport_cost" numeric, "p_labour_cost" numeric, "p_notes" "text", "p_items" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_transit_costs"("p_transit_id" "uuid", "p_driver_cost" numeric, "p_helper_cost" numeric, "p_oil_cost" numeric, "p_additional_costs" "jsonb", "p_status" "public"."transit_status") TO "anon";
GRANT ALL ON FUNCTION "public"."update_transit_costs"("p_transit_id" "uuid", "p_driver_cost" numeric, "p_helper_cost" numeric, "p_oil_cost" numeric, "p_additional_costs" "jsonb", "p_status" "public"."transit_status") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_transit_costs"("p_transit_id" "uuid", "p_driver_cost" numeric, "p_helper_cost" numeric, "p_oil_cost" numeric, "p_additional_costs" "jsonb", "p_status" "public"."transit_status") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_truck"("p_truck_id" "uuid", "p_name" character varying, "p_serial_no" character varying, "p_capacity" integer, "p_size" "public"."truck_size", "p_is_active" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."update_truck"("p_truck_id" "uuid", "p_name" character varying, "p_serial_no" character varying, "p_capacity" integer, "p_size" "public"."truck_size", "p_is_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_truck"("p_truck_id" "uuid", "p_name" character varying, "p_serial_no" character varying, "p_capacity" integer, "p_size" "public"."truck_size", "p_is_active" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."update_truck"("p_truck_id" "uuid", "p_name" character varying, "p_serial_no" character varying, "p_capacity" integer, "p_size" "public"."truck_size", "p_status" "public"."truck_status", "p_location" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."update_truck"("p_truck_id" "uuid", "p_name" character varying, "p_serial_no" character varying, "p_capacity" integer, "p_size" "public"."truck_size", "p_status" "public"."truck_status", "p_location" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_truck"("p_truck_id" "uuid", "p_name" character varying, "p_serial_no" character varying, "p_capacity" integer, "p_size" "public"."truck_size", "p_status" "public"."truck_status", "p_location" character varying) TO "service_role";



GRANT ALL ON TABLE "public"."area_officers" TO "anon";
GRANT ALL ON TABLE "public"."area_officers" TO "authenticated";
GRANT ALL ON TABLE "public"."area_officers" TO "service_role";



GRANT ALL ON TABLE "public"."audit_logs" TO "anon";
GRANT ALL ON TABLE "public"."audit_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."audit_logs" TO "service_role";



GRANT ALL ON TABLE "public"."customer_transactions" TO "anon";
GRANT ALL ON TABLE "public"."customer_transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."customer_transactions" TO "service_role";



GRANT ALL ON TABLE "public"."customers" TO "anon";
GRANT ALL ON TABLE "public"."customers" TO "authenticated";
GRANT ALL ON TABLE "public"."customers" TO "service_role";



GRANT ALL ON TABLE "public"."gas_plants" TO "anon";
GRANT ALL ON TABLE "public"."gas_plants" TO "authenticated";
GRANT ALL ON TABLE "public"."gas_plants" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_movements" TO "anon";
GRANT ALL ON TABLE "public"."inventory_movements" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_movements" TO "service_role";



GRANT ALL ON TABLE "public"."items" TO "anon";
GRANT ALL ON TABLE "public"."items" TO "authenticated";
GRANT ALL ON TABLE "public"."items" TO "service_role";



GRANT ALL ON TABLE "public"."lpg_brands" TO "anon";
GRANT ALL ON TABLE "public"."lpg_brands" TO "authenticated";
GRANT ALL ON TABLE "public"."lpg_brands" TO "service_role";



GRANT ALL ON TABLE "public"."permissions" TO "anon";
GRANT ALL ON TABLE "public"."permissions" TO "authenticated";
GRANT ALL ON TABLE "public"."permissions" TO "service_role";



GRANT ALL ON TABLE "public"."price_books" TO "anon";
GRANT ALL ON TABLE "public"."price_books" TO "authenticated";
GRANT ALL ON TABLE "public"."price_books" TO "service_role";



GRANT ALL ON TABLE "public"."purchase_items" TO "anon";
GRANT ALL ON TABLE "public"."purchase_items" TO "authenticated";
GRANT ALL ON TABLE "public"."purchase_items" TO "service_role";



GRANT ALL ON TABLE "public"."purchases" TO "anon";
GRANT ALL ON TABLE "public"."purchases" TO "authenticated";
GRANT ALL ON TABLE "public"."purchases" TO "service_role";



GRANT ALL ON TABLE "public"."role_permissions" TO "anon";
GRANT ALL ON TABLE "public"."role_permissions" TO "authenticated";
GRANT ALL ON TABLE "public"."role_permissions" TO "service_role";



GRANT ALL ON TABLE "public"."roles" TO "anon";
GRANT ALL ON TABLE "public"."roles" TO "authenticated";
GRANT ALL ON TABLE "public"."roles" TO "service_role";



GRANT ALL ON TABLE "public"."sale_items" TO "anon";
GRANT ALL ON TABLE "public"."sale_items" TO "authenticated";
GRANT ALL ON TABLE "public"."sale_items" TO "service_role";



GRANT ALL ON TABLE "public"."sales" TO "anon";
GRANT ALL ON TABLE "public"."sales" TO "authenticated";
GRANT ALL ON TABLE "public"."sales" TO "service_role";



GRANT ALL ON TABLE "public"."tenants" TO "anon";
GRANT ALL ON TABLE "public"."tenants" TO "authenticated";
GRANT ALL ON TABLE "public"."tenants" TO "service_role";



GRANT ALL ON TABLE "public"."transits" TO "anon";
GRANT ALL ON TABLE "public"."transits" TO "authenticated";
GRANT ALL ON TABLE "public"."transits" TO "service_role";



GRANT ALL ON TABLE "public"."trucks" TO "anon";
GRANT ALL ON TABLE "public"."trucks" TO "authenticated";
GRANT ALL ON TABLE "public"."trucks" TO "service_role";



GRANT ALL ON TABLE "public"."user_profiles" TO "anon";
GRANT ALL ON TABLE "public"."user_profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."user_profiles" TO "service_role";



GRANT ALL ON TABLE "public"."user_roles" TO "anon";
GRANT ALL ON TABLE "public"."user_roles" TO "authenticated";
GRANT ALL ON TABLE "public"."user_roles" TO "service_role";



GRANT ALL ON TABLE "public"."wallet_transactions" TO "anon";
GRANT ALL ON TABLE "public"."wallet_transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."wallet_transactions" TO "service_role";



GRANT ALL ON TABLE "public"."wallets" TO "anon";
GRANT ALL ON TABLE "public"."wallets" TO "authenticated";
GRANT ALL ON TABLE "public"."wallets" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";







