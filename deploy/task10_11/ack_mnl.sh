#!/usr/bin/env bash
# =============================================================================
# Day 2 · 任务 10 + 任务 11 —— 马尼拉 ACK Pro 集群 + 4×g9i.2xlarge 节点池
#
# 依据：deploy/docs/阿里云国际站菲律宾部署_详细操作指南-v2.0.md（任务 10 / 任务 11）
#       基线：K8s 1.35（马尼拉可创建 = 1.36.2 / 1.35.7 / 1.34.10，实测 2026-09-28）
#             机型 ecs.g9i.2xlarge 8C32G（g8i 未在马尼拉上架）
#
# 用法：
#   ./deploy/task10_11/ack_mnl.sh verify      # 只读：机型可用性 + vCPU 配额 + 版本复核（P0）
#   ./deploy/task10_11/ack_mnl.sh keypair     # 建 ECS 密钥对（幂等，私钥落 ~/.ssh）
#   ./deploy/task10_11/ack_mnl.sh cluster     # 建集群 ack-newapi-mnl（5–15 min）
#   ./deploy/task10_11/ack_mnl.sh nodepool    # 建节点池 np-mnl-app（desired 4 / 4–8，跨 6a+6b）
#   ./deploy/task10_11/ack_mnl.sh check       # 验证：集群/节点池/节点分布/磁盘
#   ./deploy/task10_11/ack_mnl.sh kubeconfig  # 拉 60 分钟临时 kubeconfig 到 /tmp
#   ./deploy/task10_11/ack_mnl.sh all         # verify → keypair → cluster → nodepool → check
#
# 幂等：集群/节点池已存在则跳过创建；写操作失败会打印原始错误不吞
# 日志：deploy/logs/task10_11_<ts>.log
# =============================================================================
set -euo pipefail

# 允许被直接执行：把 aliyun CLI 所在目录补进 PATH（幂等；macOS 侧二进制不在默认 PATH 里）
for d in "$HOME/.workbuddy/binaries/aliyun-cli" "/usr/local/bin"; do
  [ -d "$d" ] || continue
  case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
done
export PATH
command -v aliyun >/dev/null 2>&1 || { echo "FATAL: 未找到 aliyun CLI（预期 $HOME/.workbuddy/binaries/aliyun-cli/aliyun）" >&2; exit 1; }

# ------------------------- 基线常量（改这里，勿散落） -------------------------
REGION=ap-southeast-6
VPC=vpc-5tst1tgeessxn1azwasg2
VSW_APP_A=vsw-5tswpyzfa8od6je95td1h          # vsw-mnl-app-a  10.0.16.0/20  ap-southeast-6a
VSW_APP_B=vsw-5tshuvvtrqm97tnwe1ddm          # vsw-mnl-app-b  10.0.32.0/20  ap-southeast-6b
CLUSTER_NAME=ack-newapi-mnl
NODEPOOL_NAME=np-mnl-app
K8S_VERSION="${K8S_VERSION:-1.35.7-aliyun.1}"  # 1.35 最新 patch（指南 F 项 minor=1.35）
CLUSTER_SPEC=ack.pro.small
SERVICE_CIDR=172.21.0.0/20
KEYPAIR="${KEYPAIR:-newapi-mnl}"
RG=rg-aek4nyivmmsb6iy                        # rg-ph-mnl
DESIRED=4; MIN_SIZE=4; MAX_SIZE=8            # 8×8 vCPU = 64 = 已批配额（上限即配额，无余量）
INSTANCE_TYPES='["ecs.g9i.2xlarge","ecs.g8ine.2xlarge","ecs.g9ae.2xlarge"]'
SYS_DISK_SIZE=100
DATA_DISK_SIZE=300
USE_DISK_INIT=1                              # disk_init（官方数据盘挂载）失败则置 0 走 user_data 兜底

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"
LOG_DIR="$ROOT_DIR/deploy/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/task10_11_$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { say "FATAL: $*"; exit 1; }
hr()  { printf '%s\n' "------------------------------------------------------------"; }

step="${1:-all}"
case "$step" in
  verify|keypair|cluster|nodepool|check|kubeconfig|all) ;;
  *) die "unknown step: $step (verify|keypair|cluster|nodepool|check|kubeconfig|all)" ;;
esac

say "log -> $LOG"
say "step=$step region=$REGION cluster=$CLUSTER_NAME nodepool=$NODEPOOL_NAME k8s=$K8S_VERSION"

