#!/usr/bin/env bash
# ==============================================================================
# 任务 22 前置｜业务安全组「提前落地」幂等脚本  (v2 — 2026-09-29 修实跑缺陷)
#   马尼拉：sg-mnl-alb / sg-mnl-app / sg-mnl-db
#   新加坡：sg-sg-alb / sg-sg-app
# 依据：deploy/docs/阿里云国际站菲律宾部署_详细操作指南-v2.0.md §8.1 / 任务 22
#       deploy/aliyun/ph/security-groups.md
#
# 用法：
#   bash deploy/tasks/task22/sg_bootstrap.sh --verify              # 只读，列出 5 个组现状（含出向）
#   bash deploy/tasks/task22/sg_bootstrap.sh --dry-run             # 打印将执行的动作
#   bash deploy/tasks/task22/sg_bootstrap.sh                       # 建组 + 建规则（幂等）
#   bash deploy/tasks/task22/sg_bootstrap.sh --office-cidr 1.2.3.0/24   # 追加运维入口 SG
#
# v2 修的三个坑（v1 实跑踩到）：
#   坑A｜入向 / 出向是两个 API：AuthorizeSecurityGroup 只加**入向**规则，
#        出向必须用 AuthorizeSecurityGroupEgress（它有 DestCidrIp / DestGroupId）。
#        v1 用入向 API 建出向 → 全部静默失败，6 条出向规则一条没落。
#   坑B｜错误检测不能只认 JSON `"Code"`：aliyun CLI 的失败输出是
#        `ERROR: SDK.ServerError` + 文本行 `ErrorCode: xxx`（非 JSON），
#        v1 只 grep `"Code": "..."` → 把失败当成功，报「已添加」。
#   坑C｜查询不要 `2>/dev/null`：异常被吞 → 查不到就当「不存在」→ 重复建组
#        （v1 实跑多建了一个 sg-mnl-app）。改为「查不到=报错退出」，绝不猜。
#
# 设计约束（实测）：
#   1) 组引用（SourceGroupId / DestGroupId）要求被引用组同 VPC 已存在 → 先建组，后建规则。
#   2) 必须「普通安全组」（SecurityGroupType=normal），企业级不支持组组授权。
#   3) flat 参数（--SourceGroupId/--PortRange/...）已 Deprecated，统一用 Permissions.N.*。
#   4) VPC 安全组 NicType 必须 intranet。
#   5) 出向到托管实例（RDS/Tair）用 DestCidrIp 而非 DestGroupId：托管实例的 SG
#      由云产品自管、默认不可换，绑不上的话组引用规则会变成「静默失效」。
#      真正的控制点在数据层侧的**入向组引用**（sg-mnl-db in ← sg-mnl-app）。
# ==============================================================================
set -uo pipefail

DRY=0; VERIFY=0; OFFICE_CIDR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)     DRY=1; shift ;;
    --verify)      VERIFY=1; shift ;;
    --office-cidr) OFFICE_CIDR="${2:-}"; shift 2 ;;
    -h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

# ---------- 常量（实测值，2026-09-29） ----------
REGION_MNL=ap-southeast-6; VPC_MNL=vpc-5tst1tgeessxn1azwasg2; RG_MNL=rg-aek4nyivmmsb6iy
REGION_SG=ap-southeast-1;  VPC_SG=vpc-t4nimmwvruexbnene0a3r;  RG_SG=rg-aek4zvb3ldoiyua

CIDR_DATA_A=10.0.48.0/20    # vsw-mnl-data-a：Tair 实测 10.0.54.118
CIDR_DATA_B=10.0.64.0/20    # vsw-mnl-data-b：RDS  实测 10.0.69.77
SG_NAT_EIPS=(47.84.184.246 47.84.29.162 47.84.83.76 47.84.126.214)   # 新加坡 NAT 出口池（任务 12）

FAILED=0; ADDED=0; SKIPPED=0

log()  { printf '%s\n' "$*" >&2; }
fail() { log "  ! 失败    $*"; FAILED=$((FAILED + 1)); }

# ---------- 基础操作 ----------
LOOKUP_ERR=""
sg_id_by_name() {   # <region> <name>  → stdout: sg-xxx（精确匹配，查不到输出空；失败置 LOOKUP_ERR）
  local r=$1 n=$2 q i out
  q="SecurityGroups.SecurityGroup[?SecurityGroupName=='$n'].SecurityGroupId | [0]"
  LOOKUP_ERR=""
  for i in 1 2 3; do
    out=$(aliyun ecs DescribeSecurityGroups --RegionId "$r" --PageSize 100 --cli-query "$q" 2>&1 | tr -d '\r')
    if printf '%s' "$out" | grep -qiE 'error|throttl|timeout|SDK\.'; then
      LOOKUP_ERR="$out"; sleep 3; continue
    fi
    printf '%s' "$out" | tr -d '" \r\n' | sed 's/^null$//'
    return 0
  done
  printf ''
}

