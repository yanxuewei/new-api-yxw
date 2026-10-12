#!/bin/bash
# bodies/apply_base.sh —— dev 基础对象（Namespace/ResourceQuota/SA/ConfigMap）
# 由 dev_deploy.sh --apply-base 拼在 header 之后执行；header 已备好 $T 与 $DOCS_B64
trap 'rm -rf "$T"' EXIT
printf '%s' "$DOCS_B64" | base64 -d | tar xz -C "$T/payload" || { echo "  [XX] docs 解包失败"; exit 1; }
for k in doc_Namespace doc_ResourceQuota doc_ServiceAccount doc_ConfigMap; do
  f="$T/payload/$k.yaml"
  if [ ! -s "$f" ]; then echo "--- $k [MISS] 本地没切出来"; continue; fi
  echo "--- apply $k"
  kubectl apply -f "$f" 2>&1 | sed 's/^/    /'
done
echo "--- 回读"
kubectl -n newapi-dev get ns,resourcequota,sa,configmap -o wide 2>&1 | sed 's/^/  /'
# 节点上没有 jq（实测 rc=127）⇒ 一律用 kubectl 原生 go-template/jsonpath
echo -n "  CM keys: "
kubectl -n newapi-dev get cm new-api-config -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}' 2>&1
echo
echo "--- ConfigMap 现值（不含任何敏感值，dev 的密钥全在 Secret 里）"
kubectl -n newapi-dev get cm new-api-config -o go-template='{{range $k, $v := .data}}  {{$k}} = {{$v}}{{"\n"}}{{end}}' 2>&1
