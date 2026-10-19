#!/bin/bash
# task32/burn_alerts.sh — Day 3 · 任务 32：错误预算燃烧率告警（SLS，多窗口）
#
# 口径（任务 32 卡 §2）：SLO 可用性 99.95%/月 ⇒ 预算 21.6 min/月；
#   燃烧率 = 实测错误率 / 0.05%。多窗口（Google SRE 口径）：
#     · rapid：1h 窗口，burn 14.4x ⇒ 错误率 0.72%  → severity 8（等同 P1）
#     · mid  ：6h 窗口，burn  6.0x ⇒ 错误率 0.30%  → severity 6（P2）
#     · slow ：3d 窗口，burn  1.0x ⇒ 错误率 0.05%  → severity 6（慢烧，工作时段处理）
#
# ★ 与卡内示例 query 的差异（两处，都是实测口径修正）：
#   1) 数据源用 **SLS alb_access**（ALB 日志无健康检查行 ⇒ 分母=真实用户流量，见任务 27 坑 15），
#      不是 Prometheus 的 alb_upstream_5xx（该指标不存在，/metrics 未落地）。
#   2) **上游 5xx 不计入自身 SLO**（卡内坑 3 / §12 排除项③）：用 `upstream_status >= 500` 把
#      上游故障行单独统计为 up_pct，自身错误率 own_pct 才参与燃烧率判据。
#
# ★ 现状限制（2026-10-19 实测）：本脚本只建**规则本体**。SLS 告警的「行动策略/通知渠道」是
#   独立资源，且**国际站云监控不支持电话/SMS**（`cms PutContact` 元数据：intl 仅 邮箱/DingTalk）
#   ⇒ P1 电话通道待裁定（见 deploy/tasks/task32/P1电话通道_实测与选型_2026-10-19.md）。
#   在通知接好之前，规则触发**不会通知任何人**，勿据此认为已可值班。
#
# usage：
#   bash burn_alerts.sh --status            # 只读：列出本卡 3 条规则现值
#   bash burn_alerts.sh --dump              # 只读：打印将写入的富 body（对照用）
#   CONFIRM=yes bash burn_alerts.sh --apply # ⚠ 写：缺则 CreateAlert(最小) → UpdateAlert(富)
#   ALERT=<名字> CONFIRM=yes bash burn_alerts.sh --set-state on|off
#
# 坑（沿用任务 27 实证）：CreateAlert 拒收富 body ⇒ 两段式；UpdateAlert 全量覆盖 ⇒ body 必须完整。
set -uo pipefail

R=ap-southeast-6
P=sls-newapi-mnl
LS=alb_access
HOST=www.likha.hk
MODE="${1:-}"; ARG2="${2:-}"
say() { printf '%s\n' "$*"; }
die() { echo "[!] $*" >&2; exit 1; }
need_confirm() { [ "${CONFIRM:-}" = yes ] || die "$* 是账号写操作，需 CONFIRM=yes"; }

# name|start|threshold|severity|interval|displayName|desc
rules() {
  cat <<EOF
newapi-slo-burn-rapid-p1|-1h|0.72|8|1m|[P1] 错误预算急速燃烧（1h >14.4x）|1h 自身 5xx 错误率 >0.72%（= 预算的 14.4 倍燃烧）⇒ 约 12 分钟耗尽月预算；按 P1 处理：5 分钟内响应
newapi-slo-burn-mid-p2|-6h|0.30|6|5m|[P2] 错误预算中速燃烧（6h >6x）|6h 自身 5xx 错误率 >0.30%（6 倍燃烧）；按 P2：30 分钟内响应
newapi-slo-burn-slow-p3|-3d|0.05|6|30m|[P2/P3] 错误预算慢烧（3d >1x）|3d 自身 5xx 错误率 >0.05%（预算已按 SLA 速度消耗）；次工作时段处理，进入发布评审
EOF
}

SPEC_ONE() { rules | awk -F'|' -v n="$1" '$1==n {print $2"|"$3"|"$4"|"$5"|"$6"|"$7}'; }

QUERY="host: $HOST | select count(*) as n, sum(case when status >= 500 then 1 else 0 end) as e5xx, sum(case when status >= 500 and coalesce(upstream_status, 0) < 500 then 1 else 0 end) as own5xx, round(sum(case when status >= 500 and coalesce(upstream_status, 0) < 500 then 1 else 0 end) * 100.0 / count(*), 4) as own_pct, round(sum(case when coalesce(upstream_status, 0) >= 500 then 1 else 0 end) * 100.0 / count(*), 4) as up_pct"

body_min() { # CreateAlert 只吃最小字段
  python3 - "$1" "$R" "$P" "$LS" "$QUERY" <<'PY'
import json, sys
name, r, p, ls, q = sys.argv[1:6]
print(json.dumps({
    "name": name, "displayName": name,
    "configuration": {
        "version": "2.0", "type": "default", "threshold": 1,
        "noDataFire": False, "sendResolved": True, "autoAnnotation": False,
        "queryList": [{"storeType": "log", "project": p, "store": ls, "region": r,
                       "timeSpanType": "Custom", "start": "-1h", "end": "now", "query": q}],
        "severityConfigurations": [{"severity": 8,
                                    "evalCondition": {"condition": "own_pct > 0.72", "countCondition": ""}}],
        "groupConfiguration": {"type": "custom", "fields": []},
        "conditionConfiguration": {"condition": "own_pct > 0.72", "countCondition": ""}},
    "schedule": {"type": "FixedRate", "interval": "1m"}}, ensure_ascii=False))
PY
}

