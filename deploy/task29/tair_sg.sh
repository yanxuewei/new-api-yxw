#!/usr/bin/env bash
# Day 1 · 任务 29 第 1 步：新加坡本地 Tair（限流缓存）
#
# ── 实况（2026-10-09）──────────────────────────────────────────────────────────
# 实例已由使用者在**阿里云控制台购买**（09-30 曾走 API 下单，因账户余额 0 被交易侧
# `Trade_Not_Support_Async_Pay` 撤单，见卡内「坑 7」）。实购与 09-30 计划口径三处不同：
#   InstanceId    r-gs5ltv3m4i3655besh    Name tair-sg-newapi   Status Normal
#   InstanceClass tair.rdb.cluster.sharding.common   ← 计划为
#                 redis.amber.logic.sharding.1g.2db.0rodb.6proxy.multithread（企业版 amber 逻辑多线程）
#   Capacity 2048MB · EngineVersion 5.0 · ArchitectureType cluster · ShardCount 2 · NodeType double
#   可用区        ap-southeast-1c / SecondaryZoneId ap-southeast-1d（ZoneType=doublezone **生效**）
#                 ← 计划为 1a+1b（10-08 已把 SG 扩到 4 AZ，故 1c+1d 不是缺陷；马尼拉同款 ZoneType=singlezone）
#   落点交换机    vsw-t4nvuo2yxtftipp8vo9rn = vsw-sg-data-c（10.1.112.0/20 @1c）· PrivateIp 10.1.124.176
#                 ← 计划为 vsw-t4nr26kz6gceuz0jm4eqw = vsw-sg-data-a（10.1.48.0/20 @1a），按 §2.2 属同类数据层
#   计费          ChargeType PrePaid · CreateTime 2026-10-09T01:10:31Z · EndTime 2026-11-09T16:00:00Z
#                 ⇒ 包月 1 期、不自动续费（与 09-30 裁定一致；到期日 = 2026-11-10 00:00 +08）
#   连接地址      r-gs5ltv3m4i3655besh.redis.singapore.rds.aliyuncs.com:6379
#
# 用法：bash deploy/task29/tair_sg.sh preflight|wait|params|whitelist|check|all
#       （dryrun/create 为 09-30 的历史路径，现为安全闸门：需显式 ALLOW_CREATE=1 才会真下单）
# 口令：只从环境变量 TAIR_SG_PW 读取（定义在 ~/.bashrc ⇒ 需 `bash -lic` 起），全程不回显、不落盘
#
# ⚠ 两条实测坑（本脚本已按此写法）
#   1. 实例级 API（DescribeInstanceAttribute/DescribeSecurityIps/ModifySecurityIps/
#      ModifyInstanceParameter）**不接受 --RegionId**，必须用全局 `--region`，否则打到
#      CLI 默认地域（ap-southeast-6）→ `InvalidInstanceId.NotFound`（2026-10-09 实测）。
#      `DescribeParameters` 是例外：它的入参名是 **--DBInstanceId**（不是 --InstanceId）。
#   2. 参数名以 `DescribeParameters` 回读为准：本实例与马尼拉均为 **`maxmemory-policy`**
#      （不是 `#no_loose_maxmemory-policy`）+ `#no_loose_disabled-commands`。卡片原写法
#      `#no_loose_maxmemory-policy` 在两个实例的参数表里都不存在。
set -uo pipefail

