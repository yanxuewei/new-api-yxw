#!/usr/bin/env bash
# =============================================================================
# Day 2 · 任务 18｜master Deployment 跑通 AutoMigrate + 连跑两次验幂等
# -----------------------------------------------------------------------------
# 权威卡片：deploy/docs/阿里云国际站菲律宾部署_详细操作指南-v2.0.md:2958-3061（任务 18，2026-10-05 已按实测改写过）
# 清单：    deploy/aliyun/ph/master-deployment.yaml
# 执行通道：deploy/lib/ack_remote.sh（两集群 endpoint_public_access=false，本机无 kubeconfig，
#           全部 kubectl 经云助手在 VPC 节点内执行；ACKCTL_DIR 独立，避免与并行任务串台）
#
# 幂等的判定口径（与卡片的差异，先讲清）：
#   卡片用 `logs | grep -Ec "ALTER TABLE|CREATE TABLE|CREATE INDEX"` 计数。本仓 GORM logger
#   固定 LogLevel=Warn（model/gorm_logger.go:42），默认慢查询阈值 200ms ⇒ 首启的快速 DDL 不入日志，
#   该 grep 恒为 0，会被误读成"迁移没跑"。所以双口径互证：
#     主口径 = public schema 指纹（表数 + 列集合 md5 + 索引定义 md5），两次冷启动必须逐字相同；
#     副口径 = DDL 日志计数，靠 master 专属 env SQL_SLOW_THRESHOLD_MS=1 强制逐条打印 SQL。
#   ⚠ 副口径的四个残留盲区（2026-10-05 实测，前三个都踩过）：
#     ① GORM 只在 elapsed > 阈值时打印，<1ms 的语句仍不落日志 ⇒ "DDL 计数=0" 可能只是没打；
#     ② Pod Ready 早于日志库段 ⇒ 立即计数会抓到假 0（靠 wait_log_settled 规避）；
#     ③ 主库 PG 与日志库 CK 的 DDL 混在同一条 grep 里 ⇒ 日志库每次启动固定重放 3 条幂等 DDL，
#        永远不可能"0"。⇒ 幂等结论只认主口径（PG schema 指纹）；副口径按 PG/CK 分列。
#     ④ 计数走 kubectl logs --tail=20000，而 1 ms 阈值下约 174~218 行/分 ⇒ Pod 存活 ~90 min 后
#        启动段被挤出窗口，PG=0 又会变成假 0。--verify 的 V2 段打印总行数做覆盖度自检；
#        长跑场景改查 SLS 容器 stdout，或先回退 SQL_SLOW_THRESHOLD_MS。
#     实测：二启 PG 0 / CK 3 且 FPA==FPB 逐字相同；首启在改用拆分口径前测得 173 行（未拆分，
#     其中日志库固定 3 条是否已计入取决于当时的计数时刻 ⇒ 首启的 PG 数为 170~173，不影响结论）。
#
# 用法：
#   bash deploy/tasks/task18/master_migrate.sh --precheck  # 临时 Pod：镜像可拉性 / 端口连通 / 权限边界 / 迁移前指纹
#   bash deploy/tasks/task18/master_migrate.sh --apply     # 建 master Deployment，看首轮 AutoMigrate，记 FP1
#   bash deploy/tasks/task18/master_migrate.sh --verify    # 第 2 次冷启动，指纹比对 + 卡片全部验收项
#   bash deploy/tasks/task18/master_migrate.sh --status    # 只读现状
#   bash deploy/tasks/task18/master_migrate.sh --cleanup   # 删 master Deployment 与本卡临时 Pod
#   IMAGE=<registry>/<ns>/<repo>:<tag> bash deploy/tasks/task18/master_migrate.sh --apply   # 覆盖镜像
#
# ⚠ --apply / --verify 会对生产 RDS 的 public schema 执行 DDL（AutoMigrate）。
#   按 §0 红线：破坏性操作需项目负责人远程核准留痕，核准不到 = 不动手。
# 实现说明：远端 body 一律 POSIX sh + python3（云助手不保证以 bash 启动）。
#   body 由「本地展开段（APP_IMAGE / 清单正文）+ 全引号静态段」拼出，避免二次转义地狱。
# =============================================================================
set -uo pipefail
MODE="${1:---status}"
shift || true

HERE="$(cd "$(dirname "$0")" && pwd)"
ACK="$HERE/../../lib/ack_remote.sh"
MANIFEST="$HERE/../../aliyun/ph/master-deployment.yaml"
LOGDIR="$HERE/../../logs/task18_${MODE#--}_$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGDIR"
export ACKCTL_DIR="${ACKCTL_DIR:-/tmp/ackctl-mnl-t18}"

