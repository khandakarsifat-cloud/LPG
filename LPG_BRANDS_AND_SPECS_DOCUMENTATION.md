# LPG Brands & Cylinder Specifications Implementation

## Overview

This document outlines the implementation of LPG brand management and cylinder specifications (weight and mouth size) in the NexusLPG ERP system. These features enable businesses to manage their associated LPG brands and define cylinder-specific attributes.

---

## Features Implemented

### 1. **LPG Brands Management**

#### Database Table: `lpg_brands`

A new table has been created to store LPG brand information for each tenant:

```sql
CREATE TABLE lpg_brands (
    tenant_id    UUID        NOT NULL,
    brand_id     UUID        NOT NULL DEFAULT uuid_generate_v4(),
    brand_name   VARCHAR(100) NOT NULL,
    description  TEXT,
    is_active    BOOLEAN     NOT NULL DEFAULT true,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, brand_id),
    FOREIGN KEY (tenant_id) REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    UNIQUE (tenant_id, brand_name)
);
```

**Features:**
- Multi-tenant isolation: Each tenant has their own set of brands
- Soft delete via `is_active` flag
- Unique constraint on brand name per tenant
- Audit logging via trigger
- Full Row-Level Security (RLS) policies

#### Database Functions

Three RPC functions have been created:

1. **`create_lpg_brand(p_brand_name TEXT, p_description TEXT)`**
   - Creates a new LPG brand for the authenticated user's tenant
   - Returns: `{ brand_id, brand_name, description }`

2. **`update_lpg_brand(p_brand_id UUID, p_brand_name TEXT, p_description TEXT, p_is_active BOOLEAN)`**
   - Updates an existing brand
   - All parameters except `p_brand_id` are optional (use null to keep unchanged)
   - Returns: `{ brand_id, message }`

3. **`list_lpg_brands(p_active_only BOOLEAN DEFAULT true)`**
   - Lists brands for the current tenant
   - Filters by active status if requested
   - Returns table with: `brand_id, brand_name, description, is_active, created_at`

### 2. **Cylinder Specifications**

#### Enums

Two new PostgreSQL enums have been created:

```sql
CREATE TYPE cylinder_weight AS ENUM ('5kg', '12kg', '25kg', '35kg');
CREATE TYPE mouth_size AS ENUM ('20mm', '22mm');
```

#### Items Table Extensions

The `items` table has been extended with three new columns:

```sql
ALTER TABLE items
ADD COLUMN brand_id UUID,                    -- FK to lpg_brands
ADD COLUMN cylinder_weight cylinder_weight,  -- '5kg', '12kg', '25kg', '35kg'
ADD COLUMN mouth_size mouth_size,            -- '20mm', '22mm'
ADD COLUMN updated_at TIMESTAMPTZ;

ALTER TABLE items
ADD CONSTRAINT fk_items_brand_id
FOREIGN KEY (tenant_id, brand_id) 
REFERENCES lpg_brands(tenant_id, brand_id) ON DELETE SET NULL;
```

**Features:**
- Brand relationship: Items now reference `lpg_brands` instead of storing brand as text
- Cylinder specifications are optional
- Backward compatible: Original `brand` column remains for legacy data

### 3. **UI Components**

#### BrandManagement Component
**File:** `src/components/business/BrandManagement.tsx`

Features:
- List all brands with status indicators
- Create new brands with optional descriptions
- Edit existing brands
- Activate/deactivate brands (soft delete)
- Real-time error handling and success messages
- Responsive grid layout for brand cards

#### Settings Page
**File:** `src/pages/Settings.tsx`

Features:
- Tabbed interface with "Business Profile" and "LPG Brands" tabs
- Dedicated tab for brand management
- Foundation for future business profile settings

### 4. **Hooks & API Integration**

#### useBrands Hook
**File:** `src/hooks/useBrands.ts`

Provides:
- `useLPGBrands()` - Query hook to fetch all brands
- `useCreateBrand()` - Mutation hook to create a new brand
- `useUpdateBrand()` - Mutation hook to update an existing brand

All hooks use React Query for caching and invalidation.

