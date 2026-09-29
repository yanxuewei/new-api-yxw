#!/usr/bin/env bash
# =============================================================================
# 任务 11｜马尼拉 ECS 节点池 4×g9i.2xlarge 跨 2 可用区 + nofile 调优
#   集群: ack-newapi-mnl (ap-southeast-6)  集群 ID: cd57e40ce9a634c1698c2f5c5e09bd93c
#
#   用法:
#     bash deploy/task11_nodepool_mnl.sh --dry-run            # 只渲染 body
#     bash deploy/task11_nodepool_mnl.sh                      # 建池（默认 AUTOSCALING=0，先固定 4 台）
#     bash deploy/task11_nodepool_mnl.sh --enable-autoscaling # 再开自动伸缩 min4/max8
#     bash deploy/task11_nodepool_mnl.sh --verify             # 只读终验
#     bash deploy/task11_nodepool_mnl.sh --delete             # 删除节点池（释放 ECS）
#
#   ★ 为什么分两步（实测得出，务必保留）：
#     自动伸缩开启时**不能**设 scaling_group.desired_size/count（报
#     `InvalidDesiredSizeOrCount.NotNull`）。此时节点数完全由 ESS 决定，而实测 ACK
#     会**先备 6 台再削到 min=4**，削的时候把跨区分布削成了 3/1（违反「6a/6b 各 ≥2」）。
#     因此：① 先建**手动模式**节点池（desired_size=4）→ ESS 按 BALANCE 均匀给 2/2；
#           ② 再用 ModifyClusterNodePool 打开自动伸缩 min=4/max=8（容量不变，仅放开上限）。
#
#   ⚠️ 三处必须显式指定，否则静默跑偏（与任务 10 漏 resource_group_id 同构）：
#      1. nodepool_info.resource_group_id —— 节点池弹出的 ECS 归属资源组
#      2. scaling_group.security_group_ids —— 不填 ACK 会自建 sg- 托管组
#      3. scaling_group.image_type —— 与 user_data 的 nofile 调优耦合
#
#   ⚠️ 配额不变量：max_instances(8) × 8 vCPU = 64 = 已批 ECS vCPU 配额（顶满）
#   ⚠️ data_disks[].encrypted 是**字符串**不是布尔（传 bool 报 Unmarshal type error）
#   ⚠️ CreateClusterNodePool 的 CLI 具名参数调用必须带 `--region`，否则报
#      `InvalidAction.NotFound`（"Specified api is not found"）—— 极易误判为 API 不可用
# =============================================================================
set -uo pipefail

exec 3>&2   # fd3 = 日志通道

REGION="${REGION:-ap-southeast-6}"
CLUSTER_ID="${CLUSTER_ID:-cd57e40ce9a634c1698c2f5c5e09bd93c}"
NODEPOOL_NAME="${NODEPOOL_NAME:-np-mnl-app}"
RESOURCE_GROUP_ID="${RESOURCE_GROUP_ID:-rg-aek4nyivmmsb6iy}"   # rg-ph-mnl
SG_APP="${SG_APP:-sg-5tsil3ca5dfkqefks1g9}"                   # sg-mnl-app
VSW_APP_A="${VSW_APP_A:-vsw-5tswpyzfa8od6je95td1h}"           # 10.0.16.0/20 @6a
VSW_APP_B="${VSW_APP_B:-vsw-5tshuvvtrqm97tnwe1ddm}"           # 10.0.32.0/20 @6b
KEY_PAIR="${KEY_PAIR:-newapi-mnl}"                            # 实测已存在
INSTANCE_TYPES="${INSTANCE_TYPES:-ecs.g9i.2xlarge,ecs.g8ine.2xlarge,ecs.g9ae.2xlarge}"
IMAGE_TYPE="${IMAGE_TYPE:-AliyunLinux3ContainerOptimized}"
DESIRED="${DESIRED:-4}"          # 固定节点数（手动模式）
MIN_NODES="${MIN_NODES:-4}"      # auto_scaling.min_instances
MAX_NODES="${MAX_NODES:-8}"      # auto_scaling.max_instances
SITE_TAG="${SITE_TAG:-ph-mnl}"
MANAGED="${MANAGED:-0}"          # 1=开启节点池托管（需 ack-node-problem-detector addon）
REPO_ROOT="${REPO_ROOT:-/mnt/e/git_code/new-api-yxw}"
USERDATA_SRC="${USERDATA_SRC:-$REPO_ROOT/deploy/nodepool-userdata-nofile.sh}"
# 展示用标签（供 task24 复用同一脚本时覆盖，不影响逻辑）
TASK_LABEL="${TASK_LABEL:-任务 11｜马尼拉节点池}"
AZ_A_LABEL="${AZ_A_LABEL:-6a}"
AZ_B_LABEL="${AZ_B_LABEL:-6b}"
# 每区最少节点数（马尼拉 4 台要求每区 ≥2；新加坡常态 2 台要求每区 ≥1）
MIN_PER_ZONE="${MIN_PER_ZONE:-2}"
# 跨可用区数下限（两地均要求跨 2 区）
MIN_ZONES="${MIN_ZONES:-2}"

