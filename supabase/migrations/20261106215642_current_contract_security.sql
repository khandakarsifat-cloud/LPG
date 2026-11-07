-- Private maintenance state remains inaccessible to application roles.
alter table app_private.business_deletions enable row level security;
revoke all on app_private.business_deletions from public, anon, authenticated, service_role;