say() { printf '%s\n' "$*" >&2; }
die() { printf '  [XX] %s\n' "$*" >&2; exit 1; }

[[ -f "$ACK" ]] || die "缺 $ACK"
[[ -f "$MANIFEST" ]] || die "缺 $MANIFEST"
[[ -x "$HOME/.workbuddy/binaries/aliyun-cli/aliyun" ]] || command -v aliyun >/dev/null 2>&1 || die "未找到 aliyun CLI"
export PATH="$HOME/.workbuddy/binaries/aliyun-cli:$PATH"

# ---- 渲染清单：仅替换镜像；清单与日志都不含密钥 ----
RENDERED="$LOGDIR/master-deployment.rendered.yaml"
if [[ -n "${IMAGE:-}" ]]; then
  sed "s#^\([[:space:]]*image: \)acr-newapi-mnl-registry.*#\1${IMAGE}#" "$MANIFEST" > "$RENDERED" || die "镜像替换失败"
  say "[i] 镜像覆盖 → $IMAGE"
else
  cp "$MANIFEST" "$RENDERED"
fi
IMG="$(awk '/^[[:space:]]*image: /{print $2; exit}' "$RENDERED")"
[[ -n "$IMG" ]] || die "渲染后读不到 image"
M_YAML="$(cat "$RENDERED")"
say "[i] image  = $IMG"
say "[i] 日志   = $LOGDIR"

# =============================================================================
# 远端公共函数（单引号 heredoc ⇒ 原样落到节点）
# =============================================================================
read -r -d '' COMMON <<'COMMON_EOF' || true
set -u
NS=new-api
PGPOD=t18-pgcli
PREFLIGHT=t18-preflight

purge_tmp() {
  kubectl -n $NS delete pod $PGPOD --ignore-not-found --wait=false >/dev/null 2>&1
}

# schema 指纹：tables|cols_md5|idx_md5（SQL 走 stdin，避免嵌套引号）
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

# DDL 计数分两个口径，**必须分开**（2026-10-05 实测教训）：
#   主库 PG：GORM 输出的语句一律带双引号标识符（CREATE TABLE "x" / ALTER TABLE "x" /
#            CREATE INDEX ... ON "x"），首启那 170~173 行在这里；第二次冷启动必须为 0。
#   日志库 CK：migrateLOGDB() 每次启动都重放固定 3 条幂等 DDL
#            （model/main.go:395-407 → CREATE TABLE IF NOT EXISTS audit_logs / logs
#              + :468 ALTER TABLE logs MODIFY TTL），标识符不带引号。
#            ⇒ 卡片原口径"第二次不得有任一 DDL 命中 grep"在 CK 上永远不成立；
#              把它当成 AutoMigrate 非幂等去"修表"就会改错东西。
ddl_count_pg() {
  kubectl -n $NS logs "$1" --tail=20000 2>/dev/null \
    | grep -Ec 'ALTER TABLE "|CREATE TABLE "|CREATE (UNIQUE )?INDEX .* ON "|DROP (TABLE|COLUMN|INDEX) "'
}

ddl_count_ck() {
  kubectl -n $NS logs "$1" --tail=20000 2>/dev/null \
    | grep -Ec 'CREATE TABLE IF NOT EXISTS [a-z_]+ \(|ALTER TABLE [a-z_]+ MODIFY TTL'
}

ddl_count() { ddl_count_pg "$1"; }

err_count() {
  kubectl -n $NS logs "$1" --tail=20000 2>/dev/null | grep -Eci 'fatal|panic|\[ERROR\]'
}

# Pod Ready ≠ 迁移日志写完。readiness 在启动早期就满足，而 CK 日志库的 3 条 DDL 在其之后才落盘；
# 立刻计数会抓到"假 0"（2026-10-05 任务 18 --verify 首测就中招：显示 0，稍后同一 Pod 现 3 条）。
# 等日志跑到日志库段（CK 口径 >0）或最多 12×5s 再计数。
wait_log_settled() {
  __j=0
  while [ "$__j" -lt 12 ]; do
    [ "$(ddl_count_ck "$1")" -gt 0 ] && return 0
    sleep 5
    __j=$((__j + 1))
  done
  return 1
}

ensure_pgcli() {
  kubectl -n $NS delete pod $PGPOD --ignore-not-found --wait=true >/dev/null 2>&1
  cat <<'PGEOMF' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: t18-pgcli
  namespace: new-api
  labels: { app: t18-pgcli, project: new-api, site: ph-mnl }
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 900
  terminationGracePeriodSeconds: 0
  containers:
    - name: psql
      image: postgres:17-alpine
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 900"]
      # 本 ns 有 new-api-quota（hard 要求每个 Pod 显式声明 requests/limits），临时 Pod 也必须带
      resources:
        requests: { cpu: 100m, memory: 128Mi }
        limits:   { cpu: 200m, memory: 256Mi }
      envFrom:
        - secretRef: { name: new-api-secrets }
PGEOMF
  kubectl -n $NS wait --for=condition=Ready pod/$PGPOD --timeout=240s >/dev/null 2>&1 || return 1
  kubectl -n $NS exec $PGPOD -- sh -c 'psql "$SQL_DSN_MIGRATE" -Atqc "select 1"' >/dev/null 2>&1
}