MODE="apply"
case "${1:-}" in
  --dry-run)            MODE="dry-run" ;;
  --verify)             MODE="verify" ;;
  --enable-autoscaling) MODE="autoscaling" ;;
  --delete)             MODE="delete" ;;
esac

TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${OUTDIR:-$REPO_ROOT/deploy/logs/task11_$TS}"
mkdir -p "$OUTDIR"

say()  { printf '%s\n' "$*" >&2; }
step() { printf '\n>>> %s\n' "$*" >&2; }
ok()   { printf '    [OK] %s\n' "$*" >&2; }
warn() { printf '    [WARN] %s\n' "$*" >&2; }
fail() { printf '    [FAIL] %s\n' "$*" >&2; }

# 只读调用：重试 5 次 + 校验 JSON（绝不吞异常 → 防"查询失败当不存在"）
# 注意：马尼拉 ess/ecs 端点偶发 timeout / connection reset，故重试次数给足
api() {
  local out="$1"; shift
  if [[ "$MODE" == "dry-run" ]]; then printf '{"_dry_run":true}\n' > "$out"; return 0; fi
  local attempt rc
  for attempt in 1 2 3 4 5; do
    "$@" > "$out" 2>&1; rc=$?
    if [[ $rc -eq 0 ]] && jq -e . "$out" >/dev/null 2>&1; then return 0; fi
    [[ $attempt -lt 5 ]] && { warn "调用失败(rc=$rc)，${attempt}/5 重试: ${out##*/}"; sleep 8; }
  done
  fail "查询最终失败：${out##*/}"; return 1
}

# 写操作：判成功不能只 grep JSON 的 "Code"（CLI 失败是文本 ErrorCode:）
write_call() {      # <out> <description> <cmd...>
  local out="$1" desc="$2"; shift 2
  if [[ "$MODE" == "dry-run" ]]; then say "    [dry-run] $desc"; return 0; fi
  "$@" > "$out" 2>&1
  if grep -qE '"code"|"Code"|ErrorCode|ERROR|InvalidParameter|MissingParameter' "$out"; then
    fail "$desc"; sed -n '1,20p' "$out" | sed 's/^/      /' >&2; return 1
  fi
  ok "$desc"
}

# 取节点池 ID
np_id() {
  api "$OUTDIR/00-pools.json" aliyun cs DescribeClusterNodePools --ClusterId "$CLUSTER_ID" || return 1
  jq -r --arg n "$NODEPOOL_NAME" '[.nodepools[]?|select(.nodepool_info.name==$n)|.nodepool_info.nodepool_id]|first // empty' \
    "$OUTDIR/00-pools.json" 2>/dev/null | tr -d '\r'
}