body_full() { # 全量（UpdateAlert 覆盖写）
  local sp; sp=$(SPEC_ONE "$1") || true
  [ -n "$sp" ] || die "未知 ALERT=$1"
  R="$R" P="$P" LS="$LS" Q="$QUERY" NAME="$1" SP="$sp" python3 - <<'PY'
import json, os
name, start, thr, sev, itv, dn, desc = (os.environ["NAME"],) + tuple(os.environ["SP"].split("|"))
cond = "own_pct > %s" % thr
tags = ["task32-slo", "burn-rate"]
print(json.dumps({
 "name": name, "displayName": dn, "description": desc,
 "configuration": {
   "version": "2.0", "type": "default", "threshold": 1,
   "noDataFire": False, "noDataSeverity": 6, "sendResolved": True, "autoAnnotation": True,
   "queryList": [{"storeType": "log", "project": os.environ["P"], "store": os.environ["LS"],
                  "region": os.environ["R"], "timeSpanType": "Custom",
                  "start": start, "end": "now", "query": os.environ["Q"]}],
   "severityConfigurations": [{"severity": int(sev),
                               "evalCondition": {"condition": cond, "countCondition": ""}}],
   "groupConfiguration": {"type": "custom", "fields": []},
   "conditionConfiguration": {"condition": cond, "countCondition": ""},
   "annotations": [{"key": "title", "value": dn}, {"key": "desc", "value": desc}],
   "tags": tags},
 "schedule": {"type": "FixedRate", "interval": itv, "delay": 0,
              "runImmediately": False, "timeZone": ""}
}, ensure_ascii=False))
PY
}

exists() { aliyun sls ListAlerts --region "$R" --project "$P" 2>/dev/null | grep -q "\"$1\"" || \
           aliyun sls GetAlert --region "$R" --project "$P" --alertName "$1" 2>/dev/null | grep -q '"name"'; }

status_one() {
  local out; out=$(aliyun sls GetAlert --region "$R" --project "$P" --alertName "$1" 2>&1 | tr -d '\r')
  if printf '%s' "$out" | grep -q '"name"'; then
    printf '%s' "$out" | python3 -c "
import sys,json
d=json.load(sys.stdin); c=d.get('configuration') or {}
q=(c.get('queryList') or [{}])[0]
print('  %-26s state=%-9s window=%-5s cond=%-22s sev=%s interval=%s' % (
  d.get('name'), d.get('status') or d.get('state','?'), q.get('start'),
  (c.get('conditionConfiguration') or {}).get('condition'),
  ((c.get('severityConfigurations') or [{}])[0]).get('severity'),
  (d.get('schedule') or {}).get('interval')))"
  else
    echo "  $1  (不存在)"
  fi
}

case "$MODE" in
  --status)
    for n in $(rules | cut -d'|' -f1); do status_one "$n"; done
    say ""; say "[i] ⚠ 通知渠道/行动策略未接（国际站云监控无电话/SMS）⇒ 触发不触达"
    ;;
  --dump)
    for n in $(rules | cut -d'|' -f1); do say "=== $n (min) ==="; body_min "$n"; say "=== $n (full) ==="; body_full "$n"; say; done
    ;;
  --apply)
    need_confirm "--apply 会创建/覆盖 3 条 SLS 告警"
    for n in $(rules | cut -d'|' -f1); do
      if exists "$n"; then
        say "[skip-create] $n 已存在，直接 Update"
      else
        # VPC 端点偶发抖动（本项目既有事实）⇒ 写操作重试 3 次
        # ★ 判据必须是「输出里有没有 ERROR」，不能对空输出做 grep -qv（空输出=成功，会被误判失败）
        ok=0
        for i in 1 2 3; do
          say "[create] $n（第 $i 次）"
          out=$(aliyun sls CreateAlert --region "$R" --project "$P" --body "$(body_min "$n")" 2>&1)
          if printf '%s' "$out" | grep -q 'ERROR'; then
            say "        retry: $(printf '%s' "$out" | head -2 | tail -1)"
            sleep 4
          else
            ok=1; break
          fi
        done
        [ "$ok" = 1 ] || say "[!] $n 创建三次均失败"
        sleep 2
      fi
      say "[update] $n（富 body 全量覆盖）"
      aliyun sls UpdateAlert --region "$R" --project "$P" --alertName "$n" --body "$(body_full "$n")" 2>&1 | tail -2
      sleep 1
    done
    say ""; say "=== 回读 ==="
    for n in $(rules | cut -d'|' -f1); do status_one "$n"; done
    ;;
  --set-state)
    need_confirm "--set-state 改告警启停"
    ALERT="${ALERT:?需 ALERT=<规则名>}"; [ "$ARG2" = on ] || [ "$ARG2" = off ] || die "只接受 on|off"
    if [ "$ARG2" = on ]; then aliyun sls EnableAlert --region "$R" --project "$P" --alertName "$ALERT" 2>&1 | tail -2
    else aliyun sls DisableAlert --region "$R" --project "$P" --alertName "$ALERT" 2>&1 | tail -2; fi
    status_one "$ALERT"
    ;;
  *) die "usage: $0 --status|--dump|--apply|--set-state on|off" ;;
esac
