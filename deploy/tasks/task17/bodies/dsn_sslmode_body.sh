#!/usr/bin/env bash
# 只读探针：SQL_DSN / SQL_DSN_MIGRATE 的 sslmode 实况（脱敏，仅打印结构，绝不打印口令）
set -u
NS=new-api
for k in SQL_DSN SQL_DSN_MIGRATE; do
  echo "=== $k ==="
  kubectl -n $NS get secret new-api-secrets -o jsonpath="{.data.$k}" 2>/dev/null | base64 -d 2>/dev/null | python3 -c "
import sys,re
from urllib.parse import urlparse
v=sys.stdin.read().strip()
if not v:
    print('  (键不存在或为空)'); raise SystemExit
p=urlparse(v)
q=dict(x.split('=',1) for x in (p.query.split('&') if p.query else []) if '=' in x)
print('  scheme=%s user=%s host=%s port=%s db=%s' % (p.scheme, p.username, p.hostname, p.port, (p.path or '').lstrip('/')))
print('  query_params=%s' % (sorted(q.keys()) or '（无）'))
print('  sslmode=%s' % q.get('sslmode', '（未设置 ⇒ pgx 默认 prefer，不验证证书链）'))
"
done
echo "DONE-T17-SSLMODE"