# 取 ESS 伸缩组 ID（ACK 命名 acs-nodePool-<nodepool_id>）
asg_id() {          # <nodepool_id>
  api "$OUTDIR/10-asg.json" aliyun ess DescribeScalingGroups --RegionId "$REGION" --PageSize 50 || return 1
  jq -r --arg n "acs-nodePool-$1" '.ScalingGroups.ScalingGroup[]?|select(.ScalingGroupName==$n)|.ScalingGroupId' \
    "$OUTDIR/10-asg.json" 2>/dev/null | tr -d '\r' | head -1
}

# 池内实例 ID：优先 ESS；ESS 端点抖动时退回 ECS（按 ACK 实例名前缀过滤）
pool_instance_ids() {   # <asg_id>
  if [[ -n "${1:-}" ]] && api "$OUTDIR/11-asginst.json" aliyun ess DescribeScalingInstances \
        --RegionId "$REGION" --ScalingGroupId "$1" --PageSize 50; then
    local ids
    ids=$(jq -r '[.ScalingInstances.ScalingInstance[]?.InstanceId]|join(",")' "$OUTDIR/11-asginst.json" 2>/dev/null | tr -d '\r')
    [[ -n "$ids" ]] && { printf '%s' "$ids"; return 0; }
  fi
  warn "ESS 实例清单不可用，退回 ECS 枚举（实例名前缀 worker-k8s-for-cs-）"
  api "$OUTDIR/11b-ecs-all.json" aliyun ecs DescribeInstances --RegionId "$REGION" --PageSize 100 || return 1
  jq -r '[.Instances.Instance[]?|select((.InstanceName//"")|startswith("worker-k8s-for-cs-"))|.InstanceId]|join(",")' \
    "$OUTDIR/11b-ecs-all.json" 2>/dev/null | tr -d '\r'
}

say "============================================================"
say " $TASK_LABEL  ·  $REGION  ·  $(date '+%F %T')  ·  mode=$MODE"
say " 集群: $CLUSTER_ID   节点池: $NODEPOOL_NAME"
say " 机型: $INSTANCE_TYPES"
say " 容量: 手动建池 desired=$DESIRED   →  再开自动伸缩 min=$MIN_NODES max=$MAX_NODES"
say " 网络: SG=$SG_APP  ·  $VSW_APP_A($AZ_A_LABEL) / $VSW_APP_B($AZ_B_LABEL)  ·  无公网 IP"
say " 镜像: $IMAGE_TYPE  ·  key_pair=$KEY_PAIR  ·  RG=$RESOURCE_GROUP_ID"
say " 证据: $OUTDIR"
say "============================================================"

# ---- 0. 定位节点池 -----------------------------------------------------------
step "0. 定位节点池"
NPID=$(np_id) || exit 1
say "    现有节点池数=$(jq -r '.nodepools|length' "$OUTDIR/00-pools.json" 2>/dev/null | tr -d '\r')  同名命中='${NPID:-无}'"

# ============================ delete =========================================
if [[ "$MODE" == "delete" ]]; then
  [[ -z "$NPID" ]] && { ok "节点池不存在，无需删除"; exit 0; }
  say ""
  warn "即将删除节点池 $NPID 及其 $DESIRED 台 ECS（本项目当前无工作负载）"
  write_call "$OUTDIR/20-delete.json" "DeleteClusterNodepool $NPID" \
    aliyun cs DeleteClusterNodepool --ClusterId "$CLUSTER_ID" --NodepoolId "$NPID" \
    --region "$REGION" --body '{"release_node":true,"drain_node":false}' || exit 1
  for i in $(seq 1 40); do
    sleep 15
    CUR=$(np_id) || true
    say "    [$i/40] 同名节点池='${CUR:-已删除}'"
    [[ -z "$CUR" ]] && { ok "节点池已删除"; break; }
  done
  exit 0
