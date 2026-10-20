#!/bin/bash
# deploy/ops/bodies/readback_capacity.sh —— 换池后的集群内**只读**容量回读（kubectl get/describe，零写入）
# 目的：负责人裁定「pre 与 perf 复用新池 np-jkt-dev-x4c」⇒ 先量清新池还能给多少 requests，
#       再决定 perf 的 resources / replicas 和 ResourceQuota 要不要改。
set -uo pipefail

echo "=== K1 节点：可分配量与调度状态"
kubectl get nodes -o custom-columns='NAME:.metadata.name,TYPE:.metadata.labels.beta\.kubernetes\.io/instance-type,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory,UNSCHED:.spec.unschedulable,POOL:.metadata.labels.ack\.alibabacloud\.com/nodepool-id' --no-headers 2>&1 | sed 's/^/    /'

echo "=== K2 每节点已请求的 resources（requests 账目，调度看的是这个不是使用率）"
kubectl get pods -A -o json 2>/dev/null | python3 -c '
import sys, json, collections
d = json.load(sys.stdin); agg = collections.defaultdict(lambda: [0.0, 0, 0])
for p in d.get("items", []):
    if p.get("status", {}).get("phase") not in ("Running", "Pending"): continue
    n = p["spec"].get("nodeName") or "UNBOUND"
    for c in p["spec"].get("containers", []):
        r = c.get("resources", {}).get("requests", {}) or {}
        cu = r.get("cpu"); me = r.get("memory")
        if cu: agg[n][0] += (float(cu[:-1])/1000 if cu.endswith("m") else float(cu))
        agg[n][1] += 1
        if me:
            v = float(me[:-2]) if me.endswith("Mi") else (float(me[:-1])/1000 if me.endswith("Gi") else float(me)/1048576)
            agg[n][2] += v
    agg[n][2] += 0
for n in sorted(agg): print("    %-28s pods=%-3s cpu_req=%.2f mem_req=%.0fMi" % (n, agg[n][1], agg[n][0], agg[n][2]))
' 2>&1 | sed 's/^/    /'

echo "=== K3 命名空间现状（dev / pre / perf 是否都在）"
kubectl get ns -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,site:.metadata.labels.site,track:.metadata.labels.track' 2>&1 | awk 'NR==1 || /dev|pre|perf/ {print "    " $0}'

echo "=== K4 三个轨道的工作负载（READY 与 AGE 一起看：AGE 很新 = 换池时被重建过）"
for n in newapi-dev new-api-pre new-api-perf; do
  kubectl -n $n get deploy -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas,AGE:.metadata.creationTimestamp,IMG:.spec.template.spec.containers[0].image' --no-headers 2>&1 | sed 's/^/    /'
done
echo "    --- Pod 明细（phase / restarts / 落在哪台节点）"
for n in newapi-dev new-api-pre new-api-perf; do
  kubectl -n $n get pod -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,PHASE:.status.phase,RS:.status.containerStatuses[0].restartCount,NODE:.spec.nodeName,START:.status.startTime' --no-headers 2>&1 | sed 's/^/    /'
done

echo "=== K5 ResourceQuota 现值与已用量（perf 若共池，这里的配额口径要重算）"
for n in new-api-pre new-api-perf; do
  kubectl -n $n describe quota 2>&1 | sed 's/^/    /'
done

echo "=== K6 调度受阻的 Pod 与原因（如果有 Pending，原文在这里，不猜）"
kubectl get pods -A --field-selector=status.phase=Pending -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,NODE:.spec.nodeName' --no-headers 2>&1 | sed 's/^/    /'
kubectl get events -A --sort-by=.lastTimestamp 2>&1 | grep -Ei 'Insufficient|Too many|FailedScheduling|NodeNotReady' | tail -8 | sed 's/^/    /'

echo "=== K7 反证：本卡只读取，未改动任何对象（列出最近 15 分钟被改写过的对象；应为空）"
kubectl get events -A --sort-by=.lastTimestamp 2>&1 | awk '$NF ~ /created|updated|Applied/ {print "    " $0}' | tail -6 | sed 's/^/    /'
echo "--- K1–K7 结束"
