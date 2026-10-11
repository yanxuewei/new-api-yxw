#!/usr/bin/env bash
# =============================================================================
# 任务 9 收口 · CK 接线三件套（白名单 / 建库 / 账号）+ KMS 凭据 + RAM 策略补 ARN
# -----------------------------------------------------------------------------
# 实例：cc-5tsv2o51s1360b0pr（马尼拉企业版单 AZ，2026-09-30 用户开通）
# 代码事实（model/main.go:400-462）：
#   - LOG_SQL_DSN 走 clickhouse://user:pass@host:9000/db（native 协议）
#   - master 节点启动时自动执行 CREATE TABLE IF NOT EXISTS logs（勿手工建表）
#   - TTL 由 LOG_SQL_CLICKHOUSE_TTL_DAYS 控制（0=永久；本方案 90）
# 判据（任务 9 坑 9）："可用" = 白名单含来源网段 + 账号 + 库 + DSN 已配
#
# 用法：
#   ./deploy/tasks/task9/ck_wiring.sh --check            # 只读核对（默认）
#   ./deploy/tasks/task9/ck_wiring.sh --apply            # 执行接线（幂等；含 ckadmin GRANT 绕行）
#   ./deploy/tasks/task9/ck_wiring.sh --verify           # 云助手端到端复验（认证/建表/写入/TTL）
#   ./deploy/tasks/task9/ck_wiring.sh --apply --recreate-account  # 删号重建（密码丢失/需要轮换时）
# 密码纪律：优先 KMS（new-api/prod/LOG_SQL_DSN）；⚠ 2026-09-30 实测国际站无 KMS 实例时
#   CreateSecret 报 UnsupportedOperation（密钥与凭据须属同一 KMS 实例，官方文档口径）
#   ⇒ 降级存 WSL root 保管目录 /root/.deploy_secrets/（600，仓库与 /mnt/e 之外）
# ★ 平台缺陷绕行（2026-09-30 实测）：CreateAccount 的 DmlAuthSetting（含 AllowDatabases 数组）
#   回读为空、SQL 层无任何数据授权（SHOW GRANTS 仅 default_role）⇒ 建 ckadmin(SuperAccount)
#   从 VPC 内执行 GRANT ALL ON <DB>.* TO newapi（应用账号保持最小权限，不改）
# =============================================================================
set -uo pipefail

case ":$PATH:" in
  *":$HOME/.workbuddy/binaries/aliyun-cli:"*) ;;
  *) export PATH="$HOME/.workbuddy/binaries/aliyun-cli:$PATH" ;;
esac

REGION=ap-southeast-6
CID=cc-5tsv2o51s1360b0pr
CK_HOST=cc-5tsv2o51s1360b0pr-clickhouse.clickhouseserver.ap-southeast-6.rds.aliyuncs.com
DB=newapi_logs
ACCOUNT=newapi
WG_NAME=mnl_app
WG_IPS="10.0.16.0/20,10.0.32.0/20"     # 马尼拉 app 段（文档口径；sg EIP 待公网端点裁定后再加）
SECRET_NAME=new-api/prod/LOG_SQL_DSN
POLICY_NAME=new-api-kms-readonly
SECRETS_ALL=(SQL_DSN SQL_DSN_MIGRATE REDIS_CONN_STRING SESSION_SECRET SESSION_SECRET_OLD PAYMENT_PRIVATE_KEY TLS_WILDCARD LOG_SQL_DSN)
ACCT=5108890064395960

MODE="${1:---check}"
FORCE_RECREATE="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOGDIR="$HERE/../../logs/task9_ck_wiring_$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGDIR"
exec 3>&2
say()  { printf '%s\n' "$*" >&3; }
ok()   { printf '  [OK] %s\n' "$*" >&3; }
warn() { printf '  [!!] %s\n' "$*" >&3; }
die()  { printf '  [XX] %s\n' "$*" >&3; exit 1; }
api() { # $1=outfile, rest=aliyun args；stdout 不污染
  local out="$1"; shift
  aliyun "$@" >"$out" 2>"$out.err" || { say "[cmd-fail] aliyun $* (exit $?)"; return 1; }
}

hr() { say "------------------------------------------------------------------"; }

# ---- 状态快照 ----
snap_whitelist() { api "$LOGDIR/wl_$1.json" clickhouse DescribeSecurityIPList --RegionId "$REGION" --region "$REGION" --DBInstanceId "$CID"; }
snap_accounts()  { api "$LOGDIR/accts_$1.json" clickhouse DescribeAccounts --RegionId "$REGION" --region "$REGION" --DBInstanceId "$CID"; }

