#!/bin/bash
# task27/canary.sh — Day 3 · 任务 27（canary Deployment + 独立 Service/Ingress，权重 5）执行器
#
# 权威卡片：deploy/docs/阿里云国际站菲律宾部署_详细操作指南-v2.0.md（Day 3 · 任务 27）
# 执行通道：deploy/lib/ack_remote.sh mnl —— 两集群 endpoint_public_access=false、本机零 kubeconfig，
#           所有 kubectl 都要经 ECS RunCommand 在 VPC 节点内跑 ⇒ **连只读 body 也算写类 API，需授权留痕**。
#
# usage: task27/canary.sh --precheck|--dryrun|--apply-workload|--apply-ingress|--verify|--status
#                         |--set-weight <0|5>|--schema-fp [--teardown]
#   DRY=1  只渲染远端 body 不下发（可 shellcheck -s bash <body>）
#   CONFIRM=yes  --teardown 必需（删除属破坏性操作）
#
# 与卡片的唯一偏差：卡片写的是 `deploy/tasks/task27/bodies/0X-*.sh` 四个独立 body，
#   实际沿用本仓 deploy/tasks/task23/stable.sh 的执行器模式——manifest 全文只有一份（在 deploy/ 下），
#   由本脚本拼装成 RUN_ID 唯一的 body，避免四份副本互相漂移、并保证 checksum 在节点侧渲染。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPTURE=''            # emit_apply 的可选输出管道（仅 dryrun 用来数对象）
MODE="${1:-}"
[[ -n "$MODE" ]] || { echo "usage: $0 --precheck|--dryrun|--apply-workload|--apply-ingress|--verify|--status|--set-weight <N>|--schema-fp|--teardown"; exit 2; }
shift || true

ACK="$HERE/../../lib/ack_remote.sh"
[[ -x "$ACK" || -f "$ACK" ]] || { echo "[!] 找不到 $ACK"; exit 1; }
export ACKCTL_DIR="${ACKCTL_DIR:-/tmp/ackctl-mnl-cy}"   # 并发会话专用目录（卡片口径）
RUN_TS="$(date +%Y%m%d-%H%M%S)-$$"
LOGDIR="$HERE/../../logs/task27_${MODE#--}_$RUN_TS"
mkdir -p "$LOGDIR"

M_WL="$HERE/../../aliyun/ph/canary-deployment.yaml"
M_IW="$HERE/../../manifests/ingress-mnl-canary-weight.yaml"
M_IH="$HERE/../../manifests/ingress-mnl-canary-header.yaml"
for f in "$M_WL" "$M_IW" "$M_IH"; do [[ -s "$f" ]] || { echo "[!] 清单缺失：$f"; exit 1; }; done

