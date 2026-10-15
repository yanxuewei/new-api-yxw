#!/bin/bash
# bodies/create_ns.sh —— 建 pre / perf 命名空间底座（Namespace + ResourceQuota + ServiceAccount）
#   ONLY=new-api-pre|new-api-perf   可选，只建其中一个；不给就两个都建
# 幂等：全部走 kubectl apply -f -（已存在则按标签/配额收敛，不删除任何对象）
set -uo pipefail
ALLOW="new-api-pre new-api-perf"
APP_SA=new-api-app
DEV_NS=newapi-dev

echo "=== P0 白名单门禁（不在名单里一个字都不写）"
T="${ONLY:-}"
NSSLIST="$ALLOW"
if [ -n "$T" ]; then
  case " $ALLOW " in *" $T "*) NSSLIST="$T" ;; *) echo "  [XX] 目标 '$T' 不在白名单：$ALLOW"; exit 2 ;; esac
fi
printf '  本次作用命名空间：%s\n' "$NSSLIST"
printf '  刻意不碰：%s（现网 dev 底座）与任何马尼拉/新加坡集群\n' "$DEV_NS"
# 配额总账（卡片步骤 1 的硬约束）：节点池 np-jkt-dev-app = 3 节点 × 2C；pre 与 dev 共用它
q_for() {
  case "$1" in
    new-api-pre)  echo "1 2 2Gi 4Gi 6" ;;    # requests.cpu limits.cpu requests.memory limits.memory pods
    new-api-perf) echo "4 8 8Gi 16Gi 12" ;;  # perf 落独立节点池（2×g9i.xlarge=8C），故配额按自己的池算
  esac
}

echo "=== P1 逐 ns 建底座"
for n in $NSSLIST; do
  read -r rq lq rm lm pd <<<"$(q_for "$n")"
  printf '  --- %s（quota: requests.cpu=%s limits.cpu=%s requests.memory=%s limits.memory=%s pods=%s）\n' "$n" "$rq" "$lq" "$rm" "$lm" "$pd"
  kubectl apply -f - <<MANIFEST
apiVersion: v1
kind: Namespace
metadata:
  name: $n
  labels:
    site: jkt-dev
    track: dev
    env: dev
    project: new-api
    isolation: structural-cluster
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: $n-quota
  namespace: $n
spec:
  hard:
    requests.cpu: "$rq"
    limits.cpu: "$lq"
    requests.memory: $rm
    limits.memory: $lm
    pods: "$pd"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $APP_SA
  namespace: $n
  labels:
    site: jkt-dev
    track: dev
    env: dev
    project: new-api
MANIFEST
  printf '  apply_rc=%s\n' "$?"
done

echo "=== P2 回读（生效判据只认这里）"
kubectl get ns -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,site:.metadata.labels.site,track:.metadata.labels.track,env:.metadata.labels.env,project:.metadata.labels.project' 2>&1 \
  | awk 'NR==1 || /pre|perf|dev/ {print "    " $0}'
for n in $NSSLIST; do
  printf '    %-14s quota=%s\n' "$n" "$(kubectl -n $n get resourcequota -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.hard}{"\n"}{end}' 2>&1 | tr -d '\n')"
  printf '    %-14s SA=%s\n' "$n" "$(kubectl -n $n get sa -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>&1)"
  printf '    %-14s SA 的 imagePullSecrets=「%s」 ⇒ 此刻应为空，扩了免密 watchNamespace 后才有值（坑 16）\n' "$n" "$(kubectl -n $n get sa $APP_SA -o jsonpath='{.imagePullSecrets[*].name}' 2>&1)"
done

echo "=== P3 反证：dev 底座未被扰动（只读取现状态，前后对照用）"
kubectl -n $DEV_NS get deploy -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas,SA:.spec.template.spec.serviceAccountName' --no-headers 2>&1 | sed 's/^/    /'
kubectl -n $DEV_NS get pod -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.pod-template-hash}{"|"}{range .status.containerStatuses[*]}{.restartCount}{end}{"\n"}{end}' 2>/dev/null | sort | sed 's/^/    基线指纹 /'
echo "--- P1–P3 结束（写入面只有 $NSSLIST 里的 Namespace/ResourceQuota/ServiceAccount）"