wait_rollout() { # $1=deploy $2=轮数（每轮 5s）
  __i=0
  while [ "$__i" -lt "${2:-84}" ]; do
    if kubectl -n $NS rollout status deploy/"$1" --timeout=8s >/dev/null 2>&1; then return 0; fi
    sleep 5
    __i=$((__i + 1))
  done
  return 1
}

# 只读：从 Secret 解出 host/port（绝不回显口令）
parse_dsn_hosts() {
  kubectl -n $NS get secret new-api-secrets -o json 2>/dev/null | python3 -c '
import sys, json, base64, re
d = (json.load(sys.stdin) or {}).get("data") or {}
for key, pre in (("SQL_DSN","APP"), ("SQL_DSN_MIGRATE","MIG"), ("LOG_SQL_DSN","CK"), ("REDIS_CONN_STRING","RD")):
    v = ""
    try: v = base64.b64decode(d.get(key, "")).decode("utf-8", "replace")
    except Exception: v = ""
    m = re.search(r"@([^@/:]+):([0-9]+)", v)
    print("%s_H=%s" % (pre, m.group(1) if m else ""))
    print("%s_P=%s" % (pre, m.group(2) if m else ""))
' 2>/dev/null
}
COMMON_EOF

# =============================================================================
# 各模式静态段
# =============================================================================
read -r -d '' PRE_PRECHECK <<'S_EOF' || true
echo "=== P0) 任务 17 前置：ConfigMap / Secret / 是否已有 master ==="
printf '  ConfigMap NODE_TYPE=%s（红线：必须是 slave）\n' "$(kubectl -n $NS get cm new-api-config -o jsonpath='{.data.NODE_TYPE}' 2>/dev/null)"
kubectl -n $NS get cm new-api-config -o json 2>/dev/null | python3 -c '
import sys, json
d = (json.load(sys.stdin) or {}).get("data") or {}
for k in ("SQL_MAX_OPEN_CONNS","SQL_MAX_IDLE_CONNS","LOG_SQL_MAX_OPEN_CONNS","TZ","MEMORY_CACHE_ENABLED"):
    print("   CM %-24s = %s" % (k, d.get(k, "(未设置)")))
'
kubectl -n $NS get secret new-api-secrets -o json 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception:
    print("  [XX] 无 Secret new-api-secrets ⇒ 任务 17 未落地，任务 18 不可执行"); raise SystemExit
ks = sorted((d.get("data") or {}).keys())
print("  Secret keys=%d: %s" % (len(ks), ks))
for need in ("SQL_DSN","SQL_DSN_MIGRATE","SESSION_SECRET","LOG_SQL_DSN","REDIS_CONN_STRING"):
    print("   %-18s %s" % (need, "OK" if need in ks else "缺"))
'
printf '  现有 new-api-master Deployment=%s\n' "$(kubectl -n $NS get deploy new-api-master -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 无)"
echo "  ServiceAccount / 拉取凭证（任务 16 步骤 7：managed-aliyun-acr-credential-helper）"
printf '    SA new-api-app imagePullSecrets=[%s]\n' "$(kubectl -n $NS get sa new-api-app -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null)"
printf '    ns 内 kubernetes.io/dockerconfigjson Secret=[%s]\n' "$(kubectl -n $NS get secret -o json 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin)
print(", ".join(sorted(i["metadata"]["name"] for i in (d.get("items") or []) if i.get("type") == "kubernetes.io/dockerconfigjson")) or "")
')"
printf '    kube-system 内 acr/pull 相关 Secret=[%s]\n' "$(kubectl -n kube-system get secret -o jsonpath='{range .items[?(@.type=="kubernetes.io/dockerconfigjson")]}{.metadata.name} {end}' 2>/dev/null)"
printf '    acr-credential-helper 组件部署数=%s\n' "$(kubectl get deploy -A --no-headers 2>/dev/null | grep -c 'acr-credential-helper')"
echo "  ResourceQuota / LimitRange（本 ns 每个 Pod 必须显式声明 requests+limits，否则 403）"
kubectl -n $NS get resourcequota -o json 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin)
for it in d.get("items") or []:
    print("    quota %s hard=%s used=%s" % (it["metadata"]["name"],
          json.dumps((it.get("status") or {}).get("hard")), json.dumps((it.get("status") or {}).get("used"))))
