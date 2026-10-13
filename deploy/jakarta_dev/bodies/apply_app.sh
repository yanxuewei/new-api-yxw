#!/bin/bash
# bodies/apply_app.sh —— Deployment + Service（必须在 --secret 之后）
trap 'rm -rf "$T"' EXIT
printf '%s' "$DOCS_B64" | base64 -d | tar xz -C "$T/payload" || { echo "  [XX] docs 解包失败"; exit 1; }

echo "--- 0) 前置校验：Secret 必须已存在且 4 键齐全（否则 Pod 起不来）"
KEYS=$(kubectl -n newapi-dev get secret new-api-secrets -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}' 2>&1)
case "$?" in
  0) echo "    Secret 键: $KEYS"
     for need in SQL_DSN SQL_DSN_MIGRATE LOG_SQL_DSN SESSION_SECRET; do
       case " $KEYS " in *" $need "*) ;; *) echo "    [XX] Secret 缺键 $need ⇒ 先跑 --secret"; exit 1;; esac
     done ;;
  *) echo "    [XX] Secret new-api-secrets 取不到（$KEYS）⇒ 先跑 dev_deploy.sh --secret"; exit 1 ;;
esac

for k in doc_Deployment doc_Service; do
  f="$T/payload/$k.yaml"
  [ -s "$f" ] || { echo "--- $k [MISS]"; continue; }
  echo "--- apply $k"
  kubectl apply -f "$f" 2>&1 | sed 's/^/    /'
done

echo "--- 1) 显式 rollout restart（任务 17 已证：Secret 变更不会自动重启 Pod；dev 的 checksum 注解只覆盖 ConfigMap）"
kubectl -n newapi-dev rollout restart deploy/new-api-dev 2>&1 | sed 's/^/    /'

echo "--- 2) rollout（startupProbe 上限 150s，整卡给 240s ⇒ 必须明显短于云助手 --Timeout，否则命令被杀、节点侧凭据来不及清）"
kubectl -n newapi-dev rollout status deploy/new-api-dev --timeout=240s 2>&1 | sed 's/^/    /'
rc=$?
echo "    rollout_rc=$rc"

echo "--- 2) Pod 快照"
kubectl -n newapi-dev get pod -l app=new-api -o wide 2>&1 | sed 's/^/    /'
if [ "$rc" != 0 ]; then
  echo "--- 2b) 失败时的事件与日志（多数是镜像拉取或权限）"
  kubectl -n newapi-dev get events --sort-by=.lastTimestamp 2>&1 | tail -14 | sed 's/^/    /'
  kubectl -n newapi-dev logs deploy/new-api-dev --tail=20 2>&1 \
    | sed -E 's/(password=)[^ ]*/\1***/g; s#://([^:/]+):[^@]*@#://\1:***@#g' | sed 's/^/    /'
fi
echo "--- 3) 镜像与 SA（免密拉取面）"
kubectl -n newapi-dev get pod -l app=new-api -o jsonpath='{range .items[*]}{.metadata.name}{"  node="}{.spec.nodeName}{"  sa="}{.spec.serviceAccountName}{"  img="}{.spec.containers[0].image}{"\n"}{end}' 2>&1 | sed 's/^/    /'
