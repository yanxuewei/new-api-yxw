#!/bin/bash
# bodies/verify.sh —— dev 只读体检（零载荷，可反复跑）
# ⚠ 节点上没有 jq（实测 rc=127）⇒ 全部用 kubectl 原生 jsonpath / go-template
trap 'rm -rf "$T"' EXIT
echo "--- 对象总览"
kubectl -n newapi-dev get deploy,rs,pod,svc,cm,secret,resourcequota -o wide 2>&1 | sed 's/^/  /'
echo "--- Pod 明细（镜像 / 节点 / ready / 重启）"
kubectl -n newapi-dev get pod -l app=new-api -o jsonpath='{range .items[*]}{.metadata.name}{"  node="}{.spec.nodeName}{"  img="}{.spec.containers[0].image}{"  ready="}{.status.containerStatuses[0].ready}{"  restarts="}{.status.containerStatuses[0].restartCount}{"  started="}{.status.startTime}{"\n"}{end}' 2>&1 | sed 's/^/  /'
echo "--- 节点与 AZ"
kubectl get nodes -o wide 2>&1 | sed 's/^/  /'
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" zone="}{.metadata.labels.topology\.kubernetes\.io/zone}{" alloc_cpu="}{.status.allocatable.cpu}{" unsched="}{.spec.unschedulable}{"\n"}{end}' 2>&1 | sed 's/^/  /'
echo "--- 容器 env（名字 + 非敏感字面值 + 引用来源；Secret 值不外泄）"
kubectl -n newapi-dev get deploy new-api-dev -o jsonpath='{range .spec.template.spec.containers[0].env[*]}  env {.name} = "{.value}" from={.valueFrom.secretKeyRef.name}/{.valueFrom.secretKeyRef.key}{"\n"}{end}' 2>&1
echo "--- envFrom 引用"
kubectl -n newapi-dev get deploy new-api-dev -o jsonpath='{range .spec.template.spec.containers[0].envFrom[*]}  envFrom {.configMapRef.name}{.secretRef.name}{"\n"}{end}' 2>&1
echo "--- SQL_DSN 的取数面（master 必须取 SQL_DSN_MIGRATE）"
kubectl -n newapi-dev get deploy new-api-dev -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="SQL_DSN")].valueFrom.secretKeyRef.key}{"\n"}' 2>&1 | sed 's/^/  SQL_DSN <- Secret key: /'
echo "--- Secret / ConfigMap 键名"
echo "  secret: $(kubectl -n newapi-dev get secret new-api-secrets -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}' 2>&1)"
echo "  cm    : $(kubectl -n newapi-dev get cm new-api-config -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}' 2>&1)"
echo "--- ResourceQuota 用量"
kubectl -n newapi-dev get resourcequota -o jsonpath='{range .items[*]}  {.metadata.name} used={.status.used} hard={.status.hard}{"\n"}{end}' 2>&1
echo "--- 拓扑分布（Pod -> 节点）"
kubectl -n newapi-dev get pod -l app=new-api -o jsonpath='{range .items[*]}  {.metadata.name} -> {.spec.nodeName}{"\n"}{end}' 2>&1
echo "--- 近期事件（尾部 15 行）"
kubectl -n newapi-dev get events --sort-by=.lastTimestamp 2>&1 | tail -15 | sed 's/^/  /'
echo "--- 应用日志尾部（口令/DSN 一律打码）"
kubectl -n newapi-dev logs deploy/new-api-dev --tail=30 2>&1 \
  | sed -E 's/(password=)[^ ]*/\1***/g; s#://([^:/]+):[^@]*@#://\1:***@#g' | sed 's/^/  /'
echo "--- DDL 是否真跑过（SQL_SLOW_THRESHOLD_MS=1 后每条语句都落日志）"
echo "  DDL 行数: $(kubectl -n newapi-dev logs deploy/new-api-dev 2>&1 | grep -ciE 'CREATE TABLE|ALTER TABLE')"