'
kubectl -n $NS get limitrange -o json 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin)
for it in d.get("items") or []:
    for l in ((it.get("spec") or {}).get("limits") or []):
        print("    limitrange %s type=%s min=%s max=%s" % (it["metadata"]["name"], l.get("type"), json.dumps(l.get("min")), json.dumps(l.get("max"))))
'

echo "=== P1a) 应用镜像可拉性（凭据由 managed-aliyun-acr-credential-helper 挂到 SA new-api-app）==="
eval "$(parse_dsn_hosts)"
printf '  解析端点：RDS 应用=%s:%s  RDS 迁移=%s:%s  日志库=%s:%s  Redis=%s:%s\n' \
  "$APP_H" "$APP_P" "$MIG_H" "$MIG_P" "$CK_H" "$CK_P" "$RD_H" "$RD_P"
printf '  拉取凭据：SA new-api-app imagePullSecrets=[%s]\n' "$(kubectl -n $NS get sa new-api-app -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null)"
kubectl -n $NS delete pod $PREFLIGHT --ignore-not-found --wait=true >/dev/null 2>&1
# 注意：这里用**不带引号**的 heredoc，让节点侧直接展开 APP_IMAGE；
# Pod 内 probe() 的位置参数必须写成 \$1，否则会被节点侧提前展开成空。
cat <<PREF_EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: t18-preflight
  namespace: new-api
  labels: { app: t18-preflight, project: new-api, site: ph-mnl }
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 900
  terminationGracePeriodSeconds: 0
  # 2026-10-05：任务 16 步骤 7 补装 managed-aliyun-acr-credential-helper 后，
  # 该 SA 带 acr-credential-secret-aggregation（覆盖公网 + -vpc 两个域名）。
  # 不加这一行就会 ImagePullBackOff：helper 只按配置 patch new-api-app，不碰 default。
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
          echo "  PULL_OK 应用镜像容器已启动（= 节点能拉该镜像）"
          ls -l /new-api | sed 's/^/    /'
PREF_EOF
# kubectl 1.35 的 `wait --for=phase=Succeeded` 不是合法条件（会立刻报错），
# 这里用轮询；pullcheck 实测该写法能拿到真实的 Pulling→Pulled 轨迹。
__i=0
RC=1
while [ "$__i" -lt 60 ]; do
  PH=$(kubectl -n $NS get pod $PREFLIGHT -o jsonpath='{.status.phase}' 2>/dev/null)
  case "$PH" in
    Succeeded) RC=0; break ;;
    Failed)    RC=2; break ;;
  esac
  sleep 5
  __i=$((__i + 1))
done
printf '  preflight phase=%s（轮询 %d 次 / %ds，判定 RC=%s）\n' "${PH:-无}" "$__i" "$((__i * 5))" "$RC"
kubectl -n $NS logs $PREFLIGHT 2>&1 | sed 's/^/  /' | head -6
if [ "$RC" != "0" ]; then
  echo "  [XX] 应用镜像未在 300s 内拉起，拉取状态与事件："
  kubectl -n $NS get pod $PREFLIGHT -o jsonpath='{range .status.containerStatuses[*]}waiting={.state.waiting.reason}{"\n"}{end}' 2>/dev/null | sed 's/^/    /'
  kubectl -n $NS get events --field-selector involvedObject.name=$PREFLIGHT --sort-by=.lastTimestamp 2>/dev/null | tail -8 | sed 's/^/    /'
fi
kubectl -n $NS delete pod $PREFLIGHT --ignore-not-found --wait=false >/dev/null 2>&1

echo "=== P1b) 目标端口连通（用已验证可拉的 postgres:17-alpine 探测，与 P2 共用 Pod）==="
if ! ensure_pgcli; then
  echo "  [XX] psql 临时 Pod 未就绪 ⇒ P1b/P2/P3 全部跳过"
  echo PRECHECK-DONE
  exit 0