# =============================================================================
# 通用工具
# =============================================================================
retry() {                    # retry <n> <cmd...>；VPC/CS 端点偶发抖动，写操作一律包
  local n="$1"; shift
  local i=1 out
  while :; do
    if out="$("$@" 2>&1)"; then printf '%s' "$out"; return 0; fi
    if [ "$i" -ge "$n" ]; then printf '%s' "$out" >&2; return 1; fi
    say "  retry $i/$n failed, 3s later: $*"
    i=$((i + 1)); sleep 3
  done
}

cluster_id() {
  aliyun cs DescribeClustersV1 --region "$REGION" --Name "$CLUSTER_NAME" 2>/dev/null \
    | jq -r '.clusters[]?|select(.name=="'"$CLUSTER_NAME"'")|.cluster_id' | head -1
}

cluster_state() {
  aliyun cs DescribeClusterDetail --ClusterId "$1" --region "$REGION" 2>/dev/null | jq -r '.state // "?"'
}

# =============================================================================
# STEP: verify —— 任务 11 Step 1（P0，不可跳过）
# =============================================================================
do_verify() {
  hr; say "STEP verify｜任务 11 Step 1 · 机型可用性 + 配额复核"
  local tmp; tmp="$(mktemp -d)"

  # 2026-10-06 裁定：节点池为按量 ⇒ 库存查询用 PostPaid（包年包月/按量可售池不共享）
  aliyun ecs DescribeAvailableResource --RegionId "$REGION" --DestinationResource InstanceType \
    --InstanceChargeType PostPaid --IoOptimized optimized --NetworkCategory vpc --ResourceType instance \
    > "$tmp/avail.json" 2>"$tmp/avail.err" || die "DescribeAvailableResource failed: $(cat "$tmp/avail.err")"

  jq -r '.AvailableZones.AvailableZone[]
         | .ZoneId as $z
         | .AvailableResources.AvailableResource[]
         | .SupportedResources.SupportedResource[]
         | select(.Status=="Available") | [$z,.Value] | @tsv' "$tmp/avail.json" \
    | grep -E 'g9i\.2xlarge|g8ine\.2xlarge|g9ae\.2xlarge' | sort > "$tmp/cand.tsv"

  say "候选机型可售情况（6a/6b）："; cat "$tmp/cand.tsv"

  local n
  n="$(grep -c 'ecs.g9i.2xlarge' "$tmp/cand.tsv" || true)"
  [ "$n" -ge 2 ] || die "g9i.2xlarge 未在双可用区可售（命中 $n 个 AZ）→ 换 g8ine.2xlarge 并重算 request/limit"
  say "OK  g9i.2xlarge 双 AZ 可售（命中 $n 个 AZ）"

  say "vCPU 配额（按量 q_ecs_enterprise_postpay_c 须 ≥64 —— 2026-10-06 裁定后的核量口径，⚠ max 顶满即零余量；prepay_c 仅对照，两者分别计量）："
  aliyun quotas ListProductQuotas --ProductCode ecs-spec --QuotaCategory CommonQuota \
    --Dimensions.1.Key regionId --Dimensions.1.Value "$REGION" \
    | jq -r '.Quotas[]|select(.QuotaActionCode|test("enterprise_(pre|post)pay_c"))|[.QuotaActionCode,(.TotalQuota|tostring)]|@tsv'

  say "配额工单状态（须 Agree）："
  aliyun quotas ListQuotaApplications --ProductCode ecs-spec --QuotaCategory CommonQuota --MaxResults 30 \
    --Dimensions.1.Key regionId --Dimensions.1.Value "$REGION" \
    | jq -r '.QuotaApplications[]?|select(.QuotaActionCode=="q_ecs_enterprise_postpay_c")|[.QuotaActionCode,(.DesireValue|tostring),.Status,.ApplyTime]|@tsv' || true

  say "可创建 K8s 版本（须含 1.35）："
  aliyun cs DescribeKubernetesVersionMetadata --ClusterType ManagedKubernetes --Region "$REGION" --Mode creatable \
    | jq -r '.[].version'

  say "Terway Pod 容量（SupportedPods=(EniQuantity-1)×EniPrivateIpAddressQuantity）："
  aliyun ecs DescribeInstanceTypes --RegionId "$REGION" \
    --InstanceTypes.1 ecs.g9i.2xlarge --InstanceTypes.2 ecs.g8ine.2xlarge --InstanceTypes.3 ecs.g9ae.2xlarge \
    | jq -r '.InstanceTypes.InstanceType[] | [(.InstanceTypeId // .InstanceType),
              ((.CpuCoreCount|tostring)+"C/"+(.MemorySize|tostring)+"G"),
              ("eni="+(.EniQuantity|tostring)), ("ips="+(.EniPrivateIpAddressQuantity|tostring)),
              ("pods="+(((.EniQuantity-1)*(.EniPrivateIpAddressQuantity))|tostring))] | @tsv'
}

