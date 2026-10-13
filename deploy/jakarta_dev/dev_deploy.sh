#!/usr/bin/env bash
# =============================================================================
# deploy/jakarta_dev/dev_deploy.sh —— 雅加达 dev 工作负载执行器（任务 2d）
#
# 通道：deploy/lib/ack_remote_jkt_dev.sh（ECS 云助手 → 节点内 kubectl；
#       kubeconfig 是 **15 分钟临时私网凭据**，节点侧同一次调用内 rm -rf）
#
# 结构：远端脚本 = **静态 body**（deploy/jakarta_dev/bodies/*.sh，可 review、无生成期引号地狱）
#       + 本地拼的 **header**（临时目录 + Base64 载荷）。载荷用 tar.gz 打包（docs / secret / sql）。
#
# 子命令（各自一次独立云助手调用，全部幂等）：
#   --precheck    零凭据、零 kubectl：本地文件齐备性、ACR EE tag、RDS 白名单、DSN 结构打码自检
#   --apply-base  Namespace / ResourceQuota / ServiceAccount / ConfigMap
#   --secret      Secret new-api-secrets（4 键），值从本机保管目录 /root/.deploy_secrets_dev（600）
#   --grants      临时 psql Pod 落 dev_grants.sql 的权限 SQL + 生效判据回读 + 清理临时 Pod/Secret
#   --apply-app   Deployment + Service（须在 --secret 之后，否则 Pod 卡 ContainerCreating）
#   --verify      只读体检（Pod/镜像/AZ/配额/事件/键名/日志尾部）
#   --smoke       三库冒烟 + 权限链自证（读得到 / 写得进 / 建表必须被拒）
#   --status      只读快照
#   --delete      只删本卡产物（集群与 RDS 一律不动）
#
# 顺序（首跑）：--precheck → --apply-base → --secret → --grants → --apply-app → --verify → --smoke
#
# 凭据纪律（2026-10-05 裁定：全线不用 KMS/RRSA/ExternalSecret）：
#   - 明文只从保管目录读；清单/脚本/台账里**只有键名、长度、指纹**。body 里绝不 echo 值。
#   - 密钥值会随 --secret / --grants 的命令体经云助手投递一次（Base64）。这与任务 13 跳板 ECS
#     的既有做法同源（"命令只经云助手投递 ⇒ 跑完立刻轮换"）。补偿控制：kubeconfig 15 分钟临时、
#     临时 DBA Secret 用完即删、body 结束 shred 临时目录。轮换路径：改口令 → 重跑 --secret →
#     rollout restart（Secret 变更**不会**自动重启 Pod，任务 17 已证）。
#   - 本脚本不写台账、不做破坏性云资源操作。
# =============================================================================
set -uo pipefail

REGION=ap-southeast-5
NS=newapi-dev
APP=new-api-dev
SECRET=new-api-secrets
CM=new-api-config
ACR_INSTANCE=cri-avfqy9xkqi5bj8ee
RDS_ID=pgm-d9j9p421lzx4gw73
RDS_HOST=pgm-d9j9p421lzx4gw73.pgsql.ap-southeast-5.rds.aliyuncs.com
SEC_DIR=/root/.deploy_secrets_dev
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MANIFEST_SRC="$HERE/newapi-dev.yaml"
GRANTS_SRC="$HERE/dev_grants.sql"
BODIES="$HERE/bodies"
REMOTE="$ROOT/deploy/lib/ack_remote_jkt_dev.sh"
SECRET_KEYS=(SQL_DSN SQL_DSN_MIGRATE LOG_SQL_DSN SESSION_SECRET)
WORK=$(mktemp -d); chmod 700 "$WORK"; trap 'rm -rf "$WORK"' EXIT

notice() { echo "[dev-deploy] $*"; }
die() { echo "[dev-deploy][!] $*" >&2; exit 1; }
mask() { sed -E -e 's/(password=)[^ ]*/\1***/g' -e 's#://([^:/]+):[^@]*@#://\1:***@#g'; }

# ---- 载荷打包：目录 → tar.gz → 单行 Base64（远端解到 $T/payload）----
pack_dir() {  # $1=目录
  tar -czf - -C "$1" . 2>/dev/null | base64 -w0
}

