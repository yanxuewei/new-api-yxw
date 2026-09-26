#!/usr/bin/env bash
# create_vswitch.sh — new-api 菲律宾/新加坡 VPC + vSwitch 落地（对应操作指南 §2.2 / §4.1 / §5.2）
# 幂等：已存在的 VPC / vSwitch 跳过，不覆盖不改网段（vSwitch CIDR 不可修改）
# 用法：bash create_vswitch.sh            # 全量（马尼拉 6 + 新加坡 4）
#       bash create_vswitch.sh mnl|sg     # 单站点
#       bash create_vswitch.sh baseline   # 只打印可用 IP 基线
set -uo pipefail

ALIYUN="${ALIYUN:-$HOME/.workbuddy/binaries/aliyun-cli/aliyun}"
PY="${PY:-/usr/bin/python3}"
OUTDIR="${OUTDIR:-$PWD/.workbuddy/vswitch_out}"
TS=$(date +%Y%m%d-%H%M%S)
[ -x "$ALIYUN" ] || { echo "[FATAL] aliyun CLI 不存在: $ALIYUN"; exit 1; }
mkdir -p "$OUTDIR"

jqget() { "$PY" -c "import sys,json;d=json.load(sys.stdin)
p='$1'.split('.')
for k in p:
    d=d.get(k) if isinstance(d,dict) else None
    if d is None: break
print(d if d is not None else '')" 2>/dev/null; }

say() { printf '%s\n' "$*"; }
log() { printf '%s\n' "$*" >&2; }   # 日志走 stderr，避免污染 $(...) 捕获的返回值

# ---------- VPC ----------
ensure_vpc() { # region vpcname cidr desc rgid
  local region="$1" name="$2" cidr="$3" desc="$4" rgid="$5"
  local vid="" cur_rg=""
  vid=$("$ALIYUN" vpc DescribeVpcs --RegionId "$region" \
        | "$PY" -c "import sys,json;d=json.load(sys.stdin)
for v in d['Vpcs']['Vpc']:
    if v['VpcName']=='$name': print(v['VpcId']); break" 2>/dev/null)
  if [ -n "$vid" ]; then
    log "  [SKIP] VPC 已存在  $name  $vid"
  else
    vid=$("$ALIYUN" vpc CreateVpc --RegionId "$region" --VpcName "$name" \
          --CidrBlock "$cidr" --Description "$desc" \
          --ResourceGroupId "$rgid" | jqget VpcId)
    [ -n "$vid" ] || { log "  [FAIL] 创建 VPC $name 失败"; return 1; }
    log "  [OK]   创建 VPC  $name  $cidr  $vid  rg=$rgid"
  fi
  # 资源组归位：VPC 迁移会【级联】其下 vSwitch；反之 vSwitch 单独不可迁移
  if [ -n "$rgid" ]; then
    cur_rg=$("$ALIYUN" vpc DescribeVpcs --RegionId "$region" --VpcId "$vid" \
             | "$PY" -c "import sys,json;print(json.load(sys.stdin)['Vpcs']['Vpc'][0].get('ResourceGroupId',''))" 2>/dev/null)
    if [ "$cur_rg" != "$rgid" ]; then
      log "  [MOVE] VPC 资源组 $cur_rg → $rgid（级联 vSwitch）"
      "$ALIYUN" vpc MoveResourceGroup --RegionId "$region" --ResourceType vpc \
        --ResourceId "$vid" --NewResourceGroupId "$rgid" >/dev/null 2>&1 \
        && log "  [OK]   迁移完成" || log "  [FAIL] 迁移失败"
      sleep 3
    else
      log "         资源组=${cur_rg}（已就位）"
    fi
  fi
  # 等待 Available
  local st="" i=0
  while [ $i -lt 30 ]; do
    st=$("$ALIYUN" vpc DescribeVpcs --RegionId "$region" --VpcId "$vid" \
         | "$PY" -c "import sys,json;d=json.load(sys.stdin);print(d['Vpcs']['Vpc'][0]['Status'])" 2>/dev/null)
    [ "$st" = "Available" ] && break
    sleep 2; i=$((i+1))
  done
  log "         状态=$st"
  printf '%s\n' "$vid"
}

# ---------- vSwitch ----------
VSW_ID=""   # ensure_vsw 输出（避免函数内 printf 污染日志）
ensure_vsw() { # region vpcid zone cidr name site
  local region="$1" vpcid="$2" zone="$3" cidr="$4" name="$5" site="$6" sid
  VSW_ID=""
  sid=$("$ALIYUN" vpc DescribeVSwitches --RegionId "$region" --VpcId "$vpcid" \
        | "$PY" -c "import sys,json;d=json.load(sys.stdin)
for v in (d.get('VSwitches') or {}).get('VSwitch') or []:
    if v['VSwitchName']=='$name': print(v['VSwitchId']); break" 2>/dev/null)
  if [ -n "$sid" ]; then
    say "  [SKIP] vSwitch 已存在  $name  $sid"
  else    sid=$("$ALIYUN" vpc CreateVSwitch --RegionId "$region" --VpcId "$vpcid" \
          --ZoneId "$zone" --CidrBlock "$cidr" --VSwitchName "$name" \
          --Description "new-api $site $name" \
          --Tag.1.Key project --Tag.1.Value new-api \
          --Tag.2.Key site    --Tag.2.Value "$site" \
          --Tag.3.Key env     --Tag.3.Value prod 2>/tmp/vsw_err.$$ | jqget VSwitchId)
    if [ -z "$sid" ]; then
      # 退一步：不带 Tag 重试（部分地域/账号可能不认 Tag 参数）
      say "  [WARN]  带 Tag 创建失败：$(tr -d '\n' </tmp/vsw_err.$$ | head -c 160)"
      sid=$("$ALIYUN" vpc CreateVSwitch --RegionId "$region" --VpcId "$vpcid" \
            --ZoneId "$zone" --CidrBlock "$cidr" --VSwitchName "$name" \
            --Description "new-api $site $name" | jqget VSwitchId)
    fi
    [ -n "$sid" ] || { say "  [FAIL] 创建 vSwitch $name 失败：$(tr -d '\n' </tmp/vsw_err.$$ | head -c 200)"; rm -f /tmp/vsw_err.$$; return 1; }
    say "  [OK]   创建 vSwitch $name  $cidr  $zone  $sid"
  fi
  rm -f /tmp/vsw_err.$$
  VSW_ID="$sid"
}

# ---------- 站点定义（照抄 §2.2，勿改）----------
# 资源组约定（2026-09-25 20:35 定稿）：资源组必须在【创建时】指定，vSwitch 不可事后单独转移
#   rg-ph-mnl  rg-aek4nyivmmsb6iy  马尼拉【生产】prod
#   rg-sg      rg-aek4zvb3ldoiyua  新加坡【生产】备站 prod
#   rg-nonprod rg-aek4hk3prqgqjcy  staging + perf + 压测（一切非生产，含未来非生产站点）
#   rg-shared  rg-aek3yypouljf4ry  跨站共享（ACR cri-avfqy9xkqi5bj8ee / ActionTrail / CMS）
# 边界规则：生产 vs 非生产 = 权限边界（RG 维度）；站点 ph-mnl|sg = 标签/命名空间维度。
# 建非生产环境（staging/perf）时必须显式传 --ResourceGroupId rg-aek4hk3prqgqjcy，
# 且【先建 nonprod VPC 并放进 rg-nonprod，再建其 vSwitch】（vSwitch 继承 VPC 的组）。
RG_PH_MNL="${RG_PH_MNL:-rg-aek4nyivmmsb6iy}"   # 显示名 rg-ph-mnl（生产）
RG_SG="${RG_SG:-rg-aek4zvb3ldoiyua}"           # 显示名 rg-sg（生产）
RG_NONPROD="${RG_NONPROD:-rg-aek4hk3prqgqjcy}" # 显示名 rg-nonprod（staging/perf/压测）
RG_SHARED="${RG_SHARED:-rg-aek3yypouljf4ry}"   # 显示名 rg-shared（跨站共享）
SITE_MNL_REGION=ap-southeast-6; SITE_MNL_VPC=vpc-newapi-mnl-prod
SITE_MNL_CIDR=10.0.0.0/16;     SITE_MNL_TAG=ph-mnl
SITE_SG_REGION=ap-southeast-1; SITE_SG_VPC=vpc-newapi-sg-prod
SITE_SG_CIDR=10.1.0.0/16;      SITE_SG_TAG=sg

MNL_VSW=(
  "ap-southeast-6a 10.0.0.0/24  vsw-mnl-pub-a"
  "ap-southeast-6b 10.0.1.0/24  vsw-mnl-pub-b"
  "ap-southeast-6a 10.0.16.0/20 vsw-mnl-app-a"
  "ap-southeast-6b 10.0.32.0/20 vsw-mnl-app-b"
  "ap-southeast-6a 10.0.48.0/20 vsw-mnl-data-a"
  "ap-southeast-6b 10.0.64.0/20 vsw-mnl-data-b"
)
SG_VSW=(
  "ap-southeast-1a 10.1.0.0/24  vsw-sg-pub-a"
  "ap-southeast-1b 10.1.1.0/24  vsw-sg-pub-b"
  "ap-southeast-1a 10.1.16.0/20 vsw-sg-app-a"
  "ap-southeast-1b 10.1.32.0/20 vsw-sg-app-b"
)

do_site() { # label region vpcname cidr tag rgid "${VSW[@]}"
  local label="$1" region="$2" vpcname="$3" cidr="$4" tag="$5" rgid="$6"; shift 6
  say "=== $label  region=$region  vpc=$vpcname  rg=$rgid ==="
  local vpcid; vpcid=$(ensure_vpc "$region" "$vpcname" "$cidr" "new-api $label prod" "$rgid")
  [ -n "$vpcid" ] || { say "  [FATAL] 无 VpcId，跳过 $label"; return 1; }
  say "  VPC_ID=$vpcid"
  printf '%s\n' "$vpcid" >"$OUTDIR/vpcid_${tag}.txt"
  local row
  for row in "$@"; do
    # shellcheck disable=SC2086
    set -- $row
    ensure_vsw "$region" "$vpcid" "$1" "$2" "$3" "$tag"
  done
  # vSwitch 资源组漂移检查（vSwitch 不可单独转移 → 只能删了重建）
  local rg
  rg=$("$ALIYUN" vpc DescribeVSwitches --RegionId "$region" --VpcId "$vpcid" \
       | "$PY" -c "import sys,json;d=json.load(sys.stdin)
s={v.get('ResourceGroupId') for v in (d.get('VSwitches') or {}).get('VSwitch') or []}
print(','.join(sorted(x for x in s if x)))" 2>/dev/null)
  if [ "$rg" != "$rgid" ]; then
    say "  [WARN] vSwitch 资源组漂移：$rg ≠ $rgid"
    say "         vSwitch 不支持单独转组；已有依存资源时不可删 → 需先清依赖再重建"
  else
    say "  [OK]   vSwitch 资源组全部就位：$rg"
  fi
  say ""
}

baseline() { # 打印可用 IP 基线
  for r in ap-southeast-6 ap-southeast-1; do
    say "--- $r ---"
    "$ALIYUN" vpc DescribeVSwitches --RegionId "$r" \
      | "$PY" -c "import sys,json;d=json.load(sys.stdin)
for v in sorted((d.get('VSwitches') or {}).get('VSwitch') or [], key=lambda x:x['VSwitchName']):
    print('%-16s %-18s %-18s free=%-6s rg=%s' % (v['VSwitchName'], v['ZoneId'], v['CidrBlock'], v['AvailableIpAddressCount'], v.get('ResourceGroupId','-')))"
  done
}

export_snap() { # 落盘原始 JSON，归档证据
  for r in ap-southeast-6 ap-southeast-1; do
    "$ALIYUN" vpc DescribeVpcs     --RegionId "$r" >"$OUTDIR/vpcs_$r.json"
    "$ALIYUN" vpc DescribeVSwitches --RegionId "$r" >"$OUTDIR/vswitches_$r.json"
  done
  say "原始输出已归档：$OUTDIR"
}

case "${1:-all}" in
  baseline) baseline; export_snap; exit 0 ;;
  mnl) do_site "Philippines(Manila)" "$SITE_MNL_REGION" "$SITE_MNL_VPC" "$SITE_MNL_CIDR" "$SITE_MNL_TAG" "$RG_PH_MNL" "${MNL_VSW[@]}" ;;
  sg)  do_site "Singapore"           "$SITE_SG_REGION"  "$SITE_SG_VPC"  "$SITE_SG_CIDR"  "$SITE_SG_TAG"  "$RG_SG"     "${SG_VSW[@]}" ;;
  all)
    do_site "Philippines(Manila)" "$SITE_MNL_REGION" "$SITE_MNL_VPC" "$SITE_MNL_CIDR" "$SITE_MNL_TAG" "$RG_PH_MNL" "${MNL_VSW[@]}"
    do_site "Singapore"           "$SITE_SG_REGION"  "$SITE_SG_VPC"  "$SITE_SG_CIDR"  "$SITE_SG_TAG"  "$RG_SG"     "${SG_VSW[@]}"
    ;;
  *) say "用法: bash create_vswitch.sh [all|mnl|sg|baseline]"; exit 1 ;;
esac

say "=== 可用 IP 基线 ==="
baseline
say ""
export_snap