REGION=ap-southeast-1
VPC=vpc-t4nimmwvruexbnene0a3r
VSW=vsw-t4nr26kz6gceuz0jm4eqw          # ❌ 历史：vsw-sg-data-a @1a（实购落点为 vsw-sg-data-c，见下）
VSW_ACTUAL=vsw-t4nvuo2yxtftipp8vo9rn  # vsw-sg-data-c @1c 10.1.112.0/20
PRIMARY_ZONE=ap-southeast-1a          # ❌ 历史口径（实购 1c+1d）
SECONDARY_ZONE=ap-southeast-1d        # 实购备可用区
CLASS=redis.amber.logic.sharding.1g.2db.0rodb.6proxy.multithread  # ❌ 历史：计划规格码
NAME=tair-sg-newapi
ACTUAL_ID=r-gs5ltv3m4i3655besh        # 实购实例
RG=rg-aek4zvb3ldoiyua                 # rg-ph-sg，与 SG VPC/交换机同组
WL_GROUP=sg_app
# 四个 app 段 = Terway eniip 下 Pod/节点会取的全部 vSwitch 网段（10-08 SG 扩 4 AZ 后由 2 段增至 4 段）
WL_IPS=10.1.16.0/20,10.1.32.0/20,10.1.80.0/20,10.1.96.0/20
# ⚠ 参数名与取值均按 DescribeParameters 实况（2026-10-09 两实例一致）：
#   ① 名字是 `maxmemory-policy`（**不是** `#no_loose_maxmemory-policy`——卡片原写法）；
#   ② 禁用命令的值必须**小写**且只能取 [flushall,flushdb,keys,hgetall,eval,evalsha,script]。
#   实测：名字写错或值写大写 → 报 `ProxyError / Invoke backend proxy error`（**不是**参数校验错，
#   看着像后端抖动，容易误判成"稍后重试"，实际永远不生效）。
PARAMS='{"maxmemory-policy":"allkeys-lru","#no_loose_disabled-commands":"flushall,flushdb,keys"}'

OUTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../logs/task29_tair_sg"
mkdir -p "$OUTDIR"
IDFILE="$OUTDIR/instance_id"

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
die() { printf '%s FAIL %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; exit 1; }

need_id() {
  if [[ -s "$IDFILE" ]]; then cat "$IDFILE"; return; fi
  printf '%s\n' "$ACTUAL_ID" >"$IDFILE"
  printf '%s\n' "$ACTUAL_ID"
}

preflight() {
  [[ -n "${TAIR_SG_PW:-}" ]] || die "TAIR_SG_PW 未设置（本脚本需在能读到 ~/.bashrc 的交互 shell 里跑：bash -lic '...'）"
  log "TAIR_SG_PW 已就绪（长度 ${#TAIR_SG_PW}，值不回显）"

  aliyun r-kvstore DescribeInstances --RegionId "$REGION" --PageSize 50 >"$OUTDIR/preflight_instances.json" \
    || die "DescribeInstances 调用失败"
  local n ids mine
  n=$(jq -r '.TotalCount // 0' "$OUTDIR/preflight_instances.json")
  mine=$(jq -r --arg nm "$NAME" \
    '[.Instances.KVStoreInstance[]? | select(.Name == $nm or .InstanceName == $nm) | .InstanceId] | join(",")' \
    "$OUTDIR/preflight_instances.json")
  if [[ -n "$mine" ]]; then
    log "同名实例已存在：$mine ⇒ 幂等闸门命中，复用不再建（实购于 2026-10-09，见脚本头实况）"
    printf '%s\n' "$mine" >"$IDFILE"
    return
  fi
  if [[ "$n" != "0" ]]; then
    ids=$(jq -r '[.Instances.KVStoreInstance[]?.InstanceId] | join(",")' "$OUTDIR/preflight_instances.json")
    die "$REGION 已有其它 Tair 实例（$ids）但无 $NAME ⇒ 停止，人工确认后再动"
  fi
  log "幂等闸门通过：$REGION TotalCount=0（本卡现状应为 1，见实况）"
}

create_args() {
  # ❌ 09-30 历史口径（计划规格码 g9/amber + data-a + 1a/1b）。实购走控制台，
  #    本函数保留仅作留痕；真下单前必须先按 DescribeAvailableResource 复核规格码与落点。
  printf '%s\n' \
    --RegionId "$REGION" --ZoneId "$PRIMARY_ZONE" --SecondaryZoneId ap-southeast-1b \
    --VpcId "$VPC" --VSwitchId "$VSW" --NetworkType VPC \
    --InstanceClass "$CLASS" --EngineVersion 5.0 \
    --InstanceName "$NAME" --ResourceGroupId "$RG" \
    --ChargeType PrePaid --Period 1 --AutoRenew false \
    --Port 6379
}

create() {
  [[ -s "$IDFILE" ]] && { log "已记录实例 $(cat "$IDFILE")，跳过创建"; return; }
  [[ "${ALLOW_CREATE:-0}" == "1" ]] || die "实例已由控制台购买（$ACTUAL_ID）⇒ create 已封闸。确需另建请显式 ALLOW_CREATE=1 并先人工复核规格码/落点"
  local args
  mapfile -t args < <(create_args)
  log "CreateInstance（真实下单，PrePaid Period 1）"
  aliyun r-kvstore CreateInstance "${args[@]}" --Password "$TAIR_SG_PW" \
    >"$OUTDIR/create.json" 2>"$OUTDIR/create.err" \
    || { log "下单失败：$(tr '\n' ' ' <"$OUTDIR/create.err" | cut -c1-400)"; die "CreateInstance 非零退出"; }
  jq -r '.InstanceId // empty' "$OUTDIR/create.json" >"$IDFILE" || true
  [[ -s "$IDFILE" ]] || die "CreateInstance 未回显 InstanceId（响应见 $OUTDIR/create.json，人工核对后再重试）"
  log "  → $(cat "$IDFILE")  OrderId=$(jq -r '.OrderId // "-"' "$OUTDIR/create.json")"
}

wait_normal() {
  local id st
  id=$(need_id)
  for _ in $(seq 1 40); do
    aliyun r-kvstore DescribeInstanceAttribute --region "$REGION" --InstanceId "$id" >"$OUTDIR/attr_wait.json" 2>/dev/null || true
    st=$(jq -r '.Instances.DBInstanceAttribute[0].InstanceStatus // empty' "$OUTDIR/attr_wait.json" 2>/dev/null)
    [[ "$st" == "Normal" ]] && { log "InstanceStatus=Normal"; return; }
    log "  等待中：InstanceStatus=${st:-空}"
    sleep 15
  done
  die "40 次轮询后仍未进入 Normal"
}

params() {
  local id
  id=$(need_id)
  log "ModifyInstanceParameter：maxmemory-policy=allkeys-lru + 禁用危险命令（参数名按 DescribeParameters 实况）"
  aliyun r-kvstore ModifyInstanceParameter --region "$REGION" --InstanceId "$id" --Parameters "$PARAMS" \
    >"$OUTDIR/modify_params.json" 2>&1 || { cat "$OUTDIR/modify_params.json"; die "ModifyInstanceParameter 失败"; }
  jq -c '.RequestId' "$OUTDIR/modify_params.json"
}

whitelist() {
  local id
  id=$(need_id)
  log "ModifySecurityIps：组 $WL_GROUP = $WL_IPS（ModifyMode Cover 的作用域是该组，default 不动）"
  aliyun r-kvstore ModifySecurityIps --region "$REGION" --InstanceId "$id" --SecurityIps "$WL_IPS" \
    --ModifyMode Cover --SecurityIpGroupName "$WL_GROUP" \
    >"$OUTDIR/modify_ips.json" 2>&1 || { cat "$OUTDIR/modify_ips.json"; die "ModifySecurityIps 失败"; }
  jq -c '.RequestId' "$OUTDIR/modify_ips.json"
}

check() {
  local id
  id=$(need_id)
  aliyun r-kvstore DescribeInstanceAttribute --region "$REGION" --InstanceId "$id" >"$OUTDIR/check_attr.json" 2>&1 \
    || die "DescribeInstanceAttribute 失败"
  aliyun r-kvstore DescribeSecurityIps --region "$REGION" --InstanceId "$id" >"$OUTDIR/check_ips.json" 2>&1 \
    || die "DescribeSecurityIps 失败"
  aliyun r-kvstore DescribeParameters --region "$REGION" --DBInstanceId "$id" >"$OUTDIR/check_params.json" 2>&1 \
    || die "DescribeParameters 失败（注意它的入参名是 --DBInstanceId）"
  echo "── V5 实例回读 ──"
  jq '.Instances.DBInstanceAttribute[0] | {InstanceId,InstanceName,InstanceStatus,InstanceClass,Capacity,EngineVersion,ZoneId,SecondaryZoneId,ZoneType,AutoSecondaryZone,NodeType,ArchitectureType,ShardCount,NetworkType,VpcId,VSwitchId,PrivateIp,ConnectionDomain,Port,ChargeType,CreateTime,EndTime,ResourceGroupId,Config,SecurityIPList}' \
    "$OUTDIR/check_attr.json"
  echo "── 白名单分组 ──"
  jq -r '.SecurityIpGroups.SecurityIpGroup[] | [.SecurityIpGroupName, .SecurityIpGroupAttribute, .SecurityIpList] | @tsv' \
    "$OUTDIR/check_ips.json"
  echo "── 生效参数（仅列本卡相关的三项）──"
  jq -r '.RunningParameters.Parameter[]? | select(.ParameterName|test("maxmemory-policy|disabled-commands|evict-percent")) | [.ParameterName,(.ParameterValue|tostring)] | @tsv' \
    "$OUTDIR/check_params.json"
  echo "── 判据 ──"
  local st cap sec cls
  st=$(jq -r '.Instances.DBInstanceAttribute[0].InstanceStatus' "$OUTDIR/check_attr.json")
  cap=$(jq -r '.Instances.DBInstanceAttribute[0].Capacity' "$OUTDIR/check_attr.json")
  sec=$(jq -r '.Instances.DBInstanceAttribute[0].SecondaryZoneId // "-"' "$OUTDIR/check_attr.json")
  cls=$(jq -r '.Instances.DBInstanceAttribute[0].InstanceClass' "$OUTDIR/check_attr.json")
  [[ "$st" == "Normal" ]] && log "OK InstanceStatus=Normal" || log "WARN InstanceStatus=$st"
  log "容量 ${cap}MB（实购 2048 = 1G×2DB 集群档，与马尼拉 2048 同档；卡片原写 4096 已按 09-30 裁定改口径）"
  [[ "$sec" == "$SECONDARY_ZONE" ]] && log "OK 备可用区 = $sec（ZoneType 应为 doublezone）" || log "WARN 备可用区 = $sec（期望 $SECONDARY_ZONE）"
  log "规格码实况 = $cls（≠ 09-30 计划的企业版 amber 码 ⇒ 已按实况回改卡片）"
  jq -e --arg g "$WL_GROUP" \
    '.SecurityIpGroups.SecurityIpGroup[] | select(.SecurityIpGroupName==$g) | select(.SecurityIpList | test("10\\.1\\.16\\.0/20") and test("10\\.1\\.32\\.0/20") and test("10\\.1\\.80\\.0/20") and test("10\\.1\\.96\\.0/20"))' \
    "$OUTDIR/check_ips.json" >/dev/null && log "OK 白名单组 $WL_GROUP 四段齐" || log "WARN 白名单组 $WL_GROUP 未达期望（应为 4 个 app 段）"
  jq -e '.SecurityIpGroups.SecurityIpGroup[] | select(.SecurityIpGroupName=="default") | select(.SecurityIpList=="127.0.0.1")' \
    "$OUTDIR/check_ips.json" >/dev/null && log "OK default 组仍是 127.0.0.1（未被 Cover 波及）" || log "WARN default 组已变，需人工确认"
  jq -r '.RunningParameters.Parameter[]? | select(.ParameterName=="maxmemory-policy") | .ParameterValue' "$OUTDIR/check_params.json" \
    | grep -q allkeys-lru && log "OK maxmemory-policy=allkeys-lru 已生效" || log "WARN maxmemory-policy 未生效（下发可能有延迟，稍后复跑 check）"
  jq -r '.RunningParameters.Parameter[]? | select(.ParameterName=="#no_loose_disabled-commands") | .ParameterValue' "$OUTDIR/check_params.json" \
    | grep -qiE "flushall" && log "OK disabled-commands 含 flushall/flushdb/keys" || log "WARN disabled-commands 未生效"
}

case "${1:-}" in
  preflight) preflight ;;
  dryrun) preflight; die "DryRun 路径已停用（实例已在控制台买好）；如需重建走 create + ALLOW_CREATE=1" ;;
  create) create ;;
  wait) wait_normal ;;
  params) params ;;
  whitelist) whitelist ;;
  check) check ;;
  all) preflight; params; sleep 10; whitelist; sleep 10; check ;;
  *) die "用法: $0 preflight|wait|params|whitelist|check|all（create 需 ALLOW_CREATE=1）" ;;
esac
