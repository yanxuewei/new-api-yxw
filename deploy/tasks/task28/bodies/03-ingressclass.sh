#!/bin/bash
# 任务 28 · 插曲取证：SG 集群出现一个 48 s 龄的 IngressClass/alb（parameters→AlbConfig/sg-alb），
# 但 ns 内无 Ingress、集群内无 AlbConfig、云侧 ap-southeast-1 ALB 实例数 = 0。
# 目的：判定它是"谁、何时、因何"建的 —— 若是并发会话在做任务 25，本卡 apply 需错峰；
#       若是 ALB 控制器自建的默认类，则属任务 25 的既定起点。全部只读。
set -u
export KUBECONFIG="${K8S:-/tmp/k8s/kubeconfig}"
NS=new-api

echo "== 1) IngressClass 全文（ownerRefs / annotations / controller / 时间戳）=="
kubectl get ingressclass alb -o json > /tmp/t28_ic.json 2>/dev/null
python3 - <<'PY'
import json
d = json.load(open('/tmp/t28_ic.json'))
m = d['metadata']
print('   name              =', m['name'])
print('   creationTimestamp =', m.get('creationTimestamp'))
print('   resourceVersion   =', m.get('resourceVersion'))
print('   ownerReferences   =', m.get('ownerReferences'))
print('   labels            =', m.get('labels'))
print('   annotations       =', json.dumps(m.get('annotations') or {}, ensure_ascii=False)[:600])
print('   spec              =', json.dumps(d.get('spec') or {}, ensure_ascii=False))
PY
rm -f /tmp/t28_ic.json

echo "== 2) AlbConfig CRD 是否存在 / 是否有实例（含其它 ns 与集群作用域）=="
kubectl get crd 2>/dev/null | grep -iE "alb|ingress" | head -5
kubectl get albconfig -A -o wide 2>&1 | head -5

echo "== 3) ALB 控制器身份与年龄（托管面：lease + EndpointSlice，不用 get pods 判存活）=="
for L in alb alb-gateway; do
  kubectl -n kube-system get lease "$L" -o jsonpath="lease/$L holder={.spec.holderIdentity} renew={.spec.renewTime}{'\n'}" 2>&1
done
date -u '+   node-utc-now  = %Y-%m-%dT%H:%M:%SZ'
kubectl -n kube-system get endpointslice -l 'kubernetes.io/service-name' --no-headers 2>&1 | grep -i alb | head -4

echo "== 4) 最近 30 分钟集群事件里与 alb/class 相关的行 =="
kubectl get events -A --sort-by=.lastTimestamp 2>&1 | grep -iE "alb|ingressclass" | tail -15

echo "== 5) 马尼拉集群同期对照（本文件在 mnl 集群跑时才有意义；此处仅记录 sg 侧不可比）=="
echo "   (skip)"
echo "### DONE-28-IC"
