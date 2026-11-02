-- Owner commands distribute every component using the same retained ownership,
-- even when an older caller also supplies a single-business UI default.
do $$declare s text;begin s:=pg_get_functiondef('public.accounting_operation(jsonb,uuid)'::regprocedure);
 s:=replace(s,'jsonb_build_object(''allocations'',alloc,''type_id'',op_type)', 'jsonb_build_object(''allocations'',alloc,''type_id'',op_type,''business_category'',''shared'')');execute s;
 s:=pg_get_functiondef('app_private.post_wallet_entry()'::regprocedure);
 s:=replace(s,'wallet_id=new.wallet_id returning balance', 'wallet_id=new.wallet_id and is_active returning balance');execute s;
end $$;

create or replace function app_private.check_journal_balance() returns trigger language plpgsql security definer set search_path='' set plan_cache_mode='force_custom_plan' as $$begin
 if not exists(select 1 from public.accounting_lines where tenant_id=new.tenant_id and journal_id=new.journal_id)
 or (select sum(amount)<>0 or sum(consolidated_amount)<>0 from public.accounting_lines where tenant_id=new.tenant_id and journal_id=new.journal_id)
 or exists(select 1 from public.accounting_lines where tenant_id=new.tenant_id and journal_id=new.journal_id group by business_category having sum(amount)<>0) then raise exception 'Journal must balance for every business and the consolidated organization';end if;return null;end $$;

create function app_private.guard_wallet_archive() returns trigger language plpgsql set search_path='' as $$begin
 if not new.is_active and exists(select 1 from jsonb_each_text(new.business_balances)b where b.value::numeric<>0) then raise exception 'Clear every business balance before archiving this wallet';end if;return new;end $$;
create trigger guard_wallet_archive before update of is_active on public.wallets for each row execute function app_private.guard_wallet_archive();
alter function app_private.guard_wallet_archive() owner to postgres;
revoke all on function app_private.guard_wallet_archive() from public,anon,authenticated;

-- The unscoped private position helper has the same consolidation contract as
-- the public organization report; raw business amounts remain in typed balances.
create or replace function app_private.accounting_position(ids uuid[],as_of date,before_day boolean default false) returns jsonb language sql stable set search_path='' as $$
 select app_private.scoped_position(ids,as_of,'all',before_day);$$;

-- The canonical LPG package receipt reference is purchase_receipt_new. Correct
-- its type metadata without changing its acquisition/commission amounts.
do $$declare s text;begin s:=pg_get_functiondef('app_private.source_type(uuid,text,uuid,text)'::regprocedure);
 s:=replace(s,'''purchase_receipt_package''','''purchase_receipt_new''');execute s;
end $$;
alter table public.accounting_lines disable trigger accounting_immutable;
update public.accounting_lines l set type_id=app_private.system_type('purchase_receipt')
from public.accounting_journals j join public.inventory_movements m on m.tenant_id=j.tenant_id and m.movement_id=j.source_id
where j.source='inventory' and m.reference_type='purchase_receipt_new' and l.tenant_id=j.tenant_id and l.journal_id=j.journal_id and l.account<>'supplier_receivable';
alter table public.accounting_lines enable trigger accounting_immutable;
update app_private.accounting_source_state s set lines=(select jsonb_agg(x||jsonb_build_object('type_id',app_private.source_type(s.tenant_id,s.source,s.source_id,x->>'account'))) from jsonb_array_elements(s.lines)x)
where s.source='inventory' and exists(select 1 from public.inventory_movements m where m.tenant_id=s.tenant_id and m.movement_id=s.source_id and m.reference_type='purchase_receipt_new');
update app_private.accounting_snapshot_state st set invalid_from=least(invalid_from,(select min(j.occurred_on) from public.accounting_journals j join public.inventory_movements m on m.tenant_id=j.tenant_id and m.movement_id=j.source_id where j.tenant_id=st.tenant_id and j.source='inventory' and m.reference_type='purchase_receipt_new'));

-- New acquisition cost is the incurred invoice/transport cost less earned
-- acquisition rebates. Returning an owned shell from transit is not another
-- acquisition; later deductions only settle the earlier rebate receivable.
do $$declare s text;begin s:=pg_get_functiondef('app_private.period_financial_values(jsonb)'::regprocedure);
 s:=replace(s,'coalesce(sum(amount) filter(where account in (''inventory_lpg'',''inventory_stove'') and code in (''purchase_receipt'',''internal_inventory'') and amount>0),0)',
 'coalesce(sum(case when account=''inventory_transit'' and code in (''purchase'',''internal_transport'') then amount when account=''supplier_receivable'' and code=''monthly_commission'' then -amount when account in (''inventory_lpg'',''inventory_stove'') and code in (''inventory_capital'',''inventory_gain'') then amount else 0 end),0)');execute s;end $$;
