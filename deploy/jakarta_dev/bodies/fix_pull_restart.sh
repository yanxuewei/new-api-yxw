#!/bin/bash
# bodies/fix_pull_restart.sh —— 免密"时序坑"修复：只重建 Pod，不改任何 spec
#
# 适用症状（2026-10-14 实证，new-api-dev-slave）：
#   Pod 报 `insufficient_scope: authorization failed`，但同 ns、同镜像的另一个 Pod 正常；
#   且目标 SA（含 default）**现在**已经有 `imagePullSecrets: acr-credential-secret-aggregation`。
# 根因：Pod 的 `spec.imagePullSecrets` 由 ServiceAccount 准入控制器在**创建那一刻**固化，之后**不可变**。
#   helper 把凭据挂到 SA 上晚于本 Pod 的创建时间 ⇒ 这个 Pod 永远读不到凭据，重建即通。
# 与 fix_pull_sa.sh 的分工：
#   - SA 上有凭据（时序坑） ⇒ 用本脚本（只重建）
#   - SA 上没有凭据（helper 配置没圈到它） ⇒ 用 fix_pull_sa.sh 把 SA 换成 new-api-app
#
# 参数（经 dev_deploy.sh --fix-pull-restart <deploy> 传入）：
#   TARGET=<deployment 名>  必填，刻意无默认值
#   APPLY=0|1               默认 0＝只出计划；1 才真做 rollout restart
NS=newapi-dev
T="${TARGET:-}"
APPLY="${APPLY:-0}"

echo "=== G0 闸门"
if [ -z "$T" ]; then echo "  [XX] 未传 TARGET ⇒ 终止（刻意不设默认值）"; exit 2; fi
if [ "$T" = "new-api-dev" ]; then echo "  [XX] TARGET 不能是 new-api-dev（既有基线负载，且已健康）"; exit 2; fi
kubectl -n $NS get deploy "$T" -o jsonpath='  deploy={.metadata.name}  replicas={.spec.replicas}  template.sa=[{.spec.template.spec.serviceAccountName}]{"\n"}' 2>&1 \
  || { echo "  [XX] 取不到 deploy/$T ⇒ 终止"; exit 2; }

# 解析"该负载实际用的 SA"：模板为空 ⇒ default（这是控制台手建负载的常见形态）
SA=$(kubectl -n $NS get deploy "$T" -o jsonpath='{.spec.template.spec.serviceAccountName}')
[ -n "$SA" ] || SA=default
SAF=$(kubectl -n $NS get sa "$SA" -o jsonpath='{.imagePullSecrets[*].name}')
printf '  实际生效 SA=%s  其 imagePullSecrets=[%s]\n' "$SA" "$SAF"
case "$SAF" in
  *acr-credential-secret-aggregation*) : ;;
  *) echo "  [XX] $SA 上没有免密 Secret ⇒ 重建也没用。改走 --fix-pull-sa $T（换 SA）"; exit 2 ;;
esac

echo "=== G1 当前 Pod 与它的 pullSecrets（判据就是这一个字段）"
kubectl -n $NS get pod -l app=$T -o jsonpath='{range .items[*]}  pod {.metadata.name}  phase={.status.phase}  sa={.spec.serviceAccountName}  pullSecrets=[{.spec.imagePullSecrets[*].name}]{"/"}{"\n"}{end}' 2>&1
PODS=$(kubectl -n $NS get pod -l app=$T -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.imagePullSecrets[*].name}{"\n"}{end}')
if [ -z "$PODS" ]; then echo "  [!!] 没有匹配 app=$T 的 Pod（标签不同名？）—— 仍继续，按 Deployment 重建"; fi
if printf '%s' "$PODS" | grep -q 'acr-credential-secret-aggregation'; then
  echo "  [i] 现存 Pod 已带凭据 ⇒ 说明坑已过（多半已修过），幂等退出"
  kubectl -n $NS get deploy "$T" -o jsonpath='  ready={.status.readyReplicas}/{.status.replicas}{"\n"}' 2>&1
  exit 0
fi

if [ "$APPLY" != "1" ]; then
  echo "=== G2 [计划] 将对 deploy/$T 执行 kubectl rollout restart（不改 spec，只产生新 RS/Pod）"
  echo "     应用方式：把 APPLY=0 改成 APPLY=1 后重跑（--fix-pull-restart $T）"
  exit 0
fi

echo "=== G2 rollout restart"
kubectl -n $NS rollout restart deploy/"$T" 2>&1 | sed 's/^/  /'

echo "=== G3 新 Pod 的 pullSecrets（决定性判据，应在拉取前即可见）"
sleep 8
kubectl -n $NS get pod -l app=$T -o jsonpath='{range .items[*]}  pod {.metadata.name}  sa={.spec.serviceAccountName}  pullSecrets=[{.spec.imagePullSecrets[*].name}]{"/"}{"\n"}{end}' 2>&1

echo "=== G4 等就绪（上限 200s；跨区公网拉 78MB 可能偏慢）"
kubectl -n $NS rollout status deploy/"$T" --timeout=200s 2>&1 | sed 's/^/  /'
RC=$?

echo "=== G5 终态"
kubectl -n $NS get deploy "$T" -o jsonpath='  ready={.status.readyReplicas}/{.status.replicas}  updated={.status.updatedReplicas}{"\n"}' 2>&1
kubectl -n $NS get pod -l app=$T -o jsonpath='{range .items[*]}  pod {.metadata.name}  phase={.status.phase}  {range .status.containerStatuses[*]}ready={.ready} restarts={.restartCount}{"\n"}{end}{end}' 2>&1
echo "--- G0-G5 结束（唯一写入 = rollout restart 触发的 Pod 重建）"
exit $RC
