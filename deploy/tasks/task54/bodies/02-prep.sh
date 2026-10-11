#!/bin/bash
# 任务54 侦察②：下载 golang-migrate 二进制 + 准备一个能查 pg_stat_activity 的客户端
set -uo pipefail

echo "### A) 下载 golang-migrate v4.19.1"
mkdir -p /tmp/migbin && cd /tmp/migbin || exit 1
URL="https://github.com/golang-migrate/migrate/releases/download/v4.19.1/migrate.linux-amd64.tar.gz"
if curl -fLsS --max-time 180 -o m.tar.gz "$URL"; then
  echo "downloaded bytes=$(wc -c < m.tar.gz)"
  tar xzf m.tar.gz && ls -la ./migrate && ./migrate -version 2>&1 | head -3
  echo "sha256=$(openssl sha256 -r m.tar.gz 2>/dev/null | awk '{print $1}')"
else
  echo "DOWNLOAD FAIL"
fi

echo "### B) 客户端候选"
for b in python3 pip3 pip psql pg_isready yum dnf; do
  printf '%-10s %s\n' "$b" "$(command -v $b 2>/dev/null || echo MISSING)"
done
python3 -V 2>&1
python3 -m pip --version 2>&1 | head -1

echo "### C) 试 pip 装纯 Python 驱动 pg8000"
python3 -m pip install --quiet --disable-pip-version-check --no-input pg8000 2>&1 | tail -3
python3 -c "import pg8000, sys; print('pg8000 OK', pg8000.__version__)" 2>&1 | tail -2

echo "BODY DONE"
