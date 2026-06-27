-- =============================================================================
-- NexusLPG: Schema Cleanup
-- Drop tables and columns that are no longer used by the application.
-- =============================================================================

-- 1. Drop unused tables (CASCADE automatically handles foreign keys & triggers tied to these tables)
DROP TABLE IF EXISTS inventory_balances CASCADE;
DROP TABLE IF EXISTS trip_staff CASCADE;
DROP TABLE IF EXISTS trips CASCADE;

-- 2. Drop unused columns
ALTER TABLE items DROP COLUMN IF EXISTS type CASCADE;
