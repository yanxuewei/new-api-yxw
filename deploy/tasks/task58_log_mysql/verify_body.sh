#!/bin/bash
# __TITLE__ — 应用日志核验：DB 选择行 + DB 报错扫描（ack_remote body）
set -uo pipefail
export KUBECONFIG="${K8S:-/tmp/k8s/kubeconfig}"
NS=new-api
DEP="__DEPLOY__"
for d in $DEP; do
  P=$(kubectl -n "$NS" get pod -l app="$d" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -z "$P" ] && P=$(kubectl -n "$NS" get pods -o name 2>/dev/null | grep "$d" | head -1 | cut -d/ -f2)
  [ -z "$P" ] && { echo "$d: no pod"; continue; }
  echo "== $d ($P)"
  kubectl -n "$NS" logs "$P" 2>/dev/null | grep -iE 'using .*(database)|log database' | head -3
  kubectl -n "$NS" logs "$P" 2>/dev/null | grep -icE 'mysql.*(error|refused|denied)|(error|refused|denied).*mysql|dial tcp.*(3306|9000)|failed to (query|record|save).*(log|LOG_DB)' | sed 's/^/db_err_lines=/'
done
echo VERIFY_DONE
