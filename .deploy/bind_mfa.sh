#!/usr/bin/env bash
# 绑定虚拟 MFA 设备到 RAM 用户（幂等：已绑定则直接报成功）
# 用法:
#   bash bind_mfa.sh <admin|ops> <验证码1> <验证码2>   绑定
#   bash bind_mfa.sh status                           查看绑定状态
set -uo pipefail

ALIYUN_BIN="$HOME/.workbuddy/binaries/aliyun-cli/aliyun"
REGION="ap-southeast-6"
ACCOUNT="5108890064395960"

USER_NAME="${1:-}"
CODE1="${2:-}"
CODE2="${3:-}"

if [[ -z "$USER_NAME" ]]; then
  cat <<'USAGE'
用法: bash bind_mfa.sh <admin|ops> <验证码1> <验证码2>
      bash bind_mfa.sh status

步骤:
  1. 打开认证器 App（Google Authenticator / Microsoft Authenticator / 1Password）
  2. 扫描二维码: ~/.aliyun/mfa/newapi-<user>-mfa.png
     或手动输入 Base32 密钥（见 ~/.aliyun/newapi-ram-secrets.json）
  3. 取当前 6 位验证码 → 验证码1
  4. 等 30 秒 App 刷新 → 取新 6 位验证码 → 验证码2
  5. 立刻执行本脚本（两个码各 30 秒有效期，动作要快）

示例:
  bash bind_mfa.sh admin 123456 654321
  bash bind_mfa.sh status
USAGE
  exit 1
fi

# 查询某用户已绑定的 MFA 序列号；未绑定则输出空
bound_serial() {
  local u="$1" r
  r=$("$ALIYUN_BIN" ram GetUserMFAInfo --UserName "$u" --region "$REGION" 2>&1)
  printf '%s' "$r" | sed -n 's/.*"SerialNumber":"\([^"]*\)".*/\1/p'
}

show_status() {
  local u s
  echo "RAM MFA 绑定状态 (账号 $ACCOUNT):"
  for u in admin ops; do
    s=$(bound_serial "$u")
    if [[ -n "$s" ]]; then
      printf '  %-6s [已绑定] %s\n' "$u" "$s"
    else
      printf '  %-6s [未绑定]\n' "$u"
    fi
    sleep 2
  done
}

if [[ "$USER_NAME" == "status" ]]; then
  show_status
  exit 0
fi

[[ "$USER_NAME" == "admin" || "$USER_NAME" == "ops" ]] || { echo "仅支持 admin / ops / status"; exit 1; }

if [[ -z "$CODE1" || -z "$CODE2" ]]; then
  echo "缺少验证码。用 bash bind_mfa.sh status 查状态，或补全两码。"
  exit 1
fi

SERIAL="acs:ram::${ACCOUNT}:mfa/newapi-${USER_NAME}-mfa"

echo "绑定: $USER_NAME"
echo "设备: $SERIAL"

# 幂等前置检查：已绑定则不重复调用 BindMFADevice
existing=$(bound_serial "$USER_NAME")
if [[ -n "$existing" ]]; then
  if [[ "$existing" == "$SERIAL" ]]; then
    echo "[OK] $USER_NAME 已绑定该 MFA 设备，无需重复绑定"
  else
    echo "[WARN] $USER_NAME 已绑定其他 MFA 设备: $existing"
    echo "       如需换绑，先执行:"
    echo "       $ALIYUN_BIN ram UnbindMFADevice --UserName $USER_NAME --region $REGION"
  fi
  exit 0
fi

echo
out=$("$ALIYUN_BIN" ram BindMFADevice \
  --UserName "$USER_NAME" \
  --SerialNumber "$SERIAL" \
  --AuthenticationCode1 "$CODE1" \
  --AuthenticationCode2 "$CODE2" \
  --region "$REGION" 2>&1)

if echo "$out" | grep -q '"RequestId"'; then
  echo "[OK] $USER_NAME MFA 绑定成功"
  echo "验证:"
  "$ALIYUN_BIN" ram GetUserMFAInfo --UserName "$USER_NAME" --region "$REGION"
  exit 0
fi

# 并发/时序竞态：调用瞬间被他人绑定
if echo "$out" | grep -q 'EntityAlreadyExists'; then
  echo "[OK] $USER_NAME 已存在绑定（本次为重复调用），实际状态:"
  "$ALIYUN_BIN" ram GetUserMFAInfo --UserName "$USER_NAME" --region "$REGION"
  exit 0
fi

echo "[FAIL] $out"
cat <<'HINT'

常见原因:
  - AuthenticationCode1/2 非连续两码，或已过期 → 重新取码
  - InvalidAuthenticationCode → 手机时间不同步（认证器需开启自动校时）
  - InvalidUser.MFADevice → 设备名不匹配，核对 SerialNumber
HINT
exit 1
