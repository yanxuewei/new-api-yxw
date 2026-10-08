#!/usr/bin/env bash
# =============================================================================
# Day 2 · 任务 23｜stable Deployment（4 副本 + PDB + HPA + 反亲和）—— 马尼拉
# -----------------------------------------------------------------------------
# 权威卡片：deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md:3419-3553
# 清单：    deploy/aliyun/ph/stable-deployment.yaml
# 执行通道：deploy/ack_remote.sh（集群 endpoint_public_access=false，本机无 kubeconfig，
#           全部 kubectl 经云助手在 VPC 节点内执行；ACKCTL_DIR 独立，避免与并行任务串台）
#
# 与卡片的差异只有清单里写明的两条（PDB 沿用现网 70%、清单保留 spec.replicas），
# 其余按卡片逐条实装。checksum/config 不在清单里写死，由本脚本在**节点侧**用现值渲染：
#   sha256(sorted-json(new-api-config.data))[:12] ⇒ ConfigMap 一改，下次 apply 就触发滚动。
#
# 卡片四条验收的执行边界（重要）：
#   V1 副本与 AZ 分布            → --verify，只读，已执行
#   V2 零停机滚动                → --verify + ROLL=1 才真的 rollout restart
#                                  （maxUnavailable:0 / maxSurge:1 下不缩容量，但仍是生产写操作，需登记）
#   V3 PDB（kubectl drain 节点） → **默认不执行**。drain 在 §0 破坏性操作清单里，
#                                  需项目负责人远程核准留痕；--verify 只打印命令与判据。
#   V4 HPA 触发（stress Pod）    → **默认不执行**。会在生产 ns 起高压 Pod 并可能连锁扩容 +
#                                  节点池扩到 max 8（费用），需核准；--verify 只读 HPA 指标通路
#                                  （metrics-server + target 是否可读，无 FailedGetResourceMetric）。
#
# 用法：
#   bash deploy/task23_stable.sh --precheck    # 只读侦察：容量/配额/依赖组件 + 镜像与探针路径预检
#   bash deploy/task23_stable.sh --dryrun      # 清单 server-side dry-run（校验字段合法性，不落库）
#   bash deploy/task23_stable.sh --apply       # 建 stable Deployment/Service/HPA（PDB 无变化即 no-op）
#   bash deploy/task23_stable.sh --verify      # V1/V2 验收 + HPA/PDB/配额只读取证
#   ROLL=1 bash deploy/task23_stable.sh --verify   # 额外做一次零停机滚动（生产写，需登记）
#   bash deploy/task23_stable.sh --status      # 只读现状
#   bash deploy/task23_stable.sh --wire-alb    # 把 Ingress/new-api-verify 后端指向 new-api-stable
#   TARGET_SVC=new-api-master bash deploy/task23_stable.sh --wire-alb   # 回退到任务 19 占位后端
#   bash deploy/task23_stable.sh --cleanup     # 删本卡资源（保留现网既有 PDB，见注释）
#   IMAGE=<registry>/<ns>/<repo>:<tag> bash deploy/task23_stable.sh --apply   # 覆盖镜像
#
# ⚠ --apply / --verify(ROLL=1) / --wire-alb 是生产集群写操作，按变更窗口登记后再跑。
# =============================================================================
set -uo pipefail
MODE="${1:---status}"
shift || true

HERE="$(cd "$(dirname "$0")" && pwd)"
ACK="$HERE/ack_remote.sh"
MANIFEST="$HERE/aliyun/ph/stable-deployment.yaml"
LOGDIR="$HERE/logs/task23_${MODE#--}_$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGDIR"
export ACKCTL_DIR="${ACKCTL_DIR:-/tmp/ackctl-mnl-t23}"

say() { printf '%s\n' "$*" >&2; }
die() { printf '  [XX] %s\n' "$*" >&2; exit 1; }

[[ -f "$ACK" ]] || die "缺 $ACK"
[[ -f "$MANIFEST" ]] || die "缺 $MANIFEST"
[[ -x "$HOME/.workbuddy/binaries/aliyun-cli/aliyun" ]] || command -v aliyun >/dev/null 2>&1 || die "未找到 aliyun CLI"
export PATH="$HOME/.workbuddy/binaries/aliyun-cli:$PATH"

# ---- 渲染清单：仅替换镜像；清单与日志都不含密钥 ----
RENDERED="$LOGDIR/stable-deployment.rendered.yaml"
if [[ -n "${IMAGE:-}" ]]; then
  sed "s#^\([[:space:]]*image: \)acr-newapi-mnl-registry.*#\1${IMAGE}#" "$MANIFEST" > "$RENDERED" || die "镜像替换失败"
  say "[i] 镜像覆盖 → $IMAGE"
else
  cp "$MANIFEST" "$RENDERED"
fi
IMG="$(awk '/^[[:space:]]*image: /{print $2; exit}' "$RENDERED")"
[[ -n "$IMG" ]] || die "渲染后读不到 image"
[[ "$IMG" == *-vpc.* ]] || say "[warn] 镜像域名不是 -vpc 内网端点（任务 18 已切内网，跨区/应急才用公网）"
# 注释只属于仓库文档，不上云：清单正文 9364B 里 5.6KB 是整行注释，而 RunCommand 的
# CommandContent 上限是 24 KB（b64 后），带上注释会直接 CmdContent.ExceedLimit（实测 2026-10-05 23:11）。
SHIPPED_YAML="$(grep -vE '^[[:space:]]*#' "$RENDERED" | grep -vE '^[[:space:]]*$')"
[[ -n "$SHIPPED_YAML" ]] || die "剥离注释后清单为空"
printf '%s\n' "$SHIPPED_YAML" > "$LOGDIR/stable-deployment.shipped.yaml"

