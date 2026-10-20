#!/bin/bash
# deploy/ops/bodies/verify_addon_scope.sh —— ACR 免密组件作用域双路取证（纯只读）
# 判据顺序必须是：组件配置（云侧）→ ns 里的 Secret → SA.imagePullSecrets → Pod 用的 SA
set -uo pipefail
CID="${CID:-cb0abf5bc06034f7bbdb991752f6f3e62}"
REGION="${REGION:-ap-southeast-5}"
ADDON="${ADDON:-managed-aliyun-acr-credential-helper}"
NSLIST="${NSLIST:-newapi-dev new-api-pre new-api-perf}"
SEC=acr-credential-secret-aggregation

echo "=== S1 云侧组件配置由本机 aliyun 取证（节点上无云侧凭据，不在这里调 OpenAPI）"
echo "=== S2 ns 内有没有那个 Secret（有 ≠ Pod 拿到，见 S4）"
for n in $NSLIST; do
  printf '  %-14s secret=%s\n' "$n" "$(kubectl -n $n get secret $SEC -o jsonpath='{.metadata.name}' 2>&1 | head -1)"
done

echo "=== S3 Secret 里登记的 registry 域名（只取域名，凭据一律不取）"
for n in $NSLIST; do
  kubectl -n $n get secret $SEC -o go-template='{{index .data ".dockerconfigjson"}}' 2>/dev/null | base64 -d 2>/dev/null \
    | grep -oE '[a-z0-9.-]*\.cr\.aliyuncs\.com' | sort -u | sed "s|^|  $n registry=|"
done

echo "=== S4 每个 ns 的 SA → imagePullSecrets（免密 helper 只绑它 serviceAccount 里点名的 SA）"
for n in $NSLIST; do
  kubectl -n $n get sa -o jsonpath='{range .items[*]}{.metadata.name}{"  pullSecrets="}{.imagePullSecrets[*].name}{"\n"}{end}' 2>&1 | sed "s/^/  $n  /"
done

echo "=== S5 托管形态自查：集群内有没有 acr-configuration CM（托管版应查不到，属正常）"
kubectl -n kube-system get cm acr-configuration -o jsonpath='{.metadata.name}' 2>&1 | head -1 | sed 's/^/  /'
echo "  （查不到 = 配置只在云侧组件里，改它必须走 cs ModifyAddon/配置接口，别在集群里建 CM 冒充）"
echo "--- S1–S5 结束（全程只读：未 apply、未 patch、未删除任何对象）"
