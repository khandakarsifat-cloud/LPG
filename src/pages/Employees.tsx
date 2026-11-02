import { useEffect, useState } from 'react';
import { Plus, Search, SlidersHorizontal, Users, RotateCcw, ChevronRight } from 'lucide-react';
import { useAuth } from '../contexts/AuthContext';
import { useEmployeeDirectory, useEmployeeOperation, useEmployeeOverview } from '../hooks/useEmployees';
import { useGridPageSize } from '../hooks/useListPage';
import { defaultEmployeeFilters, employeeFilterCount, employeeUnitLabels, employeeStatus } from '../lib/employee';
import { useEmployeePresence } from '../hooks/useAttendance';
import { DirectorySort } from '../components/ui/DirectorySort';
import { Pagination } from '../components/ui/Pagination';
import { PurchaseDialog, PurchaseSelect } from '../components/purchases/PurchaseControls';
import { EmployeeForm, EmployeeOperationNotice } from '../components/employees/EmployeeForm';
import { EmployeeProfileDialog } from '../components/employees/EmployeeProfile';
import type { EmployeeFilters } from '../types/employee';
import '../components/purchases/purchases.css';
import '../components/employees/employees.css';

export function EmployeesPage() {
 const { can } = useAuth();
 const [filters, setFilters] = useState(defaultEmployeeFilters); const [deferred, setDeferred] = useState(filters);
 const [add, setAdd] = useState(false); const [advanced, setAdvanced] = useState(false); const [profile, setProfile] = useState<string | null>(null);
 useEffect(() => { const timer = setTimeout(() => setDeferred(filters), 200); return () => clearTimeout(timer); }, [filters]);
 const { grid, pageSize } = useGridPageSize(); const query = useEmployeeDirectory(deferred, pageSize); const overview = useEmployeeOverview(); const operation = useEmployeeOperation();
 const presence = useEmployeePresence(query.data?.entries.map(e => e.employee_id) ?? []);
 const disabled = operation.isPending || operation.hasPending; const count = employeeFilterCount(filters); const hasFilters = count > 0 || !!filters.search || filters.sort !== 'name_asc';
 const set = (next: EmployeeFilters) => { setFilters(next); query.setPage(0); };
 return <div className="employee-page">
  <div className="page-header"><div><p className="page-subtitle">Manage your team, salaries and bonuses.</p><small className="employee-team-count">{overview.data ? `${overview.data.active} active · ${overview.data.employees} employees` : 'Loading team…'}</small></div>{can('employees:manage') && <button className="btn btn-primary page-add-button" aria-label="Add employee" disabled={disabled} onClick={() => setAdd(true)}><Plus size={16} /><span>Add employee</span></button>}</div>
  <EmployeeOperationNotice operation={operation} />
  <div className="employee-directory-controls"><div className="employee-search"><Search size={16} /><input className="input-field" aria-label="Search employees" placeholder="Search name, phone or role" value={filters.search} onChange={ev => set({ ...filters, search: ev.target.value })} /></div><DirectorySort value={filters.sort} options={[{label:'Name',asc:'name_asc',desc:'name_desc'},{label:'Monthly salary',asc:'salary_asc',desc:'salary_desc'},{label:'Joining date',asc:'joined_asc',desc:'joined_desc'}]} onChange={sort => set({ ...filters, sort })} /><button className="btn btn-secondary" onClick={() => setAdvanced(true)}><SlidersHorizontal size={15} />Filters{count ? ` · ${count}` : ''}</button>{hasFilters && <button className="btn btn-ghost" onClick={() => set(defaultEmployeeFilters)}><RotateCcw size={14} />Reset</button>}</div>
  <Pagination page={query.data?.page ?? query.page} pageSize={query.data?.pageSize ?? pageSize} total={query.data?.total ?? 0} onChange={query.setPage} label="employees" busy={query.isFetching} alwaysVisible />
  {query.isPending && <p className="employee-empty" role="status">Loading employees…</p>}{query.isError && <p className="purchase-error" role="alert">Employees could not be loaded. <button className="btn btn-secondary" onClick={() => void query.refetch()}>Retry</button></p>}
  <div className="employee-grid adaptive-grid" ref={grid} aria-busy={query.isFetching}>{query.data?.entries.map(e => {
   const attendance = presence.data?.entries.find(a => a.employee_id === e.employee_id);
   const status = presence.isError ? 'Attendance unavailable' : presence.isPending ? 'Loading attendance…' : attendance?.clock_out ? 'Clocked out' : attendance?.clock_in ? 'Clocked in' : 'Not clocked in';
   const instant = attendance?.clock_out ?? attendance?.clock_in;
   const time = (value: string) => new Intl.DateTimeFormat('en-US', { timeZone: presence.data?.timezone ?? 'Asia/Dhaka', hour: 'numeric', minute: '2-digit', hour12: true }).format(new Date(value));
   return <button className="employee-card" key={e.employee_id} data-employee-id={e.employee_id} aria-label={`Open ${e.name}`} onClick={() => setProfile(e.employee_id)}>
   <span className="employee-card-heading"><span className="employee-avatar">{e.name.slice(0, 1).toUpperCase()}</span><span className="employee-card-name"><strong>{e.name}</strong><small>{e.employee_type_name || 'Employee'}</small></span><ChevronRight size={15} /></span>
   <span className="employee-card-body"><span className="employee-card-contact">{e.primary_phone || 'No phone'}</span><span className="employee-card-attendance"><span>{status}</span><strong>{instant ? time(instant) : '—'}</strong>{attendance?.clock_out && attendance.clock_in && <small>Arrived {time(attendance.clock_in)}</small>}</span></span>
   <span className="employee-card-footer"><span>{employeeUnitLabels[e.business_unit]}</span><span className={`employee-status-badge ${e.is_active ? 'active' : 'inactive'}`}>{employeeStatus(e)}</span></span>
  </button>; })}</div>
  {query.data && !query.data.entries.length && <div className="employee-empty"><Users size={26} /><h3>{hasFilters ? 'No matching employees' : 'Your team starts here'}</h3><p>{hasFilters ? 'Change the filters or search another name.' : 'Add an employee and set their monthly salary.'}</p>{hasFilters && <button className="btn btn-secondary" onClick={() => set(defaultEmployeeFilters)}>Clear filters</button>}</div>}
  {add && <EmployeeForm types={overview.data?.types ?? []} operation={operation} onClose={() => setAdd(false)} />}{profile && <EmployeeProfileDialog id={profile} types={overview.data?.types ?? []} operation={operation} onClose={() => setProfile(null)} />}
  {advanced && <EmployeeFiltersDialog filters={filters} types={overview.data?.types ?? []} onApply={next => { set(next); setAdvanced(false); }} onClose={() => setAdvanced(false)} />}
 </div>;
}
function EmployeeFiltersDialog({ filters, types, onApply, onClose }: { filters: EmployeeFilters; types: string[]; onApply: (filters: EmployeeFilters) => void; onClose: () => void }) {
 const [draft, setDraft] = useState(filters);
 return <PurchaseDialog title="Employee filters" compact onClose={onClose}><div className="modal-body employee-form"><PurchaseSelect label="Status" value={draft.status} options={[{ value: 'all', label: 'All employees' }, { value: 'active', label: 'Active' }, { value: 'inactive', label: 'Inactive / not started' }]} onChange={status => setDraft({ ...draft, status })} /><PurchaseSelect label="Business unit" value={draft.unit} options={[{ value: 'all', label: 'All business units' }, ...Object.entries(employeeUnitLabels).map(([value, label]) => ({ value, label }))]} onChange={unit => setDraft({ ...draft, unit })} /><PurchaseSelect label="Role" value={draft.type} options={[{ value: '', label: 'All roles' }, ...types.map(type => ({ value: type, label: type }))]} onChange={type => setDraft({ ...draft, type })} /></div><div className="modal-footer"><button className="btn btn-ghost" onClick={() => setDraft({ ...defaultEmployeeFilters, search: filters.search, sort: filters.sort })}>Reset filters</button><button className="btn btn-secondary" onClick={onClose}>Cancel</button><button className="btn btn-primary" onClick={() => onApply(draft)}>Apply filters</button></div></PurchaseDialog>;
}
