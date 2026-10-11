#!/usr/bin/env bash
# =============================================================================
# Day 2 · 任务 28｜新加坡 PH 备 Deployment + Secret —— 执行器
#
# 权威卡片：deploy/docs/阿里云国际站菲律宾部署_详细操作指南-v2.0.md 3606-3688
# 清单：    deploy/aliyun/ph/standby-deployment.yaml（与卡片的 5 处差异及依据写在该文件头）
# 通道：    deploy/lib/ack_remote.sh sg —— SG 集群 endpoint_public_access=false，本机无 kubeconfig，
#           所有 kubectl 经云助手在 VPC worker 内执行。
#
# 模式：
#   --precheck  只读：依赖对象 / 配额算术 / AZ 可放置性 / 跨区通路 / 同名对象冲突
#   --dryrun    清单 server-side dry-run（服务端校验，不落库）
#   --apply     ⚠ 集群写：**新建** Deployment+Service（SG ns 实测此前无任何业务对象 ⇒
#               不覆盖、不修改既有对象、不新增云资源、不产生云费用；可 --cleanup 全量回退）
#   --verify    V1 副本 AZ 分布 / V2 备站无建表权 / V3 跨区连接账目 / V4 鉴权链路
#               ⚠ V2/V3 需 psql，而业务镜像实测**无 psql**（见 02-mnl-check 取证），
#                 故按任务 30 既有做法临时建 postgres:17 探针 Pod（用完即删）
#   --status    只读现状
#   --cleanup   删本卡对象（deploy/svc/探针 Pod）——破坏性，需核准
#
# 密钥纪律：脚本与日志**不含任何凭据值**。SQL_DSN 只在集群内由 Secret 注入探针 Pod，
# 输出一律走掩码或只取键名。
# =============================================================================
set -uo pipefail
MODE="${1:---status}"
shift || true

HERE="$(cd "$(dirname "$0")" && pwd)"
ACK="$HERE/../../lib/ack_remote.sh"
MANIFEST="$HERE/../../aliyun/ph/standby-deployment.yaml"
NS=new-api
APP=new-api-ph-standby
PROBE=t28-pg
LOGDIR="$HERE/../../logs/task28_${MODE#--}_$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGDIR"
export ACKCTL_DIR="${ACKCTL_DIR:-/tmp/ackctl-sg-t28}"

say() { printf '%s\n' "$*" >&2; }
die() { printf '  [XX] %s\n' "$*" >&2; exit 1; }

[[ -f "$ACK" ]] || die "缺 $ACK"
[[ -f "$MANIFEST" ]] || die "缺 $MANIFEST"

# ---- 剥注释（RunCommand CommandContent 24 KB 上限，任务 23 实测踩过）----
SHIPPED_YAML="$(grep -vE '^[[:space:]]*#' "$MANIFEST" | grep -vE '^[[:space:]]*$')"
[[ -n "$SHIPPED_YAML" ]] || die "剥注释后清单为空"
printf '%s\n' "$SHIPPED_YAML" > "$LOGDIR/standby.shipped.yaml"

# ---- 从清单解析容量口径，供配额/AZ 算术（避免算术与清单脱节）----
read -r REP REQ_CPU REQ_MEM LIM_CPU LIM_MEM <<EOF
$(awk '
/^  replicas: /            { rep=$2 }
/^[[:space:]]*requests:/   { s="r"; next }
/^[[:space:]]*limits:/     { s="l"; next }
/^[[:space:]]*cpu:[[:space:]]/    { if (s=="r") rc=$2; else if (s=="l") lc=$2 }
/^[[:space:]]*memory:[[:space:]]/ { if (s=="r") rm=$2; else if (s=="l") lm=$2 }
END { print rep, rc, rm, lc, lm }
' "$LOGDIR/standby.shipped.yaml" | tr -d '"')
EOF
for v in REP REQ_CPU REQ_MEM LIM_CPU LIM_MEM; do
  [[ -n "${!v}" ]] || die "清单解析失败：$v 为空"
done
IMG="$(awk '/^[[:space:]]*image: /{print $2; exit}' "$LOGDIR/standby.shipped.yaml")"
[[ -n "$IMG" ]] || die "读不到 image"
case "$IMG" in
  *-vpc.*) die "备站镜像不能是 -vpc 域名（SG 跨区解析不到马尼拉 VPC 端点，实测 http=000）" ;;
