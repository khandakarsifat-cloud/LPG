import type { EmptyShortage } from '../../lib/purchase';
import { PurchaseDialog } from './PurchaseControls';
import { Pagination } from '../ui/Pagination';
import { useListPage } from '../../hooks/useListPage';

export function PurchaseStockWarning({ shortages, onClose }: { shortages: EmptyShortage[]; onClose: () => void }) {
  const paging = useListPage(shortages, 8);
  return <PurchaseDialog title="Not enough empty bottles" onClose={onClose} compact>
    <div className="modal-body purchase-confirmation">
      <p>Fix these refill quantities, then save again.</p>
      <ul className="purchase-shortage-list">{paging.entries.map(item => <li key={item.item_id}>
        <strong>{item.product}</strong>
        <span>Need {item.missing} more {item.missing === 1 ? 'bottle' : 'bottles'}. Available: {item.available}. Required: {item.required}.</span>
      </li>)}</ul>
      <Pagination {...paging} onChange={paging.setPage} label="shortages" />
    </div>
    <div className="modal-footer"><button type="button" className="btn btn-primary" onClick={onClose}>Okay</button></div>
  </PurchaseDialog>;
}
