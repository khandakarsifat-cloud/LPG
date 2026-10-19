# Employees and payroll

[Architecture and documentation map](../architecture.md) · [Authorization](../../supabase/authorization.md)

## Model and ownership

[Employees.tsx](../../src/pages/Employees.tsx) contains profile forms, selection, payment history and payment entry. [useEmployees](../../src/hooks/useEmployees.ts) owns their RPC/query contracts and number/phone normalization. The [employee migration](../../supabase/migrations/20260702164710_employees.sql) defines five tables and payment constraints/triggers; [reconciliation](../../supabase/migrations/20261004165315_reconcile_live_schema.sql) adjusts category foreign keys/names; [authorization](../../supabase/migrations/20261004192158_tenant_permission_authorization.sql) supplies current RPCs and private helpers.

The directory shows twelve employees per desktop page and four per phone page. Phone records expose salary, status and actions without horizontal scrolling; selecting a name brings the details panel into view. Payment and yearly totals still use the full payment collection, independently of visible directory/history pages.

Employees are business records, not Supabase Auth accounts or RBAC memberships. Business unit is `gas_business` or `truck_business`; it labels the profile and does not select a payroll wallet. Employee type names are tenant-scoped, resolved/created by the profile RPC and reactivated when reused. Blank type is allowed; salary must be nonnegative.

## Profile and phone transactions

`create_employee` and `update_employee` require `employees:manage`. Each atomically saves profile/type and phone rows. Update replaces the entire phone set; validation failure rolls back the profile update and phone deletion/inserts together.

- At least one phone and exactly one primary are required by the workflow. A partial unique index also enforces at most one primary per employee.
- Phone strings are unique across employees in a tenant, and use the same numeric Bangladesh formats as [customer phones](sales-and-inventory.md#customer-and-price-rules). Their uniqueness is independent of customers; local/prefixed representations are distinct stored strings.
- Current salary is a profile default for payment entry, not a computation of salary owed or an enforced salary payment amount.
- `deactivate_employee` hard-deletes an employee with no payments (phones cascade), but soft-deactivates one with payment history. The update RPC can reactivate/edit profiles. Keep historical payment references intact.

## Payment history

`create_employee_payment` requires `payroll:pay` and an active tenant employee/category. It records the category's trusted code, positive amount, required payment date, optional description and actor. Default categories are salary, bonus, commission, trips and other; the private seeding helper runs in employee creation/payment/category listing and restores these defaults to active.

| Category | Required fields and uniqueness |
| --- | --- |
| Salary | Year 2000–2100 and month 1–12; partial unique index allows one payment per tenant/employee/salary year/month |
| Trips | Positive trip count; salary year/month must be absent |
| Bonus, commission, other | Neither salary year/month nor trip count |

SQL constraints and RPC checks enforce these combinations. The form's duplicate-salary warning is only an early check; its loaded history may be incomplete/unavailable, so the unique index is the authority. The payment amount can differ from current salary.

UPDATE and DELETE triggers reject changes to payment rows, including privileged row mutations that reach those triggers. There is no correction/reversal workflow. Editing salary or profile fields does not rewrite payment amounts or periods. Recording a payment does **not** debit either wallet, insert a wallet transaction, calculate outstanding pay, or link trips to logistics transits.

The UI's annual totals use `salary_year` for salary records and the year of `payment_date` for other records. Its “Monthly salary run” is the sum of active employees' current salary, not an executed batch or payment obligation calculation. There is no automatic salary batch, attendance-derived calculation or ZKTeco linkage; the [attendance listener](../../zk-test/test.cjs) is an isolated logging prototype.

## Access, refresh and checks

Employee profile/count lists use employee view/manage permissions; full payment/category lists use payroll view/pay. These capabilities are separate even though the current employee screen requests both kinds of data. Preserve database gates when changing UI admission; see the [authorization guide](../../supabase/authorization.md).

Profile/payment mutations invalidate the `employees` family and affected payment reads in [useEmployees](../../src/hooks/useEmployees.ts). [authorization.sql](../../supabase/tests/authorization.sql) covers permission/tenant boundaries and legitimate profile/payment calls. It is not a comprehensive payroll constraint/lifecycle suite. Payment immutability, database uniqueness, atomic phone replacement and historical references need to remain intact when extending this module. Execution prerequisites are in [Operations](../../OPERATIONS.md#10-checks-and-tests); no device attendance, browser or live payroll acceptance was reverified for this documentation.
