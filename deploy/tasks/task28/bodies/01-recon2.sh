#!/bin/bash
# 任务 28 · 侦察缺口复测（SG，全部只读：只有 get，零写操作）
# 修正 00-recon.sh 两处缺陷：
#   ① `st` 不是合法资源类型 → 整条 get 报错、ns 清单缺失；改为逐类取，单类失败不中断
#   ② 打印键名时把 base64 值一起输出了（泄密）→ 改为只打印 dict 的 key，值不落任何输出
set -u
export KUBECONFIG="${K8S:-/tmp/k8s/kubeconfig}"
NS=new-api

echo "== A) ns $NS 对象清单（逐类）=="
for kind in deploy sts ds rs svc cm sa pdb hpa job pod ingress; do
  echo "-- $kind --"
  kubectl -n "$NS" get "$kind" --no-headers 2>&1 | awk '{printf "    %s %s %s\n", $1, $2, $3}' | head -15
done

echo "== B) Secret 仅名称/类型/键名（值绝不输出）=="
kubectl -n "$NS" get secret -o json 2>/dev/null > /tmp/t28_sec.json
python3 - <<'PY'
import json
d = json.load(open('/tmp/t28_sec.json'))
for it in d.get('items', []):
    name = it['metadata']['name']
    typ = it.get('type')
    keys = sorted((it.get('data') or {}).keys())
    print('   %s  type=%s  keys=%s' % (name, typ, keys if typ == 'Opaque' else '(值不打印)'))
PY
rm -f /tmp/t28_sec.json

echo "== C) ConfigMap 键值（非敏感）=="
kubectl -n "$NS" get configmap -o json 2>/dev/null > /tmp/t28_cm.json
python3 - <<'PY'
import json
d = json.load(open('/tmp/t28_cm.json'))
for it in d.get('items', []):
    print('-- cm/%s --' % it['metadata']['name'])
    for k, v in sorted((it.get('data') or {}).items()):
        print('   %s = %s' % (k, v))
PY
rm -f /tmp/t28_cm.json

echo "== D) 现有 Pod 的容器镜像（备站应同 SHA，任务 16 坑 1）=="
kubectl -n "$NS" get pod -o jsonpath='{range .items[*]}{.metadata.name}{" img="}{.spec.containers[*].image}{"\n"}{end}' 2>&1 | head -5
echo "   (ns 无业务 Pod 属预期：SG 首个工作负载就是本卡)"

echo "== E) SG 侧 ALB / AlbConfig 现状（任务 25 前置，本卡不建）=="
kubectl get albconfig -A 2>&1 | head -5
kubectl get ingressclass 2>&1 | head -5

echo "== F) 节点池台数硬约束复核：2 节点各 AZ 的 requests 余量 =="
kubectl describe nodes 2>/dev/null | awk '/^Name:/{n=$2} /cpu *:[0-9]+m? \/{c=$0} /^Non-terminated/{p=1} /Requests :/{r=1} r&&/cpu/{print n, "requests_cpu="$2; r=0}' | head -6
kubectl get nodes -o custom-columns='NAME:.metadata.name,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory' 2>&1
echo "### DONE-28-RECON2"