#### Updated useInventory Hooks
**File:** `src/hooks/useInventory.ts`

Enhanced queries now include:
- Brand relationship data (`lpg_brands`)
- New cylinder specifications (`cylinder_weight`, `mouth_size`)
- Proper field selection for all related data

### 5. **TypeScript Types**

#### New Types
**File:** `src/types/inventory.ts`

```typescript
export type CylinderWeight = '5kg' | '12kg' | '25kg' | '35kg';
export type MouthSize = '20mm' | '22mm';

export interface LPGBrand {
  tenant_id: string;
  brand_id: string;
  brand_name: string;
  description: string | null;
  is_active: boolean;
  created_at: string;
  updated_at: string;
}

export interface ItemWithBrand extends Item {
  lpg_brands: LPGBrand | null;
}

export interface CreateBrandPayload {
  brand_name: string;
  description?: string;
}
```

#### Updated Item Interface
```typescript
export interface Item {
  tenant_id: string;
  item_id: string;
  brand_id: string | null;
  brand: string;
  size_kg: number;
  type: ItemType;
  cylinder_weight: CylinderWeight | null;
  mouth_size: MouthSize | null;
  created_at: string;
  updated_at?: string;
}
```

#### Constants
- `CYLINDER_WEIGHT_OPTIONS`: Array of available weights
- `MOUTH_SIZE_OPTIONS`: Array of available sizes
- `CYLINDER_WEIGHT_LABELS`: Display labels for weights
- `MOUTH_SIZE_LABELS`: Display labels for sizes

### 6. **UI Updates**

#### AddItemDialog
**File:** `src/components/inventory/AddItemDialog.tsx`

New features:
- Brand dropdown selector (requires at least one brand to exist)
- Optional cylinder weight selector
- Optional mouth size selector
- Form validation ensures brand exists before creation

#### Inventory Page
**File:** `src/pages/Inventory.tsx`

Updated table to display:
- Brand name (from lpg_brands table)
- Size in KG
- **New:** Specifications column showing cylinder weight and mouth size (e.g., "25kg, 22mm")
- Classification type
- Current stock
- Created date

### 7. **App Routing**

**File:** `src/App.tsx`

- Settings route now loads the `SettingsPage` component instead of placeholder
- Full integration with protected route hierarchy

### 8. **Database Migration**

**File:** `supabase/migrations/20260608000003_lpg_brands_and_specs.sql`

Complete migration includes:
- Enum type creation
- `lpg_brands` table with indexes
- Items table extension
- RLS policies for brand table
- Audit logging trigger
- Three RPC functions for brand operations
- Performance indexes

---

## Workflow

### For Business Owners: Adding Brands

1. Navigate to **Settings → LPG Brands** tab
2. Click **"Add Brand"** button
3. Enter:
   - Brand Name (required, e.g., "Indane", "Bharat Gas")
   - Description (optional)
4. Click **"Add Brand"**
5. View the brand in the list below with an "Active" status badge

### For Business Owners: Managing Brands

- **Edit**: Click the Edit button on any brand card to modify details
- **Deactivate**: Click the Deactivate button to soft-delete (data remains, item creation blocked)
- **Activate**: Click Activate on a deactivated brand to re-enable

### For Inventory Managers: Creating Items

1. Navigate to **Inventory → Item Registry**
2. Click **"Add Item"** button
3. Select:
   - **Brand** (required, dropdown from active brands)
   - **Weight (KG)** (required, any numeric value)
   - **Cylinder Weight** (optional, enum: 5kg, 12kg, 25kg, 35kg)
   - **Mouth Size** (optional, enum: 20mm, 22mm)
   - **Classification Type** (required)
4. Click **"Create Item"**

The item now appears in the inventory with all specifications visible.

---

## Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    User Action                              │
│          (Add/Edit Brand or Create Item)                    │
└──────────────────┬──────────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────────┐
│              React Component / Hook                         │
│  (BrandManagement, AddItemDialog, useBrands, useInventory)  │
└──────────────────┬──────────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────────┐
│            Supabase Client Library                           │
│    (RPC calls or direct table inserts)                      │
└──────────────────┬──────────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────────┐
│          PostgreSQL Database                                │
│  (lpg_brands, items tables)                                │
│          ↓                                                   │
│  RLS Policies → Tenant Isolation                           │
│          ↓                                                   │
│  Triggers → Audit Logging                                  │
└─────────────────────────────────────────────────────────────┘
```

---

## Security Considerations

### Row-Level Security (RLS)

All brand-related operations are protected by RLS policies:

```sql
CREATE POLICY "lpg_brands_tenant_select" ON lpg_brands FOR SELECT
    USING (tenant_id = my_tenant_id());
-- Similar policies for INSERT, UPDATE, DELETE
```

**Guarantees:**
- Users can only see/modify brands in their own tenant
- No cross-tenant data leakage
- Enforced at database level

### Audit Logging

Every insert, update, or delete on `lpg_brands` is logged:

```sql
CREATE TRIGGER trg_audit_lpg_brands
    AFTER INSERT OR UPDATE OR DELETE ON lpg_brands
    FOR EACH ROW EXECUTE FUNCTION audit_lpg_brands();
```

**Details captured:**
- Who performed the action (`auth.uid()`)
- What changed (old_data, new_data)
- When it happened (created_at)

---

## Backward Compatibility

The original `brand` VARCHAR column in the `items` table remains unchanged. This ensures:
- Existing items continue to work
- No data loss during migration
- Gradual transition to the new brand relationship model

**Recommendation:** Update legacy data by:
1. Creating corresponding entries in `lpg_brands`
2. Running a data migration to populate `brand_id` where `brand` matches

---

## Future Enhancements

Potential additions to this feature set:

1. **Brand Logo Upload**: Store brand logos in Supabase Storage
2. **Brand Tiers**: Different pricing tiers per brand
3. **Supplier Mapping**: Link brands to suppliers
4. **Batch Operations**: Bulk import brands from CSV
5. **Brand Analytics**: Track inventory and sales by brand
6. **Predefined Specifications**: Common presets for different brands (e.g., "Standard Indane 14.2kg, 22mm")

---

## Testing Checklist

- [ ] Create a brand in Settings → LPG Brands
- [ ] Edit the brand name and description
- [ ] Deactivate and reactivate the brand
- [ ] Attempt to create an item without any brands (should show message)
- [ ] Create an item with brand, weight, and specifications
- [ ] Verify item appears in Inventory → Item Registry with all specs
- [ ] Check that only active brands appear in the item creation dropdown
- [ ] Verify RLS by checking no cross-tenant brand access
- [ ] Test audit logs show brand operations

---

## File Summary

| File | Purpose |
|------|---------|
| `supabase/migrations/20260608000003_lpg_brands_and_specs.sql` | Database migration |
| `src/types/inventory.ts` | TypeScript type definitions |
| `src/hooks/useBrands.ts` | React Query hooks for brand operations |
| `src/hooks/useInventory.ts` | Updated inventory hooks with brand relations |
| `src/components/business/BrandManagement.tsx` | Brand management UI component |
| `src/pages/Settings.tsx` | Settings page with brand management tab |
| `src/components/inventory/AddItemDialog.tsx` | Updated add item form |
| `src/pages/Inventory.tsx` | Updated inventory page display |
| `src/App.tsx` | Updated routing for settings page |

---

## Getting Started

1. **Apply the migration**:
   ```bash
   # Run in Supabase SQL Editor
   supabase/migrations/20260608000003_lpg_brands_and_specs.sql
   ```

2. **Test brand creation**:
   - Navigate to Settings → LPG Brands
   - Add your first brand

3. **Create items with specs**:
   - Navigate to Inventory → Add Item
   - Select the brand and optional specifications
   - Create item and verify in registry

4. **Verify audit trail**:
   - Check audit_logs table for brand operations

---

## Support

For issues or questions regarding this implementation:
- Check the Supabase RLS policies for permission errors
- Verify tenant_id is properly set in user_profiles
- Review migration logs for SQL errors
- Check browser console for client-side errors
