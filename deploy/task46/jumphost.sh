#!/usr/bin/env bash
# =============================================================================
# Day 2 · 任务 46｜运维访问面（方案 B：自建跳板 ECS）
# 参考：deploy/docs/阿里云国际站菲律宾部署_详细操作指南-v2.0.md 「任务 46」
# 关联：本卡是**任务 19 的前置**（任务 19 的 EXEC_MODE=ssh 经本跳板机执行 kubectl）
#
# 方案变更留痕（2026-09-29）：原选 A（云堡垒机产品），因**成本**改选 B（自建跳板 ECS）。
#   代价：云堡垒机自带的会话录制/命令审计改由本机 `script` 录制 + SLS 采集自建（ENABLE_RECORDING=1），
#        属对 §8.5「会话录制」的**部分偏差**（录制能力等价性待运维确认）。
#
# 设计（两条通道，都不开公网端点、都不放行 0.0.0.0/0）：
#   ① 人工运维：办公出口 IP → SSH(22) → 跳板机 →（可选录制）→ kubectl
#   ② 自动化  ：ECS 云助手在**跳板机**（非 prod ACK 节点）执行 → kubectl，ActionTrail 留痕
#   跳板机不落长期凭据：绑定 ECS 实例 RAM 角色，用 /usr/local/bin/newapi-kube 按需换取 60min 临时 kubeconfig。
#
# 用法：
#   OFFICE_CIDR=1.2.3.4/32,5.6.7.0/24 bash deploy/task46/jumphost.sh     # 建 SG + RAM 角色 + ECS + 装机 + 验证
#   DRY_RUN=1 ... bash deploy/task46/jumphost.sh                          # 只打印动作
#   ENABLE_RECORDING=1 ... bash deploy/task46/jumphost.sh                 # 同时装会话录制
#   bash deploy/task46/jumphost.sh --verify-only                          # 只验证（不建资源）
#   bash deploy/task46/jumphost.sh --cleanup                              # 删除跳板机与 SG（保留 RAM 角色）
#
# 幂等：SG / RAM 角色 / ECS 均按名称复用；装机与验证可重复执行。
# 实现注意：日志走 fd 3，API 原始输出落文件；写操作 3 次重试（ap-southeast-6 端点偶发 timeout）。
# =============================================================================
set -uo pipefail
exec 3>&2

REGION=ap-southeast-6
CLUSTER_ID=cd57e40ce9a634c1698c2f5c5e09bd93c      # ACK 马尼拉（任务 10 交付）
VPC=vpc-5tst1tgeessxn1azwasg2
PUB_A=vsw-5ts9tgdq1xz3picjgoqyu                 # vsw-mnl-pub-a / 6a / 10.0.0.0/24 / free=251
RG=rg-aek4nyivmmsb6iy                           # 马尼拉统一资源组（VPC/EIP/SG 同组）
EDGE_SG_NAME=sg-mnl-alb-edge                    # G6 模板命名：堡垒机/VPN 入口（运维访问面）
JUMP_NAME=newapi-ops-mnl
KEYPAIR=newapi-mnl                              # 已被 4 个 ACK worker 使用 → 团队持有私钥
INSTANCE_TYPE="${INSTANCE_TYPE:-ecs.c9i.large}" # 2C4G 按量 ≈USD 0.0855/h（g9i.large 2C8G ≈0.1024/h）
IMAGE_ID="${IMAGE_ID:-aliyun_3_x64_20G_pro_alibase_20260827.vhd}"
BW_OUT="${BW_OUT:-5}"                           # PayByTraffic 峰值 5Mbps（仅 SSH 运维）
RAM_ROLE=new-api-ops-jumphost
RAM_POLICY=new-api-ops-kubeconfig-read
OFFICE_CIDR="${OFFICE_CIDR:-}"
ENABLE_RECORDING="${ENABLE_RECORDING:-0}"
ENABLE_SSH_ALLOWLIST="${ENABLE_SSH_ALLOWLIST:-0}"   # 1=建固定 IP 白名单（仅当出口 IP 固定时）；默认 0=零入向
OSS_BUCKET="${OSS_BUCKET:-oss-newapi-mnl}"          # 会话录制投递桶（须与 ECS 同地域）
OSS_PREFIX="${OSS_PREFIX:-ops-sessions/}"
DRY_RUN="${DRY_RUN:-0}"
VERIFY_ONLY=0
CLEANUP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify-only) VERIFY_ONLY=1 ;;
    --cleanup)     CLEANUP=1 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
  shift
done

HERE="$(cd "$(dirname "$0")" && pwd)"
TS=$(date +%Y%m%d-%H%M%S)
OUTDIR="$HERE/../logs/task46_${TS}"
mkdir -p "$OUTDIR"

say()  { printf '%s\n' "$*" >&3; }
hr()   { say "------------------------------------------------------------"; }
step() { say ""; say ">>> $*"; hr; }
pass() { say "  [PASS] $*"; PASS=$((PASS+1)); }
warn() { say "  [WARN] $*"; WARN=$((WARN+1)); }
fail() { say "  [FAIL] $*"; FAIL=$((FAIL+1)); }
PASS=0; WARN=0; FAIL=0

