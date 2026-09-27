#!/usr/bin/env bash
# =============================================================================
# 阿里云国际站「控制台核实」四问 — 一键核实脚本
#
# 核实项：
#   Q1  菲律宾马尼拉 ap-southeast-6 能否选 ClickHouse (CK)
#   Q2  g8i 规格族在马尼拉的库存 (DescribeAvailableResource)
#   Q3  OSS 同城冗余 ZRS 可用性 (GetBucketInfo -> DataRedundancyType)
#   Q4  CMS/云拨测 拨测点覆盖 (DescribeSiteMonitorISPCityList)
#
# 前置：
#   1) 安装阿里云 CLI（本仓库已装到 ~/.workbuddy/binaries/aliyun-cli/aliyun）
#   2) 配置凭证（二选一）：
#        a. aliyun configure --profile default --mode AK
#        b. export ALIBABA_CLOUD_ACCESS_KEY_ID=xxx
#           export ALIBABA_CLOUD_ACCESS_KEY_SECRET=xxx
#      ⚠️ 不要用主账号 AK。用只读 RAM 子账号，仅授 AliyunReadOnlyAccess 即可。
#
# 用法：
#   bash verify_aliyun_4q.sh                # 全部四问
#   bash verify_aliyun_4q.sh 1 2            # 只跑第 1、2 问
#   OSS_BUCKET=my-bucket bash verify_aliyun_4q.sh 3
# =============================================================================

set -uo pipefail

ALIYUN_BIN="${ALIYUN_BIN:-$HOME/.workbuddy/binaries/aliyun-cli/aliyun}"
REGION="${REGION:-ap-southeast-6}"
ZONE_A="${ZONE_A:-ap-southeast-6a}"
ZONE_B="${ZONE_B:-ap-southeast-6b}"
SPEC="${SPEC:-ecs.g8i.2xlarge}"
OSS_BUCKET="${OSS_BUCKET:-}"
TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${OUTDIR:-./.workbuddy/verify_out_$TS}"

