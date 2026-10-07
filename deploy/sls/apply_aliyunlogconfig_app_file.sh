#!/usr/bin/env bash
# 任务 26 app-file 纠正版｜下发 AliyunLogConfig（经 ack_remote.sh 在 VPC 节点内执行）
# 用法：bash ack_remote.sh mnl deploy/sls/apply_aliyunlogconfig_app_file.sh
set -uo pipefail
echo "---- [1] apply ----"
kubectl apply -f - <<'YAML'
apiVersion: log.alibabacloud.com/v1alpha1
kind: AliyunLogConfig
metadata:
  name: new-api-app-file
  namespace: new-api
spec:
  logstore: app-file
  logtailConfig:
    configName: new-api-app-file
    inputType: file
    inputDetail:
      logType: common_reg_log
      logPath: /data/logs
      filePattern: "*.log"
      # ⚠ 必须 dockerFile（旧名沿用）；containerFile 会被翻译丢弃 ⇒ 0 采集
      dockerFile: true
      maxDepth: 1
YAML
echo "---- [2] CR 现状（status 期望 OK/200） ----"
kubectl -n new-api get aliyunlogconfig new-api-app-file -o yaml 2>&1 | sed -n '/^spec:/,$p' | head -30
echo "---- [3] logtail 侧是否已下发该配置（容器内检查） ----"
POD=$(kubectl -n kube-system get pod -l k8s-app=logtail-ds -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
kubectl -n kube-system exec "$POD" -- sh -c 'ls /usr/local/ilogtail/ 2>/dev/null | head -3; grep -rl "new-api-app-file" /usr/local/ilogtail/ 2>/dev/null | head -5' 2>&1 | head -8
