#!/usr/bin/env bash
# =============================================================================
# deploy/ops/ck_query.sh — 只读查询日志库 ClickHouse（mnl=VPC 端点 / sg=PUBLIC 端点）
# -----------------------------------------------------------------------------
# 为什么这么绕：
#   1) CK 白名单只有 `mnl_app` = 10.0.16.0/20 + 10.0.32.0/20（+ sg_eip），
#      本机（办公网）**连不上** ⇒ 统一借 deploy/lib/ack_remote.sh 在集群节点内执行。
#   2) 端点口径按站点不同：mnl 必须 `-clickhouse.clickhouseserver`（同区私网）、
#      sg 必须 `-public.clickhouseserver`（跨区，2026-09-30 裁定③）⇒ 脚本内断言。
#   3) 凭据从 Secret `new-api-secrets` 的 `LOG_SQL_DSN` 实时解析，**不回显、不落盘、
#      不进证据日志**（本机侧只拿到结果；远端日志经 grep [XX]/[!] 判成败）。
#   4) SQL 以 base64 传递，避免引号 / 反引号 / 中文 / `$` 被多层 shell 吃掉。
#   5) 默认**只读**：首关键字白名单；写操作一律拒绝（要与 task17 的只读纪律一致）。
#
# usage:
#   bash deploy/ops/ck_query.sh <mnl|sg|both> [options] "<SQL>"
#   bash deploy/ops/ck_query.sh mnl [options] -f query.sql
#
# options:
#   -f, --file FILE   从文件读 SQL（与位置参数二选一）
#   --json            输出 JSONEachRow（默认 TabSeparatedWithNames，带表头）
#   --raw             不指定 default_format（用 CK 默认输出）
#   --db NAME         覆盖库名（默认取 DSN 里的库，本部署 = newapi_logs；
#                     ⚠ 查 system.* 需要权限更宽的账号 ckadmin，且须 --db system）
#   --timeout SEC     单次 HTTP 超时秒数（默认 30）
#   --show-dsn        只打印脱敏后的 DSN 结构与端点口径，不执行查询（冒烟自检）
#   --print-body      只在本机打印将要下发的远端脚本，不连集群（离线自检）
#   -h, --help
#
# 例：
#   bash deploy/ops/ck_query.sh mnl "SELECT count() FROM logs"
#   bash deploy/ops/ck_query.sh both --json \
#     "SELECT fromUnixTimestamp(created_at) ts, model_name, quota FROM logs WHERE type=2 ORDER BY created_at DESC LIMIT 5"
#   bash deploy/ops/ck_query.sh mnl --show-dsn
#   bash deploy/ops/ck_query.sh mnl --print-body "SELECT 1"     # 离线看远端脚本长什么样
#
# 退出码：0 全部 [OK] / 1 出现 [XX] 或 [!!] / 2 用法或环境错误
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ACK="$HERE/../lib/ack_remote.sh"

usage() { awk 'NR>1 && /^[^#]/{exit} NR>1{sub(/^# ?/,"");print}' "$0"; }

MODE=""
SQL=""
SQLFILE=""
FMT="TabSeparatedWithNames"
DBOVER=""
TMO=30
SHOW_DSN=0
PRINT_BODY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    mnl|sg|both) MODE="$1"; shift ;;
    -f|--file)   SQLFILE="${2:?--file 需要参数}"; shift 2 ;;
    --json)      FMT="JSONEachRow"; shift ;;
    --raw)       FMT=""; shift ;;
    --db)        DBOVER="${2:?--db 需要参数}"; shift 2 ;;
    --timeout)   TMO="${2:?--timeout 需要参数}"; shift 2 ;;
    --show-dsn)  SHOW_DSN=1; shift ;;
    --print-body) PRINT_BODY=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    --)          shift; [[ $# -gt 0 ]] && { SQL="${SQL:+$SQL }$1"; shift; } ;;
    -*)          echo "未知选项：$1"; usage; exit 2 ;;
    *)           SQL="${SQL:+$SQL }$1"; shift ;;
  esac
done

[[ -n "$MODE" ]] || { echo "缺少站点参数（mnl|sg|both）"; usage; exit 2; }
case "$TMO" in ''|*[!0-9]*) echo "--timeout 必须是整数"; exit 2 ;; esac

if [[ -n "$SQLFILE" ]]; then
  [[ -f "$SQLFILE" ]] || { echo "找不到 SQL 文件：$SQLFILE"; exit 2; }
  SQL="$(cat "$SQLFILE")"
