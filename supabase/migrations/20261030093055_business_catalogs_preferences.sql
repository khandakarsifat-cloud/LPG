-- Employee job titles are a tenant catalog, independent of application RBAC.
alter table public.employee_types add column is_system boolean not null default false;
create unique index employee_type_name_ci on public.employee_types(tenant_id,lower(name));
create table public.business_weights (
 tenant_id uuid not null references public.tenants on delete cascade,
 size_kg numeric(8,3) not null check(size_kg>0 and size_kg<10000),
 is_active boolean not null default true,
 primary key(tenant_id,size_kg)
);
alter table public.business_weights enable row level security;
revoke all on public.business_weights from public,anon,authenticated;

create function app_private.initialize_business_catalogs() returns trigger language plpgsql set search_path='' as $$
begin
 insert into public.employee_types(tenant_id,name,is_system)
 select new.tenant_id,n,true from unnest(array['Owner','Manager','Salesman','Driver','Helper','General Staff']) n;
 insert into public.business_weights(tenant_id,size_kg) select new.tenant_id,n from unnest(array[5,12,25,35]) n;
 insert into public.attendance_settings(tenant_id,cutoff) values(new.tenant_id,'00:00');
 return new;
end $$;
create trigger initialize_business_catalogs after insert on public.tenants for each row execute function app_private.initialize_business_catalogs();

-- Preserve existing custom titles and every existing product weight.
insert into public.employee_types(tenant_id,name,is_system)
 select t.tenant_id,n,true from public.tenants t cross join unnest(array['Owner','Manager','Salesman','Driver','Helper','General Staff']) n
 on conflict(tenant_id,lower(name)) do update set name=excluded.name,is_system=true,is_active=true;
insert into public.business_weights(tenant_id,size_kg)
 select tenant_id,n from public.tenants cross join unnest(array[5,12,25,35]) n
 union select tenant_id,size_kg from public.items on conflict do nothing;
alter table public.items add constraint item_configured_weight_fk foreign key(tenant_id,size_kg) references public.business_weights(tenant_id,size_kg);
create index item_weight_usage on public.items(tenant_id,size_kg);

create or replace function app_private.resolve_employee_type(p_tenant_id uuid,p_employee_type_name text)
returns uuid language plpgsql set search_path='' as $$
declare result uuid;
begin
 select employee_type_id into result from public.employee_types where tenant_id=p_tenant_id
 and lower(name)=lower(coalesce(nullif(trim(p_employee_type_name),''),'General Staff')) and is_active for share;
 if result is null then raise exception 'Select an active employee role from Settings'; end if;
 return result;
end $$;

create function public.get_business_catalogs() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['settings:manage','employees:view','employees:manage','payroll:view','payroll:pay','inventory:view','inventory:manage','pos:sell','purchases:view','purchases:manage']);
begin
 return jsonb_build_object('roles',coalesce((select jsonb_agg(jsonb_build_object('id',r.employee_type_id,'name',r.name,'active',r.is_active,'system',r.is_system,
 'assigned',(select count(*) from public.employees e where e.tenant_id=t and e.employee_type_id=r.employee_type_id)) order by r.is_system desc,r.name)
 from public.employee_types r where r.tenant_id=t),'[]'),
 'weights',coalesce((select jsonb_agg(jsonb_build_object('size_kg',w.size_kg,'active',w.is_active,
 'assigned',(select count(*) from public.items i where i.tenant_id=t and i.size_kg=w.size_kg)) order by w.size_kg) from public.business_weights w where w.tenant_id=t),'[]'));
end $$;

create function public.save_business_catalog(p_kind text,p_id text,p_name text,p_active boolean,p_remove boolean default false)
returns void language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('settings:manage'); r public.employee_types; w numeric;
begin
 if p_active is null or p_remove is null then raise exception 'Choose a valid status'; end if;
 if p_kind='role' then
  if p_id is null then
   if p_remove or nullif(trim(p_name),'') is null or length(trim(p_name))>120 then raise exception 'Enter a role name (up to 120 characters)'; end if;
   insert into public.employee_types(tenant_id,name,is_active) values(t,trim(p_name),p_active);
  else
   select * into r from public.employee_types where tenant_id=t and employee_type_id=p_id::uuid for update;
   if not found then raise exception 'Role not found'; end if;
   if r.is_system then raise exception 'Predefined roles cannot be renamed, disabled or removed'; end if;
   if p_remove then
    if exists(select 1 from public.employees where tenant_id=t and employee_type_id=r.employee_type_id) then raise exception 'Assigned roles can be disabled, but cannot be removed'; end if;
    delete from public.employee_types where tenant_id=t and employee_type_id=r.employee_type_id;
   else
    if nullif(trim(p_name),'') is null or length(trim(p_name))>120 then raise exception 'Enter a role name (up to 120 characters)'; end if;
    update public.employee_types set name=trim(p_name),is_active=p_active where tenant_id=t and employee_type_id=r.employee_type_id;
   end if;
  end if;
 elsif p_kind='weight' then
  w:=coalesce(p_id,p_name)::numeric;
  if w<=0 or w>=10000 or w<>round(w,3) or w is null then raise exception 'Enter a positive weight with up to three decimal places'; end if;
  if p_remove then
   if exists(select 1 from public.items where tenant_id=t and size_kg=w) then raise exception 'Used weights can be disabled, but cannot be removed'; end if;
   delete from public.business_weights where tenant_id=t and size_kg=w;
  else insert into public.business_weights(tenant_id,size_kg,is_active) values(t,w,p_active)
   on conflict(tenant_id,size_kg) do update set is_active=excluded.is_active;
  end if;
 else raise exception 'Invalid catalog'; end if;
end $$;

