// Independent source-input model for the retained dimensional acceptance lab.
// This imports no application accounting code and reads no journals/reports.
import assert from 'node:assert/strict';
export function calculateFinancialSources(events, cutoff, scope='all') {
 const books=Object.fromEntries(['all','lpg','stove','logistics'].map(b=>[b,new Map()]));const layers=new Map();
 const put=(b,a,value,id='',consolidated=true)=>{const key=a+'|'+id;books[b].set(key,(books[b].get(key)??0)+Math.round(value*100));if(consolidated)books.all.set(key,(books.all.get(key)??0)+Math.round(value*100));};
 const split=(value,allocation)=>{let prior=0,percent=0;return Object.entries(allocation).sort().map(([b,p])=>{percent+=p;const raw=value*100*percent/100,end=Math.sign(raw)*Math.round(Math.abs(raw)),part=(end-prior)/100;prior=end;return[b,part];});};
 const cash=(b,w,value)=>put(b,'cash',value,w);
 for(const e of events.filter(e=>e.date<=cutoff).sort((a,b)=>a.date.localeCompare(b.date)||a.order-b.order)) {
  if(e.kind==='funding')for(const[b,a]of split(e.amount,e.allocations)){cash(b,e.wallet,a);put(b,'capital',-a);}
  else if(e.kind==='asset')for(const[b,a]of split(e.amount,e.allocations)){put(b,e.account,a,e.id);if(e.funding==='opening')put(b,'capital',-a);else cash(b,e.wallet,-a);}
  else if(e.kind==='depreciation')for(const[b,a]of split(e.amount,e.allocations)){put(b,e.account,-a,e.id);put(b,'expense',a);}
  else if(e.kind==='improvement')for(const[b,a]of split(e.amount,e.allocations)){put(b,e.account,a,e.id);put(b,'payable',-a,e.id);}
  else if(e.kind==='disposal')for(const[b,a]of split(e.book,e.allocations)){put(b,e.account,-a,e.id);const net=(e.proceeds-e.expense)*(e.allocations[b]/100);cash(b,e.wallet,net);put(b,'revenue',a-net);}
  else if(e.kind==='purchase'){
   const external=e.quantity*(e.unit-e.rate),internal=e.transport??0;
   const queue=layers.get(e.item)??[];queue.push({q:e.quantity,external:external/e.quantity,internal:internal/e.quantity});layers.set(e.item,queue);
   put(e.business,'inventory',external,e.item);put(e.business,'inventory',internal,e.item,false);
   put(e.business,'payable',-(e.quantity*e.unit-e.deduction),e.id);put(e.business,'receivable_supplier',e.quantity*e.rate-e.deduction,e.brand??'');
   if(internal){cash(e.business,e.wallet,-internal);cash('logistics',e.cash,internal);put('logistics','revenue',-internal,'',false);}
  }else if(e.kind==='purchasePayment'){cash(e.business,e.wallet,-e.amount);put(e.business,'payable',e.amount,e.purchase);}
  else if(e.kind==='sale'){
   let needed=e.quantity,external=0,internal=0;for(const layer of layers.get(e.item)??[]){const n=Math.min(layer.q,needed);external+=n*layer.external;internal+=n*layer.internal;layer.q-=n;needed-=n;if(!needed)break;}assert.equal(needed,0,'Source fixture oversold stock');
   put(e.business,'inventory',-external,e.item);put(e.business,'inventory',-internal,e.item,false);put(e.business,'expense',external);put(e.business,'expense',internal,'',false);
   put(e.business,'revenue',-e.amount);put(e.business,'receivable',e.amount,e.customer);
   for(const p of e.payments){if((e.payment_date??e.date)>cutoff)continue;cash(e.business,p.wallet,p.amount);put(e.business,'receivable',-p.amount,e.customer);}
  }else if(e.kind==='collection'){cash(e.business,e.wallet,e.amount);put(e.business,'receivable',-e.amount,e.customer);}
  else if(e.kind==='custom')for(const[b,a]of split(e.amount,e.allocations)){const incoming=e.category==='revenue';cash(b,e.wallet,incoming?a:-a);put(b,e.category,incoming?-a:a);}
  else if(e.kind==='loan'){cash(e.business,e.wallet,e.amount);put(e.business,'loan',-e.amount,e.id);}
  else if(e.kind==='loanRepay'){cash(e.business,e.wallet,-e.amount);put(e.business,'loan',e.amount,e.id);}
  else if(e.kind==='transfer'){cash(e.business,e.wallet,-e.amount);cash(e.destination_business,e.destination,e.amount);put(e.business,'other_equity',e.amount);put(e.destination_business,'other_equity',-e.amount);}
 }
 const accounts=books[scope];let assets=0,liabilities=0,revenue=0,expenses=0,capital=0,withdrawals=0,other=0,cashTotal=0;
 for(const[key,value]of accounts){const code=key.split('|')[0];if(['cash','inventory','receivable','receivable_supplier','equipment','vehicles'].includes(code)){if(value>=0)assets+=value;else liabilities-=value;}else if(['payable','loan'].includes(code)){if(value<=0)liabilities-=value;else assets+=value;}
  if(code==='cash')cashTotal+=value;if(code==='revenue')revenue-=value;if(code==='expense')expenses+=value;if(code==='capital')capital-=value;if(code==='withdrawal')withdrawals+=value;if(code==='other_equity')other-=value;
 }
 const equity=capital+revenue-expenses-withdrawals+other;assert.equal(assets,liabilities+equity,'Independent source equation');
 return{assets,liabilities,equity,cash:cashTotal,capital,revenue,expenses,withdrawals,other_equity:other,accumulated_income:revenue-expenses,accounts};
}