fi

# ============================ verify =========================================
if [[ "$MODE" == "verify" && -z "$NPID" ]]; then
  fail "节点池 $NODEPOOL_NAME 不存在，无可验证"; exit 1
fi

# ============================ autoscaling ====================================
if [[ "$MODE" == "autoscaling" ]]; then
  step "开启自动伸缩（ModifyClusterNodePool）"
  [[ -z "$NPID" ]] && { fail "节点池不存在"; exit 1; }
  # 手动模式下池里带着 desired_size，开自动伸缩前需一并清掉，否则可能被拒
  BODY=$(jq -nc --argjson minn "$MIN_NODES" --argjson maxn "$MAX_NODES" \
        '{auto_scaling:{enable:true,type:"cpu",min_instances:$minn,max_instances:$maxn}}')
  say "    body: $BODY"
  write_call "$OUTDIR/30-modify.json" "ModifyClusterNodePool→auto_scaling" \
    aliyun cs ModifyClusterNodePool --ClusterId "$CLUSTER_ID" --NodepoolId "$NPID" \
    --region "$REGION" --body "$BODY" || exit 1
  sleep 20
  ASG=$(asg_id "$NPID") || exit 1
  say "    ESS 伸缩组: $ASG"
  MODE="verify"   # 落到终验
fi

# ============================ dry-run ========================================
if [[ "$MODE" == "dry-run" ]]; then
  step "1. 渲染建池 body（含 base64 user_data）"
  [[ -f "$USERDATA_SRC" ]] || { fail "缺 user_data 源文件：$USERDATA_SRC"; exit 1; }
  UD_B64=$(tr -d '\r' < "$USERDATA_SRC" | base64 -w0)
  say "    user_data 源: $USERDATA_SRC  ($(wc -c < "$USERDATA_SRC" | tr -d ' ') B → b64 $(printf '%s' "$UD_B64" | wc -c | tr -d ' ') B)"
  jq -n --arg name "$NODEPOOL_NAME" --arg rg "$RESOURCE_GROUP_ID" \
     --arg vswa "$VSW_APP_A" --arg vswb "$VSW_APP_B" --arg sg "$SG_APP" \
     --arg img "$IMAGE_TYPE" --arg key "$KEY_PAIR" --arg site "$SITE_TAG" \
     --argjson types "$(printf '%s' "$INSTANCE_TYPES" | jq -R 'split(",")')" \
     --argjson desired "$DESIRED" --arg ud "$UD_B64" '
     {nodepool_info:{name:$name,type:"ess",resource_group_id:$rg},
      scaling_group:{instance_types:$types,vswitch_ids:[$vswa,$vswb],image_type:$img,
        system_disk_category:"cloud_essd",system_disk_size:100,system_disk_performance_level:"PL1",
        data_disks:[{category:"cloud_essd",size:300,performance_level:"PL1"}],
        desired_size:$desired,instance_charge_type:"PostPaid",internet_max_bandwidth_out:0,
        multi_az_policy:"BALANCE",key_pair:$key,security_group_ids:[$sg],
        tags:[{key:"site",value:$site},{key:"env",value:"prod"},{key:"track",value:"stable"}]},
      kubernetes_config:{runtime:"containerd",cpu_policy:"none",
        labels:[{key:"track",value:"stable"},{key:"site",value:$site}],user_data:$ud}}' \
     | jq 'del(.kubernetes_config.user_data)' >&3
  say "    （dry-run 结束：手动模式建池 + 之后 --enable-autoscaling 两步走）"
  exit 0
fi

