#!/usr/bin/env bash
# =============================================================================
# add-domain.sh —— 给 ACK 托管 ALB「加一个域名」的全流程封装（一条命令）
# -----------------------------------------------------------------------------
# 为什么有它：这些 ALB 是 ACK 的派生资源（ServiceManagedResource），
#   控制台规则按钮灰态、OpenAPI 直调 3/3 被拒（OperationDenied.ServiceManagedResource），
#   唯一合法通道 = Ingress / AlbConfig。而手写 Ingress 有 6 个静默失败坑
#   （见 deploy/docs/新增域名转发配置口径_Ingress优先_2026-10-12.md §5）。
#   本脚本把「生成真源 → 预检 → apply → 云端对账 → 回写真源」串成一条命令。
#
# 用法
#   bash deploy/ops/add-domain.sh plan   --site mnl --host api.likha.hk --forward
#   bash deploy/ops/add-domain.sh apply  --site mnl --host api.likha.hk --forward
#   bash deploy/ops/add-domain.sh plan   --site sg  --host old.likha.hk --redirect --to www.likha.hk
#   bash deploy/ops/add-domain.sh apply  --site sg  --host old.likha.hk --redirect --to www.likha.hk
#   bash deploy/ops/add-domain.sh verify --site mnl --host api.likha.hk
#   bash deploy/ops/add-domain.sh ls     --site mnl
#   bash deploy/ops/add-domain.sh delete --site mnl --prefix api-likha-hk --yes
#
# 模式（二选一，必填）
#   --forward                    转发到业务 Service
#       --service <name>         Service 名（默认：mnl=new-api-stable / sg=new-api-ph-standby）
#       --port <n>               Service 端口（默认 80）
#   --redirect                   30x 跳转（收敛到规范域名 / HTTP→HTTPS）
#       --to <fqdn>              跳转目标 host（必填，且不得等于 --host）
#       --code-80 <301|302|303|307|308>   80 侧状态码（默认 301）
#       --code-443 <...>                  443 侧状态码（默认 308 ← 保留 POST 方法与 body）
#
# 通用参数
#   --site mnl|sg        必填
#   --host <fqdn>        必填（不接受 IP：CAS DV 证书不签发 IP SAN，见 REFERENCE §4.5）
#   --ports 80,443       要声明的监听端口（默认 80,443）。**漏一个端口该端口就没有规则**
#   --path /             路径前缀（默认 /）
#   --order <n>          优先级声明（默认：forward=40 / redirect=1）。**必须 < 50 才能压过兜底**
#   --prefix <p>         Ingress 名前缀（默认 = host 的点换横线）
#   --ns new-api         namespace
#   --zone likha.hk      证书覆盖判定用的 zone（默认 likha.hk）
#   --allow-uncovered    证书未覆盖也不拦（默认拦截，因为 443 会握手失败）
#   --curl               额外做一次端到端 curl（需要 DNS 已就绪）
#   --force              预检 FAIL 也继续 apply（危险）
#   --yes                删除类操作免确认
#
# 产出（真源，必须提交）
#   deploy/manifests/ingress-<site>-<prefix>-forward.yaml
#   deploy/manifests/ingress-<site>-<prefix>-http-redirect.yaml
#   deploy/manifests/ingress-<site>-<prefix>-https-canonical.yaml
#
# 依赖：bash · python3 · aliyun CLI（PATH 自愈）· deploy/lib/ack_remote.sh（kubectl 走云助手）
# =============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
MANIFEST_DIR="${REPO_ROOT}/deploy/manifests"
ACK_REMOTE="${REPO_ROOT}/deploy/lib/ack_remote.sh"
WORK_DIR="${REPO_ROOT}/deploy/logs"

# PATH 自愈（与项目其它脚本同口径）
for d in "${HOME}/.workbuddy/binaries/aliyun-cli" /usr/local/bin; do
  [ -d "${d}" ] || continue
  case ":${PATH}:" in *":${d}:"*) ;; *) export PATH="${d}:${PATH}" ;; esac
done

# ── 参数默认值 ───────────────────────────────────────────────────────────────
CMD="${1:-help}"; [ $# -gt 0 ] && shift
SITE=""; HOST=""; MODE=""
SERVICE=""; SPORT=80
TO=""; CODE80=301; CODE443=308
PORTS=""; PATHP="/"; ORDER=""; PREFIX=""
NS="new-api"; ZONE="likha.hk"
ASSUME_YES=0; ALLOW_UNCOVERED=0; DO_CURL=0; FORCE=0

say()  { printf '%s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err()  { printf '[FAIL] %s\n' "$*" >&2; }
die()  { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
ok()   { printf '[ OK ] %s\n' "$*"; }

usage() { awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; }

# ── 站点常量（2026-10-12 实测）────────────────────────────────────────────────
site_region()  { case "$1" in mnl) echo ap-southeast-6 ;; sg) echo ap-southeast-1 ;; *) return 1 ;; esac; }
site_cluster() { case "$1" in mnl) echo cd57e40ce9a634c1698c2f5c5e09bd93c ;; sg) echo ca75829e3492d491d9d434de087913798 ;; *) return 1 ;; esac; }
site_alb()     { case "$1" in mnl) echo alb-1riqckb1h8ezm0y7s9 ;; sg) echo alb-amdwm60xmznh7s1nae ;; *) return 1 ;; esac; }
site_service() { case "$1" in mnl) echo new-api-stable ;; sg) echo new-api-ph-standby ;; *) return 1 ;; esac; }

