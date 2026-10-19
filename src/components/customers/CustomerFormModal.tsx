import { useId, useState, type FormEvent } from 'react';
import { Store, UserRound } from 'lucide-react';
import { PurchaseDialog } from '../purchases/PurchaseControls';
import { useAddCustomer, type Customer } from '../../hooks/useCustomers';
import { useUpdateCustomer } from '../../hooks/useCustomerDirectory';
import { assertBDMobilePhone, normalizePhoneInput } from '../../lib/bdPhone';
import type { CustomerTier } from '../../types/inventory';

export function CustomerFormModal({ customer, onClose, onSaved }: { customer?: Customer; onClose: () => void; onSaved?: (customer: Customer) => void }) {
  const id = useId();
  const [tier, setTier] = useState<CustomerTier>(customer?.tier === 'wholesale' ? 'wholesale' : 'retail');
  const [name, setName] = useState(customer?.name ?? '');
  const [shop, setShop] = useState(customer?.shop_name ?? '');
  const [phone, setPhone] = useState(customer?.phone ?? '');
  const [address, setAddress] = useState(customer?.address ?? '');
  const [error, setError] = useState('');
  const add = useAddCustomer(); const update = useUpdateCustomer();
  const busy = add.isPending || update.isPending;
  const save = async (event: FormEvent) => {
    event.preventDefault(); setError('');
    try {
      if (tier === 'wholesale' && !shop.trim()) throw new Error('Shop name is required for wholesale customers.');
      const payload = { tier, name: name.trim() || 'Unknown', shop_name: shop.trim() || null, phone: assertBDMobilePhone(phone), address: address.trim() || null };
      const saved = customer ? await update.mutateAsync({ id: customer.customer_id, payload }) : await add.mutateAsync(payload);
      onSaved?.(saved); onClose();
    } catch (cause) { setError(cause instanceof Error ? cause.message : 'Customer could not be saved.'); }
  };
  return <PurchaseDialog title={customer ? 'Edit customer' : 'Add customer'} subtitle={customer ? 'Update contact information and customer type.' : 'Keep customer contact and sales history in one place.'} compact onClose={onClose} busy={busy}>
    <form onSubmit={save} className="customer-form">
      <div className="modal-body">
        {error && <p className="purchase-error" role="alert">{error}</p>}
        <div className="input-group"><span className="input-label">Customer type</span><div className="customer-tier-switch" role="group" aria-label="Customer type">
          {(['retail', 'wholesale'] as const).map(value => <button key={value} type="button" aria-pressed={tier === value} disabled={busy} onClick={() => setTier(value)}>{value === 'retail' ? <UserRound size={16} /> : <Store size={16} />}{value === 'retail' ? 'Retail' : 'Wholesale'}</button>)}
        </div><span className="customer-help">{tier === 'wholesale' ? 'For shops and businesses buying at wholesale prices.' : 'For individuals buying at retail prices.'}</span></div>
        {tier === 'wholesale' && <label className="input-group"><span className="input-label">Shop name *</span><input className="input-field" required maxLength={255} disabled={busy} value={shop} onChange={event => setShop(event.target.value)} placeholder="e.g. Bismillah Traders" /></label>}
        <label className="input-group"><span className="input-label">{tier === 'wholesale' ? 'Contact name' : 'Customer name'}</span><input className="input-field" maxLength={255} disabled={busy} value={name} onChange={event => setName(event.target.value)} placeholder="Customer name" /></label>
        <div className="input-group"><label className="input-label" htmlFor={`${id}-phone`}>Mobile number *</label><input id={`${id}-phone`} aria-describedby={`${id}-phone-help`} className="input-field" required type="tel" inputMode="numeric" maxLength={14} disabled={busy} value={phone} onChange={event => setPhone(normalizePhoneInput(event.target.value))} placeholder="01712345678" /><span id={`${id}-phone-help`} className="customer-help">Use 01XXXXXXXXX or 08801XXXXXXXXX.</span></div>
        <div className="input-group"><label className="input-label" htmlFor={`${id}-address`}>Address</label><textarea id={`${id}-address`} className="input-field" rows={3} disabled={busy} value={address} onChange={event => setAddress(event.target.value)} placeholder="House, road, area and city" /></div>
        {customer && <p className="customer-notice">Changing customer type sets the default for future sales. Previous transactions keep their saved sale type.</p>}
      </div><div className="modal-footer"><button type="button" className="btn btn-secondary" disabled={busy} onClick={onClose}>Cancel</button><button type="submit" className="btn btn-primary" disabled={busy}>{busy ? 'Saving…' : customer ? 'Save changes' : 'Add customer'}</button></div>
    </form>
  </PurchaseDialog>;
}
