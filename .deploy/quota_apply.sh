#!/usr/bin/env bash
# ============================================================================
# quota_apply.sh —— §3.4 G2/G10 资源配额申请（幂等 / 可预演 / 可验证）
#
# 依据：`.deploy/阿里云国际站菲律宾部署_详细操作指南-ch.md` §3.4
#       `impl_deploy.md` §7.2（云资源清单）· §7.10（成本结构）
#       方案表：菲律宾部署方案-v2.1-修订版.xlsx
#
# 能力
#   check    只读：读实时配额 → 打印「需求 vs 现值」缺口表（不写云端）
#   apply    提交缺口项的配额申请（幂等：已有 Pending/Approved 则 SKIP）
#   verify   读回申请状态 + 复查 TotalQuota 是否达标
#   probe    调用 quota_probe.py 落盘全量实时值
#
# 前置
#   1. 已配置 AK/SK（aliyun CLI 可用）
#   2. ALIYUN_BIN 可覆盖 CLI 路径；本机默认
#      $HOME/.workbuddy/binaries/aliyun-cli/aliyun
#
# 用法
#   bash quota_apply.sh check
#   bash quota_apply.sh apply          # 真正提交，产生工单
#   bash quota_apply.sh verify
# ============================================================================
set -uo pipefail

ALIYUN_BIN="${ALIYUN_BIN:-$HOME/.workbuddy/binaries/aliyun-cli/aliyun}"
PY="${PY:-/usr/bin/python3}"
OUT_DIR=".workbuddy/quota"
STAMP="$(date +%Y%m%d_%H%M%S)"
LOG="${OUT_DIR}/apply_${STAMP}.log"

# 中文着色
R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'; N=$'\033[0m'
say()  { printf '%s\n' "$*" >&2; }
head1(){ printf '\n%s────────────────────────────────────────────────────────%s\n%s▌%s%s\n%s────────────────────────────────────────────────────────%s\n' "$B" "$N" "$B" "$N" "$*" "$B" "$N" >&2; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*" >&2; }
skip() { printf '  %s=%s %s\n' "$Y" "$N" "$*" >&2; }
fail() { printf '  %s✗%s %s\n' "$R" "$N" "$*" >&2; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*" >&2; }

mkdir -p "$OUT_DIR"

# ── 申请清单（唯一真源）────────────────────────────────────────────────────
# 格式：region|ProductCode|QuotaActionCode|目标值|需求说明
# 依据容量式（写进 Reason，显著提高通过率）：
#   马尼拉：ACK 节点池 ecs.g8i.2xlarge(8 vCPU) min4 → max8 = 64 vCPU
#   新加坡：备 region 接管 16 副本 × 1.5 = 24 副本 × 4 vCPU(limit) = 96 vCPU
APPLY_ITEMS=(
  "ap-southeast-6|ecs-spec|q_ecs_enterprise_postpay_c|64|node_pool_max_8_x_8vcpu"
  "ap-southeast-1|ecs-spec|q_ecs_enterprise_postpay_c|96|standby_24_replicas_x_4vcpu"
)

reason_for() { # $1=region $2=target
  case "$1" in
    ap-southeast-6)
      printf '%s' "new-api AI gateway production launch in Manila (ap-southeast-6), D4 node pool creation is on the critical path. ACK node pool uses ecs.g8i.2xlarge (8 vCPU): min 4 nodes = 32 vCPU steady state, max 8 nodes = 64 vCPU at peak, HPA up to 16 pods. Current postpaid enterprise vCPU quota is 50, which blocks the peak node pool size (8 nodes x 8 vCPU = 64). Requesting 64. Remaining capacity is already provisioned in this region (VPC/ALB/RDS/Tair/OSS)."
      ;;
    ap-southeast-1)
      printf '%s' "new-api AI gateway standby region (Singapore ap-southeast-1). To keep the committed SLA of 99.95 percent, the standby region must take over one complete primary site at no less than 1.5x of its peak: 16 pods peak x 1.5 = 24 pods, 24 x 4 vCPU (container limit) = 96 vCPU, node pool 12 nodes x 8 vCPU (ecs.g8i.2xlarge) = 96 vCPU. The quota is region scoped, so the Manila approval does not apply here. A cold standby still needs the same vCPU quota because node pool max size is pre-declared."
      ;;
    *) printf '%s' "new-api AI gateway deployment capacity requirement ${2} vCPU" ;;
  esac
}

