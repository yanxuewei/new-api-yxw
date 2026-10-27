#!/usr/bin/env bash
# set-secrets.sh —— 批量写 GitHub Actions 仓库级 Secrets（本地执行，值不进仓库）
#
# usage:
#   GH_TOKEN=<pat> bash deploy/gitops/bootstrap/set-secrets.sh \
#       ACR_REGISTRY=acr-xxx.ap-southeast-6.cr.aliyuncs.com \
#       ACR_USERNAME='user@account' \
#       ACR_PASSWORD='***' \
#       OPS_REPO_TOKEN='***'
#
# 依赖：curl + python3 + pynacl（pip3 install pynacl）
# 说明：GitHub 要求用仓库公钥做 libsodium sealed box 加密，明文不能直传。
set -euo pipefail

REPO="${GH_REPO:-yanxuewei/new-api-yxw}"
: "${GH_TOKEN:?需要 GH_TOKEN（有 repo scope 的 PAT）}"
command -v python3 >/dev/null || { echo "[!] 缺 python3" >&2; exit 1; }
python3 -c 'import nacl' 2>/dev/null || { echo "[!] 缺 pynacl：pip3 install pynacl" >&2; exit 1; }

KEY_JSON="$(curl -sS -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO}/actions/secrets/public-key")"

for kv in "$@"; do
  name="${kv%%=*}"
  value="${kv#*=}"
  enc="$(KEY_JSON="$KEY_JSON" SECRET_VALUE="$value" python3 - <<'PY'
import base64, os, json
from nacl import encoding, public
kj = json.loads(os.environ["KEY_JSON"])
pk = public.PublicKey(kj["key"].encode(), encoding.Base64Encoder())
sealed = public.SealedBox(pk).encrypt(os.environ["SECRET_VALUE"].encode())
print(base64.b64encode(sealed).decode())
PY
)"
  key_id="$(printf '%s' "$KEY_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["key_id"])')"
  code="$(curl -sS -o /tmp/secret_put.json -w '%{http_code}' -X PUT \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}/actions/secrets/${name}" \
    -d "{\"encrypted_value\":\"${enc}\",\"key_id\":\"${key_id}\"}")"
  if [ "$code" = "201" ] || [ "$code" = "204" ]; then
    echo "  [✓] ${name}"
  else
    echo "  [✗] ${name} -> HTTP ${code}: $(head -c 200 /tmp/secret_put.json)" >&2
  fi
done
rm -f /tmp/secret_put.json

echo "--- 现有 secrets"
curl -sS -H "Authorization: Bearer ${GH_TOKEN}" \
  "https://api.github.com/repos/${REPO}/actions/secrets" \
  | python3 -c 'import sys,json; [print("  "+s["name"]) for s in json.load(sys.stdin).get("secrets",[])]'
