import { useState } from 'react';
import type { FinanceWallet } from '../../types/finance';
import type { AccountingCommand } from '../../types/accounting';
import { MoneyDialog } from './FinanceDialogs';
import { AccountingOperationDialog, AssetRegister, OpeningRegister } from './AccountingManagement';
import { PurchaseDialog } from '../purchases/PurchaseControls';
import { useAuth } from '../../contexts/AuthContext';

export function BalanceAdjustments({ wallets, initialWallet, onClose }: { wallets: FinanceWallet[]; initialWallet?: string; onClose: () => void }) {
  const {can}=useAuth();
  const scopes=([
    {id:'wallet',label:'Wallet balances',allowed:can('wallets:adjust')||can('finance:capital')},
    {id:'opening',label:'Opening receivables & liabilities',allowed:can('finance:opening')},
    {id:'assets',label:'Equipment & other assets',allowed:can('finance:assets:manage')},
    {id:'obligations',label:'Unpaid operating costs',allowed:can('finance:obligations:manage')},
  ] as const).filter(s=>s.allowed);
  const [scope, setScope] = useState<'wallet' | 'assets' | 'opening' | 'obligations'>(scopes[0]?.id??'wallet');
  const [page, setPage] = useState(0);
  const [command, setCommand] = useState<Partial<AccountingCommand> | null>(null);
  const other=scopes.find(s=>s.id!=='wallet');
  if (scope === 'wallet') return <MoneyDialog action="adjustment" wallets={wallets} initialWallet={initialWallet} onClose={onClose} onManageRecords={other?() => setScope(other.id):undefined} />;
  return <><PurchaseDialog title="Adjust balances" onClose={onClose}><div className="modal-body dialog-form">
    <label className="input-group"><span className="input-label">Recorded position</span><select aria-label="Recorded position" className="input-field" value={scope} onChange={e => { const v=scopes.find(s=>s.id===e.target.value); if(v) { setScope(v.id); setPage(0); } }}>{scopes.map(s=><option key={s.id} value={s.id}>{s.label}</option>)}</select></label>
    <div className="accounting-register-actions"><button className="btn btn-primary" onClick={() => setCommand({action:scope==='assets'?'asset_register':scope==='opening'?'opening_entry':'expense_accrue'})}>{scope==='assets'?'Record asset':scope==='opening'?'Record missing balance':'Record unpaid cost'}</button></div>
    {scope==='assets' ? <AssetRegister page={page} setPage={setPage} onAction={setCommand}/> : <OpeningRegister kind={scope} page={page} setPage={setPage} onAction={setCommand}/>}
  </div><div className="modal-footer">{scopes.some(s=>s.id==='wallet')&&<button className="btn btn-secondary" onClick={() => setScope('wallet')}>Wallet balances</button>}<button className="btn btn-secondary" onClick={onClose}>Close</button></div></PurchaseDialog>
  {command && <AccountingOperationDialog initial={command} onClose={() => setCommand(null)}/>}</>;
}
