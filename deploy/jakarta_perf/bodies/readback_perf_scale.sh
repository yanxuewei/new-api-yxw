#!/bin/bash
# =============================================================================
# ⚠ DEPRECATED（2026-10-20 起）—— 本文件内的对象名已失效
#   pre / perf 的负载已按 pod 名重建（fanyan 2026-10-20 裁定）：
#     new-api-pre         → pre-new-api-master      （无 Service，不接流量）
#     new-api-pre-slave   → pre-new-api-slave       （唯一 Service，Ingress 后端）
#     new-api-perf        → perf-new-api-master     （无 Service，不接流量）
#     new-api-perf-slave  → perf-new-api-slave      （唯一 Service，Ingress 后端）
#   ⇒ 凡出现旧名的 kubectl 操作：只读诊断会 NotFound；apply / patch / scale 类会
#     重新造出旧对象并与新对象抢标签 ⇒ **不要重跑本文件**。
#   权威 IaC：deploy/jakarta_pre/manifests/pre-master-slave.yaml
#              deploy/jakarta_perf/manifests/perf-master-slave.yaml
#   弃用说明与新旧对照：deploy/jakarta_pre/DEPRECATED.md
#   注意：命名空间 new-api-pre / new-api-perf 本身**未改名**，只读诊断仍可用。
# =============================================================================
# bodies/readback_perf_scale.sh —— 只读归因：new-api-perf 的副本数怎么从 2 变成 1 了
# 为什么要它：2026-10-19 我 apply 后的回读是 **2/2 Running**（两台不同 zone，见台账 §20.3）；
#   同一天的 L5 反证里 `new-api-perf 1 1`。副本数是压测容量的分母，也直接决定"能不能外推 C"，
#   所以这不是"要不要在意"的小事：必须查清是谁、什么时候、以什么身份改的（坑 9/坑 10 同一纪律：
#   先归因再用；只看 API 返回 Success 不算证据）。
# 顺带把 setup 门查了：L4 实测 users_total=0，而 model.createRootAccountIfNeed 在本仓**没有任何调用点**，
#   真正建管理员的是 `POST /api/setup`（controller/setup.go）⇒ 压测要先过初始化这一步，先确认它的状态。
set -uo pipefail
NS=new-api-perf

echo "=== R1 期望 vs 实际（spec.replicas / status）"
kubectl -n $NS get deploy new-api-perf -o jsonpath='    spec.replicas={.spec.replicas}  ready={.status.readyReplicas}  available={.status.availableReplicas}  updated={.status.updatedReplicas}  observed={.status.observedGeneration}  gen={.metadata.generation}{"\n"}' 2>&1
kubectl -n $NS get deploy new-api-perf -o jsonpath='    created={.metadata.creationTimestamp}{"\n"}' 2>&1
echo "    --- managedFields 逐条（manager / operation / time = 谁最后改的）"
kubectl -n $NS get deploy new-api-perf -o jsonpath='{range .metadata.managedFields[*]}      mgr={.manager} op={.operation} time={.time}{"\n"}{end}' 2>&1
echo "    --- annotations（有 kubectl 记录就是有人手工动过）"
kubectl -n $NS get deploy new-api-perf -o jsonpath='{range .metadata.annotations}"      "{.}{"\n"}{end}' 2>&1 | cut -c1-160

echo "=== R2 ReplicaSet 时间线（哪一次扩缩是真的发生过）"
kubectl -n $NS get rs -o custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas,CREATED:.metadata.creationTimestamp,LABEL:.metadata.labels.pod-template-hash --no-headers 2>&1 | grep -E 'new-api-perf|NAME' | sed 's/^/    /'
kubectl -n $NS get rs -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.metadata.annotations.deployment\.kubernetes\.rs/revision}{"  "}{.metadata.creationTimestamp}{"  "}{.metadata.managedFields[0].manager}{"\n"}{end}' 2>&1 | grep new-api-perf | sed 's/^/    /'

echo "=== R3 Pod 实况与落点"
kubectl -n $NS get pod -l app=new-api-perf -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,PHASE:.status.phase,RESTART:.status.containerStatuses[0].restartCount,STARTED:.status.startTime,CREATED:.metadata.creationTimestamp --no-headers 2>&1 | sed 's/^/    /'
echo "    --- 近 40 分钟 perf ns 事件（扩缩/驱逐/抢占都会在这里留痕）"
kubectl -n $NS get events --sort-by=.lastTimestamp 2>&1 | tail -18 | sed 's/^/    /'

echo "=== R4 有没有 HPA / PDB（有 HPA 的话副本数会被自动收，我的"2 副本"前提就不成立）"
kubectl -n $NS get hpa,pdb -o wide 2>&1 | sed 's/^/    /'

echo "=== R5 mock-upstream 的归因复测（上一版 S3 的 jsonpath 写错，annotations 没读到）"
kubectl -n $NS get deploy mock-upstream -o jsonpath='    created={.metadata.creationTimestamp} gen={.metadata.generation}{"\n"}' 2>&1
kubectl -n $NS get deploy mock-upstream -o jsonpath='{range .metadata.managedFields[*]}      mgr={.manager} op={.operation} time={.time}{"\n"}{end}' 2>&1
kubectl -n $NS get deploy mock-upstream -o jsonpath='{range .metadata.labels}"      label "{.}{"\n"}{end}' 2>&1

echo "=== R6 setup 门状态（只读 GET）"
POD=$(kubectl -n $NS get pod -l track=perf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
printf '    POD=%s\n' "${POD:-无}"
[ -n "$POD" ] && kubectl -n $NS exec "$POD" -- sh -c 'wget -qO- -T 8 http://127.0.0.1:3000/api/setup' 2>&1 | head -c 300 | sed 's/^/      /'
[ -n "$POD" ] && kubectl -n $NS exec "$POD" -- sh -c 'tail -40 /data/logs/one-api-$(date +%Y-%m-%d).log 2>/dev/null || ls /data/logs 2>&1' 2>&1 | tail -12 | sed -E 's/(password=|dsn=|token=)[^ ]*/\1***/g; s/^/      /'

echo "=== R7 共池当前 requests（副本数变化对预算的实际影响）"
kubectl get pods -A -o json 2>/dev/null | python3 -c '
import sys, json, collections
d=json.load(sys.stdin); agg=collections.defaultdict(float); tot=0.0
for p in d.get("items",[]):
    if p.get("status",{}).get("phase") not in ("Running","Pending"): continue
    n=p["spec"].get("nodeName") or "UNBOUND"
    for c in p["spec"].get("containers",[]):
        cu=(c.get("resources",{}).get("requests") or {}).get("cpu")
        if cu: v=float(cu[:-1])/1000 if cu.endswith("m") else float(cu); agg[n]+=v; tot+=v
for n in sorted(agg): print("      %-34s cpu_req=%.2f (allocatable 3.92 ⇒ 余 %.2f)" % (n, agg[n], 3.92-agg[n]))
print("      集群合计 cpu_req=%.2f / 7.84" % tot)
'
echo "--- R1–R7 结束（全程只读）"
exit 0
