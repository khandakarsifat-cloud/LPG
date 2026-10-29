"""Export sanitized measured evidence, Markdown stage tables and standalone charts."""
import argparse
from datetime import datetime
import json
from pathlib import Path
from zoneinfo import ZoneInfo

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt


def load(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def get(r,key,stat='avg',default=0):
    return r.get('resources',{}).get(key,{}).get(stat,default)


def timing(r,key,stat):
    value=r.get(key,{}).get(stat)
    return f'{value:.0f}' if value is not None else '—'


def main(state,output,tuned=False):
    result_file=('bracket-result.json' if (state/'bracket-result.json').exists() else 'tuned-result.json') if tuned else 'suite-result.json'
    result=load(state/result_file)
    if tuned:
      text=text.replace('Sessions refresh outside measurement windows. Preparation, analysis and reconciliation are excluded.',
        'Sessions refresh outside measurement windows. Preparation ends with vacuum/analyze, a completed checkpoint and a quiet recovery interval. Preparation, analysis and reconciliation are excluded.')
        result={**result,'first_failed':80,'fine_failure':result['first_failing']}
    runs=sorted([load(p) for p in state.glob('*-analysis.json') if not p.name.startswith('smoke')],key=lambda r:r['run']['started'])
    if tuned:
        result['first_failed']=next((r['run']['users'] for r in runs if not r['run']['pass'] and not r['run'].get('invalid_environment') and not r['run'].get('invalid_harness') and not r['run'].get('superseded_monitor')),None)
    initial_hash=load(state/'environment.json')['workload_sha256']
    final_hash=next((r['run']['workload_sha256'] for r in reversed(runs) if r['run'].get('workload_sha256')),initial_hash)
    final_sampler=next((r['run']['sampler_sha256'] for r in reversed(runs) if r['run'].get('sampler_sha256')),None)
    for r in runs:r['run'].setdefault('workload_sha256',initial_hash)
    labels={q['queryid']:q['endpoint'] for q in load(state/'query-labels.json')} if (state/'query-labels.json').exists() else {}
    for r in runs:
      for q in r.get('query_deltas',[]):q['endpoint']=labels.get(q['queryid'],'unknown')
    candidates=[r for r in runs if r['run']['population']==result['population'] and r['run']['workload_sha256']==final_hash and r['run'].get('sampler_sha256')==final_sampler and 'endurance-' not in r['run']['label'] and not r['run'].get('invalid_environment') and not r['run'].get('invalid_harness') and not r['run'].get('superseded_monitor')]
    latest={r['run']['users']:r for r in candidates}
    final=list(latest.values())
    curve=sorted(final,key=lambda r:r['run']['users'])
    comfortable=[r['run']['users'] for r in final if r['run']['pass'] and r['run']['users']<=result['confirmed'] and r['read'].get('p95',1e9)<=500
      and r['write'].get('p95',1e9)<=750 and r['error_rate']==0 and get(r,'cpu_busy_pct','p95')<70]
    comfort=max(comfortable,default=0)
    evidence={'result':result,'comfortable_measured':comfort,'final_workload_sha256':final_hash,'final_sampler_sha256':final_sampler,'environment':load(state/'environment.json'),
      'windows':load(state/'windows-environment.json'),'stages':runs,
      'verification':{p.stem:load(p) for p in state.glob('verification-*.json')},
      'cleanup':load(state/'cleanup-result.json') if (state/'cleanup-result.json').exists() else None,
      'preparation_incidents':load(state/'preparation-incidents.json') if (state/'preparation-incidents.json').exists() else [],
      'transport_control':load(state/'transport-control.json') if (state/'transport-control.json').exists() else None,
      'workload_correction':load(state/'workload-correction.json') if (state/'workload-correction.json').exists() else None,
      'monitoring_correction':load(state/'monitoring-correction.json') if (state/'monitoring-correction.json').exists() else None,
      'failed_collection_receipt_probes':load(state/'failed-collection-receipt-probes.json') if (state/'failed-collection-receipt-probes.json').exists() else None,
      'environment_after':load(state/'environment-after.json') if (state/'environment-after.json').exists() else None,
      'post_test_health':load(state/'post-test-health.json') if (state/'post-test-health.json').exists() else None}
    output.parent.mkdir(parents=True,exist_ok=True)
    data=output.parent/'data';data.mkdir(exist_ok=True)
    base=output.stem
    (data/(base+'.json')).write_text(json.dumps(evidence,indent=2),encoding='utf-8')
    plt.rcParams.update({'font.family':'DejaVu Sans','font.size':10,'axes.spines.top':False,'axes.spines.right':False})
    fig,axes=plt.subplots(2,2,figsize=(12,8),layout='constrained')
    x=[r['run']['users'] for r in curve]
    for key,title,color in [('read','Read p95','#2563eb'),('write','Write p95','#059669'),('latency','All p99','#d97706')]:
      axes[0,0].plot(x,[r[key].get('p99' if key=='latency' else 'p95',float('nan'))/1000 for r in curve],'o-',label=title,color=color)
    axes[0,0].axhline(1,color='#2563eb',ls=':',alpha=.6)
    axes[0,0].axhline(1.5,color='#059669',ls=':',alpha=.6)
    axes[0,0].axhline(3,color='#d97706',ls=':',alpha=.6)
    axes[0,0].set(title='Response time and acceptance limits',ylabel='Seconds');axes[0,0].legend()
    axes[0,1].plot(x,[r['successful_rps'] for r in curve],'o-',color='#2563eb',label='Successful requests/s')
    axes[0,1].set(title='Completed throughput',ylabel='Requests/s')
    twin=axes[0,1].twinx();twin.plot(x,[100*(r['error_rate'] or 0) for r in curve],'x--',color='#dc2626',label='Errors')
    twin.set_ylabel('Errors (%)',color='#dc2626');twin.set_ylim(bottom=0)
    axes[1,0].plot(x,[get(r,'cpu_busy_pct','avg') for r in curve],'o-',label='Host average',color='#2563eb')
    axes[1,0].plot(x,[get(r,'cpu_busy_pct','p95') for r in curve],'o--',label='Host p95',color='#7c3aed')
    axes[1,0].plot(x,[get(r,'lpg-db-1_cpu_pct','avg')/6 for r in curve],'s-',label='Database average / 6 cores',color='#059669')
    axes[1,0].set(title='CPU normalized to six cores',ylabel='Percent of VPS CPU',ylim=(0,105));axes[1,0].legend()
    axes[1,1].plot(x,[get(r,'disk_await_ms','p95') for r in curve],'o-',color='#d97706',label='Disk await p95')
    axes[1,1].set(title='Disk latency and utilization',ylabel='Await (ms)')
    twin=axes[1,1].twinx();twin.plot(x,[get(r,'disk_util_pct','p95') for r in curve],'s--',color='#7c3aed')
    twin.set_ylabel('Utilization p95 (%)',color='#7c3aed');twin.set_ylim(bottom=0)
    for ax in axes.flat:
      ax.set_xlabel('Independent businesses / active users');ax.grid(alpha=.15)
    fig.suptitle('LPG BDIX VPS — fixed-population confirmation and threshold tests',fontsize=14,fontweight='bold')
    fig.savefig(data/(base+'.png'),dpi=170);plt.close(fig)
    fig,axes=plt.subplots(2,2,figsize=(12,8),layout='constrained')
    axes[0,0].plot(x,[get(r,'MemAvailable','min')/2**30 for r in curve],'o-',label='Available VPS RAM',color='#2563eb')
    axes[0,0].plot(x,[r['resources'].get('containers',{}).get('lpg-db-1',{}).get('memory',{}).get('max',0)/2**30 for r in curve],'s-',label='Database charged RAM/cache',color='#d97706')
    axes[0,0].set(title='Memory',ylabel='GiB');axes[0,0].legend()
    for key,label,color in [('network_rx_Bps','VPS receive','#2563eb'),('network_tx_Bps','VPS transmit','#059669')]:
      axes[0,1].plot(x,[get(r,key)/1024 for r in curve],'o-',label=label,color=color)
    axes[0,1].set(title='Network throughput',ylabel='KiB/s');axes[0,1].legend()
    for key,label,color in [('db_connections','Connections','#2563eb'),('db_active','Active queries','#d97706'),('db_blocked','Blocked sessions','#dc2626')]:
      axes[1,0].plot(x,[get(r,key,'max') for r in curve],'o-',label=label,color=color)
    axes[1,0].set(title='PostgreSQL concurrency',ylabel='Maximum sampled sessions');axes[1,0].legend()
    axes[1,1].plot(x,[r['resources'].get('windows',{}).get('cpu_pct',{}).get('p95',0) for r in curve],'o-',color='#7c3aed')
    axes[1,1].set(title='Windows generator CPU',ylabel='p95 CPU (%)',ylim=(0,100))
    for ax in axes.flat:ax.set_xlabel('Independent businesses / active users');ax.grid(alpha=.15)
    fig.suptitle('Memory, network, database sessions and generator headroom',fontsize=14,fontweight='bold')
    fig.savefig(data/(base+'-resources.png'),dpi=170);plt.close(fig)
    endurance=next((r for r in reversed(runs) if 'endurance-' in r['run']['label'] and r['run']['pass']),None)
    if endurance:
      fig,axes=plt.subplots(2,1,figsize=(12,7),layout='constrained')
      for key,label,color in [('minute_read','Read p95','#2563eb'),('minute_write','Write p95','#059669'),('minute_latency','All p99','#d97706')]:
        points=sorted([(int(k),v['p99' if key=='minute_latency' else 'p95']/1000) for k,v in endurance.get(key,{}).items() if int(k)<30])
        if points:axes[0].plot([p[0] for p in points],[p[1] for p in points],'o-',label=label,color=color)
      axes[0].set(ylabel='Seconds',title=f'{endurance["run"]["users"]} independent businesses — 30-minute endurance');axes[0].legend();axes[0].grid(alpha=.15)
      start=endurance['run']['measured_start']
      server=[load_line for load_line in (json.loads(line) for line in (state/'server.jsonl').open()) if start<=load_line['time']<=start+1800 and load_line.get('derived')]
      axes[1].plot([(r['time']-start)/60 for r in server],[r['derived'].get('cpu_busy_pct',0) for r in server],color='#7c3aed')
      axes[1].set(xlabel='Measured minutes',ylabel='Host CPU (%)',ylim=(0,100));axes[1].grid(alpha=.15)
      fig.savefig(data/(base+'-endurance.png'),dpi=170);plt.close(fig)
    sections=[]
    sections.append(f'# LPG BDIX VPS concurrent-business capacity — 29 October 2026\n\nMeasured comfortable capacity: **{comfort}** active businesses. Highest confirmed endurance concurrency: **{result["confirmed"]}**. First failing requested stage: **{result["first_failed"]}**; fine-test failure bound: **{result["fine_failure"]}**. Each business has its own authenticated user, 2,000 customers and at least 20,000 historical invoices. These numbers apply to the tested workload and current deployment configuration.\n')
    sections.append(f'![Concurrency, response time and resource charts](data/{base}.png)\n')
    sections.append(f'![Memory, network, database concurrency and Windows resources](data/{base}-resources.png)\n')
    sections.append('## Target and method\n\nThe existing primary development backend at `144.79.249.4` was tested through its public Caddy/Envoy HTTPS API, Auth and PostgREST. Azure was not contacted. Windows generated all measured load and hosted k6 2.3.0, Grafana 13.3.0 and Prometheus 3.15.1. The VPS only hosted a five-second read-only sampler.\n\nThe server exposes six KVM vCPUs (Xeon E5-2695 v4, 2.10 GHz) and about 5.6 GiB RAM. Its actual virtual disk is **100 GiB**, with a roughly 99 GiB root filesystem, rather than the requested 150 GB. Existing PostgreSQL 17.6 retains its **1 GiB container limit**, 256 MiB shared buffers, 4 MiB work memory and 80 maximum connections. Existing PostgREST retains **ten pooled connections**. No optimization or service configuration change was made. All 39 migration versions and deployed source checksums were verified, with none pending.\n\nEach stage has 60 seconds warmup and five measured minutes, normal 1.5–2.5 second interaction delays, additional cart/payment review time, normal page fan-out, bounded draining and cooldown. The mixed cycle covers POS cash/split sales and collections, customer pages/search/reporting, stock and history, purchases with dispatch/receipt/payment, Finance ledger/dues/transfers, Dashboard and saved receipts. Every k6 VU owns a different business. Sessions refresh outside measurement windows. Preparation, analysis and reconciliation are excluded.\n\nThe requested discovery sequence is followed exactly. Additional tenants are fully seeded before the next discovery stage. Confirmation and fine tests keep the final stored population fixed. Legitimate measured writes accumulate; stored population and original history remain fixed, rather than restoring transactions between stages. Latency includes response failures and drain. Throughput counts completions inside the measured window. Minute-level tails, endpoint statistics and all resource aggregates are in the evidence JSON.\n')
    sections.append('## Dataset and correctness\n\nEach fixture contains 20,000 historical invoices over 180 days, 200 related purchase shipments, six SKUs, 2,000 customers, attributed cash/bank payments, subsequent collections, customer charges, physical empty receipts and stock movements. One quarter of invoices remain unpaid. Generation calls existing authenticated domain RPCs with RBAC, constraints and posting triggers enabled. Private hooks date only registered fixture inserts during preparation and are removed before load. Synthetic opening capital is documented; it is not real operator money.\n\nEvery stage checks wallet and running ledger balances, sale/payment/customer attribution, purchase funding, invoice totals, dues, stock/movement and bottle reconciliation. Authenticated foreign-tenant direct and RPC probes verify isolation. Existing business tables are fingerprinted separately. Full check results, sample counts and preservation evidence are retained.\n')
    sections.append('The histories use a **deterministic shared statistical template** across businesses: even customer rotation, fixed SKU/cart/payment cycles and the same 180-day date pattern. Records and financial/stock postings are created independently through business functions. This enables repeatable measurements but omits real-world skew, seasonal concentration and differing business profiles. Those distributions can change query selectivity, cache locality and tail latency. Random primary keys alone do not address that limitation. The measured capacity is conditional on this standardized business shape, not a universal maximum for every LPG business.\n')
    sections.append('## Criteria and safety\n\nPass: read p95 ≤1 s, write p95 ≤1.5 s, overall p99 ≤3 s, unexpected errors <0.5%, zero correctness failures. Comfortable: read p95 ≤0.5 s, write p95 ≤0.75 s, no observed errors, host CPU p95 <70%. The highest passing concurrency is tested for 30 measured minutes after warmup.\n\nAutomatic stops protect memory/disk reserves, swap, OOM, sustained >95% host CPU, blocked/long queries, Windows generator resources and stale monitoring. Severe error/latency thresholds also abort k6. Exact values and reproduction commands are in the [suite guide](../../supabase/tests/vps-capacity/README.md).\n')
    sections.append('## All measured stages\n\nHTTP times are milliseconds. RPS counts successful completed requests inside the window; errors include unsuccessful responses, not only successful latency. Discovery rows have changing stored populations; fixed/fine/endurance rows share the final population.\n\n| Stage | Users | Stored businesses | Minutes | Requests | OK/s | Mean | All p95 | Read p95 | Write p95 | All p99 | Errors | Pass |\n|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|:---:|')
    for r in runs:
      n=r['run']
      error_text=f'{100*r["error_rate"]:.2f}%' if r['error_rate'] is not None else '—'
      outcome='invalid harness' if n.get('invalid_harness') else ('superseded monitor' if n.get('superseded_monitor') else ('invalid environment' if n.get('invalid_environment') else ('yes' if n['pass'] else 'no')))
      sections.append(f'| {n["label"]} | {n["users"]} | {n["population"]} | {r.get("measured_seconds",n["seconds"])/60:.1f} | {r["requests"]:,} | {r["successful_rps"]:.2f} | {timing(r,"latency","avg")} | {timing(r,"latency","p95")} | {timing(r,"read","p95")} | {timing(r,"write","p95")} | {timing(r,"latency","p99")} | {error_text} | {outcome} |')
    sections.append('\n## Correlated resources\n\nCPU uses host average/p95; DB CPU uses 100% per core. RAM is minimum available host GiB / maximum DB container MiB, including charged file cache. Disk and network rates are averages; await/utilization are p95. PostgreSQL transactions include sampler/background commits and do not equal business invoices. Per-core utilization/steal, all container resources, database waits/locks/temp files, query deltas and generator memory are in JSON.\n\n| Stage | CPU avg/p95 % | DB CPU % | RAM free GiB / DB MiB | Swap MiB | Disk R/W MiB/s | Await ms / util % | Net RX/TX KiB/s | DB connections / active max | DB commits/s | Windows CPU p95 % |\n|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
    for r in runs:
      dbmem=r['resources'].get('containers',{}).get('lpg-db-1',{}).get('memory',{}).get('max',0)/2**20
      wc=r['resources'].get('windows',{}).get('cpu_pct',{}).get('p95',0)
      sections.append(f'| {r["run"]["label"]} | {get(r,"cpu_busy_pct"):.1f}/{get(r,"cpu_busy_pct","p95"):.1f} | {get(r,"lpg-db-1_cpu_pct"):.0f} | {get(r,"MemAvailable","min")/2**30:.2f} / {dbmem:.0f} | {get(r,"swap_used","max")/2**20:.0f} | {get(r,"disk_read_Bps")/2**20:.2f}/{get(r,"disk_write_Bps")/2**20:.2f} | {get(r,"disk_await_ms","p95"):.1f}/{get(r,"disk_util_pct","p95"):.1f} | {get(r,"network_rx_Bps")/1024:.0f}/{get(r,"network_tx_Bps")/1024:.0f} | {get(r,"db_connections","max"):.0f}/{get(r,"db_active","max"):.0f} | {get(r,"postgres_xact_commit_per_s"):.1f} | {wc:.1f} |')
    sections.append('\nDisk await p95 is the p95 of five-second mean await samples, rather than a per-I/O latency percentile. PostgreSQL buffer-block reads can include operating-system cache hits; physical disk bytes are reported separately.\n')
    sections.append('## Per-core CPU, steal and I/O wait\n\nEach cell is average / p95 percent over measured resource samples. Core busy percentages refer to that individual vCPU; host steal and I/O wait refer to all six vCPUs.\n\n| Stage | Core 0 | Core 1 | Core 2 | Core 3 | Core 4 | Core 5 | Host steal | Host I/O wait |\n|---|---:|---:|---:|---:|---:|---:|---:|---:|')
    for r in runs:
      cells=[]
      for key in [*(f'cpu{i}_busy_pct' for i in range(6)),'cpu_steal_pct','cpu_iowait_pct']:
        metric=r['resources'].get(key,{})
        cells.append(f'{metric["avg"]:.1f}/{metric["p95"]:.1f}' if metric else '—')
      sections.append('| '+r['run']['label']+' | '+' | '.join(cells)+' |')
    sections.append('## Windows generator and network latency\n\nCPU uses all Windows logical processors. Ping latency includes only successful probes to the VPS; success fraction is based on five-second samples retaining the latest 15-second ICMP result. Network errors/drops are interface counters, not HTTP application errors. Invalid generator/monitoring runs cannot establish VPS capacity.\n\n| Stage | Windows CPU avg/p95 % | Available RAM min GiB | k6 RSS max MiB | k6 CPU % of one core | Ping avg/p95 ms | Sampled ping success % | Interface errors/drops delta |\n|---|---:|---:|---:|---:|---:|---:|---:|')
    for r in runs:
      w=r['resources'].get('windows',{})
      cpu=w.get('cpu_pct',{});ping=w.get('network_ping_ms',{})
      ping_text=f'{ping["avg"]:.1f}/{ping["p95"]:.1f}' if ping else '—'
      k6cpu=w.get('k6_cpu_percent_one_core')
      k6cpu_text=f'{k6cpu:.1f}' if k6cpu is not None else '—'
      sections.append(f'| {r["run"]["label"]} | {cpu.get("avg",0):.1f}/{cpu.get("p95",0):.1f} | {w.get("available",{}).get("min",0)/2**30:.2f} | {w.get("k6_rss",{}).get("max",0)/2**20:.1f} | {k6cpu_text} | {ping_text} | {100*w.get("network_ping_ok",{}).get("avg",0):.1f} | {w.get("network_errors_delta","—")} |')
    sections.append('## Business operation throughput\n\nSuccessful measured API completions per second; these are application operations rather than database commits. POS calls include the separately counted exact idempotent replays, which do not create another invoice. Purchase creation and its later dispatch/receipt/payment calls are separate operations. Warmup and fixture generation are excluded.\n\n| Stage | POS calls/s | Collections/s | Purchase creation/s | Purchase payments/s | Wallet operations/s | Exact POS replays |\n|---|---:|---:|---:|---:|---:|---:|')
    for r in runs:
      def rate(name):
        endpoint=r['endpoints'].get(name,{})
        return endpoint.get('requests',0)*(1-(endpoint.get('error_rate') or 0))/max(1,r['measured_seconds'])
      sections.append(f'| {r["run"]["label"]} | {rate("create_pos_sale"):.3f} | {rate("collect_sale_payment"):.3f} | {rate("create_purchase"):.3f} | {rate("record_purchase_payment"):.3f} | {rate("move_wallet_money"):.3f} | {r.get("idempotent_replays",0):.0f} |')
    if endurance:
      sections.append('\n## PostgreSQL slow-query evidence during endurance\n\nFingerprints present in both endpoint snapshots only. Deltas span the first to last five-second resource samples within measurement, so their coverage is slightly shorter than the HTTP window. Block reads can be served by OS cache. Fingerprints entering the sampled top list without a starting counter are excluded; no SQL bodies or business records are exported.\n\n| Endpoint | Calls | Mean DB ms | Total DB seconds | Blocks read | Temp blocks written |\n|---|---:|---:|---:|---:|---:|')
      for q in endurance.get('query_deltas',[])[:12]:
        sections.append(f'| {q.get("endpoint","unknown")} | {q["calls"]:,} | {q["mean_ms"]:.1f} | {q["total_ms"]/1000:.1f} | {q["blocks_read"]:,} | {q["temp_blocks_written"]:,} |')
      sections.append('## Endpoint behavior at sustained capacity\n\nTimes are milliseconds. The baseline is the latest one-user confirmation with the same population and script.\n\n| Operation | One-user p95 | Endurance p95 | Endurance p99 | Endurance requests |\n|---|---:|---:|---:|---:|')
      baseline=latest.get(1,curve[0])
      names=['get_sales_directory','get_customer_directory','get_sales_overview','get_wallet_ledger','get_product_inventory','get_purchase_settlement','get_dashboard_stats','create_pos_sale','collect_sale_payment','create_purchase','record_purchase_payment','move_wallet_money']
      for name in names:
        a=baseline['endpoints'].get(name,{});b=endurance['endpoints'].get(name,{})
        if b:sections.append(f'| {name} | {a.get("p95",0):.0f} | {b.get("p95",0):.0f} | {b.get("p99",0):.0f} | {b["requests"]:,} |')
      sections.append('\n## Containers during endurance\n\nCPU uses 100% per core. Charged memory includes file cache; anonymous and file figures are maxima and should not be added across different sample times.\n\n| Container | CPU avg / p95 % | Charged RAM max MiB | Anonymous max MiB | File/shared cache max MiB | OOM kills |\n|---|---:|---:|---:|---:|---:|')
      for name,c in endurance['resources'].get('containers',{}).items():
        sections.append(f'| {name} | {get(endurance,name+"_cpu_pct"):.1f}/{get(endurance,name+"_cpu_pct","p95"):.1f} | {c["memory"].get("max",0)/2**20:.0f} | {c["anon"].get("max",0)/2**20:.0f} | {c["file"].get("max",0)/2**20:.0f} | {c.get("memory_events_delta",{}).get("oom_kill",0)} |')
    sections.append('\n## Interpretation and operational recommendations\n\nReview the measured endpoint/resource evidence and add the specific degradation/bottleneck analysis here before delivery. Resource headroom is not a linear user-capacity forecast.\n')
    if endurance:sections.append(f'![Thirty-minute endurance latency and CPU](data/{base}-endurance.png)\n')
    sections.append('## Azure comparison and limits\n\nThe [23 October Azure result](2026-10-23-customer-load-test.md) passed 40 active reporting users at 439 ms successful p95 and failed 80 at 32.74% errors. It used a burstable two-vCPU/4-GiB VM, the same 1-GiB database cap and ten-query pool, 640 stored businesses, a disposable reporting database, preissued test JWTs and eight SSH forwards. Its 20,000 sales per business had no reconciled stock/payment ledger. Measured windows lasted 90 seconds and contained only customer directory/reporting reads.\n\nThis benchmark uses current schema, normal Auth sessions, public HTTPS, mixed page fan-out and writes, longer stages, fixed-population confirmation and endurance. Shared customer scopes, 25-record batches and 1.5–2.5 second think time preserve useful methodological continuity. The datasets and workloads differ materially: **no numerical speedup or direct Azure-to-BDIX capacity ratio is justified**. Azure CPU credit balance was never collected, so its long-duration baseline is also unavailable.\n\nCapacity is conditional on this data density, query/write mix, six-SKU catalogs and one user per business. Login storms, browser/device rendering, realtime subscription fleets, print hardware and external payment settlement are outside scope. More history, products, simultaneous staff within a tenant or different interaction rates can change the limit. A 30-minute endurance test is not a multi-day reliability guarantee.\n')
    sections.append(f'## Evidence and recovery\n\n[Complete sanitized metrics and checks](data/{base}.json). Raw k6/resource time series remain in ignored `.temp/vps-capacity/`. [Reusable infrastructure](../../supabase/tests/vps-capacity/README.md). Local Grafana retains its historical dashboard at <http://127.0.0.1:13000/d/lpg-vps-capacity>.\n\nCleanup and post-test health status: {"verified in attached evidence" if evidence["cleanup"] and evidence["post_test_health"] else "pending; do not present this draft as complete"}.\n')
    text='\n'.join(sections)
    if tuned:
      text=text.replace('Its actual virtual disk is **100 GiB**, with a roughly 99 GiB root filesystem, rather than the requested 150 GB.',
        'The verified virtual disk is **100 GiB**, with a roughly 99 GiB root filesystem.')
      text=text.replace('LPG BDIX VPS concurrent-business capacity — 29 October 2026',
        'LPG BDIX VPS tuned concurrent-business capacity — 29 October 2026')
      text=text.replace('Existing PostgreSQL 17.6 retains its **1 GiB container limit**, 256 MiB shared buffers, 4 MiB work memory and 80 maximum connections. Existing PostgREST retains **ten pooled connections**. No optimization or service configuration change was made.',
        'PostgreSQL 17.6 now has a **2.5 GiB container limit**, 640 MiB shared buffers, 1920 MiB effective cache estimate, 4 MiB work memory, 64 MiB maintenance memory, a 2 GiB WAL checkpoint target and 80 maximum connections. PostgREST retains **ten pooled connections**. Realtime and Studio limits are each 384 MiB; imgproxy is 128 MiB. The active service limits total 4800 MiB, leaving about 982 MiB outside their combined ceilings on the actual 5782 MiB host. These are ceilings, not reserved allocations. Linux uses spare RAM for reclaimable cache. The memory settings were deployed through the established backup and health workflow before preparation; no query/schema/frontend optimization was included.')
      text=text.replace('The requested discovery sequence is followed exactly. Additional tenants are fully seeded before the next discovery stage. Confirmation and fine tests keep the final stored population fixed.',
        'Following the revised request, measurement starts at **80 users**. A failure moves to 40; a passing 40 moves to 60. Subsequent integer midpoint tests narrow the passing/failing bracket. All 80 businesses are fully prepared before the first stage and remain stored at every lower-concurrency stage. A higher passing bracket would require preparing its complete population before testing. No one-user restart is used.')
      text=text.replace('Discovery rows have changing stored populations; fixed/fine/endurance rows share the final population.',
        'All rows show their stored population explicitly. Safety-aborted rows can have shorter measured windows and establish a failure bound, not sustainable throughput.')
      text=text.replace('The baseline is the latest one-user confirmation with the same population and script.',
        'The comparison column is the lowest measured concurrency with the same population and script; it is not a single-user baseline.')
      text=text.replace('| One-user p95 |','| Lowest-stage p95 |')
      text=text.replace('`.temp/vps-capacity/`','`.temp/vps-capacity-tuned/`')
      baseline_path=output.parent/'data/2026-10-29-bdix-vps-capacity.json'
      if baseline_path.exists():
        old=load(baseline_path)
        text+='\n## Untuned BDIX comparison\n\nThe [earlier BDIX baseline](2026-10-29-bdix-vps-capacity.md) confirmed 11 users for 30 minutes with a 1 GiB database ceiling and 256 MiB shared buffers; 12 users failed the latency criterion. That run stored 15 fixture businesses. This tuned run stores '+str(result['population'])+' businesses, so memory settings and total stored data both differ. The workload hash is '+('identical' if final_hash==old['final_workload_sha256'] else 'different')+'. The measured capacity difference must not be attributed solely to RAM tuning; a controlled memory-only A/B comparison was not performed.\n'
    output.write_text(text,encoding='utf-8')
    print(json.dumps({'report':str(output),'charts':str(data/(base+'.png')),'comfortable':comfort,'confirmed':result['confirmed']}))


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--state',type=Path,default=Path('.temp/vps-capacity'))
    parser.add_argument('--output',type=Path,default=Path('docs/reports/2026-10-29-bdix-vps-capacity.md'))
    parser.add_argument('--tuned',action='store_true')
    args=parser.parse_args();main(args.state,args.output,args.tuned)