# ---- 1. 建池（手动模式：固定 desired 台，保证跨区均匀） ----------------------
if [[ -z "$NPID" ]]; then
  step "1. 渲染建池 body（手动模式，desired_size=$DESIRED）"
  [[ -f "$USERDATA_SRC" ]] || { fail "缺 user_data 源文件：$USERDATA_SRC"; exit 1; }
  UD_B64=$(tr -d '\r' < "$USERDATA_SRC" | base64 -w0)
  jq -n --arg name "$NODEPOOL_NAME" --arg rg "$RESOURCE_GROUP_ID" \
     --arg vswa "$VSW_APP_A" --arg vswb "$VSW_APP_B" --arg sg "$SG_APP" \
     --arg img "$IMAGE_TYPE" --arg key "$KEY_PAIR" --arg site "$SITE_TAG" \
     --argjson types "$(printf '%s' "$INSTANCE_TYPES" | jq -R 'split(",")')" \
     --argjson desired "$DESIRED" --arg ud "$UD_B64" '
     {nodepool_info:{name:$name,type:"ess",resource_group_id:$rg},
      scaling_group:{instance_types:$types,vswitch_ids:[$vswa,$vswb],image_type:$img,
        system_disk_category:"cloud_essd",system_disk_size:100,system_disk_performance_level:"PL1",
        data_disks:[{category:"cloud_essd",size:300,performance_level:"PL1"}],
        desired_size:$desired,instance_charge_type:"PostPaid",internet_max_bandwidth_out:0,
        multi_az_policy:"BALANCE",key_pair:$key,security_group_ids:[$sg],
        tags:[{key:"site",value:$site},{key:"env",value:"prod"},{key:"track",value:"stable"}]},
      kubernetes_config:{runtime:"containerd",cpu_policy:"none",
        labels:[{key:"track",value:"stable"},{key:"site",value:$site}],user_data:$ud}}' > "$OUTDIR/nodepool-mnl.json"

  if [[ "$MANAGED" == "1" ]]; then
    jq '. + {management:{enable:true,auto_repair:true,auto_upgrade:true,
          auto_upgrade_policy:{auto_upgrade_os:false}}}' "$OUTDIR/nodepool-mnl.json" > "$OUTDIR/t.json" \
      && mv "$OUTDIR/t.json" "$OUTDIR/nodepool-mnl.json"
  fi
  jq -e . "$OUTDIR/nodepool-mnl.json" >/dev/null && ok "body JSON 合法" \
    || { fail "body JSON 不合法"; exit 1; }

  step "2. 创建节点池（单次调用，不重试）"
  write_call "$OUTDIR/01-create-node-pool.json" "CreateClusterNodePool" \
    aliyun cs CreateClusterNodePool --ClusterId "$CLUSTER_ID" --region "$REGION" \
    --body "$(cat "$OUTDIR/nodepool-mnl.json")" || exit 1
  NPID=$(jq -r '.nodepool_id // empty' "$OUTDIR/01-create-node-pool.json" 2>/dev/null | tr -d '\r')
  if [[ -z "$NPID" ]]; then
    warn "未直接取到 nodepool_id，复查是否已建（防重复创建）"
    NPID=$(np_id) || exit 1
  fi
  [[ -z "$NPID" ]] && { fail "创建失败：既无 nodepool_id 也查不到同名池"; exit 1; }
  ok "nodepool_id=$NPID"
else
  ok "复用已存在节点池 $NPID"
fi

