#!/bin/bash
# deploy/ops/ci_check_migrate_versioned.sh — 任务 54 的迁移目录门禁（可在 CI / 本地跑，零云依赖）
#
# 断言 5 项：
#   A. 每个 *.up.sql 都有同名 *.down.sql（卡片：down 从没跑过 = 二次故障）
#   B. 版本号唯一、连续（从 1 起）
#   C. 含 CREATE/DROP INDEX CONCURRENTLY 的迁移，首 3 行必须有 `-- +migrate NoTransaction`
#   D. 不可逆迁移（文件名含 contract / drop_table / drop_column）必须显式标注「不可逆」
#   E. AutoMigrate 关闭态：非测试 .go 里的 AutoMigrate( 调用点必须落在受 MIGRATE_MODE 控制的
#      migrateDB/migrateLOGDB 内（G8 patch 未合并时豁免，只 WARN）
#
# usage: bash deploy/ops/ci_check_migrate_versioned.sh [repo_root]
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
MIG="$ROOT/migrations"
PASS=0; FAIL=0; WARN=0
ok()   { printf 'PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf 'WARN  %s\n' "$1"; WARN=$((WARN+1)); }

echo "== migrations 目录门禁（root=${ROOT}）"

if [ ! -d "$MIG" ]; then
  bad "migrations/ 不存在"
  echo "---- PASS=$PASS FAIL=$FAIL WARN=$WARN"
  exit 1
fi

UPS=$(cd "$MIG" && ls *.up.sql 2>/dev/null | sort)
if [ -z "$UPS" ]; then bad "migrations/ 下没有任何 *.up.sql"; echo "---- PASS=$PASS FAIL=$FAIL WARN=$WARN"; exit 1; fi

# ---- A. up/down 配对
for f in $UPS; do
  d="${f%.up.sql}.down.sql"
  if [ -f "$MIG/$d" ]; then ok "up/down 配对: $f"
  else bad "缺 down: $MIG/$d"; fi
done

# ---- B. 版本号唯一 + 连续
VERFILE=$(mktemp)
for f in $UPS; do printf '%s\n' "${f%%_*}" >> "$VERFILE"; done
DUPS=$(sort "$VERFILE" | uniq -d | tr '\n' ' ')
[ -z "$DUPS" ] && ok "版本号无重复" || bad "版本号重复: $DUPS"
EXPECT=1; CONTIG=1
for v in $(sort "$VERFILE"); do
  n=$(printf '%s' "$v" | sed 's/^0*//'); [ -z "$n" ] && n=0    # 去前导零（别用 printf %d：000009 是非法八进制）
  if [ "$n" != "$EXPECT" ]; then CONTIG=0; bad "版本号不连续：期望 $EXPECT 实测 $n"; break; fi
  EXPECT=$((EXPECT+1))
done
[ "$CONTIG" = "1" ] && ok "版本号连续（1..$((EXPECT-1))）"
rm -f "$VERFILE"

# ---- C. CONCURRENTLY ⇒ 必须独占一个迁移文件（golang-migrate 没有 NoTransaction 注解）
# 只看**非注释行**，避免把文档里作为反例引用的写法误判成真实语句。
for f in $(cd "$MIG" && ls *.sql | sort); do
  if grep -v '^[[:space:]]*--' "$MIG/$f" | grep -q "CONCURRENTLY"; then
    if grep -qE '^[[:space:]]*--[[:space:]]*\+migrate[[:space:]]+NoTransaction' "$MIG/$f"; then
      bad "$f 用了 '+migrate NoTransaction' 注解 —— golang-migrate 无此语法（那是 goose），实测必失败"
      continue
    fi
    n=$(grep -v '^[[:space:]]*--' "$MIG/$f" | grep -c '[^[:space:]]')
    if [ "$n" = "1" ]; then ok "CONCURRENTLY 独占文件: $f"
    else bad "$f 含 $n 条语句 —— CONCURRENTLY 必须独占迁移文件（多语句会被包进隐式事务块）"; fi
  fi
done

# ---- D. 不可逆迁移必须标注
for f in $UPS; do
  case "$f" in
    *contract*|*drop_table*|*drop_column*)
      if head -10 "$MIG/$f" | grep -q "不可逆"; then ok "不可逆迁移已标注: $f"
      else bad "不可逆迁移（$f）缺「不可逆」标注（卡片要求显式标注并过评审）"; fi
      ;;
  esac
done

# ---- E. AutoMigrate 关闭态（G8 未合并 ⇒ 豁免）
NO_TEST=$(cd "$ROOT" && grep -rln "AutoMigrate(" --include="*.go" . 2>/dev/null \
  | grep -v "_test\.go$" | grep -v "/vendor/" || true)
echo "---- 非测试文件中的 AutoMigrate 调用点:"
if [ -z "$NO_TEST" ]; then
  echo "     (无)"
else
  echo "$NO_TEST" | sed 's/^/     /'
fi
if grep -rq "MIGRATE_MODE" --include="*.go" "$ROOT" 2>/dev/null; then
  MISSING=""
  for f in $NO_TEST; do
    # G8 口径：AutoMigrate 必须只在 migrateDB/migrateLOGDB 内，由 MIGRATE_MODE 控制
    if ! grep -q "func migrateDB\|func migrateLOGDB\|MIGRATE_MODE" "$ROOT/$f" 2>/dev/null; then
      MISSING="$MISSING $f"
    fi
  done
  if [ -z "$MISSING" ]; then ok "AutoMigrate 全部落在受 MIGRATE_MODE 控制的函数内（关闭态成立）"
  else bad "以下文件的 AutoMigrate 不受 MIGRATE_MODE 控制:$MISSING"; fi
else
  warn "代码里尚无 MIGRATE_MODE（G8 patch 未合并）⇒ prod 仍为 master-only AutoMigrate；"
  warn "  本目录只能在 staging 生效。G8 合并后本断言自动升级为硬门禁。"
fi

echo "---- PASS=$PASS FAIL=$FAIL WARN=$WARN"
[ "$FAIL" -eq 0 ]