# ★ kubectl go-template：一行一个 Ingress、TAB 分隔。
#   为什么不用 `-o json`：云助手 RunCommand 的 Output 有 **~24 KB 上限，且截断是「掐中间」**
#   （2026-10-12 实测：节点侧输出 30040 B，本地只收到 24386 B，丢了整段中间内容而**行数不变**
#     ⇒ JSON 解析报「Expecting ':' delimiter」，极难定位）。载荷一律 < 2 KB 才安全。
ING_TMPL='{{range .items}}{{.metadata.name}}{{"\t"}}{{range .spec.rules}}{{if .host}}{{.host}},{{else}}(noHost),{{end}}{{end}}{{"\t"}}{{with .metadata.annotations}}{{index . "alb.ingress.kubernetes.io/listen-ports"}}{{end}}{{"\t"}}{{with .metadata.annotations}}{{index . "alb.ingress.kubernetes.io/order"}}{{end}}{{"\t"}}{{with .metadata.labels}}{{index . "purpose"}}{{end}}{{"\n"}}{{end}}'

ing_table() {  # 读 stdin 的 TSV（name/hosts/ports/order/purpose）→ 人读表格
  awk -F'\t' '
    NF==0 { next }
    {
      for (i=1; i<=NF; i++) gsub(/<no value>/, "", $i)
      sub(/,$/, "", $2); gsub(/\(noHost\)/, "(无 Host)", $2)
      printf "  %-27s ports=%-27s order=%-5s purpose=%-22s hosts=%s\n",
             $1, ($3==""?"-":$3), ($4==""?"-":$4), ($5==""?"-":$5), ($2==""?"(无 Host)":$2)
    }'
}

# ── 云端读取 ─────────────────────────────────────────────────────────────────
listener_of() {  # site port -> listenerId
  local reg alb
  reg="$(site_region "$1")"; alb="$(site_alb "$1")"
  aliyun alb ListListeners --region "${reg}" --LoadBalancerIds.1 "${alb}" --MaxResults 50 \
    --cli-query 'Listeners[].[ListenerId,ListenerPort]' 2>/dev/null \
  | python3 -c "
import sys, json
want = '${2}'
try: rows = json.load(sys.stdin) or []
except Exception: sys.exit(1)
for r in rows:
    if str(r[1]) == want:
        print(r[0]); break
else:
    sys.exit(1)
"
}

alb_rules() {  # site port -> json（★ ListRules 偶发返回空，调用方须重试）
  local reg alb lsn
  reg="$(site_region "$1")"; alb="$(site_alb "$1")"
  lsn="$(listener_of "$1" "$2")" || return 3
  aliyun alb ListRules --region "${reg}" --LoadBalancerIds.1 "${alb}" \
    --ListenerIds.1 "${lsn}" --MaxResults 100 2>/dev/null
}

alb_rules_retry() {  # site port -> json（重试 ≥3 次 + 校验合法 JSON）
  local i out
  for i in 1 2 3 4; do
    out="$(alb_rules "$1" "$2")"
    if printf '%s' "${out}" | python3 -c "import sys,json;json.load(sys.stdin)" 2>/dev/null; then
      printf '%s' "${out}"; return 0
    fi
    sleep 2
  done
  return 1
}

# ── 规则解析器（一次生成，多处复用）──────────────────────────────────────────
RULES_PY=""
init_rules_py() {
  RULES_PY="$(mktemp "${TMPDIR:-/tmp}/addrules.XXXXXX.py")"
  cat > "${RULES_PY}" <<'PYEOF'
import sys, json
data = json.load(sys.stdin)
rules = data.get("Rules") or []

def hosts(r):
    out = []
    for c in (r.get("RuleConditions") or []):
        if c.get("Type") == "Host":
            out += ((c.get("HostConfig") or {}).get("Values") or [])
    return out

def cond_str(r):
    out = []
    for c in (r.get("RuleConditions") or []):
        t = c.get("Type")
        if t == "Host":
            out.append("Host=" + ",".join((c.get("HostConfig") or {}).get("Values") or []))
        elif t == "Path":
            out.append("Path=" + ",".join((c.get("PathConfig") or {}).get("Values") or []))
        elif t == "Header":
            hc = c.get("HeaderConfig") or {}
            out.append("Header=%s=%s" % (hc.get("Key"), ",".join(hc.get("Values") or [])))
        else:
            out.append(str(t))
    return " & ".join(out) if out else "(any host)"

def act_str(r):
    out = []
    for a in (r.get("RuleActions") or []):
        t = a.get("Type")
        if t == "ForwardGroup":
            tup = (a.get("ForwardGroupConfig") or {}).get("ServerGroupTuples") or []
            out.append("Forward[" + ",".join("%s:w%s" % (x.get("ServerGroupId"), x.get("Weight")) for x in tup) + "]")
        elif t == "Redirect":
            rc = a.get("RedirectConfig") or {}
            out.append("Redirect %s -> %s://%s:%s" % (rc.get("HttpCode"), rc.get("Protocol"), rc.get("Host"), rc.get("Port")))
        elif t == "FixedResponse":
            out.append("FixedResponse %s" % ((a.get("FixedResponseConfig") or {}).get("HttpCode")))
        else:
            out.append(str(t))
    return " ; ".join(out) if out else "-"

def prio(r):
    try: return int(r.get("Priority") or 0)
    except Exception: return 0

def line(r):
    return "prio=%-3s %-14s | IF %-46s | THEN %s" % (prio(r), r.get("RuleName"), cond_str(r), act_str(r))

cmd = sys.argv[1] if len(sys.argv) > 1 else "summary"

if cmd == "summary":
    print("count=%d" % len(rules))
    for r in sorted(rules, key=prio):
        print("  " + line(r))

elif cmd == "find-host":
    host = sys.argv[2]
    hit = [r for r in rules if host in hosts(r)]
    if not hit: sys.exit(4)
    for r in sorted(hit, key=prio): print(line(r))

elif cmd == "fallback-prio":
    # 无 Host 条件的规则 = 兜底；返回其最高优先（数值最小）优先级
    fb = [prio(r) for r in rules if not hosts(r)]
    if not fb: sys.exit(5)
    print(min(fb))

elif cmd == "reachable":
    # 目标可达性三态：explicit(有显式 Host 规则) / fallback(靠无 Host 兜底) / 无(exit 4)
    host = sys.argv[2]
    if any(host in hosts(r) for r in rules):
        print("explicit"); sys.exit(0)
    if any(not hosts(r) for r in rules):
        print("fallback"); sys.exit(0)
    sys.exit(4)

elif cmd == "count":
    print(len(rules))

elif cmd == "prio-of-host":
    host = sys.argv[2]
    hit = [prio(r) for r in rules if host in hosts(r)]
    if not hit: sys.exit(4)
    print(min(hit))
PYEOF
}

