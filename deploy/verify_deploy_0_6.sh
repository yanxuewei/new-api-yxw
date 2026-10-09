#!/usr/bin/env bash
# =============================================================================
# §0.6 统一复核命令 — 一键执行（跑完贴输出即销账）
#
# 对应文档：deploy/docs/阿里云国际站菲律宾部署_详细操作指南-v2.0.md §0.6
# 复核 8 项：身份 / VPC / vSwitch / OSS 桶 / CK 实例+接线 / 配额工单 / vCPU 额度 / RAM 用户
#
# ★ 设计要点（2026-09-28 全套实测踩到的坑，改脚本时勿回退）：
#   1) 所有 jq 取值走 `jq -e`：空结果 / null 返回非 0 → 杜绝「命令成功但零输出」被当成销账证据。
#      （原 §0.6 的 `ListProductQuotas | jq 'select(.Status=="Agree")'` 正是此类：恒空且 exit 0）
#   2) CLI 退出码语义：错 API 名 / 错参数名 = 2；jq 语法错 = 3；jq（-e）遇空集 = 4。
#   3) 配额两项必须分流：
#        · Agree 状态 → `quotas ListQuotaApplications`（ListProductQuotas 无 Status 字段）
#        · vCPU 额度  → `--ProductCode ecs-spec --QuotaCategory CommonQuota`
#          （`--ProductCode ecs` 只回 26 条通用配额，查不到 vCPU；`--Product` / `--PageSize` / `--QuotaCategory Common` 均非法）
#   4) ClickHouse 列实例是 `DescribeDBInstances`（**不存在** `DescribeDBClusters`，写了报 is not a valid api）。
#      状态字段是 `.Status`（企业版就绪态字面值 `ACTIVATION`），**不是** `.DBInstanceStatus`（该 API 无此字段，取到 null）。
#      ⚠ 2026-09-30 加：`TotalCount>=1` 只代表"实例已建"，**不代表日志库可用** ⇒ 5/8 还要读 `DescribeSecurityIPList`
#      与 `DescribeAccounts`，任一未接线整项判 WARN（否则就是"CK 已建"被当成"CK 就绪"的假通过）。
#   5) `vpc DescribeVpcs` 默认 PageSize=10 且必须显式给；取值按 `EXPECT_VPC_ID` 过滤定位，
#      不要退回 `.Vpcs.Vpc[0]` —— 该地域 VPC 多于 1 个时下标 0 可能命中非目标对象，
#      比对口径错了却仍可能报 PASS。
#
# 用法：
#   WSL（fanyan 默认环境）：
#     wsl -d Ubuntu -u root -- bash /mnt/e/git_code/new-api-yxw/deploy/verify_deploy_0_6.sh
#   macOS / Linux：
#     bash deploy/verify_deploy_0_6.sh
#
#   可选环境变量：REGION · ALIYUN_BIN · OUTDIR · STRICT
#   退出码：0 = 无 FAIL（WARN 需人工确认后方可勾销）；1 = 存在 FAIL
#           STRICT=1 时 WARN 也计为未通过（门禁 / CI 场景）
# =============================================================================

set -uo pipefail

ALIYUN_BIN="${ALIYUN_BIN:-$(command -v aliyun 2>/dev/null || echo /usr/local/bin/aliyun)}"
REGION="${REGION:-ap-southeast-6}"
TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${OUTDIR:-$(cd "$(dirname "$0")" && pwd)/logs/verify_0_6_$TS}"

# ---- 期望基线（来自 §0.6 / F5 / F6 / F9 / §2.2，实测已核对）-----------------
EXPECT_ACCOUNT="5108890064395960"
EXPECT_VPC_ID="vpc-5tst1tgeessxn1azwasg2"
EXPECT_VPC_CIDR="10.0.0.0/16"
EXPECT_VPC_NAME="vpc-newapi-mnl-prod"
EXPECT_VSW_COUNT=6
EXPECT_VSW_CIDRS=(10.0.0.0/24 10.0.1.0/24 10.0.16.0/20 10.0.32.0/20 10.0.48.0/20 10.0.64.0/20)
EXPECT_BUCKETS=(oss-newapi-mnl oss-newapi-backup-sgp cri-avfqy9xkqi5bj8ee-registry)
EXPECT_RAM_USERS=(admin ops cicd-push iac-terraform dev-zhangzijun dev-xiangdong yanxuewei)
EXPECT_VCPU_QUOTA_CODE="q_ecs_enterprise_postpay_c"
EXPECT_VCPU=64

