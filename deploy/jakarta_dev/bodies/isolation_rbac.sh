#!/bin/bash
# bodies/isolation_rbac.sh —— Phase 3 隔离验收 V7–V11（权限面 / 密钥面 / 资源面，全程只读）
# 为什么与 V1–V6 拆成两个 body：云助手命令内容上限（实测 ~19KB 直接 CmdContentExceedLimit），
#   而临时 kubeconfig 本身要占 ~7KB；合并后的命令体 15.6KB 已被本地闸门拦下（2026-10-12 实测）。
# 红线：任何密钥值都不打印；V9 只输出"命中/未命中"。
set -uo pipefail
NS=newapi-dev
POD=$(kubectl -n $NS get pod -l app=new-api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

echo "=== V7 dev SA 权限最小化（结构性证据 + can-i 双重口径）"
SA=system:serviceaccount:$NS:new-api-app
# 为什么先看结构：本次用的临时 admin kubeconfig 不一定有 impersonate 权，`auth can-i --as=` 全 no 有可能是
# "冒充被拒"而不是"SA 真的没权限"。⇒ 直接列 RBAC 绑定，绑定为零就是零，不依赖 impersonation。
echo "  ns 内 Role/RoleBinding：$(kubectl -n $NS get role,rolebinding --no-headers 2>/dev/null | wc -l) 个"
echo "  集群里引用 new-api-app 的 ClusterRoleBinding：$(kubectl get clusterrolebinding --no-headers 2>/dev/null | grep -c new-api-app) 个"
echo "  集群里引用 new-api-app 的 RoleBinding（全 ns）：$(kubectl get rolebinding -A --no-headers 2>/dev/null | grep -c new-api-app) 个"
for c in "get pods -n $NS" "list secrets -n $NS" "get pods -n default" "get nodes" "create clusterrolebindings" "list secrets -n kube-system"; do
  printf '  can-i %-28s ⇒ %s\n' "$c" "$(kubectl auth can-i $c --as=$SA 2>&1 | tail -1)"
done
printf '  （对照：用当前 admin 凭据本身 can-i get nodes ⇒ %s；若为 yes 则上面的 no 是真判据）\n' "$(kubectl auth can-i get nodes 2>&1 | tail -1)"

echo "=== V8 免密拉取组件的作用域只圈 dev（watchNamespace 不含生产 ns；凭据 Secret 不出 ns）"
kubectl get deploy -A 2>/dev/null | grep -i acr | sed 's/^/  /'
ACR_NS=$(kubectl get deploy -A --no-headers 2>/dev/null | grep -i acr | awk '{print $1}' | head -1)
if [ -n "$ACR_NS" ]; then
  kubectl -n "$ACR_NS" get deploy -o jsonpath='{range .items[*]}{range .spec.template.spec.containers[*]}{.name}{" "}{.env}{"\n"}{end}{end}' 2>/dev/null \
    | grep -oE '"name":"[A-Za-z_]*","value":"[^"]*"' | sed 's/^/    /'
fi
for n in newapi-dev kube-system default; do
  printf '  ns=%-12s pull-secret=%s\n' "$n" "$(kubectl -n $n get secret acr-credential-secret-aggregation --ignore-not-found -o jsonpath='{.metadata.name}' 2>/dev/null)"
done
printf '  dev SA 上的 imagePullSecrets：%s（清单里刻意不写 imagePullSecrets，与生产同构）\n' "$(kubectl -n $NS get sa new-api-app -o jsonpath='{.imagePullSecrets[*].name}')"

echo "=== V9 集群内不存在任何指向生产资源的 DSN（只打印命中与否，绝不打印值）"
for s in $(kubectl -n $NS get secret -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  for k in $(kubectl -n $NS get secret "$s" -o go-template='{{range $kk, $v := .data}}{{$kk}} {{end}}' 2>/dev/null); do
    V=$(kubectl -n $NS get secret "$s" -o jsonpath="{.data.$k}" 2>/dev/null | base64 -d 2>/dev/null)
    HIT=no
    for pat in pgm-5tstdhko64x2c01w 43.118.96.65 new-api-prod '10\.0\.' '10\.1\.' registry-vpc; do
      grep -qE "$pat" <<<"$V" && HIT="YES($pat)"
    done
    [ "$HIT" = no ] || printf '    [XX] %s/%s ⇒ %s\n' "$s" "$k" "$HIT"
    unset V
  done
done
echo "  （上面若无 [XX] 行 ⇒ dev Secret 里没有任何生产端点/生产网段串台）"

echo "=== V10 日志库分家：LOG_SQL_DSN 指向 dev 实例的 newapi_logs，且与 SQL_DSN 同实例不同库"
if [ -n "$POD" ]; then
  kubectl -n $NS exec "$POD" -- sh -c 'for K in SQL_DSN SQL_DSN_MIGRATE LOG_SQL_DSN; do V=$(printenv $K); H=$(printf "%s" "$V" | sed -nE "s#^.*://[^@]+@([^:/]+):.*#\1#p"); P=$(printf "%s" "$V" | sed -nE "s#^.*://[^@]+@[^:/]+:([0-9]+)/.*#\1#p"); D=$(printf "%s" "$V" | sed -nE "s#^.*://[^@]+@[^/]+/([^?]+).*#\1#p"); echo "    $K host=$H port=$P db=$D"; done' 2>&1
  echo "    （期望：三条 host 全为 dev 实例域名，db = newapi / newapi / newapi_logs；口令不在此输出）"
else
  echo "  (找不到应用 Pod，V10 未测)"
fi

echo "=== V11 dev ns 资源面自查（本卡产物之外不应有业务对象）"
kubectl -n $NS get deploy,svc,cm,secret,sa,pod --no-headers 2>&1 | awk '{print "  " $1}' | sed 's#/[a-z0-9.-]*##' | sort | uniq -c
echo "  临时探针/冒烟残留（应为 0）：$(kubectl -n $NS get pod -o name 2>/dev/null | grep -cE 't2d-') 个"
echo "--- V7–V11 采集结束（V1–V6 见 bodies/isolation.sh；云端侧 CEN/Peering 由本机 aliyun 只读复核，见台账 §12）"
