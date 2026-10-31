import { useState } from 'react';
import { Plus, Trash2, Wrench } from 'lucide-react';
import toast from 'react-hot-toast';
import { useAuth } from '../../contexts/AuthContext';
import {
  useServiceTrip,
  useServiceTrips,
  useVehicleAccountingOperation,
  useVehicleExpenseCategories,
  useServiceTripActivity,
} from '../../hooks/useVehicleAccounting';
import type {
  ServiceTrip,
  ServiceTripDraft,
} from '../../types/vehicleAccounting';
import { formatBDT } from '../../lib/formatBDT';
import {
  PurchaseConfirmation,
  PurchaseDialog,
  PurchaseNumber,
} from '../purchases/PurchaseControls';
import { Pagination } from '../ui/Pagination';
import { DatePicker } from '../ui/DatePicker';
import { OperatingPayments } from './OperatingPayments';
import { dhakaToday } from '../../lib/businessDate';
export function ServiceTrips({ vehicleId }: { vehicleId: string }) {
  const { can } = useAuth();
  const [filters, setFilters] = useState({
    search: '',
    from: '',
    to: '',
    category_id: '',
  });
  const [page, setPage] = useState(0);
  const q = useServiceTrips({ ...filters, vehicle_id: vehicleId }, page);
  const cats = useVehicleExpenseCategories();
  const [selected, setSelected] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const change = (key: keyof typeof filters, value: string) => {
    setFilters((p) => ({ ...p, [key]: value }));
    setPage(0);
  };
  return (
    <section>
      <div className="logistics-toolbar">
        <label className="input-group logistics-search">
          <span className="input-label">Search service trips</span>
          <input
            className="input-field"
            value={filters.search}
            onChange={(e) => change('search', e.target.value)}
            placeholder="Title, category, description or ID"
          />
        </label>
        <label className="input-group">
          <span className="input-label">Expense category</span>
          <select
            className="input-field"
            value={filters.category_id}
            onChange={(e) => change('category_id', e.target.value)}
          >
            <option value="">All categories</option>
            {cats.data?.map((c) => (
              <option key={c.category_id} value={c.category_id}>
                {c.name}
              </option>
            ))}
          </select>
        </label>
        <DatePicker
          label="Service from"
          value={filters.from}
          onChange={(v) => change('from', v)}
        />
        <DatePicker
          label="Service to"
          value={filters.to}
          onChange={(v) => change('to', v)}
        />
        {can('logistics:manage') && (
          <button
            type="button"
            className="btn btn-primary"
            onClick={() => setCreating(true)}
          >
            <Plus size={14} />
            Service trip
          </button>
        )}
      </div>
      {q.isPending && <p role="status">Loading service trips…</p>}
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
          <div className="service-trip-list">
            {q.data.entries.map((s) => (
              <button
                type="button"
                className="service-trip-card history-card"
                key={s.service_trip_id}
                onClick={() => setSelected(s.service_trip_id)}
              >
                <span>
                  <strong>
                    <Wrench size={15} />
                    {s.title}
                  </strong>
                  <small>
                    {s.service_date} · {s.finalized_at ? 'Finalized' : 'Open'}
                  </small>
                  <small>
                    {[...new Set(s.expenses.map((e) => e.category_name))].join(
                      ', ',
                    ) || 'Advance payment trip'}
                  </small>
                </span>
                <span>
                  <strong>{formatBDT(s.total_cost)}</strong>
                  <small>
                    {s.advance > 0
                      ? `${formatBDT(s.advance)} advance`
                      : `${formatBDT(s.outstanding)} outstanding`}
                  </small>
                </span>
              </button>
            ))}
          </div>
          {!q.data.total && (
            <p className="purchase-hint">
              No service trips match these filters.
            </p>
          )}
          <Pagination
            page={page}
            pageSize={8}
            total={q.data.total}
            onChange={setPage}
            busy={q.isFetching}
            label="service trips"
          />
        </>
      )}
      {creating && (
        <ServiceTripEditor
          vehicleId={vehicleId}
          onClose={() => setCreating(false)}
          onSaved={(id) => {
            setCreating(false);
            setSelected(id);
          }}
        />
      )}
      {selected && (
        <ServiceTripDetails id={selected} onClose={() => setSelected(null)} />
      )}
    </section>
  );
}
export function ServiceTripDetails({
  id,
  onClose,
}: {
  id: string;
  onClose: () => void;
}) {
  const q = useServiceTrip(id);
  const { can } = useAuth();
  const [editing, setEditing] = useState(false);
  const [finalize, setFinalize] = useState(false);
  const op = useVehicleAccountingOperation();
  const s = q.data;
  const [historyPage, setHistoryPage] = useState(0);
  const activity = useServiceTripActivity(id, historyPage);
  if (editing && s)
    return (
      <ServiceTripEditor
        vehicleId={s.vehicle_id}
        current={s}
        onClose={() => setEditing(false)}
        onSaved={() => setEditing(false)}
      />
    );
  return (
    <>
      <PurchaseDialog
        title="Vehicle service trip"
        subtitle={s?.vehicle_name}
        onClose={onClose}
        busy={op.isPending}
      >
        <div className="modal-body dialog-form">
          {q.isPending && <p role="status">Loading service trip…</p>}
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
          {s && (
            <>
              <div className="purchase-section-heading">
                <div>
                  <h3>{s.title}</h3>
                  <p>
                    {s.service_date} ·{' '}
                    {s.finalized_at
                      ? 'Finalized'
                      : 'Open for expenses and payments'}
                  </p>
                </div>
                {can('logistics:manage') && !s.finalized_at && (
                  <button
                    type="button"
                    className="btn btn-secondary"
                    onClick={() => setEditing(true)}
                  >
                    Edit expenses
                  </button>
                )}
              </div>
              <dl className="logistics-facts">
                <div>
                  <dt>Incurred expenses</dt>
                  <dd>{formatBDT(s.total_cost)}</dd>
                </div>
                <div>
                  <dt>Net paid</dt>
                  <dd>{formatBDT(s.paid)}</dd>
                </div>
                <div>
                  <dt>Outstanding</dt>
                  <dd>{formatBDT(s.outstanding)}</dd>
                </div>
                <div>
                  <dt>Unapplied advance</dt>
                  <dd>{formatBDT(s.advance)}</dd>
                </div>
              </dl>
              <div className="service-expense-breakdown">
                {s.expenses.map((e, i) => (
                  <div key={i}>
                    <span>
                      <strong>{e.category_name}</strong>
                      {e.description && <small>{e.description}</small>}
                    </span>
                    <strong>{formatBDT(e.amount)}</strong>
                  </div>
                ))}
              </div>
              <OperatingPayments
                parent={{ service_trip_id: id }}
                due={s.outstanding}
                allowAdvance
                locked={!!s.finalized_at}
              />
              <details>
                <summary>Change history</summary>
                {activity.error && (
                  <p role="alert">
                    Activity unavailable.
                    <button
                      type="button"
                      className="btn btn-secondary"
                      onClick={() => void activity.refetch()}
                    >
                      Retry
                    </button>
                  </p>
                )}
                {activity.data?.entries.map((a) => (
                  <article className="history-card" key={a.activity_id}>
                    <strong>{a.action}</strong>
                    <small>
                      {new Date(a.created_at).toLocaleString('en-BD', {
                        timeZone: 'Asia/Dhaka',
                      })}
                    </small>
                    <details>
                      <summary>Recorded details</summary>
                      <pre className="service-audit-json">
                        {JSON.stringify(a.details, null, 2)}
                      </pre>
                    </details>
                  </article>
                ))}
                {activity.data && (
                  <Pagination
                    page={historyPage}
                    pageSize={8}
                    total={activity.data.total}
                    onChange={setHistoryPage}
                    label="service changes"
                  />
                )}
              </details>
            </>
          )}
          {op.hasPending && (
            <button
              type="button"
              className="btn btn-secondary"
              disabled={op.isPending}
              onClick={() => op.mutate(undefined)}
            >
              Recover previous service change
            </button>
          )}
          {op.error && (
            <p className="payment-error" role="alert">
              {op.error.message}
            </p>
          )}
        </div>
        <div className="modal-footer">
          <button className="btn btn-secondary" onClick={onClose}>
            Close
          </button>
          {s && !s.finalized_at && can('logistics:manage') && (
            <button
              className="btn btn-primary"
              disabled={
                op.isPending ||
                op.hasPending ||
                s.outstanding > 0 ||
                s.advance > 0
              }
              onClick={() => setFinalize(true)}
            >
              Finalize service trip
            </button>
          )}
        </div>
      </PurchaseDialog>
      {finalize && s && (
        <PurchaseConfirmation
          title="Finalize service trip?"
          action="Finalize"
          onCancel={() => setFinalize(false)}
          busy={op.isPending}
          onConfirm={async () => {
            try {
              await op.mutateAsync({
                action: 'finalize',
                service_trip_id: id,
                revision: s.revision,
              });
              setFinalize(false);
              toast.success('Service trip finalized');
            } catch {
              /* Inline error. */
            }
          }}
        >
          <p>
            Lock {s.title} and its {formatBDT(s.total_cost)} in fully settled
            expenses.
          </p>
          {op.error && (
            <p role="alert" className="payment-error">
              {op.error.message}
            </p>
          )}
        </PurchaseConfirmation>
      )}
    </>
  );
}
function ServiceTripEditor({
  vehicleId,
  current,
  onClose,
  onSaved,
}: {
  vehicleId: string;
  current?: ServiceTrip;
  onClose: () => void;
  onSaved: (id: string) => void;
}) {
  const cats = useVehicleExpenseCategories();
  const op = useVehicleAccountingOperation();
  const [draft, setDraft] = useState<ServiceTripDraft>(() =>
    current
      ? {
          vehicle_id: vehicleId,
          service_trip_id: current.service_trip_id,
          revision: current.revision,
          title: current.title,
          service_date: current.service_date,
          expenses: current.expenses,
        }
      : {
          vehicle_id: vehicleId,
          title: '',
          service_date: dhakaToday(),
          expenses: [],
        },
  );
  const [review, setReview] = useState(false);
  const [page, setPage] = useState(0);
  const total = draft.expenses.reduce((s, e) => s + e.amount, 0);
  return (
    <>
      <PurchaseDialog
        title={current ? 'Edit service trip' : 'Add vehicle service trip'}
        onClose={onClose}
        busy={op.isPending}
      >
        <form
          onSubmit={(e) => {
            e.preventDefault();
            setReview(true);
          }}
        >
          <div className="modal-body dialog-form">
            <fieldset
              disabled={op.isPending || op.hasPending}
              className="service-trip-fields"
            >
              <label className="input-group">
                <span className="input-label">Title</span>
                <input
                  className="input-field"
                  required
                  maxLength={160}
                  value={draft.title}
                  onChange={(e) =>
                    setDraft({ ...draft, title: e.target.value })
                  }
                />
              </label>
              <DatePicker
                label="Service date"
                value={draft.service_date}
                max={dhakaToday()}
                onChange={(v) => setDraft({ ...draft, service_date: v })}
              />
              <div className="purchase-section-heading">
                <h3>Expenses · {formatBDT(total)}</h3>
                <button
                  type="button"
                  className="btn btn-ghost"
                  disabled={
                    !cats.data?.some((c) => c.is_active) ||
                    draft.expenses.length >= 100
                  }
                  onClick={() => {
                    setPage(Math.floor(draft.expenses.length / 5));
                    setDraft({
                      ...draft,
                      expenses: [
                        ...draft.expenses,
                        {
                          category_id:
                            cats.data?.find((c) => c.is_active)?.category_id ??
                            '',
                          amount: 0,
                          description: '',
                        },
                      ],
                    });
                  }}
                >
                  <Plus size={14} />
                  Add expense
                </button>
              </div>
              {draft.expenses.slice(page * 5, page * 5 + 5).map((e, offset) => {
                const index = page * 5 + offset;
                const update = (p: Partial<typeof e>) =>
                  setDraft({
                    ...draft,
                    expenses: draft.expenses.map((x, i) =>
                      i === index ? { ...x, ...p } : x,
                    ),
                  });
                return (
                  <div className="service-expense-editor" key={index}>
                    <label className="input-group">
                      <span className="input-label">Category</span>
                      <select
                        className="input-field"
                        required
                        value={e.category_id}
                        onChange={(v) =>
                          update({ category_id: v.target.value })
                        }
                      >
                        {cats.data
                          ?.filter(
                            (c) =>
                              c.is_active || c.category_id === e.category_id,
                          )
                          .map((c) => (
                            <option key={c.category_id} value={c.category_id}>
                              {c.name}
                            </option>
                          ))}
                      </select>
                    </label>
                    <PurchaseNumber
                      label="Amount (Tk)"
                      value={e.amount}
                      money
                      onChange={(amount) => update({ amount: amount ?? 0 })}
                    />
                    <label className="input-group service-description">
                      <span className="input-label">
                        Description (optional)
                      </span>
                      <input
                        className="input-field"
                        maxLength={1000}
                        value={e.description}
                        onChange={(v) =>
                          update({ description: v.target.value })
                        }
                      />
                    </label>
                    <button
                      type="button"
                      className="btn btn-ghost"
                      aria-label={`Remove expense ${index + 1}`}
                      onClick={() => {
                        setDraft({
                          ...draft,
                          expenses: draft.expenses.filter(
                            (_, i) => i !== index,
                          ),
                        });
                        setPage((p) =>
                          Math.min(
                            p,
                            Math.max(
                              0,
                              Math.ceil((draft.expenses.length - 1) / 5) - 1,
                            ),
                          ),
                        );
                      }}
                    >
                      <Trash2 size={16} />
                    </button>
                  </div>
                );
              })}
              <Pagination
                page={page}
                pageSize={5}
                total={draft.expenses.length}
                onChange={setPage}
                label="draft expenses"
              />
              {!draft.expenses.length && (
                <p className="purchase-hint">
                  Add expense entries, or save this trip first to record an
                  advance.
                </p>
              )}
            </fieldset>
            {cats.error && (
              <p className="payment-error" role="alert">
                Categories unavailable.
                <button
                  type="button"
                  className="btn btn-secondary"
                  onClick={() => void cats.refetch()}
                >
                  Retry
                </button>
              </p>
            )}
            {op.hasPending && (
              <button
                type="button"
                className="btn btn-secondary"
                disabled={op.isPending}
                onClick={async () => {
                  try {
                    const r = await op.mutateAsync(undefined);
                    if (r.service_trip_id) onSaved(r.service_trip_id);
                  } catch {
                    /* Inline. */
                  }
                }}
              >
                Recover service change
              </button>
            )}
            {op.error && (
              <p className="payment-error" role="alert">
                {op.error.message}
              </p>
            )}
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="btn btn-secondary"
              onClick={onClose}
              disabled={op.isPending}
            >
              Cancel
            </button>
            <button
              className="btn btn-primary"
              disabled={
                op.isPending ||
                op.hasPending ||
                draft.expenses.some((e) => e.amount <= 0)
              }
            >
              Review service trip
            </button>
          </div>
        </form>
      </PurchaseDialog>
      {review && (
        <PurchaseConfirmation
          title="Confirm service trip"
          action="Save service trip"
          onCancel={() => setReview(false)}
          busy={op.isPending}
          onConfirm={async () => {
            try {
              const r = await op.mutateAsync({
                action: 'save',
                payload: draft,
              });
              if (r.service_trip_id) onSaved(r.service_trip_id);
              toast.success('Service trip saved');
            } catch {
              /* Keep draft and request. */
            }
          }}
        >
          <p>
            {draft.title}: {draft.expenses.length} expense entries totaling{' '}
            {formatBDT(total)}.
          </p>
          <p>Payments are recorded separately and can include advances.</p>
          {op.error && (
            <p className="payment-error" role="alert">
              {op.error.message}
            </p>
          )}
        </PurchaseConfirmation>
      )}
    </>
  );
}