# 从清单里取口径值（不在脚本里另写一份，避免与清单漂移）
IMG=$(grep -m1 'image: ' "$M_WL" | sed 's#.*image: ##')
TAG=${IMG##*:}
VER=$(grep -A1 'name: VERSION' "$M_WL" | grep 'value:' | sed 's/.*value: "//; s/"//')
NS=new-api
CANARY_SVC=new-api-canary

say() { printf '%s\n' "$*"; }
die() { echo "[!] $*" >&2; exit 1; }

# ---------------------------------------------------------------- 公共前言
read -r -d '' COMMON <<'S_EOF' || true
set -u
NS=new-api
echo "--- 集群侧时间 / kubeconfig ---"
date -u +"%Y-%m-%dT%H:%M:%SZ"; kubectl config current-context 2>/dev/null || echo "  (无 current-context，靠 \$KUBECONFIG)"
S_EOF

# checksum 算法**必须与 deploy/tasks/task23/stable.sh:364-368 逐字同构**，否则 stable/canary 的联动滚动语义分叉
CFG_SNIPPET='CFG_SUM=$(kubectl -n $NS get cm new-api-config -o json 2>/dev/null | python3 -c '"'"'
import hashlib,json,sys
d=(json.load(sys.stdin) or {}).get("data") or {}
print(hashlib.sha256(json.dumps(d, sort_keys=True).encode("utf-8")).hexdigest()[:12])
'"'"' 2>/dev/null)'

emit_apply() { # $1 = kubectl apply 额外参数；$2.. = manifest 文件
  # 文件之间**必须**补 `---`：多份清单直接拼接时，前一份的尾部与后一份的头部会并进同一个
  # YAML document，重复键 last-wins ⇒ kubectl 静默少建对象（2026-10-08 dry-run 实测：4 个对象
  # 只回显 2 个，Service 与权重 Ingress 被吞）。判据要看**对象条数**，不是看有没有报错。
  printf 'cat <<'"'"'MANEOF'"'"' | sed "s/__CONFIG_CHECKSUM__/\\$CFG_SUM/" | kubectl apply %s -f -%s\n' "$1" "$CAPTURE"
  shift
  for f in "$@"; do printf -- '---\n%s\n' "$(cat "$f")"; done
  printf 'MANEOF\n'
}

# ---------------------------------------------------------------- 各模式 body
read -r -d '' BODY_PRECHECK <<'S_EOF' || true
echo "=== P1) stable 现状（对照口径）==="
kubectl -n $NS get deploy/new-api-stable -o jsonpath='  replicas={.spec.replicas} ready={.status.readyReplicas} selector={.spec.selector.matchLabels}{"\n"}'
kubectl -n $NS get svc/new-api-stable -o jsonpath='  svc selector={.spec.selector} clusterIP={.spec.clusterIP}{"\n"}'
echo "=== P2) 端点（V3 基线：stable 端点里绝不能出现 canary Pod）==="
kubectl -n $NS get endpoints/new-api-stable -o wide 2>/dev/null
echo "=== P3) ConfigMap 键与关键阈值 ==="
kubectl -n $NS get cm/new-api-config -o jsonpath='{.data}' | python3 -c 'import json,sys; d=json.load(sys.stdin); [print("  %-28s %s"%(k,v)) for k,v in sorted(d.items())]'
echo "=== P4) ResourceQuota used vs hard（灰度期天花板算术的唯一依据）==="
kubectl -n $NS get resourcequota new-api-quota -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin).get("status",{})
for scope in ("used","hard"):
    print("  %s: %s" % (scope, json.dumps(d.get(scope,{}), sort_keys=True)))'
echo "  判据：hard[limits.cpu] - used[limits.cpu] >= canary 增量 4 ⇒ 现在可落；差值 <4 ⇒ 灰度期 HPA 天花板已被吃掉"
echo "=== P5) checksum/config 现值（must=task23 算法）==="
S_EOF

read -r -d '' BODY_PRE_TAIL <<'S_EOF' || true
printf '  CFG_SUM=%s\n' "${CFG_SUM:-<空>}"
kubectl -n $NS get deploy/new-api-stable -o jsonpath='{.spec.template.metadata.annotations.checksum/config}{"\n"}' | sed 's/^/  stable 侧现值: /'
echo "=== P6) Pod→Node→AZ 分布（canary 落点与 stable AZ 硬约束算术）==="
kubectl -n $NS get pods -l app=new-api -o wide 2>/dev/null | awk '{print "  "$1" "$3" node="$7}'
kubectl get nodes -o custom-columns='NAME:.metadata.name,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,CPU:.status.allocatable.cpu' 2>/dev/null | sed 's/^/  /'
echo "=== P7) 接流件现状（order / rules / 是否已有 canary 件）==="
kubectl -n $NS get ingress 2>/dev/null | sed 's/^/  /'
for i in new-api-stable-ip new-api-canary-weight new-api-canary-header; do
  printf '  %s order=%s canary=%s weight=%s\n' "$i" \
    "$(kubectl -n $NS get ingress $i -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/order}' 2>/dev/null)" \
    "$(kubectl -n $NS get ingress $i -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/canary}' 2>/dev/null)" \
    "$(kubectl -n $NS get ingress $i -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/canary-weight}' 2>/dev/null)"
done
echo "=== P8) SA / 镜像拉取凭据（default SA 必 ImagePullBackOff）==="
kubectl -n $NS get sa/new-api-app -o jsonpath='  sa={.metadata.name} imagePullSecrets={.imagePullSecrets[*].name}{"\n"}' 2>/dev/null || echo "  [XX] SA/new-api-app 不存在"
echo "=== P9) HPA 现值（灰度期需要按 12 副本申报）==="
kubectl -n $NS get hpa 2>/dev/null | sed 's/^/  /'
echo PRECHECK-DONE
S_EOF

