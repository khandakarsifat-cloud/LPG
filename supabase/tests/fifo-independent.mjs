// Independent integer-money model driven only by the retained lab's original
// operation manifest. It never reads journals, SQL costs, snapshots or reports.
import assert from 'node:assert/strict';
const cents = n => Math.round(Number(n)*100);
export function independentlyCalculate(spec, cutoff) {
  const rates=new Map();
  for(const [key,value] of Object.entries(spec.rates)) rates.set(key,typeof value==='number'?{package:value,refill:value}:value);
  for(const group of spec.commissionGroups){
    const ids=new Set(group.items.map(i=>i.id));
    const lines=spec.events.filter(e=>e.kind==='purchase'&&e.date.slice(0,7)===group.month).flatMap(e=>e.lines).filter(l=>ids.has(l.item));
    const deducted=group.deductions.reduce((n,d)=>n+cents(d.amount),0);
    const manual=lines.reduce((n,l)=>n+(Object.hasOwn(spec.rates,`${group.month}:${l.item}`)?Math.round(l.quantity*rates.get(`${group.month}:${l.item}`)[l.type]*100):0),0);
    const basis=lines.reduce((n,l)=>n+(Object.hasOwn(spec.rates,`${group.month}:${l.item}`)?0:l.quantity*l.unit),0);
    for(const item of group.items)if(!Object.hasOwn(spec.rates,`${group.month}:${item.id}`)){
      const pair={};for(const kind of ['package','refill']){const eligible=lines.filter(l=>l.item===item.id&&l.type===kind),qty=eligible.reduce((n,l)=>n+l.quantity,0),unit=qty?eligible.reduce((n,l)=>n+l.quantity*l.unit,0)/qty:0;pair[kind]=basis?Math.round(Math.max(0,deducted-manual)/100*unit/basis*1e6)/1e6:0;}
      rates.set(`${group.month}:${item.id}`,pair);
    }
  }
  const balances={cash:0,receivables:0,supplierDebt:0,supplierCredits:0,loans:0,employeeDebt:0,operatingDebt:0,otherLiabilities:0,pendingCommissions:0,vehicles:0,equipment:0,otherAssets:0,capital:0,revenue:0,expenses:0,withdrawals:0,inventory:0,bottles:0,transit:0};
  const pools=new Map(),issued=new Map(),wallets=new Map(),customers=new Map(),purchased=new Map();
  const pool=(id,part)=>{const key=`${id}:${part}`;if(!pools.has(key))pools.set(key,[]);return pools.get(key);};
  const add=(id,part,quantity,value,shell=0,age='')=>{const layer={quantity,value,shell,age};pool(id,part).push(layer);return layer;};
  const take=(id,part,qty)=>{const out=[];let value=0,shell=0;pool(id,part).sort((a,b)=>a.age.localeCompare(b.age));for(const layer of pool(id,part)){if(!qty)break;const q=Math.min(qty,layer.quantity);if(!q)continue;const v=q===layer.quantity?layer.value:Math.round(layer.value*q/layer.quantity);const s=q===layer.quantity?layer.shell:Math.round(layer.shell*q/layer.quantity);layer.quantity-=q;layer.value-=v;layer.shell-=s;qty-=q;value+=v;shell+=s;out.push({layer,q,value:v,shell:s});}assert.equal(qty,0,`Independent model shortage ${id}:${part}`);return {value,shell,out};};
  const cash=(wallet,amount)=>{const c=cents(amount);balances.cash+=c;wallets.set(wallet,(wallets.get(wallet)??0)+c);};
  const customer=(id,amount)=>customers.set(id,(customers.get(id)??0)+amount);
  for(const e of [...spec.events].sort((a,b)=>a.date.localeCompare(b.date)||a.order-b.order)){
    if(e.date>cutoff)continue;
    const a=cents(e.amount??0);
    if(e.kind==='funding'){cash(e.wallet,e.amount);balances.capital+=a;}
    else if(e.kind==='openingLiability'){balances.operatingDebt+=a;balances.capital-=a;}
    else if(e.kind==='openingReceivable'){balances.receivables+=a;balances.capital+=a;customer(e.customer,a);}
    else if(e.kind==='openingStock'){const value=cents(e.quantity*e.unit);add(e.item,e.part,e.quantity,value,e.part==='filled'?cents(e.quantity*(e.shell??0)):0,e.date+':'+String(e.order).padStart(8,'0'));balances.capital+=value;}
    else if(e.kind==='purchase'){
      let external=0;const layers=[];
      for(const line of e.lines){const gross=cents(line.quantity*line.unit);const rebate=Math.round(line.quantity*(rates.get(`${e.date.slice(0,7)}:${line.item}`)?.[line.type]??0)*100);let shell=0;if(line.type==='refill'){shell=take(line.item,'empty',line.quantity).value;}else shell=cents(line.quantity*(line.shell??0));layers.push(add(line.item,'filled',line.quantity,gross-rebate+(line.type==='refill'?shell:0),shell,e.date+':'+String(e.order).padStart(8,'0')));external+=gross;balances.supplierCredits+=rebate;}
      purchased.set(e.id,layers);
      balances.supplierDebt+=external-cents(e.deduction??0);balances.supplierCredits-=cents(e.deduction??0);
    }else if(e.kind==='purchasePayment'){cash(e.wallet,-e.amount);balances.supplierDebt-=a;}
    else if(e.kind==='purchaseCancel'){for(const layer of purchased.get(e.purchase)){layer.quantity=0;layer.value=0;layer.shell=0;}balances.supplierDebt-=a;}
    else if(e.kind==='transitPurchase'){const shell=take(e.item,'empty',e.refills).value;balances.transit+=a+shell;balances.supplierDebt+=a-cents(e.deduction);balances.pendingCommissions+=cents(e.deduction);}
    else if(e.kind==='sale'){
      let cost=0,shell=0;const allocations=[];
      for(const line of e.lines){const used=take(line.item,'filled',line.quantity);cost+=used.value;allocations.push(...used.out);if(line.type==='refill')shell+=used.shell;}
      const returned=e.returned??[];const expected=e.lines.filter(l=>l.type==='refill').reduce((n,l)=>n+l.quantity,0);let asset=shell,remaining=expected;
      for(const r of returned){const value=r.quantity===remaining?asset:Math.round(asset*r.quantity/remaining);asset-=value;remaining-=r.quantity;add(r.item,'empty',r.quantity,value,0,e.date+':'+String(e.order).padStart(8,'0'));}
      balances.bottles+=asset;balances.revenue+=a;balances.expenses+=cost-shell;balances.receivables+=a;customer(e.customer,a);issued.set(e.id,{allocations,cost,shell,amount:a,customer:e.customer});
    }else if(e.kind==='collection'){cash(e.wallet,e.amount);balances.receivables-=a;customer(e.customer,-a);}
    else if(e.kind==='bottleCollection'){balances.bottles-=a;add(e.item,'empty',e.quantity,a,0,e.date+':'+String(e.order).padStart(8,'0'));}
    else if(e.kind==='loss'){const removed=take(e.item,e.part,e.quantity);balances.expenses+=removed.value;}
    else if(e.kind==='reversal'){const s=issued.get(e.sale);assert(s);for(const used of s.allocations){used.layer.quantity+=used.q;used.layer.value+=used.value;used.layer.shell+=used.shell;}balances.revenue-=s.amount;balances.expenses-=s.cost-s.shell;balances.receivables-=s.amount;customer(s.customer,-s.amount);}
    else if(e.kind==='refund'){cash(e.wallet,-e.amount);balances.receivables+=a;customer(e.customer,a);}
    else if(e.kind==='spending'){cash(e.wallet,-e.amount);if(e.withdrawal)balances.withdrawals+=a;else balances.expenses+=a;}
    else if(e.kind==='loan'){cash(e.wallet,e.amount);balances.loans+=a;}
    else if(e.kind==='repayment'){cash(e.wallet,-e.amount);balances.loans-=a;}
    else if(e.kind==='asset'){balances[e.asset]+=a;if(e.funding==='opening')balances.capital+=a;else if(e.funding==='capital')balances.capital+=a;else if(e.funding==='wallet')cash(e.wallet,-e.amount);else balances.operatingDebt+=a;}
    else if(e.kind==='depreciation'){balances[e.asset]-=a;balances.expenses+=a;}
    else if(e.kind==='disposal'){balances[e.asset]-=cents(e.book);cash(e.wallet,e.proceeds-e.expense);balances.revenue+=cents(e.proceeds-e.expense-e.book);}
    else if(e.kind==='salary'){balances.expenses+=a;balances.employeeDebt+=a;}
    else if(e.kind==='bonus'||e.kind==='crewCost'){balances.expenses+=a;balances.employeeDebt+=a;}
    else if(e.kind==='employeePayment'){cash(e.wallet,-e.amount);balances.employeeDebt-=a;}
    else if(e.kind==='expenseAccrual'){balances.expenses+=a;balances.otherLiabilities+=a;}
    else if(e.kind==='expensePayment'){cash(e.wallet,-e.amount);if(e.liability==='other')balances.otherLiabilities-=a;else balances.operatingDebt-=a;}
    else if(e.kind==='transfer'){cash(e.wallet,-e.amount);cash(e.destination,e.amount);}
    else if(e.kind==='transitRevenue'){balances.revenue+=a;balances.otherAssets+=a;}
    else if(e.kind==='transitCollection'){cash(e.wallet,e.amount);balances.otherAssets-=a;}
    else if(e.kind==='transitCost'){balances.expenses+=a;balances.operatingDebt+=a;}
    else if(e.kind==='transitPayment'){cash(e.wallet,-e.amount);balances.operatingDebt-=a;}
    else throw Error('Unmodelled original operation '+e.kind);
  }
  for(const layers of pools.values()) for(const layer of layers)balances.inventory+=layer.value;
  // Account classifications follow the actual signs of control balances.
  const assets=balances.cash+Math.max(balances.receivables,0)+balances.supplierCredits+balances.inventory+balances.bottles+balances.vehicles+balances.equipment+balances.otherAssets+balances.transit+Math.max(-balances.supplierDebt,0)+Math.max(-balances.employeeDebt,0)+Math.max(-balances.operatingDebt,0);
  const liabilities=Math.max(balances.supplierDebt,0)+balances.loans+Math.max(balances.employeeDebt,0)+Math.max(balances.operatingDebt,0)+balances.otherLiabilities+balances.pendingCommissions+Math.max(-balances.receivables,0);
  const inventoryByItem={};for(const [key,layers] of pools){inventoryByItem[key]={quantity:layers.reduce((n,l)=>n+l.quantity,0),value:layers.reduce((n,l)=>n+l.value,0)};}
  return {balances,inventoryByItem,wallets:Object.fromEntries(wallets),customers:Object.fromEntries(customers),assets,liabilities,equity:assets-liabilities,profit:balances.revenue-balances.expenses,rates:Object.fromEntries(rates)};
}
