-- Migration: Add unique constraint on items (brand_id + size_kg + mouth_size)
-- This allows the same brand+weight with different mouth sizes as separate SKUs
-- but prevents true duplicates (same brand+weight+mouth_size).

ALTER TABLE public.items
  ADD CONSTRAINT items_unique_sku
  UNIQUE (tenant_id, brand_id, size_kg, mouth_size);
