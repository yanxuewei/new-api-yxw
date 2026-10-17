#!/usr/bin/env bash
# jkt-dev-remediate.sh —— 雅加达 dev 集群空转整改（默认 DRY-RUN，必须 APPLY=1 才写）
#
# 🔴 **2026-10-17 18:0x：本脚本全部步骤作废，勿再 APPLY。** 负责人已直接重建节点池：
#   现池 `np72446b422a6441c0bc96762a796aed26`（np-jkt-dev-x4c）= 单一 ecs.g9i.xlarge、
#   auto_scaling.enable=true 且 min=max=2、伸缩组 asg-k1adh3qjtrpnr4gnzfs1、伸缩配置 asc-k1ahcn6v6rivopmjugy6。
#   ⇒ S1（定期望节点数）、S2、S4（换机型）已由重建本身完成；S3 早先按官方证据定为禁用；
#   S5（按 P95 降 requests）前提不成立。保留本文件只为留下「当时打算怎么写」的记录。
#   现池实况与计费方式（按量 vs 包年包月）单价实测见台账 §11.2.2、取证文档 §八。
#
# 取证结论（2026-10-17 实测，见 docs/雅加达dev集群空转与Pod上限_取证与整改_2026-10-17.md）：
#   · 节点池 auto_scaling.enable=false + desired_size=4 ⇒ 固定 4 台常驻，min=1/max=3 不生效
#   · 4 台全是 2C8G 按量，物理 CPU<5%；单台 Pod 上限 15 = (3-1)×6+3（g9i/g9ae.large 的 ENI 配额）
#   · 各节点辅助 IP=0 ⇒ 15 从未被触及，Pod 上限不是当前瓶颈
#   · 10-16 15:35Z→23:37Z 连续 9 次扩容失败原因 = Account.Arrearage（账户欠费）
#
# 用法：
#   bash deploy/scripts/jkt-dev-remediate.sh              # 只打印将要执行的写操作
#   APPLY=1 bash deploy/scripts/jkt-dev-remediate.sh S1   # 真跑某一步
#   DESIRED=2 APPLY=1 bash deploy/scripts/jkt-dev-remediate.sh S1
#
# ⚠ 标 [待实测] 的调用未在账号上执行过，APPLY 前请先看 DRY-RUN 输出并确认参数形态。
set -uo pipefail

[ -d "$HOME/.workbuddy/binaries/aliyun-cli" ] && \
  case ":$PATH:" in *":$HOME/.workbuddy/binaries/aliyun-cli:"*) ;; *) export PATH="$HOME/.workbuddy/binaries/aliyun-cli:$PATH" ;; esac
command -v aliyun >/dev/null 2>&1 || { echo "[!] aliyun CLI 不在 PATH"; exit 1; }

REGION="${REGION:-ap-southeast-5}"
CID="${CID:-cb0abf5bc06034f7bbdb991752f6f3e62}"
POOL="${POOL:-npd3cc9d7f0503472f85420d30436269b5}"
ASG="${ASG:-asg-k1a59qtckc246wh9r3ay}"
SC_CFG="${SC_CFG:-asc-k1a93mabivq2ddxe93ho}"   # 实测 DescribeScalingConfigurations 回读
DESIRED="${DESIRED:-2}"                          # 目标常驻节点数
APPLY="${APPLY:-0}"
STEP="${1:-all}"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
run() {  # run <描述> <命令...>
  local desc="$1"; shift
  say "  · $desc"
  printf '      %s\n' "$*"
  if [ "$APPLY" = "1" ]; then "$@"; else echo "      [DRY-RUN] 未执行（加 APPLY=1 才写）"; fi
}

read_pool() {  aliyun --region "$REGION" cs DescribeClusterNodePools --ClusterId "$CID" 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
for p in d.get('nodepools',[]):
    if (p.get('nodepool_info') or {}).get('nodepool_id')=='$POOL':
        a=p.get('auto_scaling') or {}; s=p.get('scaling_group') or {}; st=p.get('status') or {}
        print('    auto_scaling.enable=%s min=%s max=%s | desired_size=%s | total_nodes=%s | types=%s' % (
            a.get('enable'),a.get('min_instances'),a.get('max_instances'),
            s.get('desired_size'),st.get('total_nodes'),s.get('instance_types')))
"
}