# ── 工具 ─────────────────────────────────────────────────────────────────────
slug() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '-' | sed 's/-\{1,\}/-/g; s/^-//; s/-$//'; }

is_ipv4() { case "$1" in *[!0-9.]*) return 1 ;; *.*.*.*) return 0 ;; *) return 1 ;; esac; }

# 证书覆盖判定：zone 本身 + 单标签通配 *.zone
cert_covers() {
  local h="$1" z="${2:-likha.hk}" base
  [ "$h" = "$z" ] && return 0
  case "$h" in
    *."$z") base="${h%.$z}" ;;
    *) return 1 ;;
  esac
  case "$base" in *.*) return 1 ;; esac   # 多级子域不在 *.zone 覆盖内
  [ -n "$base" ] && return 0
  return 1
}

listen_ports_json() {
  local p out=""
  IFS=',' read -r -a _arr <<< "$PORTS"
  for p in "${_arr[@]}"; do
    case "$p" in
      80)  out="${out}{\"HTTP\":80}," ;;
      443) out="${out}{\"HTTPS\":443}," ;;
      *) die "不支持的端口 '${p}'（仅 80 / 443）" ;;
    esac
  done
  printf '[%s]' "${out%,}"
}

port_in_list() { case ",${PORTS}," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# ── 参数解析 ─────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --site)      SITE="${2:-}";    shift 2 ;;
    --host)      HOST="${2:-}";    shift 2 ;;
    --forward)   MODE=forward;     shift   ;;
    --redirect)  MODE=redirect;    shift   ;;
    --service)   SERVICE="${2:-}"; shift 2 ;;
    --port)      SPORT="${2:-}";   shift 2 ;;
    --to)        TO="${2:-}";      shift 2 ;;
    --ports)     PORTS="${2:-}";   shift 2 ;;
    --code-80)   CODE80="${2:-}";  shift 2 ;;
    --code-443)  CODE443="${2:-}"; shift 2 ;;
    --path)      PATHP="${2:-}";   shift 2 ;;
    --order)     ORDER="${2:-}";   shift 2 ;;
    --prefix)    PREFIX="${2:-}";  shift 2 ;;
    --ns)        NS="${2:-}";      shift 2 ;;
    --zone)      ZONE="${2:-}";    shift 2 ;;
    --allow-uncovered) ALLOW_UNCOVERED=1; shift ;;
    --curl)      DO_CURL=1;        shift   ;;
    --force)     FORCE=1;          shift   ;;
    --yes|-y)    ASSUME_YES=1;     shift   ;;
    -h|--help)   usage; exit 0     ;;
    *) die "未知参数：$1（-h 看用法）" ;;
  esac
done

case "${CMD}" in
  plan|apply|verify|ls|delete) ;;
  help|"") usage; exit 0 ;;
  -h|--help) usage; exit 0 ;;
  *) die "未知子命令：${CMD}（plan|apply|verify|ls|delete，-h 看用法）" ;;
esac
[ -n "${SITE}" ] || die "缺 --site mnl|sg"
site_region "${SITE}" >/dev/null || die "--site 只能是 mnl 或 sg"