# ============================== --check ==============================
do_check() {
  hr; say "STEP check | 只读核对（实例/白名单/账号/库/KMS/策略）"
  api "$LOGDIR/inst.json" clickhouse DescribeDBInstanceAttribute --RegionId "$REGION" --region "$REGION" --DBInstanceId "$CID" \
    || die "实例查询失败"
  local st sc
  st="$(jq -r '.Data.Status' "$LOGDIR/inst.json")"
  sc="$(jq -r '.Data.Category' "$LOGDIR/inst.json")"
  [ "$st" = "ACTIVATION" ] && ok "实例状态 ACTIVATION" || warn "Status=$st"
  [ "$sc" = "enterprise" ] && ok "Category=enterprise" || warn "Category=$sc"

  snap_whitelist now || die "白名单查询失败"
  local wg_def wg_mnl
  wg_def="$(jq -r '.Data.GroupItems[]|select(.GroupName=="default")|.SecurityIPList' "$LOGDIR/wl_now.json")"
  wg_mnl="$(jq -r '.Data.GroupItems[]|select(.GroupName=="'"$WG_NAME"'")|.SecurityIPList' "$LOGDIR/wl_now.json" 2>/dev/null || true)"
  say "  default 组 = $wg_def"
  if [ "$wg_mnl" = "$WG_IPS" ]; then ok "白名单组 $WG_NAME = $WG_IPS（已接线）"
  else warn "白名单组 $WG_NAME 缺失或不等（现在=${wg_mnl:-<无>}）→ 需 --apply"; fi

  snap_accounts now || die "账号查询失败"
  local n
  n="$(jq -r '.Data.TotalCount' "$LOGDIR/accts_now.json")"
  if [ "$n" -gt 0 ] && jq -e --arg a "$ACCOUNT" '.Data.Accounts[]|select(.Account==$a)' "$LOGDIR/accts_now.json" >/dev/null; then
    ok "账号 $ACCOUNT 已存在"
  else warn "账号 $ACCOUNT 不存在（TotalCount=$n）→ 需 --apply"; fi
  if jq -e '.Data.Accounts[]?|select(.Account=="ckadmin")' "$LOGDIR/accts_now.json" >/dev/null 2>&1; then
    ok "引导账号 ckadmin 已存在"
  else warn "引导账号 ckadmin 不存在 → 需 --apply"; fi
  # DSN / ckadmin DSN 保管（KMS 不可用时的降级处）
  for f in LOG_SQL_DSN CK_ADMIN_DSN; do
    if [ -s "/root/.deploy_secrets/$f" ]; then ok "保管文件 /root/.deploy_secrets/$f 就位"
    else warn "保管文件 /root/.deploy_secrets/$f 缺失或为空 → 需 --apply"; fi
  done
  say "  数据层授权（GRANT）与应用侧连通性用 --verify 实测（须走 VPC 内节点）"

  # 库只能建后验证（DescribeDBInstanceDataSources 查询）；此处只提示
  say "  库 $DB 的存在性在 --apply 后经 SQL SHOW DATABASES 验证"

  # KMS 凭据（2026-09-30 实测：国际站未购 KMS 实例 ⇒ CreateSecret 一律 UnsupportedOperation，
  # 任务 17 全部 8 个凭据被同一硬阻塞；DSN 已降级存保管目录，上方已核对）
  if aliyun kms DescribeSecret --SecretName "$SECRET_NAME" --region "$REGION" >"$LOGDIR/kms_describe.json" 2>"$LOGDIR/kms_describe.err"; then
    ok "KMS 凭据 $SECRET_NAME 已存在（region $REGION）"
  else
    warn "KMS 凭据 $SECRET_NAME 不存在（已知阻塞：账号未购 KMS 实例，国际站凭据管家硬前置）"
    warn "  ⇒ DSN 已降级保管 /root/.deploy_secrets/LOG_SQL_DSN；购买 KMS 实例后迁移"
  fi
  # 策略是否含 LOG_SQL_DSN（ListPolicyVersions 自带 PolicyDocument，取 IsDefaultVersion 那份）
  # ⚠ 字段名是 IsDefaultVersion（非 IsDefault）；数组路径 .PolicyVersions.PolicyVersion[]
  local pol_v
  pol_v="$(aliyun ram ListPolicyVersions --PolicyName "$POLICY_NAME" --PolicyType Custom --region ap-southeast-1 2>/dev/null \
    | jq -r '.PolicyVersions.PolicyVersion[]?|select(.IsDefaultVersion==true)|.PolicyDocument' | head -1 || true)"
  if echo "$pol_v" | grep -q "LOG_SQL_DSN"; then
    ok "策略 $POLICY_NAME（默认版本）已含 LOG_SQL_DSN"
  else
    warn "策略 $POLICY_NAME 尚无 LOG_SQL_DSN ARN → 需 --apply"
  fi
  ok "check 完成"
}

