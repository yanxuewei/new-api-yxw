#!/usr/bin/env bash
# =============================================================================
# 任务 46 · 运维入口工具（解决「办公/VPN 出口为动态 IP」问题）
#
# 背景（2026-09-29 决策）：办公出口为**动态 IP**，VPN 每次变更 → 固定 IP 白名单不可维护。
# 方案：入口从「IP 白名单」改为「身份认证 + 零入向端口」，两条通道：
#   ① 主通道：ECS 会话管理（Session Manager，基于云助手）
#      零入向端口、RAM 身份（+MFA）鉴权、VPC 内直达跳板机、**会话录制投递 OSS**
#      → 顺带补齐了方案 B 相对云堡垒机缺失的「会话录制」能力
#   ② 辅通道：按需动态放行 SSH（当需要原生 ssh/scp/端口转发时）
#      取本机当前出口 IP → 加 /32 规则（带过期时间标记）→ 用完自动/手动撤销
#
# 用法：
#   bash deploy/ops-access.sh --status                # 现状复核（SG 入向 / 会话管理 / 录制投递 / 活跃会话）
#   bash deploy/ops-access.sh --session               # 创建一次性会话（打印 WebSocketUrl + 控制台路径）
#   bash deploy/ops-access.sh --allow-ssh             # 动态放行本机出口 IP 的 22（默认 120 分钟）
#   bash deploy/ops-access.sh --allow-ssh --ttl-min 30
#   bash deploy/ops-access.sh --deny-ssh              # 撤销全部 22 入向（回到零入向）
#   bash deploy/ops-access.sh --gc                    # 撤销所有已过期的临时规则
#
# 幂等：重复执行安全；每次运行都会顺带 GC 过期规则。
# =============================================================================
set -uo pipefail

REGION=ap-southeast-6
EDGE_SG=sg-5tsaatp5w68w2st9r1pn          # sg-mnl-alb-edge
JUMP_INSTANCE_ID=i-5tsil3ca5dfkus9zpj7u  # newapi-ops-mnl
OSS_BUCKET=oss-newapi-mnl
OSS_PREFIX=ops-sessions/
TTL_MIN=120

ACTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)      ACTION=status ;;
    --session)     ACTION=session ;;
    --allow-ssh)   ACTION=allow ;;
    --deny-ssh)    ACTION=deny ;;
    --gc)          ACTION=gc ;;
    --ttl-min)     shift; TTL_MIN="${1:-120}" ;;
    *) echo "未知参数：$1（见脚本头用法）" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$ACTION" ]] || { echo "请指定动作：--status | --session | --allow-ssh | --deny-ssh | --gc" >&2; exit 2; }

say() { printf '%s\n' "$*"; }
NOW=$(date +%s)

# 取本机当前公网出口 IP（多源兜底）
my_ip() {
  local ip
  for u in https://ifconfig.me https://api.ipify.org https://ipinfo.io/ip; do
    ip=$(curl -s -m 6 "$u" 2>/dev/null | tr -d '\r\n ')
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { printf '%s' "$ip"; return 0; }
  done
  return 1
}

ingress_json() {
  aliyun ecs DescribeSecurityGroupAttribute --RegionId "$REGION" --SecurityGroupId "$EDGE_SG" --Direction ingress 2>/dev/null
}

# GC：撤销描述带 temp-ssh-exp=<epoch> 且已过期的规则
gc_rules() {
  local j; j=$(ingress_json) || return 0
  local n=0
  while IFS=$'\t' read -r port src desc; do
    [[ -z "${desc:-}" ]] && continue
    local exp; exp=$(printf '%s' "$desc" | sed -n 's/.*temp-ssh-exp=\([0-9]\{1,\}\).*/\1/p')
    [[ -z "$exp" ]] && continue
    if (( exp < NOW )); then
      # 注意：PortRange 已是 "22/22" 形态，切勿再拼一次（否则 22/22/22/22 → 撤销静默失败）
      if aliyun ecs RevokeSecurityGroup --RegionId "$REGION" --SecurityGroupId "$EDGE_SG" \
           --IpProtocol tcp --PortRange "$port" --SourceCidrIp "$src" >/dev/null 2>&1; then
        say "  [GC] 已撤销过期规则 TCP $port ← $src"; n=$((n+1))
      else
        say "  [GC] !! 撤销失败 TCP $port ← $src（检查权限/参数）"
      fi
    fi
  done < <(printf '%s' "$j" | jq -r '.Permissions.Permission[]?|select(.Direction=="ingress")|[.PortRange,.SourceCidrIp,(.Description//"")]|@tsv' 2>/dev/null)
  (( n == 0 )) && say "  [GC] 无过期规则"
}

