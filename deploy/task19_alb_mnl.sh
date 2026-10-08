#!/usr/bin/env bash
# =============================================================================
# Day 2 · 任务 19｜马尼拉 ALB + AlbConfig + 健康检查
# 参考：deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md §6.3（L2263-2358）
# 渲染件：deploy/aliyun/ph/albconfig.rendered.yaml
#         deploy/aliyun/ph/placeholder-svc-ingress.yaml
#
# 幂等：可重复执行；AlbConfig/IngressClass/Service/Ingress 均为声明式 apply。
# 用法（默认走自建跳板机；需先完成任务 46）：
#   JUMP_HOST=<ip> JUMP_KEY=<key.pem> CERT_ID_ALB=<cas-cert-id> \
#     bash deploy/task19_alb_mnl.sh                           # 正规路径（跳板机 + 443 + 80）
#   ... bash deploy/task19_alb_mnl.sh --without-tls            # 仅 80 监听（降级，需显式确认）
#   DRY_RUN=1 bash deploy/task19_alb_mnl.sh                    # 只渲染与前置检查，不调用写 API
#   SELFTEST=1 bash deploy/task19_alb_mnl.sh                   # 仅验证执行通道（只读，不碰资源）
#   ... bash deploy/task19_alb_mnl.sh --cleanup                # 删除占位 Service/Ingress（任务 23 前）
#
# 执行通道（决策留痕 2026-09-29）：马尼拉 ACK **只有私网 API Server 端点**
#   （10.0.22.182:6443，endpoint_public_access=false），本机在 VPC 外无法直连。
#   项目负责人已定：**运维通道必须走任务 46 的自建跳板机（方案 B），不接受临时公网端点、
#   不把云助手作为默认通道**。故本脚本：
#   EXEC_MODE=ack-remote（2026-09-30 起默认）→ 经 deploy/ack_remote.sh（云助手 + worker 节点内 kubectl）
#     —— 本会话 09-29/30 已用该通道完成任务 17/22/9 的全部集群内操作（RRSA 注入、10250 修复、CK 验证），
#        事实上的标准通道；任务 46 跳板机交付后可切回 ssh 合规路径。决策留痕：用户知情并默认采纳。
#     EXEC_MODE=ssh（任务 46 就绪后的合规路径）  → 经跳板机 SSH 执行 kubectl
#     EXEC_MODE=cloud-assistant（需显式勾选）  → 经 ECS 云助手在**跳板机**执行，
#                                                属对 §8.5 的临时偏差，仅用于任务 46 未就绪时的应急
#   两种模式都把 60 分钟临时 kubeconfig 注入远端并在结束后删除。
#   前置：EXEC_MODE=ssh 需任务 46 已交付（bash deploy/task46_jumphost.sh；JUMP_HOST/JUMP_KEY）。
#   ① 首次使用前须把跳板机 host key 固化进 ~/.ssh/known_hosts（ssh-keyscan 取回后**人工比对指纹**）；
#      禁止把 SSH_OPTS 改成 StrictHostKeyChecking=no 绕过校验（§8.5 变更审批要求）。
#   ② 发起 SSH 的机器出口 IP 必须在 sg-mnl-alb-edge 的 OFFICE_CIDR 内（跳板机被纳管前无法用云助手代替人工核验）。
#
# 前置（2026-09-29 CLI 实测）：
#   ✅ ACK mnl cd57e40ce9a634c1698c2f5c5e09bd93c running / 1.35.7 / Terway / 4×worker 跨 6a·6b
#   ✅ vsw-mnl-pub-a vsw-5ts9tgdq1xz3picjgoqyu (6a, free=251) / pub-b vsw-5ts1dygyh2x0daspwny2r (6b, free=252)
#   ✅ alb-ingress-controller 曾于 2026-09-30 运行并成功建出 ALB；⚠ **2026-10-05 复测：集群内已无任何
#      alb Pod/Deployment（云端 addon 元数据仍报 active v3.1.1，实际未运行）→ 本卡执行前须先修复组件**，
#      否则 443 监听/健康检查注解无人 reconcile（详见 deploy/Day2任务19_ALB_执行报告.md §三③）
#   ✅ AlbConfig/ALB CRD 就绪；⚠ 09-30 已建出 AlbConfig `mnl-alb` + ALB `alb-1riqckb1h8ezm0y7s9`
#      （Active，双 AZ，访问日志 sls-newapi-mnl/alb_access）+ IngressClass `alb` + 占位 svc/ingress
#      ⇒ **非干净底座**：脚本 apply 会就地更新既有 AlbConfig（幂等），勿当成"全新建"
#   ✅ sls-newapi-mnl 项目与 alb_access Logstore 已存在（⚠ webhook 强制 logstore 名以 alb_ 开头；旧 alb-access 不合规，2026-09-30 已建 alb_access）
#   ❌ 任务 46 跳板机未交付 → EXEC_MODE=ssh 无法执行（本脚本默认模式，退出码 4）
#   ❌ AliyunServiceRoleForAlb 服务关联角色不存在（建 ALB 前需先建）
#   ❌ new-api namespace 不存在（任务 17 交付物；脚本幂等创建并留痕）
#   ❌ CERT_ID_ALB 不存在：CAS TotalCount=0，且 likha.hk NS 仍在 GoDaddy（G4/G5 未闭环）
#   ❌ SESSION/… 均无；本卡依赖的 G4(NS)→G5(证书 DCV) 链条未闭环
#
# 实现注意：日志走 fd 3，API 原始输出落文件（避免污染 JSON）；写操作统一 3 次重试
#           （ap-southeast-6 端点偶发 timeout，见任务 6 实测）。
# =============================================================================
set -uo pipefail
exec 3>&2

