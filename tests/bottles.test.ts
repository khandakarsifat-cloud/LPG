import { test } from 'node:test';
import assert from 'node:assert/strict';
import { groupInventoryByBrand, orderSaleLines } from '../src/lib/inventoryGroups.ts';
import { validateBottles } from '../src/lib/bottles.ts';
import { buildSaleReceipt, formatReceipt } from '../src/lib/receipt.ts';
const obligation = { item_id: 'a', name: 'Brand A 12kg', size_kg: 12, mouth_size: '22mm', expected: 5, received: 2, difference: 3 };
const products = [obligation,{ item_id: 'b', name: 'Brand B 12kg', size_kg: 12, mouth_size: '22mm' },{ item_id: 'c', name: 'Brand C 5kg', size_kg: 5, mouth_size: '20mm' }];
test('aggregate receipt permits acknowledged different products and overcollection', () => {
 const line = { received_item_id: 'b', quantity: 2, acknowledged: true };
 assert.equal(validateBottles([obligation],products,[{...line,quantity:4}],true).error,undefined);
 assert.equal(validateBottles([obligation],products,[line],true).error,undefined);
 assert.match(validateBottles([obligation],products,[line,line],true).error ?? '',/one quantity/);
});
test('optional notes, cumulative excess and unexpected products', () => {
 assert.equal(validateBottles([obligation],products,[]).error,undefined);
 assert.match(validateBottles([obligation],products,[],true).error ?? '',/at least/);
 const line = { received_item_id: 'c', quantity: 1 };
 assert.match(validateBottles([obligation],products,[line],true).error ?? '',/Acknowledge/);
 assert.equal(validateBottles([obligation],products,[{...line,acknowledged:true}],true).error,undefined);
 assert.match(validateBottles([{...obligation,expected:2,received:2}],products,[{received_item_id:'a',quantity:1}],true,0).error ?? '',/Acknowledge/);
 for (const quantity of [-1,0.5,NaN,Infinity]) assert.match(validateBottles([obligation],products,[{...line,quantity}]).error ?? '',/valid|whole/);
});
test('thermal receipts combine checkout and later products by identity', () => {
 const receipt = { sale_id:'12345678',created_at:'2026-10-23',customer_name:'Test',customer_phone:'01700000000',customer_tier:'retail',items:[
 {item_id:'a',name:'Brand A 12kg 22mm',type:'empty_return' as const,quantity:5,unit_price:0,line_total:0},
 {item_id:'b',name:'Brand A 12kg 20mm',type:'empty_return' as const,quantity:1,unit_price:0,line_total:0}],subtotal:500,discount_amount:0,exchange_fee:0,total_amount:500,additional_charges:50,paid_amount:20,due_amount:530,unattributed_paid:0,payments:[],
 bottles:{expected:6,received:5,outstanding:1,actual:[{phase:'checkout' as const,item_id:'a',name:'Brand A 12kg',quantity:2},{phase:'checkout' as const,item_id:'c',name:'Brand A 12kg',quantity:1},{phase:'collection' as const,item_id:'a',name:'Brand A 12kg',quantity:2}],obligations:[{name:'Brand A 12kg',expected:6}]} };
 for (const width of [58,80] as const) {
  const text = formatReceipt(receipt,width).map(l=>l.text+' '+(l.right ?? '')).join('\n');
  assert.match(text,/Expected 5 \| Received 4/); assert.match(text,/Expected 1 \| Received 0/);
  assert.match(text,/Additional Settlement Cost/);
  assert.doesNotMatch(text,/Free|BOTTLE SETTLEMENT|Collected later:|At checkout:|empties returned/);
 }
 const incomplete = formatReceipt({...receipt,bottles:undefined}).map(l=>l.text).join('\n');
 assert.doesNotMatch(incomplete,/Expected 5 \| Received 5/);
});

test('saved receipt and cart ordering share categories and configured brands without mutating input', () => {
 const brands = [{brand_id:'z',brand_name:'Z first'},{brand_id:'a',brand_name:'A second'}];
 const products = ['a','z'].flatMap((brand, index) => [25,5].map(size => ({item_id:`${brand}-${size}`,brand_id:brand,brand:brands[1-index].brand_name,size_kg:size,mouth_size:'22mm' as const,lpg_brands:{brand_id:brand,brand_name:brands[1-index].brand_name}})));
 const lines = products.flatMap(item => ['empty_return','refill','package'].map(type => ({item_id:item.item_id,type,quantity:1,unit_price:type==='empty_return'?0:100,line_total:type==='empty_return'?0:100,items:{...item,size_kg:String(item.size_kg)}})));
 const sale = {sale_id:'saved',sale_tier:'retail' as const,created_at:'2026-10-23',subtotal:800,discount_amount:0,exchange_fee:0,total_amount:800,sale_items:lines};
 const payment = {unattributed_paid:800,total:800,original_total:800,additional_charges:0,paid:800,due:0,paid_at_checkout:800,checkout_payments:[],payment_count:0,payments:[],receipt_payments:[]};
 const before = JSON.stringify(sale);
 const receipt = buildSaleReceipt(sale,payment,'Shop',undefined,brands);
 const order = groupInventoryByBrand(products,brands).flatMap(group=>group.items.map(item=>item.item_id));
 const expected = ['package','refill','empty_return'].flatMap(type=>['z-5','z-25','a-5','a-25'].map(id=>`${type}:${id}`));
 assert.deepEqual(receipt.items.map(line=>`${line.type}:${line.item_id}`),expected);
 assert.deepEqual(orderSaleLines(lines,order).map(line=>`${line.type}:${line.item_id}`),expected);
 assert.equal(JSON.stringify(sale),before);
 assert.equal(receipt.items.reduce((sum,line)=>sum+line.line_total,0),800);
});