case "$ACTION" in
  status)
    say "=== 1. 安全组入向（sg-mnl-alb-edge=$EDGE_SG，期望零入向）==="
    j=$(ingress_json)
    cnt=$(printf '%s' "$j" | jq -r '[.Permissions.Permission[]?|select(.Direction=="ingress")]|length' 2>/dev/null)
    if [[ "${cnt:-0}" == "0" ]]; then say "  零入向端口 ✅（入口完全由身份认证承担）"; else
      printf '%s' "$j" | jq -r '.Permissions.Permission[]?|select(.Direction=="ingress")|"  TCP \(.PortRange) ← \(.SourceCidrIp)  [\(.Description//"-")]"'
    fi

    say "=== 2. 会话管理开关（期望 true；该设置跨地域生效）==="
    for r in "$REGION" ap-southeast-1; do
      printf "  %s: " "$r"
      aliyun ecs DescribeCloudAssistantSettings --RegionId "$r" --SettingType.1 SessionManagerConfig 2>/dev/null \
        | jq -c '.SessionManagerConfig' 2>/dev/null || echo "查询失败"
    done

    say "=== 3. 会话录制投递（期望 OSS $OSS_BUCKET/$OSS_PREFIX）==="
    aliyun ecs DescribeCloudAssistantSettings --RegionId "$REGION" --SettingType.1 SessionManagerDelivery 2>/dev/null \
      | jq -c '.OssDeliveryConfigs.OssDeliveryConfig[0]' 2>/dev/null || echo "  查询失败"

    say "=== 4. 活跃会话 ==="
    aliyun ecs DescribeTerminalSessions --RegionId "$REGION" --InstanceId "$JUMP_INSTANCE_ID" 2>/dev/null \
      | jq -r '.Sessions.Session[]?|"  \(.SessionId)  \(.InstanceState)  \(.CreationTime)"' 2>/dev/null \
      || say "  （无 / 查询失败）"
    ;;

  session)
    say "方式 A（人工，推荐）：控制台 → 云服务器 ECS → 实例 $JUMP_INSTANCE_ID → 远程连接 → 会话管理"
    say "        登录后执行：newapi-kube && kubectl get pods -n new-api"
    say "        会话内容按配置录制投递到 oss://$OSS_BUCKET/$OSS_PREFIX"
    say ""
    say "方式 B（程序化，返回 WebSocket 地址）："
    OUT=$(aliyun ecs StartTerminalSession --RegionId "$REGION" --InstanceId.1 "$JUMP_INSTANCE_ID" 2>&1)
    printf '%s\n' "$OUT" | jq -c '{SessionId, WebSocketUrl}' 2>/dev/null || printf '%s\n' "$OUT"
    SID=$(printf '%s' "$OUT" | jq -r '.SessionId // empty' 2>/dev/null)
    [[ -n "$SID" ]] && say "  用毕请结束：aliyun ecs EndTerminalSession --RegionId $REGION --SessionId $SID"
    ;;

  allow)
    IP=$(my_ip) || { say "!! 取不到本机出口 IP，放弃（请检查网络或改用手工 --SourceCidrIp）"; exit 1; }
    EXP=$(( NOW + TTL_MIN*60 ))
    say "本机出口 IP = $IP（动态）→ 放行 TCP 22，有效期 ${TTL_MIN} 分钟（到期 $EXP）"
    case "$IP" in 0.0.0.0) say "!! 拒绝 0.0.0.0，终止"; exit 1;; esac
    gc_rules
    # 幂等：同源同端口先撤销再加（避免重复规则）
    aliyun ecs RevokeSecurityGroup --RegionId "$REGION" --SecurityGroupId "$EDGE_SG" \
      --IpProtocol tcp --PortRange 22/22 --SourceCidrIp "$IP/32" >/dev/null 2>&1 || true
    if aliyun ecs AuthorizeSecurityGroup --RegionId "$REGION" --SecurityGroupId "$EDGE_SG" \
         --IpProtocol tcp --PortRange 22/22 --SourceCidrIp "$IP/32" \
         --Policy accept --Priority 1 \
         --Description "temp-ssh-exp=$EXP user=$(id -un) ttl=${TTL_MIN}m" >/dev/null 2>&1; then
      say "  ✅ 已放行。连接：ssh -i <newapi-mnl.pem> root@8.212.176.207"
      say "  撤销：bash deploy/ops-access.sh --deny-ssh   （或到期后 bash deploy/ops-access.sh --gc）"
    else
      say "  !! 放行失败（检查 RAM 是否有 ecs:AuthorizeSecurityGroup 与目标 SG 权限）"; exit 1
    fi
    ;;

  deny)
    j=$(ingress_json)
    n=0
    while IFS=$'\t' read -r port src; do
      [[ "$port" != "22/22" && "$port" != "22" ]] && continue
      aliyun ecs RevokeSecurityGroup --RegionId "$REGION" --SecurityGroupId "$EDGE_SG" \
        --IpProtocol tcp --PortRange "22/22" --SourceCidrIp "$src" >/dev/null 2>&1 \
        && { say "  已撤销 TCP 22 ← $src"; n=$((n+1)); }
    done < <(printf '%s' "$j" | jq -r '.Permissions.Permission[]?|select(.Direction=="ingress")|[.PortRange,.SourceCidrIp]|@tsv' 2>/dev/null)
    (( n == 0 )) && say "  无 22 入向规则（已是零入向）"
    cnt=$(ingress_json | jq -r '[.Permissions.Permission[]?|select(.Direction=="ingress")]|length' 2>/dev/null)
    say "  当前入向规则数=${cnt:-?}（期望 0）"
    ;;

  gc) gc_rules ;;
esac