REGION=ap-southeast-6
CLUSTER_ID=cd57e40ce9a634c1698c2f5c5e09bd93c
NS=new-api
ALBCONFIG=mnl-alb
ALB_NAME=alb-newapi-mnl
PUB_A=vsw-5ts9tgdq1xz3picjgoqyu
PUB_B=vsw-5ts1dygyh2x0daspwny2r
CERT_ID_ALB="${CERT_ID_ALB:-}"
EXEC_MODE="${EXEC_MODE:-ssh}"                 # ssh（默认，合规） | cloud-assistant（应急，须显式）
JUMP_HOST="${JUMP_HOST:-}"                    # 任务 46 产出：自建跳板机公网 IP
JUMP_USER="${JUMP_USER:-root}"
JUMP_KEY="${JUMP_KEY:-}"                      # SSH 私钥路径（不入 Git）
JUMP_PORT="${JUMP_PORT:-22}"
JUMP_INSTANCE_ID="${JUMP_INSTANCE_ID:-}"      # cloud-assistant 模式的执行目标（必须是跳板机，不得是 prod ACK 节点）
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=yes -o ConnectTimeout=10}"
NODE_CMD_TIMEOUT="${NODE_CMD_TIMEOUT:-300}"
WITHOUT_TLS=0
CLEANUP=0
DRY_RUN="${DRY_RUN:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --without-tls) WITHOUT_TLS=1 ;;
    --cleanup)     CLEANUP=1 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
  shift
done

HERE="$(cd "$(dirname "$0")" && pwd)"
TS=$(date +%Y%m%d-%H%M%S)
OUTDIR="$HERE/logs/task19_${TS}"
mkdir -p "$OUTDIR"

say()  { printf '%s\n' "$*" >&3; }
hr()   { say "------------------------------------------------------------"; }
step() { say ""; say ">>> $*"; hr; }
pass() { say "  [PASS] $*"; PASS=$((PASS+1)); }
warn() { say "  [WARN] $*"; WARN=$((WARN+1)); }
fail() { say "  [FAIL] $*"; FAIL=$((FAIL+1)); }
PASS=0; WARN=0; FAIL=0

# api <outfile> <cmd...> —— 日志到 fd3，输出落文件；非 JSON 或失败自动重试 3 次
# 注意：只用于**读**调用。写调用由调用点按 DRY_RUN 显式短路（DRY_RUN 仍会跑全部读检查）。
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

# ---------------------------------------------------------------------------
step "0. 身份与执行通道"
api "$OUTDIR/00-identity.json" aliyun sts GetCallerIdentity
ACCOUNT=$(jq -r '.AccountId // empty' "$OUTDIR/00-identity.json" 2>/dev/null | tr -d '\r')
say "AccountId=${ACCOUNT:-<失败>}（期望 5108890064395960）"
[[ "$ACCOUNT" == "5108890064395960" ]] && pass "账号正确" || fail "账号异常，终止"

