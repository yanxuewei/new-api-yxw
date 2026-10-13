#!/usr/bin/env bash
# Day 1 · 任务 29 / 任务 12 补丁：给 SG NAT 补 app-c / app-d 的 SNAT 条目
#
# 背景（2026-10-09 任务 29 执行记录 6 发现）：
#   10-08 把 SG 由 2 AZ 扩到 4 AZ 时新建了 app-c(10.1.80.0/20 @1c) / app-d(10.1.96.0/20 @1d)，
#   但 NAT `nat-sg-prod` 的 SNAT 条目只覆盖 app-a/app-b/pub-a/pub-b。四个 app 段与 pub 段
#   **共用同一张路由表**（vtb-t4n7be2ip07nuflfyppux：0.0.0.0/0 → ngw-t4n7gdnoh56rwrw3zds48）
#   ⇒ 落在这两段的 Pod 有默认路由、无 SNAT 映射 = **无公网出口**（上游 API / CK 公网端点
#   43.118.97.47 / ACR 公网拉取都会失败）。本脚本把缺失的两条补齐，口径与既有 4 条逐字一致。
#
# 命名与出口口径沿用既有条目：
#   SnatEntryName = snat-sg-vsw-<vSwitchId 去掉 vsw- 前缀>；SnatIp = 现有 4 个 EIP（全放，出口轮换）
# 幂等：按 SourceCIDR 判存在即 SKIP；--ClientToken 保证重跑不重复建
#
# 用法：bash deploy/tasks/task29/sg_snat.sh preflight|dryrun|create|verify|all
set -uo pipefail

REGION=ap-southeast-1
NATGW=ngw-t4n7gdnoh56rwrw3zds48              # nat-sg-prod
SNATTABLE=stb-t4n6c9zs6lszt9479404c
EIPS='47.84.184.246,47.84.29.162,47.84.83.76,47.84.126.214'
# <name后缀>|<SourceCIDR>|<vSwitchId>
SPECS=(
  "app-c|10.1.80.0/20|vsw-t4n2e0pkpxymjxkwvcuu6"
  "app-d|10.1.96.0/20|vsw-t4n4vw9aj22wyppbbec9w"
)

OUTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../logs/task29_sg_snat"
mkdir -p "$OUTDIR"
log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
die() { printf '%s FAIL %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; exit 1; }

dump() { aliyun vpc DescribeSnatTableEntries --RegionId "$REGION" --NatGatewayId "$NATGW" --PageSize 50; }

preflight() {
  dump >"$OUTDIR/snat_before.json" || die "DescribeSnatTableEntries 失败"
  local n exist
  n=$(jq -r '[.SnatTableEntries.SnatTableEntry[]?] | length' "$OUTDIR/snat_before.json")
  log "现有 SNAT 条目 $n 条"
  jq -r '.SnatTableEntries.SnatTableEntry[]? | [.SnatEntryId,.SourceCIDR,.SnatIp,.Status] | @tsv' "$OUTDIR/snat_before.json" | sed 's/^/    /'
  for s in "${SPECS[@]}"; do
    IFS='|' read -r tag cidr vsw <<<"$s"
    exist=$(jq -r --arg c "$cidr" '[.SnatTableEntries.SnatTableEntry[]? | select(.SourceCIDR==$c)] | length' "$OUTDIR/snat_before.json")
    if [ "$exist" != "0" ]; then
      log "  [$tag] $cidr 已有条目 ⇒ 幂等闸门命中，SKIP"
    else
      log "  [$tag] $cidr 缺失 ⇒ 待新建（vSwitch $vsw）"
    fi
  done
}

dryrun() {
  preflight
  for s in "${SPECS[@]}"; do
    IFS='|' read -r tag cidr vsw <<<"$s"
    log "[$tag] CreateSnatEntry --DryRun true（零费用、不落配置）"
    aliyun vpc CreateSnatEntry --RegionId "$REGION" --SnatTableId "$SNATTABLE" \
      --SourceCIDR "$cidr" --SnatIp "$EIPS" \
      --SnatEntryName "snat-sg-vsw-${vsw#vsw-}" \
      --ClientToken "snat-sg-${tag}-20261010" --DryRun true >"$OUTDIR/dryrun_${tag}.txt" 2>&1
    if grep -qiE '"RequestId"|DryRunOperation' "$OUTDIR/dryrun_${tag}.txt"; then
      log "  DryRun OK"
    else
      log "  DryRun 输出：$(tr '\n' ' ' <"$OUTDIR/dryrun_${tag}.txt" | cut -c1-300)"
      die "DryRun 未通过 ⇒ 停止，不进入真实写入"
    fi
  done
}

create() {
  preflight
  local i=0
  for s in "${SPECS[@]}"; do
    IFS='|' read -r tag cidr vsw <<<"$s"
    i=$((i+1))
    if [ "$(jq -r --arg c "$cidr" '[.SnatTableEntries.SnatTableEntry[]? | select(.SourceCIDR==$c)] | length' "$OUTDIR/snat_before.json")" != "0" ]; then
      log "[$tag] $cidr 已存在 ⇒ SKIP"
      continue
    fi
    log "[$tag] CreateSnatEntry 真实写入：$cidr → $EIPS"
    aliyun vpc CreateSnatEntry --RegionId "$REGION" --SnatTableId "$SNATTABLE" \
      --SourceCIDR "$cidr" --SnatIp "$EIPS" \
      --SnatEntryName "snat-sg-vsw-${vsw#vsw-}" \
      --ClientToken "snat-sg-${tag}-20261010" >"$OUTDIR/create_${tag}.json" 2>&1 \
      || { cat "$OUTDIR/create_${tag}.json"; die "CreateSnatEntry($tag) 失败"; }
    jq -c '{RequestId,SnatEntryId}' "$OUTDIR/create_${tag}.json" 2>/dev/null || cat "$OUTDIR/create_${tag}.json"
    sleep 2
  done
}

verify() {
  dump >"$OUTDIR/snat_after.json" || die "DescribeSnatTableEntries 失败"
  echo "── 写入后全量 SNAT 条目 ──"
  jq -r '.SnatTableEntries.SnatTableEntry[]? | [.SnatEntryId,.SourceCIDR,.SnatIp,.Status,.SnatEntryName] | @tsv' "$OUTDIR/snat_after.json"
  echo "── 判据 ──"
  local n
  n=$(jq -r '[.SnatTableEntries.SnatTableEntry[]?] | length' "$OUTDIR/snat_after.json")
  [ "$n" = "6" ] && log "OK 条目数 = 6（原 4 + 新 2）" || log "WARN 条目数 = $n（期望 6）"
  for c in 10.1.80.0/20 10.1.96.0/20; do
    jq -e --arg c "$c" --arg ip "$EIPS" '.SnatTableEntries.SnatTableEntry[]? | select(.SourceCIDR==$c and .SnatIp==$ip and .Status=="Available")' \
      "$OUTDIR/snat_after.json" >/dev/null && log "OK $c → 4 个 EIP，Available" || log "WARN $c 未达期望"
  done
  # 既有 4 条必须原样保留（防误删/覆盖）
  local keep=0
  for c in 10.1.16.0/20 10.1.32.0/20 10.1.0.0/24 10.1.1.0/24; do
    jq -e --arg c "$c" '.SnatTableEntries.SnatTableEntry[]? | select(.SourceCIDR==$c)' "$OUTDIR/snat_after.json" >/dev/null && keep=$((keep+1))
  done
  [ "$keep" = "4" ] && log "OK 既有 4 条（app-a/app-b/pub-a/pub-b）原样保留" || log "WARN 既有条目只剩 $keep 条，人工复核"
}

case "${1:-}" in
  preflight) preflight ;;
  dryrun) dryrun ;;
  create) create ;;
  verify) verify ;;
  all) dryrun; create; verify ;;
  *) die "用法: $0 preflight|dryrun|create|verify|all" ;;
esac
