# Employees

[Attendance](attendance.md) lives inside each employee profile: today's estimate and Attendance history sit beside the selected salary month. Device links are edited in employee forms. One activity timeline combines daily clock-in/out, employment revisions, profile changes, payments and returns. Scans remain independent of salary, bonus and wallet calculations.

[Architecture](../architecture.md) · [Finance](finance.md) · [Logistics](purchases-and-logistics.md) · [Authorization](../../supabase/authorization.md)

## Everyday workflow

[Employees](../../src/pages/Employees.tsx) is a compact employee directory with name/phone/role search, status/unit/role filters, sorting and measured display pagination. Cached server batches stay at 25 records independently of card capacity. Cards open one profile dialog. The profile exposes Pay salary and Give bonus immediately; one Edit button opens all personal, salary and employment fields. Editing and payments replace the contents of that dialog, then open a confirmation showing the proposed changes or payment details before any write. Going back retains the draft. History uses labeled activity colors, wallet tags and month badges to distinguish financial evidence from audit metadata. Today's attendance and the selected salary month sit below personal/contact information, followed by the single activity timeline. There is no global salary month, preparation, bulk payment, advance application or adjustment workspace.

[useEmployees](../../src/hooks/useEmployees.ts) owns RPCs and query invalidation. Shared contracts live in [employee types](../../src/types/employee.ts); UI lives in [employees/](../../src/components/employees/). The profile uses distinct identity, attendance/salary and activity surfaces with readable labels and timestamps beside activity categories. Attendance and employment filters select the same paginated timeline. Employee-only readers receive attendance/profile/employment events without payment or salary-revision amounts; payroll-only readers retain financial history without attendance access. Shared native dialogs, wallet selection, date controls and pagination preserve keyboard and responsive conventions. Profiles are business employees, not Auth memberships.

## Salaries and employment

Migration [20261028090057](../../supabase/migrations/20261028090057_employee_management.sql) establishes one salary model:

| Record | Responsibility |
| --- | --- |
| `employees`, `employee_types`, `employee_phone_numbers` | Profile, role, unit and primary/secondary phone numbers |
| `employee_terms` | Append-only salary/status revisions with effective dates, reasons and actors |
| `employee_salary_months` | One immutable employee/month salary amount, established automatically by its first payment |
| `employee_payments`, `employee_payment_entries` | Immutable salary, named bonus and linked trip payments; wallet splits and linked returns |
| `employee_activity` | Profile changes and archived correction evidence; revisions/payments project directly into unified activity |

Choose any salary month from 2000 through 2100, enter an amount, choose a wallet and pay. Current and past months are calculated on read; future months are available in Pay salary. A future month with a payment also appears in salary history. Multiple partial payments can settle one month. PostgreSQL rejects amounts above its remaining salary. For example, paying Tk 5,000 toward a future Tk 20,000 month establishes that month with Tk 15,000 remaining. Recording the payment does not send funds through a payment provider.

Salary is the full configured monthly rate when active employment overlaps a month; there is no daily proration. Joining/leaving months use the full monthly rate. A month entirely outside active employment has no new salary due. Zero salary supports unpaid and trip-only employees. Existing established months remain payable after an employee leaves.

Salary amount revisions start on the first day of a month; initial joining terms can begin on another day. They cannot precede the current month or the latest revision, and never change an established month's salary. The latest active rate during a month supplies that month's full amount. Employment status changes start today or later. Same-day changes append revisions; the newest saved revision for that date is authoritative. Reactivation restores salary eligibility. Creating an employee may establish an earlier joining date when known. No salary is inferred before the first recorded employment terms. Profile edits use revision checks to reject stale saves.

`remaining salary = fixed monthly salary amount − payments allocated to that month + returned salary payments`

Before a month has a payment, its amount follows applicable revisions. The first payment locks the employee, calculates and saves the amount, and posts funds in the same transaction. Later salary/status revisions preserve it, including paid future months. Salary configuration/history never posts wallet movements.

## Bonuses, corrections and Finance

A bonus needs a custom name, amount, payment date and wallet; its description is optional. Bonuses are immediate payments, never salary adjustments or obligations. They do not change salary paid or remaining. The employee history and Finance ledger show the bonus name and wallet splits. Each salary or bonus payment uses one wallet and defaults to Cash Register. Partial salary payments remain available; subsequent payments may use another wallet. Payment dates and notes remain available. Existing split payments retain their original history and audited return attribution.