mkdir -p "$OUTDIR"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
ok()   { printf '%s[PASS]%s %s\n' "$c_grn" "$c_off" "$*"; }
bad()  { printf '%s[FAIL]%s %s\n' "$c_red" "$c_off" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$c_yel" "$c_off" "$*"; }
info() { printf '%s%s%s\n' "$c_dim" "$*" "$c_off"; }
hr()   { printf '\n%s\n' "────────────────────────────────────────────────────────────"; }

n_pass=0; n_warn=0; n_fail=0
rec() {
  case "$1" in
    pass) n_pass=$((n_pass + 1)) ;;
    warn) n_warn=$((n_warn + 1)) ;;
    fail) n_fail=$((n_fail + 1)) ;;
  esac
}

# 调用 aliyun：完整输出落盘 + 原样保留退出码（不经管道，避免 pipefail 掩盖真实码）
ali() {
  local label="$1"; shift
  local out rc
  out="$("$ALIYUN_BIN" "$@" 2>&1)"; rc=$?
  printf '%s\n' "$out" > "$OUTDIR/${label}.json"
  printf '%s\n' "$out"
  return $rc
}

# jq 取值：空 / null / false → 非 0（这就是「防空集假通过」的关键）
jqget() { jq -er "$2" "$OUTDIR/$1.json" 2>/dev/null; }

# 失败时截取输出首行做提示
errline() { head -c 220 "$OUTDIR/$1.json" 2>/dev/null | tr '\n' ' '; }

# =============================================================================
# 1/8 身份
# =============================================================================
c1_identity() {
  hr; echo "1/8  身份  ·  sts GetCallerIdentity"
  local v
  if ! ali c1_sts sts GetCallerIdentity >/dev/null; then
    bad "调用失败：$(errline c1_sts)"; rec fail; return
  fi
  if ! v="$(jqget c1_sts '.AccountId')"; then
    bad "AccountId 取值为空 → 拒绝放行（空集不等于通过）"; rec fail; return
  fi
  if [[ "$v" == "$EXPECT_ACCOUNT" ]]; then
    ok "AccountId = $v   (RAM: $(jqget c1_sts '.Arn' || echo '?'))"; rec pass
  else
    bad "AccountId = $v（期望 $EXPECT_ACCOUNT）"; rec fail
  fi
}

# =============================================================================
# 2/8 VPC
# =============================================================================
c2_vpc() {
  hr; echo "2/8  VPC  ·  vpc DescribeVpcs --RegionId $REGION --PageSize 50"
  local id cidr name rc=0 total f
  if ! ali c2_vpc vpc DescribeVpcs --RegionId "$REGION" --PageSize 50 >/dev/null; then
    bad "调用失败：$(errline c2_vpc)"; rec fail; return
  fi

  echo "     实测（VpcId / CidrBlock / VpcName）："
  jq -r '.Vpcs.Vpc[]|[.VpcId,.CidrBlock,.VpcName]|@tsv' "$OUTDIR/c2_vpc.json" 2>/dev/null \
    | awk -F'\t' '{printf "       %-26s %-14s %s\n", $1, $2, $3}'

  # DescribeVpcs 默认 PageSize=10，不显式给会静默少返回；命中目标后仍要确认没被截断
  total="$(jq -r '.TotalCount // empty' "$OUTDIR/c2_vpc.json" 2>/dev/null)"
  if [[ "$total" =~ ^[0-9]+$ && "$total" -gt 50 ]]; then
    warn "该地域共 $total 个 VPC，超过 PageSize=50 单页上限，本清单不完整"
  fi

  # 按期望 ID 定位，不再硬取 .Vpcs.Vpc[0]：多于 1 个 VPC 时下标可能命中非目标对象
  f='.Vpcs.Vpc[]|select(.VpcId=="'"$EXPECT_VPC_ID"'")'
  if ! id="$(jqget c2_vpc "$f|.VpcId")"; then
    bad "未找到期望 VPC $EXPECT_VPC_ID（见上方实测清单）"; rec fail; return
  fi
  cidr="$(jqget c2_vpc "$f|.CidrBlock" || echo '?')"
  name="$(jqget c2_vpc "$f|.VpcName"   || echo '?')"
  [[ "$cidr" == "$EXPECT_VPC_CIDR" ]] || rc=1
  [[ "$name" == "$EXPECT_VPC_NAME" ]] || rc=1
  if [[ $rc -eq 0 ]]; then
    ok "$id  $cidr  $name"; rec pass
  else
    bad "$id  $cidr  $name"
    info "        期望  $EXPECT_VPC_ID  $EXPECT_VPC_CIDR  $EXPECT_VPC_NAME"
    rec fail
  fi
}

