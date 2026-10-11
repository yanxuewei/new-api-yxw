#!/bin/bash
# 任务19 收口 · 步骤1：收敛 AlbConfig mnl-alb（超时 60/600 + 去 httpDefaultActions）
set -uo pipefail
say(){ printf '\n===== %s =====\n' "$1"; }

say "0. apply 前 live listeners"
kubectl get albconfig mnl-alb -o jsonpath='{.spec.listeners}'; echo
printf 'generation(before)=%s\n' "$(kubectl get albconfig mnl-alb -o jsonpath='{.metadata.generation}')"

say "1. apply 新 AlbConfig"
cat > /tmp/albconfig-mnl.yaml <<'YAML'
apiVersion: alibabacloud.com/v1
kind: AlbConfig
metadata:
  name: mnl-alb
  labels:
    project: new-api
    site: ph-mnl
    env: prod
spec:
  config:
    name: alb-newapi-mnl
    addressType: Internet
    zoneMappings:
      - vSwitchId: vsw-5ts9tgdq1xz3picjgoqyu
      - vSwitchId: vsw-5ts1dygyh2x0daspwny2r
    accessLogConfig:
      logProject: sls-newapi-mnl
      logStore: alb_access
    tags:
      - { key: project, value: new-api }
      - { key: site, value: ph-mnl }
      - { key: env, value: prod }
  listeners:
    - port: 80
      protocol: HTTP
      idleTimeout: 60
      requestTimeout: 600
YAML
kubectl apply -f /tmp/albconfig-mnl.yaml 2>&1 | tail -3

say "2. apply 后 live listeners"
kubectl get albconfig mnl-alb -o jsonpath='{.spec.listeners}'; echo
printf 'generation(after)=%s\n' "$(kubectl get albconfig mnl-alb -o jsonpath='{.metadata.generation}')"

say "3. 等待 reconcile（25s）"
sleep 25
kubectl get albconfig mnl-alb -o jsonpath='{.status}'; echo
kubectl get albconfig mnl-alb -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason} {.message}{"\n"}{end}' 2>/dev/null

say "4. 集群内基线自测（ClusterIP，非 ALB）"
printf 'stable ClusterIP -> '
curl -s -o /dev/null -w '%{http_code}\n' -m 8 http://172.21.15.220/api/status

echo
echo "===== STEP1 DONE ====="
