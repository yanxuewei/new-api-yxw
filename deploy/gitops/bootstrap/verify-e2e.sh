#!/usr/bin/env bash
# verify-e2e.sh —— GitOps 端到端验收（业务仓 CI → ops 仓 → ArgoCD → 线上版本）
#
# 验收链路：
#   1. 最近一次 dev-build 运行结论
#   2. ops 仓最新 bump commit（应为 chore(jkt-dev): dev-<日期>-<sha7> (src=<sha7>)）
#   3. ops 仓 overlay 里的 image digest
#   4. 集群侧 ArgoCD app 状态 + 工作负载镜像
#   5. 线上 /api/status 的 version（必须等于 CI 产出的 tag）
#
# usage: bash deploy/gitops/bootstrap/verify-e2e.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
BIZ="yanxuewei/new-api-yxw"
OPS="yanxuewei/new-api-yxw-ops"
ENV_DIR="overlays/jkt-dev"

if [ -n "${GH_TOKEN:-}" ]; then
  TOKEN="$GH_TOKEN"
else
  # GIT_TERMINAL_PROMPT=0：WSL 里没配 credential helper 时立即失败，而不是卡住等输入
  TOKEN="$(printf 'protocol=https\nhost=github.com\n\n' | GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null | sed -n 's/^password=//p')"
fi
[ -n "$TOKEN" ] || { echo "[!] 取不到 GitHub token：请 GH_TOKEN=xxx bash $0" >&2; exit 1; }
api() { curl -s -H "Authorization: Bearer ${TOKEN}" -H "Accept: application/vnd.github+json" "$1"; }

echo "=== 1. 最近一次 dev-build"
api "https://api.github.com/repos/${BIZ}/actions/runs?per_page=1" | python3 -c "
import sys,json
r=json.load(sys.stdin)['workflow_runs'][0]
print(f\"  run={r['id']} {r['status']}/{r['conclusion']} head={r['head_sha'][:7]}\")
"

echo "=== 2. ops 仓最近 3 个 commit"
api "https://api.github.com/repos/${OPS}/commits?per_page=3" | python3 -c "
import sys,json
for c in json.load(sys.stdin):
    print('  '+c['sha'][:7], c['commit']['author']['date'], c['commit']['message'].splitlines()[0][:88])
"

echo "=== 3. ops 仓 ${ENV_DIR} 的镜像"
api "https://api.github.com/repos/${OPS}/contents/${ENV_DIR}/kustomization.yaml" | python3 -c "
import sys,json,base64
d=json.load(sys.stdin)
if 'content' not in d:
    print('  [!] 读取失败:', d.get('message')); raise SystemExit
for line in base64.b64decode(d['content']).decode().splitlines():
    if line.strip().startswith(('newName:','digest:','newTag:')):
        print('  '+line.strip())
"

echo "=== 4. 集群侧"
bash "${REPO_ROOT}/deploy/lib/ack_remote_jkt_dev.sh" "${HERE}/verify.sh" 2>&1 \
  | grep -E 'jkt-dev |sync=|argocd-(server|repo-server|application)' | head -8

echo "=== 5. 线上版本"
curl -sS -m 20 -o /tmp/e2e_status.json -w '  http=%{http_code} time=%{time_total}s\n' https://dev.likha.hk/api/status
grep -o '"version":"[^"]*"' /tmp/e2e_status.json | head -1 | sed 's/^/  /'

cat <<'NOTE'

判据：第 5 步的 version 必须等于第 1 步 run 的 head sha（形如 dev-YYYYMMDD-<sha7>）。
不一致说明 ArgoCD 还没收敛（等 3 min）或 ops 回写被跳过。
NOTE