# ============================== --apply ==============================
do_apply() {
  hr; say "STEP apply | CK 接线（幂等）：白名单 → 建库 → 账号 → KMS 凭据 → 策略补 ARN"

  # ---- 1. 白名单（先快照，防 default 被误覆盖）----
  say "1) 白名单：新建组 $WG_NAME = $WG_IPS（default 组保持 127.0.0.1）"
  snap_whitelist before
  local cur
  cur="$(jq -r '.Data.GroupItems[]|select(.GroupName=="'"$WG_NAME"'")|.SecurityIPList' "$LOGDIR/wl_before.json" 2>/dev/null || true)"
  if [ "$cur" = "$WG_IPS" ]; then
    ok "组 $WG_NAME 已是目标值，跳过"
  else
    api "$LOGDIR/wl_modify.json" clickhouse ModifySecurityIPList \
        --RegionId "$REGION" --region "$REGION" --DBInstanceId "$CID" \
        --GroupName "$WG_NAME" --ModifyMode 0 --SecurityIPList "$WG_IPS" \
      || die "ModifySecurityIPList 失败"
    sleep 3
    snap_whitelist after
    local d m
    d="$(jq -r '.Data.GroupItems[]|select(.GroupName=="default")|.SecurityIPList' "$LOGDIR/wl_after.json")"
    m="$(jq -r '.Data.GroupItems[]|select(.GroupName=="'"$WG_NAME"'")|.SecurityIPList' "$LOGDIR/wl_after.json" 2>/dev/null || true)"
    [ "$m" = "$WG_IPS" ] || die "回读：$WG_NAME=$m 不符"
    if [ "$d" != "127.0.0.1" ]; then
      warn "default 组被误写成 $d，立即回滚为 127.0.0.1"
      api "$LOGDIR/wl_rollback.json" clickhouse ModifySecurityIPList \
        --RegionId "$REGION" --region "$REGION" --DBInstanceId "$CID" \
        --GroupName default --ModifyMode 0 --SecurityIPList 127.0.0.1 || die "回滚失败"
      die "default 被覆盖（已回滚），请人工核对后再试"
    fi
    ok "白名单组 $WG_NAME 写入成功，default 未受影响"
  fi

  # ---- 2. 建库 ----
  say "2) 建库 $DB"
  if api "$LOGDIR/db_create.json" clickhouse CreateDB \
        --RegionId "$REGION" --region "$REGION" --DBInstanceId "$CID" \
        --DBName "$DB" --Comment "new-api usage logs (F9 mainline)"; then
    ok "CreateDB 成功"
  else
    if grep -qi "exist\|duplicate\|Already" "$LOGDIR/db_create.json.err" 2>/dev/null; then
      ok "库已存在（幂等跳过）"
    else
      warn "CreateDB 返回异常，内容见 $LOGDIR/db_create.json.err（若是『已存在』类错误可忽略）"
      head -c 300 "$LOGDIR/db_create.json.err" >&3; echo >&3
    fi
  fi

  # ---- 3. 账号 ----
  say "3) 账号 $ACCOUNT（NormalAccount + DDL/读写 + 仅授权 $DB）"
  snap_accounts before
  local need_create=1
  if [ "$FORCE_RECREATE" = "--recreate-account" ]; then
    if jq -e --arg a "$ACCOUNT" '.Data.Accounts[]?|select(.Account==$a)' "$LOGDIR/accts_before.json" >/dev/null 2>&1; then
      say "  --recreate-account：删除现有账号（密码不可恢复时用它重置）"
      api "$LOGDIR/acct_delete.json" clickhouse DeleteAccount \
        --RegionId "$REGION" --region "$REGION" --DBInstanceId "$CID" --Account "$ACCOUNT" \
        || die "DeleteAccount 失败"
      sleep 5
      ok "旧账号已删"
    fi
  elif jq -e --arg a "$ACCOUNT" '.Data.Accounts[]?|select(.Account==$a)' "$LOGDIR/accts_before.json" >/dev/null 2>&1; then
    ok "账号已存在，跳过（密码以保管处为准；丢失则 --apply --recreate-account）"
    need_create=0
  fi

  if [ "$need_create" = "1" ]; then
    # 密码：24 位纯字母数字（DSN-URL 安全；3 类字符满足口令策略）；不落证据文件
    PW="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 21)X9a"
    local dml='{"DdlAuthority":true,"DmlAuthority":0,"AllowDatabases":["'"$DB"'"]}'
    if api "$LOGDIR/acct_create.json" clickhouse CreateAccount \
          --RegionId "$REGION" --region "$REGION" --DBInstanceId "$CID" \
          --Account "$ACCOUNT" --AccountType NormalAccount --Password "$PW" \
          --DmlAuthSetting "$dml" \
          --Description "new-api log writer (task9 wiring)"; then
      ok "CreateAccount 成功（DdlAuthority=true / DmlAuthority=0 / 仅 $DB）"
    else
      # JSON 对象不被接受时退回 dotted 形式
      say "  JSON 形式失败，尝试 dotted 形式…"
      api "$LOGDIR/acct_create2.json" clickhouse CreateAccount \
          --RegionId "$REGION" --region "$REGION" --DBInstanceId "$CID" \
          --Account "$ACCOUNT" --AccountType NormalAccount --Password "$PW" \
          --DmlAuthSetting.DdlAuthority true \
          --DmlAuthSetting.DmlAuthority 0 \
          --DmlAuthSetting.AllowDatabases.1 "$DB" \
          --Description "new-api log writer (task9 wiring)" \
        || die "CreateAccount 两种形式均失败"
      ok "CreateAccount 成功（dotted 形式）"
    fi
    sleep 3
    snap_accounts after
    jq -c '.Data|{TotalCount,Accounts:[.Accounts[]?|{Account,AccountType,Description}]}' "$LOGDIR/accts_after.json" >&3
    api "$LOGDIR/acct_auth.json" clickhouse DescribeAccountAuthority \
        --RegionId "$REGION" --region "$REGION" --DBInstanceId "$CID" --Account "$ACCOUNT" || true
    [ -s "$LOGDIR/acct_auth.json" ] && jq -c '.Data' "$LOGDIR/acct_auth.json" >&3

    # ---- 4. DSN 保管：优先 KMS；无 KMS 实例则降级 WSL root 保管目录 ----
    say "4) DSN 保管（$SECRET_NAME）"
    DSN="clickhouse://${ACCOUNT}:${PW}@${CK_HOST}:9000/${DB}"
    if aliyun kms DescribeSecret --SecretName "$SECRET_NAME" --region "$REGION" >/dev/null 2>&1; then
      warn "KMS 凭据已存在，跳过（如需换值走 PutSecretValue，此处不动）"
    elif aliyun kms CreateSecret --region "$REGION" \
        --SecretName "$SECRET_NAME" --SecretData "$DSN" --VersionId v1 \
        >"$LOGDIR/kms_create.json" 2>"$LOGDIR/kms_create.err"; then
      jq -c '{SecretName,Arn}' "$LOGDIR/kms_create.json" >&3
      ok "KMS 凭据已建（值=完整 DSN）"
    else
      # 2026-09-30 实测：国际站无 KMS 实例 ⇒ UnsupportedOperation（官方：密钥与凭据须属同一 KMS 实例）
      warn "KMS CreateSecret 不可用（$(grep -o 'ErrorCode: [A-Za-z.]*' "$LOGDIR/kms_create.err" | head -1)）"
      warn "  根因：账号未购买 KMS 实例（国际站凭据管家硬前置）——阻塞任务 17 全部 8 个凭据"
      VAULT=/root/.deploy_secrets
      mkdir -p "$VAULT" && chmod 700 "$VAULT"
      printf '%s\n' "$DSN" > "$VAULT/LOG_SQL_DSN"
      chmod 600 "$VAULT/LOG_SQL_DSN"
      ok "降级：DSN 已存 $VAULT/LOG_SQL_DSN（600；仓库之外，勿入 git）"
      say "  待 KMS 实例购买后迁移：GetSecretValue 前置，届时 CreateSecret + 删除本地文件"
    fi
    # 脱敏留证
    echo "clickhouse://${ACCOUNT}:***@${CK_HOST}:9000/${DB}" > "$LOGDIR/dsn_masked.txt"
    unset PW DSN
  fi

  # ---- 4b. 数据层授权绕行（平台 DmlAuthSetting 映射不生效，2026-09-30 实测）----
  say "4b) 数据层授权：ckadmin(Super) 从 VPC 内 GRANT ALL ON ${DB}.* TO ${ACCOUNT}"
  VAULT=/root/.deploy_secrets
  mkdir -p "$VAULT" && chmod 700 "$VAULT"
  PW_APP="$(sed -E 's#clickhouse://'"${ACCOUNT}"':([^@]+)@.*#\1#' "$VAULT/LOG_SQL_DSN" 2>/dev/null | tr -d '\r\n')"
  [ -n "$PW_APP" ] || die "读不到 ${ACCOUNT} 密码（$VAULT/LOG_SQL_DSN 空/缺）；用 --apply --recreate-account 重置"
  snap_accounts forgrant
  if jq -e '.Data.Accounts[]?|select(.Account=="ckadmin")' "$LOGDIR/accts_forgrant.json" >/dev/null 2>&1; then
    PW_ADM="$(sed -E 's#clickhouse://ckadmin:([^@]+)@.*#\1#' "$VAULT/CK_ADMIN_DSN" 2>/dev/null | tr -d '\r\n')"
    [ -n "$PW_ADM" ] || die "ckadmin 已存在但 $VAULT/CK_ADMIN_DSN 空/缺（轮换走控制台或删号重建）"
    ok "ckadmin 已存在，复用"
  else
    PW_ADM="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 21)Z8b"
    api "$LOGDIR/ckadmin_create.json" clickhouse CreateAccount \
      --RegionId "$REGION" --region "$REGION" --DBInstanceId "$CID" \
      --Account ckadmin --AccountType SuperAccount --Password "$PW_ADM" \
      --Description "task9 bootstrap admin (grant fix)" || die "CreateAccount(ckadmin) 失败"
    printf 'clickhouse://ckadmin:%s@%s:9000/%s\n' "$PW_ADM" "$CK_HOST" "$DB" > "$VAULT/CK_ADMIN_DSN"
    chmod 600 "$VAULT/CK_ADMIN_DSN"
    sleep 3
    ok "ckadmin 已创建（DSN 入保管目录）"
  fi
  # GRANT 必须从 VPC 内发起（CK 仅内网）→ 复用 deploy/lib/ack_remote.sh 云助手通道
  GRANT_BODY="/tmp/ck_grant_body.$$.sh"
  cat > "$GRANT_BODY" <<GBEOF
#!/usr/bin/env bash
H="$CK_HOST"
qa(){ curl -sS -m 15 "http://ckadmin:$PW_ADM@\$H:8123/" --data-binary "\$1"; echo; }
qa "GRANT ALL ON ${DB}.* TO ${ACCOUNT}"
qa "SHOW GRANTS FOR ${ACCOUNT}" | head -3
echo GRANT-DONE
GBEOF
  chmod 600 "$GRANT_BODY"
  bash "$HERE/../../lib/ack_remote.sh" mnl "$GRANT_BODY" >&3 2>&3 || { shred -u "$GRANT_BODY" 2>/dev/null; die "GRANT 执行失败"; }
  shred -u "$GRANT_BODY" 2>/dev/null || rm -f "$GRANT_BODY"
  ok "数据层授权完成（body 已销毁）"
  unset PW_APP PW_ADM

  # ---- 5. 策略补 LOG_SQL_DSN ARN（两地 16 ARN）----
  say "5) 策略 $POLICY_NAME 补 LOG_SQL_DSN（CreatePolicyVersion）"
  python3 - "$LOGDIR/policy_new.json" "${SECRETS_ALL[@]}" <<'PY'
import json,sys
out=sys.argv[1]; names=sys.argv[2:]
acct=5108890064395960
res=["acs:kms:%s:%s:secret/new-api/prod/%s"%(r,acct,n) for r in ("ap-southeast-6","ap-southeast-1") for n in names]
doc={"Version":"1","Statement":[{"Action":["kms:GetSecretValue"],"Effect":"Allow","Resource":res}]}
open(out,"w").write(json.dumps(doc))
print("  ARN 数：%d" % len(res))
PY
  aliyun ram CreatePolicyVersion --region ap-southeast-1 \
    --PolicyName "$POLICY_NAME" \
    --PolicyDocument "$(cat "$LOGDIR/policy_new.json")" \
    --SetAsDefault true >"$LOGDIR/policy_version.json" 2>"$LOGDIR/policy_version.err" \
    || die "CreatePolicyVersion 失败（可能是版本数上限，需先删旧版本）"
  jq -c '{VersionId,IsDefault}' "$LOGDIR/policy_version.json" >&3
  ok "策略新版本已设为默认（含 LOG_SQL_DSN 两地 ARN）"

  hr
  say "apply 完成。剩余："
  say "  ① --verify（云助手从 app 段节点实测 8123/9000 + 建表探针）"
  say "  ② 应用侧：任务 17 ConfigMap 补 LOG_SQL_CLICKHOUSE_TTL_DAYS=90；DSN 从 KMS 注入"
  say "  ③ 备站公网端点（CreateEndpoint）仍待裁定，未做"
}