case "${CMD}" in
  verify|ls)
    [ -n "${HOST}" ] || [ "${CMD}" = ls ] || die "verify 需要 --host"
    [ -z "${PORTS}" ] && PORTS="80,443"
    ;;
  delete)
    [ -n "${PREFIX}" ] || die "delete 需要 --prefix"
    [ -z "${PORTS}" ] && PORTS="80,443"
    ;;
  plan|apply)
    [ -n "${HOST}" ] || die "缺 --host"
    [ -n "${MODE}" ]  || die "缺模式：--forward 或 --redirect"
    is_ipv4 "${HOST}" && die "--host 不能是 IP：CAS DV 证书不签发 IP SAN，443 必然握手失败（REFERENCE §4.5）"
    [ -z "${PREFIX}" ] && PREFIX="$(slug "${HOST}")"
    [ -z "${PORTS}" ] && PORTS="80,443"
    if [ "${MODE}" = forward ]; then
      [ -z "${SERVICE}" ] && SERVICE="$(site_service "${SITE}")"
      [ -z "${ORDER}" ] && ORDER=40
    else
      [ -n "${TO}" ] || die "redirect 需要 --to <fqdn>"
      is_ipv4 "${TO}" && die "--to 不能是 IP"
      [ "${TO}" = "${HOST}" ] && die "--to 与 --host 相同 = 自跳死循环"
      [ -z "${ORDER}" ] && ORDER=1
    fi
    ;;
esac

REGION="$(site_region "${SITE}")"
CLUSTER="$(site_cluster "${SITE}")"
ALB="$(site_alb "${SITE}")"
init_rules_py
BODY=""
REMOTE_OUT=""
cleanup() {
  [ -n "${RULES_PY}" ] && rm -f "${RULES_PY}"
  [ -n "${BODY}" ] && rm -f "${BODY}"
  if [ "${ADD_DOMAIN_KEEP:-0}" = 1 ]; then
    [ -n "${REMOTE_OUT}" ] && printf '[keep] 远端原始输出留在：%s\n' "${REMOTE_OUT}" >&2
  else
    [ -n "${REMOTE_OUT}" ] && rm -f "${REMOTE_OUT}"
  fi
}
trap cleanup EXIT

say "== add-domain.sh · cmd=${CMD} site=${SITE} host=${HOST:-<none>} mode=${MODE:-<none>} =="
say "   region=${REGION} cluster=${CLUSTER} alb=${ALB} ports=${PORTS:-<none>} order=${ORDER:-<none>}"

# ── YAML 生成 ────────────────────────────────────────────────────────────────
gen_forward_yaml() {
  local name="$1" lp file fname
  lp="$(listen_ports_json)"
  fname="ingress-${SITE}-${PREFIX}-forward.yaml"
  file="${MANIFEST_DIR}/${fname}"
  cat > "${file}" <<YAML
# ${HOST} → Service/${SERVICE}:${SPORT}  ·  站点 ${SITE}（由 add-domain.sh 生成）
# 集群：${CLUSTER}（${REGION}）· ALB ${ALB} · namespace ${NS}
# 生成时间：$(date '+%Y-%m-%d %H:%M:%S %z')
#
# ★ 本文件是真源；apply 后必须与集群一致（本脚本 apply 时同步写盘）。
# ★ order=${ORDER} 必须 **小于**本监听上「无 Host 兜底规则」的 order（两地兜底 = 50），
#   否则请求先被兜底命中 ⇒ 域名静默失效（Gateway 会照常回 200，极难发现）。
# ★ listen-ports 必须逐个列出；漏一个端口 ⇒ 该端口完全没有规则。
# ★ 443 依赖 AlbConfig 的监听证书（通配符 *.${ZONE}，SAN 含裸域），本件不需要 certificate-id。
# 应用：kubectl -n ${NS} apply -f ${fname}
# 回退：kubectl -n ${NS} delete ingress ${name}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${name}
  namespace: ${NS}
  labels:
    app: new-api
    env: prod
    project: new-api
    site: ${SITE}
    purpose: domain-forward
  annotations:
    alb.ingress.kubernetes.io/backend-protocol: HTTP
    alb.ingress.kubernetes.io/listen-ports: '${lp}'
    alb.ingress.kubernetes.io/order: "${ORDER}"
    alb.ingress.kubernetes.io/healthcheck-enabled: "true"
    alb.ingress.kubernetes.io/healthcheck-path: /api/status
    alb.ingress.kubernetes.io/healthcheck-method: GET
    alb.ingress.kubernetes.io/healthcheck-httpcode: http_2xx
    alb.ingress.kubernetes.io/healthcheck-interval-seconds: "6"
    alb.ingress.kubernetes.io/healthcheck-timeout-seconds: "3"
    alb.ingress.kubernetes.io/healthy-threshold-count: "2"
    alb.ingress.kubernetes.io/unhealthy-threshold-count: "3"
spec:
  ingressClassName: alb
  rules:
    - host: ${HOST}
      http:
        paths:
          - path: ${PATHP}
            pathType: Prefix
            backend:
              service:
                name: ${SERVICE}
                port:
                  number: ${SPORT}
YAML
  printf '%s' "${fname}"
}

gen_redirect_yaml() {  # port code -> 文件名（stdout）
  local port="$1" code="$2" pkey name ann lp file fname
  case "${port}" in 80) pkey=HTTP ;; 443) pkey=HTTPS ;; *) die "redirect 端口只能是 80/443" ;; esac
  case "${code}" in 301|302|303|307|308) ;; *) die "状态码只能是 301/302/303/307/308（ALB RedirectConfig.HttpCode 取值域）" ;; esac
  if [ "${port}" = 80 ]; then name="${PREFIX}-http-redirect"; else name="${PREFIX}-https-canonical"; fi
  lp="[{\"${pkey}\":${port}}]"
  # ★ 单引号段原样保留 ${path}/${query}（ALB 占位符），变量单独注入
  ann='[{"type":"Redirect","RedirectConfig":{"host":"'"${TO}"'","path":"${path}","port":"443","protocol":"HTTPS","query":"${query}","httpCode":"'"${code}"'"}}]'
  if [ "${port}" = 80 ]; then fname="ingress-${SITE}-${PREFIX}-http-redirect.yaml"; else fname="ingress-${SITE}-${PREFIX}-https-canonical.yaml"; fi
  file="${MANIFEST_DIR}/${fname}"
  cat > "${file}" <<YAML