# ---- 3. 等待节点就绪（最长 25 分钟） -----------------------------------------
step "3. 等待节点就绪（最长 25 分钟）"
ASG=$(asg_id "$NPID") || ASG=""
[[ -z "$ASG" ]] && warn "未取到 ESS 伸缩组（端点抖动），等待判定退回 ECS 实例数" || say "    ESS 伸缩组: $ASG"
READY=0
for i in $(seq 1 50); do
  api "$OUTDIR/02-detail.json" aliyun cs DescribeClusterNodePoolDetail \
      --ClusterId "$CLUSTER_ID" --NodepoolId "$NPID" || exit 1
  TOTCAP=""
  if [[ -n "$ASG" ]] && api "$OUTDIR/12-asg2.json" aliyun ess DescribeScalingGroups --RegionId "$REGION" --PageSize 50; then
    TOTCAP=$(jq -r --arg a "$ASG" '.ScalingGroups.ScalingGroup[]?|select(.ScalingGroupId==$a)|.TotalCapacity' "$OUTDIR/12-asg2.json" | tr -d '\r')
  fi
  IDS=$(pool_instance_ids "$ASG") || exit 1
  NCNT=$(printf '%s' "$IDS" | tr ',' '\n' | grep -c . || true)
  ST=$(jq -r '.status.state // "?"' "$OUTDIR/02-detail.json" | tr -d '\r')
  say "    [$i/50] pool=$ST essTotal=${TOTCAP:-n/a} essInstances=$NCNT"
  if [[ "${NCNT:-0}" == "$DESIRED" && ( -z "$TOTCAP" || "$TOTCAP" == "$DESIRED" ) ]]; then READY=1; break; fi
  case "$ST" in failed|deleting) fail "节点池状态异常：$ST"; exit 1;; esac
  sleep 30
done
[[ "$READY" == "1" ]] && ok "节点数=desired=$DESIRED（最长等待 $(printf '%s' "$((i*30))")s）" \
                      || warn "等待超时，继续终验取证"

# ---- 4. 终验 -----------------------------------------------------------------
step "4. 终验"
PASS=0; FAILN=0
chk() { if [[ "$2" == "$3" ]]; then printf '    [PASS] %s = %s\n' "$1" "$2" >&2; PASS=$((PASS+1));
        else printf '    [FAIL] %s 期望[%s] 实际[%s]\n' "$1" "$3" "$2" >&2; FAILN=$((FAILN+1)); fi; }

D="$OUTDIR/02-detail.json"
chk "节点池资源组"  "$(jq -r '.nodepool_info.resource_group_id // ""' "$D" | tr -d '\r')" "$RESOURCE_GROUP_ID"
chk "镜像类型"      "$(jq -r '.scaling_group.image_type // ""' "$D" | tr -d '\r')" "$IMAGE_TYPE"
chk "跨区策略"      "$(jq -r '.scaling_group.multi_az_policy // ""' "$D" | tr -d '\r')" "BALANCE"
chk "公网带宽(=0)"  "$(jq -r '.scaling_group.internet_max_bandwidth_out // "?"' "$D" | tr -d '\r')" "0"
chk "key_pair"      "$(jq -r '.scaling_group.key_pair // ""' "$D" | tr -d '\r')" "$KEY_PAIR"
chk "系统盘"        "$(jq -r '.scaling_group.system_disk_category // ""' "$D" | tr -d '\r')" "cloud_essd"
chk "系统盘容量"    "$(jq -r '.scaling_group.system_disk_size // 0' "$D" | tr -d '\r')" "100"
if jq -e --arg s "$SG_APP" '.scaling_group.security_group_ids|index($s)' "$D" >/dev/null 2>&1; then
  printf '    [PASS] 节点安全组 = %s（未自建托管组）\n' "$SG_APP" >&2; PASS=$((PASS+1))
else printf '    [FAIL] 节点安全组未含 %s\n' "$SG_APP" >&2; FAILN=$((FAILN+1)); fi
chk "数据盘容量"    "$(jq -r '.scaling_group.data_disks[0].size // 0' "$D" | tr -d '\r')" "300"
chk "数据盘 PL"     "$(jq -r '.scaling_group.data_disks[0].performance_level // ""' "$D" | tr -d '\r')" "PL1"
UDLEN=$(jq -r '(.kubernetes_config.user_data|length) // 0' "$D" | tr -d '\r')
[[ "${UDLEN:-0}" -gt 1000 ]] && { printf '    [PASS] user_data 已注入 (b64 %s B)\n' "$UDLEN" >&2; PASS=$((PASS+1)); } \
                             || { printf '    [FAIL] user_data 未注入 (len=%s)\n' "$UDLEN" >&2; FAILN=$((FAILN+1)); }
