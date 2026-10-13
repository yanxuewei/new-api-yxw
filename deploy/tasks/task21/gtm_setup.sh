#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Day 2 · 任务 21｜GTM 3.0 实例 + 访问池 + 健康探测（先只挂马尼拉）
#
# 权威卡片：deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md（Day2 任务 21）
# 执行报告：deploy/docs/Day2任务21_GTM实例与访问池_执行报告_2026-10-13.md
#
# 与卡片的三处口径修订（2026-10-13 实测）：
#   ① GTM 3.0 是**按量付费、无需预购实例**（随接入域名自动生成）⇒ 卡片「购买开通仅
#      控制台可做」不成立，本脚本全 API 可做。
#   ② GTM 3.0 **直接接管业务域名**（www.likha.hk），**不需要**卡片步骤 3 的
#      `alidns AddDomainRecord ... CNAME → GTM 接入域名`（那是旧版实例型 GTM 模型）。
#   ③ 卡片「切换 TTL = 60s」在 GTM 3.0 下**可达**（实测 Ttl=60 权威直答 TTL=60）；
#      云解析的「免费版 TTL 下限 600s」只约束普通记录，不约束 GTM 应答。
#
# 用法（均需在 WSL 内执行）：
#   bash deploy/tasks/task21/gtm_setup.sh plan       # 只读：探测现有资源，不写
#   bash deploy/tasks/task21/gtm_setup.sh apply      # 幂等创建（按名字查找，缺才建）
#   bash deploy/tasks/task21/gtm_setup.sh verify     # 只读：全链复核
#   bash deploy/tasks/task21/gtm_setup.sh enable     # 启用接入域名（接管 www 解析）
#   bash deploy/tasks/task21/gtm_setup.sh disable    # 禁用（www 回落云解析 A 记录）
#   bash deploy/tasks/task21/gtm_setup.sh teardown   # 删除接入域名+池+地址+模板（停计费）
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RPC="python3 ${SELF_DIR}/../../lib/aliyun_rpc.py"
EP=(--endpoint alidns.aliyuncs.com --version 2015-01-09)

ZONE=likha.hk
HOSTNAME_=www
RRTYPE=CNAME
TTL=60
MTPL_NAME=mt-www-https-60s
POOL_NAME=pool-mnl
ADDR_NAME=alb-newapi-mnl
ALB_MNL=alb-1riqckb1h8ezm0y7s9.ap-southeast-6.alb.aliyuncsslbintl.com
MONITOR_NODES='[{"CityCode":"569","IspCode":"465"},{"CityCode":"375","IspCode":"465"},{"CityCode":"576","IspCode":"465"}]'
MONITOR_EXT='{"host":"www.likha.hk","path":"/api/status","code":500,"sni":true,"followRedirect":false}'

jq_get() { python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('$1','') or '')"; }

# ── 查找现有资源 ID（空 = 不存在） ────────────────────────────────────────────
find_config() {
  ${RPC} alidns ListCloudGtmInstanceConfigs "${EP[@]}" PageNumber=1 PageSize=100 2>/dev/null \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
for c in (d.get('InstanceConfigs') or {}).get('InstanceConfig') or []:
    if c.get('ScheduleDomainName') == '${HOSTNAME_}.${ZONE}':
        print(c.get('ConfigId',''), c.get('InstanceId','')); break
"
}
find_template() {
  ${RPC} alidns ListCloudGtmMonitorTemplates "${EP[@]}" PageNumber=1 PageSize=100 2>/dev/null \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
for t in (d.get('Templates') or {}).get('Template') or []:
    if t.get('Name') == '${MTPL_NAME}': print(t.get('TemplateId','')); break
"
}
find_pool() {
  ${RPC} alidns ListCloudGtmAddressPools "${EP[@]}" PageNumber=1 PageSize=100 2>/dev/null \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
for p in (d.get('AddressPools') or {}).get('AddressPool') or []:
    if p.get('AddressPoolName') == '${POOL_NAME}': print(p.get('AddressPoolId','')); break
"
}
find_address() {
  ${RPC} alidns ListCloudGtmAddresses "${EP[@]}" PageNumber=1 PageSize=100 2>/dev/null \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
for a in (d.get('Addresses') or {}).get('Address') or []:
    if a.get('Name') == '${ADDR_NAME}': print(a.get('AddressId','')); break
"
}