# ---- 渲染 + 本地按 kind 切文档 ----
render() {
  [ -f "$MANIFEST_SRC" ] || die "缺清单 $MANIFEST_SRC"
  local cm ck
  cm=$(awk 'BEGIN{RS="\n---\n"} /kind: ConfigMap/ {print}' "$MANIFEST_SRC")
  [ -n "$cm" ] || die "清单里找不到 ConfigMap 文档，checksum 无法计算"
  ck=$(printf '%s' "$cm" | sha256sum | cut -c1-12)
  mkdir -p "$WORK/docs"
  sed "s/__CONFIG_CHECKSUM__/$ck/" "$MANIFEST_SRC" > "$WORK/rendered.yaml"
  notice "checksum/config=$ck"
  python3 - "$WORK" <<'PY'
import re, os, sys
W = sys.argv[1]
src = open(os.path.join(W, "rendered.yaml"), encoding="utf-8").read()
for d in src.split("\n---\n"):
    m = re.search(r"^kind:\s*(\w+)", d, re.M)
    if m:
        open(os.path.join(W, "docs", "doc_%s.yaml" % m.group(1)), "w", encoding="utf-8").write(d.lstrip("\n"))
        print("[dev-deploy]   split: %-16s %d bytes" % (m.group(1), len(d)))
PY
  [ -s "$WORK/docs/doc_Deployment.yaml" ] || die "切分失败：没有 doc_Deployment.yaml"
}

# ---- header：临时目录 + 载荷（值本身不进命令行，只进本次调用的命令体）----
header() {  # $1..=NAME=B64 形式
  cat <<HDR
#!/bin/bash
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/local/bin:\$PATH
T=\$(mktemp -d); chmod 700 \$T
mkdir -p \$T/payload; chmod 700 \$T/payload
HDR
  local pair
  for pair in "$@"; do
    printf 'export %s=%s\n' "${pair%%=*}" "'${pair#*=}'"
  done
}

run_body() {  # $1=body 文件名 $2=标签 $3..=payload NAME=B64
  local bname="$1" tag="$2"; shift 2
  [ -s "$BODIES/$bname" ] || die "缺 body：$BODIES/$bname"
  local full="$WORK/full_${tag}.sh"
  { header "$@"; cat "$BODIES/$bname"; } > "$full"
  chmod 700 "$full"
  notice "→ 云助手调用（$tag，body=$bname，载荷 $(( $# )) 项，命令体 $(wc -c <"$full") 字节）"
  bash "$REMOTE" "$full" || die "远端调用失败（$tag）"
}