read -r -d '' BODY_DRY_HEAD <<'S_EOF' || true
echo "=== D1) 四个对象 server-side dry-run（服务端校验，不落库）==="
S_EOF
read -r -d '' BODY_DRY_TAIL <<'S_EOF' || true
echo "=== D2) ★ 对象条数闸门（4 个：Deployment/Service/Ingress-weight/Ingress-header）==="
N=$(grep -c 'dry run)' /tmp/t27_dry.out 2>/dev/null || echo 0)
sed 's/^/  /' /tmp/t27_dry.out 2>/dev/null
if [ "$N" != "4" ]; then
  echo "  [XX] dry-run 只回显 $N 个对象（应为 4）⇒ 清单被静默合并/丢弃，禁止进入 apply"
  echo "      先查两份清单之间有没有 `---` 分隔（本仓 2026-10-08 实测踩过：拼接后只剩 2 个）"
  exit 1
fi
echo "  [OK] 四个对象都经服务端校验通过（created/configured/unchanged 都算通过）"
echo "      报 canary annotation 相关错误 ⇒ 回卡片订正表 #1/#2"
rm -f /tmp/t27_dry.out
echo DRYRUN-DONE
S_EOF

read -r -d '' BODY_APPLY_WL_HEAD <<'S_EOF' || true
echo "=== A1) apply Deployment+Service（先 workload，后 Ingress；顺序不能反）==="
S_EOF
read -r -d '' BODY_APPLY_WL_TAIL <<'S_EOF' || true
echo "=== A2) 等就绪（startupProbe 上限 150s/Pod）==="
if kubectl -n $NS rollout status deploy/new-api-canary --timeout=180s; then echo "  [OK] rollout 完成"; else
  echo "  [XX] 180s 未就绪，诊断 events / describe："
  kubectl -n $NS get events --sort-by=.lastTimestamp 2>/dev/null | tail -15 | sed 's/^/    /'
  kubectl -n $NS describe pod -l track=canary 2>/dev/null | tail -40 | sed 's/^/    /'
  echo "  常见四条：quota(limits.cpu) / AZ 硬约束 / required 反亲和无空节点 / 镜像拉取(SA 或 -vpc 域名)"
  exit 1
fi
echo "=== A3) Pod 落点与 VERSION 注入 ==="
kubectl -n $NS get pods -l track=canary -o wide 2>/dev/null | sed 's/^/  /'
kubectl -n $NS exec deploy/new-api-canary -- /bin/sh -c 'env | grep -E "^(VERSION|NODE_TYPE|GOMAXPROCS|CANARY)="' 2>/dev/null | sed 's/^/  /' || echo "  [warn] exec 取 env 失败（镜像无 sh/env？）"
echo "=== A4) ★ 闸门：endpoints 必须有 1 个 Ready 地址，否则不许放 Ingress ==="
kubectl -n $NS get endpoints/$CANARY_SVC -o wide --no-headers 2>/dev/null | sed 's/^/  /'
READY=$(kubectl -n $NS get endpoints/$CANARY_SVC -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w)
NOTREADY=$(kubectl -n $NS get endpoints/$CANARY_SVC -o jsonpath='{.subsets[*].notReadyAddresses[*].ip}' 2>/dev/null | wc -w)
if [ "${READY:-0}" -lt 1 ]; then echo "  [XX] ready=0 notReady=${NOTREADY:-0} ⇒ 停在这里。此时放权重件 = ALB 组内 0 后端，5% 流量全是 5xx"; exit 1; fi
echo "  [OK] ready=$READY notReady=${NOTREADY:-0} ⇒ 可以执行 --apply-ingress"
echo "=== A5) 端点隔离预检（stable 不应含 canary IP）==="
kubectl -n $NS get endpoints/new-api-stable -o wide --no-headers 2>/dev/null | sed 's/^/  /'
echo APPLY-WORKLOAD-DONE
S_EOF

