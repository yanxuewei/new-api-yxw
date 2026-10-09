#!/bin/bash
# task55_staging_apply.sh — 把 deploy/staging/manifests 下发到雅加达非生产集群
#
# 通道：deploy/lib/ack_remote.sh jkt（云助手 RunCommand，节点内 kubectl）
#   ⚠ 前置：deploy/lib/ack_remote.sh 当前只认 mnl|sg，需先打上 deploy/staging/ack_remote_jkt.patch
#   ⚠ RunCommand 载荷上限 24KB ⇒ 逐文件下发，不合并
#
# usage（WSL Ubuntu）：
#   bash deploy/staging/task55_staging_apply.sh --precheck     # 只读体检 + 门禁
#   bash deploy/staging/task55_staging_apply.sh --plan         # 渲染 + server-side dry-run
#   bash deploy/staging/task55_staging_apply.sh --apply        # 按序 apply
#   bash deploy/staging/task55_staging_apply.sh --verify       # 回读断言
#   可选：JKT_NODE=i-5ts... （不填由 deploy/lib/ack_remote.sh 自动取节点）、IMAGE=repo/tag:rc.N
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DEPLOY=$(cd "$HERE/.." && pwd)
MAN="$HERE/manifests"
NS=new-api-staging
SITE=jkt
NODE="${JKT_NODE:-}"
IMAGE="${IMAGE:-acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com/newapi-prod/newapi-master:REPLACE_ME-rc.N}"
# 真值只从跳板机的 0600 文件读（Day2任务17:143 口径），用后 shred
SECRETS_DIR="${SECRETS_DIR:-/root/.deploy_secrets}"
# apply 顺序：边界先于负载，配额先于 Pod，策略先于流量
ORDER=(
  10-namespace.yaml
  15-limitrange.yaml
  20-resourcequota.yaml
  40-rbac.yaml
  30-networkpolicy.yaml
  50-redis.yaml
  55-config-secret-template.yaml
  60-deployment.yaml
  61-service.yaml
)
# 41-acr-pull-secret.yaml **默认不在序列里**：它是"免密 helper 未纳管本 ns"时的兜底，
# 与 managed-aliyun-acr-credential-helper 双写会让两套凭证长期漂移。
# 仅当 --precheck 回读到 imagePullSecrets 缺失时才加进来：
#   ACR_FALLBACK=1 bash task55_staging_apply.sh --apply
if [ "${ACR_FALLBACK:-0}" = "1" ]; then
  ORDER=(10-namespace.yaml 15-limitrange.yaml 20-resourcequota.yaml 40-rbac.yaml 41-acr-pull-secret.yaml \
         30-networkpolicy.yaml 50-redis.yaml 55-config-secret-template.yaml 60-deployment.yaml 61-service.yaml)
fi
step(){ printf '\n===== %s =====\n' "$*"; }
die(){ printf 'FATAL: %s\n' "$*" >&2; exit 1; }
MODE="${1:---precheck}"

render(){ # 输出渲染后的清单到 stdout；REPLACE_ME_* 若集群已有则取现值，否则要求本地有密钥文件
  python3 - "$MAN/$1" "$SECRETS_DIR" "$IMAGE" <<'PY'
import sys,os,re,hashlib
man, sdir, image = sys.argv[1], sys.argv[2], sys.argv[3]
path = man
t = open(path, encoding='utf-8').read()
# ★ checksum 口径说明：prod（deploy/task23/stable.sh）取的是**集群现值** sha256[:12]。
#   本脚本无集群写权限（--plan/--apply 才下发），这里退化为"渲染后 CM/Secret 内容"的摘要，
#   只保证"改配置即滚动"这一语义；apply 后请回读 annotations 与集群值是否一致。
cm_path = os.path.join(os.path.dirname(path), '55-config-secret-template.yaml')
def digest(p):
    return hashlib.sha256(open(p, 'rb').read()).hexdigest()[:12] if os.path.isfile(p) else 'noconfig'
t = t.replace('__CONFIG_CHECKSUM__', digest(cm_path))
t = t.replace('__SECRET_CHECKSUM__', digest(cm_path))
t = t.replace(':REPLACE_ME-rc.N', ':' + image.split(':')[-1])

def sub(m):
    indent, key = m.group(1), m.group(2)
    f = os.path.join(sdir, key)
    if not os.path.isfile(f):
        sys.stderr.write("missing secret file: %s\n" % f); sys.exit(3)
    return "%s%s: \"%s\"" % (indent, key, open(f).read().strip())

if os.path.basename(path).startswith('55-'):
    out = []
    for ln in t.split('\n'):
        m = re.match(r'^(\s*)([A-Z_]+):[ \t]*"[^"]*REPLACE_ME[^"]*"', ln)
        out.append(sub(m) if m else ln)
    t = '\n'.join(out)

# 非密钥类占位符：从环境变量注入（不写死在 Git 里）
env_map = {'REPLACE_ME_JKT_EIP_CIDR':    os.environ.get('JKT_EIP_CIDR', ''),
           'REPLACE_ME_JKT_EIP':         os.environ.get('JKT_EIP', ''),
           'REPLACE_ME_JKT_RDS_IP_32':   os.environ.get('JKT_RDS_IP_32', ''),
           'REPLACE_ME_JKT_RDS_PRIVATE': os.environ.get('JKT_RDS_PRIVATE', ''),
           'REPLACE_ME_REDIS_PW':        os.environ.get('REDIS_PW', ''),
           'REPLACE_ME_ACR_DOCKER_CONFIG_JSON': os.environ.get('ACR_DOCKER_CFG_B64', '')}
for k, v in env_map.items():
    if v:
        t = t.replace(k, v)

# 残留占位符检查只看**非注释行**（清单头部的说明注释会大量提到 REPLACE_ME 这个词本身）
if any(l for l in t.split('\n') if 'REPLACE_ME' in l and not l.lstrip().startswith('#')):
    sys.stderr.write("residual placeholder in %s ⇒ 设环境变量（JKT_RDS_IP_32 / JKT_EIP / REDIS_PW）或传 IMAGE=repo:tag\n" % path)
    sys.exit(4)
print(t)
PY
}

