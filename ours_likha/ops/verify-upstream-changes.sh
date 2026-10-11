#!/usr/bin/env bash
# ours_likha/ops/verify-upstream-changes.sh
#
# 对照根目录 UPSTREAM_CHANGES.md，机械校验本仓库对上游的定制是否全部在位。
#   · 上游 sync / merge 前后必跑（纪律第 2、5 条）
#   · 退出码 0 = 全部在位；非 0 = 有定制项被覆盖或冲突未解
#
# 用法: bash ours_likha/ops/verify-upstream-changes.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PASS=0
FAIL=0
norm() { tr -d '\r' < "$1"; }

# expect_n <file> <needle> <expected_count> <desc>
expect_n() {
  local f="$1" needle="$2" n="$3" desc="$4" c
  if [ ! -f "$f" ]; then
    printf '  MISS  %-44s (文件不存在: %s)\n' "$desc" "$f"; FAIL=$((FAIL+1)); return
  fi
  c=$(norm "$f" | grep -oF -- "$needle" | wc -l | tr -d ' ')
  if [ "$c" = "$n" ]; then
    printf '  ok    %-44s (%s)\n' "$desc" "$c"; PASS=$((PASS+1))
  else
    printf '  FAIL  %-44s 期望 %s 处, 实际 %s 处\n' "$desc" "$n" "$c"; FAIL=$((FAIL+1))
  fi
}

# expect_absent <file> <needle> <desc>
expect_absent() {
  local f="$1" needle="$2" desc="$3" c
  if [ ! -f "$f" ]; then
    printf '  MISS  %-44s (文件不存在: %s)\n' "$desc" "$f"; FAIL=$((FAIL+1)); return
  fi
  c=$(norm "$f" | grep -oF -- "$needle" | wc -l | tr -d ' ')
  if [ "$c" = "0" ]; then
    printf '  ok    %-44s (0 残留)\n' "$desc"; PASS=$((PASS+1))
  else
    printf '  FAIL  %-44s 仍残留 %s 处\n' "$desc" "$c"; FAIL=$((FAIL+1))
  fi
}

echo "== UPSTREAM_CHANGES 定制项在位检查 =="

MS='15:04:05.000'
expect_n common/sys_log.go         "t.Format(\"2006/01/02 - ${MS}\")"                3 'common/sys_log.go [SYS]/[FATAL] 毫秒 x3'
expect_n logger/logger.go          "now.Format(\"2006/01/02 - ${MS}\")"              1 'logger/logger.go [INFO]/[ERR] 毫秒 x1'
expect_n middleware/logger.go      "param.TimeStamp.Format(\"2006/01/02 - ${MS}\")"  1 'middleware/logger.go [GIN] 毫秒 x1'

echo "-- 反向检查：日志时间不应残留秒级旧格式 --"
expect_absent common/sys_log.go    "t.Format(\"2006/01/02 - 15:04:05\")"             'common/sys_log.go 无秒级残留'
expect_absent logger/logger.go     "now.Format(\"2006/01/02 - 15:04:05\")"           'logger/logger.go 无秒级残留'
expect_absent middleware/logger.go "param.TimeStamp.Format(\"2006/01/02 - 15:04:05\")" 'middleware/logger.go 无秒级残留'

echo
echo "== 结果: PASS=${PASS} FAIL=${FAIL} =="
if [ "$FAIL" -eq 0 ]; then
  echo "✅ 定制项全部在位"
else
  echo "❌ 有定制项缺失/冲突，请对照 UPSTREAM_CHANGES.md 处理"
fi
exit "$FAIL"
