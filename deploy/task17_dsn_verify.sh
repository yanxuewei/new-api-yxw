#!/usr/bin/env bash
# =============================================================================
# 任务 17｜LOG_SQL_DSN 注入核验（幂等 · 只读）
# -----------------------------------------------------------------------------
# 校验对象（马尼拉 / 新加坡两地 new-api namespace）：
#   1) Secret new-api-secrets 键清单（是否含 LOG_SQL_DSN；值不外泄）
#   2) LOG_SQL_DSN 结构（脱敏：scheme/user/pw_len/host/port/db）
#   3) 端点口径：mnl 应为 VPC（`-clickhouse.clickhouseserver.`）
#                sg  应为 PUBLIC（`-public.clickhouseserver.`）— 2026-09-30 裁定③
#   4) 端到端鉴权：节点内用 Secret 自身值连 CK HTTP 8123 执行 SELECT 1 / SHOW TABLES
#   5) ConfigMap new-api-config 的 LOG_SQL_CLICKHOUSE_TTL_DAYS
#
# ⚠ 全程不打印口令；DSN 只在远端节点内存中解析，结果以脱敏形式回传。
# 用法：
#   bash deploy/task17_dsn_verify.sh            # 两地
#   bash deploy/task17_dsn_verify.sh mnl|sg     # 单站
# 前置：deploy/ack_remote.sh（云助手通道）可用；本机无需 kubeconfig。
# 退出码：0 全通过 / 1 有 FAIL
# =============================================================================
set -uo pipefail
MODE="${1:-both}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ACK="$HERE/ack_remote.sh"
[[ -x "$ACK" || -f "$ACK" ]] || { echo "缺 $ACK"; exit 2; }

build_body() { # $1=mnl|sg
  cat <<EOF
set -u
ST="$1"
echo "########## \$ST ##########"
echo "=== 1) Secret 键清单（仅键名）==="
kubectl -n new-api get secret new-api-secrets -o json 2>/dev/null | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print('  [XX] 读不到 secret new-api-secrets'); raise SystemExit(3)
ks=sorted((d.get('data') or {}).keys())
print('  count=%d' % len(ks))
for k in ks: print('   -', k)
print('  LOG_SQL_DSN: %s' % ('有' if 'LOG_SQL_DSN' in ks else '缺'))
" || exit 3
echo "=== 2/3) DSN 结构 + 端点口径 ==="
SEC=\$(kubectl -n new-api get secret new-api-secrets -o jsonpath='{.data.LOG_SQL_DSN}' 2>/dev/null | base64 -d 2>/dev/null)
[ -n "\$SEC" ] || { echo "  [XX] LOG_SQL_DSN 为空"; exit 1; }
eval "\$(python3 - "\$SEC" <<'PY'
import sys,re
d=sys.argv[1].strip()
m=re.match(r'^([a-z0-9+]+)://([^:@/]+):([^@]*)@([^:/?]+):(\d+)/([^?]*)(\?.*)?\$', d)
if not m: print("echo '  [XX] DSN 解析失败'; exit 1"); raise SystemExit
sch,user,pw,host,port,db,q=m.groups()
print("SCH=%s" % sch); print("USR=%s" % user); print("PWL=%d" % len(pw))
print("HST=%s" % host); print("PRT=%s" % port); print("DBN=%s" % db)
print("PW=%s" % pw.replace("'","'\\\\''"))
PY
)"
echo "  scheme=\$SCH user=\$USR pw_len=\$PWL host=\$HST port=\$PRT db=\$DBN"
case "\$ST:\$HST" in
  mnl:*clickhouse.clickhouseserver*) case "\$HST" in *-public.*) echo "  [!!] mnl 用了 PUBLIC 端点（预期 VPC）";; *) echo "  [OK] mnl 端点=VPC（预期）";; esac ;;
  sg:*)  case "\$HST" in *-public.*) echo "  [OK] sg 端点=PUBLIC（跨区，2026-09-30 裁定③）";; *) echo "  [XX] sg 仍指 VPC 端点 ⇒ 跨区不可达，必须改 -public";; esac ;;
esac
echo "=== 4) 端到端鉴权（HTTP 8123）==="
# ⚠ 不要用 curl 的 -w http_code 写法（远端 curl 差异下 -w 可能不回显，实测 2026-10-05 得空串）
# ⚠ 本 heredoc 为**不带引号**的 <<EOF：正文里禁止出现反引号（会被本地 shell 当命令替换执行）
# ⚠ VPC 端点两端皆偶发抖动（项目铁律）⇒ 内层重试 3 次；仍失败则用 public 端点做一次判别性诊断
H2=\$(printf '%s' "\$HST" | sed 's/-clickhouse\.clickhouseserver/-public.clickhouseserver/')
ck_try() { # args: host sql outfile
  local h="\$1" sql="\$2" of="\$3" i
  for i in 1 2 3; do
    if timeout 12 curl -fsS -m 10 -o "\$of" --user "\$USR:\$PW" "http://\$h:8123/?database=\$DBN" --data-binary "\$sql" 2>/tmp/ck.err; then return 0; fi
    echo "    (第 \$i 次失败：\$(head -c 100 /tmp/ck.err | tr '\n' ' '))"
    sleep 3
  done
  return 1
}
for q in "SELECT 1" "SHOW TABLES"; do
  if ck_try "\$HST" "\$q" /tmp/ck_out.txt; then          # 主用生产端点（mnl=VPC / sg=PUBLIC）
    echo "  [OK] \$q → \$(head -c 200 /tmp/ck_out.txt | tr '\n' ' ')"
  else
    echo "  [XX] \$q 失败（生产端点 \$HST 三次超时）"
    if [ "\$H2" != "\$HST" ]; then
      echo "    ↳ 判别：备用端点 \$H2 再试一次"
      ck_try "\$H2" "\$q" /tmp/ck_out2.txt && echo "    [!!] 仅备用端点可达（生产端点异常，须查）" || echo "    [XX] 两端皆不可达（CK/白名单/凭据问题）"
    fi
  fi
done
rm -f /tmp/ck_out.txt /tmp/ck_out2.txt /tmp/ck.err
echo "=== 5) ConfigMap ==="
kubectl -n new-api get cm new-api-config -o jsonpath='{.data.LOG_SQL_CLICKHOUSE_TTL_DAYS}' 2>/dev/null | sed 's/^/  LOG_SQL_CLICKHOUSE_TTL_DAYS=/'; echo
EOF
}

RC=0
LAST=""
run_site() { # $1=site ；输出同时落 $HERE/logs/task17_verify_<ts>/<site>.log
  local s="$1" out
  out="$LOGDIR/$s.log"
  build_body "$s" > /tmp/t17_verify_body.sh
  if bash "$ACK" "$s" /tmp/t17_verify_body.sh "" 12 > "$out" 2>&1; then :; else RC=1; fi
  cat "$out"
  grep -q '\[XX\]' "$out" && RC=1
  LAST="$out"
}
TS=$(date +%Y%m%d-%H%M%S); LOGDIR="$HERE/logs/task17_verify_$TS"; mkdir -p "$LOGDIR"
case "$MODE" in
  mnl|sg) run_site "$MODE" ;;
  both)   run_site mnl; run_site sg ;;
  *) echo "用法：$0 [mnl|sg|both]"; exit 2 ;;
esac
echo ""
say_log="证据目录：$LOGDIR"
echo "$say_log"
[[ "$RC" -eq 0 ]] && echo "结论：全部 [OK]（DSN 注入 + 端点口径 + 鉴权）" || echo "结论：存在 [XX]，见上"
exit "$RC"