fi
echo "  1b-1) nc -z 四端口"
kubectl -n $NS exec $PGPOD -- sh -c '
probe() { if nc -z -w5 "$1" "$2" 2>/dev/null; then echo "    [OK]  $3 $1:$2"; else echo "    [XX]  $3 $1:$2 不通"; fi; }
probe "'"$APP_H"'" "'"$APP_P"'" "RDS 应用端口(PgBouncer)"
probe "'"$MIG_H"'" "'"$MIG_P"'" "RDS 迁移端口(直连)"
probe "'"$CK_H"'"  "'"$CK_P"'"  "日志库端点"
probe "'"$RD_H"'"  "'"$RD_P"'"  "Redis"'
echo "  1b-2) 两个 DSN 真握手（PgBouncer transaction 池下 prepare/握手是否可用）"
kubectl -n $NS exec $PGPOD -- sh -c 'psql "$SQL_DSN" -Atqc "select current_database(), version(), current_user" 2>&1 | head -3' | sed 's/^/    app     /'
kubectl -n $NS exec $PGPOD -- sh -c 'psql "$SQL_DSN_MIGRATE" -Atqc "select current_database(), version(), current_user" 2>&1 | head -3' | sed 's/^/    migrate /'
echo "  1b-3) 日志库/Redis 协议握手"
kubectl -n $NS exec $PGPOD -- sh -c 'printf "PING\r\n" | nc -w5 -q1 '"$RD_H"' '"$RD_P"' 2>/dev/null | head -c 30 | tr -d "\r\n"; echo "   <- Redis 回应（+PONG 或 -NOAUTH 都算活着）"'
kubectl -n $NS exec $PGPOD -- sh -c 'printf "GET /ping HTTP/1.0\r\n\r\n" | nc -w5 -q1 '"$CK_H"' 8123 2>/dev/null | head -3' | sed 's/^/    CK-8123 /'

echo "=== P2) 权限边界（卡片验收：DML 账号不得建表）==="
echo "  说明：PG 的 DDL 可事务回滚 ⇒ 这里统一用 BEGIN / CREATE / ROLLBACK，probe 表不留痕"
if ! ensure_pgcli; then
  echo "  [XX] psql 临时 Pod 未就绪（postgres:17-alpine 拉不动？）→ P2/P3 跳过"
  echo PRECHECK-DONE
  exit 0
fi
echo "  2a) SQL_DSN(newapi, 仅 DML) 建表 → 期望 ERROR: permission denied for schema public"
kubectl -n $NS exec $PGPOD -- sh -c 'psql "$SQL_DSN" -c "begin; create table _perm_probe(id int); rollback" 2>&1 | tail -3' | sed 's/^/    /'
echo "  2b) SQL_DSN_MIGRATE(newapi_migrate) 建表(回滚) → 期望 CREATE TABLE 且回滚后不留痕"
kubectl -n $NS exec $PGPOD -- sh -c 'psql "$SQL_DSN_MIGRATE" -c "begin; create table _perm_probe(id int); rollback" 2>&1 | tail -3' | sed 's/^/    /'
echo "  2c) 回滚核对：两张 probe 表都必须不存在"
kubectl -n $NS exec $PGPOD -- sh -c 'psql "$SQL_DSN_MIGRATE" -Atqc "select count(*) from information_schema.tables where table_schema='"'"'public'"'"' and table_name='"'"'_perm_probe'"'"'"' | sed 's/^/    _perm_probe 存在数 = /'

echo "=== P3) 迁移前 schema 指纹 FP0 ==="
fp | sed 's/^/  FP0 /'
purge_tmp
echo PRECHECK-DONE
S_EOF

read -r -d '' PRE_APPLY <<'S_EOF' || true
echo "=== A0) apply 前基线：红线自检 + 当前运行镜像 + schema 指纹 FPA0 ==="
kubectl -n $NS get pods -o json 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin); bad = []
for p in d.get("items") or []:
    for c in (p["spec"].get("containers") or []):
        for e in (c.get("env") or []):
            if e.get("name") == "NODE_TYPE" and e.get("value") not in (None, "slave"):
                bad.append((p["metadata"]["name"], e.get("value")))
print("  显式非 slave 的容器 env: %s" % (sorted(set(bad)) or "无（符合预期）"))
'
CUR=$(kubectl -n $NS get deploy new-api-master -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
printf '  集群当前镜像 = %s\n' "${CUR:-（Deployment 尚不存在）}"
printf '  本次目标镜像 = %s\n' "$TARGET_IMG"
if [ -n "$CUR" ] && [ "$CUR" != "$TARGET_IMG" ]; then
  echo "  [i] 镜像有变更 ⇒ 本次 apply 会触发 Recreate 冷启动（同时验证新域名的拉取路径）"
fi
if ensure_pgcli; then FPA0="$(fp)"; printf '  FPA0 %s\n' "$FPA0"; else echo "  [XX] psql 临时 Pod 未就绪，跳过基线指纹"; FPA0=""; fi
echo "=== A2) apply master Deployment ==="
S_EOF

read -r -d '' POST_APPLY <<'S_EOF' || true
echo "=== A3) 等待就绪（AutoMigrate 在启动阶段同步执行）==="
if wait_rollout new-api-master 84; then
  echo "  [OK] 本次冷启动完成"
else
  echo "  [XX] 未就绪，诊断："
  kubectl -n $NS get pods -l track=master -o wide | sed 's/^/    /'
  kubectl -n $NS describe pod -l track=master 2>/dev/null | tail -25 | sed 's/^/    /'
fi

echo "=== A3b) 拉取路径取证（证明镜像从哪个域名、多久、多少字节拉下来）==="
MP=$(kubectl -n $NS get pods -l track=master -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
printf '  Pod = %s  node = %s\n' "$MP" "$(kubectl -n $NS get pod "$MP" -o jsonpath='{.spec.nodeName}' 2>/dev/null)"
printf '  spec.image  = %s\n' "$(kubectl -n $NS get pod "$MP" -o jsonpath='{.spec.containers[0].image}' 2>/dev/null)"
IID=$(kubectl -n $NS get pod "$MP" -o jsonpath='{.status.containerStatuses[0].imageID}' 2>/dev/null)
printf '  imageID     = %s\n' "$IID"
case "$IID" in
  *-vpc.*) echo "  [OK] 实际拉取域名 = VPC 内网端点" ;;
  "")      echo "  [warn] 读不到 imageID（Pod 可能未就绪）" ;;
  *)       echo "  [XX] 实际拉取域名不是 -vpc ⇒ 内网切换未生效" ;;