esac
case "$IMG" in
  *:latest) die "禁 latest（任务 28 坑 1）" ;;
esac
say "[i] 站点/集群   = sg (ap-southeast-1)"
say "[i] image       = $IMG"
say "[i] 容量口径    = ${REP} 副本 × requests ${REQ_CPU}C/${REQ_MEM} limits ${LIM_CPU}C/${LIM_MEM}"
say "[i] 日志        = $LOGDIR"

# =============================================================================
# 远端各段
# =============================================================================
BODY="$LOGDIR/body.sh"

emit_head() {
  cat <<'HEAD'
set -u
export KUBECONFIG="${K8S:-/tmp/k8s/kubeconfig}"
NS=new-api
APP=new-api-ph-standby
PROBE=t28-pg
HEAD
  printf "T28_REP='%s' T28_REQ_CPU='%s' T28_REQ_MEM='%s' T28_LIM_CPU='%s' T28_LIM_MEM='%s' T28_IMG='%s'\n" \
    "$REP" "$REQ_CPU" "$REQ_MEM" "$LIM_CPU" "$LIM_MEM" "$IMG"
  printf 'export T28_REP T28_REQ_CPU T28_REQ_MEM T28_LIM_CPU T28_LIM_MEM T28_IMG\n'
}

emit_precheck() {
  cat <<'PRE'
echo "===== P1 依赖对象存在性（Secret/CM/SA/CA；**只出键名与计数，不出值**）====="
for o in configmap/new-api-config serviceaccount/new-api-app secret/rds-ca-apse6 secret/new-api-secrets; do
  if kubectl -n "$NS" get "$o" --no-headers >/dev/null 2>&1; then echo "  [OK]   $o 存在"; else echo "  [XX]   $o 不存在"; fi
done
kubectl -n "$NS" get secret new-api-secrets -o json 2>/dev/null > /tmp/t28_s.json
kubectl -n "$NS" get secret rds-ca-apse6 -o json 2>/dev/null > /tmp/t28_c.json
python3 - <<'PY'
import json
for f, n in (('/tmp/t28_s.json', 'new-api-secrets'), ('/tmp/t28_c.json', 'rds-ca-apse6')):
    try:
        d = json.load(open(f))
        print('   %s keys=%s' % (n, sorted((d.get('data') or {}).keys())))
    except Exception as e:
        print('   %s 读取失败 %s' % (n, e))
for k in ('SQL_DSN', 'SESSION_SECRET'):
    try:
        d = json.load(open('/tmp/t28_s.json'))
        print('   必需键 %s: %s' % (k, 'present' if (d.get('data') or {}).get(k) else 'MISSING'))
    except Exception:
        pass
PY
rm -f /tmp/t28_s.json /tmp/t28_c.json

echo "===== P2 SA 拉取凭据（PRIVATE 仓无匿名路径，任务 16 §六④）====="
kubectl -n "$NS" get sa new-api-app -o jsonpath='SA imagePullSecrets: {.imagePullSecrets[*].name}{"\n"}'
kubectl -n "$NS" get secret acr-credential-secret-aggregation -o jsonpath='helper 聚合 Secret 生成于 {.metadata.creationTimestamp}{"\n"}' 2>&1

echo "===== P3 ResourceQuota 算术（清单口径 vs 现网 hard/used）====="
kubectl -n "$NS" get resourcequota -o json 2>/dev/null > /tmp/t28_q.json
python3 - <<'PY'
import json, os, re
rep = int(os.environ['T28_REP'])
def cpu(v):
    v = str(v)
    return float(v[:-1])/1000 if v.endswith('m') else float(v)
def mem(v):
    v = str(v)
    u = {'Gi': 1024**3, 'Mi': 1024**2, 'Ki': 1024}
    for s, m in u.items():
        if v.endswith(s):
            return float(v[:-len(s)])*m
    return float(v)
rc, rm = cpu(os.environ['T28_REQ_CPU']), mem(os.environ['T28_REQ_MEM'])
lc, lm = cpu(os.environ['T28_LIM_CPU']), mem(os.environ['T28_LIM_MEM'])
d = json.load(open('/tmp/t28_q.json'))
items = d.get('items') or []
if not items:
    print('   [!!] ns 无 ResourceQuota —— 少一道护栏，但不阻塞')
for it in items:
    hard, used = it['spec']['hard'], it['status']['used']
    print('   quota/%s' % it['metadata']['name'])
    for key, need in (('requests.cpu', rep*rc), ('requests.memory', rep*rm),
                      ('limits.cpu', rep*lc), ('limits.memory', rep*lm)):
        is_cpu = 'cpu' in key
        parse = cpu if is_cpu else mem
        h = parse(hard[key])
        u = parse(used.get(key, '0'))
        div = 1 if is_cpu else 1024**3
        unit = 'C' if is_cpu else 'Gi'
        verdict = 'OK' if u/div + need/div <= h/div else 'FORBIDDEN（会被配额拒绝）'
        print('     %-16s used=%.2f + 本卡 %.2f = %.2f / hard %.2f  %s → %s'
              % (key, u/div, need/div, (u+need)/div, h/div, unit, verdict))
PY
rm -f /tmp/t28_q.json

echo "===== P4 AZ 可放置性（topologySpread DoNotSchedule + $T28_REP 副本 ⇒ 需 ≥2 个可调度 AZ）====="
kubectl get nodes -o custom-columns='NAME:.metadata.name,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,CPU_alloc:.status.allocatable.cpu,MEM_alloc:.status.allocatable.memory,UNSCHED:.spec.unschedulable'
ZC=$(kubectl get nodes -o jsonpath='{.items[*].metadata.labels.topology\.kubernetes\.io/zone}' | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')
echo "   可用区去重数 = $ZC（≥2 才能让 2 副本各占一区；=1 则第二个 Pod 必 Pending）"
echo "   每节点已请求（Allocated resources）："
for n in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  printf '   node/%s ' "$n"
  kubectl describe node "$n" 2>/dev/null | awk '/Allocated resources:/{f=1;next} f&&/^  (cpu|memory) /{printf "%s=%s ", $1, $2} f&&/Events:/{exit}'
  echo
done

echo "===== P5 跨区通路（节点侧）：镜像公网域名 + 马尼拉 RDS 公网串 6432 ====="
getent hosts "$(printf '%s' "$T28_IMG" | cut -d/ -f1)" 2>&1 | head -2
curl -s -o /dev/null -w '   registry /v2/ http=%{http_code} connect=%{time_connect}s\n' --max-time 10 "https://$(printf '%s' "$T28_IMG" | cut -d/ -f1)/v2/" 2>&1
RDSH=pgm-5tstdhko64x2c01wpub.pgsql.ap-southeast-6.rds.aliyuncs.com
timeout 6 bash -c "exec 3<>/dev/tcp/$RDSH/6432 && echo '   6432 OPEN'" 2>&1 || echo "   [XX] 6432 不通"

echo "===== P6 同名对象冲突（本卡只新建，若已存在则说明有人先动手，需比对而不是覆盖）====="
kubectl -n "$NS" get deploy,svc "$APP" 2>&1 | head -6
echo "===== P7 SG ALB/Ingress 现状（任务 25 范畴；决定 V4 能否当场做）====="
kubectl -n "$NS" get ing 2>&1 | head -4
kubectl get albconfig 2>&1 | head -4
echo "   IngressClass："; kubectl get ingressclass -o custom-columns='NAME:.metadata.name,CTRL:.spec.controller,PARAMS:.spec.parameters.name,AGE:.metadata.creationTimestamp' 2>&1 | head -4
echo PRECHECK-DONE
PRE
}

emit_dryrun() {
  printf 'cat <<MANEOF | kubectl apply --dry-run=server -f -\n%s\nMANEOF\n' "$SHIPPED_YAML"
  printf 'echo DRYRUN-DONE\n'
}

emit_apply() {
  printf 'cat <<MANEOF | kubectl apply -f -\n%s\nMANEOF\n' "$SHIPPED_YAML"
  cat <<'APP'
echo "== 等待就绪（最多 240 s，含跨区冷拉 ~11 s）=="
for i in $(seq 1 48); do
  R=$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  D=$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
  [ "${R:-0}" = "$T28_REP" ] && { echo "  poll $i ready=$R available=$D → 达标"; break; }
  [ $((i % 6)) -eq 0 ] && { echo "  poll $i ready=${R:-0}/${T28_REP}"; kubectl -n "$NS" get pod -l app=new-api -o wide --no-headers 2>&1 | cut -c1-150; }
  sleep 5
done
echo "== 未就绪则贴调度/拉取事件 =="
R=$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if [ "${R:-0}" != "$T28_REP" ]; then
  kubectl -n "$NS" get pod -l app=new-api -o wide 2>&1 | head -6
  kubectl -n "$NS" get events --sort-by=.lastTimestamp 2>&1 | tail -15
  kubectl -n "$NS" logs deploy/"$APP" --tail=25 2>&1 | sed 's/^/  log| /'
else
  echo "  已 $R/$T28_REP Ready，跳过诊断"
fi
echo APPLY-DONE
APP
}

emit_verify() {
  cat <<'VER'
echo "===== V1 副本分布：2 副本分属两可用区（卡片 §12 验收项）====="
kubectl -n "$NS" get deploy "$APP" -o jsonpath='spec.replicas={.spec.replicas} ready={.status.readyReplicas} available={.status.availableReplicas}{"\n"}'
kubectl -n "$NS" get pod -l app=new-api -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,PHASE:.status.phase,READY:.status.conditions[?(@.type=="Ready")].status,IP:.status.podIP,AGE:.metadata.creationTimestamp' 2>&1
echo "   每 Pod 的 AZ（由 node label 反查）："
for p in $(kubectl -n "$NS" get pod -l app=new-api -o jsonpath='{.items[*].metadata.name}'); do
  N=$(kubectl -n "$NS" get pod "$p" -o jsonpath='{.spec.nodeName}')
  Z=$(kubectl get node "$N" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null)
  echo "     $p → node=$N zone=$Z"
done
ZC=$(for p in $(kubectl -n "$NS" get pod -l app=new-api -o jsonpath='{.items[*].metadata.name}'); do
       N=$(kubectl -n "$NS" get pod "$p" -o jsonpath='{.spec.nodeName}')
       kubectl get node "$N" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}'
     done | sort -u | wc -l | tr -d ' ')
echo "   去重 AZ 数 = $ZC（期望 2）"

echo "===== V1b 容器 env 生效值（证明清单 env 覆盖了 ConfigMap；只取白名单键）====="
kubectl -n "$NS" exec deploy/"$APP" -c new-api -- sh -c \
  'for k in NODE_TYPE GOMAXPROCS SQL_MAX_OPEN_CONNS SQL_MAX_IDLE_CONNS SYNC_FREQUENCY MEMORY_CACHE_ENABLED TZ; do printf "   %s=%s\n" "$k" "$(printenv $k || echo UNSET)"; done; printf "   SESSION_SECRET_len=%s (只取长度)\n" "$(printenv SESSION_SECRET | wc -c | tr -d " ")"; ls -l /etc/ssl/rds/ca.crt 2>&1 | sed "s/^/   ca /"' 2>&1 | head -12
echo "   应用启动日志的缓存/Redis 口径："
kubectl -n "$NS" logs deploy/"$APP" --tail=200 2>&1 | grep -iE "redis|memory.?cache|migrat" | head -6
echo "   （备站 slave 不应出现 AutoMigrate/DDL 记录；上面 grep 命中 migrat 需人工判定）"

echo "===== V1c Service 通路 + 鉴权中间件响应（任务 25 Ingress 后端的先决条件）====="
kubectl -n "$NS" get svc "$APP" -o wide 2>&1 | head -3
kubectl -n "$NS" get endpoints "$APP" -o wide 2>&1 | head -3
POD1=$(kubectl -n "$NS" get pod -l app=new-api -o jsonpath='{.items[0].metadata.name}')
echo "   /api/status（不鉴权，只证应用活着 + Service 通）："
kubectl -n "$NS" exec "$POD1" -c new-api -- sh -c \
  'wget -qO- --timeout=6 http://new-api-ph-standby/api/status 2>&1 | head -c 160; echo' 2>&1
echo "   带无效 token 打鉴权接口（期望 401 而不是 500；无凭据泄露风险）："
for path in /api/user/self /api/log/self; do
  printf '     %s -> ' "$path"
  kubectl -n "$NS" exec "$POD1" -c new-api -- sh -c \
    "wget -S -qO- --header='Authorization: Bearer t28-invalid-token' --timeout=8 http://127.0.0.1:3000$path 2>&1 | grep -E 'HTTP/' | head -1" 2>&1
done

echo "===== V2/V3 需要 psql ⇒ 建临时探针 Pod（业务镜像实测无 psql）====="
kubectl -n "$NS" delete pod "$PROBE" --ignore-not-found --wait=true --timeout=90s >/dev/null 2>&1
cat <<'PROBEYAML' | kubectl -n "$NS" apply -f - 2>&1 | head -2
apiVersion: v1
kind: Pod
metadata:
  name: t28-pg
  namespace: new-api
  labels: {app: t28-probe}
spec:
  restartPolicy: Never
  serviceAccountName: new-api-app
  containers:
  - name: pg
    image: postgres:17
    command: ["sh","-c","sleep 900"]
    env:
    - name: SQL_DSN
      valueFrom: {secretKeyRef: {name: new-api-secrets, key: SQL_DSN}}
    resources:
      requests: {cpu: "100m", memory: "128Mi"}
      limits:   {cpu: "1",    memory: "512Mi"}
    volumeMounts:
    - {name: rds-ca, mountPath: /etc/ssl/rds, readOnly: true}
  volumes:
  - name: rds-ca
    secret: {secretName: rds-ca-apse6}
PROBEYAML
for i in $(seq 1 40); do
  PH=$(kubectl -n "$NS" get pod "$PROBE" -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$PH" = "Running" ] && break
  sleep 4
done
echo "   probe phase=$(kubectl -n "$NS" get pod "$PROBE" -o jsonpath='{.status.phase}' 2>/dev/null)"
[ "$PH" = "Running" ] || { kubectl -n "$NS" describe pod "$PROBE" 2>&1 | tail -12; echo "   [XX] 探针未起来，V2/V3 无法做"; }

if [ "$PH" = "Running" ]; then
kubectl -n "$NS" exec -i "$PROBE" -- bash -c 'set -u
echo "--- V2 备地域无建表权（事务内建表并回滚；期望 permission denied）---"
psql "$SQL_DSN" -c "begin; create table public._t28_probe(id int); rollback;" 2>&1 | head -4
psql "$SQL_DSN" -c "drop table if exists public._t28_probe;" 2>&1 | head -2
echo "--- V2b 连的是马尼拉主库？（直接证据不可得：inet_server_addr() 需 superuser，实测回 NULL）---"
echo "    ⇒ 等价证据口径沿用任务 30 §V1：库名 + 角色 + 版本 + **实例启动时刻**"
psql "$SQL_DSN" -Atc "select current_user, current_database(), split_part(version(),'"'"' '"'"',2)" 2>&1 | head -2
psql "$SQL_DSN" -Atc "select pg_postmaster_start_time()" 2>&1 | head -2
echo "    （任务 30 留档：马尼拉实例启动 2026-09-29 15:59:16+08、server_version 17.10、库 newapi）"
echo "--- V2c TLS 实际生效 ---"
psql "$SQL_DSN" -Atc "select ssl from pg_stat_ssl where pid = pg_backend_pid()" 2>&1 | head -2
echo "--- V3 连接账目：newapi_sg 会话（卡片判据 ≤ 150×2=300）---"
psql "$SQL_DSN" -Atc "select count(*) from pg_stat_activity where usename='"'"'newapi_sg'"'"'" 2>&1 | head -2
psql "$SQL_DSN" -Atc "select state, count(*) from pg_stat_activity where usename='"'"'newapi_sg'"'"' group by 1 order by 2 desc" 2>&1 | head -6
echo "--- V3b 归因：client_addr 经 RDS 侧代理全是 127.0.0.1（**不能**按 Pod IP 归因）⇒ 用启动时刻差分 ---"
psql "$SQL_DSN" -Atc "select client_addr, count(*) from pg_stat_activity where usename='"'"'newapi_sg'"'"' group by 1 order by 2 desc" 2>&1 | head -4
psql "$SQL_DSN" -Atc "select date_trunc('"'"'minute'"'"', backend_start), count(*) from pg_stat_activity where usename='"'"'newapi_sg'"'"' group by 1 order by 1" 2>&1 | head -6
echo "--- V3c 池参数可见性（实测该端点 SHOW 不到 ⇒ 池口径只能引用任务 41 配置侧，不能靠 SHOW 取证）---"
for p in pool_mode default_pool_size max_client_conn; do
  printf "    show %s -> " "$p"; psql "$SQL_DSN" -Atc "show $p" 2>&1 | head -1
done
echo V23-DONE' 2>&1 | tail -40
fi

echo "===== V4 会话/令牌互通（卡片判据：主站 token 打备站 200）====="
echo "   卡片要求走 SG ALB DNS；本机与集群现状："
kubectl get albconfig 2>&1 | head -3
kubectl -n "$NS" get ing 2>&1 | head -3
echo "   [BLOCKED] SG 侧无 ALB/Ingress（任务 25 未落地）⇒ V4 判据**当场不可执行**。"
echo "   已做的替代取证（不等同于 V4）：V2c/V2b 证跨区 TLS 读到马尼拉主库、"
echo "   V3b 用 backend_start 差分把会话归因到本次备站启动、V1c 证 Service 通路与 401 鉴权响应。"

echo "===== 探针 Pod 释放 ====="
kubectl -n "$NS" delete pod "$PROBE" --ignore-not-found --wait=true --timeout=60s 2>&1
kubectl -n "$NS" get pod --no-headers 2>&1 | head -6
echo VERIFY-DONE
VER
}

emit_status() {
  cat <<'ST'
echo "== deploy/svc/endpoints =="
kubectl -n "$NS" get deploy,svc,endpoints "$APP" -o wide 2>&1 | head -8
echo "== pods =="
kubectl -n "$NS" get pod -l app=new-api -o wide 2>&1 | head -6
echo "== recent events =="
kubectl -n "$NS" get events --sort-by=.lastTimestamp 2>&1 | tail -8
echo STATUS-DONE
ST
}

emit_cleanup() {
  cat <<'CL'
echo "== 删本卡对象（Deployment/Service/探针 Pod），保留 Secret/CM/SA/CA =="
kubectl -n "$NS" delete deploy "$APP" --ignore-not-found --wait=true --timeout=180s 2>&1
kubectl -n "$NS" delete svc "$APP" --ignore-not-found 2>&1
kubectl -n "$NS" delete pod "$PROBE" --ignore-not-found 2>&1
echo "清理后："
kubectl -n "$NS" get deploy,svc,pod --no-headers 2>&1 | head -8
echo CLEANUP-DONE
CL
}

build_and_run() {
  {
    emit_head
    case "$1" in
      precheck) emit_precheck ;;
      dryrun)   emit_dryrun ;;
      apply)    emit_apply ;;
      verify)   emit_verify ;;
      status)   emit_status ;;
      cleanup)  emit_cleanup ;;
    esac
  } > "$BODY"
  chmod 600 "$BODY"
  say "[i] body = $BODY ($(wc -c < "$BODY" | tr -d ' ') B)"
  bash "$ACK" sg "$BODY" "" 120 2>&1 | tee "$LOGDIR/remote.out"
  say "[i] 完整输出：$LOGDIR/remote.out"
}

case "$MODE" in
  --precheck) say "STEP precheck | 只读侦察：依赖/配额/AZ/跨区通路/同名冲突"; build_and_run precheck ;;
  --dryrun)   say "STEP dryrun   | server-side dry-run（服务端校验，不落库）"; build_and_run dryrun ;;
  --apply)    say "STEP apply    | ⚠ 集群写：新建备站 Deployment + Service（可 --cleanup 回退）"; build_and_run apply ;;
  --verify)   say "STEP verify   | V1/V2/V3 + V4 现状判定（建临时探针 Pod，用完即删）"; build_and_run verify ;;
  --status)   say "STEP status   | 只读"; build_and_run status ;;
  --cleanup)  say "STEP cleanup  | ⚠ 破坏性：删本卡 deploy/svc/探针 Pod（需核准）"; build_and_run cleanup ;;
  *) die "未知参数：$MODE（--precheck | --dryrun | --apply | --verify | --status | --cleanup）" ;;
esac
