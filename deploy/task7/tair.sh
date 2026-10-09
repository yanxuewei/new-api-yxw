#!/usr/bin/env bash
# =============================================================================
# 任务 7｜Tair 主备 4GB（马尼拉 ap-southeast-6）
#   幂等：同名实例存在则复用，不重复创建
#   用法: bash deploy/task7/tair.sh [--dry-run]
#   环境变量: REGION / TAIR_NAME / TAIR_CLASS / TAIR_ENGINE / CHARGE_TYPE
# =============================================================================
set -uo pipefail

REGION="${REGION:-ap-southeast-6}"
VPC="${VPC:-vpc-5tst1tgeessxn1azwasg2}"
VSW_DATA_A="${VSW_DATA_A:-vsw-5tswufq2pi26l4ahoiu84}"   # vsw-mnl-data-a 10.0.48.0/20
RG="${RG:-rg-aek4nyivmmsb6iy}"                            # rg-ph-mnl
NAME="${TAIR_NAME:-tair-mnl-newapi}"
ZONE_A="${ZONE_A:-ap-southeast-6a}"
ZONE_B="${ZONE_B:-ap-southeast-6b}"
# ⚠️ 实测（2026-09-28）：马尼拉 Tair **不支持跨可用区部署**。
#    带 --SecondaryZoneId ap-southeast-6b 一律 InternalFailure（DryRun 亦拒），
#    去掉后校验通过。虽然 DescribeZones 列出 6b 且 Disabled=false，
#    但 Tair 实例建不进去（DescribeAvailableResource --ZoneId 6b 恒空）。
#    → 降级为同 AZ 主从高可用。若要恢复文档口径，需 MULTI_AZ=1 且云侧开通多 AZ。
MULTI_AZ="${MULTI_AZ:-0}"
CLASS="${TAIR_CLASS:-redis.master.stand.default}"          # 官网标准 4G 主从
NODE_TYPE="${NODE_TYPE:-MASTER_SLAVE}"                     # 高可用双副本
ENGINE_VER="${TAIR_ENGINE:-5.0}"
CHARGE_TYPE="${CHARGE_TYPE:-PostPaid}"
SECURITY_IPS="${SECURITY_IPS:-10.0.16.0/20,10.0.32.0/20}"  # app-a + app-b
REPO_ROOT="${REPO_ROOT:-/mnt/e/git_code/new-api-yxw}"
ENVFILE="${ENVFILE:-$REPO_ROOT/deploy/.env}"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${OUTDIR:-$REPO_ROOT/deploy/logs/task7_$TS}"
mkdir -p "$OUTDIR"

say()  { printf '%s\n' "$*" >&2; }
step() { printf '\n>>> %s\n' "$*" >&2; }
ok()   { printf '    [OK] %s\n' "$*" >&2; }
warn() { printf '    [WARN] %s\n' "$*" >&2; }
fail() { printf '    [FAIL] %s\n' "$*" >&2; }

# api <outfile> <cmd...> —— 重试 3 次 + 校验返回是合法 JSON
api() {
  local out="$1"; shift
  if [[ "$DRY_RUN" == "1" ]]; then printf '{"_dry_run":true}\n' > "$out"; return 0; fi
  local attempt rc
  for attempt in 1 2 3; do
    "$@" > "$out" 2>&1; rc=$?
    if [[ $rc -eq 0 ]] && jq -e . "$out" >/dev/null 2>&1; then return 0; fi
    [[ $attempt -lt 3 ]] && { warn "调用失败(rc=$rc)，${attempt}/3 重试: ${out##*/}"; sleep 5; }
  done
  return 1
}

say "============================================================"
say " 任务 7｜Tair 主备 4GB  ·  $REGION  ·  $(date '+%F %T')"
say " 规格: $CLASS  /  engine $ENGINE_VER  /  $CHARGE_TYPE  /  NodeType=$NODE_TYPE"
if [[ "$MULTI_AZ" == "1" ]]; then
  say " 目标: $ZONE_A (主) + $ZONE_B (备)  ·  VPC $VPC"
else
  say " 目标: $ZONE_A 单区主从  ·  VPC $VPC   [多 AZ 不可用，见脚本头注释]"
fi
say " 证据: $OUTDIR"
say "============================================================"

