#!/usr/bin/env bash
# task24/ack_sg.sh —— 任务 24：新加坡 ACK Pro 集群 + 常态 2 节点节点池（备站算力底座）
# 幂等：--check（只读复核） / --keypair / --create / --wait / --verify / --all
# 依据：deploy/docs/阿里云国际站菲律宾部署_详细操作指南-v2.0.md 任务 24（与任务 10/11 同构）
set -uo pipefail

REGION="${REGION:-ap-southeast-1}"
CLUSTER_NAME="${CLUSTER_NAME:-ack-newapi-sg}"
VPC="${VPC:-vpc-t4nimmwvruexbnene0a3r}"
VSW_APP_A="${VSW_APP_A:-vsw-t4nbvsnvo4z52sumr9sck}"     # vsw-sg-app-a  1a 10.1.16.0/20
VSW_APP_B="${VSW_APP_B:-vsw-t4n3dthz1ma6tp7bqor6h}"     # vsw-sg-app-b  1b 10.1.32.0/20
RESOURCE_GROUP_ID="${RESOURCE_GROUP_ID:-rg-aek4zvb3ldoiyua}"  # rg-sg
SG_APP="${SG_APP:-sg-t4n0qnhy8mxq9g733r67}"             # sg-sg-app
K8S_VERSION="${K8S_VERSION:-1.35.7-aliyun.1}"
SERVICE_CIDR="${SERVICE_CIDR:-172.22.0.0/20}"           # 与马尼拉 172.21.0.0/20 错开，防未来 CEN 重叠
KEY_PAIR="${KEY_PAIR:-newapi-sg}"
PUB_KEY_FILE="${PUB_KEY_FILE:-/mnt/e/git_code/ssh_bk1/.ssh/id_ed25519.pub}"
REPO_ROOT="${REPO_ROOT:-/mnt/e/git_code/new-api-yxw}"
LOG_DIR="${LOG_DIR:-$REPO_ROOT/deploy/logs/task24_$(date +%Y%m%d-%H%M%S)}"

MODE="${1:---check}"
BODY_FILE="$LOG_DIR/create-cluster-sg.json"

log()  { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
ok()   { printf '  [OK]   %s\n' "$*"; }
info() { printf '  [INFO] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; }

# 判 API 调用是否成功：CLI 失败时 stderr 文本含 ErrorCode:，或 JSON 含 code/ErrorCode
api_ok() {
  local raw
  raw="$(cat)"
  case "$raw" in
    *'"cluster_id"'*|*'"ClusterId"'*|*'"RequestId"'*)
      case "$raw" in
        *'"code"'*|*'ErrorCode'*|*'ERROR:'*) return 1 ;;
      esac
      return 0 ;;
    *) return 1 ;;
  esac
}

# ---------- 1. 只读复核 ----------
do_check() {
  echo "===================== 任务 24 · 前置复核 ====================="
  local cid
  cid="$(aliyun cs DescribeClustersV1 --RegionId "$REGION" --region "$REGION" 2>/dev/null \
        | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print(''); raise SystemExit
for c in d.get('clusters') or []:
    if c.get('name')=='''$CLUSTER_NAME''': print(c.get('cluster_id')); break
")"
  if [ -n "$cid" ]; then ok "集群已存在：$CLUSTER_NAME = $cid"; else info "集群不存在（待建）：$CLUSTER_NAME"; fi

  aliyun ecs DescribeKeyPairs --RegionId "$REGION" --region "$REGION" 2>/dev/null \
    | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
ks=[k.get('KeyPairName') for k in (d.get('KeyPairs') or {}).get('KeyPair') or []]
print('  [%s] 密钥对 %s：%s' % ('OK' if '$KEY_PAIR' in ks else 'INFO', '$KEY_PAIR', ks or '(无)'))
"

  aliyun ecs DescribeSecurityGroups --RegionId "$REGION" --region "$REGION" --VpcId "$VPC" --PageSize 50 2>/dev/null \
    | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
for s in (d.get('SecurityGroups') or {}).get('SecurityGroup') or []:
    if s.get('SecurityGroupId')=='$SG_APP':
        print('  [OK]   %s = %s（type=%s）' % (s.get('SecurityGroupName'), s.get('SecurityGroupId'), s.get('SecurityGroupType')))
"

  aliyun resourcemanager GetResourceGroup --ResourceGroupId "$RESOURCE_GROUP_ID" --region ap-southeast-1 2>/dev/null \
    | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
g=(d.get('ResourceGroup') or {})
print('  [OK]   资源组 %s = %s' % (g.get('Id'), g.get('DisplayName')))
"
  echo "  ── vSwitch 基线 ──"
  info "app-a $VSW_APP_A (1a) / app-b $VSW_APP_B (1b)"
  info "Service CIDR 计划：$SERVICE_CIDR（马尼拉为 172.21.0.0/20，故错开）"
}

