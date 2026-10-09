#!/bin/bash
# task27_alert.sh — Day 3 · 任务 27 V6 出口「canary 独立 5xx 告警」的 SLS 控制面执行器
#
# 卡片：deploy/docs/阿里云国际站菲律宾部署_详细操作指南-v2.0.md
#   任务 27 V6 = "能按 track 分别统计 5xx"；Day 3 出口清单要求"canary 独立告警（5xx>3 兜底）已建"。
#   现网取证（2026-10-08）：`sls-newapi-mnl/app-stdout` 的 `content` **无 SQL 索引** ⇒ 按状态码聚合在
#   应用日志侧写不出来 ⇒ 5xx 门改挂 **`sls-newapi-mnl/alb_access`**（有 `status`/`slb_pool_name` 字段索引）。
#
# ⚠ 两个必须先接受的语义（都来自卡片坑）：
#   1) 告警维度是 **ServerGroup 名**（`new-api-new-api-canary-80`），不是 group id ——
#      权重归零再恢复会**重建 ServerGroup、id 变、名字不变**（坑 12），按名字匹配才活得过回滚。
#      副作用：weight 件与 header 件派生的两个同质组**同名**（坑 6）⇒ canary 桶 = 两条通道之和。
#   2) **ALB 访问日志里没有健康检查**（--probe 实测：4 后端 ×20s 应贡献 ~17k 行/24h，
#      `alb_access` 里 `/api/status` 只有个位数）⇒ 分母只有真实用户流量。灰度期日常真实流量≈0，
#      "无样本"必然天天触发 ⇒ `newapi-canary-nosample` **建好但默认 DisableAlert**，只在演练窗口临时开。
#
# usage:
#   bash deploy/task27_alert.sh --probe               # 只读：跑规则里那条聚合查询，证明判据写得出来
#   bash deploy/task27_alert.sh --status              # 只读：ListAlerts + GetAlert 回读现值
#   bash deploy/task27_alert.sh --dump                # 只读：把 live 规格原样打印（改 body 前的对照）
#   bash deploy/task27_alert.sh --apply               # ⚠ 写：缺则 CreateAlert(最小 body) → UpdateAlert(富 body) → 回读
#   bash deploy/task27_alert.sh --set-state <on|off>  # ⚠ 写：Enable/DisableAlert，目标由 ALERT=<规则名> 指定
#   环境变量：ALERT=newapi-canary-5xx|newapi-canary-nosample   CONFIRM=yes（写操作必需）   DRY=1（只渲染）
#
# 为什么 --apply 是两段式：**实测 `CreateAlert` 拒收富 body**（`400 ParameterInvalid: Invalid request body`，
#   逐字段二分无解、`--cli-dry-run` 也不拦），而**同一份 body 给 `UpdateAlert` 能过**（坑 16）。
#   ⚠ UpdateAlert 是**全量覆盖**：漏字段会把线上规则改残（本卡 2026-10-08 自己踩过一次，靠再次 PUT + GET 恢复）
#   ⇒ 本脚本的 body 是**照 --dump 的 live 现值逐字段抄回来的**，改判据前务必先 --dump 对照，别凭记忆写。
set -uo pipefail

MODE="${1:-}"; ARG2="${2:-}"
[[ -n "$MODE" ]] || { echo "usage: $0 --probe|--status|--dump|--apply|--set-state <on|off>"; exit 2; }

R=ap-southeast-6
P=sls-newapi-mnl
LS=alb_access
ALERT="${ALERT:-newapi-canary-5xx}"
POOL=new-api-new-api-canary-80
QUERY="slb_pool_name: ${POOL} | select count(*) as n, sum(case when status >= 500 then 1 else 0 end) as e5xx"
TAGS='["task27-canary","day3"]'

say() { printf '%s\n' "$*"; }
die() { echo "[!] $*" >&2; exit 1; }
need_confirm() { [[ "${CONFIRM:-}" = yes ]] || die "$* 是账号写操作，需 CONFIRM=yes"; }
mask() { sed -E 's/(LTAI[A-Za-z0-9]{6})[A-Za-z0-9]*/\1***masked***/g'; }

# 规则表：name|start|condition|severity|displayName|description
spec() {
  case "$1" in
    newapi-canary-5xx)
      echo 'newapi-canary-5xx|-15m|e5xx > 0|8|[new-api] canary 5xx（灰度质量门）|Day3 任务27 V6 缺口闭合：ALB 访问日志按 slb_pool_name 分桶，canary 组出现 5xx 即告警（窗口15m/频率5m，容忍 ALB 日志投递延迟）' ;;
    newapi-canary-nosample)
      echo 'newapi-canary-nosample|-30m|n == 0|6|[new-api] canary 无样本（观测窗断裂）|坑2 兜底：灰度窗口内 canary 零样本说明没接流量，禁止推进权重；日常默认停用' ;;
    *) die "未知 ALERT=$1（应为 newapi-canary-5xx 或 newapi-canary-nosample）" ;;
  esac
}

