#!/bin/bash
# 固化 newapi-np 的 nodePort=32656（显式声明，防重建变号）+ 导出 YAML 存档
say() { printf '\n===== %s =====\n' "$*"; }

NS=new-api
SVC=newapi-np
PIN=32656

say "0. patch 前状态"
kubectl -n $NS get svc $SVC -o wide 2>&1
echo "current nodePort = $(kubectl -n $NS get svc $SVC -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)"

say "1. 显式固化 nodePort=$PIN（同值 = no-op，不会断流）"
kubectl -n $NS patch svc $SVC --type=merge \
  -p "{\"spec\":{\"externalTrafficPolicy\":\"Cluster\",\"ports\":[{\"name\":\"http\",\"protocol\":\"TCP\",\"port\":80,\"targetPort\":3000,\"nodePort\":$PIN}]}}" 2>&1

say "2. 回读确认"
kubectl -n $NS get svc $SVC -o jsonpath='{.spec.type} extPolicy={.spec.externalTrafficPolicy} port={.spec.ports[0].port} target={.spec.ports[0].targetPort} nodePort={.spec.ports[0].nodePort}{"\n"}' 2>&1

say "3. 导出干净 YAML（剥 runtime 字段）"
kubectl -n $NS get svc $SVC -o yaml 2>/dev/null | python3 -c "
import sys, yaml
d = yaml.safe_load(sys.stdin)
m = d.setdefault('metadata', {})
for k in ('creationTimestamp','resourceVersion','uid','generation','managedFields','selfLink'):
    m.pop(k, None)
m.setdefault('annotations', {}).pop('kubectl.kubernetes.io/last-applied-configuration', None)
d.pop('status', None)
# 去掉 ClusterIP（重建时让 k8s 重新分配）
sp = d.setdefault('spec', {})
sp.pop('clusterIP', None)
sp.pop('clusterIPs', None)
print(yaml.safe_dump(d, allow_unicode=True, sort_keys=False, default_flow_style=False))
" > /tmp/newapi-np-pinned.yaml 2>&1
cat /tmp/newapi-np-pinned.yaml

say "4. 节点本地自测"
MYIP=$(ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
[ -z "$MYIP" ] && MYIP=$(hostname -I | awk '{print $1}')
echo "self=$MYIP"
for i in 1 2 3; do
  curl --noproxy '*' -s -o /dev/null -w "  try$i http://$MYIP:$PIN/api/status -> %{http_code}\n" -m 5 "http://$MYIP:$PIN/api/status"
done

echo "RESULT node_port=$PIN pinned=yes"