fi
[[ -n "$SQL" || "$SHOW_DSN" = "1" ]] || { echo "缺少 SQL（位置参数或 -f）"; usage; exit 2; }

# base64 编码（优先 python3，与 deploy/lib/ack_remote.sh 的依赖一致；退化为 GNU base64）
b64() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import base64,sys;sys.stdout.write(base64.b64encode(sys.stdin.buffer.read()).decode())'
  else
    base64 | tr -d '\n'
  fi
}
SQL_B64="$(printf '%s' "$SQL" | b64)"

# ---------------------------------------------------------------------------
# 远端 body：占位符替换法（避免多层 heredoc 转义把 SQL 吃掉）
# ---------------------------------------------------------------------------
build_body() {
  local site="$1" body
  body="$(cat <<'BODY'
set -u
SITE='__SITE__'
SQLB64='__SQLB64__'
FMT='__FMT__'
DBOVER='__DB__'
TMO='__TMO__'
SHOWDSN='__SHOWDSN__'

echo "########## ${SITE} ##########"

# --- 1) 取凭据并解析（口令只在内存，绝不 echo） ---
SEC="$(kubectl -n new-api get secret new-api-secrets -o jsonpath='{.data.LOG_SQL_DSN}' 2>/dev/null | base64 -d 2>/dev/null)"
[ -n "$SEC" ] || { echo "  [XX] Secret new-api-secrets 中没有 LOG_SQL_DSN（或不可读）"; exit 1; }

eval "$(python3 - "$SEC" <<'PY'
import re, sys
d = sys.argv[1].strip()
m = re.match(r'^([a-z0-9+]+)://([^:@/]+):([^@]*)@([^:/?]+):(\d+)/([^?]*)(\?.*)?$', d)
if not m:
    print("echo '  [XX] LOG_SQL_DSN 解析失败（结构不符合 scheme://user:pw@host:port/db）'; exit 1")
    raise SystemExit
sch, user, pw, host, port, db, q = m.groups()
print("SCH=%s" % sch)
print("USR=%s" % user)
print("PWL=%d" % len(pw))
print("HST=%s" % host)
print("PRT=%s" % port)
print("DBN=%s" % db)
print("PW=%s" % pw.replace("'", "'\\''"))
PY
)"

# --- 2) 端点口径断言（mnl=VPC / sg=PUBLIC） ---
case "$SITE:$HST" in
  mnl:*clickhouse.clickhouseserver*)
      case "$HST" in *-public.*) echo "  [!!] mnl 用了 PUBLIC 端点（预期 VPC，会多走公网）";;
                     *)          echo "  [OK] 端点=VPC（同区私网，预期口径）";; esac ;;
  sg:*) case "$HST" in *-public.*) echo "  [OK] 端点=PUBLIC（跨区，2026-09-30 裁定③）";;
                       *)          echo "  [XX] sg 指向 VPC 端点 ⇒ 跨区不可达（备站写日志会全丢）";; esac ;;
esac
echo "  scheme=$SCH user=$USR pw_len=$PWL host=$HST port=$PRT db=$DBN"
[ -n "$DBOVER" ] && DBN="$DBOVER"

if [ "$SHOWDSN" = "1" ]; then
  echo "  [i] --show-dsn：仅打印脱敏结构与端点口径，未执行查询"
  exit 0
fi

# --- 3) SQL 解码 + 只读白名单 ---
printf '%s' "$SQLB64" | base64 -d > /tmp/ckq.sql 2>/dev/null || { echo "  [XX] SQL 解码失败"; exit 1; }
python3 - <<'PY' || exit 1
import re, sys
sql = open('/tmp/ckq.sql', encoding='utf-8').read().strip()
if not sql:
    print('  [XX] SQL 为空'); sys.exit(1)
s = re.sub(r'^\s*(?:--[^\n]*\n|/\*.*?\*/)+', '', sql, flags=re.S).lstrip()
m = re.match(r'([A-Za-z_]+)', s)
first = (m.group(1).upper() if m else '')
ALLOW = ('SELECT', 'WITH', 'SHOW', 'DESCRIBE', 'DESC', 'EXISTS', 'EXPLAIN')
if first not in ALLOW:
    print('  [XX] 只允许只读语句：首关键字「%s」不在白名单 %s' % (first or '空', '|'.join(ALLOW)))
    print('       写操作（INSERT/ALTER/DELETE/DROP/CREATE/TRUNCATE/OPTIMIZE/RENAME）一律拒绝')
    sys.exit(1)
body = s[:-1] if s.endswith(';') else s
if ';' in body:
    print('  [!] SQL 内含分号：CK HTTP 一次一发，多语句请分开调用（本脚本按单语句执行）')