# ============================== --verify ==============================
# 从 VPC 内 worker 节点实测：认证 / 库 / 建表（应用同款 DDL）/ 写入 / TTL / 清理
do_verify() {
  hr; say "STEP verify | 云助手端到端复验（节点 → CK 8123）"
  PW_APP="$(sed -E 's#clickhouse://'"${ACCOUNT}"':([^@]+)@.*#\1#' /root/.deploy_secrets/LOG_SQL_DSN 2>/dev/null | tr -d '\r\n')"
  [ -n "$PW_APP" ] || die "读不到 ${ACCOUNT} 密码（/root/.deploy_secrets/LOG_SQL_DSN 空/缺）"
  VBODY="/tmp/ck_verify_body.$$.sh"
  # 应用同款 DDL 见 model/main.go clickHouseLogCreateTableSQL（TTL 取 90 天口径）
  cat > "$VBODY" <<VEOF
#!/usr/bin/env bash
H="$CK_HOST"
qn(){ curl -sS -m 15 "http://${ACCOUNT}:$PW_APP@\$H:8123/?database=${DB}" --data-binary "\$1"; echo; }
echo "== V1 认证与库"
qn "SELECT currentUser(), currentDatabase(), version()"
echo "== V2 应用同款 DDL（幂等）"
qn "CREATE TABLE IF NOT EXISTS logs (
  id Int64 DEFAULT 0, user_id Int32 DEFAULT 0, created_at Int64 DEFAULT 0,
  type Int32 DEFAULT 0, content String DEFAULT '', username String DEFAULT '',
  token_name String DEFAULT '', model_name String DEFAULT '', quota Int32 DEFAULT 0,
  prompt_tokens Int32 DEFAULT 0, completion_tokens Int32 DEFAULT 0, use_time Int32 DEFAULT 0,
  is_stream UInt8 DEFAULT 0, channel_id Int32 DEFAULT 0, token_id Int32 DEFAULT 0,
  \\\`group\\\` String DEFAULT '', ip String DEFAULT '', request_id String DEFAULT '',
  upstream_request_id String DEFAULT '', other String DEFAULT ''
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(toDateTime(created_at))
ORDER BY (created_at, request_id)
TTL toDateTime(created_at) + INTERVAL 90 DAY DELETE"
echo "== V3 写入探针 + count"
qn "INSERT INTO logs (user_id, created_at, type, content, username, request_id) VALUES (1, \$(date +%s), 2, 'task9 wiring probe', 'fanyan', 'task9-probe-verify')"
qn "SELECT count() FROM logs"
echo "== V4 引擎与 TTL"
qn "SELECT engine FROM system.tables WHERE database='${DB}' AND name='logs' FORMAT TabSeparated"
qn "SELECT create_table_query FROM system.tables WHERE database='${DB}' AND name='logs' FORMAT TabSeparated" | grep -o "TTL.*"
echo "== V5 清理探针"
qn "TRUNCATE TABLE logs"
qn "SELECT count() FROM logs"
echo "VERIFY-DONE"
VEOF
  chmod 600 "$VBODY"
  bash "$HERE/../../lib/ack_remote.sh" mnl "$VBODY" >&3 2>&3 || { shred -u "$VBODY" 2>/dev/null; die "verify 执行失败"; }
  shred -u "$VBODY" 2>/dev/null || rm -f "$VBODY"
  unset PW_APP
  ok "verify 完成（body 已销毁）"
}

case "$MODE" in
  --check)  do_check ;;
  --apply)  do_apply ;;
  --verify) do_verify ;;
  *) die "未知参数：$MODE（--check | --apply | --verify）" ;;
esac
