#!/usr/bin/env bash
# =============================================================================
# 任务 10｜ACK Pro 马尼拉集群（ap-southeast-6）
#   幂等：同名集群存在则复用，不重复创建
#   用法: bash deploy/task10/ack_mnl.sh [--dry-run]
#   注意：集群创建不可原地续跑（Pro 托管版失败需删除重建），故 CreateCluster 只调一次
# =============================================================================
set -uo pipefail

exec 3>&2   # fd3 = 日志通道（与 say/ok 同向 stderr）

REGION="${REGION:-ap-southeast-6}"
VPC="${VPC:-vpc-5tst1tgeessxn1azwasg2}"
VSW_APP_A="${VSW_APP_A:-vsw-5tswpyzfa8od6je95td1h}"   # vsw-mnl-app-a 10.0.16.0/20 (6a)
VSW_APP_B="${VSW_APP_B:-vsw-5tshuvvtrqm97tnwe1ddm}"   # vsw-mnl-app-b 10.0.32.0/20 (6b)
CLUSTER_NAME="${CLUSTER_NAME:-ack-newapi-mnl}"
K8S_VER="${K8S_VER:-1.35.7-aliyun.1}"                 # 实测可售：1.34.10 / 1.35.7 / 1.36.2
CLUSTER_SPEC="${CLUSTER_SPEC:-ack.pro.small}"
SERVICE_CIDR="${SERVICE_CIDR:-172.21.0.0/20}"
TIMEZONE="${TIMEZONE:-Asia/Manila}"
# ⚠️ 必填：默认组禁放 new-api 资源（实测漏写会落到 rg-acfnssmgwnsb5oa=default，
#    且 ACK 集群不支持资源组迁移：MoveResources 返回 UnsupportedOperation.MoveResources）
RESOURCE_GROUP_ID="${RESOURCE_GROUP_ID:-rg-aek4nyivmmsb6iy}"   # rg-ph-mnl
REPO_ROOT="${REPO_ROOT:-/mnt/e/git_code/new-api-yxw}"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${OUTDIR:-$REPO_ROOT/deploy/logs/task10_$TS}"
mkdir -p "$OUTDIR"

say()  { printf '%s\n' "$*" >&2; }
step() { printf '\n>>> %s\n' "$*" >&2; }
ok()   { printf '    [OK] %s\n' "$*" >&2; }
warn() { printf '    [WARN] %s\n' "$*" >&2; }
fail() { printf '    [FAIL] %s\n' "$*" >&2; }

api() {   # 重试 3 次 + 校验 JSON（仅用于只读查询）
  local out="$1"; shift
  if [[ "$DRY_RUN" == "1" ]]; then printf '{"_dry_run":true}\n' > "$out"; return 0; fi
  local attempt rc
  for attempt in 1 2 3; do
    "$@" > "$out" 2>&1; rc=$?
    if [[ $rc -eq 0 ]] && jq -e . "$out" >/dev/null 2>&1; then return 0; fi
    [[ $attempt -lt 3 ]] && { warn "调用失败(rc=$rc)，${attempt}/3 重试: ${out##*/}"; sleep 5; }
  done
  return 1
}

say "============================================================"
say " 任务 10｜ACK Pro 马尼拉集群  ·  $REGION  ·  $(date '+%F %T')"
say " 集群: $CLUSTER_NAME  /  $CLUSTER_SPEC  /  k8s $K8S_VER"
say " 网络: VPC $VPC  ·  app-a=$VSW_APP_A app-b=$VSW_APP_B"
say " 关键项: terway-eniip · RRSA on · 无 SNAT · 无公网端点 · 删除保护 on"
say " 证据: $OUTDIR"
say "============================================================"

# ---- 0. 幂等 ----------------------------------------------------------------
step "0. 幂等检查"
api "$OUTDIR/00-list.json" aliyun cs DescribeClustersV1 --RegionId "$REGION"
CID=$(jq -r --arg n "$CLUSTER_NAME" '[.clusters[]?|select(.name==$n)|.cluster_id]|first // empty' \
      "$OUTDIR/00-list.json" 2>/dev/null | tr -d '\r')
say "    现有集群数=$(jq -r '.page_info.total_count // 0' "$OUTDIR/00-list.json" 2>/dev/null | tr -d '\r')  同名命中='${CID:-无}'"

# ---- 1. 渲染 body -----------------------------------------------------------
step "1. 渲染建簇 body"
cat > "$OUTDIR/create-cluster-mnl.json" <<EOF
{
  "name": "$CLUSTER_NAME",
  "cluster_type": "ManagedKubernetes",
  "profile": "Default",
  "cluster_spec": "$CLUSTER_SPEC",
  "region_id": "$REGION",
  "kubernetes_version": "$K8S_VER",
  "vpcid": "$VPC",
  "vswitch_ids": ["$VSW_APP_A", "$VSW_APP_B"],
  "pod_vswitch_ids": ["$VSW_APP_A", "$VSW_APP_B"],
  "service_cidr": "$SERVICE_CIDR",
  "snat_entry": false,
  "endpoint_public_access": false,
  "deletion_protection": true,
  "resource_group_id": "$RESOURCE_GROUP_ID",
  "proxy_mode": "ipvs",
  "timezone": "$TIMEZONE",
  "charge_type": "PostPaid",
  "rrsa_config": {"enabled": true},
  "addons": [
    {"name": "terway-controlplane", "config": "{\"ENITrunking\":\"false\"}"},
    {"name": "terway-eniip"},
    {"name": "csi-plugin"},
    {"name": "csi-provisioner"},
    {"name": "ack-pod-identity-webhook"},
    {"name": "alb-ingress-controller"},
    {"name": "managed-coredns"},
    {"name": "arms-prometheus"},
    {"name": "logtail-ds"}
  ]
}
EOF
jq -e . "$OUTDIR/create-cluster-mnl.json" >/dev/null && ok "body JSON 合法" \
  || { fail "body JSON 不合法"; exit 1; }