# =============================================================================
# STEP: keypair
# =============================================================================
do_keypair() {
  hr; say "STEP keypair｜ECS 密钥对 $KEYPAIR"
  if aliyun ecs DescribeKeyPairs --RegionId "$REGION" 2>/dev/null \
       | jq -e --arg k "$KEYPAIR" '.KeyPairs.KeyPair[]?|select(.KeyPairName==$k)' >/dev/null 2>&1; then
    say "已存在，跳过（私钥请自行保管）"
    return 0
  fi
  local out pem
  out="$(aliyun ecs CreateKeyPair --RegionId "$REGION" --KeyPairName "$KEYPAIR")" || die "CreateKeyPair failed"
  pem="$HOME/.ssh/$KEYPAIR.pem"
  printf '%s' "$(printf '%s' "$out" | jq -r '.PrivateKeyBody')" > "$pem"
  chmod 600 "$pem"
  say "私钥已保存：${pem}（仅此一次下发，务必另存）"
  say "指纹：$(printf '%s' "$out" | jq -r '.KeyPairFingerPrint // "-"')"
}

# =============================================================================
# STEP: cluster —— 任务 10
# =============================================================================
do_cluster() {
  hr; say "STEP cluster｜任务 10 · ACK Pro 马尼拉集群"
  local cid; cid="$(cluster_id || true)"
  if [ -n "$cid" ]; then
    say "集群已存在：$cid state=$(cluster_state "$cid")，跳过创建"
    return 0
  fi
  # 前置硬门禁：acks 服务未开通时 CreateCluster 报 ErrorNotEnabled
  # （实测 2026-09-28 返回 RISK.RISK_CONTROL_REJECTION —— 账户余额 0 触发风控拦截付费服务开通）
  say "开通状态预检（OpenAckService --type propayasgo，失败即停）："
  local oa; oa="$(aliyun cs OpenAckService --type propayasgo 2>&1 || true)"
  printf '%s\n' "$oa" | jq -c . 2>/dev/null || printf '%s\n' "$oa"
  case "$oa" in
    *RISK_CONTROL_REJECTION*) die "风控拦截：账户余额 0 / 账号异常 → 先充值并在控制台开通 ACK 服务后再跑本步骤" ;;
    *'"success":true'*) ;;
    *) say "WARN 开通返回非标准（继续尝试建簇）" ;;
  esac

  local body="$ROOT_DIR/deploy/.ack-mnl-cluster.json"
  jq -n \
    --arg name "$CLUSTER_NAME" --arg reg "$REGION" --arg vpc "$VPC" \
    --arg vsa "$VSW_APP_A" --arg vsb "$VSW_APP_B" --arg sc "$SERVICE_CIDR" \
    --arg rg "$RG" --arg k8s "$K8S_VERSION" --arg spec "$CLUSTER_SPEC" '
    {
      name: $name, cluster_type: "ManagedKubernetes", cluster_spec: $spec,
      region_id: $reg, resource_group_id: $rg,
      kubernetes_version: $k8s,
      vpcid: $vpc, vswitch_ids: [$vsa, $vsb], pod_vswitch_ids: [$vsa, $vsb],
      service_cidr: $sc, network: "terway-eniip", proxy_mode: "ipvs",
      charge_type: "PostPaid", timezone: "Asia/Manila",
      snat_entry: false, endpoint_public_access: false, deletion_protection: true,
      enable_rrsa: true, rrsa_config: {enabled: true},
      enable_audit: true, audit_log_config: {enabled: true},
      tags: [{key:"site",value:"ph-mnl"},{key:"env",value:"prod"},{key:"track",value:"stable"}],
      addons: [{name:"csi-plugin"},{name:"csi-provisioner"},{name:"ack-pod-identity-webhook"},
               {name:"alb-ingress-controller"},{name:"managed-coredns"},{name:"arms-prometheus"},
               {name:"logtail-ds"}, {name:"terway-eniip"}]
    }' > "$body"
  say "body -> $body"; cat "$body"

  local resp
  resp="$(aliyun cs CreateCluster --region "$REGION" --header "Content-Type=application/json" \
            --body "$(cat "$body")")" || die "CreateCluster failed（Pro 托管版建簇失败一般无法原地续跑，需删除重建）"
  say "resp: $resp"
  cid="$(printf '%s' "$resp" | jq -r '.cluster_id')"
  [ -n "$cid" ] && [ "$cid" != "null" ] || die "未取得 cluster_id"
  say "cluster_id=$cid"

  say "等待 running（最多 30 min）…"
  local i=0
  while [ "$i" -lt 60 ]; do
    local st; st="$(cluster_state "$cid")"
    say "  [$i] state=$st"
    [ "$st" = "running" ] && break
    case "$st" in failed|delete_failed) die "建簇失败，诊断：aliyun cs DescribeClusterEvents --ClusterId $cid" ;; esac
    i=$((i + 1)); sleep 30
  done
  [ "$(cluster_state "$cid")" = "running" ] || die "超时未 running"
  say "集群就绪：$(aliyun cs DescribeClusterDetail --ClusterId "$cid" --region "$REGION" \
      | jq -c '{state,current_version,cluster_spec,profile,rrsa:.rrsa_config.enabled}')"
  echo "$cid" > "$ROOT_DIR/deploy/.ack-mnl-cluster-id"
}

