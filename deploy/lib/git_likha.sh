#!/usr/bin/env bash
# deploy/lib/git_likha.sh —— 用 GITHUB_TOKEN_LIKHA 走 HTTPS 访问 ZYKJ-1688 组织下的所有仓
#
# 背景（2026-11-01）：ZYKJ-1688 的 GitHub **主用 SSH 密钥**——Windows ~/.ssh/id_ed25519（账号 yanxuewei）
# 在 WSL 里的同一份是 /root/.ssh/ops_key，已配进 /root/.ssh/config ⇒ **裸 git push/pull 直接可用**。
# 本脚本是「备用通道」：当需要 HTTPS + token 时才用（例如 SSH 被临时禁用）。
# 注意 GITHUB_TOKEN_LIKHA（/home/fanyan/.bashrc:243，账号 ZY68681688）当前是**只读** fine-grained PAT：
#   读全通（fetch / ls-remote / contents GET 200），写 403（Write access to repository not granted；
#   blob 探针 Resource not accessible by personal access token）⇒ 只能用它拉，不能推。
#   要用它推需把 Contents 改成 Read and write，或换 classic PAT（repo scope）。
#
# ⚠ .bashrc 里的 export 在**非交互 shell 读不到**（文件开头的 `case $- in *i*)` 守卫会提前 return）
#   ⇒ root 的 `bash -c` / `bash -lc` 里 $GITHUB_TOKEN_LIKHA 都是空的。本脚本因此做两级取值：
#   ① 环境变量里有就用；② 否则直接从 fanyan 的 .bashrc 里抠出来。
#
# usage:
#   bash deploy/lib/git_likha.sh <repo_dir> <git args...>
# 例：
#   bash deploy/lib/git_likha.sh /mnt/e/git_code/new-api-likha-ops fetch origin
#   bash deploy/lib/git_likha.sh /mnt/e/git_code/new-api-likha-ops push origin main
#   bash deploy/lib/git_likha.sh /mnt/e/git_code/new-api-likha-ops clone ...   # 不适用，克隆请见下
#
# 克隆新仓：先 clone 普通 HTTPS 地址，再让本脚本 fetch；或直接
#   git clone "https://x-access-token:${GITHUB_TOKEN_LIKHA}@github.com/ZYKJ-1688/<repo>.git"
#
# 安全：token 只经环境变量传给 git 子进程（GIT_CONFIG_*），不写进 argv、不落 .git/config、不打印。
set -uo pipefail

TOKEN="${GITHUB_TOKEN_LIKHA:-}"
if [ -z "$TOKEN" ]; then
  TOKEN=$(grep -m1 '^export GITHUB_TOKEN_LIKHA=' /home/fanyan/.bashrc 2>/dev/null \
          | sed -e 's/^export GITHUB_TOKEN_LIKHA=//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//" | tr -d '\r')
fi
if [ -z "$TOKEN" ]; then
  echo "[!] 拿不到 GITHUB_TOKEN_LIKHA（既不在环境变量里，也不在 /home/fanyan/.bashrc）" >&2
  exit 1
fi

REPO="${1:?usage: git_likha.sh <repo_dir> <git args...>}"
shift

exec env \
  GIT_TERMINAL_PROMPT=0 \
  GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0="url.https://x-access-token:${TOKEN}@github.com/.insteadOf" \
  GIT_CONFIG_VALUE_0="git@github.com:" \
  git -C "$REPO" "$@"