mkdir -p "$OUTDIR"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
ok()   { printf '%s[PASS]%s %s\n' "$c_grn" "$c_off" "$*"; }
bad()  { printf '%s[FAIL]%s %s\n' "$c_red" "$c_off" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$c_yel" "$c_off" "$*"; }
info() { printf '%s%s%s\n' "$c_dim" "$*" "$c_off"; }

need_cli() {
  if [[ ! -x "$ALIYUN_BIN" ]]; then
    bad "阿里云 CLI 不存在: $ALIYUN_BIN"
    echo "  安装: curl -fL -o /tmp/aliyun.tgz https://github.com/aliyun/aliyun-cli/releases/download/v3.5.1/aliyun-cli-macosx-3.5.1-amd64.tgz && tar -xzf /tmp/aliyun.tgz -C ~/.workbuddy/binaries/aliyun-cli"
    return 1
  fi
  return 0
}

# 凭证检测：环境变量优先，其次看 config.json 里是否真有 access_key_id
# 注意：`aliyun configure list` 在未配置时会报 "load configure failed"（属正常行为），
#       且失败的空配置仍会写入 config.json（无 access_key_id 字段），故不能用 profile 名判断。
have_cred() {
  if [[ -n "${ALIBABA_CLOUD_ACCESS_KEY_ID:-}" && -n "${ALIBABA_CLOUD_ACCESS_KEY_SECRET:-}" ]]; then
    return 0
  fi
  local cfg="$HOME/.aliyun/config.json"
  [[ -f "$cfg" ]] || return 1
  grep -qE '"access_key_id"[[:space:]]*:[[:space:]]*"[^"]+"' "$cfg" 2>/dev/null
}

# 全局参数：CLI 需要 --region 才能解析 endpoint（仅 --endpoint 不够，实测报 region can't be empty）
GLOBAL_ARGS=(--region "$REGION")

# 统一调用封装：截断过长输出，完整版落盘
run() {
  local label="$1"; shift
  info "  \$ aliyun ${GLOBAL_ARGS[*]} $*"
  local out
  out="$("$ALIYUN_BIN" "${GLOBAL_ARGS[@]}" "$@" 2>&1)"
  local rc=$?
  printf '%s\n' "$out" > "$OUTDIR/${label}.txt"
  printf '%s\n' "$out" | head -c 4000
  [[ ${#out} -gt 4000 ]] && printf '\n  %s... (完整输出: %s/%s.txt)%s\n' "$c_dim" "$OUTDIR" "$label" "$c_off"
  return $rc
}

run_json() { run "$@"; }

hr() { printf '\n%s\n' "────────────────────────────────────────────────────────────"; }

# =============================================================================
# Q1 — 马尼拉能否选 ClickHouse
# =============================================================================
q1() {
  hr; echo "Q1  ClickHouse 是否支持 ap-southeast-6 (菲律宾马尼拉)"
  info "文档基线: 产品地域页【不支持】 / API 接入点页【已铺设 clickhouse.ap-southeast-6.aliyuncs.com】→ 必须实测"
  echo
  run q1_DescribeRegions clickhouse DescribeRegions

  echo
  if grep -q '"RegionId":"ap-southeast-6"' "$OUTDIR/q1_DescribeRegions.txt" 2>/dev/null; then
    local zones n
    # 先把每个地域段按 {"Zones" 切成记录，再取目标 RegionId 那条 —— 避免窗口匹配混入前一地域，
    # 也绕开 BSD grep 的 \{0,n\} 上限 255 限制
    zones="$(awk -v reg="$REGION" \
             'BEGIN{RS="{\"Zones\""} index($0, "\"RegionId\":\"" reg "\""){print}' \
             "$OUTDIR/q1_DescribeRegions.txt" \
             | grep -o '"ZoneId":"[^"]*"' | sed 's/.*:"//;s/"//' | sort -u | tr '\n' ' ')"
    n=$(wc -w <<<"$zones")
    ok "ClickHouse 支持 ${REGION} ｜ 可用区: ${zones:-未知}"
    if [[ $n -le 1 ]]; then
      warn "仅 $n 个可用区 → Multi-AZ 不可用，日志库高可用受限；CK 企业版仅 OSS 存储（ESSD_L1/L2 不支持）"
      info "  → 日志主库仍建议新加坡（3 AZ + 全存储类型）"
    fi
  else
    bad "API 地域列表不含 $REGION → ClickHouse 马尼拉不可开通"
    info "  回退方案见操作指南第一章决策树：A(新加坡 CK+CEN) / B(ACK 自建) / C(RDS PG 分区表)"
  fi
  info "  控制台复核: 国际站控制台 → 云数据库 ClickHouse → 创建集群 → 地域下拉是否出现「菲律宾(马尼拉)」"
}

# =============================================================================
# Q2 — g8i 库存
# =============================================================================
q2() {
  hr; echo "Q2  $SPEC 库存 ($REGION)"
  echo
  for Z in "$ZONE_A" "$ZONE_B"; do
    echo "▸ 可用区 $Z"
    run_json "q2_${Z}" ecs DescribeAvailableResource \
      --RegionId "$REGION" \
      --ZoneId "$Z" \
      --DestinationResource InstanceType \
      --ResourceType instance \
      --InstanceType "$SPEC"
    echo
  done

  echo "▸ 该地域全部可用区"
  run_json q2_zones ecs DescribeZones --RegionId "$REGION"
  echo

  # 汇总状态
  local found=0
  for Z in "$ZONE_A" "$ZONE_B"; do
    if grep -qi "Available" "$OUTDIR/q2_${Z}.txt" 2>/dev/null && ! grep -qi "SoldOut" "$OUTDIR/q2_${Z}.txt" 2>/dev/null; then
      ok "$Z 有 $SPEC 库存 (Available)"; found=1
    elif grep -qi "SoldOut" "$OUTDIR/q2_${Z}.txt" 2>/dev/null; then
      bad "$Z $SPEC 已售罄 (SoldOut)"
    else
      warn "$Z 无返回或无该规格 → 机型未在该 AZ 上架"
    fi
  done

  if [[ $found -eq 1 ]]; then
    ok "结论: 节点池可按 $SPEC 规划（仍建议多机型混布 + 双 AZ）"
  else
    warn "结论: 需换机型。候选同代替代：g8i→g8ise/g8a/g8y/c8i/r8i；先跑下面探查"
    echo
    echo "▸ 探查该地域所有可用规格（用于挑替代机型）"
    run_json q2_alltypes ecs DescribeAvailableResource \
      --RegionId "$REGION" --DestinationResource InstanceType --ResourceType instance
  fi
  info "  控制台复核: ECS → 实例 → 创建实例 → 地域=菲律宾(马尼拉) → 规格族筛选 g8i；或用「实例规格可购买」查询页"
}

# =============================================================================
# Q3 — OSS ZRS
# =============================================================================
q3() {
  hr; echo "Q3  OSS 同城冗余 ZRS ($REGION)"
  info "文档基线: ZRS 在 ≥2 AZ 地域支持；马尼拉 2 AZ ✔；但服务可用性 = 99.99%（非 99.995%）"
  echo
  if [[ -z "$OSS_BUCKET" ]]; then
    warn "未设置 OSS_BUCKET，跳过实测。设置后重跑：OSS_BUCKET=<name> bash $0 3"
    info "  快速判断（无需凭证）: 马尼拉 ZRS 持久性 12 个 9 / 可用性 99.99%"
    info "  控制台复核: OSS → Bucket → 创建 → 冗余类型 是否出现「同城冗余 ZRS」"
    return
  fi
  run q3_GetBucketInfo oss GetBucketInfo --Bucket "$OSS_BUCKET" 2>/dev/null \
    || run ossutil_getbucketinfo ossutil stat "oss://$OSS_BUCKET"
  echo
  if grep -qi "ZRS" "$OUTDIR/q3_GetBucketInfo.txt" 2>/dev/null; then
    ok "$OSS_BUCKET 为 ZRS（同城冗余）"
  else
    warn "$OSS_BUCKET 未检出 ZRS，可能为 LRS，或该地域不支持 ZRS"
  fi
  info "  判定标准: DataRedundancyType=LRS|ZRS；马尼拉 ZRS 服务可用性 99.99%，纳入 SLA 链需按 0.9999 计算"
}

# =============================================================================
# Q4 — CMS/云拨测 拨测点
# =============================================================================
q4() {
  hr; echo "Q4  CMS 站点监控 / 云拨测 拨测点覆盖"
  echo
  echo "▸ 站点监控 拨测点全量列表"
  run_json q4_isp_city cms DescribeSiteMonitorISPCityList
  echo
  echo "▸ 拨测配额"
  run q4_quota cms DescribeSiteMonitorQuota
  echo

  echo "▸ 马尼拉拨测节点"
  if grep -q '"CityName.en":"Manila"' "$OUTDIR/q4_isp_city.txt" 2>/dev/null; then
    # 节点对象内含嵌套 {"IPPool":...}，正则难以精确切分 → 优先用 python3 解析
    if [[ -x /usr/bin/python3 ]]; then
      /usr/bin/python3 - "$OUTDIR/q4_isp_city.txt" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
keys = ('Country.en', 'CityName.en', 'IspName.en', 'IPV4ProbeCount', 'IPV6ProbeCount', 'WinProbeCount', 'BrowserProbeCount')
for n in d.get('IspCityList', {}).get('IspCity', []):
    if n.get('CityName.en') == 'Manila':
        print("  " + json.dumps({k: n[k] for k in keys if k in n}, ensure_ascii=False))
        pool = n.get('IPPool')
        if isinstance(pool, dict) and pool.get('IPPool'):
            print("  IPPool: " + ", ".join(pool['IPPool']))
PY
    else
      grep -o '"CityName.en":"Manila"[^}]*' "$OUTDIR/q4_isp_city.txt" | head -2
    fi
    echo
    ok "马尼拉有 CMS 站点监控拨测节点（探针为阿里云自有 IP，非运营商节点）"
  else
    bad "未匹配到马尼拉拨测节点 → CMS 站点监控不支持马尼拉"
  fi
  echo
  echo "▸ 东南亚各城拨测节点数（按 CityName.en 精确计数）"
  for c in Manila Singapore Bangkok Jakarta Kuala-Lumpur; do
    printf '  %-15s %s\n' "$c" "$(grep -o "\"CityName.en\":\"$c\"" "$OUTDIR/q4_isp_city.txt" | wc -l | tr -d ' ')"
  done
  echo
  info "⚠️ 两套节点池勿混淆（本次核实的关键修正）:"
  info "  CMS 站点监控 (SiteMonitor) : 阿里云自有拨测机房，东南亚每城 1 点 → 马尼拉/曼谷【均可用】"
  info "  云拨测 (ARMS)              : 运营商 IDC/LastMile 节点 → 马尼拉 GlobeTelecom、曼谷 3BBBroadband 已于 2025-03-18 下线"
  info "  风险: 站点监控为单城单点 + 机房视角(isp=Alibaba)，不代表菲律宾本地用户体验；"
  info "        WinProbe=0 / BrowserProbe=0 → 无法做浏览器级监测"
  info "  控制台复核: 云监控控制台 → 站点监控 → 创建任务 → 拨测点选择列表"
}

# =============================================================================
main() {
  need_cli || exit 1

  # 凭证前置检查：未配置则早退出，避免四问全部空跑
  if ! have_cred; then
    warn "未检测到阿里云凭证配置"
    echo "  请先执行（推荐 RAM 只读子账号，勿用主账号 AK）："
    echo "    $ALIYUN_BIN configure --profile default --mode AK"
    echo "  或设置环境变量（脚本将自动识别）："
    echo "    export ALIBABA_CLOUD_ACCESS_KEY_ID=xxx"
    echo "    export ALIBABA_CLOUD_ACCESS_KEY_SECRET=xxx"
    echo
    echo "  说明：Q1/Q3/Q4 的结论已由官方文档交叉核实，见《控制台核实四问_结论.md》；"
    echo "        本脚本用于拿实时 API 数据兜底 + Q2 库存实测。"
    exit 2
  fi

  echo "阿里云 CLI: $("$ALIYUN_BIN" version 2>/dev/null)"
  echo "地域: $REGION   规格: $SPEC   输出目录: $OUTDIR"

  local targets=("$@")
  [[ ${#targets[@]} -eq 0 ]] && targets=(1 2 3 4)

  local failed=0
  for t in "${targets[@]}"; do
    case "$t" in
      1) q1 ;;
      2) q2 ;;
      3) q3 ;;
      4) q4 ;;
      *) warn "未知项: $t" ;;
    esac
    # 检测凭证失效
    if grep -qiE "InvalidAccessKeyId|SignatureDoesNotMatch|Forbidden|NoPermission" "$OUTDIR"/*.txt 2>/dev/null; then
      bad "检测到凭证/权限错误 → 请检查 aliyun configure 或 RAM 授权"
      failed=1
      break
    fi
  done

  hr
  echo "原始输出已保存: $OUTDIR/"
  echo "汇总: 见同目录《控制台核实四问_结论.md》"
  return $failed
}

main "$@"
