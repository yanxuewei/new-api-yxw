#!/usr/bin/env bash
set -euo pipefail
WORK=/mnt/c/Users/pc260829/.workbuddy/binaries/node/workspace/omnitrade-web
BUILD=$(tr -d '\r\n' < "$WORK/LATEST_OUTPUT_DIR")
[[ "$BUILD" =~ ^dist-logout-[0-9]+$ ]]
ROOT=/mnt/e/git_code/new-api-yxw/likha/ops/omnitrade-modules
STAMP=$(date +%Y%m%d-%H%M%S)
RELEASE=frontend-ai-$STAMP
mkdir -p "$ROOT/$RELEASE/dist"
cp -a "$WORK/$BUILD/." "$ROOT/$RELEASE/dist/"
tar -czf "$ROOT/$RELEASE.tar.gz" -C "$ROOT" "$RELEASE" erp-web/src/api/ai.ts erp-web/src/views/ai
scp -q -i /root/.ssh/ops_key "$ROOT/$RELEASE.tar.gz" root@8.212.176.207:/opt/OmniTradeERP/ops/module-repair/
ssh -o BatchMode=yes -i /root/.ssh/ops_key root@8.212.176.207 "tar -xzf /opt/OmniTradeERP/ops/module-repair/$RELEASE.tar.gz -C /opt/OmniTradeERP/ops/module-repair && python3 /opt/OmniTradeERP/ops/module-repair/deploy_frontend.py $RELEASE && docker compose -f /opt/OmniTradeERP/docker-compose.minimal.yml up -d --no-build --wait --wait-timeout 120 frontend && cp /opt/OmniTradeERP/ops/module-repair/erp-web/src/api/ai.ts /opt/OmniTradeERP/erp-web/src/api/ai.ts && cp /opt/OmniTradeERP/ops/module-repair/erp-web/src/views/ai/*.vue /opt/OmniTradeERP/erp-web/src/views/ai/"
printf '%s\n' "$RELEASE" > "$ROOT/ai-frontend-release.txt"
