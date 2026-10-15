#!/bin/bash
# bodies/fix_dsn.sh —— new-api-dev-slave 的 SQL_DSN 从 SQL_DSN_MIGRATE 改为 SQL_DSN（DML 账号）
# 依据：生产 slave（stable-deployment.yaml）用 SQL_DSN；migrate 账号只给 master（AutoMigrate 用）
NS=newapi-dev
T=new-api-dev-slave
set -e

echo '--- 0) 前置：Secret 必须含 SQL_DSN 键'
KEYS=$(kubectl -n $NS get secret new-api-secrets -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}' 2>&1)
echo "    Secret 键: $KEYS"
case " $KEYS " in *" SQL_DSN "*) ;; *) echo "    [XX] 缺 SQL_DSN 键"; exit 1;; esac

echo '--- 1) patch 前 env 现值'
kubectl -n $NS get deploy $T -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{.valueFrom.secretKeyRef.name}{":"}{.valueFrom.secretKeyRef.key}{"\n"}{end}' 2>&1 | sed 's/^/    /'

CN=$(kubectl -n $NS get deploy $T -o jsonpath='{.spec.template.spec.containers[0].name}')
echo "    container=$CN"

if [ "${APPLY:-0}" != "1" ]; then
  echo '--- [计划模式] 未设 APPLY=1，不执行 patch（预期动作：env SQL_DSN 的 secretKeyRef.key → SQL_DSN，触发滚动重建）'
  exit 0
fi

echo '--- 2) patch（strategic merge：env 按 name 合并，只动 SQL_DSN 的 secretKeyRef.key）'
kubectl -n $NS patch deploy $T -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$CN\",\"env\":[{\"name\":\"SQL_DSN\",\"valueFrom\":{\"secretKeyRef\":{\"name\":\"new-api-secrets\",\"key\":\"SQL_DSN\"}}}]}]}}}}" 2>&1 | sed 's/^/    /'

echo '--- 3) rollout'
kubectl -n $NS rollout status deploy/$T --timeout=240s 2>&1 | sed 's/^/    /'
echo "    rollout_rc=$?"

echo '--- 4) patch 后 env + Pod 快照'
kubectl -n $NS get deploy $T -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{.valueFrom.secretKeyRef.name}{":"}{.valueFrom.secretKeyRef.key}{"\n"}{end}' 2>&1 | sed 's/^/    /'
kubectl -n $NS get pod -l app=$T -o wide 2>&1 | sed 's/^/    /'

echo '--- 5) 应用日志尾部（验证 DB 连接，脱敏）'
kubectl -n $NS logs deploy/$T --tail=15 2>&1 \
  | sed -E 's/(password=)[^ ]*/\1***/g; s#://([^:/]+):[^@]*@#://\1:***@#g' | sed 's/^/    /'
