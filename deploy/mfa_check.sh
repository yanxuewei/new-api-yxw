#!/usr/bin/env bash
# 校验认证器 App 上显示的验证码归属哪个 RAM 用户
# 用法: bash mfa_check.sh <6位验证码>
# 作用: 判断码属于 admin 还是 ops、以及手机时间是否偏移
set -uo pipefail

SECRETS="$HOME/.aliyun/newapi-ram-secrets.json"
CODE="${1:-}"

[[ "$CODE" =~ ^[0-9]{6}$ ]] || { echo "用法: bash mfa_check.sh <6位验证码>"; exit 1; }
[[ -f "$SECRETS" ]] || { echo "找不到 $SECRETS"; exit 1; }

/usr/bin/python3 - "$CODE" "$SECRETS" <<'PY'
import sys, json, base64, hmac, hashlib, struct, time

code = sys.argv[1]
d = json.load(open(sys.argv[2]))
seeds = {u: v["Base32StringSeed"] for u, v in d["virtual_mfa"].items() if isinstance(v, dict)}

def totp(seed, w, step=30, digits=6):
    key = base64.b32decode(seed.upper() + "=" * ((8 - len(seed) % 8) % 8))
    h = hmac.new(key, struct.pack(">Q", w), hashlib.sha1).digest()
    o = h[-1] & 0x0F
    return str((struct.unpack(">I", h[o:o+4])[0] & 0x7FFFFFFF) % 10 ** digits).zfill(digits)

W = int(time.time()) // 30
hits = []
for name, seed in sorted(seeds.items()):
    for off in range(-10, 11):        # 前后各 10 个窗口 = ±5 分钟
        if totp(seed, W + off) == code:
            hits.append((name, off))

print(f"本机时间 {time.strftime('%H:%M:%S')}   当前窗口剩余 {30 - int(time.time()) % 30}s")
print(f"待查验证码: {code}")
print()
if not hits:
    print("  ✗ 无匹配 —— 该码不属于 admin / ops 任一 seed")
    print("    可能原因: 扫错二维码 / 手工输入的 Base32 有误 / 码值敲错")
else:
    for name, off in hits:
        if off == 0:
            verdict = "✓ 匹配，且手机时间与本机一致"
        elif off < 0:
            verdict = f"✓ 匹配，但该码是 {abs(off) * 30} 秒前的（已过期）"
        else:
            verdict = f"✓ 匹配，但该码是 {off * 30} 秒后才生效的（手机时间偏快 {off * 30}s）"
        print(f"  用户 {name:6s}  窗口偏移 {off:+d}  {verdict}")
print()
print("提示: admin 与 ops 二维码的 label 可能同名，App 里会出现两条一模一样的条目。")
print("      如需区分，用 Base32 手工添加并把名称改成 newapi-admin-mfa / newapi-ops-mfa。")
PY