# =============================================================================
# 3/8 vSwitch
# =============================================================================
c3_vswitch() {
  hr; echo "3/8  vSwitch  ·  vpc DescribeVSwitches --RegionId $REGION --PageSize 50"
  local n found missing="" c
  if ! ali c3_vsw vpc DescribeVSwitches --RegionId "$REGION" --PageSize 50 >/dev/null; then
    bad "调用失败：$(errline c3_vsw)"; rec fail; return
  fi
  if ! n="$(jqget c3_vsw '.VSwitches.VSwitch|length')"; then
    bad "vSwitch 列表为空"; rec fail; return
  fi

  echo "     实测（VSwitchId / Zone / CidrBlock）："
  jq -r '.VSwitches.VSwitch[]|[.VSwitchId,.ZoneId,.CidrBlock]|@tsv' "$OUTDIR/c3_vsw.json" 2>/dev/null \
    | awk -F'\t' '{printf "       %-26s %-18s %s\n", $1, $2, $3}'

  found="$(jq -r '.VSwitches.VSwitch[].CidrBlock' "$OUTDIR/c3_vsw.json" 2>/dev/null)"
  for c in "${EXPECT_VSW_CIDRS[@]}"; do
    grep -qxF "$c" <<<"$found" || missing="$missing $c"
  done

  if [[ "$n" -eq "$EXPECT_VSW_COUNT" && -z "$missing" ]]; then
    ok "共 $n 个，网段与 §2.2 完全一致"; rec pass
  else
    bad "共 $n 个（期望 $EXPECT_VSW_COUNT）；网段缺失:${missing:-无}"; rec fail
  fi
}

# =============================================================================
# 4/8 OSS 桶
# =============================================================================
c4_oss() {
  hr; echo "4/8  OSS 桶  ·  aliyun oss ls"
  local out list miss="" extra="" b u hit
  if ! out="$(ali c4_oss oss ls)"; then
    bad "调用失败：$(errline c4_oss)"; rec fail; return
  fi
  list="$(printf '%s\n' "$out" | grep -oE 'oss://[^ ]+' | sed 's#oss://##' | sort -u)"
  if [[ -z "$list" ]]; then bad "未解析到任何桶名"; rec fail; return; fi

  echo "     实测："
  printf '%s\n' "$list" | sed 's/^/       /'

  for b in "${EXPECT_BUCKETS[@]}"; do
    grep -qxF "$b" <<<"$list" || miss="$miss $b"
  done
  while read -r u; do
    [[ -z "$u" ]] && continue
    hit=0
    for b in "${EXPECT_BUCKETS[@]}"; do [[ "$u" == "$b" ]] && hit=1; done
    [[ $hit -eq 0 ]] && extra="$extra $u"
  done <<<"$list"

  if [[ -z "$miss" && -z "$extra" ]]; then
    ok "3 桶齐全（prod 主桶 / 新加坡 CRR 目标 / ACR 镜像仓库）"; rec pass
  elif [[ -z "$miss" ]]; then
    warn "必需桶齐全；另有桶:${extra}"; rec warn
  else
    bad "缺失:${miss}；另有:${extra:-无}"; rec fail
  fi
  info "  注：备份分层靠生命周期规则（backup-data-tiering / backup-audit-tiering / backup-cleanup），"
  info "      并**不是**叫 audit 的独立桶 —— §0.6 原注释有误，已订正。"
}