# 从清单解析容量口径，供配额算术使用（避免算术与清单脱节）
# 容忍缩进：本清单只有 Deployment 段含 requests/limits 一对，按 key 名匹配即可。
read -r REP MINR MAXR REQ_CPU REQ_MEM LIM_CPU LIM_MEM <<EOF
$(awk '
/^  replicas: /      { rep=$2 }
/^  minReplicas: /   { minr=$2 }
/^  maxReplicas: /   { maxr=$2 }
/^[[:space:]]*requests:/ { s="r"; next }
/^[[:space:]]*limits:/   { s="l"; next }
/^[[:space:]]*cpu:[[:space:]]/    { if (s=="r") rc=$2; else if (s=="l") lc=$2 }
/^[[:space:]]*memory:[[:space:]]/ { if (s=="r") rm=$2; else if (s=="l") lm=$2 }
END { print rep, minr, maxr, rc, rm, lc, lm }
' "$RENDERED" | tr -d '"')
EOF
for v in REP MINR MAXR REQ_CPU REQ_MEM LIM_CPU LIM_MEM; do
  [[ -n "${!v}" ]] || die "清单解析失败：$v 为空（改过 resources/replicas 的缩进？）"
done
M_YAML="$SHIPPED_YAML"
say "[i] image       = $IMG"
say "[i] 容量口径     = ${REP} 副本 × requests ${REQ_CPU}C/${REQ_MEM} limits ${LIM_CPU}C/${LIM_MEM}；HPA ${MINR}→${MAXR}"
say "[i] 日志        = $LOGDIR"

# =============================================================================
# 远端公共函数（单引号 heredoc ⇒ 原样落到节点；节点侧 bash 执行）
# =============================================================================
read -r -d '' COMMON <<'COMMON_EOF' || true
set -u
NS=new-api
DEPLOY=new-api-stable
PGPOD=t23-pgcli
PREFLIGHT=t23-preflight

purge_tmp() {
  kubectl -n $NS delete pod $PGPOD $PREFLIGHT --ignore-not-found --wait=false >/dev/null 2>&1
  rm -f /tmp/t23_pods.json /tmp/t23_nodes.json
}

# schema 指纹：tables|cols_md5|idx_md5（与任务 18 同口径，用于证明 slave 启动零 DDL）
fp() {
  kubectl -n $NS exec -i $PGPOD -- sh -c 'psql "$SQL_DSN_MIGRATE" -Atq -F"|" -f -' <<'SQL'
select
  (select count(*) from information_schema.tables
     where table_schema='public' and table_type='BASE TABLE'),
  (select md5(string_agg(t, chr(10))) from (
     select table_name||'.'||column_name||':'||data_type||':'||coalesce(character_maximum_length::text,'-') as t
       from information_schema.columns where table_schema='public' order by t) c),
  (select md5(string_agg(t, chr(10))) from (
     select indexname||'='||indexdef as t from pg_indexes where schemaname='public' order by t) i);
SQL
}

ensure_pgcli() {
  kubectl -n $NS delete pod $PGPOD --ignore-not-found --wait=true >/dev/null 2>&1
  cat <<'PGEOMF' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: t23-pgcli
  namespace: new-api
  labels: { app: t23-pgcli, project: new-api, site: ph-mnl }
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 900
  terminationGracePeriodSeconds: 0
  containers:
    - name: psql
      image: postgres:17-alpine
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 600"]
      # 本 ns 有 ResourceQuota 的 requests/limits 硬约束，临时 Pod 也必须声明
      resources:
        requests: { cpu: 100m, memory: 128Mi }
        limits:   { cpu: 200m, memory: 256Mi }
      envFrom:
        - secretRef: { name: new-api-secrets }
PGEOMF
  kubectl -n $NS wait --for=condition=Ready pod/$PGPOD --timeout=180s >/dev/null 2>&1 || return 1
  kubectl -n $NS exec $PGPOD -- sh -c 'psql "$SQL_DSN_MIGRATE" -Atqc "select 1"' >/dev/null 2>&1
}

wait_rollout() { # $1=deploy $2=轮数（每轮 5s）
  __i=0
  while [ "$__i" -lt "${2:-60}" ]; do
    if kubectl -n $NS rollout status deploy/"$1" --timeout=8s >/dev/null 2>&1; then return 0; fi
    sleep 5
    __i=$((__i + 1))
  done
  return 1
}

# stable Pod 的 node/AZ 落点分布（反亲和验收口径：6a 与 6b 各 >=2）
dist_stable() {
  kubectl -n $NS get pods -l app=new-api -o json > /tmp/t23_pods.json 2>/dev/null
  kubectl get nodes -o json > /tmp/t23_nodes.json 2>/dev/null
  python3 - <<'PY'
import collections
import json

try:
    pods = json.load(open("/tmp/t23_pods.json"))
    nodes = json.load(open("/tmp/t23_nodes.json"))
except Exception as e:
    print("    [XX] 读取 pods/nodes 失败: %r" % e)
    raise SystemExit
zone = {n["metadata"]["name"]: (n["metadata"].get("labels") or {}).get("topology.kubernetes.io/zone", "?")
        for n in nodes.get("items") or []}
per_node, per_zone, pending = collections.Counter(), collections.Counter(), []
for p in pods.get("items") or []:
    labels = p["metadata"].get("labels") or {}
    if labels.get("track") != "stable":
        continue
    phase = (p.get("status") or {}).get("phase") or "?"
    if phase != "Running":
        pending.append((p["metadata"]["name"], phase))
        continue
    n = (p.get("spec") or {}).get("nodeName") or "?"
    per_node[n] += 1
    per_zone[zone.get(n, "?")] += 1
for z, c in sorted(per_zone.items()):
    print("    AZ %-18s Running pods = %d" % (z, c))
for n, c in sorted(per_node.items()):
    print("    node %-40s zone=%-18s pods=%d" % (n, zone.get(n, "?"), c))
for name, phase in pending:
    print("    未 Running：%s (%s)" % (name, phase))
if not per_zone and not pending:
    print("    (集群内没有 stable Pod)")
PY
}

# 每节点剩余可请求容量（口径：allocatable - 已请求；已请求含 Pending 已调度 Pod）
# free_capacity：本 ns 之外还要看全集群占用，故取 -A
free_capacity() {
  kubectl get pods -A -o json > /tmp/t23_pods.json 2>/dev/null
  kubectl get nodes -o json > /tmp/t23_nodes.json 2>/dev/null
  python3 - <<'PY'
import json
import os


def n2v(x):
    if x in (None, ""):
        return 0.0
    x = str(x)
    if x.endswith("m"):
        return float(x[:-1]) / 1000
    for suf, f in (("Gi", 1024.0), ("Mi", 1.0), ("Ki", 1 / 1024)):
        if x.endswith(suf):
            return float(x[:-len(suf)]) * f
    for suf, f in (("G", 1000 ** 3 / 1048576), ("M", 1e6 / 1048576)):
        if x.endswith(suf):
            return float(x[:-len(suf)]) * f
    try:
        return float(x) / 1048576
    except ValueError:
        return 0.0


pods = json.load(open("/tmp/t23_pods.json"))
nodes = json.load(open("/tmp/t23_nodes.json"))
agg = {}
for p in pods.get("items") or []:
    if (p.get("status") or {}).get("phase") not in ("Running", "Pending"):
        continue
    nn = (p.get("spec") or {}).get("nodeName")
    if not nn:
        continue
    cs = (p["spec"].get("containers") or []) + (p["spec"].get("initContainers") or [])
    for c in cs:
        q = (c.get("resources") or {}).get("requests") or {}
        a = agg.setdefault(nn, [0.0, 0.0])
        a[0] += n2v(q.get("cpu"))
        a[1] += n2v(q.get("memory"))
for n in nodes.get("items") or []:
    nn = n["metadata"]["name"]
    al = (n.get("status") or {}).get("allocatable") or {}
    cpu, mem = n2v(al.get("cpu")), n2v(al.get("memory"))
    used = agg.get(nn, [0.0, 0.0])
    z = (n["metadata"].get("labels") or {}).get("topology.kubernetes.io/zone", "?")
    req_cpu = n2v(os.environ.get("T23_REQ_CPU", "2"))
    req_mem = n2v(os.environ.get("T23_REQ_MEM", "4Gi"))
    fit = min(int((cpu - used[0]) // req_cpu), int((mem - used[1]) // req_mem))
    print("    %-30s %-18s cpu free %5.2f/%5.2f | mem free %6.0f/%6.0f MiB | 还能放 %d 个本卡 Pod"
          % (nn, z, cpu - used[0], cpu, mem - used[1], mem, fit))
PY
}

# 配额算术：当前 used + 本卡 N 副本增量 vs hard；并算 maxReplicas 能不能顶到
quota_math() {
  kubectl -n $NS get resourcequota -o json > /tmp/t23_quota.json 2>/dev/null
  CUR=$(kubectl -n $NS get deploy $DEPLOY -o jsonpath='{.spec.replicas}' 2>/dev/null)
  T23_CUR="${CUR:-0}" python3 - <<'PY'
import json, os


def n2v(x):
    x = str(x)
    if x.endswith("m"):
        return float(x[:-1]) / 1000
    for suf, f in (("Gi", 1024.0), ("Mi", 1.0), ("Ki", 1 / 1024)):
        if x.endswith(suf):
            return float(x[:-len(suf)]) * f
    return float(x)


d = json.load(open("/tmp/t23_quota.json"))
rep, maxr = int(os.environ["T23_REP"]), int(os.environ["T23_MAXR"])
cur = int(os.environ["T23_CUR"])
per_pod = {
    "requests.cpu": n2v(os.environ["T23_REQ_CPU"]),
    "requests.memory": n2v(os.environ["T23_REQ_MEM"]),
    "limits.cpu": n2v(os.environ["T23_LIM_CPU"]),
    "limits.memory": n2v(os.environ["T23_LIM_MEM"]),
}
for it in d.get("items") or []:
    st = it.get("status") or {}
    hard, used = st.get("hard") or {}, st.get("used") or {}
    print("    quota %s（replicas 现值=%d，本卡口径=%d，maxReplicas=%d）" % (it["metadata"]["name"], cur, rep, maxr))
    for k in ("requests.cpu", "requests.memory", "limits.cpu", "limits.memory"):
        if k not in hard:
            continue
        h, u = n2v(hard[k]), n2v(used.get(k, "0"))
        unit = "核" if "cpu" in k else "Mi"
        p = per_pod[k]
        other = max(u - p * cur, 0.0)
        at_max = other + p * maxr
        fit = int((h - other) // p)
        print("      %-16s hard %8.2f%s  used %7.2f（stable %d 副本=%6.2f，其他=%6.2f）"
              % (k, h, unit, u, cur, p * cur, other))
        print("      %-16s 扩到 maxReplicas=%d 合计 %8.2f%s  %s ｜ 配额天花板 %d 副本%s"
              % ("", maxr, at_max, unit, "[OK]" if at_max <= h else "[XX 顶不到]",
                 fit, "" if at_max <= h else " ⇒ 抬配额或降 maxReplicas，二选一"))
PY
rm -f /tmp/t23_quota.json
}
COMMON_EOF

# =============================================================================
# --precheck：只读侦察 + 清单 server-side dry-run + 镜像/探针预检
# =============================================================================
read -r -d '' PRE_A <<'S_EOF' || true
echo "=== P1) 节点：AZ / allocatable / 是否不可调度 ==="
kubectl get nodes -o custom-columns='NAME:.metadata.name,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,UNSCHED:.spec.unschedulable,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory' 2>/dev/null | sed 's/^/  /'
echo "=== P2) 每节点剩余可请求容量（本卡每 Pod requests 由清单给出）==="
free_capacity
echo "=== P3) HPA 依赖：autoscaling/policy API + metrics-server ==="
printf '  autoscaling/v2 = %s\n' "$(kubectl api-versions 2>/dev/null | grep -c '^autoscaling/v2$')"
printf '  policy/v1      = %s\n' "$(kubectl api-versions 2>/dev/null | grep -c '^policy/v1$')"
printf '  metrics-server deploy = %s\n' "$(kubectl -n kube-system get deploy metrics-server -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || echo 不存在)"
echo "  --- kubectl top nodes（metrics-server 通了才有输出；HPA 取不到指标就是卡片「FailedGetResourceMetric」）---"
kubectl top nodes 2>&1 | head -8 | sed 's/^/    /'
echo "=== P4) $NS 现状（任务 19 占位资源 / 既有 PDB / 是否已有 stable）==="
kubectl -n $NS get deploy,svc,endpoints,pdb,hpa,ing,sa -o wide 2>/dev/null | sed 's/^/  /' | cut -c1-190
printf '  既有 deploy/%s = %s（期望：无 ⇒ 本次为新建）\n' "$DEPLOY" "$(kubectl -n $NS get deploy $DEPLOY -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 无)"
echo "  既有 PDB 明细（清单用 70%，见文件头差异①）："
kubectl -n $NS get pdb -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
for it in d.get("items") or []:
    s=it.get("spec") or {}; st=it.get("status") or {}
    print("    %-22s minAvailable=%s selector=%s currentHealthy=%s allowedDisruptions=%s created=%s"
          % (it["metadata"]["name"], s.get("minAvailable"), json.dumps(s.get("selector")),
             st.get("currentHealthy"), st.get("disruptionsAllowed"),
             it["metadata"].get("creationTimestamp")))
'
echo "=== P5) 任务 17 前置：ConfigMap / Secret 键名（不回显值）==="
kubectl -n $NS get cm new-api-config -o json 2>/dev/null | python3 -c '
import json,sys
d=(json.load(sys.stdin) or {}).get("data") or {}
for k in sorted(d): print("    CM %-26s = %s" % (k, d[k]))
'
printf '  ConfigMap NODE_TYPE = %s（红线：全集群只有 master 允许非 slave）\n' "$(kubectl -n $NS get cm new-api-config -o jsonpath='{.data.NODE_TYPE}' 2>/dev/null)"
kubectl -n $NS get secret new-api-secrets -o json 2>/dev/null | python3 -c '
import base64,json,re,sys
d=(json.load(sys.stdin) or {}).get("data") or {}
print("    Secret keys=%d: %s" % (len(d), sorted(d)))
for k in ("SQL_DSN","LOG_SQL_DSN"):
    v=base64.b64decode(d.get(k,"")).decode("utf-8","replace") if d.get(k) else ""
    m=re.match(r"^[a-z0-9+]+://([^@/:]+):", v)
    h=re.search(r"@([^@/:]+):([0-9]+)", v)
    print("    %-14s user=%s host=%s port=%s" % (k, m.group(1) if m else "-", h.group(1) if h else "-", h.group(2) if h else "-"))
print("    stable 走 envFrom 取 SQL_DSN ⇒ 账号必须是 DML 的 newapi，不是 newapi_migrate")
'
echo "=== P6) ResourceQuota 与本卡容量算术 ==="
S_EOF

read -r -d '' BODY_DRY <<'S_EOF' || true
set -u
NS=new-api
echo "=== D1) 清单 server-side dry-run（服务端校验，不落库；等价 kubectl apply --dry-run=server）==="
echo "    校验覆盖：HPA autoscaling/v2 字段、PDB 百分比口径、探针端口名、topologySpreadConstraints 结构"
CFG_SUM=$(kubectl -n $NS get cm new-api-config -o json 2>/dev/null | python3 -c '
import hashlib,json,sys
d=(json.load(sys.stdin) or {}).get("data") or {}
print(hashlib.sha256(json.dumps(d, sort_keys=True).encode("utf-8")).hexdigest()[:12])
' 2>/dev/null)
if [ -z "$CFG_SUM" ]; then
  echo "  [XX] 读不到 new-api-config ⇒ 无法渲染 checksum，中止（任务 17 未落地？）"
  exit 1
fi
printf '  checksum/config 渲染值 = %s\n' "$CFG_SUM"
echo "  dry-run 结果（created/configured/unchanged 都是服务端校验通过的证据）："
S_EOF

read -r -d '' PRE_B <<'S_EOF' || true
echo "=== P7) 镜像可拉性（清单里的 image + SA new-api-app，与 stable Pod 同路径）==="
kubectl -n $NS delete pod $PREFLIGHT --ignore-not-found --wait=true >/dev/null 2>&1
cat <<PREF_EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: t23-preflight
  namespace: new-api
  labels: { app: t23-preflight, project: new-api, site: ph-mnl }
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 600
  terminationGracePeriodSeconds: 0
  serviceAccountName: new-api-app
  containers:
    - name: probe
      image: ${APP_IMAGE}
      imagePullPolicy: IfNotPresent
      resources:
        requests: { cpu: 100m, memory: 128Mi }
        limits:   { cpu: 200m, memory: 256Mi }
      command: ["bash", "-c"]
      args:
        - |
          echo "    PULL_OK 镜像容器已拉起"
          ls -l /new-api | sed 's/^/      /'
PREF_EOF
__i=0; RC=1; PH=""
while [ "$__i" -lt 40 ]; do
  PH=$(kubectl -n $NS get pod $PREFLIGHT -o jsonpath='{.status.phase}' 2>/dev/null)
  case "$PH" in Succeeded) RC=0; break ;; Failed) RC=2; break ;; esac
  sleep 5; __i=$((__i + 1))
done
printf '  preflight phase=%s（轮询 %d 次）RC=%s\n' "${PH:-无}" "$__i" "$RC"
kubectl -n $NS logs $PREFLIGHT 2>&1 | sed 's/^/  /' | head -4
if [ "$RC" != "0" ]; then
  echo "  [XX] 镜像未拉起，拉取状态与事件："
  kubectl -n $NS get pod $PREFLIGHT -o jsonpath='{range .status.containerStatuses[*]}waiting={.state.waiting.reason}{"\n"}{end}' 2>/dev/null | sed 's/^/    /'
  kubectl -n $NS get events --field-selector involvedObject.name=$PREFLIGHT --sort-by=.lastTimestamp 2>/dev/null | tail -6 | sed 's/^/    /'
fi
kubectl -n $NS delete pod $PREFLIGHT --ignore-not-found --wait=false >/dev/null 2>&1
echo "=== P8) 探针路径存活（同镜像已在跑的 master Pod）==="
POD=$(kubectl -n $NS get pod -l app=new-api-migrate -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "${POD:-}" ]; then
  kubectl -n $NS exec "$POD" -- sh -c 'wget -q -T 5 -O /tmp/s.json http://127.0.0.1:3000/api/status && echo "    [OK] /api/status 200（探针路径可用）" || echo "    [XX] /api/status 取不到"; head -c 120 /tmp/s.json 2>/dev/null; echo' 2>&1 | sed 's/^/  /'
else
  echo "  [warn] 无 master Pod，跳过（stable 的探针路径未经同镜像验证）"
fi
echo "=== P9) 近 30 分钟事件（调度/配额/拉取异常）==="
kubectl -n $NS get events --sort-by=.lastTimestamp 2>/dev/null | tail -15 | sed 's/^/  /'
echo PRECHECK-DONE
S_EOF

read -r -d '' DRY_TAIL <<'S_EOF' || true
echo "=== D2) dry-run 不持久化：现状对象应与改写前一致 ==="
kubectl -n $NS get deploy,svc,hpa,pdb -o wide 2>/dev/null | sed 's/^/  /' | cut -c1-190
echo DRYRUN-DONE
S_EOF

# =============================================================================
# --apply
# =============================================================================
read -r -d '' APPLY_A <<'S_EOF' || true
echo "=== A1) apply 前红线与容量断言 ==="
kubectl -n $NS get pods -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin); bad=[]
for p in d.get("items") or []:
    for c in (p["spec"].get("containers") or []):
        for e in (c.get("env") or []):
            if e.get("name")=="NODE_TYPE" and e.get("value") not in (None,"slave"):
                bad.append((p["metadata"]["name"], e.get("value")))
print("    显式非 slave 的既有容器：%s（期望仅 new-api-master*）" % (sorted(set(bad)) or "无"))
'
printf '    ConfigMap NODE_TYPE=%s，stable 容器显式 NODE_TYPE=slave\n' "$(kubectl -n $NS get cm new-api-config -o jsonpath='{.data.NODE_TYPE}' 2>/dev/null)"
if [ "$(kubectl -n $NS get cm new-api-config -o jsonpath='{.data.NODE_TYPE}' 2>/dev/null)" = "slave" ]; then
  echo "    [OK] 继承口径为 slave ⇒ 本卡 4 副本不会变成第二个 master 去跑迁移"
else
  echo "    [XX] ConfigMap NODE_TYPE 不是 slave，中止 apply 前先核对任务 17"
fi
echo "    目标落点核对（反亲和 DoNotSchedule 要求每 AZ 至少能放 replicas/2 个）："
free_capacity
echo "=== A2) schema 指纹基线 FP0（用于证明 stable 启动零 DDL）==="
if ensure_pgcli; then FP0="$(fp)"; printf '    FP0 = %s\n' "$FP0"; else echo "    [warn] psql 临时 Pod 未就绪 ⇒ 跳过指纹比对"; FP0=""; fi
echo "=== A3) apply（checksum 用集群现值渲染）==="
CFG_SUM=$(kubectl -n $NS get cm new-api-config -o json 2>/dev/null | python3 -c '
import hashlib,json,sys
d=(json.load(sys.stdin) or {}).get("data") or {}
print(hashlib.sha256(json.dumps(d, sort_keys=True).encode("utf-8")).hexdigest()[:12])
' 2>/dev/null)
[ -n "$CFG_SUM" ] || { echo "  [XX] 读不到 ConfigMap，中止"; exit 1; }
printf '  checksum/config -> %s\n' "$CFG_SUM"
S_EOF

read -r -d '' POST_APPLY <<'S_EOF' || true
echo "=== A4) 等待 4 副本就绪（startupProbe 上限 150s/Pod，滚动口径 maxSurge 1）==="
if wait_rollout $DEPLOY 60; then
  echo "  [OK] rollout 完成"
else
  echo "  [XX] 未在 300s 内就绪，诊断："
  kubectl -n $NS get pods -l app=new-api -o wide 2>/dev/null | sed 's/^/    /'
  kubectl -n $NS get events --sort-by=.lastTimestamp 2>/dev/null | grep -Ei 'failed|pending|unschedul|quota|back-off' | tail -12 | sed 's/^/    /'
fi
echo "=== A5) V1 副本与 AZ 分布 ==="
kubectl -n $NS get deploy $DEPLOY -o jsonpath='  readyReplicas={.status.readyReplicas} replicas={.status.replicas} updated={.status.updatedReplicas}{"\n"}' 2>/dev/null
dist_stable
echo "=== A6) Service / Endpoints ==="
kubectl -n $NS get svc $DEPLOY -o wide 2>/dev/null | sed 's/^/  /'
kubectl -n $NS get endpoints $DEPLOY -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
sub=(d.get("subsets") or [])
addrs=[a.get("ip") for s in sub for a in (s.get("addresses") or [])]
notr=[a.get("ip") for s in sub for a in (s.get("notReadyAddresses") or [])]
print("    ready=%d %s" % (len(addrs), addrs))
print("    notReady=%d %s（未就绪不进 ALB 后端）" % (len(notr), notr))
' 2>/dev/null || echo "    (endpoints 尚未生成)"
echo "=== A7) HPA：指标通路（卡片 V4 只读的替代证据）==="
kubectl -n $NS get hpa $DEPLOY -o jsonpath='  name={.metadata.name} desired={.status.desiredReplicas} current={.status.currentReplicas}{"\n"}' 2>/dev/null || kubectl -n $NS get hpa 2>/dev/null | sed 's/^/  /'
kubectl -n $NS get hpa hpa-new-api-stable -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
for m in (d.get("status") or {}).get("currentMetrics") or []:
    print("    current metric %s" % json.dumps(m.get("resource") or m))
print("    target %s" % json.dumps((d.get("spec") or {}).get("metrics")))
' 2>/dev/null
echo "    conditions（期望无 ScalingLimited/AbleToGetMetrics=False）："
kubectl -n $NS get hpa hpa-new-api-stable -o jsonpath='{range .status.conditions[*]}    {type}={status} reason={reason} msg={message}{"\n"}{end}' 2>/dev/null
kubectl -n $NS describe hpa hpa-new-api-stable 2>/dev/null | sed -n '/Events:/,$p' | head -8 | sed 's/^/      /'
echo "=== A8) PDB（现网 70% 口径）==="
kubectl -n $NS get pdb pdb-new-api-stable 2>/dev/null | sed 's/^/  /'
printf '  disruptionsAllowed = %s（4 副本 + 70%% ⇒ ceil(2.8)=3 健康下限 ⇒ 期望 1）\n' \
  "$(kubectl -n $NS get pdb pdb-new-api-stable -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null)"
echo "=== A9) stable Pod 启动期日志（期望：无 DDL、无 error；slave 在 model/main.go:215/262 提前返回）==="
SP=$(kubectl -n $NS get pod -l app=new-api,track=stable -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "${SP:-}" ]; then
  printf '  Pod = %s\n' "$SP"
  printf '  实际数据库账号 = %s（期望 newapi，非 newapi_migrate）\n' \
    "$(kubectl -n $NS exec "$SP" -- sh -c 'printf "%s" "$SQL_DSN" | sed -nE "s#^[a-z0-9+]+://([^@/:]+):.*#\1#p"' 2>/dev/null)"
  printf '  GOMAXPROCS = %s\n' "$(kubectl -n $NS exec "$SP" -- sh -c 'printf "%s" "$GOMAXPROCS"' 2>/dev/null)"
  printf '  容器内可见核数 nproc = %s（坑 2 的对照：不钉 GOMAXPROCS 就会按宿主核数起 worker）\n' "$(kubectl -n $NS exec "$SP" -- sh -c 'nproc' 2>/dev/null)"
  printf '  DDL 行数（PG 口径）= %s ｜  ERROR/FATAL 行数 = %s\n' \
    "$(kubectl -n $NS logs "$SP" --tail=20000 2>/dev/null | grep -Ec 'ALTER TABLE "|CREATE TABLE "|CREATE (UNIQUE )?INDEX .* ON "|DROP (TABLE|COLUMN|INDEX) "')" \
    "$(kubectl -n $NS logs "$SP" --tail=20000 2>/dev/null | grep -Eci 'fatal|panic|\[ERROR\]')"
  kubectl -n $NS logs "$SP" --tail=20000 2>/dev/null | grep -Ei 'migrat|fatal|panic|error' | head -6 | cut -c1-150 | sed 's/^/    /'
fi
echo "=== A10) schema 指纹 FP1 与基线比对 ==="
if [ -n "$FP0" ] && ensure_pgcli; then
  FP1="$(fp)"; printf '    FP1 = %s\n' "$FP1"
  if [ "$FP0" = "$FP1" ]; then echo "    [OK] 逐字相同 ⇒ stable 4 副本启动对 PG 零 schema 变更（权限边界成立）"; else echo "    [XX] 出现漂移 ⇒ slave 在发 DDL，立即停止并核对 NODE_TYPE"; fi
else
  echo "    [warn] 基线或复检缺失，未做漂移比对"
fi
echo "=== A11) 配额算术（含 maxReplicas 能否顶到）==="
quota_math
purge_tmp
echo APPLY-DONE
S_EOF

# =============================================================================
# --verify（V1/V2 只读；V3 drain、V4 stress 仅打印，不执行）
# =============================================================================
read -r -d '' BODY_VERIFY <<'S_EOF' || true
echo "=== V1) 副本数与 AZ 分布（卡片期望：6a 与 6b 各 >=2）==="
kubectl -n $NS get deploy $DEPLOY -o jsonpath='  spec.replicas={.spec.replicas} ready={.status.readyReplicas} updated={.status.updatedReplicas} unavailable={.status.unavailableReplicas}{"\n"}' 2>/dev/null
kubectl -n $NS get pods -l app=new-api,track=stable -o wide 2>/dev/null | sed 's/^/  /'
dist_stable
echo "  重启次数（期望全 0；非 0 说明探针或 OOM 有问题）："
kubectl -n $NS get pods -l app=new-api,track=stable -o jsonpath='{range .items[*]}    {.metadata.name} restarts={range .status.containerStatuses[*]}{.restartCount} state={.state}{"\n"}{end}{end}' 2>/dev/null
echo "=== V2) 零停机滚动 ==="
if [ "${ROLL:-0}" = "1" ]; then
  echo "  ROLL=1 ⇒ 下发 rollout restart（maxUnavailable:0 / maxSurge:1 ⇒ 容量不减）"
  kubectl -n $NS rollout restart deploy/$DEPLOY >/dev/null && echo "  restart 已下发"
  if wait_rollout $DEPLOY 60; then echo "  [OK] 滚动完成；容量是否全程不减见下面的事件序列"; else echo "  [XX] 滚动未在 300s 内完成"; fi
else
  echo "  未执行（默认）。要做零停机滚动实测：ROLL=1 bash deploy/task23_stable.sh --verify"
  echo "  本轮只读取证（滚动历史 + 当前可用性）："
  kubectl -n $NS rollout history deploy/$DEPLOY 2>/dev/null | sed 's/^/    /'
  kubectl -n $NS get deploy $DEPLOY -o jsonpath='    ready={.status.readyReplicas}/{.spec.replicas}  unavailable={.status.unavailableReplicas}{"\n"}' 2>/dev/null
fi
echo "  Service 端到端（借同 ns 的 master Pod 走 svc DNS ⇒ 证明 endpoints 真能转发）："
MP=$(kubectl -n $NS get pod -l app=new-api-migrate -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
SVC_IP=$(kubectl -n $NS get svc $DEPLOY -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
if [ -n "${MP:-}" ] && [ -n "${SVC_IP:-}" ]; then
  for i in 1 2 3; do
    kubectl -n $NS exec "$MP" -- sh -c "wget -q -T 5 -O- http://$SVC_IP/api/status >/dev/null 2>&1 && echo \"    GET #$i -> 200\" || echo \"    GET #$i -> 失败\"" 2>/dev/null
  done
  kubectl -n $NS exec "$MP" -- sh -c "for i in 1 2 3 4; do wget -q -T 5 -O- http://$DEPLOY.$NS.svc.cluster.local/api/status >/dev/null 2>&1 && printf '    via-cluster-dns #%s ok; ' \$i; done; echo" 2>/dev/null
else
  echo "    (缺 master Pod 或 svc 未就绪)"
fi
echo "  容量不减的可核查证据（maxUnavailable:0/maxSurge:1 的机械含义 = 先建后杀，看事件顺序）："
kubectl -n $NS get rs -l app=new-api -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
for it in d.get("items") or []:
    s=it.get("status") or {}
    print("    rs/%-32s desired=%s current=%s ready=%s available=%s labels-track=%s"
          % (it["metadata"]["name"], it["spec"].get("replicas"), s.get("replicas"),
             s.get("readyReplicas"), s.get("availableReplicas"),
             (it["metadata"].get("labels") or {}).get("track")))
' 2>/dev/null
kubectl -n $NS get events --sort-by=.lastTimestamp -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
rows=[]
for it in d.get("items") or []:
    obj=((it.get("involvedObject") or {}).get("name") or "")
    if "new-api-stable" not in obj: continue
    if it.get("reason") not in ("ScaledUpReplicaSet","ScalingReplicaSet","SuccessfulCreate","SuccessfulDelete","Killing","Created","Started","Completed"): continue
    rows.append((it.get("lastTimestamp") or "", it.get("reason"), obj, (it.get("message") or "")[:110]))
for r in rows[-18:]:
    print("    %-20s %-20s %-26s %s" % r)
' 2>/dev/null
echo "=== V3) PDB —— 需项目负责人核准后才做 drain，本脚本不执行 ==="
kubectl -n $NS get pdb pdb-new-api-stable 2>/dev/null | sed 's/^/  /'
printf '  disruptionsAllowed=%s（4 副本时期望 1）\n' "$(kubectl -n $NS get pdb pdb-new-api-stable -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null)"
echo "  待核准后人工执行的卡片命令与判据："
echo "    kubectl drain <NODE> --ignore-daemonsets --delete-emptydir-data --force"
echo "    期望：仅 1 个 stable Pod 被驱逐，其余 3 个保持 Running；驱逐数受 PDB 限制（allowed=1）"
echo "    前置：节点池 max_instances=8 有空闲容量，否则 drain 会卡在 Pending（卡片「drain 卡住」）"
echo "=== V4) HPA 触发 —— 需核准（stress Pod 会连锁扩容并可能触发节点池扩到 8 台，产生费用），本脚本不执行 ==="
echo "  只读替代证据（指标通路 + 当前值）："
kubectl top nodes 2>&1 | head -6 | sed 's/^/    /'
kubectl -n $NS get hpa hpa-new-api-stable 2>/dev/null | sed 's/^/    /'
kubectl -n $NS get hpa hpa-new-api-stable -o jsonpath='{range .status.conditions[*]}    cond {type}={status} reason={reason}{"\n"}{end}' 2>/dev/null
kubectl -n $NS describe hpa hpa-new-api-stable 2>/dev/null | sed -n '/Events:/,$p' | head -8 | sed 's/^/    /'
printf '  当前 requests.cpu 口径：单 Pod 2C ⇒ 65%% 阈值即 1.3C/Pod 触发扩容（卡片坑 1，分母是 request 不是 limit）\n'
echo "  待核准后人工执行的卡片命令与判据："
echo "    kubectl -n new-api run cpu-burn --image=polinux/stress --rm -it --restart=Never -- stress --cpu 8 --timeout 300s"
echo "    期望：hpa TARGETS>65%、REPLICAS 上升；注意 limits.cpu 配额天花板（见 --precheck P6 算术）"
echo "=== V5) 反亲和实际生效核对 ==="
printf '  topologySpreadConstraints：%s\n' "$(kubectl -n $NS get deploy $DEPLOY -o jsonpath='{.spec.template.spec.topologySpreadConstraints}' 2>/dev/null | cut -c1-260)"
echo "  Pending Pod（DoNotSchedule 摆不平就会 Pending）："
kubectl -n $NS get pods -l app=new-api --field-selector=status.phase=Pending 2>/dev/null | sed 's/^/    /'
echo "  节点 cordon 状态（有不可调度节点会让 AZ 硬约束卡住）："
kubectl get nodes -o custom-columns='NAME:.metadata.name,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,UNSCHED:.spec.unschedulable' 2>/dev/null | sed 's/^/    /'
echo "=== V6) 配额算术（maxReplicas 天花板）==="
quota_math
echo VERIFY-DONE
S_EOF

read -r -d '' BODY_STATUS <<'S_EOF' || true
set -u
NS=new-api
echo "=== stable Deployment / Pod / Service / HPA / PDB / Ingress ==="
kubectl -n $NS get deploy,svc,endpoints,hpa,pdb,ing -o wide 2>/dev/null | sed 's/^/  /' | cut -c1-190
kubectl -n $NS get pods -l app=new-api -o wide 2>/dev/null | sed 's/^/  /'
echo "=== 落点分布 ==="
dist_stable
echo "=== HPA 摘要 ==="
kubectl -n $NS get hpa 2>/dev/null | sed 's/^/  /'
echo "=== 最近事件 ==="
kubectl -n $NS get events --sort-by=.lastTimestamp 2>/dev/null | tail -12 | sed 's/^/  /'
echo STATUS-DONE
S_EOF

# =============================================================================
# --wire-alb：任务 19 的 V2 健康检查验收（当时被推迟到本卡）
#   把 Ingress/new-api-verify 的后端从占位 svc/new-api-master（0 endpoints）
#   换到 svc/new-api-stable，使 ALB 后端组真的拿到 Pod，从而能验健康检查。
#   可逆：TARGET_SVC=new-api-master 再跑一次即回退。占位资源本体仍留给任务 23 之后清理。
# =============================================================================
read -r -d '' BODY_WIRE <<'S_EOF' || true
set -u
NS=new-api
TARGET="${TARGET_SVC:-new-api-stable}"
echo "=== W1) 改写前 ==="
kubectl -n $NS get ingress -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
for it in d.get("items") or []:
    rules=(it["spec"].get("rules") or [])
    print("    ingress/%s rules=%d" % (it["metadata"]["name"], len(rules)))
    for r in rules:
        for p in ((r.get("http") or {}).get("paths") or []):
            b=(p.get("backend") or {}).get("service") or {}
            print("      host=%s path=%s -> svc/%s:%s" % (r.get("host"), p.get("path"), b.get("name"), (b.get("port") or {}).get("number")))
    print("      ALB hostname=%s" % ((it.get("status") or {}).get("loadBalancer",{}).get("ingress",[{}])[0].get("hostname","-")))
'
N=$(kubectl -n $NS get ingress new-api-verify -o jsonpath='{.spec.rules}' 2>/dev/null | python3 -c 'import json,sys; print(len(json.loads(sys.stdin.read() or "[]")))')
PATHS=$(kubectl -n $NS get ingress new-api-verify -o jsonpath='{.spec.rules[0].http.paths}' 2>/dev/null | python3 -c 'import json,sys; print(len(json.loads(sys.stdin.read() or "[]")))')
if [ "${N:-0}" != "1" ] || [ "${PATHS:-0}" != "1" ]; then
  echo "  [XX] new-api-verify 不是「1 rule / 1 path」结构（rule=$N path=$PATHS），JSON Patch 下标会打偏 ⇒ 中止"
  exit 1
fi
if [ "$TARGET" = "new-api-stable" ]; then
  RDY=$(kubectl -n $NS get deploy new-api-stable -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  printf '  改写目标 = new-api-stable，当前 readyReplicas=%s\n' "${RDY:-0}"
  if [ "${RDY:-0}" = "0" ]; then echo "  [XX] stable 尚无就绪 Pod，不切（切了就是全站 503）"; exit 1; fi
fi
echo "=== W2) 改写后端 svc/new-api-master -> svc/$TARGET ==="
kubectl -n $NS patch ingress new-api-verify --type=json \
  -p='[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/name","value":"'"$TARGET"'"}]'
echo "=== W3) 改写后 + ALB 后端同步事件 ==="
kubectl -n $NS get ingress new-api-verify -o jsonpath='{.spec.rules[0].http.paths[0].backend.service.name}{"\n"}' 2>/dev/null
kubectl -n $NS get endpoints $TARGET -o jsonpath='  endpoints/'$TARGET' ready={range .subsets[*].addresses[*]}{.ip} {end}{"\n"}' 2>/dev/null
sleep 20
kubectl -n $NS get events --field-selector involvedObject.name=new-api-verify --sort-by=.lastTimestamp 2>/dev/null | tail -8 | sed 's/^/  /'
ALB=$(kubectl -n $NS get ingress new-api-verify -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
HOST=$(kubectl -n $NS get ingress new-api-verify -o jsonpath='{.spec.rules[0].host}' 2>/dev/null)
if [ -n "${ALB:-}" ]; then
  printf '  从节点内直连 ALB（Host: %s）：\n' "$HOST"
  for p in /api/status /; do
    CODE=$(curl -sS -m 8 -o /dev/null -w '%{http_code}' -H "Host: $HOST" "http://$ALB$p" 2>/dev/null)
    printf '    GET %-14s -> %s\n' "$p" "${CODE:-无响应}"
  done
  echo "  判据（任务 19 卡片 V2 健康检查）：/api/status 返回 200 ⇒ ALB 后端拿到 Pod 且健康检查放行"
fi
echo WIRE-DONE
S_EOF

read -r -d '' BODY_CLEANUP <<'S_EOF' || true
set -u
NS=new-api
echo "  删除本卡创建的资源：deploy/new-api-stable、svc/new-api-stable、hpa/hpa-new-api-stable"
echo "  **保留** pdb-new-api-stable：现网 2026-09-30 08:54 就存在（早于本卡执行），非本卡产物"
kubectl -n $NS delete deploy new-api-stable --ignore-not-found
kubectl -n $NS delete svc new-api-stable --ignore-not-found
kubectl -n $NS delete hpa hpa-new-api-stable --ignore-not-found
kubectl -n $NS delete pod t23-pgcli t23-preflight --ignore-not-found --wait=false
rm -f /tmp/t23_pods.json /tmp/t23_nodes.json
echo "  清理后："
kubectl -n $NS get deploy,svc,endpoints,hpa,pdb,ing 2>/dev/null | sed 's/^/    /' | cut -c1-190
echo CLEANUP-DONE
S_EOF

# =============================================================================
# 拼装并下发
# =============================================================================
BODY="$LOGDIR/body.sh"

# 配额算术要用的口径以字面量传给节点侧（来自本脚本对清单的解析，不靠节点读清单）
emit_env() {
  printf "T23_REP='%s' T23_MINR='%s' T23_MAXR='%s' T23_REQ_CPU='%s' T23_REQ_MEM='%s' T23_LIM_CPU='%s' T23_LIM_MEM='%s'\n" \
    "$REP" "$MINR" "$MAXR" "$REQ_CPU" "$REQ_MEM" "$LIM_CPU" "$LIM_MEM"
  printf 'export T23_REP T23_MINR T23_MAXR T23_REQ_CPU T23_REQ_MEM T23_LIM_CPU T23_LIM_MEM\n'
}

# checksum 用集群现值渲染后再交 kubectl：清单里不写死，ConfigMap 一改就触发滚动
emit_manifest() { # $1 = kubectl apply 的额外参数（如 --dry-run=server）
  # \$: 本地不展开（set -u 下 CFG_SUM 本地不存在），落到节点侧由那里的双引号展开成现值
  printf "cat <<'MANEOF' | sed \"s/__CONFIG_CHECKSUM__/\$CFG_SUM/\" | kubectl apply %s -f -\n" "$1"
  printf '%s\n' "$M_YAML"
  printf 'MANEOF\n'
}

build_and_run() {
  {
    case "$1" in
      precheck)
        emit_env
        printf "APP_IMAGE='%s'\n" "$IMG"
        printf '%s\n' "$COMMON"
        printf '%s\n' "$PRE_A"
        printf 'quota_math\n'
        printf '%s\n' "$PRE_B"
        ;;
      dryrun)
        emit_env
        printf '%s\n' "$BODY_DRY"
        emit_manifest "--dry-run=server"
        printf '%s\n' "$DRY_TAIL"
        ;;
      apply)
        emit_env
        printf '%s\n' "$COMMON"
        printf '%s\n' "$APPLY_A"
        emit_manifest ""
        printf '%s\n' "$POST_APPLY"
        ;;
      verify)
        emit_env
        # ROLL 只在本地 shell 存在，节点侧读不到 ⇒ 必须以字面量写进 body
        printf "ROLL='%s'\n" "${ROLL:-0}"
        printf '%s\n' "$COMMON"
        printf '%s\n' "$BODY_VERIFY"
        ;;
      status)
        printf '%s\n' "$COMMON"
        printf '%s\n' "$BODY_STATUS"
        ;;
      wire-alb)
        printf "TARGET_SVC='%s'\n" "${TARGET_SVC:-new-api-stable}"
        printf '%s\n' "$BODY_WIRE"
        ;;
      cleanup)
        printf '%s\n' "$BODY_CLEANUP"
        ;;
    esac
  } > "$BODY"
  [[ -s "$BODY" ]] || die "远端 body 为空"

  say "[i] body -> $BODY ($(wc -l < "$BODY" | tr -d ' ') 行)"
  bash -n "$BODY" || die "body 语法检查未通过"
  # RunCommand 的 CommandContent 上限 24 KB（base64 后）。实测映射：
  #   outer_b64 ≈ (body + kubeconfig 6.4 KB + 前言) × 0.85 ⇒ 23592B body → 26.6 KB → CmdContent.ExceedLimit
  BODY_BYTES=$(wc -c < "$BODY" | tr -d ' ')
  EST=$(( (BODY_BYTES + 6600) * 85 / 100 ))
  [[ $EST -lt 24000 ]] || die "body 估算下发体积 ${EST}B ≥ 24 KB 上限（实测映射 0.85×(body+6.4KB)）⇒ 拆分该模式，勿硬发"
  say "[i] 估算下发体积 ≈ ${EST}B / 24576B"
  if [[ -n "${DRY:-}" ]]; then
    say "[i] DRY=1：只渲染，不下发（可 shellcheck -s bash $BODY 复核）"
    return 0
  fi
  bash "$ACK" mnl "$BODY" "" 160 2>&1 | tee "$LOGDIR/remote.out"
  say ""
  say "[i] 完整输出：$LOGDIR/remote.out"
}

case "$MODE" in
  --precheck) say "STEP precheck | 只读侦察：容量/配额/依赖组件 + 镜像与探针路径预检"; build_and_run precheck ;;
  --dryrun)   say "STEP dryrun   | 清单 server-side dry-run（服务端校验，不落库）"; build_and_run dryrun ;;
  --apply)    say "STEP apply    | ⚠ 生产集群写：建 4 副本 stable + Service + HPA"; build_and_run apply ;;
  --verify)   say "STEP verify   | V1/V2 只读取证；V3 drain / V4 stress 需核准，本脚本不执行"; build_and_run verify ;;
  --status)   say "STEP status   | 只读"; build_and_run status ;;
  --wire-alb) say "STEP wire-alb | ⚠ 改 Ingress 后端指向（可逆：TARGET_SVC=new-api-master）"; build_and_run wire-alb ;;
  --cleanup)  say "STEP cleanup  | 删本卡 deploy/svc/hpa（保留既有 PDB）"; build_and_run cleanup ;;
  *) die "未知参数：$MODE（--precheck|--dryrun|--apply|--verify|--status|--wire-alb|--cleanup）" ;;
esac
