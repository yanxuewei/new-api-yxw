#!/usr/bin/env bash
# deploy/perf/channel_patch.sh —— 只提交「可变字段」的 channel 局部更新（任务 33 压测换上游用）
#
# 为什么需要它：控制台/朴素 PUT 会把 GET 回来的整个对象（含 status、created_time 等只读字段）一起回写，
#   后端 UpdateChannel 见到 body 里有 "status" 就回 `Invalid parameters`（controller/channel.go:1134）。
#   本脚本只发 **id + 你显式给的字段**，状态另走 `POST /api/channel/:id/status`。
#
# 语义边界（后端 model.Channel.Update 用 GORM `Updates(struct)`）：
#   - 只更新**非零值**字段 ⇒ 无法用它把字段改回空/0（如清空 base_url、weight 归零），那种场景走控制台或 SQL。
#   - channel 的 `key` 支持 `--key-file` 传入（不落 argv）；留空=不改。
#
# usage:
#   bash deploy/perf/channel_patch.sh --show --id 3
#   bash deploy/perf/channel_patch.sh --id 3 --base-url http://mock-upstream.new-api-perf.svc.cluster.local
#   bash deploy/perf/channel_patch.sh --id 3 --models "mock-gpt" --weight 1 --priority 10
#   bash deploy/perf/channel_patch.sh --id 3 --status 2          # 2=禁用（走独立状态接口）
#   bash deploy/perf/channel_patch.sh --id 3 --key-file /tmp/k   # 改密钥（值从文件读，不进 argv）
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
REMOTE="$ROOT/deploy/lib/ack_remote_jkt_dev.sh"
BODY="$HERE/bodies/channel_patch.sh"
[ -s "$BODY" ] || { echo "[!] 缺 body：$BODY"; exit 1; }

ID="" SHOW=0 STATUS="" BASURL="" MODELS="" NAME="" WEIGHT="" PRIORITY="" GROUP="" TYPE="" KEYFILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --id) ID="$2"; shift 2 ;;
    --show) SHOW=1; shift ;;
    --base-url) BASURL="$2"; shift 2 ;;
    --models) MODELS="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --weight) WEIGHT="$2"; shift 2 ;;
    --priority) PRIORITY="$2"; shift 2 ;;
    --group) GROUP="$2"; shift 2 ;;
    --type) TYPE="$2"; shift 2 ;;
    --status) STATUS="$2"; shift 2 ;;
    --key-file) KEYFILE="$2"; shift 2 ;;
    *) echo "[!] 未知参数：$1"; exit 2 ;;
  esac
done
[ -n "$ID" ] || { echo "[!] 必须给 --id"; exit 2; }

# 组装局部 patch（只用 Python，避免引号/转义把 JSON 弄坏；值为空=不提交该字段）
PATCH_JSON=$(ID="$ID" SHOW="$SHOW" S="$STATUS" B="$BASURL" M="$MODELS" N="$NAME" W="$WEIGHT" P="$PRIORITY" G="$GROUP" T="$TYPE" KF="$KEYFILE" python3 - <<'PY'
import json, os
p = {"id": int(os.environ["ID"])}
m = {
    "base_url": os.environ.get("B", ""),
    "models": os.environ.get("M", ""),
    "name": os.environ.get("N", ""),
    "weight": os.environ.get("W", ""),
    "priority": os.environ.get("P", ""),
    "group": os.environ.get("G", ""),
    "type": os.environ.get("T", ""),
}
for k, v in m.items():
    if v == "":
        continue
    if k in ("weight", "priority", "type"):
        p[k] = int(v)
    else:
        p[k] = v
kf = os.environ.get("KF") or ""
if kf:
    p["key"] = open(kf, encoding="utf-8").read().strip()
print(json.dumps(p, ensure_ascii=False))
PY
)
[ -n "$PATCH_JSON" ] || { echo "[!] patch 组装失败"; exit 1; }

# 临时脚本自带密钥：先收紧 umask，再用 mktemp 生成不可预测文件名，退出时无论成败都删除。
umask 077
FULL="$(mktemp "${TMPDIR:-/tmp}/perf_chpatch.XXXXXX.sh")" || { echo "[!] 临时脚本创建失败"; exit 1; }
trap 'rm -f "$FULL"' EXIT INT TERM
{
  cat <<'HDR'
#!/bin/bash
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/local/bin:$PATH
HDR
  printf "export CH_ID='%s'\n" "$ID"
  printf "export CH_SHOW='%s'\n" "$SHOW"
  printf "export CH_STATUS='%s'\n" "$STATUS"
  printf "export CH_PATCH_B64='%s'\n" "$(printf '%s' "$PATCH_JSON" | base64 | tr -d '\n')"
  cat "$BODY"
} > "$FULL"
bash "$REMOTE" "$FULL"
exit $?
