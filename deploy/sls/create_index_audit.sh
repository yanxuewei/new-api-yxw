#!/usr/bin/env bash
# 任务 26 补项｜为 SLS 审计类 Logstore 建全文索引（幂等：已存在则跳过）
# 口径：复用本项目 actiontrail 现有索引的分词器（token）集合，ttl 与 Logstore 一致（30 天）
# 用法：bash create_index_audit.sh            # 干跑（只打印将执行的动作）
#       EXEC_MODE=apply bash create_index_audit.sh
set -uo pipefail

EXEC_MODE="${EXEC_MODE:-dry}"
# project:region:logstore（两站同构）
TARGETS=(
  "sls-newapi-mnl:ap-southeast-6:rds-audit"
  "sls-newapi-sg:ap-southeast-1:rds-audit"
)
# 注：sls-newapi-sg/waf-log 亦缺索引（ttl=None），但 WAF 尚未接入（count=0）→ 留待任务 20 接入后再建，
#     避免给空 Logstore 白付索引存储；届时把 "sls-newapi-sg:ap-southeast-1:waf-log" 加回本数组即可。
REF_PROJECT="sls-newapi-mnl"; REF_REGION="ap-southeast-6"; REF_LOGSTORE="actiontrail"

echo "== EXEC_MODE=$EXEC_MODE @ $(date '+%F %T') =="

# 1) 取参照索引（actiontrail）的分词器，构造全文索引 body
BODY=$(REF_PROJECT=$REF_PROJECT REF_REGION=$REF_REGION REF_LOGSTORE=$REF_LOGSTORE python3 - <<'PY'
import json, os, subprocess
env = dict(os.environ)
cmd = ["aliyun", "sls", "GetIndex", "--project", env["REF_PROJECT"],
       "--logstore", env["REF_LOGSTORE"], "--region", env["REF_REGION"]]
raw = subprocess.run(cmd, capture_output=True, text=True).stdout
d = json.loads(raw)
idx = d.get("index", d)              # 兼容 wrapped / flat
line = idx.get("line") or {"token": [" ", ",", "'", '"', ";", "=", "(", ")", "[", "]",
                                        "{", "}", "?", "@", "&", "<", ">", "/", ":", "\n", "\t", "\r"]}
body = {"ttl": 30, "line": line, "keys": {}}
print(json.dumps(body, ensure_ascii=False))
PY
)
echo "-- body(source=$REF_LOGSTORE) --"; echo "$BODY" | head -c 400; echo

# 2) 建索引
for t in "${TARGETS[@]}"; do
  IFS=':' read -r P R LS <<<"$t"
  cur=$(aliyun sls GetIndex --project "$P" --logstore "$LS" --region "$R" 2>/dev/null \
        | python3 -c "import sys,json;d=json.load(sys.stdin);i=d.get('index',d);print(i.get('ttl'))" 2>/dev/null)
  if [ "$cur" != "None" ] && [ -n "$cur" ]; then
    echo "[skip] $P/$LS 已有索引 (ttl=$cur)"
    continue
  fi
  echo "[${EXEC_MODE}] create index $P/$LS@$R"
  if [ "$EXEC_MODE" = "apply" ]; then
    aliyun sls CreateIndex --project "$P" --logstore "$LS" --region "$R" \
      --header "Content-Type=application/json" --body "$BODY" 2>&1 | head -c 300; echo
  fi
done