# ${HOST}:${port} → https://${TO}  ·  站点 ${SITE}（由 add-domain.sh 生成）
# 集群：${CLUSTER}（${REGION}）· ALB ${ALB} · namespace ${NS}
# 生成时间：$(date '+%Y-%m-%d %H:%M:%S %z')
#
# ★★★ 三条硬约束（违反任一 = 静默失效或打挂站点）★★★
#   ① order=${ORDER} 必须 < 兜底规则的 order（两地 50），否则压不过兜底 = 等于没写。
#   ② host 只放**被收敛的那一个**；跳到自己 = **无限 30x 循环**。
#   ③ service.name 必须与注解后缀 actions.<name> 逐字同名（此处 = redirect），
#      且 port.name 固定为 use-annotation。写成真实 Service ⇒ 规则不生成且不报错。
# ★ 字段名：RedirectConfig（PascalCase）+ httpCode（不是 statusCode）；
#   写错会静默忽略并退化成 ForwardGroup + 404，而 **HTTP 仍回 200**（伪装性极强）。
# ★ 状态码决策：承载 API 的域名收敛一律 **308**（保留 POST 方法与 body）；
#   301/302/303 会把 POST 降级为 GET 并丢 body ⇒ 客户端「静默调用失败」。
# ★ HTTPS 监听**只能跳 HTTPS**（本件 port/protocol 固定 443/HTTPS，符合）。
# ★ 302/307 可留反悔余地（301/308 会被浏览器长期缓存，回退对已访问者无效）。
# 应用：kubectl -n ${NS} apply -f ${fname}
# 回退：kubectl -n ${NS} delete ingress ${name}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${name}
  namespace: ${NS}
  labels:
    app: new-api
    env: prod
    project: new-api
    site: ${SITE}
    purpose: $( [ "${port}" = 80 ] && echo http-to-https || echo canonical-host-redirect )
  annotations:
    alb.ingress.kubernetes.io/actions.redirect: '${ann}'
    alb.ingress.kubernetes.io/listen-ports: '${lp}'
    alb.ingress.kubernetes.io/order: "${ORDER}"
spec:
  ingressClassName: alb
  rules:
    - host: ${HOST}
      http:
        paths:
          - path: ${PATHP}
            pathType: Prefix
            backend:
              service:
                name: redirect
                port:
                  name: use-annotation
YAML
  printf '%s' "${fname}"
}

PRECHECK_FAIL=0
pf() { printf '[FAIL] %s\n' "$*"; PRECHECK_FAIL=$((PRECHECK_FAIL+1)); }
pw() { printf '[WARN] %s\n' "$*"; }

precheck() {
  PRECHECK_FAIL=0
  say ""
  say "---- 预检 ----"

  # 1) 优先级必须压过兜底
  if [ "${ORDER}" -ge 50 ] 2>/dev/null; then
    pf "order=${ORDER} ≥ 50：压不过兜底规则 ⇒ 域名会被「无 Host 兜底」抢先命中而静默失效（建议 < 50）"
  else
    ok "order=${ORDER} < 50（可压过兜底）"
  fi

  # 2) 证书覆盖（443 才需要）
  local need_cert=0 h
  if [ "${MODE}" = redirect ]; then need_cert=1; else port_in_list 443 && need_cert=1; fi
  if [ "${need_cert}" = 1 ]; then
    for h in ${HOST} ${TO}; do
      [ -z "${h}" ] && continue
      if cert_covers "${h}" "${ZONE}"; then
        ok "证书覆盖：${h} 在 *.${ZONE} + 裸域 覆盖内"
      elif [ "${ALLOW_UNCOVERED}" = 1 ]; then
        pw "证书**不覆盖** ${h}（--allow-uncovered 已放行；443 握手会失败）"
      else
        pf "证书**不覆盖** ${h}：仅覆盖 ${ZONE} 与单标签 *.${ZONE}。多级域/IP 需单独挂证书，或用 --allow-uncovered"
      fi
    done
  fi

  # 3) 逐端口：基线 + 跳转目标可达性 + Host 占用
  local p j hit
  for p in 80 443; do
    port_in_list "${p}" || continue
    j="$(alb_rules_retry "${SITE}" "${p}")" || { pw ":${p} 取规则失败（重试 4 次），跳过该端口预检"; continue; }
    say "  [基线] ${SITE} :${p} $(printf '%s' "${j}" | python3 "${RULES_PY}" summary | head -1)（应用后应 +1）"

    if [ "${MODE}" = redirect ]; then
      local r
      r="$(printf '%s' "${j}" | python3 "${RULES_PY}" reachable "${TO}" 2>/dev/null)"
      case "${r}" in
        explicit) ok "跳转目标 ${TO} 在 :${p} 有**显式** Host 规则 ⇒ 可达" ;;
        fallback) pw "跳转目标 ${TO} 在 :${p} **没有显式规则**，靠「无 Host 兜底」命中 ⇒ 目前可达，但任务 47 若删兜底就会 502" ;;
        *)        pf "跳转目标 ${TO} 在 :${p} 既无显式规则、也无兜底 ⇒ 跳过去会 502（SG 侧必须先给目标补 443 兜底）" ;;
      esac
    fi

    hit="$(printf '%s' "${j}" | python3 "${RULES_PY}" find-host "${HOST}" 2>/dev/null)"
    if [ -n "${hit}" ]; then
      pw "${HOST} 在 :${p} 已存在 Host 规则（新增将与之按 order 竞争）："
      printf '%s\n' "${hit}" | sed 's/^/        /'
    fi
  done

  # 4) 真源文件
  if [ "${CMD}" = apply ]; then
    local f
    for f in ingress-${SITE}-${PREFIX}-forward.yaml ingress-${SITE}-${PREFIX}-http-redirect.yaml ingress-${SITE}-${PREFIX}-https-canonical.yaml; do
      [ -f "${MANIFEST_DIR}/${f}" ] && say "  [真源] 将覆盖已存在文件 ${f}"
    done
  fi

  if [ "${PRECHECK_FAIL}" -gt 0 ]; then
    say ""
    err "预检未通过（${PRECHECK_FAIL} 项）"
    return 1
  fi
  say ""
  ok "预检全部通过"
  return 0
}