printf '    [info] instance_types   = %s\n' "$(jq -c '.scaling_group.instance_types' "$D" | tr -d '\r')" >&2
printf '    [info] vswitch_ids      = %s\n' "$(jq -c '.scaling_group.vswitch_ids' "$D" | tr -d '\r')" >&2
printf '    [info] auto_scaling     = %s\n' "$(jq -c '.auto_scaling' "$D" | tr -d '\r')" >&2
printf '    [info] management       = %s\n' "$(jq -c '.management' "$D" | tr -d '\r')" >&2
printf '    [info] ram_role_name    = %s\n' "$(jq -r '.scaling_group.ram_role_name // "-"' "$D" | tr -d '\r')" >&2
printf '    [info] tags             = %s\n' "$(jq -c '.scaling_group.tags' "$D" | tr -d '\r')" >&2

# 节点实况（以 ESS 实例清单为准 → ECS 补 机型/可用区/资源组）
IDS=$(pool_instance_ids "$ASG") || exit 1
NCNT=$(printf '%s' "$IDS" | tr ',' '\n' | grep -c . || true)
chk "节点数"  "${NCNT:-0}" "$DESIRED"
if [[ -n "$IDS" ]]; then
  api "$OUTDIR/04-ecs.json" aliyun ecs DescribeInstances --RegionId "$REGION" \
      --InstanceIds "[\"$(printf '%s' "$IDS" | sed 's/,/","/g')\"]" --PageSize 50 || exit 1
  jq -r '.Instances.Instance[]? | "      \(.InstanceId)  \(.InstanceType)  \(.ZoneId)  \(.Status)  RG=\(.ResourceGroupId)  公网=\(.PublicIpAddress.IpAddress[0] // "无")"' "$OUTDIR/04-ecs.json" >&3
  NZ=$(jq -r '[.Instances.Instance[]?.ZoneId]|unique|length' "$OUTDIR/04-ecs.json" | tr -d '\r')
  ZG=$(jq -r '[.Instances.Instance[]?.ZoneId]|group_by(.)|map("\(.[0]):\(length)")|join(" ")' "$OUTDIR/04-ecs.json" | tr -d '\r')
  MINPER=$(jq -r '[.Instances.Instance[]?.ZoneId]|group_by(.)|map(length)|min // 0' "$OUTDIR/04-ecs.json" | tr -d '\r')
  printf '    [info] 实配机型       = %s\n' "$(jq -r '[.Instances.Instance[]?.InstanceType]|unique|join(",")' "$OUTDIR/04-ecs.json" | tr -d '\r')" >&2
  printf '    [info] 可用区分布     = %s\n' "$ZG" >&2
  chk "跨可用区数"  "${NZ:-0}" "$MIN_ZONES"
  if [[ "${MINPER:-0}" -ge "$MIN_PER_ZONE" ]]; then printf '    [PASS] 每区节点数 ≥%s\n' "$MIN_PER_ZONE" >&2; PASS=$((PASS+1));
  else printf '    [FAIL] 有可用区节点数 <%s（当前 %s）\n' "$MIN_PER_ZONE" "$ZG" >&2; FAILN=$((FAILN+1)); fi
  RGOK=$(jq -r --arg rg "$RESOURCE_GROUP_ID" '[.Instances.Instance[]?|select(.ResourceGroupId==$rg)]|length' "$OUTDIR/04-ecs.json" | tr -d '\r')
  chk "ECS 在目标 RG 数"  "${RGOK:-0}" "${NCNT:-0}"
  PUB=$(jq -r '[.Instances.Instance[]?|select((.PublicIpAddress.IpAddress//[])|length>0)]|length' "$OUTDIR/04-ecs.json" | tr -d '\r')
  chk "持有公网 IP 的节点数"  "${PUB:-0}" "0"
  # 数据盘
  api "$OUTDIR/05-disks.json" aliyun ecs DescribeDisks --RegionId "$REGION" \
      --InstanceId "$(printf '%s' "$IDS" | cut -d, -f1)" || exit 1
  jq -r '.Disks.Disk[]? | "      \(.DiskId)  \(.Type)  \(.Size)G  \(.Category)  \(.Status)  dev=\(.Device // "-")"' "$OUTDIR/05-disks.json" >&3
