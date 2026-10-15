#!/bin/bash
# __TITLE__ — LOG_SQL_DSN 切 MySQL（节点内执行；ack_remote body）
# 占位符：__DEPLOY__ / __DSN_B64__
set -uo pipefail
export KUBECONFIG="${K8S:-/tmp/k8s/kubeconfig}"
NS=new-api
DEP="__DEPLOY__"
B64=__DSN_B64__

echo "### 0) 备份当前 LOG_SQL_DSN（b64 原样回传，本地留回滚）"
CUR=$(kubectl -n "$NS" get secret new-api-secrets -o jsonpath='{.data.LOG_SQL_DSN}' 2>/dev/null)
echo "CURRENT_B64=${CUR}"

echo "### 1) patch 单键 LOG_SQL_DSN"
python3 - "$B64" <<'PY'
import base64, json, re, sys
dsn = base64.b64decode(sys.argv[1]).decode()
m = re.match(r'([^:]+):([^@]+)@tcp\(([^:]+):(\d+)\)/([^?]+)(?:\?(.*))?', dsn)
if m:
    host, db, q = m.group(3), m.group(5), m.group(6) or ''
    print('patch host=%s db=%s tls=%s' % (host, db, 'true' if 'tls=true' in q else 'false'))
else:
    print('patch raw dsn (scheme=%s)' % dsn.split('://')[0] if '://' in dsn else 'patch raw dsn')
open('/tmp/logdsn_patch.json', 'w').write(json.dumps({"stringData": {"LOG_SQL_DSN": dsn}}))
PY
kubectl -n "$NS" patch secret new-api-secrets --type merge --patch-file /tmp/logdsn_patch.json 2>&1
RC_PATCH=$?
rm -f /tmp/logdsn_patch.json
[ "$RC_PATCH" = "0" ] || { echo PATCH_FAIL; exit 1; }

echo "### 2) 改后回读（打码）"
kubectl -n "$NS" get secret new-api-secrets -o jsonpath='{.data.LOG_SQL_DSN}' | base64 -d \
  | sed -E 's#([^:]+):[^@]+@#\1:***@#'
echo ""

echo "### 3) 滚动重启"
kubectl -n "$NS" rollout restart deploy $DEP 2>&1
kubectl -n "$NS" rollout status deploy $DEP --timeout=300s 2>&1 | tail -3

echo "### 4) 初始化数据库选择日志"
kubectl -n "$NS" logs deploy/"$DEP" --tail=300 2>/dev/null \
  | grep -iE 'using (MySQL|PostgreSQL|SQLite|ClickHouse) as (log )?database' | head -4
echo SWITCH_DONE