# ── remote body 构建 ─────────────────────────────────────────────────────────
build_body() {  # names(空格分隔) yaml_blob -> 写 ${BODY}
  BODY="$(mktemp "${WORK_DIR}/add_domain_body.XXXXXX.sh")"
  local names="$1" blob="$2" svc_check=""
  if [ "${MODE}" = forward ]; then
    svc_check="if ! \${K} get svc ${SERVICE} >/dev/null 2>&1; then echo \"[ABORT] Service/${SERVICE} 在 ${NS} 不存在 —— 先建 Service 再加域名\"; exit 9; fi
echo \"[ok] Service/${SERVICE} 存在\""
  fi
  {
    printf '#!/bin/bash\n'
    printf 'set -uo pipefail\n'
    printf 'K="kubectl -n %s"\n' "${NS}"
    printf 'echo "[ctx] site=%s cluster=%s ns=%s"\n' "${SITE}" "${CLUSTER}" "${NS}"
    printf '%s\n' "${svc_check}"
    printf 'echo "[apply]"\n'
    printf "cat <<'YEOF' | \${K} apply -f -\n"
    printf '%s\n' "${blob}"
    printf 'YEOF\n'
    printf 'echo "[readback: ingress]"\n'
    # ★ 这里**不能**带资源名：`kubectl get ingress <name> -o go-template='{{range .items}}'`
    #   在指定名字时返回的是**单个对象**、`.items` 不存在 ⇒ range 空转 ⇒ **静默输出空**（不报错）。
    #   不带名字才是 List。整 ns 的 Ingress 只有 ~10 条，体积可忽略。
    printf "\${K} get ingress -o go-template='%s'\n" "${ING_TMPL}"
    printf 'echo "[done]"\n'
  } > "${BODY}"
}

run_remote() {
  [ -f "${ACK_REMOTE}" ] || die "找不到 ${ACK_REMOTE}"
  bash "${ACK_REMOTE}" "${SITE}" "${BODY}"
}

# 捕获远端输出（同时透出 BODY 段，并留档供本地二次解析）
run_remote_capture() {
  [ -f "${ACK_REMOTE}" ] || die "找不到 ${ACK_REMOTE}"
  REMOTE_OUT="$(mktemp "${WORK_DIR}/add_domain_out.XXXXXX.txt")"
  bash "${ACK_REMOTE}" "${SITE}" "${BODY}" > "${REMOTE_OUT}" 2>&1
  local rc=$?
  remote_body_text | grep -E '^\[' || true
  return "${rc}"
}

# BODY 段（去掉 ack_remote 的脚手架行），行数少、体积小
remote_body_text() {
  awk 'BEGIN{f=0} /================= BODY START =================/{f=1;next} f==1{print}' "${REMOTE_OUT}"
}

