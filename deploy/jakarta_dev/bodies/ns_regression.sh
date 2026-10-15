#!/bin/bash
# bodies/ns_regression.sh —— 只读：第二个负载进 ns 后，§12.5 的 V1–V11 证据是否被扰动
# 最要紧的是 N1：dev Service 的 selector 会不会把流量分给这个没配库的 Pod。
NS=newapi-dev
mask() { sed -E -e 's/(password=)[^ ]*/\1***/g' -e 's#://([^:/]+):[^@]*@#://\1:***@#g'; }

echo "=== N1 Service selector × Pod labels × Endpoints（三者必须自证，不看控制台）"
kubectl -n $NS get svc -o jsonpath='{range .items[*]}{.metadata.name}{"  sel="}{.spec.selector}{"  ports="}{.spec.ports[*].port}{"  clusterIP="}{.spec.clusterIP}{"\n"}{end}' 2>&1 | sed 's/^/  /'
echo "  --- 每个 Pod 的标签（决定它进不进 Endpoints）"
kubectl -n $NS get pod -o jsonpath='{range .items[*]}{.metadata.name}{"  labels="}{.metadata.labels}{"  ip="}{.status.podIP}{"\n"}{end}' 2>&1 | sed 's/^/  /'
echo "  --- Endpoints 实际后端（这一行是判定，不是推测）"
kubectl -n $NS get endpoints -o jsonpath='{range .items[*]}{.metadata.name}{"  ready="}{range .subsets[*].addresses[*]}{.ip}{" "}{end}{"  notReady="}{range .subsets[*].notReadyAddresses[*]}{.ip}{" "}{end}{"\n"}{end}' 2>&1 | sed 's/^/  /'
# 判定也改成通用式：原先只盯 fanyan 一个前缀，负载一删就失真。
# 现在对 ns 里每个 Service，列出其后端 IP 归属到哪个 Pod（期望：一个 Service 只收本负载的 Pod）。
PODIP=$(kubectl -n $NS get pod -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.podIP}{"\n"}{end}' 2>/dev/null)
for sv in $(kubectl -n $NS get svc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  for ip in $(kubectl -n $NS get endpoints "$sv" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null); do
    owner=$(awk -v i="$ip" '$2==i {print $1}' <<<"$PODIP")
    [ -n "$owner" ] || owner="<查不到归属 Pod>"
    printf '  后端归属：svc/%-20s → %s → pod/%s\n' "$sv" "$ip" "$owner"
  done
done
echo "  判定口径：每个 Service 只应收本负载的 Pod；跨负载串后端 = dev 内部自相污染（不是生产破口，但会让冒烟结果不可信）"

echo "=== N2 每个负载到底连了哪个库（拿它自己的配置与启动日志，不看清单猜）"
# 修口径（2026-10-13）：原先把负载名写死成 new-api-dev / fanyan-…，结果 fanyan 被删、
# ns 里新冒出 new-api-dev-slave 之后这一行直接查空 ⇒ 一律自动发现，不硬编码。
DEPS=$(kubectl -n $NS get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
for d in $DEPS; do
  printf '  [%s] env 键名（只列名，绝不列值）：%s\n' "$d" \
    "$(kubectl -n $NS get deploy "$d" -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' 2>&1)"
  printf '  [%s] envFrom：%s  secretKeyRef：%s\n' "$d" \
    "$(kubectl -n $NS get deploy "$d" -o jsonpath='{.spec.template.spec.containers[0].envFrom[*].secretRef.name} {.spec.template.spec.containers[0].envFrom[*].configMapRef.name}' 2>&1)" \
    "$(kubectl -n $NS get deploy "$d" -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}<-{.valueFrom.secretKeyRef.name}/{.valueFrom.secretKeyRef.key} {end}' 2>&1)"
  printf '  [%s] sa=%s image=%s\n' "$d" \
    "$(kubectl -n $NS get deploy "$d" -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>&1)" \
    "$(kubectl -n $NS get deploy "$d" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>&1)"
done
echo "  --- 各负载容器日志里的库判定行（口令一律打码）"
for d in $DEPS; do
  printf '  [%s]\n' "$d"
  kubectl -n $NS logs deploy/"$d" --tail=120 2>&1 | mask \
    | grep -Ei 'SQL_DSN|SQLite|PostgreSQL|MySQL|ClickHouse|SESSION|listen|Fatal|panic|slave|master' | head -8 | sed 's/^/    /'
done
echo "  --- V10 同口径：每个负载进程内看到的 DSN 落点（只打印 host/port/db，绝不打印口令）"
for p in $(kubectl -n $NS get pod -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  printf '    [%s] ' "$p"
  kubectl -n $NS exec "$p" -- sh -c 'for K in SQL_DSN SQL_DSN_MIGRATE LOG_SQL_DSN; do V=$(printenv $K); [ -n "$V" ] || continue; H=$(printf "%s" "$V" | sed -nE "s#^.*://[^@]+@([^:/]+):.*#\1#p"); P=$(printf "%s" "$V" | sed -nE "s#^.*://[^@]+@[^:/]+:([0-9]+)/.*#\1#p"); D=$(printf "%s" "$V" | sed -nE "s#^.*://[^@]+@[^/]+/([^?]+).*#\1#p"); printf "%s host=%s port=%s db=%s; " "$K" "$H" "$P" "$D"; done; echo "NODE_TYPE=$(printenv NODE_TYPE)"' 2>&1 | sed 's/^/      /'
done
echo "  （期望：host 全为 dev 实例 pgm-d9j9p421lzx4gw73；出现生产实例/生产网段即隔离破口）"

echo "=== N3 资源请求/限制（控制台手建通常为空 ⇒ dev 节点容量风险）"
kubectl -n $NS get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"  req="}{.spec.template.spec.containers[0].resources.requests}{"  lim="}{.spec.template.spec.containers[0].resources.limits}{"  probes="}{.spec.template.spec.containers[0].readinessProbe}{"\n"}{end}' 2>&1 | sed 's/^/  /'
echo "=== N4 配额与节点占用（本卡建的是 pods=20）"
kubectl -n $NS get resourcequota --no-headers 2>&1 | head -2 | sed 's/^/  /'
kubectl -n $NS get deploy -o jsonpath='{range .items[*]}{.metadata.name}{" replicas="}{.spec.replicas}{"\n"}{end}' 2>&1 | sed 's/^/  /'
kubectl top pod -n $NS 2>&1 | head -5 | sed 's/^/  /'

echo "=== N5 §12.5 敏感项回归（V7 SA 面 / V8 免密面 / V9 生产串台）"
printf '  V7 ns 内 Role+RoleBinding：%s 个（期望 0）；引用 new-api-app 的 ClusterRoleBinding：%s 个（期望 0）\n' \
  "$(kubectl -n $NS get role,rolebinding --no-headers 2>/dev/null | wc -l)" \
  "$(kubectl get clusterrolebinding --no-headers 2>/dev/null | grep -c new-api-app)"
printf '  V8 免密 Secret 仍在 ns：%s；helper 作用域未变仍只点名 new-api-app\n' \
  "$(kubectl -n $NS get secret acr-credential-secret-aggregation --ignore-not-found -o jsonpath='{.metadata.name}')"
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
echo "  （上面若无 [XX] 行 ⇒ 新增负载没有把任何生产端点/网段带进 dev Secret）"
echo "--- N1–N5 结束（全程只读：未 apply/patch/delete，未改任何对象；exec 只跑 ls/find）"