api() { "$ALIYUN_BIN" "$@" 2>&1; }

# ── 读单条配额现值 ─────────────────────────────────────────────────────────
read_quota() { # $1=ProductCode $2=QuotaActionCode $3=region → 输出 "现值 已用"
  local r
  r=$(api quotas ListProductQuotas --ProductCode "$1" \
        --Dimensions.1.Key regionId --Dimensions.1.Value "$3" \
        --QuotaActionCode "$2" --MaxResults 10)
  printf '%s' "$r" | "$PY" -c "
import sys,json
raw=sys.stdin.read(); i=raw.find('{')
if i<0: print('ERR ERR'); raise SystemExit
try: d=json.loads(raw[i:])
except Exception: print('ERR ERR'); raise SystemExit
if 'error_code' in d: print('ERR ERR'); raise SystemExit
for q in (d.get('Quotas') or []):
    if q.get('QuotaActionCode')=='$2':
        print('%s %s' % (q.get('TotalQuota'), q.get('TotalUsage')))
        break
else:
    print('ERR ERR')
"
}

need_of() { # $1=ProductCode $2=QuotaActionCode → 目标需求值（表驱动，只对显式清单生效）
  local k="$1|$2" v
  for it in "${APPLY_ITEMS[@]}"; do
    IFS='|' read -r _rg pc qc tgt _d <<<"$it"
    [ "$pc|$qc" = "$k" ] && { printf '%s' "$tgt"; return; }
  done
  printf '%s' "-"
}

# ── 申请记录（幂等判定用）──────────────────────────────────────────────────
# ⚠️ 实测坑：ListQuotaApplications 的地域字段名是 **`Dimension`（单数 dict）**，
#    不是 ListProductQuotas 的 `Dimensions`；按 `Dimensions` 取会全落 '-'。
#    国际站该配额常见**即时生效**，状态直接是 `Process`（不是 Pending/Approved）。
existing_apps() { # $1=ProductCode → "QuotaActionCode|region|DesireValue|Status|Id"
  local r
  r=$(api quotas ListQuotaApplications --ProductCode "$1" --MaxResults 100)
  printf '%s' "$r" | "$PY" -c "
import sys,json,re
raw=sys.stdin.read(); i=raw.find('{')
if i<0: raise SystemExit
try: d=json.loads(raw[i:])
except Exception: raise SystemExit
for a in (d.get('QuotaApplications') or []):
    dims=a.get('Dimension') or a.get('Dimensions') or {}
    rg=dims.get('regionId') or a.get('RegionId') or ''
    if not rg:                       # 兜底：从 QuotaArn 的 region 段解析
        m=re.match(r'acs:quotas:([a-z0-9-]*):', a.get('QuotaArn') or '')
        rg=(m.group(1) if m else '') or '-'
    dv=a.get('DesireValue')
    dv=('%g' % dv) if isinstance(dv,(int,float)) else str(dv)
    print('%s|%s|%s|%s|%s' % (a.get('QuotaActionCode'), rg, dv,
                              a.get('Status'), a.get('ApplicationId') or a.get('Id') or ''))
"
}

# 已生效/豁免状态：出现其一即不再重复提交
# ⚠️ 实测状态机：Submit → `Process`（受理中）→ **`Agree`（已通过，TotalQuota 即时抬高）**；
#    国际站 ECS vCPU 这类 CommonQuota 常见**自动审批、分钟级生效**，不是 2–3 工作日。
APP_DONE_RE='^(Approved|Agree|Agreed|Pass|Passed|Process)$'
APP_PENDING_RE='^(Pending|Approving|Processing|Audit|Auditing|UnderReview|WaitReview)$'