read -r -d '' BODY_APPLY_IN_HEAD <<'S_EOF' || true
echo "=== I1) 前置闸门：canary 必须已有 Ready 端点（否则权重 5% 直接打成 5xx）==="
READY=$(kubectl -n $NS get endpoints/$CANARY_SVC -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w)
if [ "${READY:-0}" -lt 1 ]; then echo "  [XX] canary ready 端点数=$READY ⇒ 拒绝下发 Ingress"; exit 1; fi
printf '  [OK] canary ready=%s，继续\n' "$READY"
S_EOF
read -r -d '' BODY_APPLY_IN_TAIL <<'S_EOF' || true
echo "=== I2) 回读注解（两件必须都是 canary=true，且权重件无 header、头件无 weight）==="
for i in new-api-canary-weight new-api-canary-header; do
  echo "  --- $i"
  kubectl -n $NS get ingress $i -o jsonpath='{.metadata.annotations}' 2>/dev/null | tr ',' '\n' | grep -E 'canary|order|listen-ports|healthcheck-interval' | sed 's/^/      /'
done
echo "=== I3) ALB 同步事件（控制器是否 SuccessfullyReconciled）==="
kubectl -n $NS get events --sort-by=.lastTimestamp 2>/dev/null | grep -Ei 'canary|ingress' | tail -12 | sed 's/^/  /'
kubectl -n $NS get ingress new-api-canary-weight -o jsonpath='  LB hostname={.status.loadBalancer.ingress[0].hostname} host={.spec.rules[0].host} path={.spec.rules[0].http.paths[0].path} pathType={.spec.rules[0].http.paths[0].pathType}{"\n"}' 2>/dev/null
echo APPLY-INGRESS-DONE
S_EOF

read -r -d '' BODY_VERIFY <<'S_EOF' || true
echo "=== V3) 端点隔离（两件 Service 互不误收）==="
kubectl -n $NS get endpoints/new-api-stable -o wide 2>/dev/null | sed 's/^/  /'
kubectl -n $NS get endpoints/new-api-canary -o wide 2>/dev/null | sed 's/^/  /'
echo "  判据：stable 只有 track=stable 的 4 个 IP:3000；canary 只有 1 个"
echo "=== V5a) canary 启动日志不应出现任何 DDL ==="
kubectl -n $NS logs -l track=canary --tail=200 2>/dev/null | grep -Ei 'CREATE |ALTER |DROP |ERROR' | head | sed 's/^/  /'
echo "  判据：上面 0 行（有行=灰度版在动库，立刻 canary-weight=0 止血）"
echo "=== V5b) canary Pod 的 NODE_TYPE / 账号（slave + newapi@6432 才不发 DDL）==="
kubectl -n $NS exec deploy/new-api-canary -- /bin/sh -c 'echo NODE_TYPE=$NODE_TYPE VERSION=$VERSION' 2>/dev/null | sed 's/^/  /'
echo "=== V6a) canary 容器 stdout 是否可归因（SLS 按 _pod_name_ 过滤的前提）==="
kubectl -n $NS logs --tail=3 -l track=canary 2>/dev/null | sed 's/^/  /'
echo "=== V2 后端计数（主证据：窗口内非 /api/status 请求按 track 分桶）==="
echo "  窗口起点 V2_FROM=${V2_FROM:-<未设置：只出结构证，不出占比>}"
if [ -n "${V2_FROM}" ]; then
  for T in stable canary; do
    F=/tmp/t27_v2_$T.log
    # 只数 GET /（灰度采样打的根路径）；/api/status 是 ALB 健康检查，两个组都会打，必须排除
    kubectl -n $NS logs --since-time="$V2_FROM" -l track=$T --prefix > "$F" 2>/dev/null || true
    C=$(grep -c 'GET /$' "$F" || true)
    echo "  track=$T root_reqs=$C total_lines=$(wc -l < "$F")"
    grep 'GET /$' "$F" | head -2 | sed 's/^/    /'
  done
  echo "  判据：canary/(canary+stable) 落在 3%~7%（n=1000,p=0.05 ⇒ 50±13.5 的 95% 区间）"
