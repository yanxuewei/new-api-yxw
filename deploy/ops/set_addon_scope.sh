#!/usr/bin/env bash
# =============================================================================
# deploy/ops/set_addon_scope.sh —— 扩 ACR 免密组件的 watchNamespace（本机运行，非节点）
#
# 为什么必须做：managed-aliyun-acr-credential-helper 只在 watchNamespace 里的命名空间创建
#   Secret `acr-credential-secret-aggregation`，且只把凭据绑到 serviceAccount 里点名的 SA 上。
#   新建的 new-api-pre / new-api-perf 不在作用域里 ⇒ 必然 ErrImagePull（台账 §13 实测过的因果）。
#
# 判据：只认提交后的 GET 回读，不认"没报错"。
# 红线：只允许雅加达集群；马尼拉/新加坡集群一律不碰。
# =============================================================================
set -uo pipefail
REGION=ap-southeast-5
CID=cb0abf5bc06034f7bbdb991752f6f3e62
ADDON=managed-aliyun-acr-credential-helper
INSTANCE=cri-avfqy9xkqi5bj8ee          # 马尼拉 ACR EE（跨区复用，见坑 15：必须走公网入口）
INSTANCE_REGION=ap-southeast-6
WATCH="newapi-dev,new-api-pre,new-api-perf"
SA="new-api-app,default"

die() { echo "[addon][!] $*" >&2; exit 1; }
mask() { sed -E 's/("auth"|"password"|"token"|"secret"|"username")[[:space:]]*:[[:space:]]*"[^"]*"/\1: "***"/gI'; }

echo "=== A0 只允许雅加达集群"
[ "$REGION" = ap-southeast-5 ] || die "REGION 不是 ap-southeast-5，拒绝对其他 region 改组件配置"
case "$CID" in cb0abf5bc06034f7bbdb991752f6f3e62) : ;; *) die "CID 不是雅加达 dev 集群，拒绝" ;; esac
# 三个 ns 必须都已在集群里存在，否则等于给不存在的对象开权限（回读会查，不在这里查）
for n in ${WATCH//,/ }; do
  printf '  作用域将包含 %s\n' "$n"
done

echo "=== A1 提交前配置（先存一份，便于回滚）"
aliyun cs GET "/clusters/$CID/addon_instances/$ADDON" --region "$REGION" > /tmp/addon_before.$$.json 2>&1 \
  || die "GET 失败：$(head -2 /tmp/addon_before.$$.json)"
jq -r '.config' /tmp/addon_before.$$.json | mask | sed 's/^/  before: /'
jq -r '.state + "  " + .version' /tmp/addon_before.$$.json | sed 's/^/  state+version: /'
cp /tmp/addon_before.$$.json "$HOME/.addon_backup_jkt_$(date +%Y%m%d-%H%M%S).json" 2>/dev/null \
  && echo "  备份已存（本机 $HOME，模式见 ls -l）" || echo "  [!] 备份未落盘，仅本次会话可见"

echo "=== A2 组新配置（config 是**字符串**字段，不是对象；这是 ModifyClusterAddon 的形态）"
NEWCFG=$(jq -nc --arg inst "$INSTANCE" --arg ir "$INSTANCE_REGION" --arg watch "$WATCH" --arg sa "$SA" \
  '{AcrInstanceInfo:[{instanceId:$inst,regionId:$ir}],enableRRSA:false,expiringThreshold:"15m",notifyEmail:"xxx@aliyun.com",serviceAccount:$sa,watchNamespace:$watch}') \
  || die "jq 组配置失败"
BODY=$(jq -nc --arg c "$NEWCFG" '{config:$c}') || die "jq 包 body 失败"
printf '  将提交：%s\n' "$BODY"

echo "=== A3 提交"
aliyun cs POST "/clusters/$CID/components/$ADDON/config" --region "$REGION" \
  --header "Content-Type=application/json" --body "$BODY" 2>&1 | head -c 800 | sed 's/^/  /'
RC=$?
printf '  post_rc=%s\n' "$RC"

echo "=== A4 回读（唯一生效判据；组件收敛需要时间，最多轮询 8 次）"
for i in $(seq 1 8); do
  sleep 15
  CUR=$(aliyun cs GET "/clusters/$CID/addon_instances/$ADDON" --region "$REGION" 2>/dev/null | jq -r '.config' 2>/dev/null)
  GOT=$(jq -r '.watchNamespace' <<<"$CUR" 2>/dev/null)
  printf '  t+%02ds watchNamespace=%s\n' "$((i*15))" "${GOT:-<空>}"
  [ "$GOT" = "$WATCH" ] && { echo "  [ok] 云侧作用域已含三个命名空间"; break; }
done
aliyun cs GET "/clusters/$CID/addon_instances/$ADDON" --region "$REGION" 2>&1 | jq -r '.config' 2>/dev/null | mask | sed 's/^/  after: /'
rm -f /tmp/addon_before.$$.json
echo "--- A1–A4 结束（写入面只有该集群这一条组件配置；Secret/SA 绑定的实际生效由 --addon-verify 取证）"