secret_payload() {  # 把保管目录的键文件收进 $WORK/sec（含按需生成的 ops DSN）
  # 0=只要应用键  1=应用键+ops DSN+grants.sql（render-check 用）
  # 2=只要 ops DSN（owner 修复/探测） 3=ops DSN+grants.sql（授权落地）⇒ 载荷越小命令体越不容易顶云助手上限
  local with_ops="${1:-0}" k
  mkdir -p "$WORK/sec"; chmod 700 "$WORK/sec"
  case "$with_ops" in
    2|3)
      [ -s "$SEC_DIR/dev_ops" ] || die "缺 $SEC_DIR/dev_ops（授权 SQL 需要 newapi_ops）"
      local ops; ops=$(cat "$SEC_DIR/dev_ops")
      printf 'postgres://newapi_ops:%s@%s:5432/newapi?sslmode=require' "$ops" "$RDS_HOST" > "$WORK/sec/DSN_OPS_MAIN"
      printf 'postgres://newapi_ops:%s@%s:5432/newapi_logs?sslmode=require' "$ops" "$RDS_HOST" > "$WORK/sec/DSN_OPS_LOGS"
      [ "$with_ops" = 3 ] && cp "$GRANTS_SRC" "$WORK/sec/grants.sql"
      chmod 600 "$WORK/sec"/*
      return 0 ;;
  esac
  for k in "${SECRET_KEYS[@]}"; do
    [ -s "$SEC_DIR/$k" ] || die "缺 $SEC_DIR/$k"
    cp "$SEC_DIR/$k" "$WORK/sec/$k"
  done
  if [ "$with_ops" = 1 ]; then
    [ -s "$SEC_DIR/dev_ops" ] || die "缺 $SEC_DIR/dev_ops（授权 SQL 需要 newapi_ops）"
    local ops; ops=$(cat "$SEC_DIR/dev_ops")
    printf 'postgres://newapi_ops:%s@%s:5432/newapi?sslmode=require' "$ops" "$RDS_HOST" > "$WORK/sec/DSN_OPS_MAIN"
    printf 'postgres://newapi_ops:%s@%s:5432/newapi_logs?sslmode=require' "$ops" "$RDS_HOST" > "$WORK/sec/DSN_OPS_LOGS"
    cp "$GRANTS_SRC" "$WORK/sec/grants.sql"
  fi
  chmod 600 "$WORK/sec"/*
}

# ---------------- precheck（零凭据）----------------
precheck() {
  notice "== 1. 文件 =="
  local f
  for f in "$MANIFEST_SRC" "$GRANTS_SRC" "$REMOTE" "$BODIES/apply_base.sh" "$BODIES/apply_secret.sh" \
           "$BODIES/apply_grants.sh" "$BODIES/apply_app.sh" "$BODIES/verify.sh" "$BODIES/smoke.sh"; do
    [ -s "$f" ] && notice "  [ok] ${f#$ROOT/} ($(wc -l <"$f") 行)" || die "  [MISS] $f"
  done
  notice "== 2. 保管目录键（只报长度/指纹，值不出现在本输出）=="
  local k v
  for k in "${SECRET_KEYS[@]}"; do
    if [ -s "$SEC_DIR/$k" ]; then
      v=$(cat "$SEC_DIR/$k")
      case "$k" in *DSN*) notice "  [ok] $k => $(mask <<<"$v")";; *) notice "  [ok] $k len=${#v} fp=$(printf '%s' "$v" | sha256sum | cut -c1-12)";; esac
    else notice "  [MISS] $k"; fi
  done
  [ -s "$SEC_DIR/dev_ops" ] && notice "  [ok] dev_ops len=$(wc -c <"$SEC_DIR/dev_ops")" || notice "  [MISS] dev_ops"
  notice "== 3. 清单结构与 checksum 占位 =="
  grep -n "^kind:" "$MANIFEST_SRC" | sed 's/^/  doc: /'
  grep -q "__CONFIG_CHECKSUM__" "$MANIFEST_SRC" && notice "  [ok] checksum 占位符存在（apply 时渲染）" || notice "  [!!] 没有占位符"
  notice "== 4. 镜像 tag 是否真在 ACR EE（dev 走马尼拉 EE 公网入口，跨区）=="
  local img img_nohost img_ns img_name img_tag repo_id
  img=$(grep -m1 "^[[:space:]]*image:" "$MANIFEST_SRC" | awk '{print $2}')
  img_nohost=${img#*/}; img_ns=${img_nohost%%/*}
  img_name=${img_nohost#*/}; img_name=${img_name%%:*}
  img_tag=${img##*:}
  notice "  清单镜像：host=${img%%/*}  ns=$img_ns  repo=$img_name  tag=$img_tag"
  # cr 的企业版 API 用 RepoId（不是名字），且实例在马尼拉 ⇒ --region 必须是 ap-southeast-6
  repo_id=$(aliyun cr ListRepository --region ap-southeast-6 --InstanceId "$ACR_INSTANCE" --PageSize 100 2>/dev/null \
    | jq -r --arg ns "$img_ns" --arg r "$img_name" '.Repositories[]? | select(.RepoNamespaceName==$ns and .RepoName==$r) | .RepoId' | head -1)
  if [ -z "$repo_id" ]; then
    notice "  [XX] EE 里没有仓库 $img_ns/$img_name（镜像面未就绪）"
  else
    aliyun cr ListRepoTag --region ap-southeast-6 --InstanceId "$ACR_INSTANCE" --RepoId "$repo_id" --PageSize 100 2>/dev/null \
      | jq -r --arg t "$img_tag" 'if ([.Images[]? | select(.Tag==$t)] | length) > 0 then
            "  [ok] EE 命中 tag=\($t)（\(.Images[]? | select(.Tag==$t) | "status=\(.Status) size=\(.ImageSize)字节")）"
          else "  [XX] EE 无此 tag，现有：\([.Images[]?.Tag] | join(", "))" end'
  fi
  notice "== 5. dev RDS 白名单（应用/数据网段必须覆盖 Pod 与节点）=="
  aliyun rds DescribeDBInstanceIPArrayList --RegionId "$REGION" --DBInstanceId "$RDS_ID" 2>/dev/null \
    | jq -r '.Items.DBInstanceIPArray[] | "  \(.DBInstanceIPArrayName // "-")  \(.SecurityIPList)"'
  notice "== 6. 集群状态 =="
  aliyun cs DescribeClusterDetail --ClusterId cb0abf5bc06034f7bbdb991752f6f3e62 --region "$REGION" > "$WORK/cd.json" 2>"$WORK/cd.err"
  if [ -s "$WORK/cd.json" ]; then
    jq -r '"  cluster state=\(.state)  version=\(.current_version)  profile=\(.profile)  spec=\(.cluster_spec)"' "$WORK/cd.json" \
      || { notice "  jq 失败："; head -3 "$WORK/cd.err"; }
  else
    notice "  DescribeClusterDetail 失败：$(head -2 "$WORK/cd.err" | tr '\n' ' ')"
  fi
  notice "precheck 完成（未接触集群、未投递任何凭据）"
}

