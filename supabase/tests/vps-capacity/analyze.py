"""Summarize raw k6 cohorts with aligned five-second resource measurements."""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import statistics
import os


def percentile(values, n):
    if not values:
        return None
    values=sorted(values)
    p=(len(values)-1)*n/100
    i=int(p)
    return values[i]+(values[min(i+1,len(values)-1)]-values[i])*(p-i)


def stats(values):
    values=[x for x in values if x is not None]
    return {'min':min(values),'avg':statistics.mean(values),'p50':percentile(values,50),'p95':percentile(values,95),
            'p99':percentile(values,99),'max':max(values)} if values else {}


def lines(path):
    if not path.exists():
        return
    with path.open() as stream:
        for line in stream:
            if line.strip(): yield json.loads(line)


def analyze(state,label):
    run=json.loads((state/(label+'-run.json')).read_text())
    latency,read,write,actions=[],[],[],[]
    endpoint=defaultdict(list)
    endpoint_errors=defaultdict(list)
    errors=[]
    minutes=defaultdict(list)
    minute_reads=defaultdict(list)
    minute_writes=defaultdict(list)
    first,last=None,None
    success=0
    request_times=[]
    success_times=[]
    correctness=0
    replays=0
    timeouts=0
    code_counts=defaultdict(int)
    connection=defaultdict(list)
    raw_http_errors=[]
    raw_http_latency=[]
    from datetime import datetime
    for point in lines(state/(label+'-requests.jsonl')):
        if point['type']!='Point': continue
        d=point['data']; tags=d.get('tags',{})
        if point['metric']=='correctness_failures': correctness+=d['value']
        if tags.get('phase')!='measured': continue
        t=datetime.fromisoformat(d['time'].replace('Z','+00:00')).timestamp()
        if point['metric']=='operation_latency':
            first=t if first is None else min(first,t);last=t if last is None else max(last,t)
            latency.append(d['value']); endpoint[tags['endpoint']].append(d['value'])
            request_times.append(t)
            (write if tags['kind']=='write' else read).append(d['value'])
            minute=int((t-run.get('measured_start',run['started']+run['warmup']))//60)
            minutes[minute].append(d['value'])
            (minute_writes if tags['kind']=='write' else minute_reads)[minute].append(d['value'])
        elif point['metric']=='operation_errors':
            errors.append(d['value']);endpoint_errors[tags['endpoint']].append(d['value'])
        elif point['metric']=='successful_requests':
            success+=d['value']
            success_times.extend([t]*int(d['value']))
        elif point['metric']=='unexpected_errors': code_counts[tags.get('code','unknown')]+=d['value']
        elif point['metric']=='action_latency': actions.append(d['value'])
        elif point['metric']=='idempotent_replays':replays+=d['value']
        elif point['metric']=='request_timeouts':timeouts+=d['value']
        elif point['metric']=='http_req_failed':raw_http_errors.append(d['value'])
        elif point['metric']=='http_req_duration':raw_http_latency.append(d['value'])
        elif point['metric'].startswith('http_req_') and point['metric']!='http_req_duration': connection[point['metric']].append(d['value'])
    begin=run.get('measured_start',run['started']+run['warmup'])
    end=min(begin+run['seconds'],run['ended'])
    server=[r for r in lines(state/'server.jsonl') if begin<=r['time']<=end and r.get('derived')]
    windows=[r for r in lines(state/'windows.jsonl') if begin<=r['time']<=end]
    resource={}
    keys=sorted({k for r in server for k in r['derived']})
    for k in keys: resource[k]=stats([r['derived'].get(k) for r in server])
    for k in ['MemAvailable','SwapFree','Dirty','Writeback']:
        resource[k]=stats([r['memory'][k] for r in server])
    resource['swap_used']=stats([r['memory']['SwapTotal']-r['memory']['SwapFree'] for r in server])
    resource['disk_free_bytes']=stats([r['disk_free_bytes'] for r in server])
    for k in ['active','connections','client_connections','replication_connections','blocked','longest_seconds']:
        resource['db_'+k]=stats([r.get('database',{}).get(k) for r in server])
    waits=sorted({name for r in server for name in r.get('database',{}).get('waits',{})})
    resource['db_waits']={name:stats([r.get('database',{}).get('waits',{}).get(name,0) for r in server]) for name in waits}
    resource['sampler_elapsed_seconds']=stats([r.get('sample_elapsed_seconds') for r in server])
    if server:
        resource['host_oom_kills_delta']=server[-1]['vm']['oom_kill']-server[0]['vm']['oom_kill']
    resource['containers']={}
    for name in sorted({name for r in server for name in r['containers']}):
        resource['containers'][name]={'memory':stats([r['containers'][name]['memory'] for r in server]),
          'anon':stats([r['containers'][name]['memory_stat'].get('anon') for r in server]),
          'file':stats([r['containers'][name]['memory_stat'].get('file') for r in server])}
        first_events=server[0]['containers'][name]['events']
        last_events=server[-1]['containers'][name]['events']
        resource['containers'][name]['memory_events_delta']={key:last_events[key]-first_events.get(key,0) for key in last_events}
    resource['windows']={k:stats([r.get(k) for r in windows]) for k in ['cpu_pct','available','network_rx_Bps','network_tx_Bps','k6_rss','network_ping_ok','network_ping_ms']}
    if len(windows)>1:
        resource['windows']['network_errors_delta']=windows[-1]['net_errors']-windows[0]['net_errors']
        elapsed=windows[-1]['time']-windows[0]['time']
        cpu_delta=windows[-1]['k6_cpu_seconds']-windows[0]['k6_cpu_seconds']
        resource['windows']['k6_cpu_percent_one_core']=100*cpu_delta/elapsed if cpu_delta>=0 else None
    queries=[]
    unaligned_queries=[]
    if server:
        q0={q['queryid']:q for q in server[0].get('database',{}).get('queries',[])}
        for q in server[-1].get('database',{}).get('queries',[]):
            if q['queryid'] not in q0:
                # A fingerprint entering the sampled top list has cumulative
                # history, not a known stage-start counter. Never call it a delta.
                unaligned_queries.append(q['queryid'])
                continue
            old=q0.get(q['queryid'],{})
            calls=q['calls']-old.get('calls',0)
            total=q['total_exec_time']-old.get('total_exec_time',0)
            if calls>0 and total>=0:
                queries.append({'queryid':q['queryid'],'calls':calls,'total_ms':total,'mean_ms':total/calls,
                  'blocks_read':q['shared_blks_read']-old.get('shared_blks_read',0),
                  'temp_blocks_written':q['temp_blks_written']-old.get('temp_blks_written',0)})
    effective=max(1,end-begin)
    result={'run':run,'measured_seconds':effective,'requests':len(latency),'successful':success,'rps':sum(begin<=t<=end for t in request_times)/effective,
      'successful_rps':sum(begin<=t<=end for t in success_times)/effective,'error_rate':statistics.mean(errors) if errors else None,
      'error_codes':dict(code_counts),'timeouts':timeouts,'correctness_failures':correctness,'idempotent_replays':replays,
      'raw_http_failure_rate':statistics.mean(raw_http_errors) if raw_http_errors else None,
      'raw_http_requests':len(raw_http_latency),'raw_http_latency':stats(raw_http_latency),
      'latency':stats(latency),'read':stats(read),'write':stats(write),'action_latency':stats(actions),
      'endpoints':{name:{**stats(v),'requests':len(v),'error_rate':statistics.mean(endpoint_errors[name]) if endpoint_errors[name] else None} for name,v in endpoint.items()},
      'minute_latency':{str(k):stats(v) for k,v in sorted(minutes.items())},
      'minute_read':{str(k):stats(v) for k,v in sorted(minute_reads.items())},
      'minute_write':{str(k):stats(v) for k,v in sorted(minute_writes.items())},
      'connection':{k:stats(v) for k,v in connection.items()},'resources':resource,
      'query_deltas':sorted(queries,key=lambda q:q['total_ms'],reverse=True),
      'query_fingerprints_without_start_counter':unaligned_queries,'resource_samples':len(server)}
    (state/(label+'-analysis.json')).write_text(json.dumps(result,indent=2))
    print(json.dumps({'label':label,'users':run['users'],'requests':len(latency),'rps':result['rps'],
      'p95':result['latency'].get('p95'),'p99':result['latency'].get('p99'),'error_rate':result['error_rate'],
      'CPU_avg':resource.get('cpu_busy_pct',{}).get('avg'),'CPU_p95':resource.get('cpu_busy_pct',{}).get('p95')}))
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('label')
    parser.add_argument('--state',type=Path,default=Path(os.environ.get('LPG_CAPACITY_STATE','.temp/vps-capacity')))
    args=parser.parse_args()
    analyze(args.state,args.label)