# ── plan ──────────────────────────────────────────────────────────────────────
do_plan() {
  echo "=== 任务21 GTM 3.0 现状探测（只读）==="
  read -r CFG INST <<<"$(find_config)"
  TPL=$(find_template); POOL=$(find_pool); ADDR=$(find_address)
  echo "  接入域名  ${HOSTNAME_}.${ZONE} (${RRTYPE}, TTL ${TTL})  ConfigId=${CFG:-<缺>} InstanceId=${INST:-<缺>}"
  echo "  探测模板  ${MTPL_NAME}  TemplateId=${TPL:-<缺>}"
  echo "  地址池    ${POOL_NAME}   AddressPoolId=${POOL:-<缺>}"
  echo "  地址      ${ADDR_NAME} → ${ALB_MNL}  AddressId=${ADDR:-<缺>}"
  if [ -n "${CFG}" ]; then
    ${RPC} alidns DescribeCloudGtmInstanceConfigFullInfo "${EP[@]}" \
      InstanceId="${INST}" ConfigId="${CFG}" 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('  启用状态  %s / 可用性 %s / 健康 %s' % (d.get('EnableStatus'), d.get('AvailableStatus'), d.get('HealthStatus')))
print('  池间策略  %s / %s' % (d.get('AddressPoolLbStrategy'), d.get('SequenceLbStrategyMode')))
p=(d.get('AddressPools') or {}).get('AddressPool') or []
for x in p:
    print('  已挂池    %s (SN=%s W=%s, %s)' % (x.get('AddressPoolName'), x.get('SerialNumber'), x.get('WeightValue'), x.get('EnableStatus')))
"
  fi
  echo "  计费摘要  $(${RPC} alidns DescribeCloudGtmSummary "${EP[@]}" 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('instances=%s monitorTasks=%s quota=%s' % (d.get('InstanceTotalCount'), d.get('MonitorTaskTotalCount'), d.get('MonitorTaskTotalQuota')))")"
}

# ── apply ─────────────────────────────────────────────────────────────────────
do_apply() {
  read -r CFG INST <<<"$(find_config)"
  if [ -z "${CFG}" ]; then
    echo "[+] 创建接入域名 ${HOSTNAME_}.${ZONE}（禁用态）"
    ${RPC} alidns CreateCloudGtmInstanceConfig "${EP[@]}" \
      ScheduleZoneMode=custom ScheduleZoneName="${ZONE}" ScheduleHostname="${HOSTNAME_}" \
      ScheduleRrType="${RRTYPE}" Ttl="${TTL}" ChargeType=postpay EnableStatus=disable \
      Remark="Day2 task21 GTM3.0 new-api PH access domain (mnl only)" \
      ClientToken=gtm-t21-cfg-v1
    read -r CFG INST <<<"$(find_config)"
  else
    echo "[=] 接入域名已存在 ConfigId=${CFG} InstanceId=${INST}"
  fi
  [ -n "${CFG}" ] || { echo "[ABORT] 接入域名创建失败"; return 1; }

  TPL=$(find_template)
  if [ -z "${TPL}" ]; then
    echo "[+] 创建探测模板 ${MTPL_NAME}"
    TPL=$(${RPC} alidns CreateCloudGtmMonitorTemplate "${EP[@]}" \
      Name="${MTPL_NAME}" IpVersion=IPv4 Protocol=https Interval=60 Timeout=5000 \
      EvaluationCount=3 FailureRate=100 ExtendInfo="${MONITOR_EXT}" \
      IspCityNodes="${MONITOR_NODES}" ClientToken=gtm-t21-mtpl-v1 2>/dev/null | jq_get TemplateId)
  else
    echo "[=] 探测模板已存在 TemplateId=${TPL}"
  fi
  [ -n "${TPL}" ] || { echo "[ABORT] 探测模板创建失败"; return 1; }

  POOL=$(find_pool)
  if [ -z "${POOL}" ]; then
    echo "[+] 创建地址池 ${POOL_NAME}（domain/enable/any_ok）"
    POOL=$(${RPC} alidns CreateCloudGtmAddressPool "${EP[@]}" \
      AddressPoolName="${POOL_NAME}" AddressPoolType=domain HealthJudgement=any_ok \
      EnableStatus=enable Remark="Day2 task21 pool-mnl: Manila ALB (sg not in pool until M4)" \
      ClientToken=gtm-t21-pool-v1 2>/dev/null | jq_get AddressPoolId)
  else
    echo "[=] 地址池已存在 AddressPoolId=${POOL}"
  fi
  [ -n "${POOL}" ] || { echo "[ABORT] 地址池创建失败"; return 1; }

  ADDR=$(find_address)
  if [ -z "${ADDR}" ]; then
    echo "[+] 创建地址 ${ADDR_NAME} → ${ALB_MNL}（探测 443/https）"
    ADDR=$(${RPC} alidns CreateCloudGtmAddress "${EP[@]}" \
      Name="${ADDR_NAME}" Type=domain Address="${ALB_MNL}" EnableStatus=enable \
      AvailableMode=auto HealthJudgement=any_ok \
      HealthTasks="[{\"Port\":443,\"TemplateId\":\"${TPL}\"}]" \
      Remark="Day2 task21: Manila ALB DNS, probe https/443 /api/status" \
      ClientToken=gtm-t21-addr-v1 2>/dev/null | jq_get AddressId)
    ${RPC} alidns ReplaceCloudGtmAddressPoolAddress "${EP[@]}" \
      AddressPoolId="${POOL}" \
      Addresses="[{\"AddressId\":\"${ADDR}\",\"WeightValue\":1,\"SerialNumber\":1}]" \
      ClientToken=gtm-t21-pooladdr-v1 >/dev/null && echo "    已关联进池"
  else
    echo "[=] 地址已存在 AddressId=${ADDR}"
  fi

  echo "[+] 接入域名关联池 + 池间策略 sequence/preemptive"
  ${RPC} alidns ReplaceCloudGtmInstanceConfigAddressPool "${EP[@]}" \
    InstanceId="${INST}" ConfigId="${CFG}" \
    AddressPools="[{\"AddressPoolId\":\"${POOL}\",\"WeightValue\":1,\"SerialNumber\":1}]" \
    ClientToken=gtm-t21-cfgpool-v1 >/dev/null
  ${RPC} alidns UpdateCloudGtmInstanceConfigLbStrategy "${EP[@]}" \
    InstanceId="${INST}" ConfigId="${CFG}" \
    AddressPoolLbStrategy=sequence SequenceLbStrategyMode=preemptive >/dev/null

  echo "[i] apply 完成（接入域名仍为 disable，需显式 enable）"
  printf '%s %s %s %s %s\n' "${CFG}" "${INST}" "${TPL}" "${POOL}" "${ADDR}" > /tmp/gtm_t21_ids
  echo "[i] ids -> /tmp/gtm_t21_ids: $(cat /tmp/gtm_t21_ids)"
}