ensure_sg() {       # <region> <vpc> <rg> <name> <desc>  → stdout: sg-xxx
  local r=$1 v=$2 rg=$3 n=$4 d=$5 id out
  id=$(sg_id_by_name "$r" "$n")
  if [[ -n "$LOOKUP_ERR" ]]; then
    log "$LOOKUP_ERR"; fail "查询 $n 失败（拒绝新建，防重复组）"; printf ''; return 0
  fi
  if [[ -n "$id" ]]; then
    log "= 已存在  $n  $id"
    printf '%s' "$id"; return 0
  fi
  if [[ $DRY -eq 1 ]]; then
    log "[dry-run] 建组 $n（$r / $v）"
    printf 'sg-dryrun-%s' "$n"; return 0
  fi
  out=$(aliyun ecs CreateSecurityGroup --RegionId "$r" --VpcId "$v" --ResourceGroupId "$rg" \
        --SecurityGroupName "$n" --ServiceManaged false --Description "$d" 2>&1 | tr -d '\r')
  if printf '%s' "$out" | grep -qE '"Code"|ErrorCode|^ERROR'; then
    log "$out"; fail "建组 $n"; printf ''; return 0
  fi
  id=$(printf '%s' "$out" | grep -o '"SecurityGroupId": *"[^"]*"' | sed 's/.*: *"//; s/"$//' | head -1)
  log "+ 已新建  $n  $id"
  printf '%s' "$id"
}

