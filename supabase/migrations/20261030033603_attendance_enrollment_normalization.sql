-- Normalize once before both the ownership check and the upsert. Do not allow
-- whitespace variants to move an enrollment's existing scans to another person.
create or replace function public.link_attendance_user(p_device_id uuid,p_pin text,p_employee_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('employees:manage'); prior uuid;
begin
 p_pin:=trim(p_pin);
 if not exists(select 1 from public.attendance_devices where tenant_id=t and device_id=p_device_id)
 or not exists(select 1 from public.employees where tenant_id=t and employee_id=p_employee_id) then raise exception 'Device or employee not found'; end if;
 perform 1 from public.attendance_devices where tenant_id=t and device_id=p_device_id for update;
 select employee_id into prior from public.attendance_users where tenant_id=t and device_id=p_device_id and pin=p_pin;
 if prior is not null and prior<>p_employee_id then raise exception 'This enrollment already belongs to another employee. Use a new enrollment ID on the device'; end if;
 insert into public.attendance_users(tenant_id,device_id,pin,employee_id) values(t,p_device_id,p_pin,p_employee_id)
 on conflict(tenant_id,device_id,pin) do update set employee_id=excluded.employee_id;
end $$;