case "$EXEC_MODE" in
  ack-remote)
    say "EXEC_MODE=ack-remote（deploy/ack_remote.sh：云助手 → worker 节点内 kubectl，临时 kubeconfig 用完即删）"
    # ack_remote.sh 自带 worker 枚举（worker-k8s-for-cs- 前缀动态发现），无需实例参数
    ACK_REMOTE=/tmp/ack_remote.sh
    tr -d '\r' < "$HERE/ack_remote.sh" > "$ACK_REMOTE" && chmod +x "$ACK_REMOTE" \
      || { fail "ack_remote.sh 转换失败"; exit 1; }
    pass "ack_remote.sh 已就位（/tmp/ack_remote.sh）"
    ;;
  ssh)
    say "EXEC_MODE=ssh（合规路径：经任务 46 自建跳板机执行，VPC 内 + 私网端点）"
    if [[ -z "$JUMP_HOST" || -z "$JUMP_KEY" ]]; then
      fail "跳板机未就绪：缺少 JUMP_HOST / JUMP_KEY（任务 46 交付物）"
      say "   决策留痕（2026-09-29）：负责人已定运维通道=自建跳板 ECS（方案 B，原方案 A 云堡垒机因成本否决）。"
      say "   不允许临时开 API Server 公网端点；云助手通道仅为应急，须显式 EXEC_MODE=cloud-assistant ALLOW_CLOUD_ASSISTANT=1 且 JUMP_INSTANCE_ID 指向跳板机。"
      say "   解除阻塞：先完成任务 46（bash deploy/task46_jumphost.sh），再回跑本脚本。"
      say ""
      say "证据目录：$OUTDIR"
      exit 4
    fi
    pass "跳板机参数已提供：${JUMP_USER}@${JUMP_HOST}:${JUMP_PORT}"
    ;;
  cloud-assistant)
    [[ "${ALLOW_CLOUD_ASSISTANT:-0}" == "1" ]] || {
      fail "EXEC_MODE=cloud-assistant 属应急通道（不经 SSH、无会话录制），须显式 ALLOW_CLOUD_ASSISTANT=1"
      say ""; say "证据目录：$OUTDIR"; exit 4
    }
    if [[ -z "$JUMP_INSTANCE_ID" ]]; then
      fail "EXEC_MODE=cloud-assistant 必须指定 JUMP_INSTANCE_ID（**不得**用 prod ACK 节点承载 kubectl）"
      say ""; say "证据目录：$OUTDIR"; exit 4
    fi
    warn "EXEC_MODE=cloud-assistant：经 ECS 云助手在跳板机 $JUMP_INSTANCE_ID 执行（应急通道，须在证据链留痕）"
    pass "应急执行目标已指定（跳板机实例）"
    ;;
  *)
    fail "未知 EXEC_MODE=$EXEC_MODE（合法值：ssh | cloud-assistant）"
    ;;
esac
[[ "$FAIL" -eq 0 ]] || { say "!! 前置失败，终止"; exit 1; }

# 60 分钟临时 kubeconfig（私网端点）
api "$OUTDIR/00c-kubeconfig.json" aliyun cs DescribeClusterUserKubeconfig \
  --ClusterId "$CLUSTER_ID" --TemporaryDurationMinutes 60
jq -r '.config' "$OUTDIR/00c-kubeconfig.json" > "$OUTDIR/kubeconfig.yaml" 2>/dev/null
if [[ -s "$OUTDIR/kubeconfig.yaml" ]]; then
  chmod 600 "$OUTDIR/kubeconfig.yaml"; pass "临时 kubeconfig 已签发（60min，私网 10.0.22.182:6443）"
else
  fail "kubeconfig 签发失败，终止"; exit 1
fi