fi
echo "=== 两件 Ingress 的当前权重 ==="
kubectl -n $NS get ingress new-api-canary-weight -o jsonpath='{"  weight="}{.metadata.annotations.alb\.ingress\.kubernetes\.io/canary-weight}{"\n"}'
kubectl -n $NS get ingress new-api-canary-header -o jsonpath='{"  header="}{.metadata.annotations.alb\.ingress\.kubernetes\.io/canary-by-header}{"="}{.metadata.annotations.alb\.ingress\.kubernetes\.io/canary-by-header-value}{"\n"}'
echo "  ⚠ V1/V2（外部 curl 采样）与 V4（annotate）不在本 body 内：V1/V2 从集群外打 ALB 公网 IP，V4 是写操作需单独核准"
echo VERIFY-DONE
S_EOF

read -r -d '' BODY_STATUS <<'S_EOF' || true
echo "=== STATUS) canary 三件套 + 权重现值 ==="
kubectl -n $NS get deploy/new-api-canary,pods -l track=canary,svc/new-api-canary,endpoints/new-api-canary,ingress 2>/dev/null | sed 's/^/  /'
echo "=== ALB Ingress 控制器活性三级取证（托管面，get pods 查不到≠没跑）==="
kubectl -n kube-system get lease alb -o jsonpath='{"  lease holder={.spec.holderIdentity} renew={.spec.renewTime}\n"}' 2>/dev/null
date -u +"  节点 UTC 时间 %Y-%m-%dT%H:%M:%SZ"
S_EOF

read -r -d '' BODY_SCHEMA_FP <<'S_EOF' || true
# 口径与任务 18/23 **逐字同构**（同一 SQL、同一 `SQL_DSN_MIGRATE`、同一临时 psql Pod 形态），
# 否则指纹值不可比。基线 FP0 来自 deploy/docs/Day2任务23_stable部署_执行报告.md §十。
# ⚠ 并发写入面：任务 17 实测 `ops_drill_marker`（任务 30 演练表）会让表数 36→37，
#   所以 FP0 是**含该表**的口径。若本次读到的表数差 1 且差异只落在这一张表上，
#   属"他人演练面变化"不是 schema 漂移，必须显式写明而不是含糊判过。
echo "=== F1) 临时 psql Pod（new-api ns 有 ResourceQuota，必须声明 requests/limits）==="
kubectl -n $NS delete pod t27-pgcli --ignore-not-found --wait=true >/dev/null 2>&1
cat <<'PGEOMF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: t27-pgcli
  namespace: new-api
  labels: { app: t27-pgcli, project: new-api, site: ph-mnl }
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 600
  terminationGracePeriodSeconds: 0
  containers:
    - name: psql
      image: postgres:17-alpine
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 480"]
      resources:
        requests: { cpu: 100m, memory: 128Mi }
        limits:   { cpu: 200m, memory: 256Mi }
      envFrom:
        - secretRef: { name: new-api-secrets }
PGEOMF
if ! kubectl -n $NS wait --for=condition=Ready pod/t27-pgcli --timeout=180s; then
  echo "  [XX] pgcli 未就绪（多为镜像拉取）⇒ 清理后中止"
  kubectl -n $NS delete pod t27-pgcli --ignore-not-found --wait=false >/dev/null 2>&1
  exit 1
fi
echo "=== F2) 指纹取数面自证（账号/库必须与任务 23 同：newapi_migrate@newapi）==="
kubectl -n $NS exec -i t27-pgcli -- sh -c 'psql "$SQL_DSN_MIGRATE" -Atq -F"|" -f -' <<'SQL' 2>&1 | sed 's/^/  /'
select current_user, current_database(), inet_server_port();
SQL
echo "=== F3) schema 指纹（SQL 与任务 18/23 逐字相同）==="
FP=$(kubectl -n $NS exec -i t27-pgcli -- sh -c 'psql "$SQL_DSN_MIGRATE" -Atq -F"|" -f -' <<'SQL'
select
  (select count(*) from information_schema.tables
     where table_schema='public' and table_type='BASE TABLE'),
  (select md5(string_agg(t, chr(10))) from (
     select table_name||'.'||column_name||':'||data_type||':'||coalesce(character_maximum_length::text,'-') as t
       from information_schema.columns where table_schema='public' order by t) c),
  (select md5(string_agg(t, chr(10))) from (
     select indexname||'='||indexdef as t from pg_indexes where schemaname='public' order by t) i);
SQL
)
FP=$(printf '%s' "$FP" | tr -d ' \n')
FP0='37|77f5c248d32cecb7c7e28a9b655deede|1174c9028cc094295a7b6bb066f51c14'
printf '  FP1 = %s\n' "$FP"
printf '  FP0 = %s\n' "$FP0"
echo "=== F4) 差异定位辅助（表清单 + 演练表在位与否）==="
kubectl -n $NS exec -i t27-pgcli -- sh -c 'psql "$SQL_DSN_MIGRATE" -Atq -F"|" -f -' <<'SQL' 2>&1 | sed 's/^/  /'
select (select count(*) from information_schema.tables where table_schema='public' and table_type='BASE TABLE') as tables,
       exists (select 1 from information_schema.tables where table_schema='public' and table_name='ops_drill_marker') as drill_marker;
