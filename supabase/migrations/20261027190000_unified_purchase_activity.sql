-- One chronological audit stream. Attach each ledger row to exactly one recorded
-- operation, retaining unmatched historical evidence as its own timeline event.
create or replace function public.get_purchase_activity(p_purchase_id uuid) returns setof jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid := app_private.require_any_permission(array['purchases:view','purchases:manage']);
begin
  return query
  with activities as materialized (
    select a.*, coalesce(nullif(u.full_name,''),u.email,'Historical user') actor_name
    from public.purchase_activity a
    left join public.user_profiles u on u.tenant_id=a.tenant_id and u.user_id=a.created_by
    where a.tenant_id=t and a.purchase_id=p_purchase_id
  ), ledger as materialized (
    select x.transaction_id, x.purchase_payment_id, x.wallet_name_snapshot wallet_name,
      x.wallet_method_snapshot method, x.amount, x.type, x.created_at, x.entry_no,
      x.operation_id, x.description, x.counterparty_wallet_id,
      pp.reference, pp.component, pp.obligation_id, u.full_name actor,
      linked.activity_id
    from public.wallet_transactions x
    left join public.purchase_payments pp on pp.tenant_id=t and pp.payment_id=x.purchase_payment_id
    left join public.user_profiles u on u.tenant_id=t and u.user_id=x.created_by
    left join lateral (
      select a.activity_id from activities a
      where (x.operation_id is not null and a.details->>'operation_id'=x.operation_id::text)
         or (x.purchase_payment_id is not null and exists (
           select 1 from jsonb_array_elements(case when jsonb_typeof(a.details->'payments')='array'
             then a.details->'payments' else '[]'::jsonb end) payment
           where payment->>'payment_id'=x.purchase_payment_id::text))
      order by a.created_at,a.activity_id limit 1
    ) linked on true
    where x.tenant_id=t and x.reference_id=p_purchase_id
  ), events as (
    select a.created_at, a.activity_id id, 0::bigint entry_no,
      to_jsonb(a)||jsonb_build_object('wallet_entries',coalesce((
        select jsonb_agg(to_jsonb(l)-'activity_id' order by l.entry_no)
        from ledger l where l.activity_id=a.activity_id),'[]'::jsonb)) body
    from activities a
    union all
    select l.created_at,l.transaction_id,l.entry_no,
      jsonb_build_object('activity_id',l.transaction_id,'action','wallet_entry',
        'actor_name',coalesce(l.actor,'Historical user'),'created_at',l.created_at,
        'details','{}'::jsonb,'wallet_entries',jsonb_build_array(to_jsonb(l)-'activity_id'))
    from ledger l where l.activity_id is null
  )
  select e.body from events e order by e.created_at,e.entry_no,e.id;
end $$;

revoke all on function public.get_purchase_activity(uuid) from public,anon;
grant execute on function public.get_purchase_activity(uuid) to authenticated;
comment on function public.get_purchase_activity(uuid) is
  'Tenant-authorized chronological purchase activity with each wallet ledger row represented once.';

-- Local display pagination reads this catalog in bounded ranges. Use a unique
-- tie-breaker when several trips were created in the same transaction.
create or replace function public.list_transits() returns setof jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid := app_private.require_any_permission(array['logistics:view','logistics:manage']);
begin
  return query select to_jsonb(tr)||jsonb_build_object('truck_name',truck.name,
    'purchase_refund_due',p.refund_due,'purchase_financial_closed_at',p.financial_closed_at)
    from public.transits tr
    join public.trucks truck on truck.tenant_id=tr.tenant_id and truck.truck_id=tr.truck_id
    left join public.purchases p on p.tenant_id=tr.tenant_id and p.purchase_id=tr.purchase_id
    where tr.tenant_id=t order by tr.created_at desc,tr.transit_id;
end $$;