api() {
  local out="$1"; shift
  printf '+ %s\n' "$*" >&3
  local i
  for i in 1 2 3; do
    if "$@" > "$out" 2>&1 && jq -e . "$out" >/dev/null 2>&1; then return 0; fi
    say "  !! 第 ${i} 次调用失败，3s 后重试：$(head -c 160 "$out" | tr '\n' ' ')"
    sleep 3
  done
  say "  !! 已重试 3 次仍失败：$*"
  return 1
}

# node_sh <name> <script> —— 经云助手在跳板机执行；输出解码落 $OUTDIR/<name>.out
node_sh() {
  local name="$1" script="$2" b64 inv st i
  # ⚠ base64 可移植性：BSD/macOS 不支持 `-w0`（会报 invalid argument 并静默产出空内容）→ 走 python3
  b64=$(printf '%s' "$script" | python3 -c "import base64,sys;sys.stdout.write(base64.b64encode(sys.stdin.buffer.read()).decode())")
  printf '+ [cloud-assistant %s] %s …\n' "$JUMP_ID" "$name" >&3
  if [[ "$DRY_RUN" == "1" ]]; then printf '(dry-run)\n' > "$OUTDIR/$name.out"; return 0; fi
  inv=$(api "$OUTDIR/$name.invoke.json" aliyun ecs RunCommand --RegionId "$REGION" \
          --Type RunShellScript --InstanceId.1 "$JUMP_ID" \
          --ContentEncoding Base64 --CommandContent "$b64" --Timeout 600 \
        && jq -r '.InvokeId // empty' "$OUTDIR/$name.invoke.json" | tr -d '\r')
  [[ -n "$inv" ]] || { say "  !! RunCommand 未返回 InvokeId"; return 1; }
  for i in $(seq 1 90); do
    api "$OUTDIR/$name.result.json" aliyun ecs DescribeInvocationResults --RegionId "$REGION" --InvokeId "$inv" || true
    st=$(jq -r '.Invocation.InvocationResults.InvocationResult[0].InvocationStatus // "Unknown"' \
         "$OUTDIR/$name.result.json" 2>/dev/null | tr -d '\r')
    [[ "$st" =~ ^(Success|Failed|Timeout|PartialFailed)$ ]] && break
    sleep 5
  done
  jq -r '.Invocation.InvocationResults.InvocationResult[0].Output // ""' "$OUTDIR/$name.result.json" \
    2>/dev/null | base64 -d > "$OUTDIR/$name.out" 2>/dev/null || : > "$OUTDIR/$name.out"
  say "  执行状态=$st"; cat "$OUTDIR/$name.out" >&3
  [[ "$st" == "Success" ]]
}

# ---------------------------------------------------------------------------
step "0. 身份与前置复核"
api "$OUTDIR/00-identity.json" aliyun sts GetCallerIdentity
ACCOUNT=$(jq -r '.AccountId // empty' "$OUTDIR/00-identity.json" | tr -d '\r')
say "AccountId=$ACCOUNT  Arn=$(jq -r '.Arn' "$OUTDIR/00-identity.json")"
[[ "$ACCOUNT" == "5108890064395960" ]] && pass "账号正确" || fail "账号异常"
if [[ "$(jq -r '.Arn' "$OUTDIR/00-identity.json")" == *"user/yanxuewei"* ]]; then
  warn "当前身份为 yanxuewei（持 AdministratorAccess，F6 列为「遗留 AK 待降权」）——建议本卡完成后立即按其降权"
fi

api "$OUTDIR/00-quota.json" aliyun quotas ListProductQuotas --ProductCode ecs-spec --QuotaCategory CommonQuota \
  --Dimensions.1.Key regionId --Dimensions.1.Value "$REGION"
jq -r '.Quotas[]?|select(.QuotaActionCode=="q_ecs_enterprise_postpay_c")|"  vCPU 配额=\(.TotalQuota) 已用=\(.TotalUsage)"' \
  "$OUTDIR/00-quota.json" >&3
Q_TOTAL=$(jq -r '.Quotas[]?|select(.QuotaActionCode=="q_ecs_enterprise_postpay_c")|.TotalQuota' "$OUTDIR/00-quota.json" | tr -d '\r')
Q_USED=$(jq -r '.Quotas[]?|select(.QuotaActionCode=="q_ecs_enterprise_postpay_c")|.TotalUsage' "$OUTDIR/00-quota.json" | tr -d '\r')
if [[ -n "$Q_TOTAL" && -n "$Q_USED" ]]; then
  NEED=2
  if (( Q_USED + NEED <= Q_TOTAL )); then pass "配额充足（$Q_USED+$NEED ≤ $Q_TOTAL）"; else fail "vCPU 配额不足"; fi
fi

api "$OUTDIR/00-keypair.json" aliyun ecs DescribeKeyPairs --RegionId "$REGION"
jq -e --arg k "$KEYPAIR" '[.KeyPairs.KeyPair[]?|select(.KeyPairName==$k)]|length>0' "$OUTDIR/00-keypair.json" >/dev/null 2>&1 \
  && pass "密钥对 $KEYPAIR 存在（团队持有私钥）" || fail "密钥对 $KEYPAIR 不存在"

