export interface PerformanceMetrics { sold:number;bought:number;revenue:number;cogs:number|null;margin:number|null;average_margin:number|null;missing_units:number;estimated_units:number }
export interface PerformanceRow extends PerformanceMetrics { item_id:string;category:string;product_name:string;type:'refill'|'package' }
export interface ProductPerformanceReport { total:number;generated_at:string;business:'lpg'|'stove';rows:PerformanceRow[];totals:PerformanceMetrics }
export interface FifoProduct { item_id:string;label:string }
export interface FifoStockLayer { layer_id:string;component:'gas'|'bottle'|'unit';acquired_at:string;source_kind:string;source_id:string|null;remaining:number;in_transit:number;estimated:boolean;carrying_value:number;unit_cost:number|null;projected_margin:number|null }
export interface FifoStockReport { business:'lpg'|'stove';total:number;generated_at:string;tier:string;summary:{gas:number;bottle:number;unit:number;transit_bottles:number};prices:{customer_tier:string;price_type:string;price:number;effective_from:string}[];layers:FifoStockLayer[] }
