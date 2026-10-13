#!/bin/bash
# bodies/fix_pull_sa.sh —— 免密方案 A：把目标 Deployment 的 SA 改成 new-api-app（helper 已点名绑定的那个）
# 边界：只动 TARGET 一个负载；不碰 new-api-dev；不改 helper 配置、不改 Secret、不改 RBAC、不改镜像。
# 依据（§13.2 实测）：ns 内只有 new-api-app 挂 acr-credential-secret-aggregation；default 为空。
# 依据（V7）：new-api-app 没有任何 Role/RoleBinding ⇒ 换 SA 不会多发一点集群权限。
NS=newapi-dev
SA=new-api-app
T="${TARGET:-}"
podline() {  # 按 Pod 名列印「一项一行的可判定字段」，避免 grep 到别的负载
  kubectl -n $NS get pod -o jsonpath="{range .items[*]}{.metadata.name}{\"  \"}$1{\"\\n\"}{end}" 2>&1
}
echo "=== F0 目标与前置闸门"
if [ -z "$T" ]; then echo "  [XX] 未传 TARGET ⇒ 终止（刻意不设默认值，避免误伤别的负载）"; exit 2; fi
if [ "$T" = "new-api-dev" ]; then echo "  [XX] TARGET 不能是 new-api-dev（它本来就在该 SA 上，且属本卡产物）"; exit 2; fi
kubectl -n $NS get deploy "$T" -o jsonpath="  before: name={.metadata.name}  sa={.spec.template.spec.serviceAccountName}  replicas={.spec.replicas}{\"\\n\"}" 2>&1 \
  || { echo "  [XX] 取不到 deploy/$T ⇒ 终止"; exit 2; }
kubectl -n $NS get deploy "$T" -o jsonpath='  before: image={.spec.template.spec.containers[0].image}{"\n"}' 2>&1
SAF=$(kubectl -n $NS get sa $SA -o jsonpath='{.imagePullSecrets[*].name}' 2>&1)
printf '  闸门：SA=%s 的 imagePullSecrets=%s（必须非空，否则换了也白换）\n' "$SA" "$SAF"
case "$SAF" in
  acr-credential-secret-aggregation) : ;;
  *) echo "  [XX] $SA 上没有免密 Secret ⇒ helper 作用域变了，先回 §13.2 复核，不动手"; exit 1 ;;
esac

echo "=== F1 patch serviceAccountName（幂等：已同值则输出 unchanged）"
OUT=$(kubectl -n $NS patch deploy "$T" -p "{\"spec\":{\"template\":{\"spec\":{\"serviceAccountName\":\"$SA\"}}}}" 2>&1)
printf '  %s\n' "$OUT"
case "$OUT" in
  *error*|*Error*) echo "  [XX] patch 失败 ⇒ 不重试、不 restart，交回人工判读"; exit 1 ;;
esac

echo "=== F2 回读 spec（生效判据只认这里，不信 patch 的返回码）"
kubectl -n $NS get deploy "$T" -o jsonpath='  after: sa={.spec.template.spec.serviceAccountName}  deploy级pullSecrets={.spec.template.spec.imagePullSecrets[*].name}{"   （Pod 级应为空：免密挂在 SA 上）"}{"\n"}' 2>&1
echo "  --- 各 RS 的模板 SA（新旧 RS 并存是正常滚动过程）"
kubectl -n $NS get rs -o jsonpath='{range .items[*]}{.metadata.name}{"  sa="}{.spec.template.spec.serviceAccountName}{"  des/cur/ready="}{.spec.replicas}{"/"}{.status.replicas}{"/"}{.status.readyReplicas}{"\n"}{end}' 2>&1 | sed 's/^/    /'

echo "=== F3 等拉取（240s，必须 < 云助手 RunCommand 900s；跨区公网 78MB×replicas 可能偏慢）"
kubectl -n $NS rollout status deploy/"$T" --timeout=240s 2>&1 | sed 's/^/    /'
RC=$?
printf '  rollout_rc=%s（非 0 不等于失败，可能是还在拉；看 F4 的 reason 原文）\n' "$RC"

echo "=== F4 实测结论（ready / imageID 是否真解析成功 / 残余拉取错误）"
kubectl -n $NS get deploy "$T" -o jsonpath='  ready={.status.readyReplicas}/{.status.replicas}  updated={.status.updatedReplicas}  unavailable={.status.unavailableReplicas}{"\n"}' 2>&1
podline '{range .status.containerStatuses[*]}ready={.ready} restarts={.restartCount} imageID={.imageID}{"\n"}{end}' | grep -F -- "$T" | sed 's/^/    /'
echo "  --- 仍在等待的容器（原文，口令一律打码）"
podline '{range .status.containerStatuses[*]}{.state.waiting.reason}|{.state.waiting.message}{"\n"}{end}' | grep -F -- "$T" \
  | grep -Ev '\|\s*$' | sed -E 's#(https?://[^ ]*):([^@]*)@#\1:***@#g; s/(password=)[^ ]*/\1***/g' | cut -c1-400 | sed 's/^/    /'
echo "--- F0–F4 结束（只 patch 了 deploy/$T 的 serviceAccountName）"
exit $RC