SQL
kubectl -n $NS exec -i t27-pgcli -- sh -c 'psql "$SQL_DSN_MIGRATE" -Atqc "select table_name from information_schema.tables where table_schema='"'"'public'"'"' and table_type='"'"'BASE TABLE'"'"' order by 1"' 2>&1 | paste -sd' ' - | sed 's/^/  /'
if [ "$FP" = "$FP0" ]; then
  echo "  [OK] 逐字相同 ⇒ canary 存续期（含一次归零回滚演练）schema 零漂移"
else
  echo "  [XX] 不一致 ⇒ 先按 F4 判是否只落在 ops_drill_marker 上；是真漂移则立刻 canary-weight=0 并停在 20% 之前"
fi
echo "=== F5) 清理临时 Pod（残留必须为 0）==="
kubectl -n $NS delete pod t27-pgcli --ignore-not-found --wait=false >/dev/null 2>&1
kubectl -n $NS get pod t27-pgcli --ignore-not-found 2>/dev/null | sed 's/^/  /'
echo "  （无输出=已删）"
echo SCHEMA-FP-DONE
S_EOF

# ---------------------------------------------------------------- 组装
build_and_run() {
  local body="$LOGDIR/body.sh"
  {
    printf 'APP_IMAGE=%s\nTAG=%s\nVER=%s\nCANARY_SVC=%s\n' "$IMG" "$TAG" "$VER" "$CANARY_SVC"
    printf 'V2_FROM=%s\n' "${V2_FROM:-}"
    printf 'export NS APP_IMAGE TAG VER CANARY_SVC V2_FROM\n'
    printf '%s\n' "$COMMON"
    case "$1" in
      precheck)
        printf '%s\n' "$BODY_PRECHECK"; printf '%s\n' "$CFG_SNIPPET"; printf '%s\n' "$BODY_PRE_TAIL" ;;
      dryrun)
        printf '%s\n' "$BODY_DRY_HEAD"; printf '%s\n' "$CFG_SNIPPET"
        printf 'printf "  CFG_SUM=%%s\\n" "${CFG_SUM:-<空>}"; [ -n "$CFG_SUM" ] || { echo "  [XX] 读不到 ConfigMap"; exit 1; }\n'
        CAPTURE=' | tee /tmp/t27_dry.out'
        emit_apply "--dry-run=server" "$M_WL" "$M_IW" "$M_IH"
        CAPTURE=''
        printf '%s\n' "$BODY_DRY_TAIL" ;;
      apply-workload)
        printf '%s\n' "$BODY_APPLY_WL_HEAD"; printf '%s\n' "$CFG_SNIPPET"
        printf 'printf "  CFG_SUM=%%s\\n" "${CFG_SUM:-<空>}"; [ -n "$CFG_SUM" ] || { echo "  [XX] 读不到 ConfigMap，中止"; exit 1; }\n'
        emit_apply "" "$M_WL"
        printf '%s\n' "$BODY_APPLY_WL_TAIL" ;;
      apply-ingress)
        printf '%s\n' "$BODY_APPLY_IN_HEAD"; printf '%s\n' "$CFG_SNIPPET"
        emit_apply "" "$M_IW" "$M_IH"
        printf '%s\n' "$BODY_APPLY_IN_TAIL" ;;
      verify)   printf '%s\n' "$BODY_VERIFY" ;;
      schema-fp) printf '%s\n' "$BODY_SCHEMA_FP" ;;
      status)   printf '%s\n' "$BODY_STATUS" ;;
      set-weight)
        printf 'echo "=== W) 权重改为 %s（V4 回滚通道；annotate 是集群写）==="\n' "$WEIGHT"
        printf 'kubectl -n $NS annotate ingress new-api-canary-weight alb.ingress.kubernetes.io/canary-weight="%s" --overwrite\n' "$WEIGHT"
        printf 'kubectl -n $NS get ingress new-api-canary-weight -o jsonpath=%s | tr "," "\\n" | grep -E "canary|order" | sed "s/^/  /"\n' "'{.metadata.annotations}'"
        printf 'echo "  ⚠ 权重件归零不等于全量回滚：new-api-canary-header 仍会把 x-canary:1 送进 canary"\n'
        printf 'echo SET-WEIGHT-DONE\n' ;;
      teardown)
        printf 'echo "=== X) 删除两件 canary Ingress（下线灰度的唯一正解；Deployment 保留）==="\n'
        printf 'kubectl -n $NS delete ingress new-api-canary-weight new-api-canary-header --wait=false\n'
        printf 'kubectl -n $NS get ingress 2>/dev/null | sed "s/^/  /"\n'
        printf 'echo "  残留告核：ALB 侧 may 留下空 ServerGroup ⇒ 控制面 ListServerGroups 复核，别留空组"\n'
        printf 'echo TEARDOWN-DONE\n' ;;
    esac
  } > "$body"
  [[ -s "$body" ]] || die "远端 body 为空"
  say "[i] body -> $body ($(wc -l < "$body" | tr -d ' ') 行)"
  bash -n "$body" || die "body 语法检查未通过"
  local bytes est
  bytes=$(wc -c < "$body" | tr -d ' ')
  est=$(( (bytes + 6600) * 85 / 100 ))
  [[ $est -lt 24000 ]] || die "估算下发体积 ${est}B ≥ 24 KB（实测映射 0.85×(body+6.4KB)）⇒ 拆分该模式，勿硬发"
  say "[i] 估算下发体积 ≈ ${est}B / 24576B   ACKCTL_DIR=$ACKCTL_DIR"
  if [[ -n "${DRY:-}" ]]; then say "[i] DRY=1：只渲染，不下发"; return 0; fi
  say "[i] ⚠ 本模式会调用 ECS RunCommand（写类 API）"
  bash "$ACK" mnl "$body" "" 160 2>&1 | tee "$LOGDIR/remote.out"
  say "[i] 完整输出：$LOGDIR/remote.out"
}

