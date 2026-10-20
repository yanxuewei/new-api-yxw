#!/bin/bash
# bodies/readback_perf_state.sh —— perf 落地后的**只读**状态回读（含我未创建的对象归因）
# 为什么要它：冒烟 V3③ 的对象清单里出现了 `deployment.apps/mock-upstream`（6 副本 + ClusterIP），
#   不是我建的、也不是任何 body 建的 ⇒ 共池/压测口径都得先认清它的来源和形状，不能当噪声略过。
set -uo pipefail
NS=new-api-perf

echo "=== S1 perf 负载与服务（READY 必须等于期望，Service 是 ClusterIP 即不外露）"
kubectl -n $NS get deploy,svc -o wide 2>&1 | sed 's/^/    /'

echo "=== S2 Pod 落点（两台不同节点 = 换池后 zone 打散仍成立）"
kubectl -n $NS get pod -o custom-columns='POD:.metadata.name,DEPLOY:.metadata.ownerReferences[0].name,PHASE:.status.phase,NODE:.spec.nodeName,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,RESTART:.status.containerStatuses[0].restartCount,AGE:.metadata.creationTimestamp' --no-headers 2>&1 | sed 's/^/    /'

echo "=== S3 谁建的 mock-upstream（managedFields 的 manager + 首次写入时间 = 归因证据，不改任何东西）"
kubectl -n $NS get deploy mock-upstream -o jsonpath='    managers={.metadata.managedFields[*].manager}{"\n    times="}{.metadata.managedFields[*].time}{"\n    created="}{.metadata.creationTimestamp}{"\n    uid_prefix="}{.metadata.uid}{"\n"}' 2>&1
kubectl -n $NS get deploy mock-upstream -o jsonpath='    labels={.metadata.labels}{"\n    annotations={.metadata.annotations}{"\n"}' 2>&1
echo "    --- 容器形状（镜像/端口/资源；镜像里没有凭据，可原样打印）"
kubectl -n $NS get deploy mock-upstream -o jsonpath='{range .spec.template.spec.containers[*]}    img={.image}{"  port="}{.ports[0].containerPort}{"  req="}{.resources.requests}{"  lim="}{.resources.limits}{"\n"}{end}' 2>&1
echo "    --- 它的 env（只打印键名，值一律不外显）"
kubectl -n $NS get deploy mock-upstream -o go-template='{{range .spec.template.spec.containers}}{{range .env}}      key={{.name}}{{"\n"}}{{end}}{{end}}' 2>&1

echo "=== S4 perf 侧连通性：应用 Pod 能不能打到 mock-upstream（压测上游链路的先决条件）"
POD=$(kubectl -n $NS get pod -l track=perf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$POD" ] || { echo "    [XX] 没有 track=perf 的 Pod"; exit 1; }
printf '    POD=%s\n' "$POD"
kubectl -n $NS exec "$POD" -- sh -c 'wget -qO- -T 5 http://127.0.0.1:3000/api/status' 2>&1 | head -c 120 | sed 's/^/      status: /'
printf '\n    判定 /api/status success=true ：'
kubectl -n $NS exec "$POD" -- sh -c 'wget -qO- -T 5 http://127.0.0.1:3000/api/status' 2>&1 | grep -q '"success":true' && echo PASS || echo FAIL
printf '    mock-upstream 域名解析与应答：'
kubectl -n $NS exec "$POD" -- sh -c 'wget -qO- -T 5 http://mock-upstream.'"$NS"'.svc.cluster.local/ 2>&1 | head -c 80' 2>&1 | sed 's/^/      /'

echo "=== S5 共池 requests 总账（perf 上线后邻居还剩多少）"
kubectl get pods -A -o json 2>/dev/null | python3 -c '
import sys, json, collections
d=json.load(sys.stdin); agg=collections.defaultdict(float); tot=0.0
for p in d.get("items",[]):
    if p.get("status",{}).get("phase") not in ("Running","Pending"): continue
    n=p["spec"].get("nodeName") or "UNBOUND"
    for c in p["spec"].get("containers",[]):
        cu=(c.get("resources",{}).get("requests") or {}).get("cpu")
        if cu: v=float(cu[:-1])/1000 if cu.endswith("m") else float(cu); agg[n]+=v; tot+=v
for n in sorted(agg): print("      %-30s cpu_req=%.2f (allocatable 3.92 ⇒ 余 %.2f)" % (n, agg[n], 3.92-agg[n]))
print("      集群合计 cpu_req=%.2f / 7.84" % tot)
'
echo "=== S6 反证：本卡只读；perf 之外没有对象被改动（dev 指纹应与冒烟里一致）"
kubectl -n newapi-dev get pod -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.pod-template-hash}{"|"}{range .status.containerStatuses[*]}{.restartCount}{end}{"\n"}{end}' 2>&1 | sort | sed 's/^/    /'
echo "--- S1–S6 结束"