# exec_sh <name> <script> —— 按 EXEC_MODE 在远端执行 script（stdin 传脚本），输出落 $OUTDIR/<name>.out
exec_sh() {
  local name="$1" script="$2" rc
  if [[ "$DRY_RUN" == "1" ]]; then printf '(dry-run)\n' > "$OUTDIR/$name.out"; return 0; fi
  case "$EXEC_MODE" in
    ssh)
      printf '+ [ssh %s@%s] %s …\n' "$JUMP_USER" "$JUMP_HOST" "$name" >&3
      printf '%s' "$script" | ssh $SSH_OPTS -p "$JUMP_PORT" -i "$JUMP_KEY" \
        "$JUMP_USER@$JUMP_HOST" 'bash -s' > "$OUTDIR/$name.out" 2>&1
      rc=$?
      say "  ssh 执行退出码=$rc"
      cat "$OUTDIR/$name.out" >&3
      return $rc
      ;;
    cloud-assistant) run_cloud_assistant "$name" "$script" ;;
    ack-remote)
      local bodyf="$OUTDIR/$name.body.sh" try rc
      printf '%s' "$script" > "$bodyf"
      # ⚠ VPC 端点偶发抖动（项目铁律：写操作重试 ≥3 次）；ack_remote.sh 内部无重试 → 此处兜底
      for try in 1 2 3; do
        printf '+ [ack-remote %s] 第 %s 次尝试 …\n' "$name" "$try" >&3
        # 第 4 参 LOOPS=100（500s）：apply-main 内部等 AlbConfig ready 最长 300s，默认 24×5=120s 必超时（2026-09-30 实测）
      bash "$ACK_REMOTE" mnl "$bodyf" "" 100 > "$OUTDIR/$name.out" 2>&1
        rc=$?
        [[ $rc -eq 0 ]] && break
        say "  第 ${try} 次退出码=$rc，3s 后重试"
        sleep 3
      done
      say "  ack-remote 执行退出码=$rc"
      cat "$OUTDIR/$name.out" >&3
      return $rc
      ;;
    *) say "  !! 未知 EXEC_MODE=$EXEC_MODE"; return 1 ;;
  esac
}

# run_cloud_assistant <name> <script> —— 经 ECS 云助手在**跳板机**执行（应急通道）
run_cloud_assistant() {
  local name="$1" script="$2" b64 inv st i
  # ⚠ base64 可移植性：GNU 支持 `base64 -w0`，BSD/macOS 不支持（会静默产出空 Body）
  b64=$(printf '%s' "$script" | python3 -c "import base64,sys;sys.stdout.write(base64.b64encode(sys.stdin.buffer.read()).decode())")
  [ -n "$b64" ] || { say "  !! base64 编码为空，终止"; return 1; }
  printf '+ [cloud-assistant %s] %s …\n' "$JUMP_INSTANCE_ID" "$name" >&3
  inv=$(api "$OUTDIR/$name.invoke.json" aliyun ecs RunCommand --RegionId "$REGION" \
          --Type RunShellScript --InstanceId.1 "$JUMP_INSTANCE_ID" \
          --ContentEncoding Base64 --CommandContent "$b64" --Timeout "$NODE_CMD_TIMEOUT" \
        && jq -r '.InvokeId // empty' "$OUTDIR/$name.invoke.json" | tr -d '\r')
  [[ -n "$inv" ]] || { say "  !! RunCommand 未返回 InvokeId"; return 1; }
  for i in $(seq 1 60); do
    api "$OUTDIR/$name.result.json" aliyun ecs DescribeInvocationResults --RegionId "$REGION" --InvokeId "$inv" || true
    st=$(jq -r '.Invocation.InvocationResults.InvocationResult[0].InvocationStatus // "Unknown"' \
         "$OUTDIR/$name.result.json" 2>/dev/null | tr -d '\r')
    [[ "$st" =~ ^(Success|Failed|Timeout|PartialFailed)$ ]] && break
    sleep 5
  done
  jq -r '.Invocation.InvocationResults.InvocationResult[0].Output // ""' "$OUTDIR/$name.result.json" \
    2>/dev/null | base64 -d > "$OUTDIR/$name.out" 2>/dev/null || : > "$OUTDIR/$name.out"
  say "  node 执行状态=$st"
  cat "$OUTDIR/$name.out" >&3
  [[ "$st" == "Success" ]]
}