esac
echo "  Pulling/Pulled 事件："
kubectl -n $NS get events --field-selector involvedObject.name="$MP" \
  --sort-by=.lastTimestamp -o custom-columns=REASON:.reason,TS:.lastTimestamp,MSG:.message 2>/dev/null \
  | grep -E 'Pull|Pulling' | sed 's/^/    /'

echo "=== A4) 本次冷启动：迁移日志与 DDL 计数（PG / CK 分口径）==="
wait_log_settled deploy/new-api-master || echo "  [warn] 60s 内没等到日志库段，计数可能偏小"
printf '  DDL 行数·主库 PG = %s（空库首启期望 >0；库已建好时期望 0）\n' "$(ddl_count_pg deploy/new-api-master)"
printf '  DDL 行数·日志库 CK = %s（期望 3，每次启动重放的幂等 DDL）\n' "$(ddl_count_ck deploy/new-api-master)"
printf '  ERROR/FATAL 行数 = %s\n' "$(err_count deploy/new-api-master)"
TOTAL=$(kubectl -n $NS logs deploy/new-api-master 2>/dev/null | wc -l | tr -d ' ')
if [ "${TOTAL:-0}" -le 20000 ]; then
  printf '  日志总行数 = %s（≤20000 ⇒ 计数窗口未截断，PG 计数可信）\n' "$TOTAL"
else
  printf '  [warn] 日志总行数 = %s > 20000 ⇒ 窗口已截断启动段，PG 计数不可信，改查 SLS 容器 stdout\n' "$TOTAL"
fi
echo "  迁移日志样本（最多 12 行，每行截 150 字符）："
kubectl -n $NS logs deploy/new-api-master --tail=20000 2>/dev/null \
  | grep -Ei 'migrat|ALTER TABLE|CREATE TABLE|CREATE (UNIQUE )?INDEX|fatal|panic' \
  | head -12 | cut -c1-150 | sed 's/^/    /'

echo "=== A5) schema 指纹 FP1 + 与 A0 基线比对（镜像变更不得动 schema）==="
if ensure_pgcli; then
  FP1="$(fp)"; printf '  FP1 %s\n' "$FP1"
  if [ -z "$FPA0" ]; then
    echo "  [warn] 基线指纹缺失，无法比对"
  elif [ "$FPA0" = "$FP1" ]; then
    echo "  [OK]  指纹逐字相同 ⇒ 本次变更零 schema 漂移"
  else
    echo "  [XX]  指纹发生变化 ⇒ 记录差异，走 expand-contract，勿反复重启刷掉"
  fi
else
  echo "  [XX] psql 临时 Pod 未就绪"
fi
kubectl -n $NS get deploy new-api-master -o jsonpath='  readyReplicas={.status.readyReplicas} replicas={.status.replicas}{"\n"}' 2>/dev/null
purge_tmp
echo APPLY-DONE
S_EOF

read -r -d '' BODY_VERIFY <<'S_EOF' || true
echo "=== V0) 第 2 次冷启动前基线指纹 FPA ==="
if ! ensure_pgcli; then echo "  [XX] psql 临时 Pod 未就绪，无法比对"; exit 1; fi
FPA=$(fp)
printf '  FPA = %s\n' "$FPA"
purge_tmp

echo "=== V1) rollout restart（strategy=Recreate ⇒ 旧 Pod 先退出，等价冷启动）==="
kubectl -n $NS rollout restart deploy/new-api-master >/dev/null && echo "  restart 已下发"
if ! wait_rollout new-api-master 84; then
  echo "  [XX] 第 2 次冷启动未就绪"
  kubectl -n $NS describe pod -l track=master 2>/dev/null | tail -20 | sed 's/^/    /'
  exit 1