# =============================================================================
# 5/8 ClickHouse 实例 + 接线状态（实例存在 ≠ 日志库可用）
# =============================================================================
c5_clickhouse() {
  hr; echo "5/8  ClickHouse 实例+接线  ·  clickhouse DescribeDBInstances / DescribeSecurityIPList / DescribeAccounts / DescribeDBInstanceDataSources --RegionId $REGION"
  local n id st ips accts dbs verdict
  if ! ali c5_ck clickhouse DescribeDBInstances --RegionId "$REGION" >/dev/null; then
    bad "调用失败：$(errline c5_ck)"
    info "        若报 is not a valid api → API 名写成了 DescribeDBClusters（不存在）"
    rec fail; return
  fi
  n="$(jq -r '.Data.TotalCount // empty' "$OUTDIR/c5_ck.json" 2>/dev/null)"
  if [[ -z "$n" || ! "$n" =~ ^[0-9]+$ || "$n" -lt 1 ]]; then
    warn "TotalCount = ${n:-空} → 任务 29 尚未创建，本项【不能】作为销账证据"
    info "        建成后本项转 PASS；Day 1 出口（M1）需要 d1/ck-instance.txt"
    rec warn; return
  fi
  echo "       TotalCount = $n（实例已创建）："
  jq -r '.Data.DBInstances[]|[.DBInstanceId,(.Status//"-"),(.ZoneId//"-"),(.ChargeType//"-")]|@tsv' \
    "$OUTDIR/c5_ck.json" 2>/dev/null | awk -F'\t' '{printf "       %-28s %-12s %-18s %s\n", $1, $2, $3, $4}'
  info "        注：企业版就绪态字面值是 ACTIVATION（不是社区版的 Running）；状态字段名是 .Status，非 .DBInstanceStatus —— 2026-09-30 实测"
  # 实例存在只是第一步。日志库真正可用还要：白名单放行来源 + 有账号（任务 29 的 S-1/S-2）。
  id="$(jq -r '.Data.DBInstances[0].DBInstanceId // empty' "$OUTDIR/c5_ck.json" 2>/dev/null)"
  if [[ -z "$id" ]]; then
    warn "拿不到 DBInstanceId → 无法复核接线，本项记 WARN"; rec warn; return
  fi
  verdict=pass
  # 就绪态：ACTIVATION 是唯一已实测的"可用"字面值；INSTALL_EXTENSIONS（2026-09-30 实测：开通
  # ClickObserve/Langfuse 扩展时进入）是过渡态，此时接线判据不能算通过。
  st="$(jq -r '.Data.DBInstances[0].Status // empty' "$OUTDIR/c5_ck.json" 2>/dev/null)"
  if [[ "$st" == "ACTIVATION" ]]; then
    echo "       Status = ACTIVATION（就绪）"
  else
    warn "Status = ${st:-空}（非 ACTIVATION）→ 实例处于过渡/异常态，本项记 WARN"
    info "        已观测到的过渡态：INSTALL_EXTENSIONS（扩展安装中，配 ClickObserveServiceStatus=creating）"
    verdict=warn
  fi
  if ali c5_ck_ip clickhouse DescribeSecurityIPList --RegionId "$REGION" --DBInstanceId "$id" >/dev/null \
     && ips="$(jqget c5_ck_ip '[.Data.GroupItems[].SecurityIPList] | join(",")')" && [[ -n "$ips" ]]; then
    if [[ "$ips" == "127.0.0.1" ]]; then
      warn "白名单仅 default=127.0.0.1 → CK 未接线（主站网段未放行，任务 29 的 S-1 未做）"
      verdict=warn
    else
      echo "       白名单已放行：$ips"
    fi
  else
    warn "DescribeSecurityIPList 调用失败或取数为空（空集不判通过）：$(errline c5_ck_ip)"; verdict=warn
  fi
  if ali c5_ck_ac clickhouse DescribeAccounts --RegionId "$REGION" --DBInstanceId "$id" >/dev/null \
     && accts="$(jqget c5_ck_ac '.Data.TotalCount')" && [[ -n "$accts" ]]; then
    if [[ "$accts" == "0" ]]; then
      warn "账号数 = 0 → CK 未接线（任务 29 的 S-2 未做）⇒ 日志库仍为 PG，I-1 须按 PG 分支（3680 > 2000）算"
      verdict=warn
    else
      echo "       账号数 = $accts"
    fi
  else
    warn "DescribeAccounts 调用失败或取数为空（空集不判通过）：$(errline c5_ck_ac)"; verdict=warn
  fi
  # S-3：库。DescribeDBInstanceDataSources 不带 --DBName 时回该实例的 schema 列表（JSON 字符串数组）。
  if ali c5_ck_db clickhouse DescribeDBInstanceDataSources --RegionId "$REGION" --DBInstanceId "$id" >/dev/null \
     && dbs="$(jq -r '[.Data.Schemas[]? | (fromjson | .schemaName)] | join(",")' "$OUTDIR/c5_ck_db.json" 2>/dev/null)"; then
    if [[ "$dbs" == *newapi_logs* ]]; then
      echo "       库：$dbs"
    else
      warn "库列表不含 newapi_logs（现在=${dbs:-空}）→ 任务 29 的 S-3 未做"; verdict=warn
    fi
  else
    warn "DescribeDBInstanceDataSources 调用失败或取数为空（空集不判通过）：$(errline c5_ck_db)"; verdict=warn
  fi
  if [[ "$verdict" == pass ]]; then
    ok "实例 ACTIVATION 且 API 可见的接线三件套齐（白名单 + 账号 + 库）—— S-4 的 LOG_SQL_DSN 与 SELECT version() 端到端仍需应用侧/VPC 内复验"
    info "        三件套齐 ⇒ 只差 S-4（把保管的 DSN 注入任务 17 的 ConfigMap/Secret）；应用首启时 LOG_SQL_DSN 指向 CK，I-1 才可按 CK 分支（1840 ≤ 2000）记账"
  else
    info "        本项汇总判 WARN：CK 只完成了「建实例」，未完成「可用」。销账前勿把任务 41 的 I-1 记到 CK 分支。"
  fi
  rec "$verdict"
}