# 入口策略（2026-09-29 修订）：办公/VPN 出口为**动态 IP** → 固定白名单不可维护。
#   默认 ENABLE_SSH_ALLOWLIST=0：**零入向端口**，入口走 ECS 会话管理（RAM 身份 + 会话录制到 OSS）。
#   需要原生 ssh/scp 时用 deploy/ops/ops-access.sh --allow-ssh（按需放行当前出口 IP，带过期标记）。
if [[ "${ENABLE_SSH_ALLOWLIST:-0}" == "1" ]]; then
  if [[ -z "$OFFICE_CIDR" ]]; then
    fail "ENABLE_SSH_ALLOWLIST=1 但未提供 OFFICE_CIDR —— 拒绝（禁止 0.0.0.0/0）"
    say "  取数建议：ActionTrail 的 sourceIpAddress 是真实调用源 IP："
    say "    aliyun actiontrail LookupEvents --MaxResults 20 | jq -r '.Events[]|.sourceIpAddress' | sort -u"
    say ""
    say "证据目录：$OUTDIR"; exit 4
  fi
  case "$OFFICE_CIDR" in
    *0.0.0.0/0*) fail "OFFICE_CIDR 含 0.0.0.0/0 —— 拒绝执行" ;;
    *) pass "ENABLE_SSH_ALLOWLIST=1，OFFICE_CIDR=$OFFICE_CIDR（格式校验通过）" ;;
  esac
else
  warn "ENABLE_SSH_ALLOWLIST!=1 → 不建固定 IP 白名单（应对动态出口）；入口走 ECS 会话管理（零入向端口）"
  say "  临时需要原生 SSH/SCP 时：bash deploy/ops/ops-access.sh --allow-ssh [--ttl-min 120]"
fi
[[ "$FAIL" -eq 0 ]] || { say "!! 前置失败，终止"; exit 1; }

# ---------------------------------------------------------------------------
step "1. 运维访问面安全组 ${EDGE_SG_NAME}"
api "$OUTDIR/02-sg-list.json" aliyun ecs DescribeSecurityGroups --RegionId "$REGION" --VpcId "$VPC" --PageSize 50
EDGE_SG=$(jq -r --arg n "$EDGE_SG_NAME" '[.SecurityGroups.SecurityGroup[]?|select(.SecurityGroupName==$n)][0].SecurityGroupId // empty' \
          "$OUTDIR/02-sg-list.json" | tr -d '\r')
if [[ -n "$EDGE_SG" ]]; then
  pass "安全组已存在：$EDGE_SG（复用）"
elif [[ "$DRY_RUN" == "1" || "$VERIFY_ONLY" == "1" ]]; then
  warn "将创建安全组 ${EDGE_SG_NAME}（当前未创建）"
else
  api "$OUTDIR/02-sg-create.json" aliyun ecs CreateSecurityGroup --RegionId "$REGION" \
    --VpcId "$VPC" --SecurityGroupName "$EDGE_SG_NAME" \
    --Description "Ops access edge: self-built bastion/jumphost (mnl)" \
    --ResourceGroupId "$RG" \
    --Tag.1.Key project --Tag.1.Value new-api \
    --Tag.2.Key site    --Tag.2.Value ph-mnl \
    --Tag.3.Key env     --Tag.3.Value prod \
    --Tag.4.Key managed-by --Tag.4.Value iac
  EDGE_SG=$(jq -r '.SecurityGroupId // empty' "$OUTDIR/02-sg-create.json" | tr -d '\r')
  [[ -n "$EDGE_SG" ]] && pass "已创建安全组：$EDGE_SG" || fail "安全组创建失败"
fi

if [[ "${ENABLE_SSH_ALLOWLIST:-0}" == "1" && -n "$EDGE_SG" && -n "$OFFICE_CIDR" && "$DRY_RUN" != "1" && "$VERIFY_ONLY" != "1" ]]; then
  api "$OUTDIR/02-rules-before.json" aliyun ecs DescribeSecurityGroupAttribute --RegionId "$REGION" --SecurityGroupId "$EDGE_SG"
  IFS=',' read -r -a _cidrs <<< "$OFFICE_CIDR"
  RULE_OK=0; RULE_FAIL=0
  for p in 22 443; do
    for c in "${_cidrs[@]}"; do
      has=$(jq -r --arg p "$p" --arg c "$c" \
        '[.Permissions.Permission[]?|select(.Direction=="ingress" and .PortRange==$p and .SourceCidrIp==$c)]|length' \
        "$OUTDIR/02-rules-before.json" 2>/dev/null | tr -d '\r')
      if [[ "${has:-0}" != "0" ]]; then say "  TCP $p ← $c 已放行，跳过"; RULE_OK=$((RULE_OK+1)); continue; fi
      # ⚠ 证据文件名必须去掉 CIDR 里的 '/'，否则重定向失败 → 命令不执行却静默通过（2026-09-29 实测踩坑）
      c_safe="${c//[^A-Za-z0-9._-]/_}"
      if api "$OUTDIR/02-rule-$p-$c_safe.json" aliyun ecs AuthorizeSecurityGroup --RegionId "$REGION" \
        --SecurityGroupId "$EDGE_SG" --IpProtocol tcp --PortRange "$p/$p" \
        --SourceCidrIp "$c" --Policy accept --Priority 1 \
        --Description "ops-jumphost-entry-from-office"; then
        say "  TCP $p ← $c 已放行"; RULE_OK=$((RULE_OK+1))
      else
        say "  !! TCP $p ← $c 放行失败"; RULE_FAIL=$((RULE_FAIL+1))
      fi
    done
  done
  if [[ "$RULE_FAIL" -eq 0 && "$RULE_OK" -gt 0 ]]; then
    pass "入向 22/443 已收敛到 OFFICE_CIDR（$RULE_OK 条，无 0.0.0.0/0）"
  else
    fail "入向规则未全部落地（成功 $RULE_OK / 失败 $RULE_FAIL）—— 跳板机将不可 SSH，务必修复后复跑"
  fi
  say "  注：出向沿用安全组默认（放行），跳板机需访问 dl.k8s.io 与 API Server；如需收口见 §8.1"