fi

echo "=== V2) 第 2 次冷启动：PG 口径 DDL 必须为 0（CK 口径恒为 3，见 ddl_count 注释）==="
wait_log_settled deploy/new-api-master || echo "  [warn] 60s 内没等到日志库段，下面的 PG 计数可能不可信（指纹比对仍有效）"
printf '  DDL 行数·主库 PG(第2次) = %s（期望 0）\n' "$(ddl_count_pg deploy/new-api-master)"
printf '  DDL 行数·日志库 CK(第2次) = %s（期望 3，属每次启动重放的幂等 DDL）\n' "$(ddl_count_ck deploy/new-api-master)"
printf '  ERROR/FATAL 行数 = %s\n' "$(err_count deploy/new-api-master)"
# 采样窗口覆盖度自检：计数只在全量日志未被 --tail=20000 截断时才可信。
# 1 ms 阈值下约 174~218 行/分 ⇒ Pod 存活 ~90 min 后启动段会被挤出窗口，届时 PG=0 会是假 0。
__total=$(kubectl -n $NS logs deploy/new-api-master 2>/dev/null | wc -l | tr -d ' ')
if [ "${__total:-0}" -le 20000 ]; then
  printf '  日志总行数 = %s（≤20000 ⇒ 计数窗口未截断，PG 计数可信）\n' "$__total"
else
  printf '  [warn] 日志总行数 = %s > 20000 ⇒ 窗口已截断启动段，PG 计数不可信，改查 SLS 容器 stdout\n' "$__total"
fi
echo "  第 2 次日志中的 PG DDL（若有，最多 6 行）："
kubectl -n $NS logs deploy/new-api-master --tail=20000 2>/dev/null \
  | grep -E 'ALTER TABLE "|CREATE TABLE "|CREATE (UNIQUE )?INDEX .* ON "|DROP (TABLE|COLUMN|INDEX) "' \
  | head -6 | cut -c1-150 | sed 's/^/    /'

echo "=== V3) 指纹比对（主口径：两次冷启动 schema 必须逐字相同）==="
if ! ensure_pgcli; then echo "  [XX] psql 临时 Pod 未就绪"; exit 1; fi
FPB=$(fp)
printf '  FPB = %s\n' "$FPB"
if [ "$FPA" = "$FPB" ]; then
  echo "  [OK]  幂等成立：第 2 次冷启动零 schema 变更"
else
  echo "  [XX]  幂等被破坏：存在漂移，走 expand-contract 手工修表 + 补版本化迁移，勿反复重启刷掉"
fi

echo "=== V4) 卡片验收项 ==="
printf '  readyReplicas = %s（期望 1）\n' "$(kubectl -n $NS get deploy new-api-master -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
printf '  master Pod 数 = %s（期望 1）\n' "$(kubectl -n $NS get pods -l track=master --no-headers 2>/dev/null | wc -l | tr -d ' ')"
kubectl -n $NS get pods -l track=master -o wide 2>/dev/null | sed 's/^/    /'
printf '  Pod env NODE_TYPE = %s（期望 master，全集群仅此 Deployment 允许）\n' "$(kubectl -n $NS get deploy new-api-master -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="NODE_TYPE")].value}' 2>/dev/null)"
printf '  Pod 实际迁移账号 = %s（期望 newapi_migrate）\n' "$(kubectl -n $NS exec deploy/new-api-master -- sh -c 'printf "%s" "$SQL_DSN" | sed -nE "s#^[a-z0-9+]+://([^@/:]+):.*#\1#p"' 2>/dev/null)"
echo "  —— 坑 1：master 不挂 Service、不进 ALB 后端 ——"
kubectl -n $NS get svc new-api-master -o json 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception:
    print("    (无 svc/new-api-master)"); raise SystemExit
print("    占位 svc selector=%s（master Pod 标签 app=new-api-migrate，故意不命中）" % json.dumps(d["spec"].get("selector")))
'
kubectl -n $NS get endpoints -o json 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin)
for it in d.get("items") or []:
    addrs = [a.get("ip") for s in (it.get("subsets") or []) for a in (s.get("addresses") or [])]
    print("    endpoints/%-24s ready=%d %s" % (it["metadata"]["name"], len(addrs), "⚠ 若含 master Pod 即命中坑 1" if addrs else ""))
'
kubectl -n $NS get ingress -o json 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin)
for it in d.get("items") or []:
    for r in (it["spec"].get("rules") or []):
        for p in ((r.get("http") or {}).get("paths") or []):
            b = (p.get("backend") or {}).get("service") or {}
            print("    ingress/%s host=%s -> svc/%s:%s" % (it["metadata"]["name"], r.get("host"), b.get("name"), (b.get("port") or {}).get("number")))