# ── enable / disable ──────────────────────────────────────────────────────────
do_switch() {
  local st="$1"
  read -r CFG INST <<<"$(find_config)"
  [ -n "${CFG}" ] || { echo "[ABORT] 未找到接入域名"; return 1; }
  ${RPC} alidns UpdateCloudGtmInstanceConfigEnableStatus "${EP[@]}" \
    InstanceId="${INST}" ConfigId="${CFG}" EnableStatus="${st}"
  echo "[i] ${HOSTNAME_}.${ZONE} EnableStatus=${st}"
}

# ── verify ────────────────────────────────────────────────────────────────────
do_verify() {
  echo "=== 权威直答（ns7/ns8）==="
  for n in ns7.alidns.com ns8.alidns.com; do
    echo "  @${n}: $(dig +short @"${n}" "${HOSTNAME_}.${ZONE}" CNAME | tr '\n' ' ')$(dig +short @"${n}" "${HOSTNAME_}.${ZONE}" A | tr '\n' ' ')"
  done
  echo "=== 公共递归 ==="
  echo "  223.5.5.5: $(dig +short @223.5.5.5 ${HOSTNAME_}.${ZONE} | tr '\n' ' ')"
  echo "  8.8.8.8  : $(dig +short @8.8.8.8 ${HOSTNAME_}.${ZONE} | tr '\n' ' ')"
  echo "=== 应用层 ==="
  echo -n "  https /api/status: "
  curl -s -o /tmp/gtm_body -w 'http=%{http_code} ip=%{remote_ip} ttfb=%{time_starttransfer}s\n' --max-time 12 "https://${HOSTNAME_}.${ZONE}/api/status"
  echo "  body: $(head -c 120 /tmp/gtm_body)"
  echo "=== GTM 侧状态 ==="
  do_plan
}

case "${1:-}" in
  plan)     do_plan ;;
  apply)    do_apply ;;
  enable)   do_switch enable ;;
  disable)  do_switch disable ;;
  verify)   do_verify ;;
  teardown)
    read -r CFG INST TPL POOL ADDR <<<"$(cat /tmp/gtm_t21_ids 2>/dev/null || true)"
    [ -n "${CFG:-}" ] || read -r CFG INST _ <<<"$(find_config)"
    echo "[!] 删除接入域名（会同时删除其按量付费实例）ConfigId=${CFG}"
    [ -n "${CFG:-}" ] && ${RPC} alidns DeleteCloudGtmInstanceConfig "${EP[@]}" \
      InstanceId="${INST}" ConfigId="${CFG}" ClientToken=gtm-t21-del-cfg-v1
    for a in $(find_address); do
      ${RPC} alidns DeleteCloudGtmAddress "${EP[@]}" AddressId="$a" ClientToken="gtm-t21-del-addr-$a"
    done
    for p in $(find_pool); do
      ${RPC} alidns DeleteCloudGtmAddressPool "${EP[@]}" AddressPoolId="$p" ClientToken="gtm-t21-del-pool-$p"
    done
    for t in $(find_template); do
      ${RPC} alidns DeleteCloudGtmMonitorTemplate "${EP[@]}" TemplateId="$t" ClientToken="gtm-t21-del-tpl-$t"
    done
    echo "[i] teardown 完成（www 回落云解析 A 记录）"
    ;;
  *) sed -n '2,30p' "$0" ;;
esac
