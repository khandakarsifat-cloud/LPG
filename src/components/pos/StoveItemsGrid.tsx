import { useStoveProducts, useStoveTypes } from '../../hooks/useAccounting';
import { usePriceBooks, type POSSalePayload } from '../../hooks/usePOS';
import { findSellingPrice } from '../../lib/productPricing';
import { formatBDT } from '../../lib/formatBDT';
import { ProductImage } from '../inventory/ProductImage';

export function StoveItemsGrid({
  tier,
  onAddItem,
}: {
  tier: 'retail' | 'wholesale';
  onAddItem: (item: POSSalePayload['items'][0]) => void;
}) {
  const q = useStoveProducts();
  const prices = usePriceBooks();
  const types = useStoveTypes();

  return (
    <>
      {q.isPending && <p role="status">Loading stove products…</p>}
      {q.error && <p role="alert" className="payment-error">{q.error.message}</p>}
      <div className="stove-catalog inv-tiles-grid adaptive-grid adaptive-grid--inventory">
        {q.data?.map(p => {
          const price = findSellingPrice(prices.data ?? [], p.item_id, 'package', tier);
          return (
            <button
              className="inv-tile stove-tile"
              key={p.item_id}
              disabled={p.filled_quantity < 1 || price === null}
              onClick={() => {
                if (price !== null) {
                  onAddItem({ item_id: p.item_id, type: 'package', quantity: 1, unit_price: price });
                }
              }}
            >
              <ProductImage path={p.image_url} name={p.product_name} className="product-image--catalog" />
              <strong className="inv-tile-brand">{p.product_name}</strong>
              <span className="stove-tile-type">
                {types.data?.find(t => t.type_id === p.product_type_id)?.name}
              </span>
              <div className="inv-tile-counts">
                <strong className="inv-tile-count inv-tile-count-filled">
                  {price === null ? 'Price not set' : formatBDT(price)}
                </strong>
                <span style={{ fontSize: '0.6875rem', color: 'var(--text-muted)' }}>
                  {p.filled_quantity} available
                </span>
              </div>
            </button>
          );
        })}
      </div>
      {q.data?.length === 0 && (
        <p className="empty-state">No stove products. Add products and stock in Inventory.</p>
      )}
    </>
  );
}