# ════════════════════════════ check ════════════════════════════
cmd_check() {
  head1 "① 实时配额 vs 需求（只读）"
  printf '  %-14s %-32s %-8s %-8s %s\n' 产品 配额code 现值 需求 结论 >&2
  local bad=0
  for it in "${APPLY_ITEMS[@]}"; do
    IFS='|' read -r rg pc qc tgt desc <<<"$it"
    local v used; read -r v used <<<"$(read_quota "$pc" "$qc" "$rg")"
    local verdict
    if [ "$v" = "ERR" ]; then verdict="${R}读取失败${N}"; bad=$((bad+1))
    elif [ "$v" -lt "$tgt" ]; then verdict="${R}缺口 $((tgt - v))${N}"; bad=$((bad+1))
    else verdict="${G}满足${N}"; fi
    printf '  %-14s %-32s %-8s %-8s %b\n' "$rg" "$qc" "$v" "$tgt" "$verdict" >&2
  done

  head1 "② 申请记录（幂等判定）"
  local apps; apps=$(existing_apps ecs-spec)
  if [ -z "$apps" ]; then skip "ecs-spec 下暂无申请记录（ListQuotaApplications 空）"
  else printf '%s\n' "$apps" | while IFS='|' read -r qc rg dv st id; do
      say "  ${qc} @${rg} → ${dv}  [${st}]  id=${id}"; done
  fi

  head1 "③ 结论"
  local pending=0
  for it in "${APPLY_ITEMS[@]}"; do
    IFS='|' read -r rg pc qc tgt desc <<<"$it"
    if printf '%s' "$apps" | grep -qE "^${qc}\|${rg}\|"; then
      local line; line=$(printf '%s' "$apps" | grep -E "^${qc}\|${rg}\|" | head -1)
      local st dv; st=$(printf '%s' "$line" | cut -d'|' -f4); dv=$(printf '%s' "$line" | cut -d'|' -f3)
      if printf '%s' "$st" | grep -qE "$APP_DONE_RE"; then
        ok "${rg} ${qc} 已生效（状态 ${st}，申请值 ${dv}）—— 无需再提"
      elif printf '%s' "$st" | grep -qE "$APP_PENDING_RE"; then
        ok "${rg} ${qc} 审批中（状态 ${st}，申请值 ${dv}）—— 无需重复提"
      else
        fail "${rg} ${qc} 状态 ${st} —— 需人工研判（驳回则改理由后重提，见 ${LOG}）"; pending=$((pending+1))
      fi
    else
      [ "$bad" -gt 0 ] && skip "${rg} ${qc} 未提交 → 跑 apply"
    fi
  done
  [ "$bad" -eq 0 ] && ok "所有清单项现值均已 ≥ 需求"
  return 0
}

