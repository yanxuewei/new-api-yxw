#!/usr/bin/env bash
# 切换 LOG_SQL_DSN -> MySQL 日志库（mnl / sg）
# usage: bash /mnt/e/git_code/new-api-yxw/deploy/tmp_do_switch.sh <mnl|sg> <probe|switch>
set -euo pipefail
case ":${PATH}:" in
  *":/usr/local/bin:"*) ;;
  *) PATH="${PATH}:/usr/local/bin" ;;
esac
SITE="${1:?mnl|sg}"
MODE="${2:?switch|probe}"
DEPLOY_MNL="new-api-stable new-api-master new-api-canary"
DEPLOY_SG="new-api-ph-standby"
DEP=""; DSN_FILE=""
case "$SITE" in
  mnl) DEP="$DEPLOY_MNL";  DSN_FILE="${DSN_OVERRIDE:-/root/.deploy_secrets/MYSQL_LOG_DSN_MNL}" ;;
  sg)  DEP="$DEPLOY_SG";   DSN_FILE="${DSN_OVERRIDE:-/root/.deploy_secrets/MYSQL_LOG_DSN_SG}"  ;;
  *) echo "[X] bad site"; exit 1 ;;
esac
B=/mnt/e/git_code/new-api-yxw/deploy
TMPB="/tmp/log_body_${SITE}_${MODE}.sh"
if [ "$MODE" = "switch" ]; then
  SRC="${B}/tmp_log_switch_body.sh"
else
  SRC="${B}/tmp_log_probe_body.sh"
fi
tr -d '\r' < "$SRC" | sed -e "s/__DEPLOY__/${DEP}/g" \
  -e "s/__DSN_B64__/$(base64 -w0 < "${DSN_FILE}")/" \
  -e "s/__TITLE__/log-switch ${SITE} ${MODE}/" > "${TMPB}"
OUT="/tmp/log_switch_out_${SITE}_${MODE}.txt"
bash "${B}/lib/ack_remote.sh" "${SITE}" "${TMPB}" > "${OUT}" 2>&1 || true
echo "---- remote output (${SITE}/${MODE}) ----"
cat "${OUT}" | tr -d '\r'
# 回滚留档：switch 模式抓 CURRENT_B64（只在留档文件不存在时写，防重跑被新值覆盖）
if [ "$MODE" = "switch" ] && [ ! -s "/root/.deploy_secrets/CK_LOG_DSN_${SITE}" ] \
   && grep -q '^CURRENT_B64=' "${OUT}"; then
  CB=$(grep '^CURRENT_B64=' "${OUT}" | head -1 | cut -d= -f2-)
  echo "$CB" | base64 -d > "/root/.deploy_secrets/CK_LOG_DSN_${SITE}" 2>/dev/null || true
  echo "[i] 回滚留档 -> /root/.deploy_secrets/CK_LOG_DSN_${SITE}"
fi
rm -f "${TMPB}"
