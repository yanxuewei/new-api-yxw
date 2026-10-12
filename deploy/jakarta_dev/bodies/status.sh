#!/bin/bash
# bodies/status.sh —— dev 只读快照（含隔离面：ns 内不该有任何生产端点被引用）
trap 'rm -rf "$T"' EXIT
echo "--- ns 全量"
kubectl -n newapi-dev get all,secret,configmap,resourcequota 2>&1 | sed 's/^/  /'
echo "--- 集群节点"
kubectl get nodes -o wide 2>&1 | sed 's/^/  /'
echo "--- 免密拉取组件（acr-credential-helper）"
kubectl get pods -A 2>/dev/null | grep -i -E 'acr|credential' | sed 's/^/  /'
kubectl -n kube-system get secrets 2>/dev/null | grep -i acr | head -5 | sed 's/^/  secret: /'
echo "--- new-api-app SA 上挂的 imagePullSecrets（应含 acr 凭据）"
kubectl -n newapi-dev get sa new-api-app -o go-template='{{if .imagePullSecrets}}imagePullSecrets={{range .imagePullSecrets}}{{.name}} {{end}}{{else}}imagePullSecrets=(空 ⇒ 免密拉取未生效){{end}}{{"\n"}}' 2>&1 | sed 's/^/  /'
echo "--- 清单里的镜像域名（必须是马尼拉 EE 公网入口，跨区无 -vpc）"
kubectl -n newapi-dev get deploy new-api-dev -o jsonpath='{.spec.template.spec.containers[0].image}' 2>&1 | sed 's/^/  /'
echo
echo "--- 隔离面（口径提示，真正的 V2–V10 实测在 bodies/isolation.sh）"
echo "  ConfigMap 值里出现的域名/IP：$(kubectl -n newapi-dev get cm new-api-config -o go-template='{{range $k, $v := .data}}{{$v}} {{end}}' 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}|[a-z0-9.-]+\.(aliyuncs\.com|com|cn|hk)' | sort -u | tr '\n' ' ')"
echo "  （生产端点只应出现在 dev 自己的 RDS 域名里；10.0.x/10.1.x 出现即为串台，期望无）"
