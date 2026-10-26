#!/usr/bin/env bash
# deploy/lib/ack_remote_jkt_dev.sh —— 雅加达 dev 集群的节点内 kubectl 通道
#
# 与 deploy/lib/ack_remote.sh（生产在用）同一套机制（ECS 云助手 → 节点内 kubectl），
# 三处按 dev 收紧：
#   1) kubeconfig 用 **15 分钟临时凭据**（--TemporaryDurationMinutes 15）而非长期 admin 凭据，
#      且只在本次调用的节点侧临时目录里存在，执行完立即 rm；本机也不缓存（每次重取）。
#   2) 只服务 dev 集群，杜绝误手打到 mnl/sg。
#   3) 输出不落盘（云助手 Output 里含命令结果，本脚本只打印，不写文件）。
#
# usage: bash deploy/lib/ack_remote_jkt_dev.sh <body.sh> [node_id]
#   body.sh 里直接用 kubectl（KUBECONFIG 已注入）
set -uo pipefail

REGION=ap-southeast-5
CID=cb0abf5bc06034f7bbdb991752f6f3e62
BODY="${1:?body file required}"
NODE_ARG="${2:-}"
# 默认节点**不写死**：2026-10-19 实测节点池 np-jkt-dev-app 已被整体替换为 np-jkt-dev-x4c
# （2 × ecs.g9i.xlarge，auto_scaling.enable=true）⇒ 原先硬编码的 i-k1afy1aqgdl8rwa9gxvf 随旧实例
# 一起消失，且开了弹性后实例 id 会继续变。这里每次现取一个 state=running 的实例，
# 拿不到就直接失败（不猜 id，免得命令打到已释放实例上还报成"应用有问题"）。
if [ -z "$NODE_ARG" ]; then
  # 阿里云 OpenAPI 偶发超时/重置会返回空列表，先有限重试再判定无节点。
  for _try in 1 2 3 4 5; do
    NODE_ARG=$(aliyun cs DescribeClusterNodes --ClusterId "$CID" --region "$REGION" 2>/dev/null \
      | jq -r '[.nodes[]? | select(.state=="running") | .instance_id] | first // empty')
    [ -n "$NODE_ARG" ] && break
    sleep 3
  done
  [ -n "$NODE_ARG" ] || { echo "[!] 集群 $CID 连续 5 次未取到 state=running 节点 ⇒ 终止（不向已释放实例发命令）"; exit 1; }
  echo "[i] 动态选定节点=$NODE_ARG（DescribeClusterNodes 现取，未写死）"
fi
RUN_ID="$(date +%s)-$$-${RANDOM}"
TMPD="/tmp/ackctl-jkt-dev"
RW="${TMPD}/remote_body.${RUN_ID}.sh"
CMD="${TMPD}/remote_cmd.${RUN_ID}.sh"
KCF="${TMPD}/kubeconfig.${RUN_ID}"
RTMP="/tmp/ackctl-${RUN_ID}"
trap 'rm -f "$RW" "$CMD" "$KCF" 2>/dev/null' EXIT

mkdir -p "$TMPD"; chmod 700 "$TMPD" 2>/dev/null || true
command -v aliyun >/dev/null || { echo "[!] aliyun CLI 不在 PATH"; exit 1; }

echo "[i] 取 15 分钟临时私网 kubeconfig"
KC_OK=0
for _try in 1 2 3; do
  if aliyun cs DescribeClusterUserKubeconfig --ClusterId "$CID" --region "$REGION" \
      --PrivateIpAddress true --TemporaryDurationMinutes 15 > "${TMPD}/kc.${RUN_ID}.json" 2>&1; then
    KC_OK=1
    break
  fi
  sleep 2
done
[ "$KC_OK" = "1" ] || { echo "[!] kubeconfig 拉取失败（已重试 3 次）："; head -5 "${TMPD}/kc.${RUN_ID}.json"; exit 1; }
jq -r '.config' "${TMPD}/kc.${RUN_ID}.json" > "$KCF"
[ -s "$KCF" ] || { echo "[!] kubeconfig 为空（检查 DescribeClusterUserKubeconfig 返回）"; exit 1; }
rm -f "${TMPD}/kc.${RUN_ID}.json"
chmod 600 "$KCF"
echo "[i] server=$(grep -m1 'server:' "$KCF" | tr -d '\r')  节点=$NODE_ARG  RUN_ID=$RUN_ID"

