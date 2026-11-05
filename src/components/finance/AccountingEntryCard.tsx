import { accountingEffectName, entryTitle, explanation } from '../../lib/accountingEntry';
import { useState } from 'react';
import { ArrowDownLeft, ArrowUpRight, Layers3 } from 'lucide-react';
import type { AccountingBreakdownEntry, JournalFilters } from '../../types/accounting';
import { businessNames, type BusinessLine } from '../../types/financial';
import { formatBDT } from '../../lib/formatBDT';
import { JournalLines } from './JournalAudit';
import './accounting-activity.css';

export function AccountingEntryCard({ row, mode, filters, onOpen, onActivity }: { row: AccountingBreakdownEntry; mode: 'history'|'components'; filters: JournalFilters; onOpen?: () => void; onActivity?: () => void }) {
 const [evidence,setEvidence]=useState(false);
 const history=mode==='history'; const movement=history && row.amount_kind!=='value'; const down=row.amount<0; const business=row.business_category==='all'?'Combined businesses':businessNames[row.business_category as BusinessLine] ?? row.business_category;
 const effectTotals=new Map<string,{name:string;amount:number}>();
 for(const effect of row.effects ?? []){const previous=effectTotals.get(effect.account);effectTotals.set(effect.account,{name:effect.name,amount:(previous?.amount ?? 0)+effect.amount});}
 const effects=[...effectTotals].sort(([a],[b])=>(a==='cash'?0:a==='customer_receivable'?1:2)-(b==='cash'?0:b==='customer_receivable'?1:2)).slice(0,2);
 return <article className={`accounting-entry-card ${history?(down?'entry-decrease':'entry-increase'):'entry-component'}`}>
  <header><span className="accounting-entry-icon" aria-hidden="true">{movement?(down?<ArrowDownLeft size={19}/>:<ArrowUpRight size={19}/>):<Layers3 size={19}/>}</span>
   <div className="accounting-entry-identity">
    <h3>{history?entryTitle(row):row.type_name || row.entity_name}</h3>
    {row.entity_name && row.entity_name!==row.name && row.entity_name!==row.type_name && <p>{row.entity_name}</p>}
    <div className="accounting-entry-tags">{!row.event_row && <span>{row.name}</span>}{business && <span>{business}</span>}{row.event_row && <span>{row.line_count} accounting lines</span>}</div>
   </div>
   <div className="accounting-entry-amount"><span>{row.amount_kind==='value'?'Value recorded':history?(down?'Decrease':'Increase'):'Balance'}</span><strong>{formatBDT(Math.abs(row.amount))}</strong>{!history && down && <small>Credit / negative balance</small>}</div>
  </header>
  <div className="accounting-entry-context"><div className="accounting-entry-meta">{row.occurred_on && <time dateTime={row.occurred_on}>{new Date(`${row.occurred_on}T12:00:00+06:00`).toLocaleDateString('en-BD',{day:'numeric',month:'short',year:'numeric',timeZone:'Asia/Dhaka'})}</time>}{history && row.type_name && <span>{row.type_name}</span>}{row.entry_no && <span>Entry #{row.entry_no}</span>}{row.estimated && <span>Development estimate</span>}</div>
  {row.event_row && effects.length>0 && <div className="accounting-entry-effects">{effects.map(([account,effect])=><span key={account}>{accountingEffectName(account,effect.name)} <strong>{effect.amount<0?'−':'+'}{formatBDT(Math.abs(effect.amount))}</strong></span>)}</div>}
  </div>
  <footer>{onActivity && <button className="btn btn-secondary" onClick={onActivity}>View activity</button>}{onOpen && <button className="btn btn-secondary" onClick={onOpen}>View source record</button>}</footer>
  {row.journal_id && <details className="accounting-entry-evidence" onToggle={e=>setEvidence(e.currentTarget.open)}><summary>Accounting details</summary>{evidence && <>{history && <p className="accounting-entry-explanation">{row.event_row?'These lines record the financial effects of this action. They are not additional transactions or payments.':explanation(row)}</p>}<p className="journal-reference finance-note">Reference: {row.transaction_reference ?? row.source_id ?? row.journal_id}</p><JournalLines filters={filters} id={row.journal_id}/></>}</details>}
 </article>;
}
