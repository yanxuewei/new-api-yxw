#!/usr/bin/env bash
# =============================================================================
# ⚠ DEPRECATED（2026-10-20 起）—— 本文件走的是「旧名对象」链路，勿再执行
#   pre / perf 的负载已按 pod 名重建（fanyan 2026-10-20 裁定）：
#     new-api-pre         → pre-new-api-master      （无 Service，不接流量）
#     new-api-pre-slave   → pre-new-api-slave       （唯一 Service，Ingress 后端）
#     new-api-perf        → perf-new-api-master     （无 Service，不接流量）
#     new-api-perf-slave  → perf-new-api-slave      （唯一 Service，Ingress 后端）
#   本文件会渲染 / apply `deploy/jakarta_{pre,perf}/manifests/legacy/new-api-{pre,perf}.yaml`（旧清单），
#   或按 APP=new-api-pre|new-api-perf 这一旧标签选 pod ⇒ 重跑会重建旧对象、
#   让新对象与旧对象抢标签，或让诊断「查不到任何 pod」。**不要重跑**。
#   权威 IaC：deploy/jakarta_pre/manifests/pre-master-slave.yaml
#              deploy/jakarta_perf/manifests/perf-master-slave.yaml
#   弃用说明与新旧对照：deploy/jakarta_pre/DEPRECATED.md
#   注意：命名空间 new-api-pre / new-api-perf 本身**未改名**。
# =============================================================================
# =============================================================================
# deploy/jakarta_pre/scripts/pre_deploy.sh —— 雅加达 pre / perf 底座执行器（任务 45 改写版）
#
# 通道：deploy/lib/ack_remote_jkt_dev.sh（ECS 云助手 → 节点内 kubectl，15 分钟临时私网 kubeconfig）
#   该通道只服务雅加达集群 cb0abf5bc06034f7bbdb991752f6f3e62（ap-southeast-5）⇒ 结构上打不到马尼拉。
#
# 结构：远端脚本 = 静态 body（deploy/jakarta_pre/bodies/*.sh）+ 本地拼的 header（临时目录 + 载荷）。
#
# 子命令：
#   --ns-base               建 new-api-pre / new-api-perf 的 Namespace/Quota/SA（幂等，只写这两 ns）
#   --addon-verify          只读：免密组件作用域双路取证（CS API + 集群内 SA/Secret）
#   --pull-check <ns>       只读：指定 ns 里探针 Pod 能否拉到镜像（不落业务负载）
#
# 凭据纪律：本执行器当前步骤**不投递任何凭据**；Secret 面走后续 --apply-pre（沿用 dev 的保管目录口径）。
# =============================================================================
set -uo pipefail

REGION=ap-southeast-5
CID=cb0abf5bc06034f7bbdb991752f6f3e62
ADDON=managed-aliyun-acr-credential-helper
DEV_NS=newapi-dev
APP_SA=new-api-app
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # deploy/jakarta_pre/scripts
ENVDIR="$(cd "$HERE/.." && pwd)"                        # deploy/jakarta_pre
ROOT="$(cd "$HERE/../../.." && pwd)"                    # 仓库根
BODIES="$ENVDIR/bodies"                                 # pre 专属 body（剩 3 个）
OPS_BODIES="$ROOT/deploy/ops/bodies"                    # 跨环境/环境无关 body（2026-10-20 迁入）
REMOTE="$ROOT/deploy/lib/ack_remote_jkt_dev.sh"
WORK=$(mktemp -d); chmod 700 "$WORK"; trap 'rm -rf "$WORK"' EXIT

notice() { echo "[pre-deploy] $*"; }
die() { echo "[pre-deploy][!] $*" >&2; exit 1; }

header() {
  cat <<HDR
#!/bin/bash
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/local/bin:\$PATH
T=\$(mktemp -d); chmod 700 \$T
mkdir -p \$T/payload; chmod 700 \$T
HDR
  local pair
  for pair in "$@"; do printf 'export %s=%s\n' "${pair%%=*}" "'${pair#*=}'"; done
}

