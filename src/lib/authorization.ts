// Business capabilities mirror the database catalog; role names are never UI guards.
export const routePermissions: Record<string, readonly string[]> = {
  '/': ['dashboard:view'],
  '/pos': ['pos:sell'],
  '/inventory': ['inventory:view', 'inventory:manage'],
  '/customers': ['customers:view', 'customers:manage'],
  '/purchases': ['purchases:view', 'purchases:manage'],
  '/logistics': ['logistics:view', 'logistics:manage'],
  '/gas-plants': ['gas_plants:view', 'gas_plants:manage'],
  '/employees': ['employees:view', 'employees:manage'],
  '/settings': ['settings:manage'],
  '/finance': ['finance:view', 'finance:manage'],
};

export const hasAnyPermission = (permissions: readonly string[], required: readonly string[]) =>
  required.some(permission => permissions.includes(permission));