# ---------------- render-check（零凭据：先把"命令体怎么拼"本身验证一遍）----------------
render_check() {
  render
  secret_payload 1                       # 含 DSN_OPS_* 与 grants.sql，供 grants 的组装检查
  local DOCS SEC; DOCS=$(pack_dir "$WORK/docs"); SEC=$(pack_dir "$WORK/sec")
  local b full
  for b in apply_base.sh apply_secret.sh apply_grants.sh apply_app.sh verify.sh smoke.sh status.sh delete.sh db_owner_fix.sh db_owner_probe.sh logs.sh isolation.sh isolation_rbac.sh diagnose_pull.sh fix_pull_sa.sh; do
    case "$b" in
      apply_base.sh|apply_app.sh) full="$WORK/rc_$b"; { header "DOCS_B64=$DOCS"; cat "$BODIES/$b"; } > "$full" ;;
      diagnose_pull.sh|fix_pull_sa.sh) full="$WORK/rc_$b"; { header; cat "$BODIES/$b"; } > "$full" ;;
      db_owner_fix.sh|db_owner_probe.sh) full="$WORK/rc_$b"; { header "SEC_B64=$SEC"; cat "$BODIES/$b"; } > "$full" ;;
      *)                           full="$WORK/rc_$b"; { header "SEC_B64=$SEC";  cat "$BODIES/$b"; } > "$full" ;;
    esac
    if bash -n "$full" 2>/dev/null; then
      notice "  [ok] $b 组装后语法通过（命令体 $(wc -c <"$full") 字节）"
    else
      notice "  [XX] $b 语法失败："; bash -n "$full" 2>&1 | head -5 | sed 's/^/      /'
    fi
  done
  notice "（以上只做本地拼装 + bash -n，未发起任何云助手调用、未投递凭据）"
}

# ---------------- 各步骤 ----------------
apply_base() {
  render
  run_body apply_base.sh apply-base "DOCS_B64=$(pack_dir "$WORK/docs")"
}
apply_secret() {
  secret_payload 0
  run_body apply_secret.sh secret "SEC_B64=$(pack_dir "$WORK/sec")"
}
apply_grants() {
  secret_payload 3
  run_body apply_grants.sh grants "SEC_B64=$(pack_dir "$WORK/sec")"
}
apply_app() {
  render
  run_body apply_app.sh apply-app "DOCS_B64=$(pack_dir "$WORK/docs")"
}
db_owner_fix() {
  secret_payload 2
  run_body db_owner_fix.sh ownerfix "SEC_B64=$(pack_dir "$WORK/sec")"
}
db_owner_probe() {
  secret_payload 2
  run_body db_owner_probe.sh ownerprobe "SEC_B64=$(pack_dir "$WORK/sec")"
}
verify()  { run_body verify.sh verify; }
logs()    { run_body logs.sh logs; }
diag_pull() { run_body diagnose_pull.sh diagpull; }
fix_pull_sa() {
  [ -n "${TGT:-}" ] || die "--fix-pull-sa 必须显式给第二参目标负载名（刻意不设默认，避免误伤）"
  run_body fix_pull_sa.sh fixpull "TARGET=$TGT"
}
isolation() {
  run_body isolation.sh isolation-net
  run_body isolation_rbac.sh isolation-rbac
}
smoke()   { run_body smoke.sh smoke; }
status()  { run_body status.sh status; }
del_all() { run_body delete.sh delete; }

A="${1:---precheck}"
TGT="${2:-}"
case "$A" in
  --precheck)    precheck ;;
  --render-check) render_check ;;
  --apply-base) apply_base ;;
  --secret)     apply_secret ;;
  --grants)     apply_grants ;;
  --db-owner-probe) db_owner_probe ;;
  --db-owner-fix) db_owner_fix ;;
  --apply-app)  apply_app ;;
  --verify)     verify ;;
  --logs)       logs ;;
  --diagnose-pull) diag_pull ;;
  --fix-pull-sa) fix_pull_sa ;;
  --isolation)  isolation ;;
  --smoke)      smoke ;;
  --status)     status ;;
  --delete)     del_all ;;
  *) die "未知子命令：$A（--precheck/--render-check/--apply-base/--secret/--grants/--db-owner-probe/--db-owner-fix/--apply-app/--verify/--logs/--diagnose-pull/--fix-pull-sa <deploy>/--smoke/--isolation/--status/--delete）" ;;
esac