run_body() {
  local bname="$1" tag="$2"; shift 2
  # body 解析顺序：pre 专属 → deploy/ops/bodies（2026-10-20 起跨环境 body 统一放那里）
  local src=""
  [ -s "$BODIES/$bname" ] && src="$BODIES/$bname"
  [ -n "$src" ] || { [ -s "$OPS_BODIES/$bname" ] && src="$OPS_BODIES/$bname"; }
  [ -n "$src" ] || die "缺 body：$BODIES/$bname 或 $OPS_BODIES/$bname"
  local full="$WORK/full_${tag}.sh"
  { header "$@"; cat "$src"; } > "$full"
  chmod 700 "$full"
  notice "→ 云助手调用（$tag，body=$src，载荷 $(( $# )) 项，命令体 $(wc -c <"$full") 字节）"
  bash "$REMOTE" "$full" || die "远端调用失败（$tag）"
}

ns_base() {
  if [ -n "${ONLY:-}" ]; then
    case "$ONLY" in new-api-pre|new-api-perf) : ;; *) die "--ns-base 的 ONLY 只能是 new-api-pre / new-api-perf（当前='$ONLY'）" ;; esac
    notice "只建一个 ns：$ONLY"
    run_body create_ns.sh creans "ONLY=$ONLY"
  else
    run_body create_ns.sh creans
  fi
}
addon_verify() {
  notice "S1 云侧组件配置（值打码，只留作用域结构）"
  aliyun cs GET "/clusters/$CID/addon_instances/$ADDON" --region "$REGION" 2>&1 \
    | sed -E 's/"(auth|password|token|secret|username)"[[:space:]]*:[[:space:]]*"[^"]*"/"\1":"***"/gi' \
    | tr ',' '\n' | sed -E 's/^([[:space:]]*)"/\1/' | cut -c1-200 | sed 's/^/  /'
  notice "S2–S5 集群内取证（只读）"
  run_body verify_addon_scope.sh addverify
}
pull_check() {
  [ -n "${TGT:-}" ] || die "--pull-check 必须给第二参命名空间（new-api-pre / new-api-perf）"
  case "$TGT" in new-api-pre|new-api-perf) : ;; *) die "--pull-check 只允许 new-api-pre / new-api-perf（当前='$TGT'）" ;; esac
  run_body pull_probe.sh pullprobe "NS=$TGT"
}

db_ports() { run_body probe_db_ports.sh dbports; }

# ---- 步骤 4：建独立库 + 落权限链 ----
RDS=pgm-d9j9p421lzx4gw73
RDS_HOST=$RDS.pgsql.ap-southeast-5.rds.aliyuncs.com
SEC_DIR=/root/.deploy_secrets_dev
GRANTS_SRC="$ENVDIR/sql/pre_grants.sql"
DBS=(newapi_pre newapi_perf)
OPS_ACCT=newapi_ops          # 唯一拿 DBOwner 的账号（dev 现网终态一致）；绝不给业务账号提 DBOwner（坑 11）
fp() { printf '%s' "$1" | sha256sum | cut -c1-12; }
mask() { sed -E -e 's/(password=)[^ ]*/\1***/g' -e 's#://([^:/]+):[^@]*@#://\1:***@#g' <<<"$1"; }

db_state() {  # 只读回读：库清单 + 账号授权账目
  notice "== 库 =="
  aliyun rds DescribeDatabases --RegionId "$REGION" --DBInstanceId "$RDS" 2>&1 \
    | jq -r '.Databases.Database[] | "  \(.DBName)  status=\(.DBStatus)  char=\(.CharacterSetName)  desc=\(.DBDescription // "-")"'
  notice "== 账号授权（只打印账号/类型/库:权限，无凭据）=="
  aliyun rds DescribeAccounts --RegionId "$REGION" --DBInstanceId "$RDS" 2>&1 \
    | jq -c '[.Accounts.DBInstanceAccount[] | {a:.AccountName, t:.AccountType, s:.AccountStatus, p:[.DatabasePrivileges.DatabasePrivilege[]? | {d:.DBName, priv:.AccountPrivilege}]}]'
}

