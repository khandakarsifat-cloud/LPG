import { useState } from 'react';
import { formatBDT } from '../../lib/formatBDT';
import { DatePicker } from '../ui/DatePicker';
import { Pagination } from '../ui/Pagination';
import { PurchaseDialog } from '../purchases/PurchaseControls';
import {
  useFinancialActivity,
  useActivityWalletAudit,
  type FinancialActivityEntry as Activity,
} from '../../hooks/useFinance';
export function FinancialActivity() {
  const [filters, setFilters] = useState({
    search: '',
    source: '',
    from: '',
    to: '',
  });
  const [page, setPage] = useState(0);
  const [selected, setSelected] = useState<Activity | null>(null);
  const q = useFinancialActivity(filters, page);
  const change = (key: keyof typeof filters, value: string) => {
    setPage(0);
    setFilters((p) => ({ ...p, [key]: value }));
  };
  return (
    <section className="finance-ledger">
      <div className="finance-toolbar">
        <input
          className="input-field"
          aria-label="Search financial activity"
          placeholder="Search purchase, service trip or transit"
          value={filters.search}
          onChange={(e) => change('search', e.target.value)}
        />
        <select
          className="input-field"
          aria-label="Activity source"
          value={filters.source}
          onChange={(e) => change('source', e.target.value)}
        >
          <option value="">Purchases & vehicle operations</option>
          <option value="purchase">Purchases</option>
          <option value="transit">Transits</option>
          <option value="service_trip">Service trips</option>
        </select>
        <DatePicker
          label="Activity from"
          value={filters.from}
          onChange={(v) => change('from', v)}
        />
        <DatePicker
          label="Activity to"
          value={filters.to}
          onChange={(v) => change('to', v)}
        />
      </div>
      <p className="finance-note">
        Each purchase or vehicle operation is one activity. Its cost breakdown
        and individual wallet records stay together. View all actual money
        movements in Wallet ledger.
      </p>
      {q.isPending && <p role="status">Loading financial activity…</p>}
      {q.error && (
        <p className="payment-error" role="alert">
          {q.error.message}
          <button
            className="btn btn-secondary"
            onClick={() => void q.refetch()}
          >
            Retry
          </button>
        </p>
      )}
      {q.data && (
        <>
          <div className="financial-activity-list">
            {q.data.entries.map((a) => (
              <button
                className="financial-activity-row history-card"
                key={a.source + a.id}
                onClick={() => setSelected(a)}
              >
                <span>
                  <strong>{a.title}</strong>
                  <small>
                    {a.source.replaceAll('_', ' ')} ·{' '}
                    {new Date(a.created_at).toLocaleDateString('en-BD', {
                      timeZone: 'Asia/Dhaka',
                    })}{' '}
                    · {a.status}
                  </small>
                </span>
                <span>
                  Cost<strong>{formatBDT(a.cost)}</strong>
                </span>
                <span>
                  Net paid<strong>{formatBDT(a.paid)}</strong>
                </span>
                <span>
                  {a.source === 'transit' ? 'Revenue' : 'Outstanding'}
                  <strong>
                    {formatBDT(
                      a.source === 'transit'
                        ? a.revenue
                        : a.status === 'cancelled'
                          ? 0
                          : Math.max(0, a.cost - a.paid),
                    )}
                  </strong>
                </span>
              </button>
            ))}
          </div>
          {!q.data.total && (
            <p className="finance-empty">No matching financial activities.</p>
          )}
          <Pagination
            page={page}
            pageSize={12}
            total={q.data.total}
            onChange={setPage}
            busy={q.isFetching}
            label="financial activities"
            alwaysVisible
          />
        </>
      )}
      {selected && (
        <ActivityDetails
          activity={selected}
          onClose={() => setSelected(null)}
        />
      )}
    </section>
  );
}
function ActivityDetails({
  activity: a,
  onClose,
}: {
  activity: Activity;
  onClose: () => void;
}) {
  return (
    <PurchaseDialog
      title={a.title}
      subtitle={`${a.source.replaceAll('_', ' ')} #${a.id.slice(0, 8)}`}
      onClose={onClose}
    >
      <div className="modal-body dialog-form">
        <dl className="payment-totals">
          <div>
            <dt>Incurred cost</dt>
            <dd>{formatBDT(a.cost)}</dd>
          </div>
          <div>
            <dt>Net paid</dt>
            <dd>{formatBDT(a.paid)}</dd>
          </div>
          {a.internal_allocation > 0 && (
            <div>
              <dt>Internal transport allocation</dt>
              <dd>{formatBDT(a.internal_allocation)}</dd>
            </div>
          )}
        </dl>
        <div className="financial-breakdown">
          {Object.entries(a.breakdown).map(([label, value]) => (
            <div key={label}>
              <span>{label}</span>
              <strong>
                {typeof value === 'number'
                  ? formatBDT(value)
                  : Array.isArray(value)
                    ? `${value.length} categorized entries`
                    : String(value)}
              </strong>
            </div>
          ))}
        </div>
        {a.internal_allocation > 0 && (
          <p className="finance-note">
            Internal transport is an allocation, not a cash payment. It is
            eliminated from consolidated revenue.
          </p>
        )}
        <ActivityWalletAudit activity={a} />
      </div>
      <div className="modal-footer">
        <button className="btn btn-secondary" onClick={onClose}>
          Close
        </button>
      </div>
    </PurchaseDialog>
  );
}
function ActivityWalletAudit({ activity: a }: { activity: Activity }) {
  const [page, setPage] = useState(0);
  const q = useActivityWalletAudit(a.source, a.id, page);
  return (
    <section>
      <h3>Wallet audit</h3>
      {q.isPending && <p role="status">Loading payments…</p>}
      {q.error && (
        <p role="alert" className="payment-error">
          {q.error.message}
          <button
            className="btn btn-secondary"
            onClick={() => void q.refetch()}
          >
            Retry
          </button>
        </p>
      )}
      {q.data && (
        <>
          {q.data.entries.map((p) => (
            <article className="history-card" key={p.transaction_id}>
              <strong>
                {p.wallet_name} · {formatBDT(p.amount)}
              </strong>
              <small>
                {new Date(p.created_at).toLocaleString('en-BD', {
                  timeZone: 'Asia/Dhaka',
                })}
              </small>
              <p>{p.description}</p>
              <small>Ledger #{p.transaction_id}</small>
            </article>
          ))}
          {!q.data.total && <p>No actual wallet payments recorded.</p>}
          <Pagination
            page={page}
            pageSize={10}
            total={q.data.total}
            onChange={setPage}
            label="wallet entries"
          />
        </>
      )}
    </section>
  );
}
