#!/bin/bash
set -uo pipefail
export KUBECONFIG="${K8S:-/tmp/k8s/kubeconfig}"
kubectl get deploy -n new-api -o name 2>&1 | tr -d '\r'
echo '--- pods ---'
kubectl get pods -n new-api --no-headers 2>&1 | tr -d '\r' | head -6
echo QUERY_DONE