# ── 云端对账 ─────────────────────────────────────────────────────────────────
verify_rule() {  # 返回 0/1；结果打印到 stdout
  local p out fb prc rc=0
  for p in 80 443; do
    port_in_list "${p}" || continue
    out="$(alb_rules_retry "${SITE}" "${p}")" || { err ":${p} 取规则失败（重试 4 次）"; rc=1; continue; }
    say "  -- ${SITE} :${p} --"
    printf '%s' "${out}" | python3 "${RULES_PY}" summary | sed 's/^/     /'

    local hit
    hit="$(printf '%s' "${out}" | python3 "${RULES_PY}" find-host "${HOST}" 2>/dev/null)"
    if [ -z "${hit}" ]; then
      err ":${p} 上**没有** Host=${HOST} 的规则 ⇒ Ingress 未生效（查 listen-ports / 伪服务名 / 注解名）"
      rc=1
      continue
    fi
    ok ":${p} 已生成规则：$(printf '%s' "${hit}" | head -1)"

    # 被兜底抢占检查
    fb="$(printf '%s' "${out}" | python3 "${RULES_PY}" fallback-prio 2>/dev/null)"
    prc="$(printf '%s' "${out}" | python3 "${RULES_PY}" prio-of-host "${HOST}" 2>/dev/null)"
    if [ -n "${fb}" ] && [ -n "${prc}" ]; then
      if [ "${prc}" -lt "${fb}" ]; then
        ok ":${p} 优先级 ${prc} < 兜底 ${fb}（不会被兜底抢走）"
      else
        err ":${p} 优先级 ${prc} ≥ 兜底 ${fb} ⇒ **该规则永远不会被命中**，请把 order 调小后重放"
        rc=1
      fi
    fi

    # 动作类型核对（verify 模式不预设模式，只如实报出类型）
    if [ "${MODE}" = redirect ]; then
      case "${hit}" in
        *Redirect*) ok ":${p} 动作 = Redirect（不是 ForwardGroup/404 伪装的）" ;;
        *) err ":${p} 动作不是 Redirect ⇒ 注解字段名写错（RedirectConfig/httpCode）" ; rc=1 ;;
      esac
    elif [ "${MODE}" = forward ]; then
      case "${hit}" in
        *Forward*) ok ":${p} 动作 = ForwardGroup" ;;
        *) err ":${p} 动作不是 ForwardGroup" ; rc=1 ;;
      esac
    else
      case "${hit}" in
        *Redirect*) ok ":${p} 动作 = Redirect" ;;
        *Forward*)  ok ":${p} 动作 = ForwardGroup" ;;
        *) err ":${p} 动作类型无法识别（既非 Redirect 也非 ForwardGroup）" ; rc=1 ;;
      esac
    fi
  done
  return "${rc}"
}

do_curl() {
  local u="${1:-}"
  say "  -- 端到端 curl --"
  curl -sS -m 15 -o /dev/null -w "     no-follow: code=%{http_code} redirects=%{num_redirects}\n" "${u}" || true
  curl -sSL -m 25 -o /dev/null -w "     -L       : code=%{http_code} redirects=%{num_redirects} final=%{url_effective}\n" "${u}" || true
}

server_group_of() {  # 打印 ServerGroupId <-> Name 映射中匹配 Service 的项
  local reg
  reg="$(site_region "${SITE}")"
  aliyun alb ListServerGroups --region "${reg}" --MaxResults 100 2>/dev/null \
  | python3 -c "
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for g in (d.get('ServerGroups') or []):
    n = g.get('ServerGroupName','')
    if '${NS}-${SERVICE:-new-api-ph-standby}' in n:
        print('       %s  %s' % (g.get('ServerGroupId'), n))
"
}

# ── 子命令实现 ───────────────────────────────────────────────────────────────
cmd_plan() {
  local files=()
  if [ "${MODE}" = forward ]; then
    files+=("$(gen_forward_yaml "${PREFIX}-forward")")
  else
    port_in_list 80  && files+=("$(gen_redirect_yaml 80  "${CODE80}")")
    port_in_list 443 && files+=("$(gen_redirect_yaml 443 "${CODE443}")")
  fi
  say ""
  say "---- 生成真源 ----"
  local f
  for f in "${files[@]}"; do say "  ${MANIFEST_DIR}/${f}"; done

  precheck || true
  say ""
  say "---- 生成的 YAML ----"
  for f in "${files[@]}"; do
    say "### ${f}"
    sed 's/^/    /' "${MANIFEST_DIR}/${f}"
  done
  if [ "${PRECHECK_FAIL}" -gt 0 ] && [ "${FORCE}" != 1 ]; then
    say ""
    err "预检未通过 ⇒ **不要 apply**。修好上面的项，或（确认风险后）加 --force"
    exit 3
  fi
  say ""
  say "下一步："
  say "  bash deploy/ops/add-domain.sh apply --site ${SITE} --host ${HOST} \\"
  say "       $( [ "${MODE}" = forward ] && printf '%s' "--forward --service ${SERVICE} --port ${SPORT}" || printf '%s' "--redirect --to ${TO}" ) \\"
  say "       --ports ${PORTS} --order ${ORDER}"
}