fi

# ---------------------------------------------------------------------------
step "1b. 运维入口：ECS 会话管理 + 会话录制投递 OSS（零入向端口）"
if [[ "$DRY_RUN" == "1" || "$VERIFY_ONLY" == "1" ]]; then
  warn "（dry-run/verify）跳过会话管理配置"
else
  api "$OUTDIR/02b-sm-before.json" aliyun ecs DescribeCloudAssistantSettings --RegionId "$REGION" --SettingType.1 SessionManagerConfig
  SM=$(jq -r '.SessionManagerConfig.SessionManagerEnabled // false' "$OUTDIR/02b-sm-before.json" 2>/dev/null | tr -d '\r')
  if [[ "$SM" == "true" ]]; then
    pass "会话管理已启用（SessionManagerEnabled=true）"
  else
    api "$OUTDIR/02b-sm-enable.json" aliyun ecs ModifyCloudAssistantSettings --RegionId "$REGION" \
      --SettingType SessionManagerConfig --SessionManagerConfig '{"SessionManagerEnabled":true}' || true
    sleep 5
    api "$OUTDIR/02b-sm-after.json" aliyun ecs DescribeCloudAssistantSettings --RegionId "$REGION" --SettingType.1 SessionManagerConfig
    SM2=$(jq -r '.SessionManagerConfig.SessionManagerEnabled // false' "$OUTDIR/02b-sm-after.json" 2>/dev/null | tr -d '\r')
    [[ "$SM2" == "true" ]] && pass "会话管理已启用（本次开启）" || fail "会话管理启用失败（SessionManagerEnabled=$SM2）"
  fi

  api "$OUTDIR/02b-del-before.json" aliyun ecs DescribeCloudAssistantSettings --RegionId "$REGION" --SettingType.1 SessionManagerDelivery
  B=$(jq -r '.OssDeliveryConfigs.OssDeliveryConfig[0].BucketName // ""' "$OUTDIR/02b-del-before.json" 2>/dev/null | tr -d '\r')
  if [[ "$B" == "$OSS_BUCKET" ]]; then
    pass "会话录制投递已配置 → oss://$OSS_BUCKET/$(jq -r '.OssDeliveryConfigs.OssDeliveryConfig[0].Prefix // ""' "$OUTDIR/02b-del-before.json" | tr -d '\r')"
  else
    api "$OUTDIR/02b-del-set.json" aliyun ecs ModifyCloudAssistantSettings --RegionId "$REGION" \
      --SettingType SessionManagerDelivery \
      --OssDeliveryConfig "{\"Enabled\":true,\"BucketName\":\"$OSS_BUCKET\",\"Prefix\":\"$OSS_PREFIX\",\"EncryptionType\":\"Inherit\"}" || true
    sleep 3
    api "$OUTDIR/02b-del-after.json" aliyun ecs DescribeCloudAssistantSettings --RegionId "$REGION" --SettingType.1 SessionManagerDelivery
    B2=$(jq -r '.OssDeliveryConfigs.OssDeliveryConfig[0].BucketName // ""' "$OUTDIR/02b-del-after.json" 2>/dev/null | tr -d '\r')
    [[ "$B2" == "$OSS_BUCKET" ]] && pass "会话录制已投递到 oss://$OSS_BUCKET/$OSS_PREFIX" \
      || fail "录制投递配置失败（BucketName=$B2）"
  fi
  say "  注：Bucket 必须与 ECS 同地域（否则报 InvalidOssBucketName.InOtherRegion）；本卡用 $REGION"
fi

# ---------------------------------------------------------------------------
step "2. ECS 实例 RAM 角色（跳板机不落长期凭据）"
if [[ "$DRY_RUN" == "1" || "$VERIFY_ONLY" == "1" ]]; then
  warn "（dry-run/verify）跳过 RAM 角色创建"