# =============================================================================
# 6/8 配额工单状态（Agree 的唯一正确出处）
# =============================================================================
c6_quota_apps() {
  hr; echo "6/8  配额工单  ·  quotas ListQuotaApplications"
  local tsv prod val st hit64=0 hit96=0 notagree=0 total=0
  info "  Agree 状态只在 ListQuotaApplications 返回；ListProductQuotas 的对象没有 Status 字段"
  if ! ali c6_app quotas ListQuotaApplications >/dev/null; then
    bad "调用失败：$(errline c6_app)"; rec fail; return
  fi
  tsv="$(jq -r '.QuotaApplications[]|[.ProductCode,(.DesireValue|tostring),(.Status|tostring)]|@tsv' \
          "$OUTDIR/c6_app.json" 2>/dev/null)"
  if [[ -z "$tsv" ]]; then
    bad "无配额申请记录 → 期望至少 ecs-spec 的 64 / 96 两条"; rec fail; return
  fi

  echo "     实测（ProductCode / DesireValue / Status）："
  printf '%s\n' "$tsv" | awk -F'\t' '{printf "       %-12s %-6s %s\n", $1, $2, $3}'

  while IFS=$'\t' read -r prod val st; do
    [[ -z "$prod" ]] && continue
    total=$((total + 1))
    [[ "$st" == "Agree" ]] || notagree=$((notagree + 1))
    [[ "$prod" == "ecs-spec" && "$val" == "64" && "$st" == "Agree" ]] && hit64=1
    [[ "$prod" == "ecs-spec" && "$val" == "96" && "$st" == "Agree" ]] && hit96=1
  done <<<"$tsv"

  if [[ $hit64 -eq 1 && $hit96 -eq 1 && $notagree -eq 0 ]]; then
    ok "$total 条全部 Agree，含 64（马尼拉）与 96（新加坡） · G2 / G10 闭环"; rec pass
  else
    bad "64=${hit64} 96=${hit96} 非 Agree 条数=$notagree（共 $total 条）"; rec fail
  fi
}

# =============================================================================
# 7/8 vCPU 额度（ecs-spec 才是 vCPU 的来源）
# =============================================================================
c7_vcpu_quota() {
  hr; echo "7/8  vCPU 额度  ·  quotas ListProductQuotas --ProductCode ecs-spec --QuotaCategory CommonQuota"
  local v
  if ! ali c7_q quotas ListProductQuotas --ProductCode ecs-spec --QuotaCategory CommonQuota \
        --RegionId "$REGION" --Dimensions.1.Key regionId --Dimensions.1.Value "$REGION" >/dev/null; then
    bad "调用失败：$(errline c7_q)"; rec fail; return
  fi
  v="$(jq -r --arg code "$EXPECT_VCPU_QUOTA_CODE" \
        '.Quotas[]|select(.QuotaActionCode==$code)|.TotalQuota' "$OUTDIR/c7_q.json" 2>/dev/null)"
  if [[ "$v" == "$EXPECT_VCPU" ]]; then
    ok "$EXPECT_VCPU_QUOTA_CODE = $v"; rec pass
  else
    bad "$EXPECT_VCPU_QUOTA_CODE = ${v:-空}（期望 $EXPECT_VCPU）"
    info "        实得清单：$(jq -r '.Quotas[]|[.QuotaActionCode,(.TotalQuota|tostring)]|@tsv' "$OUTDIR/c7_q.json" 2>/dev/null | head -3 | tr '\n' ' ')"
    rec fail
  fi
  info "  对照坑：--ProductCode ecs 只回 26 条通用配额，查不到 vCPU；"
  info "          --Product / --PageSize / --QuotaCategory Common 均为非法参数值。"
}

