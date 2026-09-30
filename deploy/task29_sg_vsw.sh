#!/usr/bin/env bash
# 任务 29 前置：按 v2.1《网络、安全组、EIP 与凭据规划》补建新加坡 data 层交换机。
# 背景：§2.2 基线表只登记了 SG 的 pub-a/pub-b/app-a/app-b 四个交换机，
#       v2.1 表格另有 vsw-sg-data-a/b（RDS、Tair / ClickHouse 用，"数据库不暴露公网子网"），
#       实际账号里不存在 ⇒ 任务 29 的 CreateInstance 无落点。
# 用法：bash deploy/task29_sg_vsw.sh verify    # 只读预检（幂等 + 网段冲突）
#       bash deploy/task29_sg_vsw.sh create    # 建交换机 + 归位资源组 + 回读
set -euo pipefail

REGION=ap-southeast-1
VPC=vpc-t4nimmwvruexbnene0a3r
RG=rg-aek4zvb3ldoiyua                     # rg-ph-sg，与既有 4 个 SG 交换机同组
OUTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logs/task29_sg_vsw"
mkdir -p "$OUTDIR"

# name:zone:cidr —— 与 v2.1 表格逐字一致；CIDR 建成后不可改，改这里等于改架构
SPECS=(
  "vsw-sg-data-a:ap-southeast-1a:10.1.48.0/20"
  "vsw-sg-data-b:ap-southeast-1b:10.1.64.0/20"
)

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
die() { printf '%s FAIL %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; exit 1; }

ip2int() { local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (a << 24) + (b << 16) + (c << 8) + d )); }

# overlap CIDRA CIDRB —— 两个网段是否有交集（用两侧较窄的掩码比对网络号）
overlap() {
  local m1 m2 m i1 i2
  m1=$((0xFFFFFFFF << (32 - ${1#*/})))
  m2=$((0xFFFFFFFF << (32 - ${2#*/})))
  m=$((m1 < m2 ? m1 : m2))
  i1=$(( $(ip2int "${1%/*}") & m ))
  i2=$(( $(ip2int "${2%/*}") & m ))
  [[ $i1 -eq $i2 ]]
}

snapshot() {
  local f=$1
  aliyun vpc DescribeVSwitches --RegionId "$REGION" --VpcId "$VPC" --PageSize 50 >"$f" \
    || die "DescribeVSwitches 调用失败"
  jq -r '.VSwitches.VSwitch[] | [.VSwitchName, .ZoneId, .CidrBlock, .Status, (.AvailableIpAddressCount|tostring)] | @tsv' "$f"
}

# plan_status name cidr —— 打印 exists（同名已建，跳过）或 free（可建）；网段交叠直接终止
plan_status() {
  local name=$1 cidr=$2 other
  if jq -e --arg n "$name" '.VSwitches.VSwitch[] | select(.VSwitchName == $n)' \
      "$OUTDIR/vsw_before.json" >/dev/null 2>&1; then
    echo exists
    return
  fi
  for other in $(jq -r '.VSwitches.VSwitch[].CidrBlock' "$OUTDIR/vsw_before.json"); do
    overlap "$cidr" "$other" && die "$name 的 $cidr 与既有交换机 $other 交叠"
  done
  echo free
}

verify() {
  log "现有 SG 交换机（name / zone / cidr / status / free）："
  snapshot "$OUTDIR/vsw_before.json"
  log "TotalCount = $(jq -r '.TotalCount' "$OUTDIR/vsw_before.json")"
  for spec in "${SPECS[@]}"; do
    IFS=: read -r name zone cidr <<<"$spec"
    case $(plan_status "$name" "$cidr") in
      exists) log "SKIP $name 已存在（幂等闸门命中，不重复建）" ;;
      free) log "TODO $name $zone $cidr（无同名、无网段交叠）" ;;
    esac
  done
}

move_to_rg() {
  local id=$1
  local cur
  cur=$(aliyun vpc DescribeVSwitchAttributes --RegionId "$REGION" --VSwitchId "$id" |
    jq -r '.ResourceGroupId // empty')
  if [[ "$cur" == "$RG" ]]; then
    log "资源组已正确（$cur），无需 move"
    return
  fi
  log "资源组 = ${cur:-默认} ≠ $RG，执行 MoveResourceGroup"
  aliyun vpc MoveResourceGroup --RegionId "$REGION" --ResourceId "$id" \
    --ResourceType VSwitch --NewResourceGroupId "$RG" \
    >"$OUTDIR/move_${id}.json" \
    || die "MoveResourceGroup 失败：请改用 aliyun resourcemanager MoveResources（$id → $RG）"
}

create() {
  log "写前快照（幂等闸门与网段比对的依据）："
  snapshot "$OUTDIR/vsw_before.json"
  for spec in "${SPECS[@]}"; do
    IFS=: read -r name zone cidr <<<"$spec"
    if [[ $(plan_status "$name" "$cidr") == exists ]]; then
      log "SKIP $name 已存在"
      continue
    fi
    log "CreateVSwitch $name $zone $cidr"
    aliyun vpc CreateVSwitch --RegionId "$REGION" --VpcId "$VPC" --ZoneId "$zone" \
      --CidrBlock "$cidr" --VSwitchName "$name" --Description "new-api sg $name" \
      --ClientToken "newapi-$name-20260930" \
      --Tag.1.Key project --Tag.1.Value new-api \
      --Tag.2.Key site --Tag.2.Value sg \
      --Tag.3.Key env --Tag.3.Value prod \
      >"$OUTDIR/create_${name}.json" || die "CreateVSwitch $name 失败（未产生资源，可直接重跑）"
    local id
    id=$(jq -r '.VSwitchId // empty' "$OUTDIR/create_${name}.json")
    [[ -n "$id" ]] || die "CreateVSwitch $name 未回显 VSwitchId"
    log "  → $id"
    move_to_rg "$id"
    # 刷新快照：下一个 spec 的同名/交叠比对要看到刚建出来的这条
    snapshot "$OUTDIR/vsw_before.json" >/dev/null
  done

  log "回读（name / zone / cidr / status / free / rg）："
  snapshot "$OUTDIR/vsw_after.json"
  jq -r '.VSwitches.VSwitch[] | select(.VSwitchName|startswith("vsw-sg-data")) |
    [.VSwitchName, .VSwitchId, .ZoneId, .CidrBlock, .Status,
     (.AvailableIpAddressCount|tostring), .ResourceGroupId,
     ([.Tags.Tag[]? | .Key + "=" + .Value] | join(","))] | @tsv' "$OUTDIR/vsw_after.json"
}

case "${1:-}" in
  verify) verify ;;
  create) create ;;
  *) die "用法: $0 verify|create" ;;
esac