cat "$OUTDIR/create-cluster-mnl.json" >&3

# ---- 2. 创建（只调一次） -----------------------------------------------------
if [[ -n "$CID" ]]; then
  ok "复用已存在集群 $CID"
else
  step "2. 创建集群（单次调用，不重试）"
  if [[ "$DRY_RUN" == "1" ]]; then
    CID="c-dryrun"
  else
    aliyun cs CreateCluster --body "$(cat "$OUTDIR/create-cluster-mnl.json")" \
      > "$OUTDIR/01-create.json" 2>&1
    cat "$OUTDIR/01-create.json" >&3
    CID=$(jq -r '.cluster_id // empty' "$OUTDIR/01-create.json" 2>/dev/null | tr -d '\r')
    if [[ -z "$CID" ]]; then
      warn "未取到 cluster_id，复查是否已建（防重复创建）"
      api "$OUTDIR/01b-recheck.json" aliyun cs DescribeClustersV1 --RegionId "$REGION"
      CID=$(jq -r --arg n "$CLUSTER_NAME" '[.clusters[]?|select(.name==$n)|.cluster_id]|first // empty' \
            "$OUTDIR/01b-recheck.json" 2>/dev/null | tr -d '\r')
    fi
    [[ -z "$CID" ]] && { fail "创建失败"; exit 1; }
    ok "cluster_id=$CID"
  fi
fi

# ---- 3. 等待 running（最长 25 分钟） -----------------------------------------
step "3. 等待集群就绪（最长 25 分钟）"
if [[ "$DRY_RUN" == "1" ]]; then
  ok "(dry-run 跳过)"
else
  STATE=""
  for i in $(seq 1 50); do
    api "$OUTDIR/02-detail.json" aliyun cs DescribeClusterDetail --ClusterId "$CID"
    STATE=$(jq -r '.state // "?"' "$OUTDIR/02-detail.json" 2>/dev/null | tr -d '\r')
    say "    [$i/50] state=$STATE"
    [[ "$STATE" == "running" ]] && { ok "集群 running"; break; }
    [[ "$STATE" == "failed" ]] && { fail "集群创建失败，查 $OUTDIR/02-detail.json"; exit 1; }
    sleep 30
  done
  [[ "$STATE" != "running" ]] && { fail "等待超时，最后 state=$STATE"; exit 1; }
fi

# ---- 4. 终验 -----------------------------------------------------------------
step "4. 终验"
if [[ "$DRY_RUN" != "1" ]]; then
  jq -r '{cluster_id,name,state,cluster_type,cluster_spec,current_version,region_id,vpc_id,zone_id,network,subnet_cidr,proxy_mode,timezone,deletion_protection,rrsa_config,created,updated}' \
    "$OUTDIR/02-detail.json" >&3
  jq -r '.rrsa_config' "$OUTDIR/02-detail.json" >&3
  # vSwitch 剩余 IP 基线（Terway 下 Pod 占真实 IP）
  api "$OUTDIR/04-vsw-a.json" aliyun vpc DescribeVSwitchAttributes --VSwitchId "$VSW_APP_A" --RegionId "$REGION"
  api "$OUTDIR/04-vsw-b.json" aliyun vpc DescribeVSwitchAttributes --VSwitchId "$VSW_APP_B" --RegionId "$REGION"
  say "    app-a free=$(jq -r '.AvailableIpAddressCount' "$OUTDIR/04-vsw-a.json" 2>/dev/null | tr -d '\r')  app-b free=$(jq -r '.AvailableIpAddressCount' "$OUTDIR/04-vsw-b.json" 2>/dev/null | tr -d '\r')" >&3
  # 资源组断言：默认组禁放 new-api 资源（漏写 resource_group_id 会静默落到 default）
  GOT_RG=$(jq -r '.resource_group_id // ""' "$OUTDIR/02-detail.json" 2>/dev/null | tr -d '\r')
  if [[ "$GOT_RG" == "$RESOURCE_GROUP_ID" ]]; then
    ok "资源组正确: $GOT_RG"
  else
    fail "资源组不符！期望 $RESOURCE_GROUP_ID，实际 $GOT_RG（ACK 不支持迁移，需重建）"
    exit 1
  fi
fi

say ""
say "============================================================"
say " 结果"
say "  cluster_id : $CID"
say "  证据目录   : $OUTDIR"
say "  提示       : 私网端点，kubectl 需在 VPC 内（堡垒机）；公网端点未开"
say "============================================================"