Every real-wallet split creates exactly one referenced `wallet_transactions.employee_entry_id`. The existing posting trigger alone changes wallet balances. `payroll_salary`, `payroll_bonus`, `payroll_trips` and `payroll_reversal` remain the shared Finance ledger classifications, not a second employee accounting system. Salary obligations and actual payments are distinct: do not add both when reporting expense. Historical ledger labels remain evidence only; removed categories cannot be created through employee operations.

Return / correct payment requires the actual return date, reason and confirmation that funds returned to the original wallets. It appends a linked return and wallet credits; salary returns reopen the original salary month. To correct month/amount/wallet allocation, record the return and then the correct payment. Each original payment can be returned once. A database constraint rejects infinite payment dates; the RPC also rejects future payment dates. Historical payments without wallet evidence cannot invent a refund. No payment preparation or approvals are introduced.

## Logistics and integrity

Logistics records immutable departure participants and deferred Driver/Helper earnings. Vehicle reassignment affects future transits. Profiles show participation, current/historical assignments and total/paid/outstanding transit earnings. Transit payments use the canonical employee payment operation, may be partial or split across active wallets, and appear in unified activity alongside salary/bonus payments without changing salary balances. PostgreSQL checks the saved participant, caps net payments at role earnings and serializes payment/return/completion on the transit. Completion requires both role balances and non-employee operating costs fully paid; completion makes no wallet posting. Completed payments are locked. See [Logistics](purchases-and-logistics.md).

`save_employee` requires `employees:manage`; `employee_payment_operation` requires `payroll:pay`. Profile/directory reads accept employee or payroll capabilities, while salary-month and financial activity reads require payroll view/pay. Payroll-only users can read wallet names without Finance balances. Tables retain RLS, tenant-qualified keys, denied browser writes and immutable financial/revision records. Internal helpers are unexposed and not browser-callable. Write requests share `finance_requests`, actor-qualified payloads, advisory request locks and original matching results. Browser recovery persists the original request per tenant/user/tab across response loss/reload. Lock order is request → transit when relevant → employee → salary month → ordered wallets.

The migration replaces the former payroll table and RPCs, removes adjustments/advance helpers/preparation/bulk operations, and retains existing salary payable amounts after previous net corrections. Retired corrections become immutable activity evidence. Earlier standalone payment categories become named bonuses while retaining amounts, IDs, dates, descriptions and original source snapshots. Every existing wallet, ledger entry and stock row is asserted unchanged. Applied migrations and their historical replay tests remain intact; none is a runtime compatibility path.

## Verification

- `employees.sql`: rolled-back creation/revisions/status, month calculations, future/partial/repeated single-wallet payments, bonuses, returns, request safety, Logistics, reconciliation and tenant checks.
- `payroll.sql` and `payroll-legacy.before.sql` / `.after.sql`: historical tests executed only at the old migration boundary during disposable replay.
- `run-transaction-concurrency.py`: all current SQL suites in a disposable PostgreSQL database plus duplicate/competing payments, future-month creation, return races, salary revision versus first payment and trip payout versus closure. It removes only that database.
- `tests/employees.browser.cjs`: intercepted API fixtures for responsive cards/profiles, inline edits/payments, future partial payment, named bonuses, search and same-request recovery after response loss/reload.
- `employees-api.mjs --vps --browser`: real Auth/PostgREST and published browser flows in disposable businesses, trusted burner membership inspected read-only, Finance/Logistics integration, accounting reconciliation and original-business fingerprint preservation after fixture cleanup.

Browser emulation does not establish physical PWA/device behavior or bank/mobile-provider settlement.

## Business job titles

Settings manages the existing tenant `employee_types` catalog. Owner, Manager, Salesman, Driver, Helper and General Staff are seeded automatically; custom titles remain business-specific. Employee forms use a selection rather than creating titles implicitly. Predefined titles cannot be renamed/disabled/removed. Assigned custom titles can be renamed or disabled, but removal is rejected. Existing assignments to disabled titles remain editable without forcing a new title. These are job titles, not Auth memberships, and confer no application permissions. Device link changes join the same idempotent profile transaction; [attendance](attendance.md) defines attribution periods and corrections.

Directory cards display Clocked in / Clocked out with the corresponding AM/PM time, or Not clocked in when no arrival is recorded. Clocked-out cards also retain the arrival time. The profile attendance heading displays its current clocked-in/out or unavailable/unlinked status. Crew selection uses Driver-only and Helper-only dropdowns; vehicle saves and transit cost saves show a confirmation dialog before applying changes.

Historical virtual-wallet attribution is archived before removal; existing employee payments and recorded earnings remain intact. The real source wallet stays unknown when evidence is absent, and such entries cannot generate an invented wallet refund. Finance counts incurred transit crew costs once and treats employee trip payments as settlement.