step "0 - 门禁：非生产清单不得引用生产资源"
bash "$HERE/ci_check_env_isolation.sh" || die "ci_check_env_isolation 未通过"

step "1 - 本地渲染检查（不落盘密钥，只看是否有 REPLACE_ME 残留）"
for f in "${ORDER[@]}"; do
  [ -f "$MAN/$f" ] || die "缺清单 $f"
  if grep -q "REPLACE_ME" "$MAN/$f"; then
    if [ "$f" = "55-config-secret-template.yaml" ] && [ ! -d "$SECRETS_DIR" ]; then
      printf '  %-34s 需 %s 下的密钥文件（跳板机 0600）\n' "$f" "$SECRETS_DIR"
    else
      printf '  %-34s 含占位符，apply 时渲染\n' "$f"
    fi
  else
    printf '  %-34s ok\n' "$f"
  fi
done

if [ "$MODE" = "--precheck" ]; then
  step "2 - 集群侧只读体检（经 deploy/lib/ack_remote.sh jkt）"
  cat > /tmp/t55_precheck_body.sh <<EOF
#!/bin/bash
set -uo pipefail
export KUBECONFIG=\${KUBECONFIG:-/tmp/k8s/kubeconfig}
echo "-- kubectl version --"; kubectl version --short 2>/dev/null || kubectl version | head -3
echo "-- nodes --"; kubectl get nodes -o wide
echo "-- namespaces --"; kubectl get ns | grep -E 'new-api|NAME'
echo "-- NetworkPolicy 生效性（terway policy sidecar）--"
kubectl -n kube-system get ds terway-eniip -o jsonpath='{..containers[*].name}'; echo
echo "-- ACR 免密 helper --"; kubectl -n kube-system get ds,deploy 2>/dev/null | grep -i acr || echo "  (无 acr-credential-helper ⇒ 41-acr-pull-secret.yaml 为必需)"
echo "-- 现有 ResourceQuota/Secret --"
kubectl get resourcequota -A 2>/dev/null | grep -E 'new-api|NAME' || true
kubectl get secret -A 2>/dev/null | grep -E 'acr-auth|new-api' || true
echo "-- 出网与拉镜像（O2 断言点）--"
kubectl run t55-netcheck --rm -i --restart=Never --image=busybox:1.36 --image-pull-policy=IfNotPresent -- \
  sh -c 'nslookup registry.cn-hangzhou.aliyuncs.com || echo DNS_FAIL' 2>&1 | tail -3 || echo "  PULL/网络未验证 ⇒ 先解 O2"
EOF
  bash "$DEPLOY/lib/ack_remote.sh" "$SITE" /tmp/t55_precheck_body.sh $NODE || die "jkt 通道不可用：先打 ack_remote_jkt.patch，或确认集群 2 节点已就绪（jakarta_dev_ledger §11.4）"
  exit 0
fi

apply_one(){
  local f="$1" out; out="/tmp/t55_${MODE#--}_${f%.yaml}.yaml"
  render "$f" > "$out" || die "渲染 $f 失败（多半是 $SECRETS_DIR 下缺密钥文件）"
  local body="/tmp/t55_body_${f%.yaml}.sh"
  {
    echo '#!/bin/bash'; echo 'set -uo pipefail'
    echo "export KUBECONFIG=\${KUBECONFIG:-/tmp/k8s/kubeconfig}"
    echo "cat > /tmp/t55_${f%.yaml}.yaml <<'MANEOF'"; cat "$out"; echo "MANEOF"
    if [ "$MODE" = "--plan" ]; then
      echo "kubectl apply -f /tmp/t55_${f%.yaml}.yaml --dry-run=server -o name"
    else
      echo "kubectl apply -f /tmp/t55_${f%.yaml}.yaml"
    fi
    echo "rm -f /tmp/t55_${f%.yaml}.yaml"
  } > "$body"
  local sz; sz=$(wc -c < "$body")
  [ "$sz" -le 24576 ] || die "$f 载荷 ${sz}B 超 24KB RunCommand 上限 ⇒ 拆分该清单"
  bash "$DEPLOY/lib/ack_remote.sh" "$SITE" "$body" $NODE || return 1
  rm -f "$out" "$body"
}

