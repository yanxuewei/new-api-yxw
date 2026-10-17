#!/usr/bin/env bash
# 步骤1：下线非必需 addon（先查 webhook failurePolicy=Fail 则中止）
set -uo pipefail

echo "########## A. 目标 deploy 确切名 ##########"
kubectl -n kube-system get deploy 2>&1 | grep -E 'gatekeeper|koord-manager|cost-exporter'

echo
echo "########## B. 相关 ValidatingWebhook ##########"
BADV=$(kubectl get validatingwebhookconfiguration -o json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin); bad = 0; found = False
for w in d.get('items', []):
    n = w['metadata']['name']
    if any(k in n for k in ('gatekeeper', 'koord', 'cost')):
        found = True
        for wh in w.get('webhooks', []):
            fp = wh.get('failurePolicy', 'Ignore')
            res = []
            for r in (wh.get('rules') or []): res += (r.get('resources') or [])
            print('  VWC %-50s fp=%-6s res=%s' % (n, fp, sorted(set(res))))
            if fp == 'Fail': bad += 1
if not found: print('  (none)')
print(bad)
")
NFAIL=$(printf '%s' "$BADV" | tail -1)
printf '%s\n' "$BADV" | head -n -1

if [ "${NFAIL:-0}" != "0" ]; then
  echo
  echo "!! 存在 failurePolicy=Fail 的 webhook，scale 到 0 会锁死集群写入 —— 中止。"
  exit 9
fi

echo
echo "########## C. scale 到 0 ##########"
for d in gatekeeper ack-koord-manager ack-cost-exporter; do
  if kubectl -n kube-system get deploy "$d" >/dev/null 2>&1; then
    echo "--- $d ---"
    kubectl -n kube-system scale deploy "$d" --replicas=0 2>&1
  else
    echo "--- $d 不存在，跳过 ---"
  fi
done

echo
echo "########## D. 等 40s 回读 ##########"
sleep 40
kubectl -n kube-system get deploy 2>&1 | grep -E 'NAME|gatekeeper|koord-manager|cost-exporter'
echo "--- 各节点 Pod 数 ---"
kubectl get pods -A -o json 2>/dev/null | python3 -c "
import sys, json, collections
d = json.load(sys.stdin); c = collections.Counter()
for p in d.get('items', []):
    if p.get('status', {}).get('phase') in ('Succeeded','Failed'): continue
    c[p['spec'].get('nodeName')] += 1
for n, v in sorted(c.items()): print('  %-32s %d' % (n, v))
"