# ---------- 规则集合（预读，用于把「已存在」和「已添加」正确区分开） ----------
# 注：Permissions.N.* 新路径下，重复规则**不会**返回 InvalidPermission.Duplicate，
#     而是静默成功并去重 → 只靠返回值无法区分，必须前置比对。
declare -A RULE_SET=()
req_key() { printf '%s|%s|%s|%s|%s|%s|%s|%s' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"; }

load_rules() {      # <region> <sgid>
  local r=$1 sg=$2 key
  [[ $DRY -eq 1 ]] && return 0
  # ⚠️ 不能用 `IFS=$'\t' read a b c ...` 拆 TSV：tab 属 IFS 空白字符，
  #    连续 tab（空字段）会被折叠 → 列错位（踩过）。直接让 jq 拼出整条 key。
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    RULE_SET["$key"]=1
  done < <(aliyun ecs DescribeSecurityGroupAttribute --RegionId "$r" --SecurityGroupId "$sg" \
             --cli-query 'Permissions.Permission[].[Direction,PortRange,SourceCidrIp,SourceGroupId,DestCidrIp,Description]' \
             2>/dev/null | tr -d '\r' \
             | jq -r --arg r "$r" --arg sg "$sg" '.[] | [$r,$sg,.[0],.[1],.[2],.[3],.[4],.[5]] | join("|")' 2>/dev/null)
}

exec_rule() {       # <api> <label> <region> <sgid> <key> <Permissions.N.* 参数...>
  local api=$1 label=$2 r=$3 sg=$4 key=$5; shift 5
  if [[ -n "${RULE_SET["$key"]:-}" ]]; then
    log "  = 已存在  $label"; SKIPPED=$((SKIPPED + 1)); return 0
  fi
  if [[ $DRY -eq 1 ]]; then log "[dry-run] $api  $label"; return 0; fi
  local out
  out=$(aliyun ecs "$api" --RegionId "$r" --SecurityGroupId "$sg" "$@" 2>&1 | tr -d '\r')
  if printf '%s' "$out" | grep -q 'InvalidPermission.Duplicate'; then
    log "  = 已存在  $label"; SKIPPED=$((SKIPPED + 1)); RULE_SET["$key"]=1; return 0
  fi
  if printf '%s' "$out" | grep -qE '"Code"|ErrorCode|^ERROR'; then
    log "$out"; fail "规则 $label（$api）"; return 0
  fi
  log "  + 已添加  $label"; ADDED=$((ADDED + 1)); RULE_SET["$key"]=1
}

in_cidr()  { local k; k=$(req_key "$1" "$2" ingress "$3" "$5" "" "" "$4")
  exec_rule AuthorizeSecurityGroup "$4" "$1" "$2" "$k" \
  --Permissions.1.IpProtocol tcp --Permissions.1.PortRange "$3" \
  --Permissions.1.SourceCidrIp "$5" --Permissions.1.NicType intranet \
  --Permissions.1.Policy accept --Permissions.1.Priority 1 --Permissions.1.Description "$4"; }
in_group() { local k; k=$(req_key "$1" "$2" ingress "$3" "" "$5" "" "$4")
  exec_rule AuthorizeSecurityGroup "$4" "$1" "$2" "$k" \
  --Permissions.1.IpProtocol tcp --Permissions.1.PortRange "$3" \
  --Permissions.1.SourceGroupId "$5" --Permissions.1.NicType intranet \
  --Permissions.1.Policy accept --Permissions.1.Priority 1 --Permissions.1.Description "$4"; }
out_cidr() { local k; k=$(req_key "$1" "$2" egress "$3" "" "" "$5" "$4")
  exec_rule AuthorizeSecurityGroupEgress "$4" "$1" "$2" "$k" \
  --Permissions.1.IpProtocol tcp --Permissions.1.PortRange "$3" \
  --Permissions.1.DestCidrIp "$5" --Permissions.1.NicType intranet \
  --Permissions.1.Policy accept --Permissions.1.Priority 1 --Permissions.1.Description "$4"; }

dump_sg() {         # <region> <name>
  local r=$1 n=$2 id
  id=$(sg_id_by_name "$r" "$n")
  if [[ -n "$LOOKUP_ERR" || -z "$id" ]]; then log "  [缺失] $n  ($r)"; return 0; fi
  log "  [存在] $n  $id  ($r)"
  aliyun ecs DescribeSecurityGroupAttribute --RegionId "$r" --SecurityGroupId "$id" \
    --cli-query 'Permissions.Permission[].{Dir:Direction,Port:PortRange,SrcIp:SourceCidrIp,SrcGrp:SourceGroupId,DstIp:DestCidrIp,Desc:Description}' \
    2>/dev/null | tr -d '\r' | sed 's/^/        /' >&2
}

# ==============================================================================
if [[ $VERIFY -eq 1 ]]; then
  log "===== 业务安全组现状（只读） ====="
  for pair in "$REGION_MNL:sg-mnl-alb" "$REGION_MNL:sg-mnl-app" "$REGION_MNL:sg-mnl-db" \
              "$REGION_SG:sg-sg-alb"  "$REGION_SG:sg-sg-app"; do
    dump_sg "${pair%%:*}" "${pair##*:}"
  done
  exit 0
fi

# ==============================================================================
log "===== 1/3 建组（先建被引用方） ====="
SG_MNL_ALB=$(ensure_sg "$REGION_MNL" "$VPC_MNL" "$RG_MNL" sg-mnl-alb "ALB public ingress layer (mnl)")
SG_MNL_APP=$(ensure_sg "$REGION_MNL" "$VPC_MNL" "$RG_MNL" sg-mnl-app "ACK node/pod workload SG (mnl, Terway)")
SG_MNL_DB=$(ensure_sg  "$REGION_MNL" "$VPC_MNL" "$RG_MNL" sg-mnl-db  "Data layer (RDS/Tair/ClickHouse) (mnl)")
SG_SG_ALB=$(ensure_sg  "$REGION_SG"  "$VPC_SG"  "$RG_SG"  sg-sg-alb  "ALB public ingress layer (sg standby)")
SG_SG_APP=$(ensure_sg  "$REGION_SG"  "$VPC_SG"  "$RG_SG"  sg-sg-app  "ACK node/pod workload SG (sg standby, Terway)")

if [[ -z "$SG_MNL_ALB" || -z "$SG_MNL_APP" || -z "$SG_MNL_DB" || -z "$SG_SG_ALB" || -z "$SG_SG_APP" ]]; then
  log "有安全组未就位，跳过规则阶段"; exit 1
fi

log "===== 2/3 建规则（入向 AuthorizeSecurityGroup / 出向 AuthorizeSecurityGroupEgress） ====="
log "  预读现有规则…"
for _sg in "$SG_MNL_ALB" "$SG_MNL_APP" "$SG_MNL_DB"; do load_rules "$REGION_MNL" "$_sg"; done
for _sg in "$SG_SG_ALB" "$SG_SG_APP";           do load_rules "$REGION_SG"  "$_sg"; done

# --- sg-mnl-alb：公网入口 ---
in_cidr "$REGION_MNL" "$SG_MNL_ALB" 443/443 "pub-https-ingress" 0.0.0.0/0
in_cidr "$REGION_MNL" "$SG_MNL_ALB" 80/80   "http-301-only"     0.0.0.0/0

# --- sg-mnl-app：入向仅 ALB；出向 db/tair/上游 ---
in_group "$REGION_MNL" "$SG_MNL_APP" 3000/3000 "from-alb-only" "$SG_MNL_ALB"
out_cidr "$REGION_MNL" "$SG_MNL_APP" 5432/5432 "to-rds-pg-primary"     "$CIDR_DATA_B"
out_cidr "$REGION_MNL" "$SG_MNL_APP" 5432/5432 "to-rds-pg-primary-az-a" "$CIDR_DATA_A"
out_cidr "$REGION_MNL" "$SG_MNL_APP" 6379/6379 "to-tair-cache"         "$CIDR_DATA_A"
out_cidr "$REGION_MNL" "$SG_MNL_APP" 6379/6379 "to-tair-cache-az-b"    "$CIDR_DATA_B"
out_cidr "$REGION_MNL" "$SG_MNL_APP" 443/443   "to-upstream-api-via-nat" 0.0.0.0/0

# --- sg-mnl-db：只收 app 组 + 新加坡 NAT 出口池 ---
in_group "$REGION_MNL" "$SG_MNL_DB" 5432/5432 "from-app-only" "$SG_MNL_APP"
for ip in "${SG_NAT_EIPS[@]}"; do
  in_cidr "$REGION_MNL" "$SG_MNL_DB" 5432/5432 "from-sg-nat-eip" "$ip/32"
done

# --- 新加坡 ---
in_cidr  "$REGION_SG" "$SG_SG_ALB" 443/443 "pub-https-ingress" 0.0.0.0/0
in_cidr  "$REGION_SG" "$SG_SG_ALB" 80/80   "http-301-only"     0.0.0.0/0
in_group "$REGION_SG" "$SG_SG_APP" 3000/3000 "from-alb-only" "$SG_SG_ALB"
out_cidr "$REGION_SG" "$SG_SG_APP" 443/443   "to-upstream-api-via-nat" 0.0.0.0/0

# --- 可选：运维入口（需企业办公出口 IP 段） ---
if [[ -n "$OFFICE_CIDR" ]]; then
  log "--- 运维入口 SG（办公出口 $OFFICE_CIDR） ---"
  SG_MNL_EDGE=$(ensure_sg "$REGION_MNL" "$VPC_MNL" "$RG_MNL" sg-mnl-alb-edge "Ops bastion / jump host (mnl)")
  SG_MNL_ACK=$(ensure_sg  "$REGION_MNL" "$VPC_MNL" "$RG_MNL" sg-mnl-ack-api  "ACK API server endpoint (mnl)")
  if [[ -n "$SG_MNL_EDGE" ]]; then
    in_cidr "$REGION_MNL" "$SG_MNL_EDGE" 22/22   "from-office-only" "$OFFICE_CIDR"
    in_cidr "$REGION_MNL" "$SG_MNL_EDGE" 443/443 "from-office-only" "$OFFICE_CIDR"
  fi
  [[ -n "$SG_MNL_ACK" ]] && in_cidr "$REGION_MNL" "$SG_MNL_ACK" 6443/6443 "from-office-only" "$OFFICE_CIDR"
fi

# ==============================================================================
log ""
log "===== 3/3 汇总 ====="
log "  新增 $ADDED 条 / 已存在 $SKIPPED 条 / 失败 $FAILED 条"
log "  SG ID 台账（回填 IaC 与 deploy/sg_ledger.md）："
log "    SG_MNL_ALB=$SG_MNL_ALB"
log "    SG_MNL_APP=$SG_MNL_APP"
log "    SG_MNL_DB=$SG_MNL_DB"
log "    SG_SG_ALB=$SG_SG_ALB"
log "    SG_SG_APP=$SG_SG_APP"
log ""
log "  ⏳ 必须延后（依赖未产生的值，勿手抄）："
log "    1) sg-mnl-alb in 443 <- \${DCDN_L2_IPS}：DCDN 未开通 → 按坑 1 走 WAF 云原生接入，本条【不适用】"
log "    2) sg-mnl-alb in <- GTM 探测源 IP 段：GTM 未建（任务 21 后补，同时加 WAF 白名单）"
log "    3) sg-sg-app out 5432 -> \${RDS_MNL_PUB}/32：RDS 公网地址未开（当前仅 Private 10.0.69.77，任务 15 后补）"
[[ -z "$OFFICE_CIDR" ]] && log "    4) sg-mnl-alb-edge / sg-mnl-ack-api：需 --office-cidr <企业办公出口 CIDR>"
log ""
log "  ⚠️ 剩余动作：把 SG_MNL_APP 挂进 ACK 节点池 scaling_group.security_group_ids，"
log "     集群级 is_enterprise_security_group 保持 false；否则 ACK 会自建托管 sg- 组（坑 2）。"

[[ $FAILED -eq 0 ]] || exit 1
