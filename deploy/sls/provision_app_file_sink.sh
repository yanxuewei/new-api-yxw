#!/usr/bin/env bash
# 任务 26 app-file 纠正版｜在 logtail **实际写入的项目**里补齐 `app-file` Logstore + 全文索引（幂等）
#
# 背景：`AliyunLogConfig` 的落点项目由 logtail 附加组件绑定（= `k8s-log-<clusterId>`），CRD 无 project 字段；
#       卡内写的 `sls-newapi-mnl/app-file` 不是真实落点 ⇒ 必须在 k8s-log 项目里建同名 Logstore，
#       否则 CRD 建了也采不到（logtail 无目标 Logstore）。
# 用法：bash provision_app_file_sink.sh                  # 干跑
#       EXEC_MODE=apply bash provision_app_file_sink.sh  # 执行
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
EXEC_MODE="${EXEC_MODE:-dry}"
TTL=30
TARGETS=(
  "k8s-log-cd57e40ce9a634c1698c2f5c5e09bd93c:ap-southeast-6"   # mnl
  "k8s-log-ca75829e3492d491d9d434de087913798:ap-southeast-1"   # sg
)
LS_BODY='{"logstoreName":"app-file","ttl":30,"shardCount":2,"autoSplit":true,"maxSplitShard":64}'
IDX_BODY="$(cat "$HERE/appfile_index_body.json")"

echo "== EXEC_MODE=$EXEC_MODE @ $(date '+%F %T') =="
for t in "${TARGETS[@]}"; do
  IFS=':' read -r P R <<<"$t"
  printf '%-46s %-16s ' "$P" "$R"
  if aliyun sls GetLogStore --project "$P" --logstore app-file --region "$R" >/dev/null 2>&1; then
    echo "[skip] Logstore 已存在"
  else
    echo "[${EXEC_MODE}] 建 Logstore(app-file, ttl=$TTL, 2 shard)"
    [ "$EXEC_MODE" = apply ] && aliyun sls CreateLogStore --project "$P" --region "$R" \
      --header "Content-Type=application/json" --body "$LS_BODY" 2>&1 | head -c 200
  fi
  cur=$(aliyun sls GetIndex --project "$P" --logstore app-file --region "$R" 2>/dev/null \
        | python3 -c "import sys,json;d=json.load(sys.stdin);i=d.get('index',d);print(i.get('ttl'))" 2>/dev/null)
  if [ -n "$cur" ] && [ "$cur" != "None" ]; then
    echo "  [skip] 索引已存在 (ttl=$cur)"
  else
    echo "  [${EXEC_MODE}] 建全文索引 (ttl=$TTL)"
    [ "$EXEC_MODE" = apply ] && aliyun sls CreateIndex --project "$P" --logstore app-file --region "$R" \
      --header "Content-Type=application/json" --body "$IDX_BODY" 2>&1 | head -c 200
  fi
done