fi

# ESS 组核对（端点抖动时降级为 info）
ASGMIN=""; ASGMAX=""; ASGMZ=""
if [[ -n "$ASG" ]] && api "$OUTDIR/13-asg3.json" aliyun ess DescribeScalingGroups --RegionId "$REGION" --PageSize 50; then
  jq -r --arg a "$ASG" '.ScalingGroups.ScalingGroup[]?|select(.ScalingGroupId==$a)|{ScalingGroupId,MinSize,MaxSize,DesiredCapacity,TotalCapacity,MultiAZPolicy,HealthCheckType,GroupDeletionProtection}' "$OUTDIR/13-asg3.json" >&3
  ASGMIN=$(jq -r --arg a "$ASG" '.ScalingGroups.ScalingGroup[]?|select(.ScalingGroupId==$a)|.MinSize' "$OUTDIR/13-asg3.json" | tr -d '\r')
  ASGMAX=$(jq -r --arg a "$ASG" '.ScalingGroups.ScalingGroup[]?|select(.ScalingGroupId==$a)|.MaxSize' "$OUTDIR/13-asg3.json" | tr -d '\r')
  ASGMZ=$(jq -r --arg a "$ASG" '.ScalingGroups.ScalingGroup[]?|select(.ScalingGroupId==$a)|.MultiAZPolicy' "$OUTDIR/13-asg3.json" | tr -d '\r')
  say "    ESS: min=$ASGMIN max=$ASGMAX multiAZ=$ASGMZ"
  chk "ESS MultiAZPolicy"  "$ASGMZ" "BALANCE"
  if [[ "$MODE" == "autoscaling" || "${EXPECT_AS:-0}" == "1" ]]; then
    chk "ESS MinSize"  "$ASGMIN" "$MIN_NODES"
    chk "ESS MaxSize"  "$ASGMAX" "$MAX_NODES"
  fi
else
  warn "ESS 伸缩组不可读，跳过 ESS 断言（不视为失败）"
fi

# vSwitch 余量
for vs in "$VSW_APP_A" "$VSW_APP_B"; do
  api "$OUTDIR/06-vsw-$vs.json" aliyun vpc DescribeVSwitchAttributes --VSwitchId "$vs" --RegionId "$REGION" || true
  say "    vSwitch $vs free=$(jq -r '.AvailableIpAddressCount // "?"' "$OUTDIR/06-vsw-$vs.json" | tr -d '\r')"
done

# 配额占用
api "$OUTDIR/07-quota.json" aliyun quotas ListProductQuotas --ProductCode ecs-spec \
    --QuotaCategory CommonQuota --Dimensions.1.Key regionId --Dimensions.1.Value "$REGION" || true
QC=$(jq -r '.Quotas[]?|select(.QuotaActionCode=="q_ecs_enterprise_postpay_c")|.TotalQuota' "$OUTDIR/07-quota.json" | tr -d '\r')
say "    vCPU 配额=$QC   已用=$(( NCNT * 8 ))   上限节点=$(( ${QC:-0} / 8 ))"

say ""
say "===== 终验汇总: PASS=$PASS  FAIL=$FAILN ====="
say ""
say "============================================================"
say " nodepool_id : $NPID"
say " ESS 伸缩组  : $ASG"
say " 证据目录    : $OUTDIR"
say " 提示        : 私网端点 → kubectl / ulimit 落地核查需 VPC 内（任务 46 堡垒机）"
say "============================================================"
[[ "$FAILN" -eq 0 ]]