else
  api "$OUTDIR/03-role.json" aliyun ram CreateRole --RoleName "$RAM_ROLE" \
    --AssumeRolePolicyDocument '{"Version":"1","Statement":[{"Action":"sts:AssumeRole","Effect":"Allow","Principal":{"Service":["ecs.aliyuncs.com"]}}]}'
  jq -e '.Role.RoleName' "$OUTDIR/03-role.json" >/dev/null 2>&1 \
    && pass "RAM 角色 $RAM_ROLE 存在/已创建" \
    || warn "角色创建未确认（多为已存在）：$(head -c 120 "$OUTDIR/03-role.json" | tr -d '\n')"

  api "$OUTDIR/03-policy.json" aliyun ram CreatePolicy --PolicyName "$RAM_POLICY" \
    --PolicyDocument '{"Version":"1","Statement":[{"Effect":"Allow","Action":["cs:DescribeClusterUserKubeconfig","cs:DescribeClusterDetail","cs:DescribeClusterNodes","cs:ListClusterNodePools","cs:DescribeClusterLogs"],"Resource":["*"]}]}'
  jq -e '.Policy.PolicyName' "$OUTDIR/03-policy.json" >/dev/null 2>&1 \
    && pass "RAM 策略 $RAM_POLICY 已创建（仅 cs 只读换 kubeconfig）" \
    || warn "策略创建未确认（多为已存在）：$(head -c 120 "$OUTDIR/03-policy.json" | tr -d '\n')"

  api "$OUTDIR/03-attach.json" aliyun ram AttachPolicyToRole --RoleName "$RAM_ROLE" \
    --PolicyName "$RAM_POLICY" --PolicyType Custom \
    && pass "策略已绑定角色" || warn "策略绑定未确认（多为已绑定）：$(head -c 120 "$OUTDIR/03-attach.json" | tr -d '\n')"

  api "$OUTDIR/03-profile.json" aliyun ram CreateInstanceProfile --InstanceProfileName "$RAM_ROLE"
  api "$OUTDIR/03-addrole.json" aliyun ram AddRoleToInstanceProfile \
    --InstanceProfileName "$RAM_ROLE" --RoleName "$RAM_ROLE" \
    && pass "实例角色（InstanceProfile）就绪" || warn "AddRoleToInstanceProfile 未确认（多为已绑定）：$(head -c 120 "$OUTDIR/03-addrole.json" | tr -d '\n')"
fi

# ---------------------------------------------------------------------------
step "3. 跳板 ECS ${JUMP_NAME}（${INSTANCE_TYPE} / ${IMAGE_ID}）"
api "$OUTDIR/04-jump.json" aliyun ecs DescribeInstances --RegionId "$REGION" --PageSize 100
JUMP_ID=$(jq -r --arg n "$JUMP_NAME" '[.Instances.Instance[]?|select(.InstanceName==$n)][0].InstanceId // empty' \
          "$OUTDIR/04-jump.json" | tr -d '\r')

if [[ "$CLEANUP" == "1" ]]; then
  if [[ -z "$JUMP_ID" ]]; then warn "无 ${JUMP_NAME} 实例，无需删除"; else
    [[ "$DRY_RUN" == "1" ]] && warn "DRY_RUN：将删除 ECS $JUMP_ID" || {
      api "$OUTDIR/09-del-ecs.json" aliyun ecs DeleteInstance --RegionId "$REGION" --InstanceId "$JUMP_ID" --Force true \
        && pass "已删除 ECS $JUMP_ID"; }
  fi
  if [[ -n "$EDGE_SG" ]]; then
    [[ "$DRY_RUN" == "1" ]] && warn "DRY_RUN：将删除 SG $EDGE_SG" || {
      api "$OUTDIR/09-del-sg.json" aliyun ecs DeleteSecurityGroup --RegionId "$REGION" --SecurityGroupId "$EDGE_SG" \
        && pass "已删除安全组 $EDGE_SG" || warn "SG 删除失败（可能仍被占用）"; }
  fi
  say ""; say "证据目录：$OUTDIR"; exit 0
fi

if [[ -n "$JUMP_ID" ]]; then
  pass "跳板机已存在，复用：$JUMP_ID"
elif [[ "$DRY_RUN" == "1" || "$VERIFY_ONLY" == "1" ]]; then
  warn "跳板机未创建（dry-run/verify 模式不创建）"
else
  api "$OUTDIR/04-run.json" aliyun ecs RunInstances --RegionId "$REGION" \
    --InstanceType "$INSTANCE_TYPE" --ImageId "$IMAGE_ID" --Amount 1 \
    --InstanceName "$JUMP_NAME" --HostName "$JUMP_NAME" \
    --VSwitchId "$PUB_A" --SecurityGroupId "$EDGE_SG" \
    --InstanceChargeType PostPaid --InternetChargeType PayByTraffic \
    --InternetMaxBandwidthOut "$BW_OUT" \
    --SystemDisk.Category cloud_essd --SystemDisk.Size 40 \
    --KeyPairName "$KEYPAIR" --RamRoleName "$RAM_ROLE" \
    --ResourceGroupId "$RG" \
    --Tag.1.Key project --Tag.1.Value new-api \
    --Tag.2.Key site    --Tag.2.Value ph-mnl \
    --Tag.3.Key env     --Tag.3.Value prod \
    --Tag.4.Key role    --Tag.4.Value ops-jumphost
  JUMP_ID=$(jq -r '.InstanceIdSets.InstanceIdSet[0] // empty' "$OUTDIR/04-run.json" | tr -d '\r')
  [[ -n "$JUMP_ID" ]] && pass "已创建跳板机：$JUMP_ID" || { fail "RunInstances 失败：$(jq -r '.Message // "?"' "$OUTDIR/04-run.json")"; say "证据目录：$OUTDIR"; exit 1; }
