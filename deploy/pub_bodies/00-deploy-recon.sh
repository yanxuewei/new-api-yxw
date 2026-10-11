#!/usr/bin/env bash
# 取 new-api-stable 部署形态（供控制台发布说明使用）
set -uo pipefail
NS=new-api

echo "########## 1. deploy 概览 ##########"
kubectl -n "$NS" get deploy -o wide 2>&1

echo
echo "########## 2. new-api-stable image / 容器 ##########"
kubectl -n "$NS" get deploy new-api-stable -o json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('generation      =', d['metadata'].get('generation'))
print('observedGen     =', d.get('status', {}).get('observedGeneration'))
print('strategy        =', json.dumps(d['spec'].get('strategy'), ensure_ascii=False))
for c in d['spec']['template']['spec']['containers']:
    print('container %-14s image=%s' % (c.get('name'), c.get('image')))
    print('   imagePullPolicy =', c.get('imagePullPolicy'))
print('annotations(k,s) =')
for k in ('deployment.kubernetes.io/revision','kubectl.kubernetes.io/last-applied-configuration'):
    if k in (d['metadata'].get('annotations') or {}):
        print('   ', k)
print('podTemplate labels =', (d['spec']['template']['metadata'].get('labels') or {}))
"

echo
echo "########## 3. 容器命令/副本 ##########"
kubectl -n "$NS" get deploy new-api-stable -o jsonpath='{.spec.replicas}{"\n"}' 2>&1
kubectl -n "$NS" get deploy new-api-stable -o yaml 2>&1 | sed -n '/containers:/,/^ *[a-z]*:/p' | head -60

echo
echo "########## 4. rollout history ##########"
kubectl -n "$NS" rollout history deploy/new-api-stable 2>&1 | head -20

echo
echo "########## 5. ReplicaSet（各版本）##########"
kubectl -n "$NS" get rs -l app=new-api-stable -o custom-columns='NAME:.metadata.name,REV:.metadata.annotations.deployment\.kubernetes\.io/revision,DESIRED:.spec.replicas,READY:.status.readyReplicas,IMAGE:.spec.template.spec.containers[0].image,AGE:.metadata.creationTimestamp' 2>&1

echo
echo "########## 6. Pod 归属 ##########"
kubectl -n "$NS" get pods -l app=new-api-stable -o custom-columns='POD:.metadata.name,RS:.metadata.ownerReferences[0].name,NODE:.spec.nodeName,IP:.status.podIP,STATUS:.status.phase,START:.status.startTime' 2>&1

echo
echo "########## 7. ACR 镜像拉取 Secret ##########"
kubectl -n "$NS" get secret 2>&1 | grep -i -E 'acr|registry|docker' || echo "(无匹配 secret 名)"
kubectl -n "$NS" get deploy new-api-stable -o jsonpath='{.spec.template.spec.imagePullSecrets}{"\n"}' 2>&1

echo
echo "########## 8. 工作负载形态（是否有 HPA/PDB/其他控制器）##########"
kubectl -n "$NS" get hpa,pdb,sts,ds 2>&1 | head -20