# kubectl_prelude —— 注入临时 kubeconfig 的固定前置（umask 077，用完删除）
# ⚠ ack-remote 模式：ack_remote.sh 已在节点注入 KUBECONFIG（/tmp/k8s/kubeconfig），
#   body 内再嵌一份既冗余又会撑爆 RunCommand 16KB 级内容上限（CmdContent.ExceedLimit，2026-09-30 实测）
kubectl_prelude() {
  if [[ "$EXEC_MODE" == "ack-remote" ]]; then
    cat <<'PRE'
set -u
um=$(umask)
printf '[prelude] KUBECONFIG is provided by ack_remote.sh\n'
PRE
    return 0
  fi
  cat <<KCFG
set -u
um=\$(umask); umask 077
mkdir -p /tmp/task19
cat > /tmp/task19/kubeconfig <<'KCFG_EOF'
$(cat "$OUTDIR/kubeconfig.yaml")
KCFG_EOF
export KUBECONFIG=/tmp/task19/kubeconfig
KCFG
}
kubectl_epilogue() { printf 'rc=$?\nrm -rf /tmp/task19\numask $um\nexit $rc\n'; }

# node_k8s <name> <shell 语句（多行，须自行带 kubectl 前缀）> —— 在 VPC 节点内执行，退出码回传
node_k8s() {
  local name="$1" body="$2"
  exec_sh "$name" "$(kubectl_prelude)
$body
$(kubectl_epilogue)"
}

# SELFTEST=1：只验证「云助手 + 临时 kubeconfig」执行通道（全部只读），不碰任何资源
if [[ "${SELFTEST:-0}" == "1" ]]; then
  step "selftest：验证执行通道（EXEC_MODE=$EXEC_MODE）+ 临时 kubeconfig（只读）"
  node_k8s "selftest" 'kubectl version
kubectl auth whoami
kubectl get ns
kubectl get ingressclass
kubectl get crd | grep -c alibabacloud.com || true' \
    && pass "执行通道 OK" || fail "执行通道失败"
  say ""; say "证据目录：$OUTDIR"; exit 0
fi

# ---------------------------------------------------------------------------
step "2. 前置复核（网络 / 组件 / 服务关联角色 / 证书）"
api "$OUTDIR/02-vsw.json" aliyun vpc DescribeVSwitches --RegionId "$REGION" --VpcId vpc-5tst1tgeessxn1azwasg2 --PageSize 20
for v in "$PUB_A" "$PUB_B"; do
  free=$(jq -r --arg v "$v" '[.VSwitches.VSwitch[]?|select(.VSwitchId==$v)][0].AvailableIpAddressCount // empty' "$OUTDIR/02-vsw.json" | tr -d '\r')
  if [[ -n "$free" && "$free" -gt 20 ]]; then pass "vSwitch $v free=$free"; else fail "vSwitch $v 不可用或 IP 不足（free=${free:-?}）"; fi
done

api "$OUTDIR/02-addons.json" aliyun cs ListClusterAddonInstances --cluster_id "$CLUSTER_ID"
albstate=$(jq -r '[.addons[]?|select(.name=="alb-ingress-controller")][0]|"\(.state):\(.version)"' "$OUTDIR/02-addons.json" 2>/dev/null | tr -d '\r')
if [[ "$albstate" == active:* ]]; then pass "alb-ingress-controller $albstate（指南步骤 1 已完成，仅复核）"; else fail "alb-ingress-controller 未就绪（$albstate）"; fi

api "$OUTDIR/02-slr.json" aliyun ram GetRole --RoleName AliyunServiceRoleForAlb
if jq -e '.Role.RoleName' "$OUTDIR/02-slr.json" >/dev/null 2>&1; then
  pass "服务关联角色 AliyunServiceRoleForAlb 存在"
else
  warn "服务关联角色 AliyunServiceRoleForAlb 不存在 → 建 ALB 前需创建（ram:CreateServiceLinkedRole）"
  if [[ "${CREATE_SLR:-0}" == "1" && "$DRY_RUN" != "1" ]]; then
    api "$OUTDIR/02-slr-create.json" aliyun ram CreateServiceLinkedRole --ServiceName alb.aliyuncs.com \
      && say "  已提交创建服务关联角色（如报权限不足，请用 admin/ops 身份补授权）"
  else
    say "  （默认不代建；确认后用 CREATE_SLR=1 重跑，或在控制台/首次创建 ALB 时自动创建）"
  fi
fi

if [[ -n "$CERT_ID_ALB" ]]; then
  pass "CERT_ID_ALB=$CERT_ID_ALB（将创建 80 + 443 双监听）"
