import { useState } from 'react';
import {
  useVehicleExpenseCategories,
  useSaveVehicleExpenseCategory,
} from '../../hooks/useVehicleAccounting';
import { Pagination } from '../ui/Pagination';
export function VehicleExpenseCategories() {
  const q = useVehicleExpenseCategories();
  const save = useSaveVehicleExpenseCategory();
  const [name, setName] = useState('');
  const [page, setPage] = useState(0);
  return (
    <section className="settings-section">
      <header className="settings-section-heading">
        <div>
          <h2>Vehicle expense categories</h2>
          <p>
            Categories for service trips and additional transit expenses.
            Archived categories remain in history.
          </p>
        </div>
      </header>
      <div className="settings-card">
        <form
          className="settings-profile-form"
          onSubmit={async (e) => {
            e.preventDefault();
            try {
              await save.mutateAsync({ name });
              setName('');
            } catch {
              /* Inline. */
            }
          }}
        >
          <label className="input-group">
            <span className="input-label">New category</span>
            <input
              className="input-field"
              maxLength={80}
              required
              value={name}
              onChange={(e) => setName(e.target.value)}
            />
          </label>
          <button className="btn btn-primary" disabled={save.isPending}>
            Add category
          </button>
        </form>
        {q.isPending && <p role="status">Loading categories…</p>}
        {q.error && (
          <p role="alert">
            Categories unavailable.
            <button
              className="btn btn-secondary"
              onClick={() => void q.refetch()}
            >
              Retry
            </button>
          </p>
        )}
        {q.data?.slice(page * 8, page * 8 + 8).map((c) => (
          <div className="settlement-row" key={c.category_id}>
            <strong>
              {c.name}
              {!c.is_active ? ' (archived)' : ''}
            </strong>
            <button
              className="btn btn-secondary"
              disabled={save.isPending}
              onClick={() => save.mutate({ ...c, is_active: !c.is_active })}
            >
              {c.is_active ? 'Archive' : 'Restore'}
            </button>
          </div>
        ))}
        {q.data && (
          <Pagination
            page={page}
            pageSize={8}
            total={q.data.length}
            onChange={setPage}
            label="expense categories"
          />
        )}
        {save.error && (
          <p className="payment-error" role="alert">
            {save.error.message}
          </p>
        )}
      </div>
    </section>
  );
}