# ════════════════════════════ apply ════════════════════════════
cmd_apply() {
  head1 "提交配额申请（写入云端 · 会产生工单）"
  local apps; apps=$(existing_apps ecs-spec)
  {
    printf '=== quota_apply %s ===\n' "$STAMP"
    printf '%s\n' "$apps"
  } >> "$LOG"

  local n_new=0 n_skip=0 n_fail=0
  for it in "${APPLY_ITEMS[@]}"; do
    IFS='|' read -r rg pc qc tgt desc <<<"$it"
    # ① 现值已达标 → 直接跳过（最强幂等，不依赖申请记录的可读性）
    local v used; read -r v used <<<"$(read_quota "$pc" "$qc" "$rg")"
    if [ "$v" != "ERR" ] && [ "$v" -ge "$tgt" ]; then
      skip "${rg} 现值 ${v} 已 ≥ ${tgt}，无需申请"; n_skip=$((n_skip+1)); continue
    fi

    # ② 已有同维度申请记录 → 审批中/已生效则跳过
    local app_line=""
    printf '%s' "$apps" | grep -qE "^${qc}\|${rg}\|" && \
      app_line=$(printf '%s' "$apps" | grep -E "^${qc}\|${rg}\|" | head -1)
    if [ -n "$app_line" ]; then
      local st dv; st=$(printf '%s' "$app_line" | cut -d'|' -f4)
      dv=$(printf '%s' "$app_line" | cut -d'|' -f3)
      if printf '%s' "$st" | grep -qE "$APP_DONE_RE|$APP_PENDING_RE"; then
        skip "${rg} 已有申请（${dv}, ${st}），现值仍 ${v} —— 等生效或催办"; n_skip=$((n_skip+1)); continue
      fi
      warn "${rg} 已有申请但状态为 ${st} —— 按驳回处理，重新提交"
    fi

    local reason; reason=$(reason_for "$rg" "$tgt")
    local r
    r=$(api quotas CreateQuotaApplication \
          --ProductCode "$pc" --QuotaActionCode "$qc" \
          --DesireValue "$tgt" --Reason "$reason" \
          --Dimensions.1.Key regionId --Dimensions.1.Value "$rg" \
          --NoticeType 3 --QuotaCategory CommonQuota)
    printf '%s\n---\n' "$r" >> "$LOG"
    local id; id=$(printf '%s' "$r" | "$PY" -c "
import sys,json
raw=sys.stdin.read(); i=raw.find('{')
if i<0: print(''); raise SystemExit
try: d=json.loads(raw[i:])
except Exception: print(''); raise SystemExit
print(d.get('ApplicationId') or d.get('Id') or '')
")
    if [ -n "$id" ]; then
      ok "${rg} ${qc}: ${v:-?} → ${tgt}，申请已提交（id=${id}）"
      n_new=$((n_new+1))
    else
      fail "${rg} ${qc}: $(printf '%s' "$r" | head -c 240)"
      n_fail=$((n_fail+1))
    fi
  done
  head1 "小结"
  say "  新提交 ${n_new} · 跳过 ${n_skip} · 失败 ${n_fail}"
  say "  日志：${LOG}"
  say ""
  say "  下一步：等 2–3 工作日 → bash quota_apply.sh verify"
  [ "$n_fail" -eq 0 ]
}

# ════════════════════════════ verify ════════════════════════════
cmd_verify() {
  head1 "① 申请状态"
  local r; r=$(api quotas ListQuotaApplications --ProductCode ecs-spec --MaxResults 100)
  printf '%s' "$r" | "$PY" -c "
import sys,json,re
raw=sys.stdin.read(); i=raw.find('{')
if i<0: print('  (无返回)'); raise SystemExit
try: d=json.loads(raw[i:])
except Exception: print('  (解析失败)', raw[:200]); raise SystemExit
apps=d.get('QuotaApplications') or []
if not apps: print('  (无申请记录)')
for a in apps:
    dims=a.get('Dimension') or a.get('Dimensions') or {}
    rg=dims.get('regionId') or a.get('RegionId') or ''
    if not rg:
        m=re.match(r'acs:quotas:([a-z0-9-]*):', a.get('QuotaArn') or '')
        rg=(m.group(1) if m else '') or '-'
    print('  %-34s %-16s → %-6s [%s] id=%s' % (
        a.get('QuotaActionCode'), rg,
        a.get('DesireValue'), a.get('Status'), a.get('ApplicationId') or a.get('Id')))"
  head1 "② 现值是否达标（TotalQuota ≥ 申请值）"
  local bad=0
  for it in "${APPLY_ITEMS[@]}"; do
    IFS='|' read -r rg pc qc tgt desc <<<"$it"
    local v used; read -r v used <<<"$(read_quota "$pc" "$qc" "$rg")"
    if [ "$v" = "ERR" ]; then fail "${rg} 读取失败"; bad=$((bad+1))
    elif [ "$v" -ge "$tgt" ]; then ok "$(printf '%-14s' "$rg") ${qc} = ${v} ≥ ${tgt}"
    else fail "$(printf '%-14s' "$rg") ${qc} = ${v} < ${tgt}（未批复或仍在审批）"; bad=$((bad+1)); fi
  done
  head1 "③ 结论"
  if [ "$bad" -eq 0 ]; then ok "全部达标 —— 把申请 id 抄进操作指南 §12 里程碑证据（G2 / G10）"
  else fail "${bad} 项未达标：若长时间 Approving → 另交工单催办（配额审批与工单是两套流程）"; fi
  return "$bad"
}

# ════════════════════════════ probe ════════════════════════════
cmd_probe() { "$PY" quota_probe.py; }

case "${1:-check}" in
  check)  cmd_check ;;
  apply)  cmd_apply ;;
  verify) cmd_verify ;;
  probe)  cmd_probe ;;
  all)    cmd_probe; cmd_check; cmd_apply; cmd_verify ;;
  *) say "用法: bash quota_apply.sh {check|apply|verify|probe|all}"; exit 2 ;;
esac