# ---------- 2. 密钥对 ----------
do_keypair() {
  echo "===================== 任务 24 · 密钥对 ====================="
  local exists
  exists="$(aliyun ecs DescribeKeyPairs --RegionId "$REGION" --region "$REGION" 2>/dev/null \
    | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print(''); raise SystemExit
for k in (d.get('KeyPairs') or {}).get('KeyPair') or []:
    if k.get('KeyPairName')=='$KEY_PAIR': print('yes'); break
")"
  if [ "$exists" = "yes" ]; then ok "密钥对 $KEY_PAIR 已存在，跳过"; return 0; fi

  [ -f "$PUB_KEY_FILE" ] || { bad "公钥文件不存在：$PUB_KEY_FILE"; return 1; }
  local body; body="$(cat "$PUB_KEY_FILE")"
  log "导入公钥 → $KEY_PAIR（来源 $PUB_KEY_FILE）"
  local raw
  raw="$(aliyun ecs ImportKeyPair --RegionId "$REGION" --region "$REGION" \
        --KeyPairName "$KEY_PAIR" --PublicKeyBody "$body" 2>&1)"
  case "$raw" in
    *'"KeyPairName"'*) ok "已导入 $KEY_PAIR"; printf '%s\n' "$raw" > "$LOG_DIR/keypair-import.json" ;;
    *) bad "导入失败：$raw" ; return 1 ;;
  esac
}

# ---------- 3. 建集群 ----------
do_create() {
  echo "===================== 任务 24 · 创建集群 ====================="
  mkdir -p "$LOG_DIR"
  local cid
  cid="$(get_cluster_id)"
  if [ -n "$cid" ]; then
    ok "集群已存在，跳建：$cid"
    printf '%s' "$cid" > "$LOG_DIR/cluster_id.txt"
    return 0
  fi

  cat > "$BODY_FILE" <<JSON
{"name":"${CLUSTER_NAME}",
 "cluster_type":"ManagedKubernetes","profile":"Default","cluster_spec":"ack.pro.small",
 "region_id":"${REGION}","kubernetes_version":"${K8S_VERSION}",
 "vpcid":"${VPC}",
 "vswitch_ids":["${VSW_APP_A}","${VSW_APP_B}"],
 "pod_vswitch_ids":["${VSW_APP_A}","${VSW_APP_B}"],
 "service_cidr":"${SERVICE_CIDR}",
 "resource_group_id":"${RESOURCE_GROUP_ID}",
 "snat_entry":false,"endpoint_public_access":false,"deletion_protection":true,
 "rrsa_config":{"enabled":true},"timezone":"Asia/Singapore","proxy_mode":"ipvs",
 "charge_type":"PostPaid",
 "addons":[{"name":"terway-controlplane","config":"{\"ENITrunking\":\"false\"}"},
           {"name":"terway-eniip"},{"name":"csi-plugin"},{"name":"csi-provisioner"},
           {"name":"ack-pod-identity-webhook"},{"name":"alb-ingress-controller"},
           {"name":"managed-coredns"},{"name":"arms-prometheus"},{"name":"logtail-ds"}]}
JSON
  log "建簇 body → $BODY_FILE"
  python3 -c "import json,sys; json.load(open('$BODY_FILE')); print('  [OK]   body JSON 合法')" || return 1

  log "调用 CreateCluster…（3–15 分钟）"
  local raw
  raw="$(aliyun cs CreateCluster --region "$REGION" --body "$(cat "$BODY_FILE")" 2>&1)"
  printf '%s\n' "$raw" > "$LOG_DIR/create-cluster.resp.json"
  cid="$(printf '%s' "$raw" | python3 -c "
import sys,json
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception: print(''); raise SystemExit
print(d.get('cluster_id') or '')
")"
  if [ -z "$cid" ]; then bad "建簇失败：$raw"; return 1; fi
  ok "已受理 cluster_id = $cid"
  printf '%s' "$cid" > "$LOG_DIR/cluster_id.txt"
  printf '%s' "$cid"
}

get_cluster_id() {
  aliyun cs DescribeClustersV1 --RegionId "$REGION" --region "$REGION" 2>/dev/null \
    | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print(''); raise SystemExit
for c in d.get('clusters') or []:
    if c.get('name')=='$CLUSTER_NAME': print(c.get('cluster_id')); break
"
}

