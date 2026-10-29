import type { ActivityFilters, Employee, EmployeeFilters } from '../types/employee';
export const employeeUnitLabels = { gas_business: 'Gas business', truck_business: 'Truck business' };
export const defaultEmployeeFilters: EmployeeFilters = { search: '', status: 'all', unit: 'all', type: '', sort: 'name_asc' };
export const defaultActivityFilters: ActivityFilters = { search: '', kind: '', from: '', to: '' };
export const employeeToday = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Dhaka', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
export const employeeMonth = () => employeeToday().slice(0, 7) + '-01';
export const monthLabel = (month: string) => new Date(`${month}T00:00:00+06:00`).toLocaleDateString('en-BD', { month: 'long', year: 'numeric', timeZone: 'Asia/Dhaka' });
export const employeeDate = (date: string) => new Date(`${date.slice(0, 10)}T00:00:00+06:00`).toLocaleDateString('en-BD', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'Asia/Dhaka' });
export const employeeFilterCount = (filters: EmployeeFilters) => (['status', 'unit', 'type'] as const).filter(key => filters[key] !== defaultEmployeeFilters[key]).length;

export const employeeStatus = (employee: Employee) => employee.joining_date > employeeToday() ? 'Not started' : employee.is_active ? 'Active' : 'Inactive';