# ---- 0. 幂等：查同名实例 ----------------------------------------------------
step "0. 幂等检查（按名称查现有实例）"
api "$OUTDIR/00-list.json" aliyun r-kvstore DescribeInstances --RegionId "$REGION" --PageSize 50
TOTAL=$(jq -r '.TotalCount // 0' "$OUTDIR/00-list.json" 2>/dev/null | tr -d '\r')
TAIR_ID=$(jq -r --arg n "$NAME" '[.Instances.KVStoreInstance[]?|select(.InstanceName==$n)|.InstanceId]|first // empty' \
          "$OUTDIR/00-list.json" 2>/dev/null | tr -d '\r')
say "    现有实例总数=$TOTAL  同名命中='${TAIR_ID:-无}'"

# ---- 1. 创建（或复用） ------------------------------------------------------
if [[ -n "$TAIR_ID" ]]; then
  ok "复用已存在实例 $TAIR_ID"
  TAIR_PW=""
else
  step "1. 创建 Tair 实例（主从高可用${MULTI_AZ:+；MULTI_AZ=$MULTI_AZ}）"
  if [[ "$DRY_RUN" == "1" ]]; then
    TAIR_ID="r-dryrun"; TAIR_PW="<dry-run>"
  else
    # 生成密码：保证含大写/小写/数字/特殊，长度 24，URL-safe
    TAIR_PW="Aa1-$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
    zargs=(--ZoneId "$ZONE_A")
    [[ "$MULTI_AZ" == "1" ]] && zargs+=(--SecondaryZoneId "$ZONE_B")
    api "$OUTDIR/01-create.json" aliyun r-kvstore CreateInstance \
      "${zargs[@]}" \
      --RegionId "$REGION" \
      --VpcId "$VPC" --VSwitchId "$VSW_DATA_A" --NetworkType VPC \
      --InstanceType Redis --EngineVersion "$ENGINE_VER" --InstanceClass "$CLASS" \
      --NodeType "$NODE_TYPE" \
      --ChargeType "$CHARGE_TYPE" --InstanceName "$NAME" \
      --ResourceGroupId "$RG" --Password "$TAIR_PW" \
      || { fail "创建调用失败，见 $OUTDIR/01-create.json"; exit 1; }
    cat "$OUTDIR/01-create.json" >&3 2>/dev/null || true
    TAIR_ID=$(jq -r '.InstanceId // empty' "$OUTDIR/01-create.json" 2>/dev/null | tr -d '\r')
    [[ -z "$TAIR_ID" ]] && { fail "未取到 InstanceId"; jq . "$OUTDIR/01-create.json" >&2; exit 1; }
    ok "已创建 $TAIR_ID"
  fi
fi

# ---- 2. 等待 Normal ---------------------------------------------------------
step "2. 等待实例就绪（最长 20 分钟）"
if [[ "$DRY_RUN" == "1" ]]; then
  ok "(dry-run 跳过等待)"
else
  for i in $(seq 1 40); do
    api "$OUTDIR/02-attr.json" aliyun r-kvstore DescribeInstanceAttribute --InstanceId "$TAIR_ID"
    ST=$(jq -r '.Instances.DBInstanceAttribute[0].InstanceStatus // .InstanceStatus // "?"' "$OUTDIR/02-attr.json" 2>/dev/null | tr -d '\r')
    say "    [$i/40] status=$ST"
    [[ "$ST" == "Normal" ]] && { ok "实例 Normal"; break; }
    [[ "$ST" == "?" || -z "$ST" ]] && warn "状态解析为空，继续等待"
    sleep 30
  done
  [[ "$ST" != "Normal" ]] && { fail "等待超时，最后状态=$ST"; exit 1; }
fi

# ---- 3. 参数：maxmemory-policy + 危险命令禁用 -------------------------------
step "3. 修改参数（allkeys-lru + 禁用 flushall/flushdb/keys）"
# ⚠️ 实测校正（2026-09-28）：
#   - 正确 API 是 ModifyInstanceConfig（ModifyInstanceParameter 是"应用参数模板"，需
#     --ParameterGroupId，直传 --Parameters 会 ProxyError）
#   - maxmemory-policy 是标准 Redis 参数，**不带** #no_loose_ 前缀（默认 volatile-lru）
#   - #no_loose_disabled-commands 是 Tair 扩展参数，**带**前缀
api "$OUTDIR/03-param.json" aliyun r-kvstore ModifyInstanceConfig --InstanceId "$TAIR_ID" \
  --Config '{"maxmemory-policy":"allkeys-lru","#no_loose_disabled-commands":"flushall,flushdb,keys"}' \
  && ok "参数已提交" || { fail "参数修改失败"; cat "$OUTDIR/03-param.json" >&2; }