# ---------- 4. 等待 running ----------
do_wait() {
  echo "===================== 任务 24 · 等待集群 running ====================="
  local cid="$1" i=0
  [ -n "$cid" ] || cid="$(get_cluster_id)"
  [ -n "$cid" ] || { bad "找不到集群"; return 1; }
  while [ "$i" -lt 60 ]; do
    local st
    st="$(aliyun cs DescribeClusterDetail --ClusterId "$cid" --region "$REGION" 2>/dev/null \
        | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print(''); raise SystemExit
print(d.get('state') or '')
")"
    info "[$((i*20))s] state=$st"
    [ "$st" = "running" ] && { ok "集群 running"; return 0; }
    [ "$st" = "failed" ] && { bad "集群 failed"; return 1; }
    sleep 20; i=$((i+1))
  done
  bad "等待超时"; return 1
}

# ---------- 5. 终验 ----------
do_verify() {
  echo "===================== 任务 24 · 终验 ====================="
  local cid="${1:-$(get_cluster_id)}"
  [ -n "$cid" ] || { bad "找不到集群"; return 1; }
  aliyun cs DescribeClusterDetail --ClusterId "$cid" --region "$REGION" > "$LOG_DIR/describe.json" 2>&1
  python3 - "$LOG_DIR/describe.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
rows = [
    ('cluster_id', d.get('cluster_id'), d.get('cluster_id') != ''),
    ('name', d.get('name'), d.get('name') == 'ack-newapi-sg'),
    ('state', d.get('state'), d.get('state') == 'running'),
    ('version', d.get('current_version'), (d.get('current_version') or '').startswith('1.35')),
    ('spec', d.get('cluster_spec'), d.get('cluster_spec') == 'ack.pro.small'),
    ('cluster_type', d.get('cluster_type'), d.get('cluster_type') == 'ManagedKubernetes'),
    ('resource_group_id', d.get('resource_group_id'), d.get('resource_group_id') == 'rg-aek4zvb3ldoiyua'),
    ('vpc_id', d.get('vpc_id'), d.get('vpc_id') == 'vpc-t4nimmwvruexbnene0a3r'),
    ('proxy_mode', d.get('proxy_mode'), d.get('proxy_mode') == 'ipvs'),
    ('timezone', d.get('timezone'), d.get('timezone') == 'Asia/Singapore'),
    ('deletion_protection', d.get('deletion_protection'), bool(d.get('deletion_protection'))),
    ('rrsa.enabled', (d.get('rrsa_config') or {}).get('enabled'), (d.get('rrsa_config') or {}).get('enabled') is True),
]
p = sum(1 for _,_,c in rows if c)
for k, v, c in rows:
    print('  [%s] %-22s %s' % ('OK' if c else 'FAIL', k, v))
print('  ---- 终验 %d/%d' % (p, len(rows)))
# 关键：控制面安全组 + 6443 血案核验
sg = d.get('security_group_id')
print('  ── 控制面安全组：%s ──' % sg)
open('/tmp/sg24_cpsg.txt','w').write(sg or '')
PY

  local cpsg; cpsg="$(cat /tmp/sg24_cpsg.txt 2>/dev/null)"
  if [ -n "$cpsg" ]; then
    echo "  ── 6443 入向规则核验（马尼拉血案同构检查）──"
    aliyun ecs DescribeSecurityGroupAttribute --RegionId "$REGION" --region "$REGION" \
      --SecurityGroupId "$cpsg" --Direction ingress > "$LOG_DIR/cpsg-ingress.json" 2>&1
    python3 - "$LOG_DIR/cpsg-ingress.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print('  [WARN] 安全组规则查询失败'); raise SystemExit
perms = (d.get('Permissions') or {}).get('Permission') or []
print('  规则数 = %d' % len(perms))
hit = False
for p in perms:
    pr = str(p.get('PortRange') or '')
    print('    %-8s %-14s src=%s  %s' % (p.get('IpProtocol'), pr, p.get('SourceCidrIp') or p.get('SourceGroupId'), p.get('Description') or ''))
    if '6443' in pr:
        hit = True
if hit:
    print('  [OK]   6443 已放行 —— 新加坡未复现马尼拉血案')
else:
    print('  [FAIL] 6443 未放行 —— 与马尼拉同构缺陷复现，须按 nodepool_ledger.md §7 处置')
PY
  fi
}

case "$MODE" in
  --check)   do_check ;;
  --keypair) mkdir -p "$LOG_DIR"; do_keypair ;;
  --create)  mkdir -p "$LOG_DIR"; do_keypair && do_create ;;
  --wait)    do_wait "${2:-}" ;;
  --verify)  mkdir -p "$LOG_DIR"; do_verify ;;
  --all)     mkdir -p "$LOG_DIR"; echo "日志目录：$LOG_DIR"; do_check; do_keypair && do_create ;;
  *) echo "用法：$0 [--check|--keypair|--create|--wait|--verify|--all]"; exit 2 ;;
esac
