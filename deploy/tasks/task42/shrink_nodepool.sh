#!/usr/bin/env bash
# ============================================================================
# 任务 42 追加｜节点池「显式缩容」（马尼拉 / 新加坡）
# ----------------------------------------------------------------------------
# 背景（2026-10-14 实测，详见 REFERENCE「节点缩容机制」节）：
#   ACK GOATScaler 的 kube-system/autoscaler-meta 配置里
#     skip_nodes_with_system_pods = true
#   而两集群**每一台**节点都载有 kube-system 的**非 DaemonSet** Pod
#   （mnl: .194 载 13 个 + logtail-statefulset；.195 载 2；.200 载 1；.201 载 4）
#   ⇒ 所有节点都被排除在缩容候选之外 ⇒ **自动缩容结构性不会发生**。
#   事件 `ScaleDownLimited: blocked by nodepool minsize limit` 只是最后一层；
#   即便 min 放开，节点仍会因系统 Pod 被 skip。
#
#   因此：要真正把节点数降到目标值，只能**显式**调用 RemoveNodePoolNodes。
#   `ScaleClusterNodePool` 只支持**扩容**（count 只能加），不能用于缩容。
#
# usage:
#   bash shrink_nodepool.sh <mnl|sg> [--target N] [--keep i-x,i-y] [--apply]
#     · 默认 dry-run：只打印计划，**不做任何变更**
#     · --apply     ：真正执行（逐台串行 + 轮询释放）
#     · --target N  ：目标台数（默认 mnl=2 / sg=1）
#     · --keep      ：强制保留的实例 ID（逗号分隔）；不给则按可用区均衡自动挑
#
# 幂等：当前台数 <= target 时直接退出 0。
#
# ⚠ 前置（本脚本**不**代劳，需先人工确认）：
#   1) 目标台数 >= ACK auto_scaling.min_instances（否则会立刻被补回）
#   2) 目标态下的 Pod 能装下（用 ack_remote.sh 跑 requests 汇总；见文件末尾清单）
#   3) sg 缩到 1 台前，必须先把 new-api-ph-standby 副本降到 1（否则请求超额）
# ============================================================================
set -euo pipefail

SITE="${1:?usage: shrink_nodepool.sh <mnl|sg> [--target N] [--keep i-a,i-b] [--apply]}"
shift || true
TARGET=""; KEEP=""; APPLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="${2:-}"; shift 2 ;;
    --keep)   KEEP="${2:-}";   shift 2 ;;
    --apply)  APPLY=1; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "[!] 未知参数：${1}" >&2; exit 2 ;;
  esac
done

case "$SITE" in
  mnl) REGION=ap-southeast-6; CID=cd57e40ce9a634c1698c2f5c5e09bd93c
       NPID=npaad418131aa84c899be022b5463d13bf; ASG=asg-5tsd68ew4u0wutaqk5cy; DEF=2 ;;
  sg)  REGION=ap-southeast-1; CID=ca75829e3492d491d9d434de087913798
       NPID=npab9d46aefe3a4649b074543f36f32599; ASG=asg-t4ngzbg7m9u84y59dkxl; DEF=1 ;;
  *) echo "[!] site 必须是 mnl|sg" >&2; exit 2 ;;
esac
TARGET="${TARGET:-$DEF}"

log(){ printf '%s\n' "$*" >&2; }
J(){ python3 -c "import sys,json;d=json.load(sys.stdin);print(d$1)" 2>/dev/null; }

log "[i] site=${SITE} region=${REGION} nodepool=${NPID} target=${TARGET} apply=${APPLY}"

