#!/bin/bash
# bodies/diagnose_pull.sh —— 只读：诊断"控制台手建的 Deployment 拉不到镜像"（不投递任何凭据）
#
# 为什么先取原始报错串：免密失败和镜像路径写错在控制台都表现为 0/1 + ImagePullBackOff，
# 但修法完全不同（① 给 Pod 挂上凭据；② 改镜像名）。只有 Pod status 里的 waiting.message
# 和 Event 的原文能分辨。⇒ 本机 aliyun cr 已证明 newapi-prod/newapi-master:20261009-a8e646954
#    在 EE 实例里存在且 digest 与 dev 正在跑的那个相同，所以这里预期是 ①，但仍以实测为准。
trap 'rm -rf /tmp/diag-pull-*' EXIT
NS=newapi-dev
echo "=== D1 ns 里所有 Deployment 的「镜像 / SA / imagePullSecrets」三要素（免密只认这三个）"
kubectl -n $NS get deploy --no-headers 2>&1 | awk '{print "  deploy="$1}'
kubectl -n $NS get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"  sa="}{.spec.template.spec.serviceAccountName}{"  img="}{.spec.template.spec.containers[0].image}{"  pullSecrets="}{.spec.template.spec.imagePullSecrets[*].name}{"\n"}{end}' 2>&1 | sed 's/^/    /'
echo "    （sa 为空 ⇒ 实际用 default；控制台「使用镜像创建」就是这个默认值）"

echo "=== D2 谁在 ImagePullBackOff / ErrImagePull —— 取 waiting.message 原文"
kubectl -n $NS get pod -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{range .status.containerStatuses[*]}{.state.waiting.reason}{"  "}{.state.waiting.message}{"\n"}{end}{end}' 2>&1 \
  | sed -E 's#(https?://[^ ]*):([^@]*)@#\1:***@#g; s/(password=)[^ ]*/\1***/g' | sed 's/^/    /'
echo "  --- 事件原文（只留拉取相关行，口令一律打码）"
kubectl -n $NS get events --sort-by=.lastTimestamp 2>&1 \
  | grep -Ei 'imagepull|errimage|pull|authoriz|denied|manifest|unauthorized' | tail -20 \
  | sed -E 's#(https?://[^ ]*):([^@]*)@#\1:***@#g' | sed 's/^/    /'

echo "=== D3 免密凭据 Secret 在不在 ns 里、里面登记了哪些 registry"
kubectl -n $NS get secret acr-credential-secret-aggregation -o jsonpath='{.metadata.name}' 2>&1 | sed 's/^/    name=/'
# 结构性不取值（替代原先的"事后正则打码"，见 §13.6 坑 17）：整段只 grep 出 registry 域名，
# 值通道从头到尾不存在 ⇒ 任何键名大小写变化都不可能再造成暴露。
kubectl -n $NS get secret acr-credential-secret-aggregation -o go-template='{{index .data ".dockerconfigjson"}}' 2>/dev/null | base64 -d 2>/dev/null \
  | grep -oE '[a-z0-9.-]*\.cr\.aliyuncs\.com' | sort -u | sed 's/^/    registry=/'
echo "    （只打印域名。Username/Password 一类字段一律不取、不打、不进输出）"

echo "=== D4 ns 内每个 SA 的 imagePullSecrets —— 免密 helper 只把凭据挂到它配置里那个 SA"
kubectl -n $NS get sa -o jsonpath='{range .items[*]}{.metadata.name}{"  pullSecrets="}{.imagePullSecrets[*].name}{"\n"}{end}' 2>&1 | sed 's/^/    /'
kubectl -n $NS get sa --no-headers 2>&1 | wc -l | sed 's/^/    SA 总数: /'

echo "=== D5 helper 自身的配置（kube-system/acr-configuration，只取作用域键，值打码）"
kubectl -n kube-system get cm acr-configuration -o go-template='{{range $k, $v := .data}}{{$k}}={{$v}}{{"\n"}}{{end}}' 2>&1 \
  | sed -E 's/(pwd|password|token|secret)([^=]*)=[^[:space:]]*/\1\2=***/gi' | cut -c1-320 | sed 's/^/    /'

echo "=== D6 对照：能正常跑的 new-api-dev 与没起来的 Deployment 的差异（同 ns、同节点、同入口）"
# 目标 = ns 里所有 ready 数 < 期望数的 Deployment（自动发现，不写死名字，避免下次换名字又要改 body）
TARGETS=$(kubectl -n $NS get deploy -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.replicas}{" "}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null \
  | awk '$2 != $3 {print $1}')
for d in new-api-dev $TARGETS; do
  printf '    %-24s sa=%-14s pullSecrets=%-40s ready=%s\n' "$d" \
    "$(kubectl -n $NS get deploy "$d" -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null)" \
    "$(kubectl -n $NS get deploy "$d" -o jsonpath='{.spec.template.spec.imagePullSecrets[*].name}' 2>/dev/null)" \
    "$(kubectl -n $NS get deploy "$d" -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null)"
done
echo "--- D1–D6 采集结束（只读：未 apply、未 patch、未删除任何对象）"
