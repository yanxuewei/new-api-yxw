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
NODE_ARG="${2:-i-k1afy1aqgdl8rwa9gxvf}"
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
aliyun cs DescribeClusterUserKubeconfig --ClusterId "$CID" --region "$REGION" \
  --PrivateIpAddress true --TemporaryDurationMinutes 15 > "${TMPD}/kc.${RUN_ID}.json" 2>&1 \
  || { echo "[!] kubeconfig 拉取失败："; head -5 "${TMPD}/kc.${RUN_ID}.json"; exit 1; }
jq -r '.config' "${TMPD}/kc.${RUN_ID}.json" > "$KCF"
[ -s "$KCF" ] || { echo "[!] kubeconfig 为空（检查 DescribeClusterUserKubeconfig 返回）"; exit 1; }
rm -f "${TMPD}/kc.${RUN_ID}.json"
chmod 600 "$KCF"
echo "[i] server=$(grep -m1 'server:' "$KCF" | tr -d '\r')  节点=$NODE_ARG  RUN_ID=$RUN_ID"

# 远端包装：解出 kubeconfig(600) + body，执行，然后无条件删除 kubeconfig
K64=$(base64 -w0 "$KCF")
B64=$(base64 -w0 "$BODY")
cat > "$CMD" <<EOF
#!/bin/bash
set -uo pipefail
mkdir -p ${RTMP} && chmod 700 ${RTMP}
printf '%s' '${K64}' | base64 -d > ${RTMP}/kubeconfig; chmod 600 ${RTMP}/kubeconfig
printf '%s' '${B64}' | base64 -d > ${RTMP}/body.sh; chmod 700 ${RTMP}/body.sh
export KUBECONFIG=${RTMP}/kubeconfig
export PATH=/usr/bin:/bin:/usr/local/bin:\$PATH
bash ${RTMP}/body.sh
RC=\$?
rm -rf ${RTMP}
echo "### remote_rc=\$RC cleaned=\$([ -e ${RTMP} ] && echo NO || echo YES)"
exit \$RC
EOF

INV=$(aliyun ecs RunCommand --RegionId "$REGION" --Type RunShellScript --ContentEncoding Base64 \
      --CommandContent "$(base64 -w0 "$CMD")" --InstanceId.1 "$NODE_ARG" --Timeout 300 \
      --Name "jkt-dev-remote-${RUN_ID}" 2>&1)
INVOKE=$(jq -r '.InvokeId // empty' <<<"$INV")
[ -n "$INVOKE" ] || { echo "[!] RunCommand 失败："; head -5 <<<"$INV"; exit 1; }
echo "[i] InvokeId=$INVOKE"

for _ in $(seq 1 60); do
  RESP=$(aliyun ecs DescribeInvocationResults --RegionId "$REGION" --InvokeId "$INVOKE" 2>/dev/null)
  ST=$(jq -r '.Invocation.InvocationResults.InvocationResult[0].InvocationStatus' <<<"$RESP")
  [ "$ST" != "Running" ] && [ "$ST" != "Pending" ] && [ "$ST" != "Invoking" ] && break
  sleep 5
done
OUT=$(jq -r '.Invocation.InvocationResults.InvocationResult[0].Output // empty' <<<"$RESP" | base64 -d)
echo "----- 节点内输出（status=$ST）-----"
printf '%s\n' "$OUT"
echo "-----------------------------------"
printf '%s\n' "$OUT" | grep -q "remote_rc=0" || { echo "[!] 远端未正常收口"; exit 1; }
echo "[i] 凭据清理：本机 $( [ -e "$KCF" ] && echo 残留 || echo 已删 ) / 节点侧 $(printf '%s' "$OUT" | grep -o 'cleaned=[A-Z]*')"
rm -f "$KCF" "${TMPD}/kc.${RUN_ID}.json"