# ───────────────────────────────────────────────────────── S0
step_S0() {
  say "S0 欠费护栏（本次事故的根因，优先级最高）"
  cat <<'TXT'
  事实：Account.Arrearage 让 ESS 连续 9 小时静默扩容失败，K8s 侧 0 可见性。
  钱的问题不解决，后面所有缩容/换机型动作都可能同样卡在静默失败上。
TXT
  say "  余额回读（只读，始终执行）"
aliyun --region "$REGION" bssopenapi QueryAccountBalance 2>/dev/null | python3 -c "
import sys,json
try: d=json.load(sys.stdin)['Data']
except Exception: print('      (读取失败)'); sys.exit()
print('      AvailableAmount=%s %s  QuotaLimit=%s' % (d.get('AvailableAmount'), d.get('Currency'), d.get('QuotaLimit')))
"
  cat <<'TXT'
  落地两条（本脚本不代配 crontab）：
    1) 费用中心 → 账户资金 → 余额预警阈值（控制台目视；国际站建议 ≥ 1 个月节点费 ≈ 133 USD）
    2) 定时探测（下行已实测可跑，退出码非 0 即告警）：
       0 9 * * * PATH=$HOME/.workbuddy/binaries/aliyun-cli:$PATH aliyun --region ap-southeast-5 \
         bssopenapi QueryAccountBalance 2>/dev/null | python3 -c \
         'import sys,json; v=float(json.load(sys.stdin)["Data"]["AvailableAmount"].replace(",","")); print("AvailableAmount=%.2f USD"%v); sys.exit(0 if v>=300 else 1)'
       接现有告警通道（云监控站点监控 / 邮件闸门）。
TXT
  echo "  [待实测] 云监控/消息中心的欠费告警 API 未在本账号验证过，先用控制台 + 定时探测兜住。"
}

# ModifyClusterNodePool 是 ROA PUT（aliyun cs ModifyClusterNodePool --help 实测：
#   url=/clusters/{ClusterId}/nodepools/{NodepoolId}, contentType=application/json, body 为 string）
pool_put() {
  aliyun cs PUT "/clusters/$CID/nodepools/$POOL" --region "$REGION" \
    --header "Content-Type=application/json" --body "$1"
}

# ───────────────────────────────────────────────────────── S1
step_S1() {
  say "S1 把「固定 4 台」改为「固定 $DESIRED 台」（停止无谓补货）"
  read_pool
  cat <<TXT
  为什么先做这步：desired_size=4 才是 4 台的原因（auto_scaling 已关）。
  改小 desired_size 后 ESS 会自行回收超出部分，无需手工 drain。
  注意 desired(4) > max(3) 本身自相矛盾，说明这条池子早被控制台改过。
TXT
  local body="{\"scaling_group\":{\"desired_size\":$DESIRED}}"
  run "ModifyClusterNodePool 下发 desired_size=$DESIRED" pool_put "$body"
  echo "  [待实测] body 形态未在本账号跑过。若服务端拒绝局部 patch，改为回读全量 JSON、"
  echo "           只改 desired_size 后整体提交；或直接在控制台节点池「容量」处改。"
  say "  回读（等待 1~2 分钟，节点被回收后再看）"
  [ "$APPLY" = "1" ] && read_pool
}

# ───────────────────────────────────────────────────────── S2
step_S2() {
  say "S2 或：恢复弹性伸缩（按量 dev 更推荐这条，闲时能自己掉到 min）"
  read_pool
  cat <<TXT
  开启 auto_scaling 后 desired_size 不再兜底，负载为零时 autoscaler 会回收空节点。
  min=1 / max=$DESIRED，type 仍用 cpu。
  ⚠ 台账已记录一次同类事故：autoscaler 因 coredns 跨可用区打散约束，
     10:13:22 同一秒把节点从 1 加到 3 顶到 max。⇒ max 不要给到 3，且要么收到单 AZ，
     要么给 coredns 加 topologySpreadConstraints 的 soft 版本 / minDomains 容忍。
TXT
  run "开启弹性伸缩 min=1 max=$DESIRED" pool_put \
    "{\"auto_scaling\":{\"enable\":true,\"min_instances\":1,\"max_instances\":$DESIRED,\"type\":\"cpu\"}}"
  echo "  [待实测] body 形态需先看 DRY-RUN 再确认。"
  echo "  ⚠ 与 S1 互斥：开启弹性伸缩时要把 desired_size 一并置 0/清空，否则「固定数量」与"
  echo "           「弹性」并存，ESS 仍会按 desired 补货，S1 的事故会重演。"
}

# ───────────────────────────────────────────────────────── S3
step_S3() {
  say "S3 定时伸缩（dev 集群按作息收钱，节省最直观）"
  cat <<TXT
  目标：夜间/周末压到 1 台，工作时段允许 2 台。
  实测本池 ESS 伸缩配置为 $SC_CFG，伸缩组 $ASG。
  ⚠ ACK 托管的伸缩组由集群纳管，直接用 ESS ScheduledTask 改期望容量可能与集群侧状态互相覆盖。
    优先用 ACK 自己的「节点池定时伸缩」（cost autoscaler / 控制台定时伸缩），ESS 原语只作兜底。
TXT
  run "[兜底方案，慎用] 每日 18:00Z 把期望容量压到 1" \
    aliyun --region "$REGION" ess CreateScheduledTask \
    --ScalingGroupId "$ASG" --ScheduledTaskName "jkt-dev-night-cap1" \
    --DesiredCapacity 1 --LaunchTime "2026-10-18T18:00:00Z" \
    --RecurrenceType Daily --RecurrenceValue "1" --Description "dev 闲时缩容"
  echo "  [待实测] 本步标记为兜底，不建议 APPLY；先走 ACK 定时伸缩或 S2 的弹性伸缩。"
}