cmd_apply() {
  precheck || true
  if [ "${PRECHECK_FAIL}" -gt 0 ] && [ "${FORCE}" != 1 ]; then
    err "预检未通过 ⇒ 已中止（--force 可强制，危险）"
    exit 3
  fi

  local names="" files=() blob=""
  if [ "${MODE}" = forward ]; then
    files+=("$(gen_forward_yaml "${PREFIX}-forward")"); names="${PREFIX}-forward"
  else
    port_in_list 80  && { files+=("$(gen_redirect_yaml 80  "${CODE80}")");  names="${names} ${PREFIX}-http-redirect"; }
    port_in_list 443 && { files+=("$(gen_redirect_yaml 443 "${CODE443}")"); names="${names} ${PREFIX}-https-canonical"; }
  fi
  names="$(printf '%s' "${names}" | sed 's/^ //')"
  local f
  for f in "${files[@]}"; do blob="${blob}
---
$(cat "${MANIFEST_DIR}/${f}")"; done
  blob="$(printf '%s' "${blob}" | sed '1{/^$/d}')"

  say ""
  say "---- 下发到集群（云助手 + 私网 kubeconfig）----"
  say "  Ingress: ${names}"
  build_body "${names}" "${blob}"
  local rrc=0
  run_remote_capture || rrc=$?
  # 远端在 apply 前主动中止（如 Service 不存在）⇒ 立即停，不空等 reconcile
  local abrt
  abrt="$(remote_body_text | grep -F '[ABORT]' | head -1)"
  if [ -n "${abrt}" ]; then
    say ""
    err "${abrt}"
    die "远端在 apply 前中止 ⇒ **零变更**，未创建任何 Ingress"
  fi
  [ "${rrc}" = 0 ] || die "远端执行失败（rc=${rrc}，见上方 BODY 输出）"
  remote_body_text | grep -qE 'created|configured|unchanged' \
    || pw "远端未报告 created/configured/unchanged，请核对上方 [apply] 段"
  say "  [回读] 集群侧 Ingress 实况："
  remote_body_text | sed -n '/\[readback: ingress\]/,$p' | grep -v '^\[' | ing_table

  say ""
  say "---- 等 Controller reconcile ----"
  local p wait_ok=0 i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 6
    wait_ok=0
    for p in 80 443; do
      port_in_list "${p}" || continue
      if alb_rules_retry "${SITE}" "${p}" | python3 "${RULES_PY}" find-host "${HOST}" >/dev/null 2>&1; then :; else wait_ok=$((wait_ok+1)); fi
    done
    [ "${wait_ok}" = 0 ] && break
    say "  [${i}/10] 规则尚未出现，继续等…"
  done

  say ""
  say "---- 云端对账 ----"
  verify_rule; local vrc=$?

  if [ "${MODE}" = forward ]; then
    say ""
    say "---- 后端服务器组（同名不同 ID 很常见，务必按 ID 引用）----"
    server_group_of
  fi

  if [ "${DO_CURL}" = 1 ]; then
    local pp="${PATHP%/}"
    do_curl "$( [ "${MODE}" = redirect ] && echo "http://${HOST}${pp}/api/status" || echo "https://${HOST}${pp}/api/status" )"
    say "  （若解析失败 curl 会报错，属正常：DNS 可能还没加记录）"
    say "  提示：给域名加解析 → bash deploy/manifests/dns-likha-hk.sh add（RR=<前缀> IPS='<ALB 双 IP>'）"
  fi

  say ""
  if [ "${vrc}" = 0 ]; then
    ok "完成。真源已写入 deploy/manifests/（记得 git add/commit）"
  else
    err "规则已下发但**云端对账未全绿**，请按上面 FAIL 项排查（多半是 listen-ports / 伪服务名 / order）"
    return "${vrc}"
  fi
}

cmd_verify() {
  say ""
  say "---- 云端对账 ----"
  verify_rule
}

cmd_ls() {
  say ""
  say "---- 集群 Ingress（namespace ${NS} @ ${SITE}）----"
  BODY="$(mktemp "${WORK_DIR}/add_domain_body.XXXXXX.sh")"
  {
    printf '#!/bin/bash\nset -uo pipefail\n'
    printf 'K="kubectl -n %s"\n' "${NS}"
    printf "\${K} get ingress -o go-template='%s'\n" "${ING_TMPL}"
  } > "${BODY}"
  run_remote_capture
  remote_body_text | ing_table
  local p out
  for p in 80 443; do
    port_in_list "${p}" || continue
    out="$(alb_rules_retry "${SITE}" "${p}")" || continue
    say ""
    say "---- ALB 规则 :${p}（1 Ingress → N 规则；控制台「路由」页按 Ingress 聚合、ALB 页平铺无归属）----"
    printf '%s' "${out}" | python3 "${RULES_PY}" summary | sed 's/^/  /'
  done
}

cmd_delete() {
  local names="" p
  for p in 80 443; do
    port_in_list "${p}" || continue
    if [ "${p}" = 80 ]; then names="${names} ${PREFIX}-http-redirect"; else names="${names} ${PREFIX}-https-canonical"; fi
  done
  names="${names} ${PREFIX}-forward"
  if [ "${ASSUME_YES}" != 1 ]; then
    warn "即将删除 Ingress：${names}（namespace ${NS} @ ${SITE}）"
    warn "这会让对应域名的规则从 ALB 上消失 ⇒ 对外访问立即中断。加 --yes 确认。"
    exit 2
  fi
  BODY="$(mktemp "${WORK_DIR}/add_domain_body.XXXXXX.sh")"
  {
    printf '#!/bin/bash\nset -uo pipefail\n'
    printf 'K="kubectl -n %s"\n' "${NS}"
    printf '${K} delete ingress %s --ignore-not-found 2>&1\n' "${names}"
    printf '${K} get ingress 2>&1\n'
  } > "${BODY}"
  run_remote || die "远端删除失败"
  say ""
  say "---- 云端对账（规则应已消失）----"
  for p in 80 443; do
    port_in_list "${p}" || continue
    out_msg="$(alb_rules_retry "${SITE}" "${p}" | python3 "${RULES_PY}" summary 2>/dev/null | head -1)"
    say "  :${p} ${out_msg}"
  done
  say "  提示：对应真源文件需手动删除 → ${MANIFEST_DIR}/ingress-${SITE}-${PREFIX}-*.yaml"
}

case "${CMD}" in
  plan)   cmd_plan ;;
  apply)  cmd_apply ;;
  verify) cmd_verify ;;
  ls)     cmd_ls ;;
  delete) cmd_delete ;;
esac
