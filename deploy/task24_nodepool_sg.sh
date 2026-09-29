#!/usr/bin/env bash
# =============================================================================
# 任务 24｜新加坡备站节点池 np-sg-ph-standby（常态 2 节点 / 自动伸缩 2–12）
#
#   只做参数绑定，实际逻辑**复用任务 11 的同一份脚本**（task11_nodepool_mnl.sh）——
#   符合方案要求「user_data 与任务 11 Step 3 完全同一份脚本（禁止手工点两遍）」。
#
#   用法（与 task11 完全一致）：
#     bash deploy/task24_nodepool_sg.sh --dry-run
#     bash deploy/task24_nodepool_sg.sh                  # 手动模式建池 desired=2
#     bash deploy/task24_nodepool_sg.sh --enable-autoscaling   # 再开伸缩 min2/max12
#     bash deploy/task24_nodepool_sg.sh --verify
#     bash deploy/task24_nodepool_sg.sh --delete
#
#   ⚠️ 与马尼拉的差异（实测）：
#     · `ecs.g9i.2xlarge` 在 ap-southeast-1b **不在售**（1a 有）→ 跨区必然混机型，
#       候选池保持 [g9i, g8ine, g9ae]，ESS 按 zone 可用性自动回落，**勿硬编码机型分布**。
#     · 密钥对 `newapi-sg`（导入 fanyan 的 id_ed25519 公钥；马尼拉的 newapi-mnl 取不到公钥体）。
#     · 常态 2 台（马尼拉 4 台），autoscaling max=12（马尼拉 8）。
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"

export REGION="${REGION:-ap-southeast-1}"
export CLUSTER_ID="${CLUSTER_ID:-ca75829e3492d491d9d434de087913798}"   # ack-newapi-sg
export NODEPOOL_NAME="${NODEPOOL_NAME:-np-sg-ph-standby}"
export RESOURCE_GROUP_ID="${RESOURCE_GROUP_ID:-rg-aek4zvb3ldoiyua}"     # rg-sg
export SG_APP="${SG_APP:-sg-t4n0qnhy8mxq9g733r67}"                      # sg-sg-app
export VSW_APP_A="${VSW_APP_A:-vsw-t4nbvsnvo4z52sumr9sck}"              # vsw-sg-app-a 1a 10.1.16.0/20
export VSW_APP_B="${VSW_APP_B:-vsw-t4n3dthz1ma6tp7bqor6h}"              # vsw-sg-app-b 1b 10.1.32.0/20
export KEY_PAIR="${KEY_PAIR:-newapi-sg}"
# ⚠️ 机型顺序**必须**把「两区都在售」的排在首位，否则跨区必然失衡（2026-09-29 实测）：
#    1a 有 g9i/g8ine/g9ae；**1b 没有 g9i**。ESS 按 instance_types 优先级选型后再选可用区，
#    首位机型只存在于 1a 时 → 全部实例落在 1a（实测 desired=2 得到 1a:2 / 1b:0）。
#    ACK 不暴露「按交换机绑机型」的 instance_type_overrides，故只能靠顺序纠正。
export INSTANCE_TYPES="${INSTANCE_TYPES:-ecs.g9ae.2xlarge,ecs.g9i.2xlarge,ecs.g8ine.2xlarge}"
export IMAGE_TYPE="${IMAGE_TYPE:-AliyunLinux3ContainerOptimized}"
export DESIRED="${DESIRED:-2}"
export MIN_NODES="${MIN_NODES:-2}"
export MAX_NODES="${MAX_NODES:-12}"
export SITE_TAG="${SITE_TAG:-sg}"                                       # tags site=sg
export MANAGED="${MANAGED:-0}"
export USERDATA_SRC="${USERDATA_SRC:-$REPO_ROOT/deploy/nodepool-userdata-nofile.sh}"
export TASK_LABEL="${TASK_LABEL:-任务 24｜新加坡备站节点池}"
export AZ_A_LABEL="${AZ_A_LABEL:-1a}"
export AZ_B_LABEL="${AZ_B_LABEL:-1b}"
export MIN_PER_ZONE="${MIN_PER_ZONE:-1}"    # 常态 2 台 → 每区 1 台即达标
export MIN_ZONES="${MIN_ZONES:-2}"

TS="$(date +%Y%m%d-%H%M%S)"
export OUTDIR="${OUTDIR:-$REPO_ROOT/deploy/logs/task24_np_$TS}"
mkdir -p "$OUTDIR"

exec bash "$HERE/task11_nodepool_mnl.sh" "$@"
