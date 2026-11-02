import { useState } from 'react';
import type { FinanceWallet } from '../../types/finance';
import type { AccountingCommand } from '../../types/accounting';
import { MoneyDialog } from './FinanceDialogs';
import { AccountingOperationDialog, AssetRegister, OpeningRegister } from './AccountingManagement';
import { PurchaseDialog } from '../purchases/PurchaseControls';

export function BalanceAdjustments({ wallets, initialWallet, onClose }: { wallets: FinanceWallet[]; initialWallet?: string; onClose: () => void }) {
  const [scope, setScope] = useState<'wallet' | 'assets' | 'opening' | 'obligations'>('wallet');
  const [page, setPage] = useState(0);
  const [command, setCommand] = useState<Partial<AccountingCommand> | null>(null);
  if (scope === 'wallet') return <MoneyDialog action="adjustment" wallets={wallets} initialWallet={initialWallet} onClose={onClose} onManageRecords={() => setScope('opening')} />;
  return <><PurchaseDialog title="Adjust balances" onClose={onClose}><div className="modal-body dialog-form">
    <label className="input-group"><span className="input-label">Recorded position</span><select aria-label="Recorded position" className="input-field" value={scope} onChange={e => { const v=e.target.value; if(v==='wallet'||v==='assets'||v==='opening'||v==='obligations') { setScope(v); setPage(0); } }}><option value="wallet">Wallet balances</option><option value="opening">Opening receivables & liabilities</option><option value="assets">Equipment & other assets</option><option value="obligations">Unpaid operating costs</option></select></label>
    <div className="accounting-register-actions"><button className="btn btn-primary" onClick={() => setCommand({action:scope==='assets'?'asset_register':scope==='opening'?'opening_entry':'expense_accrue'})}>{scope==='assets'?'Record asset':scope==='opening'?'Record missing balance':'Record unpaid cost'}</button></div>
    {scope==='assets' ? <AssetRegister page={page} setPage={setPage} onAction={setCommand}/> : <OpeningRegister kind={scope} page={page} setPage={setPage} onAction={setCommand}/>}
  </div><div className="modal-footer"><button className="btn btn-secondary" onClick={() => setScope('wallet')}>Wallet balances</button><button className="btn btn-secondary" onClick={onClose}>Close</button></div></PurchaseDialog>
  {command && <AccountingOperationDialog initial={command} onClose={() => setCommand(null)}/>}</>;
}
