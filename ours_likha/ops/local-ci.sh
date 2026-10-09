#!/usr/bin/env bash
# ours_likha/ops/local-ci.sh
#
# 本地复现 .github/workflows/ci.yml 的**全部** job。
# 纪律第 5 条：merge 冲突解决后必须跑全量测试，sync PR 的 CI 不允许 skip 任何 job。
#   backend : go vet / go build（root + relaykit 两个 module）、make test
#   frontend: bun install / bun run typecheck / bun run test（web/）
#
# 用法: bash ours_likha/ops/local-ci.sh [backend|frontend|all]   （默认 all）
set -uo pipefail
export GOWORK=off   # 与 CI 的 env 保持一致

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PASS=0
FAIL=0
step() {
  local desc="$1"; shift
  echo ">>> ${desc}"
  if "$@"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "!!! FAILED: ${desc}"
  fi
}

run_backend() {
  # main 包 embed 了被 gitignore 的 web/dist；CI 会建占位文件
  [ -f web/dist/index.html ] || { mkdir -p web/dist; : > web/dist/index.html; }
  step "backend: go vet ./..."          go vet ./...
  step "backend: relaykit: go vet ./..." bash -c 'cd relaykit && go vet ./...'
  step "backend: go build ./..."        go build ./...
  step "backend: relaykit: go build"    bash -c 'cd relaykit && go build ./...'
  step "backend: make test"             make test
}

run_frontend() {
  if command -v bun >/dev/null 2>&1; then
    step "frontend: bun install"           bash -c 'cd web && bun install --frozen-lockfile'
    step "frontend: bun run typecheck"     bash -c 'cd web && bun run typecheck'
    step "frontend: bun run test"          bash -c 'cd web && bun run test'
  else
    echo "!!! SKIP frontend: 未找到 bun（CI 中该 job 不允许 skip，请装 Linux 版 bun 后重跑）"
    FAIL=$((FAIL + 1))
  fi
}

case "${1:-all}" in
  backend)  run_backend ;;
  frontend) run_frontend ;;
  all)      run_backend; run_frontend ;;
  *)        echo "用法: $0 [backend|frontend|all]"; exit 2 ;;
esac

echo "== local-ci 结果: PASS=${PASS} FAIL=${FAIL} =="
if [ "$FAIL" -eq 0 ]; then echo "✅ 全量 job 通过"; else echo "❌ 存在失败/SKIP job"; fi
exit "$FAIL"
