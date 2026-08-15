import { type FormEvent, useMemo, useState } from 'react';
import { BadgeDollarSign, BriefcaseBusiness, Pencil, Plus, Search, Users, X } from 'lucide-react';
import {
  type BusinessUnit,
  type Employee,
  type EmployeeInput,
  type EmployeePaymentCategory,
  type EmployeePhone,
  useCreateEmployee,
  useCreateEmployeePayment,
  useEmployeePaymentCategories,
  useEmployeePayments,
  useEmployees,
  useUpdateEmployee,
} from '../hooks/useEmployees';
import { BD_MOBILE_PHONE_ERROR, normalizePhoneInput, validateBDMobilePhone } from '../lib/bdPhone';
import { formatBDT } from '../lib/formatBDT';

const businessUnitLabels: Record<BusinessUnit, string> = {
  gas_business: 'Gas Business',
  truck_business: 'Truck Business',
};

const currentYear = new Date().getFullYear();

const monthOptions = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

const employeeTypeOptions = [
  'Manager',
  'Salesman',
  'Staff',
  'Driver',
  'Helper',
  'Senior Staff',
  'Other',
];

const emptyPhone = (): EmployeePhone => ({ phone: '', is_primary: false });

const toEmployeeInput = (employee?: Employee): EmployeeInput => ({
  name: employee?.name ?? '',
  phones: employee?.phones?.length ? employee.phones.map((phone) => ({ ...phone })) : [{ phone: '', is_primary: true }],
  address: employee?.address ?? '',
  current_salary: employee?.current_salary ?? 0,
  employee_type_name: employee?.employee_type_name ?? '',
  business_unit: employee?.business_unit ?? 'gas_business',
  notes: employee?.notes ?? '',
  is_active: employee?.is_active ?? true,
});