# =============================================================================
# 8/8 RAM 用户
# =============================================================================
c8_ram_users() {
  hr; echo "8/8  RAM 用户  ·  ram ListUsers"
  local list miss="" extra="" u e hit
  if ! ali c8_ram ram ListUsers >/dev/null; then
    bad "调用失败：$(errline c8_ram)"; rec fail; return
  fi
  list="$(jq -r '.Users.User[].UserName' "$OUTDIR/c8_ram.json" 2>/dev/null | sort)"
  if [[ -z "$list" ]]; then bad "用户列表为空"; rec fail; return; fi

  echo "     实测："
  printf '%s\n' "$list" | sed 's/^/       /'

  for u in "${EXPECT_RAM_USERS[@]}"; do
    grep -qxF "$u" <<<"$list" || miss="$miss $u"
  done
  while read -r u; do
    [[ -z "$u" ]] && continue
    hit=0
    for e in "${EXPECT_RAM_USERS[@]}"; do [[ "$u" == "$e" ]] && hit=1; done
    [[ $hit -eq 0 ]] && extra="$extra $u"
  done <<<"$list"

  if [[ -z "$miss" && -z "$extra" ]]; then
    ok "7 个必需身份齐全，无额外账号"; rec pass
  elif [[ -z "$miss" ]]; then
    warn "必需身份齐全；额外账号:${extra}"
    info "        多为命名规范收敛前的遗留（与 dev-* 成对），建议核后清理"
    rec warn
  else
    bad "缺失:${miss}；额外:${extra:-无}"; rec fail
  fi
}

# =============================================================================
main() {
  if [[ ! -x "$ALIYUN_BIN" ]]; then
    bad "aliyun CLI 不存在: $ALIYUN_BIN"
    info "  WSL 安装：bash /mnt/e/WSL/setup-aliyun-toolchain.sh"
    exit 2
  fi

  local ver; ver="$("$ALIYUN_BIN" version 2>/dev/null | head -1)"
  echo "============================================================"
  echo " §0.6 统一复核 — 菲律宾部署（马尼拉 + 新加坡备站）"
  echo "============================================================"
  echo " CLI     : $ALIYUN_BIN  ($ver)"
  echo " Region  : $REGION"
  echo " 时间    : $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo " 原始输出: $OUTDIR/"
  echo "============================================================"

  c1_identity
  c2_vpc
  c3_vswitch
  c4_oss
  c5_clickhouse
  c6_quota_apps
  c7_vcpu_quota
  c8_ram_users

  hr
  echo "复核汇总"
  echo "------------------------------------------------------------"
  printf '  PASS %d   WARN %d   FAIL %d\n' "$n_pass" "$n_warn" "$n_fail"
  echo "------------------------------------------------------------"
  if [[ $n_fail -gt 0 ]]; then
    echo "  结论：存在 $n_fail 项 FAIL → 不得销账"
  elif [[ $n_warn -gt 0 ]]; then
    echo "  结论：基线未被破坏，但有 $n_warn 项 WARN 未消 → 须人工确认后方可勾销"
    [[ "${STRICT:-0}" == "1" ]] && echo "        （STRICT=1：WARN 计为未通过）"
  else
    echo "  结论：8 项全部 PASS → 可销账"
  fi
  echo "  证据文件：$OUTDIR/"
  echo "============================================================"

  # STRICT=1 时 WARN 也视为未通过（门禁 / CI 用）
  if [[ "${STRICT:-0}" == "1" ]]; then
    [[ $n_fail -eq 0 && $n_warn -eq 0 ]]
  else
    [[ $n_fail -eq 0 ]]
  fi
}

main "$@"