elif [[ "$WITHOUT_TLS" == "1" ]]; then
  warn "未提供 CERT_ID_ALB 且显式 --without-tls：将**只创建 80 监听**（无 TLS，仅内部验证用，任务 40 补齐）"
else
  fail "CERT_ID_ALB 未提供：443 监听无法创建（G5 证书未闭环，CAS TotalCount=0）"
  say ""
  say "  阻塞说明："
  say "   · aliyun cas ListUserCertificateOrder → TotalCount=0（账号内无任何证书）"
  say "   · dig NS likha.hk → ns21/ns22.domaincontrol.com（GoDaddy），G4「NS 指向阿里云」亦未闭环"
  say "   · 影响：443 监听、TLS 策略、证书链、SNI 反例四项验收（指南 V1/V3/V4 及部分 V2）全部无法执行"
  say "  处置：① 先闭环 G4+G5（购买付费通配符 *.likha.hk 并完成 DCV）后重跑本脚本；或"
  say "        ② 显式接受降级：bash deploy/task19_alb_mnl.sh --without-tls （仅建 ALB + 80 监听）"
  say ""
  say "证据目录：$OUTDIR"
  exit 3
fi

# ---------------------------------------------------------------------------
step "3. 渲染清单（真实 ID 回填 + 证书分支）"
RENDERED="$OUTDIR/albconfig.applied.yaml"
# ⚠ /mnt/e 下文本是 CRLF：awk 的 /^    - port: 443$/ 会因 \r 匹配失败、整段剔除静默落空（2026-09-30 实测）→ 先归一
tr -d '\r' < "$HERE/aliyun/ph/albconfig.rendered.yaml" > "$OUTDIR/albconfig.tpl.yaml"
if [[ -n "$CERT_ID_ALB" ]]; then
  CERT_ID_ALB="$CERT_ID_ALB" envsubst < "$OUTDIR/albconfig.tpl.yaml" > "$RENDERED"
else
  # --without-tls：剔除 443 监听整段（保持 AlbConfig 语法合法）
  awk '
    /^    - port: 443$/ {skip=1}
    skip && /^---$/ {skip=0}
    skip {next}
    {print}
  ' "$OUTDIR/albconfig.tpl.yaml" | envsubst > "$RENDERED"
fi
grep -q 'port: 443' "$RENDERED" && say "  渲染含 443 监听" || say "  渲染不含 443 监听（--without-tls 降级）"
python3 -c "import sys,yaml" 2>/dev/null && \
  python3 -c "import yaml,sys; list(yaml.safe_load_all(open('$RENDERED'))); print('  YAML 语法校验：通过')" >&3 || say "  （本机无 pyyaml，跳过本地 YAML 校验）"

if [[ "$DRY_RUN" == "1" ]]; then
  say ""; say "(DRY_RUN 结束 — 未执行任何写操作)"; say "渲染件：$RENDERED"; exit 0
fi

step "4. 经云助手在 VPC 节点执行 kubectl apply（临时 kubeconfig，用完即删）"
node_k8s "04-apply-ns" "kubectl create ns $NS --dry-run=client -o yaml | kubectl apply -f -" \
  && pass "namespace/$NS 就绪" || fail "namespace 创建失败"

if [[ "$CLEANUP" == "1" ]]; then
  node_k8s "04-cleanup" "um=\$(umask); umask 077
mkdir -p /tmp/task19
kubectl -n $NS delete -f - --ignore-not-found <<'YAML_EOF'
$(cat "$HERE/aliyun/ph/placeholder-svc-ingress.yaml")
YAML_EOF
rm -rf /tmp/task19; umask \$um" && pass "占位 Service/Ingress 已删除" || fail "占位资源删除失败"
  say ""; say "证据目录：$OUTDIR"; exit 0
fi

