#!/bin/bash
# ci_check_env_isolation.sh — 非生产清单不得指向生产资源（硬门禁）
#
# 来源：任务45:380 的 CI 规则「DSN 含 pgm-5tstdhko64x2c01w 且 ns≠new-api 即 fail」的实现，
#       外加 4 条本仓实测出来的坑。风格对齐 deploy/ops/ci_check_migrate_versioned.sh。
#
# usage:
#   bash deploy/staging/ci_check_env_isolation.sh            # 检查 staging 清单目录
#   STRICT=1 bash deploy/staging/ci_check_env_isolation.sh    # WARN 也计入失败（G8 合并后升级用）
#   非零退出 = 门禁不通过，禁止合并/apply。
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"   # → deploy/

STAGING_DIR="${STAGING_DIR:-staging}"
FAIL=0; WARN=0
ok(){ printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
warn(){ printf '  \033[33mWARN\033[0m %s\n' "$*"; WARN=$((WARN+1)); }

# 生产资源标识（出现即说明非生产清单接了生产）
PROD_RDS="pgm-5tstdhko64x2c01w"
PROD_RDS_IP_PRIV="10.0.69.77"
PROD_RDS_IP_PUB="43.118.96.65"
PROD_TAIR="r-5tsf1fe16543e274"
PROD_TAIR_HOST="tair-mnl-newapi"
PROD_NS="new-api"

# 扫描范围：**只有 manifests/**（集群侧真实下发的对象）。
# ⚠ 不扫 *.sh：task55_staging_apply.sh 的 --verify 里**故意**写了一条"staging Pod 连 prod RDS 必须失败"
#   的反向探针（10.0.69.77 / 43.118.96.65），扫脚本会把它误判成引用生产资源。
# 同时忽略注释行（清单头部大量引用生产实例 ID 作为反例说明）。
FILES=$(find "$STAGING_DIR/manifests" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
[ -n "$FILES" ] || { echo "FATAL: $STAGING_DIR/manifests 下无清单文件"; exit 2; }
# 去掉注释后的副本（放 /tmp，避免污染 Git）
SCAN_DIR=$(mktemp -d)
trap 'rm -rf "$SCAN_DIR"' EXIT
for f in $FILES; do
  cp "$f" "$SCAN_DIR/$(basename "$f")"
  sed -i '/^[[:space:]]*#/d' "$SCAN_DIR/$(basename "$f")"
done
SCAN=$(find "$SCAN_DIR" -type f | sort)

echo "=== 0. 扫描范围 ==="
printf '  文件数：%s（已剔除注释行）\n' "$(echo "$SCAN" | wc -l)"

echo "=== 1. 生产 RDS 实例标识不得出现在非生产清单（任务45:380）==="
if grep -rnE "$PROD_RDS|$PROD_RDS_IP_PRIV|$PROD_RDS_IP_PUB" $SCAN >/dev/null 2>&1; then
  grep -rnE "$PROD_RDS|$PROD_RDS_IP_PRIV|$PROD_RDS_IP_PUB" $SCAN
  bad "清单引用了生产 RDS（实例/私网/公网 IP 任一）"
else
  ok "无生产 RDS 引用"
fi

echo "=== 2. 生产 Tair 不得被非生产使用（键无前缀 + 共用 DB0 ⇒ 限流互相污染）==="
if grep -rnE "$PROD_TAIR|$PROD_TAIR_HOST" $SCAN >/dev/null 2>&1; then
  grep -rnE "$PROD_TAIR|$PROD_TAIR_HOST" $SCAN
  bad "清单引用了生产 Tair 实例"
else
  ok "无生产 Tair 引用（staging 用集群内 redis-staging）"
fi

echo "=== 3. 非生产清单不得使用生产 namespace: $PROD_NS ==="
if grep -rnE "^[[:space:]]*namespace:[[:space:]]*${PROD_NS}[[:space:]]*$" $SCAN >/dev/null 2>&1; then
  grep -rnE "^[[:space:]]*namespace:[[:space:]]*${PROD_NS}[[:space:]]*$" $SCAN
  bad "出现 namespace: new-api（生产 ns）"
else
  ok "所有对象都在 new-api-staging"
fi
if ! grep -rq "name: new-api-staging" $SCAN 2>/dev/null; then
  warn "未找到 new-api-staging 资源名，确认目录内容是否为空壳"
fi

echo "=== 4. NODE_TYPE 必须显式 slave（留空即 master ⇒ 启动发 AutoMigrate DDL）==="
if [ -f "$STAGING_DIR/manifests/60-deployment.yaml" ]; then
  if grep -qE '^[[:space:]]*value:[[:space:]]*"slave"' "$STAGING_DIR/manifests/60-deployment.yaml"; then
    ok "Deployment 显式 NODE_TYPE=slave"
  else
    bad "Deployment 缺 NODE_TYPE=slave（common/init.go:89 是 != \"slave\" 字符串判断）"
  fi
  if grep -qE '^[[:space:]]*value:[[:space:]]*"master"' "$STAGING_DIR/manifests/60-deployment.yaml"; then
    bad "Deployment 写了 NODE_TYPE=master ⇒ staging Pod 会发 DDL"
  fi
fi

echo "=== 5. MEMORY_CACHE_ENABLED 在多副本下必须 false（余额随机跳变，part2a:481）==="
REPLICAS=$(sed -n 's/^  replicas:[[:space:]]*\([0-9]\+\)[[:space:]]*$/\1/p' "$STAGING_DIR/manifests/60-deployment.yaml" 2>/dev/null | head -1)
REPLICAS="${REPLICAS:-1}"
if [ "${REPLICAS}" -gt 1 ] 2>/dev/null; then
  if grep -qE 'MEMORY_CACHE_ENABLED["'\'']?:[[:space:]]*["'\'']?true' "$STAGING_DIR/manifests/60-deployment.yaml"; then
    bad "replicas=$REPLICAS 且 MEMORY_CACHE_ENABLED=true"
  else
    ok "replicas=$REPLICAS，MEMORY_CACHE_ENABLED 非 true"
  fi
else
  ok "单副本（MEMORY_CACHE_ENABLED 允许为 true，但本清单刻意保持 false）"
fi

echo "=== 6. Secret 值不得入 Git（KMS弃用裁定 / Day2任务17:129）==="
if grep -rn 'REPLACE_ME' "$STAGING_DIR/manifests" 2>/dev/null | grep -qE "REPLACE_ME[A-Za-z0-9]{20,}"; then
  bad "占位符形态异常（疑似被真实值替换）"
elif grep -rnE "(SESSION_SECRET|SQL_DSN|SQL_DSN_MIGRATE|LOG_SQL_DSN|REDIS_CONN_STRING):" \
      "$STAGING_DIR/manifests" 2>/dev/null | grep -vE "REPLACE_ME|valueFrom|secretKeyRef|#" >/dev/null; then
  grep -rnE "(SESSION_SECRET|SQL_DSN|SQL_DSN_MIGRATE|LOG_SQL_DSN|REDIS_CONN_STRING):" \
    "$STAGING_DIR/manifests" 2>/dev/null | grep -vE "REPLACE_ME|valueFrom|secretKeyRef|#"
  bad "疑似明文密钥入库（模板里只允许 REPLACE_ME_* 占位）"
else
  ok "Secret 模板只含 REPLACE_ME_* 占位"
fi
if grep -rn "password\|passwd" "$STAGING_DIR/manifests" 2>/dev/null \
   | grep -viE "requirepass|REPLACE_ME|passwd-\\\$|SecretKeyRef|key: password|^[^:]+:[0-9]+:[[:space:]]*#" >/dev/null; then
  warn "清单里出现 password 字面量，请人工复核"
fi

echo "=== 7. 生产 SessionSecret 同值偏差的继承检查（O4/C3，需集群侧实测）==="
warn "本门禁无法读取集群 Secret。apply 前必须人工比对：
      staging SESSION_SECRET 的 sha256[:12] != prod 的（现两地域 prod 同值 c5fbe2dbc89b，len 42）
      命令：kubectl -n new-api-staging get secret new-api-staging-secrets -o jsonpath='{.data.SESSION_SECRET}' | base64 -d | sha256sum | cut -c1-12"

echo "=== 8. 结构性不可达（CEN / VPC peer 必须恒为 0，任务45:E12）==="
if [ "${CHECK_CLOUD:-0}" = "1" ] && [ -n "${ALI_PROFILE:-}" ]; then
  CEN=$(aliyun --profile "$ALI_PROFILE" cbn DescribeCens | python3 -c 'import sys,json;print(json.load(sys.stdin)["Cens"]["Cen"].__len__())' 2>/dev/null || echo "?")
  PEER=$(aliyun --profile "$ALI_PROFILE" vpcpeer ListVpcPeerConnections | python3 -c 'import sys,json;print(len(json.load(sys.stdin).get("VpcPeerConnections",[])))' 2>/dev/null || echo "?")
  if [ "$CEN" = "0" ] && [ "$PEER" = "0" ]; then ok "CEN=0 且 VPC peer=0"; else bad "出现 CEN=$CEN / peer=$PEER ⇒ 非生产到生产的内网路径被打通"; fi
else
  warn "未开 CHECK_CLOUD=1，跳过 CEN/VPC peer 云端断言"
fi

echo
if [ "${STRICT:-0}" = "1" ] && [ "$WARN" -gt 0 ]; then FAIL=$((FAIL+1)); fi
printf '===== ci_check_env_isolation: FAIL=%d WARN=%d =====\n' "$FAIL" "$WARN"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