# ───────────────────────────────────────────────────────── S4
step_S4() {
  say "S4 提高单节点 Pod 上限：换成 g9i.xlarge（推荐），而不是 g8ine.large"
  cat <<TXT
  实测 ENI 配额（DescribeInstanceTypes）：
    ecs.g9i.large    2C8G  3 ENI × 6 IP  ⇒ (3-1)×6+3 = 15 Pod
    ecs.g9ae.large   2C8G  3 ENI × 6 IP  ⇒ 15 Pod
    ecs.g8ine.large  2C8G  3 ENI × 10 IP ⇒ 23 Pod
    ecs.g9i.xlarge   4C16G 4 ENI × 15 IP ⇒ 48 Pod   ← 推荐
  实测三区库存（DescribeAvailableResource，PostPaid）：
    ecs.g8ine.large  仅 ap-southeast-5b 有货，5a/5c = NO_DATA ⇒ 不能进 BALANCE 多 AZ 列表
    ecs.g9i.xlarge   5a/5b/5c 全部 Available
  所以 xlarge 才是可落地方案：2 台 xlarge 与 4 台 large 总算力持平（8C32G），
  但 Pod 配额 60→96、节点数 4→2、DaemonSet/预留开销减半，月费基本不变。
  ⚠ 只对新建节点生效；存量节点靠 S1 缩容 + 重建自然过渡，勿在未 drain 时直接改。
  ⚠ 这一步解决的是「装箱密度」，不解决「内存 request 83% vs 实际 4%」——先做 S1/S5。
  ⚠ 机型列表只放 g9i.xlarge。掺回任何 large 规格会重新掉到 15 Pod/台，且补货时
     选到哪台不可控；g8ine.large 更不能用（5a/5c 无货 ⇒ 像欠费那样静默反复失败）。
     代价是单机型库存风险，需靠 S0 的余额/库存探测与 S9 复跑兜住。
TXT
  local b='{"scaling_group":{"instance_types":["ecs.g9i.xlarge"]}}'
  run "机型列表改为单一 g9i.xlarge" pool_put "$b"
  echo "  [待实测] body 形态同 S1。建议顺序：S0 余额 → S1 缩到 2 台 → 再换机型 → S5 降 request。"
}

# ───────────────────────────────────────────────────────── S5
step_S5() {
  say "S5 降内存 request（真正让 83% 下来的那一步，需集群凭据）"
  cat <<TXT
  本机不可直连（endpoint_public_access=false）。三选一：
    A) 控制台 Cloud Shell 粘贴下面命令
    B) deploy/pub_bodies/07-lower-requests.sh（已有，newapi-dev 降到 cpu=50m/mem=256Mi）
    C) 给 deploy/lib/ack_remote.sh 加 jkt 分支后在节点内跑（文档 §4.3）
TXT
  cat <<'CMD'
  # 1) 谁把内存 request 抬上去了
  kubectl get pods -A -o json | python3 -c "
import sys,json,collections
d=json.load(sys.stdin); agg=collections.Counter()
def m(v):
    if not v: return 0
    v=str(v); u={'Ki':1/1024/1024,'Mi':1/1024,'Gi':1}.get(v[-2:])
    return float(v[:-2])*u if u else float(v)/1024/1024/1024
for p in d.get('items',[]):
    if p.get('status',{}).get('phase') in ('Succeeded','Failed'): continue
    for c in p['spec'].get('containers',[]):
        r=(c.get('resources') or {}).get('requests') or {}
        agg['%s/%s' % (p['metadata']['namespace'], c['name'])] += m(r.get('memory'))
for k,v in agg.most_common(15): print('  %-44s %.2fGi' % (k,v))
"
  # 2) 真实用量对照（决定能降到多少）
  kubectl top pods -A --sort-by=memory
  # 3) 单点降配（示例，值以 1)2) 的实测为准，不要照抄）
  kubectl -n newapi-dev set resources deploy/new-api-dev -c new-api \
    --requests=cpu=50m,memory=256Mi
  kubectl -n newapi-dev rollout status deploy/new-api-dev --timeout=200s
CMD
  echo "  验收口径：改后「调度器 Memory Request」应 < 50%，且 kubectl top nodes 用量不变。"
}

# ───────────────────────────────────────────────────────── S9
step_S9() {
  say "S9 复跑取证，确认漂移已消除"
  run "重新执行只读取证脚本" bash deploy/scripts/jkt-dev-recon.sh
}

for s in S0 S1 S2 S3 S4 S5; do
  case "$STEP" in "$s"|all) "step_$s" ;; esac
done
[ "$STEP" = "S9" ] && step_S9
[ "$STEP" = "all" ] && step_S9

if [ "$APPLY" != "1" ]; then
  say "以上为 DRY-RUN。逐条确认后再 APPLY=1 ... S<n>，不要一次 all。"
fi