fi

if [[ -n "$JUMP_ID" ]]; then
  say "等待 Running（最长 5 分钟）…"
  ST=Unknown
  for i in $(seq 1 30); do
    api "$OUTDIR/04-status.json" aliyun ecs DescribeInstances --RegionId "$REGION" --InstanceIds "[\"$JUMP_ID\"]"
    ST=$(jq -r '.Instances.Instance[0].Status // "Unknown"' "$OUTDIR/04-status.json" | tr -d '\r')
    JUMP_PUB=$(jq -r '.Instances.Instance[0].PublicIpAddress.IpAddress[0] // "-"' "$OUTDIR/04-status.json" | tr -d '\r')
    JUMP_PRV=$(jq -r '.Instances.Instance[0].VpcAttributes.PrivateIpAddress.IpAddress[0] // "-"' "$OUTDIR/04-status.json" | tr -d '\r')
    say "  [$i] Status=$ST pub=$JUMP_PUB prv=$JUMP_PRV"
    [[ "$ST" == "Running" ]] && break
    sleep 10
  done
  [[ "$ST" == "Running" ]] && pass "跳板机 Running（pub=$JUMP_PUB prv=$JUMP_PRV）" || fail "跳板机未 Running（$ST）"
fi

# ---------------------------------------------------------------------------
step "4. 装机（kubectl + aliyun CLI + 临时 kubeconfig 换票脚本）"
if [[ -n "$JUMP_ID" && "$DRY_RUN" != "1" && "$VERIFY_ONLY" != "1" ]]; then
  # ⚠️ 2026-09-29 回退：原 ENABLE_RECORDING=1 会在 /etc/profile.d/ 装一个
  #   `exec script ... >/dev/null 2>&1` 的 hook —— 它把登录 shell 整个替换掉且丢弃 stdout，
  #   导致「ssh 登录后无提示符、看起来卡死」。且会话录制已由 **ECS 会话管理**投递 OSS 覆盖，
  #   该 hook 属冗余且有害 → 本脚本不再安装，并主动清理历史残留（幂等）。
  REC_BLOCK='
# 清理历史遗留的录制 hook（有害：会让登录看起来卡死）
if [ -f /etc/profile.d/ops-record.sh ]; then rm -f /etc/profile.d/ops-record.sh; echo "[rec] 已移除历史 ops-record.sh hook"; fi
mkdir -p /var/log/ops-sessions && chmod 700 /var/log/ops-sessions
echo "[rec] 会话录制由 ECS 会话管理承担（投递 oss://'"$OSS_BUCKET"'/'"$OSS_PREFIX"'）"
'

  node_sh "05-provision" "set -u
set -x
# --- kubectl v1.35.0（与集群 1.35.7 同次版本，skew 合规）---
curl -sSLO https://dl.k8s.io/release/v1.35.0/bin/linux/amd64/kubectl && install -m 0755 kubectl /usr/local/bin/kubectl && rm -f kubectl
# --- aliyun CLI 3.5.1（企业版项目实测版本；用于经实例角色换取临时 kubeconfig）---
curl -sSL -o /tmp/aliyun-cli.tgz https://github.com/aliyun/aliyun-cli/releases/download/v3.5.1/aliyun-cli-linux-3.5.1-amd64.tgz \
  && tar -xzf /tmp/aliyun-cli.tgz -C /tmp \
  && install -m 0755 \$(find /tmp -maxdepth 2 -name 'aliyun' -type f | head -1) /usr/local/bin/aliyun \
  && rm -rf /tmp/aliyun-cli.tgz /tmp/aliyun-cli
# --- CLI 凭据模式：EcsRamRole（经实例元数据自取临时凭据，主机上不落 AK）---
# 实测坑（2026-09-29 第二次失败点）：只传 --region 不够，CLI 要求 default profile 已配置，
#   否则报 'profile default is not configure yet' → 必须显式 set 出 EcsRamRole 模式。
/usr/local/bin/aliyun configure set --profile default --mode EcsRamRole \
  --ram-role-name $RAM_ROLE --region $REGION --language en || true
