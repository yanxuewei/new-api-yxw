#!/usr/bin/env bash
# 收敛 limits.cpu 超卖：把系统组件 limits 压到实际用量的 5~10 倍
set -uo pipefail

echo "########## 改前每节点 limits 合计 ##########"
sum_limits() {
  kubectl get pods -A -o json > /tmp/p.json 2>/dev/null
  python3 - <<'PY'
import json, collections
d = json.load(open('/tmp/p.json'))
def cpu(v):
    if not v: return 0
    v = str(v)
    return int(v[:-1]) if v.endswith('m') else float(v) * 1000
per = collections.defaultdict(float)
for p in d.get('items', []):
    if p.get('status', {}).get('phase') in ('Succeeded', 'Failed'): continue
    n = p['spec'].get('nodeName')
    for c in p['spec'].get('containers', []):
        per[n] += cpu(((c.get('resources') or {}).get('limits') or {}).get('cpu'))
for n in sorted(per):
    print('  %-30s limits=%6.0fm (%3.0f%%)' % (n, per[n], per[n] / 3920 * 100))
PY
}
sum_limits

echo
echo "########## 执行 ##########"
apply() {
  kind=$1; ns=$2; name=$3; cname=$4; target=$5
  if ! kubectl -n "$ns" get "$kind" "$name" >/dev/null 2>&1; then
    echo "  [skip] $kind/$name 不存在"; return
  fi
  c="${cname:-$(kubectl -n "$ns" get "$kind" "$name" -o jsonpath='{.spec.template.spec.containers[0].name}')}"
  req=$(kubectl -n "$ns" get "$kind" "$name" -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$c\")].resources.requests.cpu}" 2>/dev/null)
  [ -z "$req" ] && req=0
  reqm=$(printf '%s' "$req" | sed 's/m$//')
  case "$req" in *m) ;; *) reqm=$(( ${req:-0} * 1000 ));; esac
  t="$target"; [ "${reqm:-0}" -gt "$target" ] && t="${reqm}m"
  echo "  $kind/$ns/$name [$c] limits.cpu -> $t"
  kubectl -n "$ns" set resources "$kind/$name" -c "$c" --limits=cpu="$t" 2>&1 | grep -v '^Warning'
}

# Deployment（单容器，容器名留空自动取第一个）
apply deploy kube-system csi-provisioner csi-provisioner 1000m
apply deploy kube-system metrics-server metrics-server 500m
apply deploy arms-prom  arms-prometheus-ack-arms-prometheus "" 1000m
apply deploy kube-system loongcollector-operator "" 500m
apply deploy kube-system storage-operator "" 200m
apply deploy kube-system alicloud-monitor-controller "" 200m
apply deploy arms-prom  o11y-addon-controller "" 200m
apply deploy arms-prom  kube-state-metrics "" 200m
apply deploy kube-system gatekeeper manager 300m

# DaemonSet（必须指定主容器，否则会误改 sidecar）
apply ds kube-system loongcollector-ds "" 500m
apply ds kube-system csi-plugin csi-plugin 500m
apply ds kube-system terway-eniip terway 500m
apply ds kube-system ack-node-problem-detector-daemonset ack-node-problem-detector 200m
apply ds arms-prom  node-exporter node-exporter 200m

echo
echo "########## 等 120s 收敛 ##########"
sleep 120
kubectl get pods -A 2>&1 | grep -vE 'Running|Completed|NAME' | head -8
echo "(空=全部正常)"
echo
echo "########## 改后每节点 limits 合计 ##########"
sum_limits
