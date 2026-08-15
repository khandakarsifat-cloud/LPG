import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';

export type BusinessUnit = 'gas_business' | 'truck_business';
export type PaymentCategoryKind = 'salary' | 'bonus' | 'commission' | 'trips' | 'other';

export interface EmployeePhone {
  employee_phone_id?: string;
  phone: string;
  is_primary: boolean;
}

export interface Employee {
  employee_id: string;
  name: string;
  address: string | null;
  current_salary: number;
  business_unit: BusinessUnit;
  notes: string | null;
  is_active: boolean;
  created_at: string;
  updated_at: string;
  employee_type_id: string | null;
  employee_type_name: string | null;
  phones: EmployeePhone[];
  primary_phone: string | null;
  payment_count: number;
}

export interface EmployeeInput {
  name: string;
  phones: EmployeePhone[];
  address: string | null;
  current_salary: number;
  employee_type_name: string | null;
  business_unit: BusinessUnit;
  notes: string | null;
  is_active?: boolean;
}

export interface EmployeePaymentCategory {
  category_id: string;
  code: string;
  name: string;
  category_kind: PaymentCategoryKind;
  is_active: boolean;
}

export interface EmployeePayment {
  payment_id: string;
  employee_id: string;
  employee_name: string;
  category_id: string;
  category_code: string;
  category_name: string;
  category_kind: PaymentCategoryKind;
  amount: number;
  payment_date: string;
  description: string | null;
  salary_year: number | null;
  salary_month: number | null;
  trip_count: number | null;
  created_at: string;
}

export interface EmployeePaymentInput {
  employee_id: string;
  category_id: string;
  amount: number;
  payment_date: string;
  description: string | null;
  salary_year: number | null;
  salary_month: number | null;
  trip_count: number | null;
}

export const employeeKeys = {
  all: ['employees'] as const,
  list: ['employees', 'list'] as const,
  categories: ['employees', 'payment-categories'] as const,
  payments: (employeeId?: string) => ['employees', 'payments', employeeId] as const,
};

const asEmployees = (rows: unknown[]): Employee[] =>
  rows.map((row) => {
    const employee = row as Omit<Employee, 'phones'> & { phones?: EmployeePhone[] | string | null };
    const phones = Array.isArray(employee.phones)
      ? employee.phones
      : typeof employee.phones === 'string'
        ? (JSON.parse(employee.phones) as EmployeePhone[])
        : [];

    return {
      ...employee,
      current_salary: Number(employee.current_salary ?? 0),
      payment_count: Number(employee.payment_count ?? 0),
      phones,
    };
  });

export const useEmployees = () =>
  useQuery<Employee[]>({
    queryKey: employeeKeys.list,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_employees');
      if (error) throw error;
      return asEmployees(data ?? []);
    },
  });

export const useEmployeePaymentCategories = () =>
  useQuery<EmployeePaymentCategory[]>({
    queryKey: employeeKeys.categories,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_employee_payment_categories');
      if (error) throw error;
      return (data ?? []) as EmployeePaymentCategory[];
    },
  });

export const useEmployeePayments = (employeeId?: string) =>
  useQuery<EmployeePayment[]>({
    queryKey: employeeKeys.payments(employeeId),
    enabled: Boolean(employeeId),
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_employee_payments', {
        p_employee_id: employeeId,
      });
      if (error) throw error;
      return ((data ?? []) as EmployeePayment[]).map((payment) => ({
        ...payment,
        amount: Number(payment.amount ?? 0),
      }));
    },
  });

export const useCreateEmployee = () => {
  const qc = useQueryClient();
  return useMutation<unknown, Error, EmployeeInput>({
    mutationFn: async (payload) => {
      const { data, error } = await supabase.rpc('create_employee', {
        p_name: payload.name,
        p_phones: payload.phones,
        p_address: payload.address,
        p_current_salary: payload.current_salary,
        p_employee_type_name: payload.employee_type_name,
        p_business_unit: payload.business_unit,
        p_notes: payload.notes,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: employeeKeys.all });
    },
  });
};

export const useUpdateEmployee = () => {
  const qc = useQueryClient();
  return useMutation<unknown, Error, { employeeId: string; payload: EmployeeInput }>({
    mutationFn: async ({ employeeId, payload }) => {
      const { data, error } = await supabase.rpc('update_employee', {
        p_employee_id: employeeId,
        p_name: payload.name,
        p_phones: payload.phones,
        p_address: payload.address,
        p_current_salary: payload.current_salary,
        p_employee_type_name: payload.employee_type_name,
        p_business_unit: payload.business_unit,
        p_notes: payload.notes,
        p_is_active: payload.is_active ?? true,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: (_, variables) => {
      qc.invalidateQueries({ queryKey: employeeKeys.all });
      qc.invalidateQueries({ queryKey: employeeKeys.payments(variables.employeeId) });
    },
  });
};

export const useDeactivateEmployee = () => {
  const qc = useQueryClient();
  return useMutation<unknown, Error, string>({
    mutationFn: async (employeeId) => {
      const { data, error } = await supabase.rpc('deactivate_employee', {
        p_employee_id: employeeId,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: (_, employeeId) => {
      qc.invalidateQueries({ queryKey: employeeKeys.all });
      qc.invalidateQueries({ queryKey: employeeKeys.payments(employeeId) });
    },
  });
};

export const useCreateEmployeePayment = () => {
  const qc = useQueryClient();
  return useMutation<unknown, Error, EmployeePaymentInput>({
    mutationFn: async (payload) => {
      const { data, error } = await supabase.rpc('create_employee_payment', {
        p_employee_id: payload.employee_id,
        p_category_id: payload.category_id,
        p_amount: payload.amount,
        p_payment_date: payload.payment_date,
        p_description: payload.description,
        p_salary_year: payload.salary_year,
        p_salary_month: payload.salary_month,
        p_trip_count: payload.trip_count,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: (_, payload) => {
      qc.invalidateQueries({ queryKey: employeeKeys.all });
      qc.invalidateQueries({ queryKey: employeeKeys.payments(payload.employee_id) });
    },
  });
};
