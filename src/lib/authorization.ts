// Business capabilities mirror the database catalog; role names are never UI guards.
export const routePermissions: Record<string, readonly string[]> = {
  '/': ['dashboard:view'],
  '/pos': ['pos:sell'],
  '/sales': ['sales:view'],
  '/inventory': ['inventory:view', 'inventory:manage'],
  '/customers': ['customers:view', 'customers:manage'],
  '/purchases': ['purchases:view', 'purchases:manage'],
  '/logistics': ['logistics:view', 'logistics:manage'],
  '/employees': ['employees:view', 'employees:manage', 'payroll:view', 'payroll:pay'],
  '/settings': ['settings:manage', 'preferences:manage', 'gas_plants:view', 'gas_plants:manage'],
  '/finance': ['finance:view', 'finance:manage'],
};

export const hasAnyPermission = (permissions: readonly string[], required: readonly string[]) =>
  required.some(permission => permissions.includes(permission));
