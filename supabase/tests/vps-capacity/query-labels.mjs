import { readFileSync } from 'node:fs';
import { sql, save } from './common.mjs';

const source=readFileSync(new URL('./workload.js',import.meta.url),'utf8');
const names=[...new Set([...source.matchAll(/'(get_[a-z_]+|create_pos_sale|create_purchase|dispatch_purchase|receive_purchase|record_purchase_payment|collect_sale_payment|move_wallet_money)'/g)].map(m=>m[1]))];
const labels=JSON.parse(sql(`select coalesce(jsonb_agg(to_jsonb(q)),'[]') from (
 select queryid::text,case ${names.map(name=>`when query like '%${name}%' then '${name}'`).join(' ')} else 'scoped_rest_read' end endpoint,
  calls,total_exec_time,mean_exec_time,max_exec_time,shared_blks_read,shared_blks_hit,temp_blks_read,temp_blks_written
 from pg_stat_statements where dbid=(select oid from pg_database where datname=current_database()) and query like '%pgrst_source%'
 order by total_exec_time desc limit 100) q;`));
save('query-labels.json',labels);
console.log(`Saved ${labels.length} query fingerprints with endpoint labels; no SQL bodies, tokens or records exported.`);