# =============================================================================
# STEP: nodepool —— 任务 11
# =============================================================================
do_nodepool() {
  hr; say "STEP nodepool｜任务 11 · 4×g9i.2xlarge 跨 2 AZ + nofile 调优"
  local cid; cid="$(cluster_id || true)"
  [ -n "$cid" ] || die "集群不存在，先跑 cluster"
  [ "$(cluster_state "$cid")" = "running" ] || die "集群非 running（$(cluster_state "$cid")）"

  if aliyun cs DescribeClusterNodePools --ClusterId "$cid" --region "$REGION" 2>/dev/null \
       | jq -e --arg n "$NODEPOOL_NAME" '.nodepools[]?|select(.nodepool_info.name==$n)' >/dev/null 2>&1; then
    say "节点池已存在：${NODEPOOL_NAME}，跳过创建"
    return 0
  fi

  local ud_in="$ROOT_DIR/deploy/task11/node_init.sh"
  [ -f "$ud_in" ] || die "缺少 user_data 脚本：$ud_in"
  local user_data; user_data="$(base64 < "$ud_in" | tr -d '\n')"

  local body="$ROOT_DIR/deploy/.ack-mnl-nodepool.json"
  jq -n --arg ud "$user_data" --arg rg "$RG" --arg np "$NODEPOOL_NAME" \
        --arg vsa "$VSW_APP_A" --arg vsb "$VSW_APP_B" --arg kp "$KEYPAIR" \
        --argjson its "$INSTANCE_TYPES" --argjson des "$DESIRED" --argjson mn "$MIN_SIZE" --argjson mx "$MAX_SIZE" \
        --argjson syssz "$SYS_DISK_SIZE" --argjson ddsz "$DATA_DISK_SIZE" '
    {
      nodepool_info: {name: $np, resource_group_id: $rg, type: "ess"},
      scaling_group: {
        instance_types: $its,
        vswitch_ids: [$vsa, $vsb],
        system_disk_category: "cloud_essd", system_disk_size: $syssz, system_disk_performance_level: "PL1",
        data_disks: [{category:"cloud_essd", size:$ddsz, performance_level:"PL1", disk_name:"data-1"}],
        desired_size: $des, min_size: $mn, max_size: $mx,
        # 2026-10-06 裁定：节点池维持按量（原 PrePaid + period_unit/period/auto_renew 作废）
        instance_charge_type: "PostPaid",
        internet_max_bandwidth_out: 0,
        multi_az_policy: "BALANCE",
        key_pair: $kp, login_password: "",
        tags: [{key:"site",value:"ph-mnl"},{key:"env",value:"prod"},{key:"track",value:"stable"}]
      },
      kubernetes_config: {
        runtime: "containerd", cpu_policy: "none",
        labels: [{key:"track",value:"stable"}],
        user_data: $ud
      },
      auto_scaling: {enable: true, min_instances: $mn, max_instances: $mx}
    }' > "$body"

  if [ "$USE_DISK_INIT" = "1" ]; then
    jq '.scaling_group.disk_init = [{disk_name:"data-1", mkfs_type:"ext4", mount_for_runtime:true}]' \
      "$body" > "$body.tmp" && mv "$body.tmp" "$body"
  fi
  say "body -> $body"; cat "$body"

  local resp
  resp="$(aliyun cs CreateClusterNodePool --ClusterId "$cid" --region "$REGION" \
            --body "$(cat "$body")")" || die "CreateClusterNodePool failed（若错误指向 disk_init，把脚本里 USE_DISK_INIT 置 0 重跑；user_data 已含数据盘兜底）"
  say "resp: $resp"

  say "等待节点池达到 desired=${DESIRED}（最多 20 min）…"
  local i=0
  while [ "$i" -lt 40 ]; do
    local line; line="$(aliyun cs DescribeClusterNodePools --ClusterId "$cid" --region "$REGION" 2>/dev/null \
      | jq -r --arg n "$NODEPOOL_NAME" '.nodepools[]?|select(.nodepool_info.name==$n)
        |[(.status.state//"?"),(.status.total_nodes|tostring),(.status.healthy_nodes|tostring),.status.instances[0].instance_type//"-"]|@tsv')"
    say "  [$i] state/total/healthy/type = $line"
    case "$line" in active*) break ;; esac
    i=$((i + 1)); sleep 30
  done
  say "节点池：$line"
}

# =============================================================================
# STEP: check —— 验证方法（指南任务 11）
# =============================================================================
do_check() {
  hr; say "STEP check｜任务 11 验证"
  local cid; cid="$(cluster_id || true)"; [ -n "$cid" ] || die "集群不存在"
  say "集群：$(aliyun cs DescribeClusterDetail --ClusterId "$cid" --region "$REGION" \
      | jq -c '{state,current_version,cluster_spec,profile,rrsa:.rrsa_config.enabled,public:.endpoint_public_access,del_prot:.deletion_protection}')"

  say "节点池："
  aliyun cs DescribeClusterNodePools --ClusterId "$cid" --region "$REGION" \
    | jq -r '.nodepools[]?|[(.nodepool_info.name),(.status.state//"?"),
             ((.status.total_nodes|tostring)+"/"+(.status.healthy_nodes|tostring)),
             (.scaling_group.instance_types[0]//"-"),
             ((.scaling_group.desired_size|tostring)+"-"+(.scaling_group.max_size|tostring)),
             (.auto_scaling.enable|tostring)]|@tsv'

  say "Pod vSwitch 余量（Terway 每 Pod 占真实 VPC IP，free<200 告警 P2）："
  aliyun vpc DescribeVSwitches --RegionId "$REGION" \
    --VSwitchId.1 "$VSW_APP_A" --VSwitchId.2 "$VSW_APP_B" \
    | jq -r '.VSwitches.VSwitch[]|[.VSwitchId,.ZoneId,.CidrBlock,(.AvailableIpAddressCount|tostring)]|@tsv'

  say "节点列表（kubectl，需 KUBECONFIG）："
  say "  aliyun cs DescribeClusterUserKubeconfig --ClusterId $cid --TemporaryDurationMinutes 60 | jq -r .config > /tmp/kubeconfig-mnl"
  say "  kubectl get nodes -L topology.kubernetes.io/zone -l site=ph-mnl   # 期望 ≥4 Ready，6a/6b 各 ≥2"
  say "  kubectl run u --image=busybox --rm -it --restart=Never -- sh -c 'ulimit -n'   # 期望 200000"
  say "  kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{\"\\t\"}{.metadata.labels.node\\.beta\\.kubernetes\\.io/instance-type}{\"\\n\"}{end}'"
  if [ -f /tmp/kubeconfig-mnl ]; then
    KUBECONFIG=/tmp/kubeconfig-mnl kubectl get nodes -L topology.kubernetes.io/zone -l site=ph-mnl 2>/dev/null || true
  fi
}

do_kubeconfig() {
  hr; say "STEP kubeconfig｜临时凭证 60 分钟"
  local cid; cid="$(cluster_id || true)"; [ -n "$cid" ] || die "集群不存在"
  aliyun cs DescribeClusterUserKubeconfig --ClusterId "$cid" --region "$REGION" \
    --TemporaryDurationMinutes 60 | jq -r .config > /tmp/kubeconfig-mnl
  chmod 600 /tmp/kubeconfig-mnl
  say "已写入 /tmp/kubeconfig-mnl（60 min 过期）"
  KUBECONFIG=/tmp/kubeconfig-mnl kubectl get nodes 2>/dev/null || say "（节点尚未就绪或本机无 kubectl）"
  say "RRSA（任务 17 用）：$(aliyun cs DescribeClusterDetail --ClusterId "$cid" --region "$REGION" | jq -c '.rrsa_config')"
}

# =============================================================================
case "$step" in
  verify)     do_verify ;;
  keypair)    do_keypair ;;
  cluster)    do_keypair; do_cluster ;;
  nodepool)   do_nodepool ;;
  check)      do_check ;;
  kubeconfig) do_kubeconfig ;;
  all)
    do_verify
    do_keypair
    do_cluster
    do_nodepool
    do_kubeconfig
    do_check
    ;;
esac

hr; say "done step=$step log=$LOG"