create_db() {
  local list="${DBS[*]}"
  if [ -n "${ONLY:-}" ]; then
    case " ${DBS[*]} " in *" $ONLY "*) list="$ONLY" ;; *) die "--create-db 的 ONLY 只能是 ${DBS[*]}（当前='$ONLY'）" ;; esac
  fi
  local D cur
  for D in $list; do
    notice "== $D"
    cur=$(aliyun rds DescribeDatabases --RegionId "$REGION" --DBInstanceId "$RDS" --DBName "$D" 2>/dev/null \
          | jq -r '.Databases.Database[0].DBStatus // "none"')
    if [ "$cur" = Running ]; then
      notice "  已存在（status=Running）⇒ 跳过 CreateDatabase（幂等）"
    else
      notice "  CreateDatabase（CharacterSetName=UTF8，不指定 TEMPLATE——拷模板会把结构连同数据一起带来）…"
      aliyun rds CreateDatabase --RegionId "$REGION" --DBInstanceId "$RDS" \
        --DBName "$D" --CharacterSetName UTF8 \
        --DBDescription "jakarta pre/perf (task45) $D" 2>&1 | head -6 | sed 's/^/    /'
    fi
  done
  db_state
  notice "== 达权前置：把 $OPS_ACCT 提为这两库 owner（dev 现网同口径；不给业务账号提）"
  for D in $list; do
    cur=$(aliyun rds DescribeAccounts --RegionId "$REGION" --DBInstanceId "$RDS" --AccountName "$OPS_ACCT" 2>/dev/null \
          | jq -r --arg db "$D" '[.Accounts.DBInstanceAccount[].DatabasePrivileges.DatabasePrivilege[]?
                                 | select(.DBName==$db) | .AccountPrivilege] | join(",")')
    if [ "$cur" = DBOwner ]; then notice "  [$OPS_ACCT/$D] 已是 DBOwner，跳过"; continue; fi
    aliyun rds GrantAccountPrivilege --RegionId "$REGION" --DBInstanceId "$RDS" \
      --AccountName "$OPS_ACCT" --DBName "$D" --AccountPrivilege DBOwner 2>&1 | head -4 | sed 's/^/    /'
    notice "  回读 [$OPS_ACCT/$D] = $(aliyun rds DescribeAccounts --RegionId "$REGION" --DBInstanceId "$RDS" --AccountName "$OPS_ACCT" 2>/dev/null \
      | jq -r --arg db "$D" '[.Accounts.DBInstanceAccount[].DatabasePrivileges.DatabasePrivilege[]? | select(.DBName==$db) | .AccountPrivilege] | join(",")')"
  done
}

