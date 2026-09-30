#!/usr/bin/env bash
# ==============================================================================
# task22_sg_object_audit.sh — 任务 22 步骤 4｜安全组「对象面」反例自查（只读）
#
# 做什么：扫两个地域的**全部**安全组，找出「入向 0.0.0.0/0 且端口非 80/443」的规则
#         （含 ICMP 等非 TCP 协议），并对每条命中项判定处置：
#           · 命中组 == 某个 ACK 集群的 security_group_id → 【保留 + 挂例外记录】
#           · 否则                                       → 【待裁定：删除或收紧源 CIDR】
#
# 为什么需要"判定"而不是直接删（坑 7，2026-09-29 实测）：
#   ACK 自动建的 `alicloud-cs-auto-created-security-group-<集群ID>` 有一条
#   `ICMP -1/-1 ← 0.0.0.0/0`（NicType=intranet）。它会被反例自查命中，但
#   `DescribeSecurityGroupReferences` 对它返回**空数组**——因为托管控制面的 ENI
#   在 ACK 侧账号，本账号看不到引用。**空数组 ≠ 无人使用**：该组正是集群的
#   `security_group_id`，删了 ACK 会重建、且控制面→节点链路有中断风险。
#   另注：该组的 `TCP 6443 ← <VPC 段>` 必须存在，缺了节点 bootstrap 会卡 10 分钟
#   后永久 NotReady（见 wf2/part2a.md 坑 6 / 工单_ACK马尼拉控制面安全组缺失.md）。
#
# 用法：
#   bash deploy/task22_sg_object_audit.sh            # 只读扫描 + 判定（表格）
#   bash deploy/task22_sg_object_audit.sh --json     # 机器可读（供 §12 证据归档）
#
# 基线（2026-09-29 实测）：命中**仅 2 条**，且都是集群级 ICMP 例外 →
#   马尼拉 sg-5tsaatp5w68vyqszezja / 新加坡 sg-t4nevyfflaeo3tdvi510；
#   业务 5 组（sg-mnl-alb/app/db、sg-sg-alb/app）零命中；
#   `sg-mnl-alb` 的 80/443 因端口白名单被正确排除。
#
# 退出码：0 = 命中项全部为集群级例外（与基线一致）；1 = 出现需人工裁定的命中项
# ==============================================================================
set -uo pipefail

REGIONS=(ap-southeast-6 ap-southeast-1)
JSON=0
[ "${1:-}" = "--json" ] && JSON=1
HIT_FILE=$(mktemp)
trap 'rm -f "$HIT_FILE"' EXIT

# --- 判定依据：所有集群的 security_group_id（"集群级"的权威口径）---
CLUSTER_MAP=$(for R in "${REGIONS[@]}"; do
  aliyun cs DescribeClustersV1 --RegionId "$R" --region "$R" 2>/dev/null \
    | jq -r '.clusters[]?|select(.security_group_id!=null and .security_group_id!="")
             |[.security_group_id,.cluster_id]|@tsv'
done | sort -u)

if [ "$JSON" = "0" ]; then
  echo "集群级安全组（判【保留】的依据）："
  echo "$CLUSTER_MAP" | sed 's/^/  /'
  echo
fi

# 输出列：region  sg_id  sg_name  protocol  port  nic_type  description  verdict
scan_region() {
  local R="$1" id name rules sgid sgname proto port nic desc clu
  while IFS=$'\t' read -r id name; do
    [ -z "$id" ] && continue
    # 查询失败必须中断报错（坑 6：绝不把查询异常当作"不存在"）
    if ! rules=$(aliyun ecs DescribeSecurityGroupAttribute --RegionId "$R" --SecurityGroupId "$id" 2>&1); then
      echo "ERROR: 查询安全组 $id 失败，终止（不猜）" >&2; exit 2
    fi
    if ! echo "$rules" | jq -e '.Permissions' >/dev/null 2>&1; then
      echo "ERROR: $id 返回不可解析，终止（不猜）：$(echo "$rules" | head -c 200)" >&2; exit 2
    fi
    while IFS=$'\t' read -r sgid sgname proto port nic desc; do
      [ -z "$sgid" ] && continue
      clu=$(echo "$CLUSTER_MAP" | awk -F'\t' -v s="$sgid" '$1==s{print $2; exit}')
      if [ -n "$clu" ]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t保留(集群级 security_group_id, cluster=%s)\n' \
          "$R" "$sgid" "$sgname" "$proto" "$port" "$nic" "$desc" "$clu" >> "$HIT_FILE"
      else
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t待裁定(非集群级 → 删除或收紧源 CIDR)\n' \
          "$R" "$sgid" "$sgname" "$proto" "$port" "$nic" "$desc" >> "$HIT_FILE"
      fi
    done < <(echo "$rules" | jq -r --arg id "$id" --arg name "$name" '
        [.Permissions.Permission[]?
         | select(.Direction=="ingress" and .SourceCidrIp=="0.0.0.0/0")
         | select(.PortRange!="80/80" and .PortRange!="443/443")]
        | if length>0 then (.[]|[ $id,$name,.IpProtocol,.PortRange,.NicType,
              (if (.Description//"")|length>0 then .Description else "(无)" end)]|@tsv) else empty end')
  done < <(aliyun ecs DescribeSecurityGroups --RegionId "$R" --PageSize 100 2>/dev/null \
             | jq -r '.SecurityGroups.SecurityGroup[]|[.SecurityGroupId,.SecurityGroupName]|@tsv')
}

for R in "${REGIONS[@]}"; do scan_region "$R"; done

RESERVED=$(grep -c '保留(集群级' "$HIT_FILE" 2>/dev/null || true)
REVIEW=$(grep -c '待裁定' "$HIT_FILE" 2>/dev/null || true)
TOTAL=$((RESERVED + REVIEW))

if [ "$JSON" = "1" ]; then
  jq -Rn --argjson reserved "$RESERVED" --argjson review "$REVIEW" --rawfile hits "$HIT_FILE" \
    '{reserved_cluster_level:$reserved, need_review:$review,
      hits: ($hits | rtrimstr("\n") | if length==0 then [] else
             (split("\n") | map(split("\t") | {region:.[0],sg_id:.[1],sg_name:.[2],
               protocol:.[3],port:.[4],nic_type:.[5],description:.[6],verdict:.[7]})) end)}'
else
  echo "命中明细："
  if [ "$TOTAL" -eq 0 ]; then echo "  （无命中）"; else
    { echo -e "region\tsg_id\tprotocol\tport\tnic\tdescription\t判定";
      awk -F'\t' '{print $1"\t"$2"\t"$4"\t"$5"\t"$6"\t"$7"\t"$8}' "$HIT_FILE"; } \
    | column -t -s $'\t' 2>/dev/null || cat "$HIT_FILE"
  fi
  echo
  echo "命中总数：$TOTAL　集群级例外：$RESERVED　需人工裁定：$REVIEW"
  if [ "$REVIEW" -gt 0 ]; then
    echo "⚠️ 需裁定清单（按任务 22 步骤 3 处理，处理完重跑应回到 0）："
    awk -F'\t' '$8 ~ /待裁定/{print "  "$1"  "$2"  "$3}' "$HIT_FILE" | sort -u
  fi
fi

[ "$REVIEW" -gt 0 ] && exit 1
exit 0