get_alert() { aliyun sls GetAlert --region "$R" --project "$P" --alertName "$1" 2>&1; }
readable() { # 把 GetAlert 输出压成判据行
  python3 -c '
import json,sys
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception: print("  [XX] 非 JSON：",raw[:200]); sys.exit(1)
c=d["configuration"]; ql=c["queryList"][0]
print("  name=%s state=%s" % (d["name"], d["status"]))
print("    store=%s/%s start=%s end=%s timeSpanType=%s" % (ql["project"],ql["store"],ql["start"],ql["end"],ql["timeSpanType"]))
print("    query=%s" % ql["query"])
print("    condition=%s severity=%s" % (c["conditionConfiguration"]["condition"],
        c["severityConfigurations"][0]["severity"]))
print("    group=%s noDataFire=%s noDataSeverity=%s sendResolved=%s autoAnnotation=%s threshold=%s" % (
        c["groupConfiguration"]["type"], c["noDataFire"], c["noDataSeverity"], c["sendResolved"],
        c["autoAnnotation"], c["threshold"]))
print("    annotations=%d tags=%s schedule=%s" % (len(c["annotations"]), c["tags"], json.dumps(d["schedule"],ensure_ascii=False)))
print("    displayName=%s" % d["displayName"])
'
}

# ---------------------------------------------------------------- 只读三模式
case "$MODE" in
  --probe)
    TO=$(date +%s); FROM=$(( TO - 86400 ))
    say "[i] 窗口=最近 24h（$FROM→$TO） project=$P logstore=$LS region=$R"
    say "[i] 分桶查询（与告警同口径，但按组拆开看）"
    aliyun sls GetLogsV2 --region "$R" --project "$P" --logstore "$LS" \
      --body "{\"from\":$FROM,\"to\":$TO,\"line\":20,\"offset\":0,\"query\":\"* | select slb_pool_name, count(*) as n, sum(case when status >= 500 then 1 else 0 end) as e5xx from log group by slb_pool_name order by n desc limit 20\"}" \
      2>&1 | python3 -c '
import json,sys
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception: print("  [XX] 非 JSON：",raw[:300]); sys.exit(1)
rows=d.get("data") or []
print("  组数=%d（判据：canary 组必须出现且 n/e5xx 可取）" % len(rows))
for r in rows: print("   %-34s n=%-8s e5xx=%s" % (r.get("slb_pool_name"), r.get("n"), r.get("e5xx")))
'
    say "[i] 告警本体的单桶查询（就是规则里那条）"
    aliyun sls GetLogsV2 --region "$R" --project "$P" --logstore "$LS" \
      --body "{\"from\":$FROM,\"to\":$TO,\"line\":5,\"offset\":0,\"query\":\"$(printf '%s' "$QUERY" | sed 's/"/\\"/g')\"}" \
      2>&1 | tail -c 600
    say ""
    say "[i] n=0 是**日常常态**（ALB 访问日志不含健康检查，灰度期无真实流量）⇒ 这正是 nosample 默认停用的原因（坑 15）"
    ;;
  --status)
    aliyun sls ListAlerts --region "$R" --project "$P" --size 100 2>&1 | python3 -c '
import json,sys
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception: print("  [XX] 非 JSON：",raw[:200]); sys.exit(1)
rs=d.get("results") or []
print("  ListAlerts count=%d" % len(rs))
for a in rs: print("   %-28s state=%-9s apiType=%s" % (a.get("name"), a.get("state") or a.get("status"), a.get("apiType")))
'
    for a in newapi-canary-5xx newapi-canary-nosample; do say "--- $a"; get_alert "$a" | readable; done
    ;;
  --dump)
    for a in newapi-canary-5xx newapi-canary-nosample; do
      say "=== $a live 规格（原样，改 body 前抄这个）"
      get_alert "$a" | python3 -m json.tool 2>/dev/null || echo "  [XX] 读取失败"
    done
    ;;
esac
[[ "$MODE" =~ ^--(probe|status|dump)$ ]] && exit 0