# ---- 1) 读节点池 / 伸缩组现状 ------------------------------------------------
NP_JSON=$(aliyun cs DescribeClusterNodePoolDetail --ClusterId "$CID" --NodepoolId "$NPID" --region "$REGION" 2>&1 | tr -d '\r') || true
MIN=$(printf '%s' "$NP_JSON" | J "['auto_scaling']['min_instances']") || true
MAX=$(printf '%s' "$NP_JSON" | J "['auto_scaling']['max_instances']") || true
ESG=$(aliyun ess DescribeScalingGroups --RegionId "$REGION" --ScalingGroupId.1 "$ASG" 2>&1 | tr -d '\r') || true
ESS_MIN=$(printf '%s' "$ESG" | J "['ScalingGroups']['ScalingGroup'][0]['MinSize']") || true
ESS_TOTAL=$(printf '%s' "$ESG" | J "['ScalingGroups']['ScalingGroup'][0]['TotalCapacity']") || true
log "[i] ACK auto_scaling: min=${MIN} max=${MAX} ｜ ESS MinSize=${ESS_MIN} TotalCapacity=${ESS_TOTAL}"

if [[ -z "${MIN:-}" || -z "${ESS_MIN:-}" ]]; then log "[!] 读取节点池/伸缩组失败，终止"; exit 1; fi
if (( TARGET < 1 )); then log "[!] target 至少为 1"; exit 1; fi
if (( TARGET < MIN )); then log "[!] target(${TARGET}) < ACK min_instances(${MIN})，会被自动补回。请先下调 min 或改 target。"; exit 1; fi
if (( TARGET < ESS_MIN )); then log "[!] target(${TARGET}) < ESS MinSize(${ESS_MIN})，会被 ESS 补回。请先下调。"; exit 1; fi

