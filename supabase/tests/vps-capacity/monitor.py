"""Windows monitor and loopback Prometheus bridge. SSH sampler never runs load."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import threading
import time
import re
import socket
import hashlib

import psutil
import ctypes

parser = argparse.ArgumentParser()
parser.add_argument('--state', type=Path, required=True)
parser.add_argument('--host', required=True)
parser.add_argument('--port', default='22')
parser.add_argument('--key')
args = parser.parse_args()
state = args.state.resolve()
# Hold a temporary system-awake request while the automated test monitor lives.
# Display sleep remains allowed; no persistent power-plan setting is changed.
ctypes.windll.kernel32.SetThreadExecutionState(0x80000001)
latest = {'server': {}, 'windows': {}}
previous = None
ssh = ['ssh'] + (['-i', args.key] if args.key else []) + ['-p', args.port, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', args.host]


def derive(r, p):
    if not p or 'cpu' not in p:
        return {}
    elapsed = r.get('server_time',r['time'])-p.get('server_time',p['time'])
    result = {}
    for name, ticks in r['cpu'].items():
        delta = [a-b for a,b in zip(ticks, p['cpu'][name])]
        total = sum(delta[:8]) or 1
        result[name+'_busy_pct'] = 100*(1-(delta[3]+delta[4])/total)
        result[name+'_steal_pct'] = 100*delta[7]/total
        result[name+'_iowait_pct'] = 100*delta[4]/total
    for name,c in r['containers'].items():
        if name in p['containers']:
            result[name+'_cpu_pct'] = (c['cpu_usec']-p['containers'][name]['cpu_usec'])/elapsed/10000
    for name, d in r['disk'].items():
        old = p['disk'][name]
        ios = (d[0]+d[4]-old[0]-old[4])
        result['disk_await_ms'] = (d[3]+d[7]-old[3]-old[7])/max(1,ios)
        result['disk_util_pct'] = (d[9]-old[9])/elapsed/10
        result['disk_read_Bps'] = (d[2]-old[2])*512/elapsed
        result['disk_write_Bps'] = (d[6]-old[6])*512/elapsed
        result['disk_queue'] = (d[10]-old[10])/elapsed/1000
    for name, n in r['net'].items():
        if name in p['net']:
            result['network_rx_Bps'] = (n[0]-p['net'][name][0])/elapsed
            result['network_tx_Bps'] = (n[8]-p['net'][name][8])/elapsed
    db, olddb = r.get('database',{}).get('db'), p.get('database',{}).get('db')
    if db and olddb:
        for key in ['xact_commit','xact_rollback','blks_read','blks_hit','temp_bytes','deadlocks']:
            result['postgres_'+key+'_per_s'] = (db[key]-olddb[key])/elapsed
    return result


def server():
    global previous
    # No SSH arguments contain credentials or code payloads.
    process = subprocess.Popen(ssh+['sudo -n python3 -u /tmp/lpg-capacity-sample.py'], stdout=subprocess.PIPE,
        stderr=open(state/'monitor-ssh.stderr','w'), text=True, creationflags=subprocess.CREATE_NO_WINDOW)
    (state/'monitor-ssh.pid').write_text(str(process.pid))
    with (state/'server.jsonl').open('a', buffering=1) as output:
        for line in process.stdout:
            r = json.loads(line)
            r['received_time']=time.time()
            if 'sample_elapsed_seconds' in r:
                r['server_time']=r['time']
                r['time']=r['received_time']-r['sample_elapsed_seconds']
                r['clock_mapping']='Windows receive time minus collection duration; includes one-way SSH latency'
            if 'cpu' in r:
                r['derived'] = derive(r, previous)
                previous = r
                latest['server'] = r
            output.write(json.dumps(r)+'\n')


def windows():
    psutil.cpu_percent()
    prior_net, prior_time = psutil.net_io_counters(), time.time()
    last_ping=0
    ping_metrics={}
    with (state/'windows.jsonl').open('a', buffering=1) as output:
        while not (state/'stop-monitor').exists():
            now = time.time()
            net = psutil.net_io_counters()
            memory = psutil.virtual_memory()
            k6 = [p for p in psutil.process_iter(['name','memory_info','cpu_times']) if p.info['name'].lower()=='k6.exe']
            r = {'time':now, 'cpu_pct':psutil.cpu_percent(), 'available':memory.available, 'memory_pct':memory.percent,
                 'network_rx_Bps':(net.bytes_recv-prior_net.bytes_recv)/(now-prior_time),
                 'network_tx_Bps':(net.bytes_sent-prior_net.bytes_sent)/(now-prior_time),
                 'k6_rss':sum(p.info['memory_info'].rss for p in k6),
                 'k6_cpu_seconds':sum(sum(p.info['cpu_times'][:2]) for p in k6),
                 'net_errors':net.errin+net.errout+net.dropin+net.dropout}
            battery=psutil.sensors_battery()
            if battery:
                r['battery_pct']=battery.percent
                r['power_plugged']=int(battery.power_plugged)
            if now-last_ping>=15:
                probe=subprocess.run(['ping','-n','1','-w','2000',args.host.rsplit('@',1)[-1]],
                    text=True,capture_output=True,timeout=3,creationflags=subprocess.CREATE_NO_WINDOW)
                ping_metrics={'network_ping_ok':int(probe.returncode==0)}
                match=re.search(r'Average = (\d+)ms',probe.stdout)
                if match:ping_metrics['network_ping_ms']=int(match[1])
                last_ping=now
            r.update(ping_metrics)
            addresses=sorted((name,a.address) for name,values in psutil.net_if_addrs().items() for a in values
                if a.family==socket.AF_INET and not a.address.startswith(('127.','169.254.')))
            r['network_signature']=hashlib.sha256(json.dumps(addresses).encode()).hexdigest()
            latest['windows'] = r
            output.write(json.dumps(r)+'\n')
            prior_net, prior_time = net, now
            time.sleep(5)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/state':
            body = json.dumps(latest).encode()
        else:
            lines = []
            def emit(name, value, labels=''):
                lines.append(f'lpg_{name}{labels} {value}')
            s, w = latest['server'], latest['windows']
            if s:
                emit('server_sample_timestamp_seconds',s['time'])
                for key,value in s.get('derived',{}).items():
                    emit(key.replace('-','_'),value)
                for key,value in s['memory'].items():
                    emit('server_'+key+'_bytes',value)
                emit('server_disk_free_bytes',s['disk_free_bytes'])
                for key in ['connections','active','blocked','longest_seconds']:
                    if key in s.get('database',{}): emit('postgres_'+key,s['database'][key])
                for name,c in s['containers'].items():
                    emit('container_memory_bytes',c['memory'],f'{{container="{name}"}}')
            for key,value in w.items():
                if isinstance(value,(int,float)):emit('windows_'+key,value)
            try:
                current=json.loads((state/'current-stage.json').read_text())
                emit('active_businesses',current['users'])
            except (FileNotFoundError,KeyError):
                pass
            body = ('\n'.join(lines)+'\n').encode()
        self.send_response(200)
        self.send_header('Content-Type','application/json' if self.path=='/state' else 'text/plain; version=0.0.4')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self,*args):
        pass


threading.Thread(target=server,daemon=True).start()
threading.Thread(target=windows,daemon=True).start()
ThreadingHTTPServer(('127.0.0.1',9917), Handler).serve_forever()