apply_grants_pre() {
  [ -s "$GRANTS_SRC" ] || die "缺 $GRANTS_SRC"
  [ -s "$SEC_DIR/dev_ops" ] || die "缺 $SEC_DIR/dev_ops（授权 SQL 需要 newapi_ops）"
  mkdir -p "$WORK/sec"; chmod 700 "$WORK/sec"
  # DSN 一律 5432 直连：DDL 走池没有收益，反而多一层"池没配好"的干扰变量
  local ops; ops=$(cat "$SEC_DIR/dev_ops")
  printf 'postgres://newapi_ops:%s@%s:5432/newapi_pre?sslmode=require'  "$ops" "$RDS_HOST" > "$WORK/sec/DSN_OPS_PRE"
  printf 'postgres://newapi_ops:%s@%s:5432/newapi_perf?sslmode=require' "$ops" "$RDS_HOST" > "$WORK/sec/DSN_OPS_PERF"
  cp "$GRANTS_SRC" "$WORK/sec/grants.sql"
  chmod 600 "$WORK/sec"/*
  unset ops
  notice "载荷：DSN_OPS_PRE fp=$(fp "$(cat "$WORK/sec/DSN_OPS_PRE")")  DSN_OPS_PERF fp=$(fp "$(cat "$WORK/sec/DSN_OPS_PERF")")  grants=$(wc -l <"$WORK/sec/grants.sql") 行"
  notice "  打码：$(mask "$(cat "$WORK/sec/DSN_OPS_PRE")") / $(mask "$(cat "$WORK/sec/DSN_OPS_PERF")")"
  run_body apply_pre_grants.sh pregrants "SEC_B64=$(pack_dir "$WORK/sec")"
  rm -rf "$WORK/sec"
  db_state
}
pack_dir() { (cd "$1" && tar cz . ) | base64 -w0; }

dev_baseline() { run_body inspect_dev_baseline.sh devbaseline; }

# ---- 步骤 5：pre 的 Secret / 清单 / 冒烟 ----
PRE_MANIFEST="$ENVDIR/manifests/legacy/new-api-pre.yaml"
PRE_NS=new-api-pre

gen_pre_secret() {  # 幂等：只在文件不存在时生成；口令只落保管目录（600），永不进命令体/台账
  mkdir -p "$SEC_DIR"; chmod 700 "$SEC_DIR"
  [ -s "$SEC_DIR/dev_app" ] && [ -s "$SEC_DIR/dev_migrate" ] || die "缺 dev_app/dev_migrate（pre 复用同一批账号，不新建口令）"
  if [ ! -s "$SEC_DIR/pre_session_secret" ]; then
    local s; s=$(head -c 2048 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-21)
    [ "${#s}" -ge 16 ] || die "随机 SESSION_SECRET 生成异常"
    printf '%s' "$s" > "$SEC_DIR/pre_session_secret"; chmod 600 "$SEC_DIR/pre_session_secret"
    notice "pre_session_secret 已生成 len=${#s} fp=$(fp "$s")（与 dev/prod 无关的新值）"
    unset s
  else
    v=$(cat "$SEC_DIR/pre_session_secret"); notice "pre_session_secret 已存在 len=${#v} fp=$(fp "$v")（幂等复用）"; unset v
  fi
  local app mig
  app=$(cat "$SEC_DIR/dev_app"); mig=$(cat "$SEC_DIR/dev_migrate")
  # 端口 6432 = 托管池（session 模式）；这是卡片偏差②，也是"池在承载业务"的端到端判据
  printf 'postgres://newapi:%s@%s:6432/newapi_pre?sslmode=require'         "$app" "$RDS_HOST" > "$SEC_DIR/PRE_SQL_DSN"
  printf 'postgres://newapi_migrate:%s@%s:6432/newapi_pre?sslmode=require' "$mig" "$RDS_HOST" > "$SEC_DIR/PRE_SQL_DSN_MIGRATE"
  chmod 600 "$SEC_DIR/PRE_SQL_DSN" "$SEC_DIR/PRE_SQL_DSN_MIGRATE"
  unset app mig
  for f in PRE_SQL_DSN PRE_SQL_DSN_MIGRATE; do
    notice "  $f => $(mask "$(cat "$SEC_DIR/$f")")"
  done
}

apply_pre_secret() {
  [ -s "$SEC_DIR/PRE_SQL_DSN" ] || { gen_pre_secret; }
  mkdir -p "$WORK/sec"; chmod 700 "$WORK/sec"
  cp "$SEC_DIR/PRE_SQL_DSN"         "$WORK/sec/SQL_DSN"
  cp "$SEC_DIR/PRE_SQL_DSN_MIGRATE" "$WORK/sec/SQL_DSN_MIGRATE"
  cp "$SEC_DIR/pre_session_secret"  "$WORK/sec/SESSION_SECRET"
  chmod 600 "$WORK/sec"/*
  run_body apply_pre_secret.sh presecret "SEC_B64=$(pack_dir "$WORK/sec")"
  rm -rf "$WORK/sec"
}

render_pre() {
  [ -f "$PRE_MANIFEST" ] || die "缺清单 $PRE_MANIFEST"
  local cm ck
  cm=$(awk 'BEGIN{RS="\n---\n"} /kind: ConfigMap/ {print}' "$PRE_MANIFEST")
  [ -n "$cm" ] || die "清单里找不到 ConfigMap 文档"
  ck=$(printf '%s' "$cm" | sha256sum | cut -c1-12)
  mkdir -p "$WORK/docs"
  sed "s/__CONFIG_CHECKSUM__/$ck/" "$PRE_MANIFEST" > "$WORK/rendered.yaml"
  notice "checksum/config=$ck"
  python3 - "$WORK" <<'PY'
import re, os, sys
W = sys.argv[1]
src = open(os.path.join(W, "rendered.yaml"), encoding="utf-8").read()
for d in src.split("\n---\n"):
    m = re.search(r"^kind:\s*(\w+)", d, re.M)
    if m:
        open(os.path.join(W, "docs", "doc_%s.yaml" % m.group(1)), "w", encoding="utf-8").write(d.lstrip("\n"))
        print("[pre-deploy]   split: %-16s %d bytes" % (m.group(1), len(d)))
PY
  [ -s "$WORK/docs/doc_Deployment.yaml" ] || die "切分失败：没有 doc_Deployment.yaml"
}

apply_pre_app() {
  render_pre
  run_body apply_pre_app.sh preapp "DOCS_B64=$(pack_dir "$WORK/docs")"
}

pre_smoke() {  # --smoke [pre|perf]；不给参数 = pre，历史口径逐字不变
  # 拆两次调用：单条 body + 通道外层包装必须 <15000B（实测合并后 15270B 被 CmdContentExceedLimit 拦）
  local t="${1:-pre}" ns track app
  case "$t" in
    pre)  ns=new-api-pre;  track=pre;  app=new-api-pre ;;
    perf) ns=new-api-perf; track=perf; app=new-api-perf ;;
    *) die "--smoke 只接受 pre|perf（当前='$t'）" ;;
  esac
  notice "冒烟目标=$t（ns=$ns 判据与另一轨道完全相同，只是换轨道）"
  run_body smoke_pre.sh "smoke-$t" "NS=$ns" "TRACK=$track" "APP=$app"
  run_body smoke_sqlite.sh "smokesqlite-$t" "NS=$ns" "APP=$app" "TRACK=$track"
}
diag_pending() { run_body diag_pending.sh diagpending; }

# ---- 步骤 5 的 perf 半边 ----
# 2026-10-16 口径：先建专用节点池（新增 ECS 费用）再 apply ⇒ 门禁绑在"池存在 + cost-approved"。
# **2026-10-19 裁定变更**：原节点池已换成更强机型（np-jkt-dev-x4c，2 × g9i.xlarge），
# pre 与 perf 都复用这张池 ⇒ 不再建池、不再钉 nodeSelector；门禁改成"共池核准"。
# 建池载荷 perf_nodepool.json 就此作废，**保留不删**作审计痕迹（我不替负责人销毁核准证据）。
PERF_MANIFEST="$ROOT/deploy/jakarta_perf/manifests/legacy/new-api-perf.yaml"
PERF_NS=new-api-perf
PERF_DB=newapi_perf
PERF_POOL_NAME=${PERF_POOL_NAME:-np-jkt-perf}   # 仅历史口径；现网实际共用池名 np-jkt-dev-x4c

perf_pool_state() {  # 只读：专用节点池是否存在（存在 = 已核准并产生费用）
  aliyun cs DescribeClusterNodePools --ClusterId "$CID" --region "$REGION" 2>&1 \
    | jq -r '[.nodepools[]? | {id:.nodepool_info.nodepool_id, name:.nodepool_info.name, state:.status.state,
              inst:(.scaling_group.instance_types // [] | join("/")), nodes:(.status.total_nodes // 0)}] | .[]
              | "\(.id) \(.name) state=\(.state) types=\(.inst) nodes=\(.nodes)"'
}

gen_perf_secret() {  # 与 pre 同构，只是库名/端口账目不同；口令只落保管目录（600）
  mkdir -p "$SEC_DIR"; chmod 700 "$SEC_DIR"
  [ -s "$SEC_DIR/dev_app" ] && [ -s "$SEC_DIR/dev_migrate" ] || die "缺 dev_app/dev_migrate"
  if [ ! -s "$SEC_DIR/perf_session_secret" ]; then
    local s; s=$(head -c 2048 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-21)
    [ "${#s}" -ge 16 ] || die "随机 SESSION_SECRET 生成异常"
    printf '%s' "$s" > "$SEC_DIR/perf_session_secret"; chmod 600 "$SEC_DIR/perf_session_secret"
    notice "perf_session_secret 已生成 len=${#s} fp=$(fp "$s")"
    unset s
  else
    v=$(cat "$SEC_DIR/perf_session_secret"); notice "perf_session_secret 已存在 len=${#v} fp=$(fp "$v")（幂等复用）"; unset v
  fi
  local pfx=""
  for f in dev_session_secret pre_session_secret perf_session_secret; do
    [ -s "$SEC_DIR/$f" ] || continue
    v=$(cat "$SEC_DIR/$f")
    [ "$f" = perf_session_secret ] || pfx="$pfx $f=$(fp "$v")"
    unset v
  done
  pfp=$(fp "$(cat "$SEC_DIR/perf_session_secret")")
  notice "  跨环境反证：perf fp=$pfp vs$pfx（必须两两不同）"
  unset pfp
  local app mig
  app=$(cat "$SEC_DIR/dev_app"); mig=$(cat "$SEC_DIR/dev_migrate")
  printf 'postgres://newapi:%s@%s:6432/%s?sslmode=require'         "$app" "$RDS_HOST" "$PERF_DB" > "$SEC_DIR/PERF_SQL_DSN"
  printf 'postgres://newapi_migrate:%s@%s:6432/%s?sslmode=require' "$mig" "$RDS_HOST" "$PERF_DB" > "$SEC_DIR/PERF_SQL_DSN_MIGRATE"
  chmod 600 "$SEC_DIR/PERF_SQL_DSN" "$SEC_DIR/PERF_SQL_DSN_MIGRATE"
  unset app mig
  for f in PERF_SQL_DSN PERF_SQL_DSN_MIGRATE; do notice "  $f => $(mask "$(cat "$SEC_DIR/$f")")"; done
}

apply_perf_secret() {
  [ -s "$SEC_DIR/PERF_SQL_DSN" ] || gen_perf_secret
  mkdir -p "$WORK/sec"; chmod 700 "$WORK/sec"
  cp "$SEC_DIR/PERF_SQL_DSN"         "$WORK/sec/SQL_DSN"
  cp "$SEC_DIR/PERF_SQL_DSN_MIGRATE" "$WORK/sec/SQL_DSN_MIGRATE"
  cp "$SEC_DIR/perf_session_secret"  "$WORK/sec/SESSION_SECRET"
  chmod 600 "$WORK/sec"/*
  # 复用 pre 的 body（2026-10-16 参数化：NS/DBNAME 注入，门禁逻辑一字不改）
  run_body apply_pre_secret.sh perfsecret "SEC_B64=$(pack_dir "$WORK/sec")" "NS=$PERF_NS" "DBNAME=$PERF_DB"
  rm -rf "$WORK/sec"
}

render_perf() {  # 只渲染，不落集群。裁定 2026-10-19：perf 复用 dev 站新池 ⇒ 不再注入 nodepool-id
  [ -f "$PERF_MANIFEST" ] || die "缺清单 $PERF_MANIFEST"
  # P0 门禁（口径已从"专用池必须存在"换成"共池不许再钉机器"）：清单里若还残留
  # nodeSelector / tolerations / nodepool 占位符，说明有人在换池后把旧设计抄了回来 ⇒ 直接拒。
  if grep -qE '^[[:space:]]*(nodeSelector|tolerations):|__PERF_NODE' "$PERF_MANIFEST"; then
    die "P0 门禁：清单仍含 nodeSelector/tolerations 或 nodepool 占位符 ⇒ 与裁定 2026-10-19（pre/perf 共池）冲突"
  fi
  local cm ck
  cm=$(awk 'BEGIN{RS="\n---\n"} /kind: ConfigMap/ {print}' "$PERF_MANIFEST")
  [ -n "$cm" ] || die "清单里找不到 ConfigMap 文档"
  ck=$(printf '%s' "$cm" | sha256sum | cut -c1-12)
  mkdir -p "$WORK/docs"
  sed -e "s/__CONFIG_CHECKSUM__/$ck/" "$PERF_MANIFEST" > "$WORK/rendered.yaml"
  # P1 门禁：任何未替换的 __X__ 占位符都不许进集群（configmap 名里合法不含下划线对，误写立即暴露）
  grep -qE '__[A-Z][A-Z_]+__' "$WORK/rendered.yaml" && die "P1 门禁：仍有未替换占位符 ⇒ 拒绝 apply"
  notice "P0/P1 通过：共池（无 nodeSelector/toleration）  checksum/config=$ck"
  python3 - "$WORK" <<'PY'
import re, os, sys
W = sys.argv[1]
src = open(os.path.join(W, "rendered.yaml"), encoding="utf-8").read()
for d in src.split("\n---\n"):
    m = re.search(r"^kind:\s*(\w+)", d, re.M)
    if m:
        open(os.path.join(W, "docs", "doc_%s.yaml" % m.group(1)), "w", encoding="utf-8").write(d.lstrip("\n"))
        print("[pre-deploy]   split: %-16s %d bytes" % (m.group(1), len(d)))
PY
  [ -s "$WORK/docs/doc_Deployment.yaml" ] || die "切分失败：没有 doc_Deployment.yaml"
}

apply_perf_app() {
  # 门禁换了理由：2026-10-19 起 perf 不再新建节点池 ⇒ 不是"新增 ECS 费用"的核准，
  # 而是"往 dev/pre 在用的池里加 2 核压测负载"的核准（共池会挤邻居，仍需书面确认）。
  [ "${PERF_APPROVAL:-}" = "shared-pool-approved" ] \
    || die "P-1 门禁：perf apply 需要 PERF_APPROVAL=shared-pool-approved（负责人 2026-10-19 裁定共池；确认新池余量够压测负载）"
  render_perf
  run_body apply_pre_app.sh perfapp "DOCS_B64=$(pack_dir "$WORK/docs")" "NS=$PERF_NS" "APP=new-api-perf" "TRACK=perf"
}

perf_plan() {  # 纯只读：现网池清单 +（历史口径）机型报价。2026-10-19 起 perf 不建池，报价段仅作账目留档
  notice "P-R0 口径：裁定 2026-10-19 ⇒ perf 复用现网池，**不新建节点池**；下面的报价段是历史核准材料，不是本次要花的钱"
  notice "P-R1 现网节点池（只读）"; perf_pool_state | sed 's/^/    /'
  notice "P-R2 机型可售性与报价（DescribeAvailableResource / DescribePrice，只读）"
  for z in ap-southeast-5a ap-southeast-5b ap-southeast-5c; do
    st=$(aliyun ecs DescribeAvailableResource --RegionId "$REGION" --DestinationResource InstanceType \
          --InstanceChargeType PostPaid --ZoneId "$z" --InstanceType ecs.g9i.xlarge 2>&1 \
          | jq -r '[.AvailableZones.AvailableZone[]?|"\(.Status)/\(.StatusCategory // "-")"]|join(",")')
    pr=$(aliyun ecs DescribePrice --RegionId "$REGION" --ResourceType instance --InstanceType ecs.g9i.xlarge \
          --PriceUnit Hour --SystemDisk.Category cloud_essd --SystemDisk.Size 40 --Amount 1 \
          --IoOptimized optimized --InternetChargeType PayByTraffic 2>&1 \
          | jq -r '.PriceInfo.Price.TradePrice // "ERR"')
    printf '    %s g9i.xlarge avail=%s price=%s USD/h\n' "$z" "${st:-空读数}" "${pr:-ERR}"
  done
  notice "P-R3 2 节点账目：0.215328 × 2 ≈ 0.4307 USD/h ≈ 10.34 USD/天 ≈ 310 USD/月（按量，40GiB ESSD，不含公网出流量）"
}

A="${1:---help}"
TGT="${2:-}"
case "$A" in
  --ns-base)     ns_base ;;
  --addon-verify) addon_verify ;;
  --pull-check)  pull_check ;;
  --db-ports)    db_ports ;;
  --db-state)    db_state ;;
  --create-db)   create_db ;;
  --apply-grants) apply_grants_pre ;;
  --dev-baseline) dev_baseline ;;
  --gen-secret)  gen_pre_secret ;;
  --apply-secret) apply_pre_secret ;;
  --apply-app)   apply_pre_app ;;
  --smoke)       pre_smoke "$TGT" ;;
  --diag)        diag_pending ;;
  --diag-nodes)  run_body diag_nodes.sh diagnost ;;
  --diag-mem)    run_body diag_mem.sh diagmem ;;
  --diag-sqlite) run_body diag_sqlite_and_devroll.sh diagsqlite ;;
  --perf-pool)   perf_pool_state ;;
  --perf-plan)   perf_plan ;;
  --perf-gen-secret) gen_perf_secret ;;
  --perf-apply-secret) apply_perf_secret ;;
  --perf-apply)  apply_perf_app ;;
  *) die "未知子命令：$A（--ns-base / --addon-verify / --pull-check <ns> / --db-ports / --db-state / --create-db / --apply-grants / --dev-baseline / --gen-secret / --apply-secret / --apply-app / --smoke / --perf-pool 只读列池 / --perf-plan 只读报价 / --perf-gen-secret / --perf-apply-secret / --perf-apply[需 PERF_APPROVAL=shared-pool-approved]）" ;;
esac
