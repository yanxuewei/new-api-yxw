#!/usr/bin/env bash
# task17/bline_align.sh — 任务 17「B 线（承认降级）」收口写操作
#
# 裁定（2026-10-05 项目负责人）：**全线不使用 KMS / 凭据管家**（成本），密钥一律走手工 Opaque Secret。
# 期望态（两地同构）：
#   SQL_MAX_OPEN_CONNS=100（裁定①，现为 150）· SQL_MAX_IDLE_CONNS=50（sg 缺）
#   删除空转配置 LOG_SQL_MAX_OPEN_CONNS（代码 0 读取点）· SESSION_MAX_AGE（会话时长由 DB expiresAt
#     推导，见 service/auth_session.go:315）
#   SA new-api-app 摘掉 pod-identity role-name 注解（sg 现在指向不存在的角色 new-api-rrsa-kms-sg）
# mnl 侧改完 ConfigMap 必须 rollout restart（卡片坑 7：env 只在启动时注入）。
# JSON Patch 按现值生成 ⇒ 幂等可复跑（已符合期望则不下发 patch）。
#
# usage: task17/bline_align.sh [--check|--apply]
set -uo pipefail
MODE="${1:---check}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOGDIR="$HERE/../logs/task17_bline_$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGDIR"

readonly_block() {
  cat <<'EOS'
NS=new-api
echo "== CM 现值 =="
kubectl -n $NS get cm new-api-config -o json 2>/dev/null | python3 -c "
import json,sys
for k,v in sorted(json.load(sys.stdin).get('data',{}).items()): print('  %-30s= %s' % (k,v))
"
echo "== SA role-name 注解 =="
printf '  [%s]\n' "$(kubectl -n $NS get sa new-api-app -o jsonpath='{.metadata.annotations.pod-identity\.alibabacloud\.com/role-name}' 2>/dev/null)"
EOS
}

write_block() { # $1=site
  cat <<'EOS'
NS=new-api
PATCH=$(kubectl -n $NS get cm new-api-config -o json | python3 -c "
import json,sys
data=json.load(sys.stdin).get('data',{})
want={'SQL_MAX_OPEN_CONNS':'100','SQL_MAX_IDLE_CONNS':'50'}
drop=['LOG_SQL_MAX_OPEN_CONNS','SESSION_MAX_AGE']
ops=[]
for k,v in want.items():
    if k not in data: ops.append({'op':'add','path':'/data/'+k,'value':v})
    elif data[k]!=v:  ops.append({'op':'replace','path':'/data/'+k,'value':v})
for k in drop:
    if k in data: ops.append({'op':'remove','path':'/data/'+k})
print(json.dumps(ops) if ops else '[]')
")
echo "待下发 ops: $PATCH"
if [ "$PATCH" = "[]" ]; then echo "  [OK] ConfigMap 已符合期望，跳过 patch"; else
  kubectl -n $NS patch cm new-api-config --type json -p "$PATCH"
fi
kubectl -n $NS annotate sa new-api-app pod-identity.alibabacloud.com/role-name- 2>/dev/null \
  || echo "  [OK] SA 无 role-name 注解，跳过"
EOS
  if [ "$1" = "mnl" ]; then
    cat <<'EOS'
echo "== rollout restart（ConfigMap 变更需重启才生效）=="
kubectl -n new-api rollout restart deploy/new-api-master
kubectl -n new-api rollout status deploy/new-api-master --timeout=300s
EOS
  fi
}

verify_block() {
  cat <<'EOS'
NS=new-api
echo "== AFTER CM =="
kubectl -n $NS get cm new-api-config -o json 2>/dev/null | python3 -c "
import json,sys
for k,v in sorted(json.load(sys.stdin).get('data',{}).items()): print('  %-30s= %s' % (k,v))
"
echo "== AFTER SA role-name 注解（期望空）=="
printf '  [%s]\n' "$(kubectl -n $NS get sa new-api-app -o jsonpath='{.metadata.annotations.pod-identity\.alibabacloud\.com/role-name}' 2>/dev/null)"
echo "== 工作负载 =="
kubectl -n $NS get deploy,pods --no-headers 2>/dev/null | head -8
echo "== Pod 内实际生效值 =="
P=$(kubectl -n $NS get pods -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "${P:-}" ]; then
  for k in SQL_MAX_OPEN_CONNS SQL_MAX_IDLE_CONNS LOG_SQL_MAX_OPEN_CONNS SESSION_MAX_AGE NODE_TYPE; do
    printf '  %-24s= %s\n' "$k" "$(kubectl -n $NS exec "$P" -- printenv $k 2>/dev/null)"
  done
else
  echo "  (无 Pod，跳过 env 校验)"
fi
echo DONE-BLINE
EOS
}

for site in mnl sg; do
  b="/tmp/t17_bline_${site}.sh"
  { readonly_block; [ "$MODE" = "--apply" ] && write_block "$site"; verify_block; } > "$b"
  chmod 600 "$b"
  tag=$([ "$MODE" = "--apply" ] && echo apply || echo check)
  echo "########## $site （$MODE） ##########"
  bash "$HERE/../ack_remote.sh" "$site" "$b" > "$LOGDIR/${site}_${tag}.out" 2>&1
  sed -n '/BODY START/,$p' "$LOGDIR/${site}_${tag}.out"
  grep -qiE 'error|forbidden|panic|exit code' "$LOGDIR/${site}_${tag}.out" \
    && echo "  [!!] $site 输出含错误关键字，详见 $LOGDIR/${site}_${tag}.out"
  rm -f "$b"
done
echo "[i] 日志：$LOGDIR"