# ---- 4. 白名单 --------------------------------------------------------------
step "4. 白名单 mnl_app = $SECURITY_IPS"
# ⚠️ 实测校正：组名参数是 --SecurityIpGroupName（文档写的 --DBInstanceIPArrayName 无效）
api "$OUTDIR/04-whitelist.json" aliyun r-kvstore ModifySecurityIps --InstanceId "$TAIR_ID" \
  --SecurityIps "$SECURITY_IPS" --ModifyMode Cover --SecurityIpGroupName mnl_app \
  && ok "白名单已提交" || { fail "白名单设置失败"; cat "$OUTDIR/04-whitelist.json" >&2; }

# ---- 5. 终验 -----------------------------------------------------------------
step "5. 终验"
api "$OUTDIR/05-final.json" aliyun r-kvstore DescribeInstanceAttribute --InstanceId "$TAIR_ID"
jq -r '.Instances.DBInstanceAttribute[0] // .' "$OUTDIR/05-final.json" 2>/dev/null \
  | jq -r '{InstanceId,InstanceName,InstanceStatus,ZoneId,SecondaryZoneId,InstanceClass,Capacity,ConnectionDomain,Port,ChargeType,ResourceGroupId}' 2>/dev/null >&3
# 5b. 参数复核（maxmemory-policy 应已生效）
api "$OUTDIR/05b-params.json" aliyun r-kvstore DescribeParameters --DBInstanceId "$TAIR_ID"
MP=$(jq -r '.RunningParameters.Parameter[]?|select(.ParameterName=="maxmemory-policy")|.ParameterValue' \
     "$OUTDIR/05b-params.json" 2>/dev/null | tr -d '\r')
DC=$(jq -r '.RunningParameters.Parameter[]?|select(.ParameterName=="#no_loose_disabled-commands")|.ParameterValue' \
     "$OUTDIR/05b-params.json" 2>/dev/null | tr -d '\r')
say "    maxmemory-policy = $MP  |  disabled-commands = $DC" >&3
[[ "$MP" == "allkeys-lru" ]] && ok "maxmemory-policy=allkeys-lru ✅" || warn "maxmemory-policy 未生效（当前 $MP）"

# 5c. 白名单复核
api "$OUTDIR/05c-ips.json" aliyun r-kvstore DescribeSecurityIps --InstanceId "$TAIR_ID"
jq -r '.SecurityIpGroups.SecurityIpGroup[]?|"    WL \(.SecurityIpGroupName): \(.SecurityIpList)"' \
   "$OUTDIR/05c-ips.json" 2>/dev/null >&3

HOST=$(jq -r '.Instances.DBInstanceAttribute[0].ConnectionDomain // empty' "$OUTDIR/05-final.json" 2>/dev/null | tr -d '\r')
PORT=$(jq -r '.Instances.DBInstanceAttribute[0].Port // 6379' "$OUTDIR/05-final.json" 2>/dev/null | tr -d '\r')
CAP=$(jq -r '.Instances.DBInstanceAttribute[0].Capacity // empty' "$OUTDIR/05-final.json" 2>/dev/null | tr -d '\r')
SAZ=$(jq -r '.Instances.DBInstanceAttribute[0].SecondaryZoneId // empty' "$OUTDIR/05-final.json" 2>/dev/null | tr -d '\r')

# ---- 6. 写凭证（gitignored） -------------------------------------------------
if [[ "$DRY_RUN" != "1" && -n "$TAIR_PW" ]]; then
  step "6. 写凭证到 $ENVFILE（.env 已被 .gitignore 覆盖）"
  {
    echo ""
    echo "# --- 任务7 Tair (马尼拉) · $TS ---"
    echo "TAIR_MNL_ID=$TAIR_ID"
    echo "TAIR_MNL_HOST=$HOST"
    echo "TAIR_MNL_PORT=$PORT"
    echo "TAIR_MNL_PASSWORD=$TAIR_PW"
    echo "REDIS_CONN_STRING=redis://default:${TAIR_PW}@${HOST}:${PORT}/0"
  } >> "$ENVFILE"
  chmod 600 "$ENVFILE"
  ok "已写入（600）"
fi

say ""
say "============================================================"
say " 结果"
say "  InstanceId      : $TAIR_ID"
say "  内网地址        : $HOST:$PORT"
say "  规格 / 容量      : $CLASS / ${CAP}MB"
say "  主区 / 备区      : $ZONE_A / ${SAZ:-未返回}"
say "  证据目录        : $OUTDIR"
say "============================================================"