# 远端包装：kubeconfig 与 body 都用**引号 heredoc 原样落盘**（不再 base64）。
# 实测教训：Base64 内嵌会让命令体膨胀 1.35x，grants/secret 这种 7KB 级 body 叠上 7KB 级
# kubeconfig 就撞 `CmdContent.ExceedLimit`（云助手命令内容上限约 16KB，Base64 与 PlainText 同样受限）。
DESK="DELMETA${RUN_ID//-}"
DESB="DELBODY${RUN_ID//-}"
cat > "$CMD" <<OUTER
#!/bin/bash
set -uo pipefail
mkdir -p ${RTMP} && chmod 700 ${RTMP}
cat > ${RTMP}/kubeconfig <<'${DESK}'
$(cat "$KCF")
${DESK}
chmod 600 ${RTMP}/kubeconfig
cat > ${RTMP}/body.sh <<'${DESB}'
$(cat "$BODY")
${DESB}
chmod 700 ${RTMP}/body.sh
export KUBECONFIG=${RTMP}/kubeconfig
export PATH=/usr/bin:/bin:/usr/local/bin:\$PATH
bash ${RTMP}/body.sh
RC=\$?
rm -rf ${RTMP}
echo "### remote_rc=\$RC cleaned=\$([ -e ${RTMP} ] && echo NO || echo YES)"
exit \$RC
OUTER

# 内容编码：用 PlainText 直发。理由（实测）：Base64 编码会把"已经内嵌 base64 载荷"的命令体
# 二次膨胀（~1.35x），dev 的 grants/secret 命令体因此撞过 `CmdContentExceedLimit`（上限 24KB）。
CMDLEN=$(wc -c < "$CMD")
[ "$CMDLEN" -le 15000 ] || { echo "[!] 命令体 $CMDLEN 字节，接近云助手上限（实测 ~19KB 直接被 CmdContentExceedLimit 拒）⇒ 拆步/瘦身 body"; exit 1; }
INV=$(aliyun ecs RunCommand --RegionId "$REGION" --Type RunShellScript --ContentEncoding PlainText \
      --CommandContent "$(cat "$CMD")" --InstanceId.1 "$NODE_ARG" --Timeout 900 \
      --Name "jkt-dev-remote-${RUN_ID}" 2>&1)
INVOKE=$(jq -r '.InvokeId // empty' <<<"$INV")
[ -n "$INVOKE" ] || { echo "[!] RunCommand 失败："; head -5 <<<"$INV"; exit 1; }
echo "[i] InvokeId=$INVOKE"

# 轮询预算必须 ≥ RunCommand 的 --Timeout（900s），否则本地先放弃、远端还在跑（2026-10-12 实测踩过：
# rollout 卡 300s 上限 ⇒ 云助手把命令判 Timeout、status 读成空，看起来像"远端没收口"）。
for _ in $(seq 1 190); do
  RESP=$(aliyun ecs DescribeInvocationResults --RegionId "$REGION" --InvokeId "$INVOKE" 2>/dev/null)
  ST=$(jq -r '.Invocation.InvocationResults.InvocationResult[0].InvocationStatus // empty' <<<"$RESP" 2>/dev/null)
  # 空状态 = 这次 Describe 本身失败（限流/网络抖动），不是"命令结束"⇒ 继续下一轮，绝不提前收口
  [ -z "$ST" ] && { sleep 5; continue; }
  case "$ST" in Running|Pending|Invoking|Stopping) sleep 5; continue ;; esac
  break
done
[ -n "$ST" ] || { echo "[!] 60 轮轮询仍拿不到 InvocationStatus（InvokeId=$INVOKE，可手工复查）"; exit 1; }
OUT=$(jq -r '.Invocation.InvocationResults.InvocationResult[0].Output // empty' <<<"$RESP" | base64 -d)
echo "----- 节点内输出（status=$ST）-----"
printf '%s\n' "$OUT"
echo "-----------------------------------"
printf '%s\n' "$OUT" | grep -q "remote_rc=0" || { echo "[!] 远端未正常收口"; exit 1; }
rm -f "$KCF" "${TMPD}/kc.${RUN_ID}.json"
# 先删再断言：否则"本机已删"这行是在删除之前打印的，属于自证不成立
echo "[i] 凭据清理：本机 $( [ -e "$KCF" ] && echo 残留 || echo 已删 ) / 节点侧 $(printf '%s' "$OUT" | grep -o 'cleaned=[A-Z]*')"
