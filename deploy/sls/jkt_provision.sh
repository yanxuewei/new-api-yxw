#!/usr/bin/env bash
# jkt dev 集群 SLS 业务日志库开通（logstore + 索引，幂等）
#
# 背景：ack-newapi-jkt-dev 的容器日志落 **ACK 自管 project** `k8s-log-<cid>`（与 mnl/sg 同机制，
#       由 loongcollector 附加组件绑定）——该 project 建集群时已存在，但只有 `audit-<cid>` / `k8s-event`
#       两个系统库，缺 app-stdout / app-file ⇒ 本脚本补齐（参数**照抄马尼拉实测值**）。
#
# 用法：
#   bash deploy/sls/jkt_provision.sh check            # 只读：现状
#   bash deploy/sls/jkt_provision.sh plan             # 默认：打印将执行的动作（不写）
#   EXEC_MODE=apply bash deploy/sls/jkt_provision.sh apply
#
# 照抄来源（马尼拉 k8s-log-cd57e40ce9a634c1698c2f5c5e09bd93c 实测）：
#   app-stdout → ttl=180 shardCount=2 autoSplit=true maxSplitShard=32 appendMeta=true mode=standard
#   app-file   → ttl=30  shardCount=2 autoSplit=true maxSplitShard=64 appendMeta=false mode=standard
#   索引（index_mode=v2）：app-stdout 17 个字段键 + 全文；app-file 纯全文（keys={}）
#   ⇒ 索引 body **直接从马尼拉 GetIndex 取回后裁剪**，避免手抄漂移。
set -uo pipefail

JP="k8s-log-cb0abf5bc06034f7bbdb991752f6f3e62"   # jkt（建集群时由 log controller 创建，RG=rg-nonprod）
JR="ap-southeast-5"
MP="k8s-log-cd57e40ce9a634c1698c2f5c5e09bd93c"   # 马尼拉参照
MR="ap-southeast-6"

EXEC_MODE="${EXEC_MODE:-plan}"
ALIYUN="${ALIYUN:-aliyun}"
PY="${PY:-python3}"

say() { printf '%s\n' "$*" >&2; }

ls_exists() { # $1=logstore
  "$ALIYUN" sls ListLogStores --project "$JP" --region "$JR" 2>/dev/null \
    | "$PY" -c 'import sys,json;d=json.load(sys.stdin);print("1" if sys.argv[1] in (d.get("logstores") or []) else "0")' "$1"
}

store_body() { # $1=logstore $2=ttl $3=maxSplitShard $4=appendMeta
  printf '{"logstoreName":"%s","ttl":%s,"shardCount":2,"mode":"standard","autoSplit":true,"maxSplitShard":%s,"appendMeta":%s}' \
    "$1" "$2" "$3" "$4"
}

# 取马尼拉索引 → 裁剪为可创建 body（去掉回读字段，ttl 按 jkt 目标）
index_body() { # $1=mnl logstore $2=jkt ttl
  MP="$MP" MR="$MR" LS="$1" TTL="$2" "$PY" - <<'PYEOF'
import json, os, subprocess
ls, ttl = os.environ["LS"], int(os.environ["TTL"])
raw = subprocess.run(["aliyun","sls","GetIndex","--project",os.environ["MP"],
                      "--logstore",ls,"--region",os.environ["MR"]],
                     capture_output=True, text=True).stdout
d = json.loads(raw)
idx = d.get("index", d)
body = {"index_mode": idx.get("index_mode", "v2"), "ttl": ttl,
        "keys": idx.get("keys") or {}, "line": idx.get("line") or {}}
print(json.dumps(body, ensure_ascii=False))
PYEOF
}

check() {
  say "== jkt $JP @ $JR =="
  "$ALIYUN" sls ListLogStores --project "$JP" --region "$JR" 2>/dev/null | head -20
  for ls in app-stdout app-file; do
    t=$("$ALIYUN" sls GetIndex --project "$JP" --logstore "$ls" --region "$JR" 2>/dev/null \
        | "$PY" -c 'import sys,json
try:
    d=json.load(sys.stdin); i=d.get("index",d); print("ttl=%s keys=%d" % (i.get("ttl"), len(i.get("keys") or {})))
except Exception: print("(无索引)")' 2>/dev/null)
    printf '  %-12s index: %s\n' "$ls" "$t"
  done
  say "== CR 侧（集群内另查） =="
}

run() {
  say "== EXEC_MODE=$EXEC_MODE @ $(date '+%F %T') =="
  for spec in "app-stdout:180:32:true" "app-file:30:64:false"; do
    IFS=':' read -r LS TTL MSS AM <<<"$spec"
    if [ "$(ls_exists "$LS")" = "1" ]; then
      say "[skip] logstore $LS 已存在"
    else
      body=$(store_body "$LS" "$TTL" "$MSS" "$AM")
      say "[$EXEC_MODE] CreateLogStore $LS :: $body"
      if [ "$EXEC_MODE" = "apply" ]; then
        "$ALIYUN" sls CreateLogStore --project "$JP" --region "$JR" --body "$body" 2>&1 | head -c 300; echo
        sleep 3
      fi
    fi
    b=$(index_body "$LS" "$TTL")
    say "[$EXEC_MODE] CreateIndex $LS（keys=$(printf '%s' "$b" | "$PY" -c 'import sys,json;print(len(json.load(sys.stdin)["keys"]))') ）"
    if [ "$EXEC_MODE" = "apply" ]; then
      "$ALIYUN" sls CreateIndex --project "$JP" --logstore "$LS" --region "$JR" \
        --header "Content-Type=application/json" --body "$b" 2>&1 | head -c 300; echo
    fi
  done
  if [ "$EXEC_MODE" = "apply" ]; then
    say ""
    say "== 回读 =="; check
  fi
}

case "${1:-plan}" in
  check) check ;;
  plan|apply) EXEC_MODE=${EXEC_MODE:-$1}; [ "$1" = apply ] && EXEC_MODE=apply; run ;;
  *) say "用法: $0 [check|plan|apply|EXEC_MODE=apply $0 apply]"; exit 2 ;;
esac