export const EmployeesPage = () => {
  const [searchTerm, setSearchTerm] = useState('');
  const [showInactive, setShowInactive] = useState(false);
  const [selectedEmployeeId, setSelectedEmployeeId] = useState<string | undefined>();
  const [employeeModal, setEmployeeModal] = useState<{ mode: 'create' | 'edit'; employee?: Employee } | null>(null);
  const [paymentEmployee, setPaymentEmployee] = useState<Employee | null>(null);
  const [totalsYear, setTotalsYear] = useState(currentYear);

  const { data: employees = [], isLoading, isError } = useEmployees();
  const { data: categories = [] } = useEmployeePaymentCategories();

  const visibleEmployees = useMemo(() => {
    const term = searchTerm.trim().toLowerCase();
    return employees.filter((employee) => {
      if (!showInactive && !employee.is_active) return false;
      if (!term) return true;
      const text = [
        employee.name,
        employee.employee_type_name,
        businessUnitLabels[employee.business_unit],
        employee.address,
        employee.primary_phone,
        ...employee.phones.map((phone) => phone.phone),
      ]
        .filter(Boolean)
        .join(' ')
        .toLowerCase();
      return text.includes(term);
    });
  }, [employees, searchTerm, showInactive]);

  const selectedEmployee = useMemo(
    () => employees.find((employee) => employee.employee_id === selectedEmployeeId) ?? visibleEmployees[0],
    [employees, selectedEmployeeId, visibleEmployees],
  );

  const { data: payments = [], isLoading: paymentsLoading } = useEmployeePayments(selectedEmployee?.employee_id);

  const yearlyTotals = useMemo(() => {
    return payments
      .filter((payment) => {
        const dateYear = new Date(`${payment.payment_date}T00:00:00`).getFullYear();
        return payment.category_code === 'salary'
          ? payment.salary_year === totalsYear
          : dateYear === totalsYear;
      })
      .reduce(
        (totals, payment) => {
          if (payment.category_code === 'salary') {
            totals.salary += payment.amount;
          } else {
            totals.extra += payment.amount;
          }
          totals.total += payment.amount;
          return totals;
        },
        { salary: 0, extra: 0, total: 0 },
      );
  }, [payments, totalsYear]);

  const activeCount = employees.filter((employee) => employee.is_active).length;
  const salaryTotal = employees
    .filter((employee) => employee.is_active)
    .reduce((sum, employee) => sum + employee.current_salary, 0);

  return (
    <div className="employees-page">
      <div className="page-header">
        <div>
          <h1 className="page-title">Employees</h1>
          <p className="page-subtitle">Manage staff profiles, salary details, and employee payment history.</p>
        </div>
        <button className="btn btn-primary" type="button" onClick={() => setEmployeeModal({ mode: 'create' })}>
          <Plus size={16} />
          Add Employee
        </button>
      </div>

      <div className="stats-grid">
        <div className="stat-card glass-panel">
          <span className="stat-label">Active employees</span>
          <span className="stat-value">{activeCount}</span>
        </div>
        <div className="stat-card glass-panel">
          <span className="stat-label">Monthly salary run</span>
          <span className="stat-value">{formatBDT(salaryTotal)}</span>
        </div>
        <div className="stat-card glass-panel">
          <span className="stat-label">Payment categories</span>
          <span className="stat-value">{categories.length}</span>
        </div>
      </div>

      <div className="employees-toolbar glass-panel">
        <div className="search-bar">
          <Search size={16} className="search-icon" />
          <input
            className="input-field search-input"
            value={searchTerm}
            onChange={(event) => setSearchTerm(event.target.value)}
            placeholder="Search employees, phones, type, or address"
          />
        </div>
        <label className="employees-toggle">
          <input
            type="checkbox"
            checked={showInactive}
            onChange={(event) => setShowInactive(event.target.checked)}
          />
          Show inactive
        </label>
      </div>

      <div className="employees-workspace">
        <section className="glass-panel app-screen-panel">
          {isLoading ? (
            <div className="p-8 text-center" style={{ color: 'var(--text-muted)' }}>Loading employees...</div>
          ) : isError ? (
            <div className="p-8 text-center" style={{ color: 'var(--danger)' }}>Failed to load employees.</div>
          ) : visibleEmployees.length === 0 ? (
            <div className="empty-state" style={{ margin: 'var(--space-lg)' }}>
              <Users size={24} />
              <h2 style={{ margin: 0 }}>No employees found</h2>
              <p style={{ margin: 0 }}>Add an employee to start tracking salaries and other payments.</p>
            </div>
          ) : (
            <div className="table-scroll">
              <table className="data-table employees-table">
                <thead>
                  <tr>
                    <th>Employee</th>
                    <th>Phone</th>
                    <th>Type</th>
                    <th>Unit</th>
                    <th>Salary</th>
                    <th>Status</th>
                    <th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {visibleEmployees.map((employee) => (
                    <tr
                      key={employee.employee_id}
                      className={selectedEmployee?.employee_id === employee.employee_id ? 'employees-row-active' : ''}
                      onClick={() => setSelectedEmployeeId(employee.employee_id)}
                    >
                      <td>
                        <div className="td-strong">{employee.name}</div>
                        <div className="employees-muted">{employee.address || 'No address'}</div>
                      </td>
                      <td>
                        <div>{employee.primary_phone ?? '-'}</div>
                        {employee.phones.length > 1 && (
                          <div className="employees-muted">{employee.phones.length} numbers</div>
                        )}
                      </td>
                      <td>{employee.employee_type_name || '-'}</td>
                      <td>{businessUnitLabels[employee.business_unit]}</td>
                      <td className="td-strong">{formatBDT(employee.current_salary)}</td>
                      <td>
                        <span className={`employee-status ${employee.is_active ? 'employee-status-active' : 'employee-status-inactive'}`}>
                          {employee.is_active ? 'Active' : 'Inactive'}
                        </span>
                      </td>
                      <td>
                        <div className="employees-actions">
                          <button
                            className="btn btn-ghost"
                            type="button"
                            onClick={(event) => {
                              event.stopPropagation();
                              setPaymentEmployee(employee);
                            }}
                            disabled={!employee.is_active}
                          >
                            <BadgeDollarSign size={14} />
                            Pay
                          </button>
                          <button
                            className="topbar-icon-btn"
                            type="button"
                            aria-label="Edit employee"
                            title="Edit employee"
                            onClick={(event) => {
                              event.stopPropagation();
                              setEmployeeModal({ mode: 'edit', employee });
                            }}
                          >
                            <Pencil size={15} />
                          </button>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>

        <EmployeeDetailsPanel
          employee={selectedEmployee}
          payments={payments}
          paymentsLoading={paymentsLoading}
          totalsYear={totalsYear}
          onTotalsYearChange={setTotalsYear}
          yearlyTotals={yearlyTotals}
          onPay={setPaymentEmployee}
          onEdit={(employee) => setEmployeeModal({ mode: 'edit', employee })}
        />
      </div>

      {employeeModal && (
        <EmployeeModal
          mode={employeeModal.mode}
          employee={employeeModal.employee}
          onClose={() => setEmployeeModal(null)}
        />
      )}

      {paymentEmployee && (
        <PaymentModal
          employee={paymentEmployee}
          categories={categories}
          payments={paymentEmployee.employee_id === selectedEmployee?.employee_id ? payments : []}
          onClose={() => setPaymentEmployee(null)}
        />
      )}
    </div>
  );
};

const EmployeeDetailsPanel = ({
  employee,
  payments,
  paymentsLoading,
  totalsYear,
  onTotalsYearChange,
  yearlyTotals,
  onPay,
  onEdit,
}: {
  employee?: Employee;
  payments: ReturnType<typeof useEmployeePayments>['data'];
  paymentsLoading: boolean;
  totalsYear: number;
  onTotalsYearChange: (year: number) => void;
  yearlyTotals: { salary: number; extra: number; total: number };
  onPay: (employee: Employee) => void;
  onEdit: (employee: Employee) => void;
}) => {
  if (!employee) {
    return (
      <aside className="glass-panel employees-detail-panel">
        <div className="empty-state">
          <BriefcaseBusiness size={24} />
          <p style={{ margin: 0 }}>Select an employee to view payment history.</p>
        </div>
      </aside>
    );
  }

  return (
    <aside className="glass-panel employees-detail-panel">
      <div className="employees-detail-header">
        <div>
          <h2>{employee.name}</h2>
          <p>{employee.employee_type_name || 'No type'} | {businessUnitLabels[employee.business_unit]}</p>
        </div>
        <div className="employees-detail-actions">
          <button className="btn btn-ghost" type="button" onClick={() => onEdit(employee)}>
            <Pencil size={14} />
            Edit
          </button>
          <button className="btn btn-primary" type="button" onClick={() => onPay(employee)} disabled={!employee.is_active}>
            <BadgeDollarSign size={14} />
            Payment
          </button>
        </div>
      </div>

      <div className="employees-phone-list">
        {employee.phones.map((phone) => (
          <span key={phone.employee_phone_id ?? phone.phone} className="employee-phone-pill">
            {phone.phone}{phone.is_primary ? ' primary' : ''}
          </span>
        ))}
      </div>

      {employee.notes && <p className="employees-note">{employee.notes}</p>}

      <div className="employees-year-row">
        <h3>Yearly totals</h3>
        <input
          className="input-field"
          type="number"
          min="2000"
          max="2100"
          value={totalsYear}
          onChange={(event) => onTotalsYearChange(Number(event.target.value) || currentYear)}
        />
      </div>
      <div className="employees-total-grid">
        <div>
          <span>Salary</span>
          <strong>{formatBDT(yearlyTotals.salary)}</strong>
        </div>
        <div>
          <span>Extra</span>
          <strong>{formatBDT(yearlyTotals.extra)}</strong>
        </div>
        <div>
          <span>Total paid</span>
          <strong>{formatBDT(yearlyTotals.total)}</strong>
        </div>
      </div>

      <h3 className="employees-history-title">Payment history</h3>
      {paymentsLoading ? (
        <div className="p-8 text-center" style={{ color: 'var(--text-muted)' }}>Loading payments...</div>
      ) : !payments || payments.length === 0 ? (
        <div className="empty-state">
          <BadgeDollarSign size={24} />
          <p style={{ margin: 0 }}>No payments recorded yet.</p>
        </div>
      ) : (
        <div className="employees-payment-list">
          {payments.map((payment) => (
            <div key={payment.payment_id} className="employees-payment-row">
              <div>
                <div className="td-strong">{payment.category_name}</div>
                <div className="employees-muted">
                  {new Date(`${payment.payment_date}T00:00:00`).toLocaleDateString()}
                  {payment.category_code === 'salary' && payment.salary_month && payment.salary_year
                    ? ` | ${monthOptions[payment.salary_month - 1]} ${payment.salary_year}`
                    : ''}
                  {payment.trip_count ? ` | ${payment.trip_count} trips` : ''}
                </div>
                {payment.description && <div className="employees-muted">{payment.description}</div>}
              </div>
              <strong>{formatBDT(payment.amount)}</strong>
            </div>
          ))}
        </div>
      )}
    </aside>
  );
};

const EmployeeModal = ({ mode, employee, onClose }: { mode: 'create' | 'edit'; employee?: Employee; onClose: () => void }) => {
  const [form, setForm] = useState<EmployeeInput>(() => toEmployeeInput(employee));
  const [errorMsg, setErrorMsg] = useState('');
  const createEmployee = useCreateEmployee();
  const updateEmployee = useUpdateEmployee();
  const isPending = createEmployee.isPending || updateEmployee.isPending;

  const setPhone = (index: number, value: string) => {
    const phones = [...form.phones];
    phones[index] = { ...phones[index], phone: normalizePhoneInput(value) };
    setForm({ ...form, phones });
  };

  const setPrimary = (index: number) => {
    setForm({
      ...form,
      phones: form.phones.map((phone, phoneIndex) => ({ ...phone, is_primary: phoneIndex === index })),
    });
  };

  const addPhone = () => {
    setForm({ ...form, phones: [...form.phones, emptyPhone()] });
  };

  const removePhone = (index: number) => {
    const phones = form.phones.filter((_, phoneIndex) => phoneIndex !== index);
    if (!phones.some((phone) => phone.is_primary) && phones[0]) {
      phones[0] = { ...phones[0], is_primary: true };
    }
    setForm({ ...form, phones });
  };

  const validate = () => {
    if (!form.name.trim()) return 'Employee name is required.';
    if (form.current_salary < 0) return 'Current salary cannot be negative.';
    if (form.phones.length === 0) return 'At least one phone number is required.';
    if (form.phones.filter((phone) => phone.is_primary).length !== 1) return 'Mark exactly one phone number as primary.';
    if (form.phones.some((phone) => !validateBDMobilePhone(phone.phone))) return BD_MOBILE_PHONE_ERROR;
    return '';
  };

  const handleSubmit = async (event: FormEvent) => {
    event.preventDefault();
    const validationError = validate();
    if (validationError) {
      setErrorMsg(validationError);
      return;
    }

    try {
      setErrorMsg('');
      const payload = {
        ...form,
        name: form.name.trim(),
        employee_type_name: form.employee_type_name?.trim() || null,
        address: form.address?.trim() || null,
        notes: form.notes?.trim() || null,
      };
      if (mode === 'create') {
        await createEmployee.mutateAsync(payload);
      } else if (employee) {
        await updateEmployee.mutateAsync({ employeeId: employee.employee_id, payload });
      }
      onClose();
    } catch (error: unknown) {
      setErrorMsg(error instanceof Error ? error.message : 'Failed to save employee.');
    }
  };

  return (
    <div className="modal-overlay">
      <div className="modal-content large">
        <div className="modal-header">
          <div>
            <h2 className="modal-title">{mode === 'create' ? 'Add Employee' : 'Edit Employee'}</h2>
            <p className="modal-subtitle employees-muted">At least one phone number is required.</p>
          </div>
          <button className="modal-close" type="button" onClick={onClose} aria-label="Close">
            <X size={20} />
          </button>
        </div>

        <form onSubmit={handleSubmit} className="modal-body employees-form">
          {errorMsg && <div className="auth-error">{errorMsg}</div>}

          <div className="form-grid">
            <div className="input-group">
              <label className="input-label">Name *</label>
              <input className="input-field" value={form.name} onChange={(event) => setForm({ ...form, name: event.target.value })} required />
            </div>
            <div className="input-group">
              <label className="input-label">Employee Type</label>
              <select
                className="input-field"
                value={form.employee_type_name ?? ''}
                onChange={(event) => setForm({ ...form, employee_type_name: event.target.value })}
              >
                <option value="">Select employee type</option>
                {employeeTypeOptions.map((type) => (
                  <option key={type} value={type}>{type}</option>
                ))}
                {form.employee_type_name && !employeeTypeOptions.includes(form.employee_type_name) && (
                  <option value={form.employee_type_name}>{form.employee_type_name}</option>
                )}
              </select>
            </div>
            <div className="input-group">
              <label className="input-label">Current Salary</label>
              <input
                className="input-field"
                type="number"
                min="0"
                step="0.01"
                value={form.current_salary}
                onChange={(event) => setForm({ ...form, current_salary: Number(event.target.value) || 0 })}
              />
            </div>
            <div className="input-group">
              <label className="input-label">Business Unit *</label>
              <select
                className="input-field"
                value={form.business_unit}
                onChange={(event) => setForm({ ...form, business_unit: event.target.value as BusinessUnit })}
              >
                <option value="gas_business">Gas Business</option>
                <option value="truck_business">Truck Business</option>
              </select>
            </div>
          </div>

          <section className="form-section">
            <div className="employees-section-heading">
              <h3 className="form-section-title">Phone Numbers</h3>
              <button className="btn btn-ghost" type="button" onClick={addPhone}>
                <Plus size={14} />
                Add Phone
              </button>
            </div>
            <div className="employees-phone-editor">
              {form.phones.map((phone, index) => (
                <div key={index} className="employees-phone-row">
                  <input
                    className="input-field"
                    type="tel"
                    value={phone.phone}
                    onChange={(event) => setPhone(index, event.target.value)}
                    placeholder="01712345678 or 08801712345678"
                    required
                  />
                  <label className="employees-radio">
                    <input
                      type="radio"
                      checked={phone.is_primary}
                      onChange={() => setPrimary(index)}
                    />
                    Primary
                  </label>
                  <button
                    className="topbar-icon-btn"
                    type="button"
                    aria-label="Remove phone"
                    disabled={form.phones.length === 1}
                    onClick={() => removePhone(index)}
                  >
                    <X size={15} />
                  </button>
                </div>
              ))}
            </div>
          </section>

          <div className="input-group">
            <label className="input-label">Address</label>
            <input className="input-field" value={form.address ?? ''} onChange={(event) => setForm({ ...form, address: event.target.value })} />
          </div>
          <div className="input-group">
            <label className="input-label">Notes</label>
            <textarea className="input-field" rows={3} value={form.notes ?? ''} onChange={(event) => setForm({ ...form, notes: event.target.value })} />
          </div>

          <div className="modal-footer">
            <button className="btn btn-ghost" type="button" onClick={onClose} disabled={isPending}>Cancel</button>
            <button className="btn btn-primary" type="submit" disabled={isPending}>
              {isPending ? 'Saving...' : 'Save Employee'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
};

const PaymentModal = ({
  employee,
  categories,
  payments,
  onClose,
}: {
  employee: Employee;
  categories: EmployeePaymentCategory[];
  payments: ReturnType<typeof useEmployeePayments>['data'];
  onClose: () => void;
}) => {
  const salaryCategory = categories.find((category) => category.code === 'salary');
  const [categoryId, setCategoryId] = useState(salaryCategory?.category_id ?? categories[0]?.category_id ?? '');
  const effectiveCategoryId = categoryId || salaryCategory?.category_id || categories[0]?.category_id || '';
  const selectedCategory = categories.find((category) => category.category_id === effectiveCategoryId);
  const [amount, setAmount] = useState(employee.current_salary);
  const [paymentDate, setPaymentDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [description, setDescription] = useState('');
  const [salaryYear, setSalaryYear] = useState(currentYear);
  const [salaryMonth, setSalaryMonth] = useState(new Date().getMonth() + 1);
  const [tripCount, setTripCount] = useState(1);
  const [errorMsg, setErrorMsg] = useState('');
  const createPayment = useCreateEmployeePayment();

  const changeCategory = (nextCategoryId: string) => {
    const nextCategory = categories.find((category) => category.category_id === nextCategoryId);
    setCategoryId(nextCategoryId);
    setAmount(nextCategory?.code === 'salary' ? employee.current_salary : 0);
  };

  const salaryAlreadyPaid = selectedCategory?.code === 'salary'
    ? payments?.some((payment) => payment.category_code === 'salary' && payment.salary_year === salaryYear && payment.salary_month === salaryMonth)
    : false;

  const handleSubmit = async (event: FormEvent) => {
    event.preventDefault();
    if (!selectedCategory) {
      setErrorMsg('Select a payment category.');
      return;
    }
    if (amount <= 0) {
      setErrorMsg('Payment amount must be greater than zero.');
      return;
    }
    if (salaryAlreadyPaid) {
      setErrorMsg('Salary payment already exists for this employee and month.');
      return;
    }

    try {
      setErrorMsg('');
      await createPayment.mutateAsync({
        employee_id: employee.employee_id,
        category_id: selectedCategory.category_id,
        amount,
        payment_date: paymentDate,
        description: description.trim() || null,
        salary_year: selectedCategory.code === 'salary' ? salaryYear : null,
        salary_month: selectedCategory.code === 'salary' ? salaryMonth : null,
        trip_count: selectedCategory.code === 'trips' ? tripCount : null,
      });
      onClose();
    } catch (error: unknown) {
      setErrorMsg(error instanceof Error ? error.message : 'Failed to record payment.');
    }
  };

  return (
    <div className="modal-overlay">
      <div className="modal-content">
        <div className="modal-header">
          <div>
            <h2 className="modal-title">Record Payment</h2>
            <p className="modal-subtitle employees-muted">{employee.name}</p>
          </div>
          <button className="modal-close" type="button" onClick={onClose} aria-label="Close">
            <X size={20} />
          </button>
        </div>

        <form onSubmit={handleSubmit} className="modal-body employees-form">
          {errorMsg && <div className="auth-error">{errorMsg}</div>}
          <div className="input-group">
            <label className="input-label">Category *</label>
            <select className="input-field" value={effectiveCategoryId} onChange={(event) => changeCategory(event.target.value)} required>
              {categories.map((category) => (
                <option key={category.category_id} value={category.category_id}>{category.name}</option>
              ))}
            </select>
          </div>
          <div className="form-grid">
            <div className="input-group">
              <label className="input-label">Amount *</label>
              <input
                className="input-field"
                type="number"
                min="0.01"
                step="0.01"
                value={amount}
                onChange={(event) => setAmount(Number(event.target.value) || 0)}
                required
              />
            </div>
            <div className="input-group">
              <label className="input-label">Payment Date *</label>
              <input className="input-field" type="date" value={paymentDate} onChange={(event) => setPaymentDate(event.target.value)} required />
            </div>
          </div>

          {selectedCategory?.code === 'salary' && (
            <div className="form-grid">
              <div className="input-group">
                <label className="input-label">Salary Month *</label>
                <select className="input-field" value={salaryMonth} onChange={(event) => setSalaryMonth(Number(event.target.value))}>
                  {monthOptions.map((month, index) => (
                    <option key={month} value={index + 1}>{month}</option>
                  ))}
                </select>
              </div>
              <div className="input-group">
                <label className="input-label">Salary Year *</label>
                <input className="input-field" type="number" min="2000" max="2100" value={salaryYear} onChange={(event) => setSalaryYear(Number(event.target.value) || currentYear)} />
              </div>
            </div>
          )}

          {selectedCategory?.code === 'trips' && (
            <div className="input-group">
              <label className="input-label">Trip Count *</label>
              <input className="input-field" type="number" min="1" value={tripCount} onChange={(event) => setTripCount(Number(event.target.value) || 1)} />
            </div>
          )}

          <div className="input-group">
            <label className="input-label">Description</label>
            <textarea className="input-field" rows={3} value={description} onChange={(event) => setDescription(event.target.value)} />
          </div>

          <div className="modal-footer">
            <button className="btn btn-ghost" type="button" onClick={onClose} disabled={createPayment.isPending}>Cancel</button>
            <button className="btn btn-primary" type="submit" disabled={createPayment.isPending || salaryAlreadyPaid}>
              {createPayment.isPending ? 'Recording...' : 'Record Payment'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
};