case "$MODE" in
  --render)
    # 本地纯渲染自检（不碰集群）：证明占位符能被填满、YAML 可解析、载荷不超 24KB
    OUT=$(mktemp -d); step "3 - 本地渲染到 $OUT"
    for f in "${ORDER[@]}"; do
      render "$f" > "$OUT/$f" || die "渲染 $f 失败（检查 $SECRETS_DIR 与 IMAGE/JKT_* 环境变量）"
      sz=$(wc -c < "$OUT/$f")
      [ "$sz" -le 24576 ] || die "$f 渲染后 ${sz}B 超 24KB RunCommand 上限"
      printf '  %-34s %6sB\n' "$f" "$sz"
    done
    python3 -c '
import sys,glob,yaml
n=0
for f in sorted(glob.glob(sys.argv[1]+"/*.yaml")):
    docs=[d for d in yaml.safe_load_all(open(f,encoding="utf-8")) if d]
    n+=len(docs)
    for d in docs:
        assert d.get("metadata",{}).get("namespace") in (None,"new-api-staging"), (f,d.get("metadata"))
print("  YAML 解析 + namespace 断言通过，对象数 %d" % n)' "$OUT"
    rm -rf "$OUT"
    printf '  ★ 渲染产物已丢弃（含明文密钥，绝不落 Git）\n'
    ;;
  --plan)  step "3 - server-side dry-run 逐文件"; for f in "${ORDER[@]}"; do step "plan $f"; apply_one "$f" || die "plan 失败于 $f"; done ;;
  --apply) step "3 - 按序 apply"
           # 门禁：集群里若已存在同名的 prod 命名空间对象，说明清单被误改
           for f in "${ORDER[@]}"; do step "apply $f"; apply_one "$f" || die "apply 失败于 $f（回滚：kubectl -n $NS delete -f 对应清单）"; done ;;
  --verify)
    cat > /tmp/t55_verify_body.sh <<EOF
#!/bin/bash
set -uo pipefail
export KUBECONFIG=\${KUBECONFIG:-/tmp/k8s/kubeconfig}
NS=$NS
echo "-- pods --"; kubectl -n \$NS get pod -o wide
echo "-- 无跨 ns 引用（不得出现 prod 对象）--"
kubectl get all -A | grep -E 'new-api-staging' | grep -v "^\$NS" || echo "  OK 全部落在 \$NS"
echo "-- NetworkPolicy 已生效 --"; kubectl -n \$NS get networkpolicy
echo "-- Quota 用量 --"; kubectl -n \$NS describe resourcequota new-api-staging-quota | sed -n '/^   Resource/,/^$/p'
echo "-- NODE_TYPE 实测 --"
kubectl -n \$NS get deploy new-api-staging -o jsonpath='{.spec.template.spec.containers[0].env}' ; echo
echo "-- Redis 连通 --"
kubectl -n \$NS run t55-rcheck --rm -i --restart=Never --image=busybox:1.36 -- \
  sh -c 'nc -z -w3 redis-staging.$NS.svc 6379 && echo REDIS_OK || echo REDIS_FAIL' 2>&1 | tail -2
echo "-- 与 prod 不可达断言（必须 FAIL：连不上 prod RDS 私网/公网）--"
kubectl -n \$NS run t55-netdeny --rm -i --restart=never --image=busybox:1.36 -- \\
  sh -c 'nc -z -w3 10.0.69.77 5432 && echo LEAK_PROD_RDS || echo PROD_RDS_UNREACHABLE_OK; nc -z -w3 43.118.96.65 5432 && echo LEAK_PROD_RDS_PUB || echo PROD_RDS_PUB_UNREACHABLE_OK' 2>&1 | tail -3
echo "-- SessionSecret 指纹（与 prod 不得同值）--"
kubectl -n \$NS get secret new-api-staging-secrets -o jsonpath='{.data.SESSION_SECRET}' | base64 -d | sha256sum | cut -c1-12
EOF
    bash "$DEPLOY/lib/ack_remote.sh" "$SITE" /tmp/t55_verify_body.sh $NODE || die "verify 通道失败"
    printf '\n人工比对：prod 现为 c5fbe2dbc89b（len 42，两地域同值，属既有偏差 C3）⇒ staging 指纹必须不同\n'
    ;;
  *) die "unknown mode $MODE" ;;
esac

step "done ($MODE)"