create function app_private.require_configured_weight() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform 1 from public.business_weights where tenant_id=new.tenant_id and size_kg=new.size_kg and is_active for share;
 if not found then raise exception 'Select an active weight from Settings'; end if;
 return new;
end $$;
create trigger require_configured_weight before insert or update of size_kg on public.items for each row execute function app_private.require_configured_weight();

create table public.user_preferences (
 user_id uuid primary key references auth.users(id) on delete cascade,
 theme text not null check(theme in ('light','dark'))
);
alter table public.user_preferences enable row level security;
revoke all on public.user_preferences from public,anon,authenticated;
create function public.get_my_preferences() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform app_private.current_tenant_id();
 if auth.uid() is null then raise insufficient_privilege; end if;
 return jsonb_build_object('theme',(select theme from public.user_preferences where user_id=auth.uid()));
end $$;
create function public.save_my_preferences(p_theme text) returns void language plpgsql security definer set search_path='' as $$
begin
 if app_private.current_tenant_id() is null then raise insufficient_privilege; end if;
 insert into public.user_preferences(user_id,theme) values(auth.uid(),p_theme) on conflict(user_id) do update set theme=excluded.theme;
end $$;
create function public.save_business_profile(p_name text) returns void language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('settings:manage');
begin
 if nullif(trim(p_name),'') is null or length(trim(p_name))>255 then raise exception 'Business name is required (up to 255 characters)'; end if;
 update public.tenants set business_name=trim(p_name) where tenant_id=t;
end $$;
revoke all on function public.get_business_catalogs(),public.save_business_catalog(text,text,text,boolean,boolean),public.get_my_preferences(),public.save_my_preferences(text),public.save_business_profile(text) from public,anon;
grant execute on function public.get_business_catalogs(),public.save_business_catalog(text,text,text,boolean,boolean),public.get_my_preferences(),public.save_my_preferences(text),public.save_business_profile(text) to authenticated;
revoke all on function app_private.initialize_business_catalogs(),app_private.require_configured_weight() from public,anon,authenticated;

insert into public.permissions(permission_id,description) values('preferences:manage','Manage own appearance preferences');
insert into public.role_permissions(tenant_id,role_id,permission_id) select tenant_id,role_id,'preferences:manage' from public.roles;
CREATE OR REPLACE FUNCTION public.setup_business(p_business_name text, p_owner_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
    v_user_id    UUID := auth.uid();
    v_user_email TEXT;
    v_tenant_id  UUID;
    v_owner_role UUID;
    v_mgr_role   UUID;
    v_sales_role UUID;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    -- Lock the identity so concurrent setup cannot create a second membership.
    SELECT email INTO v_user_email FROM auth.users
    WHERE id = v_user_id AND is_anonymous IS NOT TRUE FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501'; END IF;
    IF EXISTS (SELECT 1 FROM public.user_profiles WHERE user_id = v_user_id) THEN
        RAISE EXCEPTION 'Business membership already exists' USING ERRCODE = '42501';
    END IF;
    IF NULLIF(TRIM(p_business_name), '') IS NULL OR NULLIF(TRIM(p_owner_name), '') IS NULL THEN
        RAISE EXCEPTION 'Business and owner names are required';
    END IF;

    -- 1. Create the Tenant
    INSERT INTO public.tenants (business_name, status)
    VALUES (p_business_name, 'active')
    RETURNING tenant_id INTO v_tenant_id;

    -- 2. Create User Profile
    INSERT INTO public.user_profiles (user_id, tenant_id, full_name, email)
    VALUES (v_user_id, v_tenant_id, p_owner_name, v_user_email);

    -- 3. Create default roles: Owner, Manager, Salesman
    INSERT INTO public.roles (tenant_id, name) VALUES (v_tenant_id, 'OWNER')   RETURNING role_id INTO v_owner_role;
    INSERT INTO public.roles (tenant_id, name) VALUES (v_tenant_id, 'MANAGER') RETURNING role_id INTO v_mgr_role;
    INSERT INTO public.roles (tenant_id, name) VALUES (v_tenant_id, 'SALESMAN') RETURNING role_id INTO v_sales_role;

    -- 4. Owner gets ALL permissions
    INSERT INTO public.role_permissions (tenant_id, role_id, permission_id)
    SELECT v_tenant_id, v_owner_role, permission_id FROM public.permissions;

    -- 5. Manager currently gets the same complete tenant permission set
    INSERT INTO public.role_permissions (tenant_id, role_id, permission_id)
    SELECT v_tenant_id, v_mgr_role, permission_id
    FROM public.permissions
    ;

    -- 6. Salesman gets only Dashboard, POS and receipt capabilities
    INSERT INTO public.role_permissions (tenant_id, role_id, permission_id)
    SELECT v_tenant_id, v_sales_role, permission_id
    FROM public.permissions
    WHERE permission_id IN ('dashboard:view','pos:sell','sales:view','receipts:print','preferences:manage');

    -- 7. Assign Owner role to registering user
    INSERT INTO public.user_roles (tenant_id, user_id, role_id)
    VALUES (v_tenant_id, v_user_id, v_owner_role);

    -- 8. Display metadata only; authorization never trusts user metadata
    UPDATE auth.users
    SET raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object(
        'full_name', p_owner_name,
        'tenant_id', v_tenant_id::text
    )
    WHERE id = v_user_id;

    RETURN jsonb_build_object(
        'tenant_id', v_tenant_id,
        'user_id',   v_user_id,
        'role',      'OWNER'
    );
END;
$function$;


-- Match the application's established trusted routine/table owner.
alter table public.business_weights owner to postgres;
alter table public.user_preferences owner to postgres;
alter function app_private.initialize_business_catalogs() owner to postgres;
alter function app_private.require_configured_weight() owner to postgres;