# ---------------------------------------------------------------- body 渲染
body_min() { # 只带必填字段：CreateAlert 只吃这一份
  python3 - "$1" "$R" "$P" "$LS" "$QUERY" <<'PY'
import json, sys
name, r, p, ls, q = sys.argv[1:6]
print(json.dumps({
    "name": name, "displayName": name,
    "configuration": {
        "version": "2.0", "type": "default", "threshold": 1,
        "noDataFire": False, "sendResolved": True, "autoAnnotation": False,
        "queryList": [{"storeType": "log", "project": p, "store": ls, "region": r,
                       "timeSpanType": "Custom", "start": "-15m", "end": "now", "query": q}],
        "severityConfigurations": [{"severity": 8,
                                    "evalCondition": {"condition": "e5xx > 0", "countCondition": ""}}],
        "groupConfiguration": {"type": "custom", "fields": []},
        "conditionConfiguration": {"condition": "e5xx > 0", "countCondition": ""}},
    "schedule": {"type": "FixedRate", "interval": "5m"}}, ensure_ascii=False))
PY
}
body_full() { # 与 live 现值逐字段同构（--dump 抄回来）；漏字段=覆盖成残缺
  spec "$1" | python3 -c '
import json,sys
name,start,cond,sev,dn,desc = sys.stdin.read().strip().split("|",5)
dn, desc = dn.strip(), desc.strip()
R,P,LS,Q,TAGS = "ap-southeast-6","sls-newapi-mnl","alb_access",\
  "slb_pool_name: new-api-new-api-canary-80 | select count(*) as n, sum(case when status >= 500 then 1 else 0 end) as e5xx",\
  ["task27-canary","day3"]
print(json.dumps({
 "name":name,"displayName":dn,"description":desc,
 "configuration":{
   "version":"2.0","type":"default","threshold":1,"noDataFire":False,"noDataSeverity":6,
   "sendResolved":True,"autoAnnotation":True,
   "queryList":[{"storeType":"log","project":P,"store":LS,"region":R,
                 "timeSpanType":"Custom","start":start,"end":"now","query":Q}],
   "severityConfigurations":[{"severity":int(sev),
                              "evalCondition":{"condition":cond,"countCondition":""}}],
   "groupConfiguration":{"type":"custom","fields":[]},
   "conditionConfiguration":{"condition":cond,"countCondition":""},
   "annotations":[{"key":"title","value":dn},{"key":"desc","value":desc}],
   "tags":TAGS},
 "schedule":{"type":"FixedRate","interval":"5m","delay":0,"runImmediately":False,"timeZone":""}
},ensure_ascii=False))'
}

# ---------------------------------------------------------------- 写：单条收敛
apply_one() {
  local n="$1" exists
  exists=$(aliyun sls ListAlerts --region "$R" --project "$P" --size 100 2>/dev/null \
    | python3 -c 'import json,sys; print("yes" if sys.argv[1] in [a.get("name") for a in (json.load(sys.stdin).get("results") or [])] else "no")' "$n")
  say "[i] $n 现存在=$exists（存在性闸门：缺才 Create，避免 JobAlreadyExist 伪装成失败）"
  if [[ "${DRY:-}" = 1 ]]; then
    say "[i] DRY=1 ⇒ 只渲染 body（下面两行分别是 CreateAlert 与 UpdateAlert 的 body）"
    [[ "$exists" = no ]] && { echo "  min : $(body_min "$n")"; }
    echo "  full: $(body_full "$n")"
    return 0
  fi
  if [[ "$exists" = no ]]; then
    say "[i] CreateAlert（最小 body；富 body 在这里必失败，见坑 16）"
    aliyun sls CreateAlert --region "$R" --project "$P" --body "$(body_min "$n")" 2>&1 | mask | tail -3
  fi
  say "[i] UpdateAlert（富 body，PUT 全量覆盖）"
  aliyun sls UpdateAlert --region "$R" --project "$P" --alertName "$n" --body "$(body_full "$n")" 2>&1 | mask | tail -3
  say "[i] 回读验证（调用成功≠生效，必须 GET 对字段）"
  get_alert "$n" | readable
}

case "$MODE" in
  --apply)
    need_confirm "--apply 会 Create（缺时）+ Update 两条规则"
    apply_one newapi-canary-5xx
    apply_one newapi-canary-nosample
    say "[i] ⚠ 启停态**不由 --apply 管**（UpdateAlert 不改 state）；nosample 应保持 Disabled，演练期用 --set-state on"
    ;;
  --set-state)
    need_confirm "--set-state 会改告警启停"
    say "[i] 当前 $ALERT："
    get_alert "$ALERT" | readable
    case "$ARG2" in
      on)  say "[i] EnableAlert $ALERT";  aliyun sls EnableAlert  --region "$R" --project "$P" --alertName "$ALERT" 2>&1 | mask | tail -3 ;;
      off) say "[i] DisableAlert $ALERT"; aliyun sls DisableAlert --region "$R" --project "$P" --alertName "$ALERT" 2>&1 | mask | tail -3 ;;
      *) die "--set-state 只接受 on|off" ;;
    esac
    [[ "${DRY:-}" = 1 ]] || { say "[i] 回读："; get_alert "$ALERT" | readable; }
    ;;
  *) die "未知参数：$MODE" ;;
esac
