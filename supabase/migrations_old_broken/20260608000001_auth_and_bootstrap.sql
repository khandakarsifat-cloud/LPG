-- =============================================================================
-- NexusLPG Auth Bootstrap Migration
-- Creates an atomic RPC that sets up a business (tenant) along with its owner.
-- Called immediately after Supabase Auth creates the user account.
-- =============================================================================

-- Ensure user_profiles references auth.users from Supabase Auth
-- (Uncomment if you haven't already set this in the core schema)
-- ALTER TABLE user_profiles ADD CONSTRAINT fk_auth_user
--   FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

-- Seed the default permissions that every tenant will use
INSERT INTO permissions (permission_id, description) VALUES
  ('pos:sell',             'Can create a sales invoice at POS'),
  ('pos:void',             'Can void/cancel a sales invoice'),
  ('inventory:view',       'Can view inventory balances'),
  ('inventory:adjust',     'Can create manual inventory adjustments'),
  ('inventory:purchase',   'Can log a purchase / replenishment'),
  ('customers:view',       'Can view customer list and details'),
  ('customers:manage',     'Can create and edit customers'),
  ('finance:view',         'Can view financial ledger and statements'),
  ('finance:manage',       'Can record payments and credits'),
  ('logistics:view',       'Can view trips and staff assignments'),
  ('logistics:manage',     'Can create and complete delivery trips'),
  ('settings:view',        'Can view system settings'),
  ('settings:manage',      'Can modify roles, users, and system config')
ON CONFLICT (permission_id) DO NOTHING;


-- =============================================================================
-- FUNCTION: setup_business
-- Called once after a successful auth.signUp() to wire up the tenant and owner.
-- =============================================================================
CREATE OR REPLACE FUNCTION setup_business(
  p_business_name TEXT,
  p_owner_name    TEXT
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER -- Runs as the function owner (postgres), not the calling user
SET search_path = public
AS $$
DECLARE
  v_user_id   UUID := auth.uid();   -- The newly authenticated user's ID
  v_tenant_id UUID;
  v_role_id   UUID;
BEGIN
  -- Guard: must be called by an authenticated user
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- 1. Create the Tenant (Business)
  INSERT INTO tenants (business_name, status)
  VALUES (p_business_name, 'active')
  RETURNING tenant_id INTO v_tenant_id;

  -- 2. Create the User Profile linked to the tenant
  INSERT INTO user_profiles (user_id, tenant_id, email, is_active)
  VALUES (
    v_user_id,
    v_tenant_id,
    (SELECT email FROM auth.users WHERE id = v_user_id),
    true
  );

  -- 3. Create the "Owner" role for this tenant with all permissions
  INSERT INTO roles (tenant_id, name)
  VALUES (v_tenant_id, 'Owner')
  RETURNING role_id INTO v_role_id;

  -- 4. Grant ALL permissions to the Owner role
  INSERT INTO role_permissions (tenant_id, role_id, permission_id)
  SELECT v_tenant_id, v_role_id, permission_id
  FROM permissions;

  -- 5. Assign the Owner role to this user
  INSERT INTO user_roles (tenant_id, user_id, role_id)
  VALUES (v_tenant_id, v_user_id, v_role_id);

  -- 6. Store owner display name in auth.users raw_user_meta_data
  UPDATE auth.users
  SET raw_user_meta_data = raw_user_meta_data || jsonb_build_object(
    'full_name', p_owner_name,
    'tenant_id', v_tenant_id::text
  )
  WHERE id = v_user_id;

  -- Return the created context
  RETURN jsonb_build_object(
    'tenant_id', v_tenant_id,
    'user_id',   v_user_id,
    'role',      'Owner'
  );
END;
$$;

-- Grant execute to authenticated users only
GRANT EXECUTE ON FUNCTION setup_business(TEXT, TEXT) TO authenticated;


-- =============================================================================
-- RLS for user_profiles
-- Users can only see/manage their own profile within their tenant.
-- =============================================================================
ALTER TABLE user_profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own profile"
ON user_profiles FOR SELECT
USING (user_id = auth.uid());

CREATE POLICY "Users can update their own profile"
ON user_profiles FOR UPDATE
USING (user_id = auth.uid());


-- =============================================================================
-- RLS for tenants
-- Users can only see the tenant they belong to.
-- =============================================================================
ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Tenant members can view their tenant"
ON tenants FOR SELECT
USING (
  tenant_id IN (
    SELECT tenant_id FROM user_profiles WHERE user_id = auth.uid()
  )
);


-- =============================================================================
-- RLS for roles & permissions
-- =============================================================================
ALTER TABLE roles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Tenant isolation on roles"
ON roles FOR ALL
USING (
  tenant_id IN (
    SELECT tenant_id FROM user_profiles WHERE user_id = auth.uid()
  )
);

ALTER TABLE role_permissions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Tenant isolation on role_permissions"
ON role_permissions FOR ALL
USING (
  tenant_id IN (
    SELECT tenant_id FROM user_profiles WHERE user_id = auth.uid()
  )
);

ALTER TABLE user_roles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Tenant isolation on user_roles"
ON user_roles FOR ALL
USING (
  tenant_id IN (
    SELECT tenant_id FROM user_profiles WHERE user_id = auth.uid()
  )
);