node_k8s "04-apply-main" "um=\$(umask); umask 077
mkdir -p /tmp/task19
cat > /tmp/task19/albconfig.yaml <<'YAML_EOF'
$(cat "$RENDERED")
YAML_EOF
cat > /tmp/task19/placeholder.yaml <<'YAML_EOF'
$(cat "$HERE/aliyun/ph/placeholder-svc-ingress.yaml")
YAML_EOF
echo '--- apply AlbConfig + IngressClass ---'
kubectl apply -f /tmp/task19/albconfig.yaml
echo '--- apply 占位 Service + 验证 Ingress ---'
kubectl apply -f /tmp/task19/placeholder.yaml
echo '--- 等待 AlbConfig ready（最长 5min）---'
for i in \$(seq 1 60); do
  st=\$(kubectl -n $NS get albconfig $ALBCONFIG -o jsonpath='{.status.loadBalancer.id}' 2>/dev/null)
  echo \"  [\$i] alb.id=\${st:-<pending>}\"
  [ -n \"\$st\" ] && break
  sleep 5
done
kubectl -n $NS get albconfig $ALBCONFIG -o yaml | head -60
rm -rf /tmp/task19
umask \$um" && pass "AlbConfig/IngressClass/占位资源已 apply" || fail "apply 失败（详见 out 文件）"

step "5. 验证 V1–V5（控制面用 ALB OpenAPI，数据面用节点内 kubectl）"
api "$OUTDIR/05-alb.json" aliyun alb ListLoadBalancers --RegionId "$REGION"
ALB_ID=$(jq -r --arg n "$ALB_NAME" '[.LoadBalancers[]?|select(.LoadBalancerName==$n)][0].LoadBalancerId // empty' "$OUTDIR/05-alb.json" | tr -d '\r')
ALB_DNS=$(jq -r --arg n "$ALB_NAME" '[.LoadBalancers[]?|select(.LoadBalancerName==$n)][0].DNSName // empty' "$OUTDIR/05-alb.json" | tr -d '\r')
if [[ -n "$ALB_ID" ]]; then pass "V1 ALB 已创建 ${ALB_ID} dns=${ALB_DNS}"; else fail "V1 ALB 未创建（看 04-apply-main.out 事件）"; fi

if [[ -n "$ALB_ID" ]]; then
  api "$OUTDIR/05-alb-attr.json" aliyun alb GetLoadBalancerAttribute --LoadBalancerId "$ALB_ID"
  zones=$(jq -r '[.ZoneMappings[]?.ZoneId]|join(",")' "$OUTDIR/05-alb-attr.json" 2>/dev/null | tr -d '\r')
  say "  ZoneMappings=$zones（期望含 ap-southeast-6a 与 6b）"
  [[ "$zones" == *6a* && "$zones" == *6b* ]] && pass "V1b 双可用区绑定" || fail "V1b 未跨 2 AZ"
  api "$OUTDIR/05-listeners.json" aliyun alb ListListeners --LoadBalancerIds.1 "$ALB_ID"
  jq -r '.Listeners[]?|"  listener \(.ListenerPort)/\(.ListenerProtocol)  idle=\(.IdleTimeout // "-")  req=\(.RequestTimeout // "-")  cert=\(.Certificates[0].CertificateId // "-")"' "$OUTDIR/05-listeners.json" >&3
  api "$OUTDIR/05-alb-acl.json" aliyun alb ListAclRelations --LoadBalancerIds.1 "$ALB_ID" || true
  if [[ -n "$CERT_ID_ALB" ]]; then
    n443=$(jq -r '[.Listeners[]?|select(.ListenerPort==443)]|length' "$OUTDIR/05-listeners.json" | tr -d '\r')
    [[ "$n443" == "1" ]] && pass "V3 443 监听存在" || fail "V3 443 监听缺失"
  fi
fi

node_k8s "05-k8s" "kubectl -n $NS get albconfig,ingressclass,svc,ingress -o wide" \
  && pass "V5 K8s 侧对象已落地" || fail "K8s 侧查询失败"
node_k8s "05-ingress-events" "echo '=== 健康检查后端（0 endpoints 属预期，见占位件偏差②）==='
kubectl -n $NS get ingress new-api-verify -o jsonpath='{.status.loadBalancer.ingress}{\"\\n\"}' 2>/dev/null"

step "完成"
say "证据目录：$OUTDIR"
say "PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
say "ALB_ID=${ALB_ID:-<无>}   ALB_DNS=${ALB_DNS:-<无>}"
[[ "$FAIL" -eq 0 ]] && say "结论：任务 19 通过（未决 WARN 需人工确认）" || say "结论：存在 FAIL，任务 19 未通过"