case "$MODE" in
  --precheck)       say "STEP precheck | 集群内只读侦察（仍需 RunCommand 授权）"; build_and_run precheck ;;
  --dryrun)         say "STEP dryrun   | server-side dry-run，不落库"; build_and_run dryrun ;;
  --apply-workload) say "STEP apply    | ⚠ 生产集群写：建 canary Deployment(1 副本)+Service"; build_and_run apply-workload ;;
  --apply-ingress)  say "STEP apply    | ⚠ 生产集群写：放两件 canary Ingress（5% 权重自此生效）"; build_and_run apply-ingress ;;
  --verify)         say "STEP verify   | 集群内只读：V3/V5/V6 取证"; build_and_run verify ;;
  --schema-fp)      say "STEP schema-fp| ⚠ 写：建/删临时 psql Pod 取 schema 指纹（V5 缺口）"; build_and_run schema-fp ;;
  --status)         say "STEP status   | 只读"; build_and_run status ;;
  --set-weight)     WEIGHT="${1:-}"; [[ "$WEIGHT" =~ ^(0|5)$ ]] || die "--set-weight 只接受 0 或 5（本卡口径），收到 '$WEIGHT'";
                    say "STEP rollback | ⚠ 写：canary-weight -> $WEIGHT"; build_and_run set-weight ;;
  --teardown)       [[ "${CONFIRM:-}" = yes ]] || die "--teardown 属破坏性删除，需 CONFIRM=yes";
                    say "STEP teardown | ⚠ 删两件 canary Ingress"; build_and_run teardown ;;
  *) die "未知参数：$MODE" ;;
esac
