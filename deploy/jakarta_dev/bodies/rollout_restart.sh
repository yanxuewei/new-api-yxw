#!/bin/bash
# bodies/rollout_restart.sh —— 显式 rollout restart TARGET 负载（Secret/CM 变更后生效用）
# 闸门：TARGET 必须显式传入（刻意无默认值）；APPLY=1 才真做，默认只出计划。
# 零凭据 body：不需要任何 SEC/DOCS 载荷。
NS=newapi-dev
T="${TARGET:-}"
APPLY="${APPLY:-0}"
echo "=== R0 目标闸门"
[ -n "$T" ] || { echo "  [XX] 未传 TARGET"; exit 2; }
kubectl -n $NS get deploy "$T" -o jsonpath='  before: replicas={.status.replicas} ready={.status.readyReplicas}  image={.spec.template.spec.containers[0].image}{"\n"}' 2>&1 \
  || { echo "  [XX] 取不到 deploy/$T"; exit 2; }
if [ "$APPLY" != "1" ]; then
  echo "=== APPLY=0 ⇒ 只出计划，不执行（APPLY=1 才真做）"
  exit 0
fi
echo "=== R1 rollout restart"
kubectl -n $NS rollout restart deploy/"$T" 2>&1 | sed 's/^/    /'
echo "=== R2 等滚动完成（240s < 云助手 900s，错峰上限）"
kubectl -n $NS rollout status deploy/"$T" --timeout=240s 2>&1 | sed 's/^/    /'
RC=$?
printf '  rollout_rc=%s\n' "$RC"
echo "=== R3 回读"
kubectl -n $NS get deploy "$T" -o jsonpath='  after: ready={.status.readyReplicas}/{.status.replicas}  updated={.status.updatedReplicas}{"\n"}' 2>&1
kubectl -n $NS get pod -l pod-template-hash -o jsonpath='{range .items[*]}{.metadata.name}{"  phase="}{.status.phase}{"  ready="}{.status.containerStatuses[0].ready}{"  restarts="}{.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>&1 | sed 's/^/    /'
echo "--- R0–R3 结束（写入面只有 deploy/$T 的 pod-template 注解）"
exit $RC
