#!/bin/bash
# deploy/jakarta_pre/jkt_nodes.sh —— 雅加达 dev 站的**只读**容量回读（零写入、零费用）
#
# 为什么要它：2026-10-19 负责人裁定「原节点池已更换更强机型，pre 与 perf 都复用这张新池」。
# 换池会把 ECS 实例一起换掉 ⇒ 通道脚本里的默认 NODE_ARG（旧实例 id）大概率已失效，
# 而且"能不能给两个环境放行"从此取决于**新池的真实 requests 账目**，不是旧池的实测值。
# 本脚本只回答三件事：池清单 / 节点实例 id（通道入参用）/ 每节点可分配与已请求。
set -uo pipefail
REGION=ap-southeast-5
CID=cb0abf5bc06034f7bbdb991752f6f3e62

echo "=== N1 节点池清单（名称 / 机型 / 期望节点数 / 状态）"
aliyun cs DescribeClusterNodePools --ClusterId "$CID" --region "$REGION" 2>&1 \
  | jq -r '(.node_pools // .nodepools // [])[]
           | "    " + .nodepool_info.nodepool_id + "  " + .nodepool_info.name
             + "  state=" + (.status.state // "?")
             + "  types=" + ((.scaling_group.instance_types // []) | join(","))
             + "  desired=" + ((.scaling_group.desired_size // -1) | tostring)
             + "  nodes=" + ((.status.total_nodes // 0) | tostring)
             + "  charge=" + (.scaling_group.instance_charge_type // "?")'

echo "=== N2 集群节点（实例 id + 状态 + 池标签）⇒ 通道 NODE_ARG 从这里取"
aliyun cs DescribeClusterNodes --ClusterId "$CID" --region "$REGION" 2>&1 \
  | jq -r '(.nodes // [])[]
           | "    " + (.instance_id // "?") + "  " + (.ip_address // [] | join("/"))
             + "  state=" + (.state // "?")
             + "  pool=" + (.nodepool_id // "?")
             + "  name=" + (.node_name // "?")'

echo "=== N3 每个池的扩容配置（auto_scaling 是否开、taint/label 现值）"
aliyun cs DescribeClusterNodePools --ClusterId "$CID" --region "$REGION" 2>&1 \
  | jq -r '(.node_pools // .nodepools // [])[]
           | "    " + .nodepool_info.name
             + "  autoscale.enable=" + ((.auto_scaling.enable // false) | tostring)
             + "  min/max=" + ((.auto_scaling.min_nodes // "-" | tostring)) + "/" + ((.auto_scaling.max_nodes // "-" | tostring))
             + "  labels=" + ((.kubernetes_config.labels // []) | map(.key + "=" + .value) | join(","))
             + "  taints=" + ((.kubernetes_config.taints // []) | map(.key + "=" + (.value // "") + ":" + .effect) | join(","))'

echo "=== N4 RDS 侧连接账目前提（池模式必须是 session，否则 6432 语义变化）"
aliyun rds DescribeDBInstanceAttribute --DBInstanceId pgm-d9j9p421lzx4gw73 --region "$REGION" 2>&1 \
  | jq -r '.Items.DBInstanceAttribute[0]
           | "    instance=" + .DBInstanceId + "  class=" + .DBInstanceClass
             + "  cpu=" + (.ExtraInstanceAttribute.DBInstanceClassType // "?" | tostring)
             + "  connections_max=" + ((.MaxConnections // 0) | tostring)
             + "  expire=" + (.EndTime // "?")' 2>&1 | head -4

echo "--- N1–N4 全部只读（Describe* 系列），未创建/未修改任何云端资源"
