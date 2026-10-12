#!/bin/bash
# bodies/delete.sh —— 只删本卡产物（集群、节点池、RDS 一律不动；回滚口径）
trap 'rm -rf "$T"' EXIT
echo "--- 删除顺序：工作负载 → 临时 Pod → Secret → ConfigMap（Namespace 保留，便于复跑）"
for item in "deploy/new-api-dev" "svc/new-api-dev" "pod/t2d-pgcli" "pod/t2d-smoke" "pod/t2d-curl" \
            "secret/new-api-secrets" "secret/t2d-dba" "cm/new-api-config"; do
  echo "  delete $item"
  kubectl -n newapi-dev delete "$item" --ignore-not-found 2>&1 | sed 's/^/    /'
done
echo "--- 剩余对象"
kubectl -n newapi-dev get all,secret,cm,resourcequota 2>&1 | sed 's/^/  /'
echo "--- RBAC/SA 保留（SA new-api-app 是免密拉取的挂载点，删了下次 --apply-base 会重建）"
kubectl -n newapi-dev get sa new-api-app -o jsonpath='{.metadata.name}{"  imagePullSecrets="}{.imagePullSecrets[*].name}' 2>&1 | sed 's/^/  /'
echo; echo "--- 如需连 Namespace 一起删：kubectl -n 无关，跑 kubectl delete ns newapi-dev（本脚本不自动做）"