/usr/local/bin/aliyun configure get --profile default | grep -E '"mode"|"region_id"|"ram_role_name"' || true
# --- 临时 kubeconfig 换票脚本（60 分钟有效期，不落长期凭据）---
cat > /usr/local/bin/newapi-kube <<'KUBEEOF'
#!/bin/bash
# 经 ECS 实例 RAM 角色换取 60 分钟临时 kubeconfig 并写入 ~/.kube/config
# 实测坑（2026-09-29 首跑失败点）：跳板机全新装机时 aliyun CLI 无默认 region，
#   不带 --region 会报 'region can't be empty / Configuration failed' → 必须显式传。
set -euo pipefail
REGION=\"\${REGION:-ap-southeast-6}\"
CLUSTER_ID=\"\${CLUSTER_ID:-cd57e40ce9a634c1698c2f5c5e09bd93c}\"
export ALIBABA_CLOUD_REGION_ID=\"\$REGION\"
mkdir -p \"\$HOME/.kube\"; chmod 700 \"\$HOME/.kube\"
tmp=\$(mktemp)
aliyun cs DescribeClusterUserKubeconfig --ClusterId \"\$CLUSTER_ID\" \
  --TemporaryDurationMinutes 60 --region \"\$REGION\" > \"\$tmp\"
if command -v jq >/dev/null 2>&1; then
  jq -r .config \"\$tmp\" > \"\$HOME/.kube/config\"
else
  python3 -c \"import json,sys;print(json.load(open(sys.argv[1]))['config'],end='')\" \"\$tmp\" > \"\$HOME/.kube/config\"
fi
rm -f \"\$tmp\"; chmod 600 \"\$HOME/.kube/config\"
echo \"kubeconfig 已刷新（60min）: \$HOME/.kube/config\"
KUBEEOF
chmod 0755 /usr/local/bin/newapi-kube
command -v jq >/dev/null 2>&1 || (yum install -y jq >/dev/null 2>&1 || dnf install -y jq >/dev/null 2>&1 || true)
command -v jq >/dev/null 2>&1 && echo '[dep] jq ok' || echo '[dep] jq MISSING（newapi-kube 将走 python3 回退）'
command -v python3 >/dev/null 2>&1 && echo '[dep] python3 ok' || echo '[dep] python3 MISSING'
echo '--- versions ---'
/usr/local/bin/kubectl version --client
/usr/local/bin/aliyun version | head -1
$REC_BLOCK
" && pass "装机完成" || fail "装机失败（见 out）"
else
  warn "跳过装机（无实例 / dry-run / verify）"
fi

# ---------------------------------------------------------------------------
step "5. 验证：实例角色凭据 + kubectl 经跳板机可达私网 API Server"
if [[ -n "$JUMP_ID" && "$DRY_RUN" != "1" ]]; then
  node_sh "06-verify" "set -u
export ALIBABA_CLOUD_REGION_ID=ap-southeast-6
echo '=== 实例角色身份（应为 assumed-role，而非任何 AK）==='
aliyun sts GetCallerIdentity --region ap-southeast-6 2>&1 | head -8 || echo 'aliyun cli 未就绪'
echo '=== 换取临时 kubeconfig ==='
/usr/local/bin/newapi-kube || exit 1
echo '=== kubectl 经跳板机访问集群 ==='
export KUBECONFIG=\$HOME/.kube/config
kubectl version 2>&1 | head -3
kubectl get ns
kubectl get ingressclass
kubectl auth whoami
rm -f \$HOME/.kube/config
echo '=== 会话录制状态 ==='
ls -ld /var/log/ops-sessions 2>/dev/null || echo 'recording: disabled'
" && pass "跳板机 → 集群链路验证通过" || fail "链路验证失败（见 out）"
else
  warn "跳过验证"
fi

step "6. 集群 RBAC：授权跳板机角色主体（跨集群授权必须用管理员身份，跳板机自身份无法自我授权）"
if [[ -n "$JUMP_ID" && "$DRY_RUN" != "1" ]]; then
  api "$OUTDIR/07-role-id.json" aliyun ram GetRole --RoleName "$RAM_ROLE"
  ROLE_ID=$(jq -r '.Role.RoleId // empty' "$OUTDIR/07-role-id.json" | tr -d '\r')
  if [[ -z "$ROLE_ID" ]]; then
    warn "取不到 $RAM_ROLE 的 RoleId，跳过 RBAC 绑定"
  else
    say "跳板机角色主体（K8s Username）= $ROLE_ID"
    api "$OUTDIR/07-adminkube.json" aliyun cs DescribeClusterUserKubeconfig \
      --ClusterId "$CLUSTER_ID" --TemporaryDurationMinutes 60
    jq -r '.config' "$OUTDIR/07-adminkube.json" > "$OUTDIR/adminkube.yaml" 2>/dev/null
    chmod 600 "$OUTDIR/adminkube.yaml"
    if [[ -s "$OUTDIR/adminkube.yaml" ]]; then
      node_sh "07-rbac" "set -u
um=\$(umask); umask 077; mkdir -p /tmp/rbac
cat > /tmp/rbac/kubeconfig <<'KCFG_EOF'
$(cat "$OUTDIR/adminkube.yaml")
KCFG_EOF
export KUBECONFIG=/tmp/rbac/kubeconfig
kubectl create clusterrolebinding newapi-ops-jumphost-cluster-admin \
  --clusterrole=cluster-admin --user=$ROLE_ID --dry-run=client -o yaml | kubectl apply -f -
