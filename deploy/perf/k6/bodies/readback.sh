# bodies/readback.sh —— 压测环境只读回读：对象状态 / CPU / mock 指标 / Service 端点 / DNS
# 零凭据：不读任何 Secret 值（只判断键是否存在）
NS=new-api-perf

echo "=== 1) 负载与 Service"
kubectl -n $NS get deploy,pod -o wide 2>&1 | grep -vE "^$" | head -12
kubectl -n $NS get svc 2>&1 | head -8

echo "=== 2) CPU / 内存现值"
kubectl -n $NS top pod 2>&1 | head -12

echo "=== 3) mock 上游（ClusterIP 直连，节点可解析不了集群 DNS）"
MIP=$(kubectl -n $NS get svc mock-upstream -o jsonpath='{.spec.clusterIP}')
curl -sS -m 5 "http://$MIP/metrics" 2>&1 | grep -E "^mock_" | head -6

echo "=== 4) 被测 Service 的端点分布（≈每副本是否都被选中）"
for S in perf-new-api-master perf-new-api-slave; do
  printf '  %-22s %s\n' "$S" "$(kubectl -n $NS get endpoints $S -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | tr ' ' ',')"
done

echo "=== 5) 关键 Secret 键面（只报键名，不出值）"
kubectl -n $NS get secret new-api-secrets -o go-template='{{range $k,$v := .data}}  {{$k}}{{"\n"}}{{end}}' 2>&1
kubectl -n $NS get secret perf-load-test-credentials -o go-template='{{range $k,$v := .data}}  {{$k}}{{"\n"}}{{end}}' 2>&1

echo "=== 6) 集群内 DNS 与通道自检（临时 Pod，跑完即删）"
kubectl -n $NS delete pod dns-check --ignore-not-found >/dev/null 2>&1
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: dns-check, namespace: new-api-perf}
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: postgres:17-alpine
      command: ["sh","-c"]
      args:
        - |
          echo "  FQDN: $(getent hosts mock-upstream.new-api-perf.svc.cluster.local | head -1 | tr '\n' ' ')"
          echo "  HTTP: $(wget -qO- -T 3 http://mock-upstream.new-api-perf.svc.cluster.local/v1/models | head -c 60)"
      resources: {requests: {cpu: 50m, memory: 32Mi}, limits: {cpu: 200m, memory: 128Mi}}
YAML
for i in $(seq 1 20); do P=$(kubectl -n $NS get pod dns-check -o jsonpath='{.status.phase}' 2>/dev/null); [ "$P" = "Succeeded" ] && break; sleep 5; done
kubectl -n $NS logs dns-check 2>&1
kubectl -n $NS delete pod dns-check --wait=false >/dev/null 2>&1
