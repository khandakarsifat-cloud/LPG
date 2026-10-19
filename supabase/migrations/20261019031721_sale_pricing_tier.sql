-- A sale owns its pricing tier independently of the customer's current tier.
-- Historical sales have no tier snapshot: infer from the linked customer once.
alter table public.sales add column sale_tier text;
update public.sales set sale_tier = 'retail';
update public.sales s
set sale_tier = 'wholesale'
from public.customers c
where c.tenant_id = s.tenant_id and c.customer_id = s.customer_id and c.tier = 'wholesale';
alter table public.sales alter column sale_tier set default 'retail';
alter table public.sales alter column sale_tier set not null;
alter table public.sales add constraint sales_sale_tier_check check (sale_tier in ('retail', 'wholesale'));
comment on column public.sales.sale_tier is 'Pricing tier captured at checkout. Legacy rows inferred from linked customer at migration time.';

-- Keep the established checkout signature, capability gate, tenant checks,
-- submitted-price contract and atomic stock/accounting transaction intact.
CREATE OR REPLACE FUNCTION public.create_pos_sale(p_customer_phone character varying, p_customer_name character varying, p_customer_shop_name character varying, p_customer_address text, p_customer_tier character varying, p_discount_amount numeric, p_exchange_fee numeric, p_notes text, p_items jsonb, p_customer_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
    v_user_id        UUID := auth.uid();
    v_tenant_id      UUID;
    v_sale_tier      text := COALESCE(p_customer_tier, 'retail');
    v_customer_id    UUID;
    v_customer_phone VARCHAR;
    v_customer_name  VARCHAR;
    v_existing_id    UUID;
    v_sale_id        UUID;
    v_item           JSONB;
    v_subtotal       NUMERIC(12,2) := 0.00;
    v_total_amount   NUMERIC(12,2);
    v_item_total     NUMERIC(12,2);
    v_total_refills  INT := 0;
    v_total_empties  INT := 0;
    v_filled_qty_change INT;
    v_empty_qty_change  INT;
    v_filled_stock      INT;
BEGIN
    PERFORM app_private.require_any_permission(array['pos:sell']);
    IF v_sale_tier NOT IN ('retail', 'wholesale') THEN
        RAISE EXCEPTION 'Invalid sale tier';
    END IF;
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

    v_tenant_id := app_private.current_tenant_id();
    IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'No tenant found for user'; END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
        RAISE EXCEPTION 'Cart must be an array';
    END IF;
    IF COALESCE(p_discount_amount, 0) < 0 OR COALESCE(p_exchange_fee, 0) < 0 THEN
        RAISE EXCEPTION 'Discount and exchange fee cannot be negative';
    END IF;

    IF p_customer_phone IS NULL OR TRIM(p_customer_phone) = '' THEN
        RAISE EXCEPTION 'Customer phone number is required to complete a sale';
    END IF;

    IF p_customer_id IS NOT NULL THEN
        SELECT customer_id, phone, name
        INTO v_customer_id, v_customer_phone, v_customer_name
        FROM public.customers
        WHERE tenant_id = v_tenant_id
          AND customer_id = p_customer_id;

        IF v_customer_id IS NULL THEN
            RAISE EXCEPTION 'Selected customer was not found';
        END IF;
    ELSE
        SELECT customer_id INTO v_existing_id
        FROM public.customers
        WHERE tenant_id = v_tenant_id
          AND phone = TRIM(p_customer_phone);

        IF v_existing_id IS NOT NULL THEN
            RAISE EXCEPTION 'This phone number belongs to a saved customer. Select the saved customer before completing the sale.';
        END IF;

        INSERT INTO public.customers (tenant_id, name, phone, shop_name, address, tier)
        VALUES (
            v_tenant_id,
            COALESCE(NULLIF(TRIM(p_customer_name), ''), 'Unknown'),
            TRIM(p_customer_phone),
            NULLIF(TRIM(COALESCE(p_customer_shop_name, '')), ''),
            NULLIF(TRIM(COALESCE(p_customer_address, '')), ''),
            COALESCE(p_customer_tier, 'retail')
        )
        RETURNING customer_id, phone, name
        INTO v_customer_id, v_customer_phone, v_customer_name;
    END IF;

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

    INSERT INTO public.sales (tenant_id, customer_id, sale_tier, status, discount_amount, exchange_fee, notes, created_by)
    VALUES (v_tenant_id, v_customer_id, v_sale_tier, 'completed',
            COALESCE(p_discount_amount, 0), COALESCE(p_exchange_fee, 0), p_notes, v_user_id)
    RETURNING sale_id INTO v_sale_id;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        IF v_item->>'type' IS NULL OR v_item->>'type' NOT IN ('refill','package','empty_return')
            OR (v_item->>'quantity')::INT IS NULL OR (v_item->>'quantity')::INT <= 0
            OR (v_item->>'unit_price')::NUMERIC IS NULL OR (v_item->>'unit_price')::NUMERIC < 0 THEN
            RAISE EXCEPTION 'Invalid sale line';
        END IF;
        SELECT filled_quantity INTO v_filled_stock FROM public.items
        WHERE tenant_id = v_tenant_id AND item_id = (v_item->>'item_id')::UUID FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Item not found'; END IF;
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

        IF v_filled_qty_change < 0 THEN
            SELECT filled_quantity INTO v_filled_stock
            FROM public.items
            WHERE tenant_id = v_tenant_id AND item_id = (v_item->>'item_id')::UUID;

            IF v_filled_stock < ABS(v_filled_qty_change) THEN
                RAISE EXCEPTION 'Insufficient filled stock for item %', (v_item->>'item_id');
            END IF;
        END IF;

        IF v_filled_qty_change != 0 OR v_empty_qty_change != 0 THEN
            INSERT INTO public.inventory_movements
                (tenant_id, item_id, movement_type, reference_type, reference_id,
                 filled_quantity_change, empty_quantity_change, notes, created_by)
            VALUES
                (v_tenant_id, (v_item->>'item_id')::UUID, 'sale', 'sale', v_sale_id,
                 v_filled_qty_change, v_empty_qty_change,
                 'POS Sale #' || LEFT(v_sale_id::TEXT, 8),
                 v_user_id);

            -- The movement trigger applies this stock delta exactly once.
        END IF;

        INSERT INTO public.sale_items (tenant_id, sale_id, item_id, type, quantity, unit_price, line_total)
        VALUES (
            v_tenant_id, v_sale_id,
            (v_item->>'item_id')::UUID,
            (v_item->>'type')::public.sale_item_type,
            (v_item->>'quantity')::INT,
            (v_item->>'unit_price')::NUMERIC,
            v_item_total
        );
    END LOOP;

    v_total_amount := v_subtotal - COALESCE(p_discount_amount, 0) + COALESCE(p_exchange_fee, 0);
    IF v_total_amount < 0 THEN RAISE EXCEPTION 'Sale total cannot be negative'; END IF;
    IF EXISTS (SELECT 1 FROM public.items i WHERE i.tenant_id = v_tenant_id
        AND i.item_id IN (SELECT (x->>'item_id')::UUID FROM jsonb_array_elements(p_items) x)
        AND (i.filled_quantity < 0 OR i.empty_quantity < 0)) THEN
        RAISE EXCEPTION 'Insufficient stock';
    END IF;
    UPDATE public.sales SET subtotal = v_subtotal, total_amount = v_total_amount WHERE tenant_id = v_tenant_id AND sale_id = v_sale_id;

    INSERT INTO public.customer_transactions (tenant_id, customer_id, type, amount, reference_id, created_by)
    VALUES
        (v_tenant_id, v_customer_id, 'invoice_charge',  -v_total_amount, v_sale_id, v_user_id),
        (v_tenant_id, v_customer_id, 'payment_receipt',  v_total_amount, v_sale_id, v_user_id);

    PERFORM app_private.ensure_tenant_wallets(v_tenant_id);
    UPDATE public.wallets SET balance = balance + v_total_amount, updated_at = NOW()
    WHERE tenant_id = v_tenant_id AND type = 'dealership';

    RETURN jsonb_build_object(
        'sale_id',        v_sale_id,
        'sale_tier',      v_sale_tier,
        'customer_id',    v_customer_id,
        'subtotal',       v_subtotal,
        'total_amount',   v_total_amount,
        'customer_phone', v_customer_phone,
        'customer_name',  COALESCE(NULLIF(TRIM(v_customer_name), ''), 'Unknown')
    );
END;
$function$;

alter function public.create_pos_sale(character varying,character varying,character varying,text,character varying,numeric,numeric,text,jsonb,uuid) owner to postgres;
revoke all on function public.create_pos_sale(character varying,character varying,character varying,text,character varying,numeric,numeric,text,jsonb,uuid) from public, anon;
grant execute on function public.create_pos_sale(character varying,character varying,character varying,text,character varying,numeric,numeric,text,jsonb,uuid) to authenticated;
notify pgrst, 'reload schema';