kubectl get clusterrolebinding newapi-ops-jumphost-cluster-admin -o wide
rm -rf /tmp/rbac; umask \$um" \
        && pass "已绑定 cluster-admin（主体 $ROLE_ID，⚠ 见下方硬化说明）" || fail "RBAC 绑定失败"
      rm -f "$OUTDIR/adminkube.yaml"
    else
      fail "管理员 kubeconfig 签发失败，无法完成 RBAC 绑定"
    fi
  fi
fi

step "7. 复验（授权后跳板机自身份应可访问集群）"
if [[ -n "$JUMP_ID" && "$DRY_RUN" != "1" ]]; then
  node_sh "08-reverify" "set -u
export ALIBABA_CLOUD_REGION_ID=ap-southeast-6
/usr/local/bin/newapi-kube >/dev/null || exit 1
export KUBECONFIG=\$HOME/.kube/config
kubectl auth whoami
kubectl get ns
kubectl get ingressclass
rm -f \$HOME/.kube/config
echo '（临时 kubeconfig 已删除）'" \
    && pass "跳板机自身份已可用（任务 19 EXEC_MODE=ssh 的 kubectl 通道打通）" || fail "复验失败"
fi

step "8. 控制面复核：安全组入向收口（脚本自证，不信中间 PASS）"
if [[ -n "$EDGE_SG" && "$DRY_RUN" != "1" && "$VERIFY_ONLY" != "1" ]]; then
  api "$OUTDIR/09-sg-final.json" aliyun ecs DescribeSecurityGroupAttribute --RegionId "$REGION" --SecurityGroupId "$EDGE_SG"
  N_ING=$(jq -r '[.Permissions.Permission[]?|select(.Direction=="ingress")]|length' "$OUTDIR/09-sg-final.json" | tr -d '\r')
  N_OPEN=$(jq -r '[.Permissions.Permission[]?|select(.Direction=="ingress" and .SourceCidrIp=="0.0.0.0/0")]|length' "$OUTDIR/09-sg-final.json" | tr -d '\r')
  say "入向规则数=$N_ING（期望 ≥2×CIDR 数）  0.0.0.0/0 条数=$N_OPEN（期望 0）"
  jq -r '.Permissions.Permission[]?|select(.Direction=="ingress")|"  \(.IpProtocol) \(.PortRange) ← \(.SourceCidrIp)  [\(.Description // "-")]"' \
    "$OUTDIR/09-sg-final.json" >&3
  if [[ "${ENABLE_SSH_ALLOWLIST:-0}" == "1" ]]; then
    [[ "${N_ING:-0}" -ge 2 ]] && pass "入向规则已落地（SSH 白名单模式）" || fail "入向规则缺失（跳板机不可 SSH）"
  else
    [[ "${N_ING:-1}" == "0" ]] && pass "零入向端口（入口由会话管理+RAM 身份承担）" \
      || warn "入向规则数=${N_ING}（期望 0；若为 deploy/ops/ops-access.sh 的临时 SSH 规则属预期）"
  fi
  [[ "${N_OPEN:-1}" == "0" ]] && pass "无 0.0.0.0/0 入向" || fail "存在 0.0.0.0/0 入向（违反最小开放原则）"
fi

step "完成"
say "证据目录：$OUTDIR"
say "PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
say "JUMP_ID=${JUMP_ID:-<无>}   JUMP_PUB=${JUMP_PUB:-<无>}   JUMP_PRV=${JUMP_PRV:-<无>}   EDGE_SG=${EDGE_SG:-<无>}"
say ""
say "人工运维入口（动态出口 IP 下的推荐方式）："
say "  ① 主通道 · ECS 会话管理（零入向端口 / RAM 身份 / 会话录制→OSS）："
say "     控制台 → 云服务器 ECS → 实例 ${JUMP_ID:-<id>} → 远程连接 → 会话管理"
say "     登录后：newapi-kube && kubectl get pods -n new-api"
say "     状态复核：bash deploy/ops/ops-access.sh --status"
say "  ② 辅通道 · 按需临时 SSH（仅需原生 ssh/scp 时）："
say "     bash deploy/ops/ops-access.sh --allow-ssh --ttl-min 120   # 放行本机当前出口 IP 的 22"
say "     ssh -i <newapi-mnl.pem> root@${JUMP_PUB:-<公网IP>}"
say "     bash deploy/ops/ops-access.sh --deny-ssh                  # 用完立即回收"
say ""
say "回跑任务 19（经跳板机执行，SSH 模式）："
say "  JUMP_HOST=<跳板机公网IP> JUMP_KEY=<私钥> OFFICE_CIDR 内的机器上执行："
say "  JUMP_HOST=<ip> JUMP_USER=root JUMP_KEY=<key> SELFTEST=1 bash deploy/task19/alb_mnl.sh"
[[ "$FAIL" -eq 0 ]] && say "结论：任务 46（方案 B）通过（未决 WARN 需人工确认）" || say "结论：存在 FAIL，需处理后复跑"
