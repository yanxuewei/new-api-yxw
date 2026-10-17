#!/usr/bin/env bash
# 第四轮：csi-plugin / terway 主容器 500m -> 200m
# 注意：两者都是 DaemonSet，会逐节点重建
#   - csi-plugin 重建期间该节点存储挂载/卸载短暂受影响
#   - terway 重建期间该节点新建 Pod 拿不到 IP（已有 Pod 网络不受影响）
set -uo pipefail

echo "########## 改前 ##########"
kubectl -n kube-system get ds csi-plugin -o jsonpath='  csi-plugin   limits={.spec.template.spec.containers[?(@.name=="csi-plugin")].resources.limits.cpu} requests={.spec.template.spec.containers[?(@.name=="csi-plugin")].resources.requests.cpu}{"\n"}' 2>&1
kubectl -n kube-system get ds terway-eniip -o jsonpath='  terway       limits={.spec.template.spec.containers[?(@.name=="terway")].resources.limits.cpu} requests={.spec.template.spec.containers[?(@.name=="terway")].resources.requests.cpu}{"\n"}' 2>&1

echo
echo "########## 执行 ##########"
kubectl -n kube-system set resources ds/csi-plugin -c csi-plugin --limits=cpu=200m 2>&1 | grep -v '^Warning'
kubectl -n kube-system set resources ds/terway-eniip -c terway --limits=cpu=200m 2>&1 | grep -v '^Warning'

echo
echo "########## 等 180s（DaemonSet 逐节点滚动）##########"
sleep 180
kubectl -n kube-system get ds csi-plugin terway-eniip 2>&1
echo
echo "--- DaemonSet Pod 状态 ---"
kubectl -n kube-system get pods 2>&1 | grep -E 'csi-plugin|terway' 
echo
echo "--- 全集群非 Running ---"
kubectl get pods -A 2>&1 | grep -vE 'Running|Completed|NAME' | head -6
echo "(空=正常)"

echo
echo "########## 终值 ##########"
kubectl get pods -A -o json > /tmp/p.json
python3 - <<'PY'
import json, collections
d = json.load(open('/tmp/p.json'))
def cpu(v):
    if not v: return 0
    v = str(v)
    return int(v[:-1]) if v.endswith('m') else float(v) * 1000
per = collections.defaultdict(float)
rows = []
for p in d.get('items', []):
    if p.get('status', {}).get('phase') in ('Succeeded', 'Failed'): continue
    n = p['spec'].get('nodeName')
    lc = 0
    for c in p['spec'].get('containers', []):
        lc += cpu(((c.get('resources') or {}).get('limits') or {}).get('cpu'))
    per[n] += lc
    if lc >= 600: rows.append((lc, p['metadata']['namespace'], p['metadata']['name']))
print('--- 每节点 limits.cpu ---')
for n in sorted(per):
    print('  %-30s limits=%6.0fm (%3.0f%%)' % (n, per[n], per[n] / 3920 * 100))
print('\n--- 剩余 >=600m 的 Pod ---')
for r in sorted(rows, reverse=True): print('  %6.0fm  %-14s %s' % r)
print('  (空=无)' if not rows else '')
PY

echo
echo "########## 网络连通性验证 ##########"
kubectl -n kube-system run netcheck-$RANDOM --rm -i --restart=Never --image=busybox:1.36 --timeout=90s -- \
  sh -c 'nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 && echo DNS_OK || echo DNS_FAIL' 2>&1 | tail -3
