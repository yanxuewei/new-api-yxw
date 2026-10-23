#!/usr/bin/env python3
import subprocess, os, glob, time

os.chdir('/opt/OmniTradeERP')

LOG = open('/tmp/rebuild4.log', 'w', buffering=1)

def log(msg):
    print(msg, flush=True)
    LOG.write(msg + '\n')
    LOG.flush()

def run(cmd):
    log(f'$ {cmd}')
    r = subprocess.run(cmd, shell=True, stdout=LOG, stderr=LOG)
    return r.returncode

def capture(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return r.stdout.strip()

log('=== step1: rebuild images ===')
for svc in ['customer', 'supplier', 'product', 'warehouse', 'inventory']:
    matches = glob.glob(f'docker/Dockerfile.{svc}-service')
    if not matches:
        matches = glob.glob(f'docker/Dockerfile.{svc}')
    df = matches[0] if matches else None
    if not df:
        log(f'  {svc}: no Dockerfile, skip')
        continue
    img = f'omnitradeerp-{svc}-service'
    log(f'  building {svc} from {df} -> {img}')
    run(f'docker build -f {df} -t {img}:latest .')

log('\n=== step2: restart services ===')
svcs = 'customer-service supplier-service product-service warehouse-service inventory-service order-service gateway'
run(f'docker compose up -d --no-build {svcs}')

log('\n=== step3: wait 90s ===')
time.sleep(90)

log('\n=== step4: health check ===')
fmt = '{{.Names}} {{.Status}}'
out = capture(f'docker ps --format "{fmt}"')
for line in out.splitlines():
    if 'service' in line or 'gateway' in line:
        log('  ' + line)

log('\n=== step5: actuator health ===')
for p in [8081, 8083, 8085, 8086, 8087, 8088]:
    fmt2 = '%{http_code}'
    code = capture(f'curl -s -o /dev/null -w "{fmt2}" --max-time 5 http://localhost:{p}/actuator/health')
    log(f'  port {p}: {code}')

log('\nDONE')
LOG.close()
