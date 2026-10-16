#!/bin/bash
# bodies/inspect_ck_gone.sh —— 马尼拉正式环境**只读**取证：CK 被删之后应用侧的真实状态
# 不 apply、不 delete、不 rollout、不 exec 写操作；只 get / describe / logs（值一律打码）
NS="${NS:-new-api}"
echo "=== C1 正式集群里与 CK 有关的配置键（只看键名与主机名，DSN 口令永不外泄）"
kubectl -n "$NS" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>&1 | sed 's/^/    /'
kubectl -n "$NS" get cm,secret -o name 2>&1 | sed 's/^/    /'
for d in $(kubectl -n "$NS" get deploy -o name 2>/dev/null); do
  echo "  [$d]"
  kubectl -n "$NS" get "$d" -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}' 2>/dev/null \
    | grep -iE "clickhouse|log_sql|logs_" | sed 's/^/    env键 /'
  kubectl -n "$NS" get "$d" -o jsonpath='{range .spec.template.spec.containers[0].envFrom[*]}{.configMapRef.name}{.secretRef.name}{"\n"}{end}' 2>/dev/null \
    | sed 's/^/    envFrom /'
done

echo "=== C2 ConfigMap 里的 CK 开关与主机（只回显开关值与主机名，不含账号口令）"
for c in $(kubectl -n "$NS" get cm -o name 2>/dev/null); do
  kubectl -n "$NS" get "$c" -o jsonpath='{.data}' 2>/dev/null \
    | python3 -c '
import sys,json,re
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for k,v in (d or {}).items():
    if re.search(r"CLICKHOUSE|LOG_SQL", k, re.I):
        s=str(v)
        s=re.sub(r"://([^:/]+):[^@]*@", r"://\1:***@", s)
        s=re.sub(r"(password=)[^& ]*", r"\1***", s)
        print("    %-34s %s" % (k, s[:120]))
' 2>/dev/null
done

echo "=== C3 应用日志里的 CK 连接失败计数（近 800 行，只出计数与打码样本）"
for p in $(kubectl -n "$NS" get pod -o name 2>/dev/null | head -4); do
  raw=$(kubectl -n "$NS" logs "$p" --tail=800 --timestamps 2>&1)
  n_ck=$(printf '%s' "$raw" | grep -ciE "clickhouse" )
  n_dial=$(printf '%s' "$raw" | grep -ciE "dial tcp|connect: connection refused|cannot connect|code: 210|code: 81" )
  n_err=$(printf '%s' "$raw" | grep -ciE '\[ERROR\]|level=error' )
  printf '    %-52s clickhouse行=%s 连接失败行=%s error行=%s\n' "$p" "$n_ck" "$n_dial" "$n_err"
  printf '%s' "$raw" | grep -iE "clickhouse|dial tcp|code: 210|code: 81" | tail -3 \
    | sed -E 's#://([^:/]+):[^@]*@#://\1:***@#g; s/(password=)[^ &]*/\1***/g' | sed 's/^/        /' | cut -c1-200
done

echo "=== C4 Pod 状态与重启计数（CK 消失若打崩写入，会体现在这里）"
kubectl -n "$NS" get pod -o wide 2>&1 | sed 's/^/    /'
kubectl -n "$NS" get pod -o jsonpath='{range .items[*]}{.metadata.name}{" ready="}{range .status.containerStatuses[*]}{.ready}{end}{" restarts="}{range .status.containerStatuses[*]}{.restartCount}{end}{" age="}{.metadata.creationTimestamp}{"\n"}{end}' 2>&1 | sed 's/^/    /'

echo "=== C5 节点内对旧 CK 端点的连通性（域名已随实例删除 ⇒ 期望解析失败；只读探测）"
OLDHOST="cc-5tsv2o51s1360b0pr.clickhouse.ads.aliyuncs.com"
python3 - "$OLDHOST" <<'PY' 2>&1 | sed 's/^/    /'
import socket,sys
h=sys.argv[1]
try:
    print("getaddrinfo(%s) => %s" % (h, socket.getaddrinfo(h, None)[0][4][0]))
except Exception as e:
    print("getaddrinfo(%s) => 失败：%s" % (h, e))
PY

echo "--- C1–C5 结束（本次调用零写入）"