'
echo "=== V5) 关键表结构（卡片：users 的 quota / used_quota / access_token / status）==="
kubectl -n $NS exec $PGPOD -- sh -c 'psql "$SQL_DSN_MIGRATE" -c "\d users"' 2>/dev/null \
  | grep -E 'quota|access_token|status|password|^ +id ' | sed 's/^/    /'
kubectl -n $NS exec $PGPOD -- sh -c 'psql "$SQL_DSN_MIGRATE" -Atqc "select count(*) from information_schema.tables where table_schema='"'"'public'"'"' and table_type='"'"'BASE TABLE'"'"'"' 2>/dev/null | sed 's/^/  public 表总数 = /'
purge_tmp
echo VERIFY-DONE
S_EOF

read -r -d '' BODY_STATUS <<'S_EOF' || true
set -u
NS=new-api
echo "=== master Deployment / Pod ==="
kubectl -n $NS get deploy new-api-master -o wide 2>/dev/null | sed 's/^/  /' || echo "  未创建"
kubectl -n $NS get pods -l track=master -o wide 2>/dev/null | sed 's/^/  /'
echo "=== 最近日志（尾部 15 行，截 150 字符）==="
kubectl -n $NS logs deploy/new-api-master --tail=15 2>/dev/null | cut -c1-150 | sed 's/^/  /'
echo "=== namespace 全景 ==="
kubectl -n $NS get deploy,svc,endpoints,cm,pvc 2>/dev/null | sed 's/^/  /' | cut -c1-170
kubectl -n $NS get pods -o json 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin)
for p in d.get("items") or []:
    for c in (p["spec"].get("containers") or []):
        envs = {e.get("name"): e.get("value") for e in (c.get("env") or [])}
        print("  pod %-30s NODE_TYPE=%s" % (p["metadata"]["name"], envs.get("NODE_TYPE", "(继承 ConfigMap)")))
'
echo STATUS-DONE
S_EOF

read -r -d '' BODY_CLEANUP <<'S_EOF' || true
set -u
NS=new-api
kubectl -n $NS delete deploy new-api-master --ignore-not-found
kubectl -n $NS delete pod t18-pgcli t18-preflight --ignore-not-found --wait=false
echo "  清理后："
kubectl -n $NS get deploy,pods,svc,endpoints 2>/dev/null | sed 's/^/    /'
echo CLEANUP-DONE
S_EOF

# =============================================================================
# 拼装并下发
# =============================================================================
BODY="$LOGDIR/body.sh"
build_and_run() {
  {
    case "$1" in
      precheck)
        printf "APP_IMAGE='%s'\n" "$IMG"
        printf '%s\n' "$COMMON"
        printf '%s\n' "$PRE_PRECHECK"
        ;;
      apply)
        printf "TARGET_IMG='%s'\n" "$IMG"
        printf '%s\n' "$COMMON"
        printf '%s\n' "$PRE_APPLY"
        printf "cat <<'MANEOF' | kubectl apply -f -\n"
        printf '%s\n' "$M_YAML"
        printf 'MANEOF\n'
        printf '%s\n' "$POST_APPLY"
        ;;
      verify) printf '%s\n' "$COMMON"; printf '%s\n' "$BODY_VERIFY" ;;
      status) printf '%s\n' "$BODY_STATUS" ;;
      cleanup) printf '%s\n' "$BODY_CLEANUP" ;;
    esac
  } > "$BODY"
  [[ -s "$BODY" ]] || die "远端 body 为空"

  say "[i] body -> $BODY ($(wc -l < "$BODY" | tr -d ' ') 行)"
  if [[ -n "${DRY:-}" ]]; then
    say "[i] DRY=1：只渲染，不下发（可 shellcheck -s sh $BODY 复核）"
    return 0
  fi
  bash "$ACK" mnl "$BODY" "" 160 2>&1 | tee "$LOGDIR/remote.out"
  say ""
  say "[i] 完整输出：$LOGDIR/remote.out"
}

case "$MODE" in
  --precheck) say "STEP precheck | 只读 + 临时 Pod，不改生产 schema"; build_and_run precheck ;;
  --apply)    say "STEP apply    | ⚠ 会对生产 RDS 执行 AutoMigrate DDL"; build_and_run apply ;;
  --verify)   say "STEP verify   | 第 2 次冷启动 + 幂等比对 + 卡片验收"; build_and_run verify ;;
  --status)   say "STEP status   | 只读"; build_and_run status ;;
  --cleanup)  say "STEP cleanup  | 删 master Deployment 与本卡临时 Pod"; build_and_run cleanup ;;
  *) die "未知参数：$MODE（--precheck|--apply|--verify|--status|--cleanup）" ;;
esac