# ---- 2) 实例清单 + 可用区 ----------------------------------------------------
IDS=$(aliyun ess DescribeScalingInstances --RegionId "$REGION" --ScalingGroupId "$ASG" --PageSize 100 2>&1 | tr -d '\r' \
      | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(','.join(i['InstanceId'] for i in (d.get('ScalingInstances') or {}).get('ScalingInstance') or []))" 2>/dev/null) || IDS=""
if [[ -z "${IDS:-}" ]]; then log "[!] 未取到伸缩组实例列表（端点抖动？重试）"; exit 1; fi
IDJSON=$(printf '%s' "$IDS" | python3 -c "import sys;print('[\"%s\"]' % '\",\"'.join(sys.stdin.read().strip().split(',')))") || true
# ⚠ ap-southeast-6 的 ecs 端点偶发抖动（项目已知）⇒ 重试 3 次
ZJSON=""
for _t in 1 2 3; do
  ZJSON=$(aliyun ecs DescribeInstances --RegionId "$REGION" --InstanceIds "$IDJSON" --PageSize 100 2>&1 | tr -d '\r') || ZJSON=""
  printf '%s' "$ZJSON" | grep -q '"Instances"' && break
  log "[i] ecs DescribeInstances 第 ${_t} 次失败，重试…"
  sleep 6; ZJSON=""
done
if [[ -z "${ZJSON:-}" ]]; then log "[!] 未取到实例可用区信息，终止"; exit 1; fi

# ---- 3) 规划保留 / 移除 ------------------------------------------------------
PLAN=$(ZJSON="$ZJSON" KEEP="$KEEP" TARGET="$TARGET" python3 - <<'PY'
import os, json
d = json.loads(os.environ['ZJSON'])
inst = (d.get('Instances') or {}).get('Instance') or []
recs = [{'id': i['InstanceId'], 'zone': i.get('ZoneId','?')} for i in inst]
recs.sort(key=lambda r: (r['zone'], r['id']))
keep_pref = [x for x in os.environ.get('KEEP','').split(',') if x]
target = int(os.environ['TARGET'])
if keep_pref:
    keep = [r for r in recs if r['id'] in keep_pref]
    if len(keep) > target:
        keep = keep[:target]
elif len(recs) <= target:
    keep = recs
else:
    # 按可用区均衡：以 (该区数量, 区名) 升序轮转取席
    zones = {}
    for r in recs: zones.setdefault(r['zone'], []).append(r)
    for z in zones: zones[z].sort(key=lambda r: r['id'])
    keep = []
    order = sorted(zones, key=lambda z: (len(zones[z]), z))
    while len(keep) < target:
        moved = False
        for z in order:
            if len(keep) >= target: break
            if zones[z]:
                keep.append(zones[z].pop(0)); moved = True
        if not moved: break
keep_ids = {r['id'] for r in keep}
remove = [r for r in recs if r['id'] not in keep_ids]
zc = {}
for r in keep: zc[r['zone']] = zc.get(r['zone'],0)+1
rm = ','.join(r['id'] for r in remove)
kp = ','.join('%s(%s)' % (r['id'], r['zone']) for r in keep)
print('KEEP=%s' % kp)
print('REMOVE=%s' % (' '.join('%s(%s)' % (r['id'], r['zone']) for r in remove) or '(无)'))
print('KEEP_ZONES=%s' % json.dumps(zc, sort_keys=True))
print('REMOVE_IDS=%s' % rm)
PY
) || PLAN=""
printf '%s\n' "$PLAN" >&2

if [[ -z "${PLAN:-}" ]]; then log "[!] 规划失败（未产出计划），终止 —— 请检查 ecs/ess 端点连通性"; exit 1; fi
REMOVE_IDS=$(printf '%s' "$PLAN" | sed -n 's/^REMOVE_IDS=//p')
if [[ -z "${REMOVE_IDS:-}" ]]; then log "[i] 已在目标台数(${TARGET})，无需操作（幂等退出）"; exit 0; fi

log ""
log "=== 计划（dry-run 到此为止） ==="
N_REM=$(printf '%s\n' "$REMOVE_IDS" | tr ',' '\n' | grep -c . || true)
log "  将移除 ${N_REM} 台 ⇒ 剩余 ${TARGET} 台"
log "  移除方式：cs RemoveNodePoolNodes（drain_node=true · release_node=true · concurrency=false）"

if (( APPLY == 0 )); then
  log "[i] 未加 --apply，未做任何变更。"
  exit 0
fi

# ---- 4) 逐台移除 + 轮询 -------------------------------------------------------
IFS=',' read -r -a ARR <<< "$REMOVE_IDS"
for id in "${ARR[@]}"; do
  log ""
  log "--- [$SITE] 移除 ${id} （drain + release） ---"
  BODY=$(printf '["%s"]' "$id")
  OUT=$(aliyun cs RemoveNodePoolNodes --ClusterId "$CID" --NodepoolId "$NPID" --region "$REGION" \
        --instance_ids "$BODY" --release_node true --drain_node true --concurrency false 2>&1 | tr -d '\r') || true
  log "[i] API 返回：$(printf '%s' "$OUT" | head -c 300)"
  case "$OUT" in
    *'"task_id"'*|*task_id*) : ;;
    *) log "[!] 未拿到 task_id，可能失败 —— 先停下来人工确认，不继续下一台"; exit 1 ;;
  esac
  for i in $(seq 1 60); do
    sleep 10
    LEFT=$(aliyun ess DescribeScalingInstances --RegionId "$REGION" --ScalingGroupId "$ASG" --PageSize 100 2>/dev/null | tr -d '\r' \
           | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print('?'); raise SystemExit
ids=[i['InstanceId'] for i in (d.get('ScalingInstances') or {}).get('ScalingInstance') or []]
print('YES' if '$id' in ids else 'NO')" 2>/dev/null)
    log "    第 ${i} 轮：实例是否仍在伸缩组 = ${LEFT}"
    [[ "$LEFT" == "NO" ]] && break
  done
done

# ---- 5) 终态 ----------------------------------------------------------------
log ""
log "=== 终态 ==="
aliyun ess DescribeScalingGroups --RegionId "$REGION" --ScalingGroupId.1 "$ASG" \
  --cli-query 'ScalingGroups.ScalingGroup[].{total:TotalCapacity,min:MinSize,max:MaxSize}' 2>&1 | tr -d '\r' >&2
log "[i] 集群内复核（请另行执行）："
log "    bash deploy/lib/ack_remote.sh ${SITE} deploy/logs/t_shrink_k8s.sh"
