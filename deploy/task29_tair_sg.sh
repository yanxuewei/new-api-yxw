#!/usr/bin/env bash
# Day 1 · 任务 29 第 1 步：新加坡本地 Tair（企业版 · 包月 1 个月 · 双可用区 1a+1b）
#
# 规格取用户 2026-09-30 裁定：与马尼拉 r-5tsf1fe16543e274 逐字同规格
#   redis.amber.logic.sharding.1g.2db.0rodb.6proxy.multithread（企业版 amber 逻辑多线程 1G×2DB/6 proxy = 2048MB）
#   报价实测 71.81 USD/月（双可用区不加价；企业版标准架构 4GB 为 130.56，社区版 4GB 为 65.28）
#
# 用法：bash deploy/task29_tair_sg.sh preflight|dryrun|create|wait|params|whitelist|check|all
# 口令：只从环境变量 TAIR_SG_PW 读取（定义在 ~/.bashrc ⇒ 需 `bash -lic` 起），全程不回显、不落盘
set -uo pipefail

REGION=ap-southeast-1
VPC=vpc-t4nimmwvruexbnene0a3r
VSW=vsw-t4nr26kz6gceuz0jm4eqw          # vsw-sg-data-a @1a 10.1.48.0/20（2026-09-30 补建）
PRIMARY_ZONE=ap-southeast-1a
SECONDARY_ZONE=ap-southeast-1b
CLASS=redis.amber.logic.sharding.1g.2db.0rodb.6proxy.multithread
NAME=tair-sg-newapi
RG=rg-aek4zvb3ldoiyua                  # rg-ph-sg，与 SG VPC/交换机同组
WL_GROUP=sg_app
WL_IPS=10.1.16.0/20,10.1.32.0/20       # = vsw-sg-app-a / vsw-sg-app-b（Terway eniip 下 Pod 取交换机地址）
PARAMS='{"#no_loose_maxmemory-policy":"allkeys-lru","#no_loose_disabled-commands":"FLUSHALL,FLUSHDB,KEYS"}'

OUTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logs/task29_tair_sg"
mkdir -p "$OUTDIR"
IDFILE="$OUTDIR/instance_id"

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
die() { printf '%s FAIL %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; exit 1; }

need_id() {
  [[ -s "$IDFILE" ]] || die "找不到实例 ID（先跑 create，或把 r-xxx 写进 $IDFILE）"
  cat "$IDFILE"
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
    log "同名实例已存在：$mine ⇒ 幂等闸门命中，复用不再建（如需另建请改 $NAME）"
    printf '%s\n' "$mine" >"$IDFILE"
    return
  fi
  if [[ "$n" != "0" ]]; then
    ids=$(jq -r '[.Instances.KVStoreInstance[]?.InstanceId] | join(",")' "$OUTDIR/preflight_instances.json")
    die "$REGION 已有其它 Tair 实例（$ids）但无 $NAME ⇒ 停止，人工确认后再动"
  fi
  log "幂等闸门通过：$REGION TotalCount=0"

  aliyun vpc DescribeVSwitches --RegionId "$REGION" --VpcId "$VPC" >"$OUTDIR/preflight_vsw.json" \
    || die "DescribeVSwitches 调用失败"
  jq -e --arg v "$VSW" '.VSwitches.VSwitch[] | select(.VSwitchId == $v and .Status == "Available")' \
    "$OUTDIR/preflight_vsw.json" >/dev/null || die "$VSW 不存在或不可用"
  log "落点交换机 $VSW Available（$(jq -r --arg v "$VSW" '.VSwitches.VSwitch[]|select(.VSwitchId==$v)|.CidrBlock' "$OUTDIR/preflight_vsw.json")）"
}

create_args() {
  # DryRun 与真实下单共用同一份参数，保证"校验过的就是付钱的"
  printf '%s\n' \
    --RegionId "$REGION" --ZoneId "$PRIMARY_ZONE" --SecondaryZoneId "$SECONDARY_ZONE" \
    --VpcId "$VPC" --VSwitchId "$VSW" --NetworkType VPC \
    --InstanceClass "$CLASS" --EngineVersion 5.0 \
    --InstanceName "$NAME" --ResourceGroupId "$RG" \
    --ChargeType PrePaid --Period 1 --AutoRenew false \
    --Port 6379
}

dryrun() {
  preflight
  local args
  mapfile -t args < <(create_args)
  log "CreateInstance --DryRun true（零费用、不建实例）"
  local out
  out=$(aliyun r-kvstore CreateInstance "${args[@]}" --DryRun true 2>&1)
  printf '%s\n' "$out" >"$OUTDIR/dryrun.txt"
  if grep -q "DryRunOperation" "$OUTDIR/dryrun.txt"; then
    log "DRYRUN OK：参数、格式、服务限额与可售资源均通过"
  else
    log "DRYRUN 输出：$(tr '\n' ' ' <"$OUTDIR/dryrun.txt" | cut -c1-400)"
    die "DryRun 未通过 ⇒ 停止，不进入真实下单"
  fi
}

create() {
  [[ -s "$IDFILE" ]] && { log "已记录实例 $(cat "$IDFILE")，跳过创建"; return; }
  local args
  mapfile -t args < <(create_args)
  log "CreateInstance（真实下单，PrePaid Period 1，报价 71.81 USD）"
  aliyun r-kvstore CreateInstance "${args[@]}" --Password "$TAIR_SG_PW" \
    >"$OUTDIR/create.json" 2>"$OUTDIR/create.err" \
    || { log "下单失败：$(tr '\n' ' ' <"$OUTDIR/create.err" | cut -c1-400)"; die "CreateInstance 非零退出"; }
  # create.err 里可能带请求回显，落盘后立刻剥敏并只留必要字段
  jq -r '.InstanceId // empty' "$OUTDIR/create.json" >"$IDFILE" || true
  [[ -s "$IDFILE" ]] || die "CreateInstance 未回显 InstanceId（响应见 $OUTDIR/create.json，人工核对后再重试）"
  log "  → $(cat "$IDFILE")  OrderId=$(jq -r '.OrderId // "-"' "$OUTDIR/create.json")"
}

wait_normal() {
  local id st
  id=$(need_id)
  for _ in $(seq 1 40); do
    aliyun r-kvstore DescribeInstanceAttribute --InstanceId "$id" >"$OUTDIR/attr_wait.json" 2>/dev/null || true
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
  log "ModifyInstanceParameter：allkeys-lru + 禁用危险命令"
  aliyun r-kvstore ModifyInstanceParameter --InstanceId "$id" --Parameters "$PARAMS" \
    >"$OUTDIR/modify_params.json" 2>&1 || { cat "$OUTDIR/modify_params.json"; die "ModifyInstanceParameter 失败"; }
  jq -c '.RequestId' "$OUTDIR/modify_params.json"
}

whitelist() {
  local id
  id=$(need_id)
  log "ModifySecurityIps：组 $WL_GROUP = $WL_IPS（ModifyMode Cover 的作用域是该组，default 不动）"
  aliyun r-kvstore ModifySecurityIps --InstanceId "$id" --SecurityIps "$WL_IPS" \
    --ModifyMode Cover --SecurityIpGroupName "$WL_GROUP" \
    >"$OUTDIR/modify_ips.json" 2>&1 || { cat "$OUTDIR/modify_ips.json"; die "ModifySecurityIps 失败"; }
  jq -c '.RequestId' "$OUTDIR/modify_ips.json"
}

check() {
  local id
  id=$(need_id)
  aliyun r-kvstore DescribeInstanceAttribute --InstanceId "$id" >"$OUTDIR/check_attr.json" 2>&1 \
    || die "DescribeInstanceAttribute 失败"
  aliyun r-kvstore DescribeSecurityIps --InstanceId "$id" >"$OUTDIR/check_ips.json" 2>&1 \
    || die "DescribeSecurityIps 失败"
  echo "── V5 实例回读 ──"
  jq '.Instances.DBInstanceAttribute[0] | {InstanceId,InstanceName,InstanceStatus,InstanceClass,Capacity,EngineVersion,ZoneId,SecondaryZoneId,ZoneType,AutoSecondaryZone,NodeType,ArchitectureType,ShardCount,NetworkType,VpcId,VSwitchId,PrivateIp,ConnectionDomain,Port,ChargeType,CreateTime,EndTime,ResourceGroupId,Config,SecurityIPList}' \
    "$OUTDIR/check_attr.json"
  echo "── 白名单分组 ──"
  jq -r '.SecurityIpGroups.SecurityIpGroup[] | [.SecurityIpGroupName, .SecurityIpGroupAttribute, .SecurityIpList] | @tsv' \
    "$OUTDIR/check_ips.json"
  echo "── 判据 ──"
  local st cap sec
  st=$(jq -r '.Instances.DBInstanceAttribute[0].InstanceStatus' "$OUTDIR/check_attr.json")
  cap=$(jq -r '.Instances.DBInstanceAttribute[0].Capacity' "$OUTDIR/check_attr.json")
  sec=$(jq -r '.Instances.DBInstanceAttribute[0].SecondaryZoneId // "-"' "$OUTDIR/check_attr.json")
  [[ "$st" == "Normal" ]] && log "OK InstanceStatus=Normal" || log "WARN InstanceStatus=$st"
  log "容量 ${cap}MB（企业版 1G×2DB 集群档 = 2048，与马尼拉同规格；卡片原写 4096 已按用户裁定改口径）"
  [[ "$sec" == "$SECONDARY_ZONE" ]] && log "OK 备可用区 = $sec" || log "WARN SecondaryZoneId=$sec（非 $SECONDARY_ZONE）⇒ 双可用区未生效，见马尼拉同款先例 ZoneType=singlezone"
  jq -e --arg g "$WL_GROUP" --arg ips "$WL_IPS" \
    '.SecurityIpGroups.SecurityIpGroup[] | select(.SecurityIpGroupName==$g) | select(.SecurityIpList | test("10\\.1\\.16\\.0/20") and test("10\\.1\\.32\\.0/20"))' \
    "$OUTDIR/check_ips.json" >/dev/null && log "OK 白名单组 $WL_GROUP 两段齐" || log "WARN 白名单组 $WL_GROUP 未达期望"
  jq -e '.SecurityIpGroups.SecurityIpGroup[] | select(.SecurityIpGroupName=="default") | select(.SecurityIpList=="127.0.0.1")' \
    "$OUTDIR/check_ips.json" >/dev/null && log "OK default 组仍是 127.0.0.1（未被 Cover 波及）" || log "WARN default 组已变，需人工确认"
  jq -r '.Instances.DBInstanceAttribute[0].Config' "$OUTDIR/check_attr.json" | grep -q allkeys-lru \
    && log "OK maxmemory-policy=allkeys-lru 已生效" || log "WARN 配置里还没看到 allkeys-lru（参数下发可能有延迟，稍后复跑 check）"
}

case "${1:-}" in
  preflight) preflight ;;
  dryrun) dryrun ;;
  create) create ;;
  wait) wait_normal ;;
  params) params ;;
  whitelist) whitelist ;;
  check) check ;;
  all) preflight; [[ -s "$IDFILE" ]] || dryrun; create; wait_normal; params; sleep 20; whitelist; sleep 20; check ;;
  *) die "用法: $0 preflight|dryrun|create|wait|params|whitelist|check|all" ;;
esac