print('  [i] 首关键字=%s（只读白名单通过）· SQL %d 字符' % (first, len(sql)))
PY

# --- 4) 执行（HTTP 8123；不用 -w，与 task17 一致避免远端 curl 差异） ---
URL="http://$HST:8123/?database=$DBN"
[ -n "$FMT" ] && URL="$URL&default_format=$FMT"
echo "=== 查询（输出格式：${FMT:-CK 默认}）==="
i=0
while [ "$i" -lt 3 ]; do
  i=$((i+1))
  if timeout $((TMO+5)) curl -fsS -m "$TMO" --user "$USR:$PW" "$URL" \
        --data-binary @/tmp/ckq.sql -o /tmp/ckq.out 2>/tmp/ckq.err; then
    cat /tmp/ckq.out
    echo
    echo "  [OK] $(wc -l < /tmp/ckq.out | tr -d ' ') 行 / $(wc -c < /tmp/ckq.out | tr -d ' ') B"
    rm -f /tmp/ckq.sql /tmp/ckq.out /tmp/ckq.err
    exit 0
  fi
  echo "  (第 $i 次失败：$(head -c 200 /tmp/ckq.err 2>/dev/null | tr '\n' ' '))"
  sleep 3
done
echo "  [XX] 查询失败（重试 3 次）——排查顺序：白名单网段 → 端点口径 → 库名/权限 → SQL 语法"
head -c 500 /tmp/ckq.err 2>/dev/null; echo
rm -f /tmp/ckq.sql /tmp/ckq.out /tmp/ckq.err
exit 1
BODY
)"
  body="${body//__SITE__/$site}"
  body="${body//__SQLB64__/$SQL_B64}"
  body="${body//__FMT__/$FMT}"
  body="${body//__DB__/$DBOVER}"
  body="${body//__TMO__/$TMO}"
  body="${body//__SHOWDSN__/$SHOW_DSN}"
  printf '%s\n' "$body"
}

# ---------------------------------------------------------------------------
# 离线自检
# ---------------------------------------------------------------------------
if [[ "$PRINT_BODY" = "1" ]]; then
  echo "===== 远端脚本（站点 $( [[ "$MODE" = "both" ]] && echo mnl || echo "$MODE")）====="
  build_body "$( [[ "$MODE" = "both" ]] && echo mnl || echo "$MODE")"
  echo "===== （未连接集群；--print-body 到此结束）====="
  exit 0
fi

[[ -x "$ACK" || -f "$ACK" ]] || { echo "缺 $ACK（本脚本依赖它下发到集群节点）"; exit 2; }

# deploy/lib/ack_remote.sh 的缓存目录 /tmp/ackctl-<site> 可能被历史 root 运行创建成 root:root，
# 当前用户写不进去（写 body 时 PermissionError）⇒ 自动降级到用户自有目录并提示修复。
prepare_ackdir() { # $1=mnl|sg
  local site="$1"
  local d="/tmp/ackctl-$site" me
  me="$(id -un)"
  [[ -e "$d" && ! -w "$d" ]] || return 0
  echo "[!] $d 不可写（owner=$(stat -c '%U' "$d" 2>/dev/null)），改用 $d-$me 并重新拉取 kubeconfig" >&2
  echo "    永久修复：sudo chown -R $me $d" >&2
  export ACKCTL_DIR="$d-$me"
}

TS="$(date +%Y%m%d-%H%M%S)"
LOGDIR="$HERE/../logs/ck_query_$TS"; mkdir -p "$LOGDIR"

run_site() { # $1=mnl|sg
  local s="$1" out rc=0
  out="$LOGDIR/$s.log"
  prepare_ackdir "$s"
  build_body "$s" > "$LOGDIR/body_$s.sh"
  echo "───── $s ─────"
  if ! bash "$ACK" "$s" "$LOGDIR/body_$s.sh" "" 24 > "$out" 2>&1; then rc=1; fi
  cat "$out"
  grep -q '\[XX\]' "$out" && rc=1
  grep -q '\[!!\]' "$out" && rc=1
  rm -f "$LOGDIR/body_$s.sh"
  return "$rc"
}

RC=0
case "$MODE" in
  mnl|sg) run_site "$MODE" || RC=1 ;;
  both)   run_site mnl || RC=1; run_site sg || RC=1 ;;
esac

echo ""
echo "证据目录：$LOGDIR"
[[ "$RC" -eq 0 ]] && echo "结论：全部 [OK]" || echo "结论：存在 [XX]/[!!]，见上"
exit "$RC"
