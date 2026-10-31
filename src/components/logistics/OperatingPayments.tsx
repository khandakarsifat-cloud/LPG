import { useState } from 'react';
import toast from 'react-hot-toast';
import { useAuth } from '../../contexts/AuthContext';
import { usePaymentWallets } from '../../hooks/useFinance';
import {
  useOperatingPayments,
  useVehicleAccountingOperation,
} from '../../hooks/useVehicleAccounting';
import { formatBDT } from '../../lib/formatBDT';
import { validatePayments } from '../../lib/payments';
import type { PaymentDraft } from '../../types/finance';
import type {
  OperatingPayment,
  OperatingPaymentKind,
} from '../../types/vehicleAccounting';
import { PaymentEntries } from '../pos/PaymentEntries';
import { PurchaseDialog } from '../purchases/PurchaseControls';
import { Pagination } from '../ui/Pagination';
import { dhakaToday } from '../../lib/businessDate';
const labels: Record<OperatingPaymentKind, string> = {
  expense: 'Expense payment',
  expense_return: 'Funds returned',
  client_receipt: 'Client collection',
  client_refund: 'Client refund',
};
export function OperatingPayments({
  parent,
  due,
  locked,
  allowAdvance = false,
  clientDue,
  clientRefund = 0,
  clientReceipts = true,
}: {
  parent: { transit_id?: string; service_trip_id?: string };
  due: number;
  locked: boolean;
  allowAdvance?: boolean;
  clientDue?: number;
  clientRefund?: number;
  clientReceipts?: boolean;
}) {
  const { can } = useAuth();
  const [page, setPage] = useState(0);
  const q = useOperatingPayments(parent, page);
  const [payment, setPayment] = useState<{
    kind: OperatingPaymentKind;
    original?: OperatingPayment;
  } | null>(null);
  const operation = useVehicleAccountingOperation();
  return (
    <section className="purchase-section">
      <div className="purchase-section-heading">
        <h3>Payments & history</h3>
        {can('logistics:manage') && !locked && (
          <div className="finance-actions">
            {(due > 0 || allowAdvance) && (
              <button
                type="button"
                className="btn btn-secondary"
                onClick={() => setPayment({ kind: 'expense' })}
              >
                Pay expenses{allowAdvance ? ' / advance' : ''}
              </button>
            )}
            {clientDue !== undefined && clientDue > 0 && clientReceipts && (
              <button
                type="button"
                className="btn btn-secondary"
                onClick={() => setPayment({ kind: 'client_receipt' })}
              >
                Collect client payment
              </button>
            )}
            {clientRefund > 0 && (
              <button
                type="button"
                className="btn btn-secondary"
                onClick={() => setPayment({ kind: 'client_refund' })}
              >
                Refund client
              </button>
            )}
          </div>
        )}
      </div>
      {operation.hasPending && (
        <div className="purchase-alert" role="alert">
          A previous vehicle payment or change needs confirmation.{' '}
          <button
            type="button"
            className="btn btn-secondary"
            disabled={operation.isPending}
            onClick={() => operation.mutate(undefined)}
          >
            Recover transaction
          </button>
        </div>
      )}
      {operation.error && (
        <p className="payment-error" role="alert">
          {operation.error.message}
        </p>
      )}
      {q.isPending && <p role="status">Loading payment history…</p>}
      {q.error && (
        <p className="payment-error" role="alert">
          {q.error.message}
          <button
            type="button"
            className="btn btn-secondary"
            onClick={() => void q.refetch()}
          >
            Retry
          </button>
        </p>
      )}
      {q.data && (
        <>
          <div className="operating-payment-history">
            {q.data.entries.map((p) => (
              <article className="history-card" key={p.payment_id}>
                <div className="purchase-section-heading">
                  <span>
                    <strong>{labels[p.kind]}</strong>
                    <small>
                      {p.wallet_name} · {p.payment_date}
                      {p.reference ? ` · ${p.reference}` : ''}
                    </small>
                  </span>
                  <strong>{formatBDT(p.amount)}</strong>
                </div>
                {p.kind === 'expense' && p.returned > 0 && (
                  <small>Returned {formatBDT(p.returned)}</small>
                )}
                {!locked &&
                  can('logistics:manage') &&
                  p.kind === 'expense' &&
                  p.amount > p.returned && (
                    <button
                      type="button"
                      className="btn btn-ghost"
                      onClick={() =>
                        setPayment({ kind: 'expense_return', original: p })
                      }
                    >
                      Record funds returned
                    </button>
                  )}
              </article>
            ))}
          </div>
          {!q.data.total && (
            <p className="purchase-hint">No wallet payments recorded.</p>
          )}
          <Pagination
            page={page}
            pageSize={8}
            total={q.data.total}
            onChange={setPage}
            busy={q.isFetching}
            label="trip payments"
          />
        </>
      )}
      {payment && (
        <OperatingPaymentDialog
          parent={parent}
          kind={payment.kind}
          original={payment.original}
          due={
            payment.original
              ? payment.original.amount - payment.original.returned
              : payment.kind === 'client_receipt'
                ? (clientDue ?? 0)
                : payment.kind === 'client_refund'
                  ? clientRefund
                  : due
          }
          allowAdvance={allowAdvance && payment.kind === 'expense'}
          onClose={() => setPayment(null)}
        />
      )}
    </section>
  );
}
function OperatingPaymentDialog({
  parent,
  kind,
  due,
  allowAdvance,
  original,
  onClose,
}: {
  parent: { transit_id?: string; service_trip_id?: string };
  kind: OperatingPaymentKind;
  due: number;
  allowAdvance: boolean;
  original?: OperatingPayment;
  onClose: () => void;
}) {
  const wallets = usePaymentWallets();
  const operation = useVehicleAccountingOperation();
  const [entries, setEntries] = useState<PaymentDraft[]>([]);
  const [date, setDate] = useState(dhakaToday);
  const [review, setReview] = useState(false);
  const available = (wallets.data ?? []).filter(
    (w) => !original || w.wallet_id === original.wallet_id,
  );
  const paid = entries.reduce((s, p) => s + (Number(p.amount) || 0), 0);
  const total = allowAdvance ? Math.max(due, paid) : due;
  const validation = validatePayments(entries, total, available);
  return (
    <PurchaseDialog
      title={review ? 'Confirm payment' : labels[kind]}
      onClose={onClose}
      compact
      busy={operation.isPending}
    >
      <form
        onSubmit={async (e) => {
          e.preventDefault();
          if (!review) {
            setReview(true);
            return;
          }
          try {
            await operation.mutateAsync({
              action: 'payment',
              payload: {
                ...parent,
                kind,
                payment_date: date,
                return_of: original?.payment_id,
                payments: validation.payments,
              },
            });
            toast.success('Payment recorded');
            onClose();
          } catch {
            /* Recover using original request. */
          }
        }}
      >
        <div className="modal-body dialog-form">
          {review ? (
            <>
              <p>
                Record <strong>{formatBDT(validation.paid)}</strong> on {date}?
              </p>
              {validation.payments.map((p, i) => (
                <p key={i}>
                  {available.find((w) => w.wallet_id === p.wallet_id)?.name}:{' '}
                  {formatBDT(p.amount)}
                </p>
              ))}
              {allowAdvance && paid > due && (
                <p>Advance beyond current costs: {formatBDT(paid - due)}.</p>
              )}
            </>
          ) : (
            <>
              <p>
                {kind === 'expense_return'
                  ? 'Record money actually returned to its original wallet.'
                  : 'Record actual money paid or received.'}
                {allowAdvance
                  ? ' Payments above current costs remain advances until applied to incurred costs or returned.'
                  : ''}
              </p>
              <label className="input-group">
                <span className="input-label">Payment date</span>
                <input
                  type="date"
                  className="input-field"
                  required
                  max={dhakaToday()}
                  min={original?.payment_date}
                  value={date}
                  onChange={(e) => setDate(e.target.value)}
                />
              </label>
              {wallets.isPending && <p role="status">Loading wallets…</p>}
              {wallets.error && (
                <p role="alert" className="payment-error">
                  Wallets unavailable.
                  <button
                    type="button"
                    className="btn btn-secondary"
                    onClick={() => void wallets.refetch()}
                  >
                    Retry
                  </button>
                </p>
              )}
              {wallets.data && (
                <>
                  <PaymentEntries
                    wallets={available}
                    entries={entries}
                    onChange={setEntries}
                    total={total}
                    disabled={operation.isPending || operation.hasPending}
                    refund={
                      kind === 'client_refund' || kind === 'expense_return'
                    }
                  />
                </>
              )}
            </>
          )}
          {operation.error && (
            <p className="payment-error" role="alert">
              {operation.error.message}
            </p>
          )}
          {operation.hasPending && (
            <button
              type="button"
              className="btn btn-secondary"
              disabled={operation.isPending}
              onClick={async () => {
                try {
                  await operation.mutateAsync(undefined);
                  onClose();
                } catch {
                  /* Inline. */
                }
              }}
            >
              Recover transaction
            </button>
          )}
        </div>
        <div className="modal-footer">
          <button
            type="button"
            className="btn btn-secondary"
            disabled={operation.isPending}
            onClick={() => (review ? setReview(false) : onClose())}
          >
            {review ? 'Back' : 'Cancel'}
          </button>
          <button
            className="btn btn-primary"
            disabled={
              operation.isPending ||
              operation.hasPending ||
              !!validation.error ||
              !entries.length
            }
          >
            {review ? 'Record payment' : 'Review payment'}
          </button>
        </div>
      </form>
    </PurchaseDialog>
  );
}
