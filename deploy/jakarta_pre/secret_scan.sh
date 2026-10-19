#!/bin/bash
# deploy/jakarta_pre/secret_scan.sh —— 交付前凭据扫描：**只输出计数，任何命中内容都不打印**
#
# 为什么要它（台账 §18.5 / §18.7 两次都是我自己的打码失误造成的外泄）：
#   "先取子串再打码"这条路的正确性依赖于**穷举所有 DSN 方言**（PG `postgres://`、
#   CK `clickhouse://`、MySQL `user:pass@tcp(host:port)/db` 无 scheme、…），而方言集合我记不全
#   ⇒ 必然漏。反过来，"**拿保管目录里的真实值去比对，只报有几个命中**"与方言无关，不可能漏。
#   所以：判"仓库里有没有明文口令"用本脚本，不要用 grep 打印内容的那种写法。
#
# usage: bash deploy/jakarta_pre/secret_scan.sh [文件或目录 ...]   不给参数 = 扫 deploy/jakarta_pre 与两份主文档
set -uo pipefail
SECDIRS="/root/.deploy_secrets /root/.deploy_secrets_dev"
TARGETS="${*:-new-api-yxw/deploy/jakarta_pre new-api-yxw/deploy/jakarta_dev_ledger.md new-api-yxw/deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md}"

# 收集待扫文件（目录递归，排除本脚本自身与 .git）
FILES=$(for t in $TARGETS; do
  if [ -d "$t" ]; then find "$t" -type f \( -name '*.md' -o -name '*.sh' -o -name '*.yaml' -o -name '*.json' -o -name '*.sql' \) 2>/dev/null
  else [ -f "$t" ] && printf '%s\n' "$t"; fi
done | sort -u)
[ -n "$FILES" ] || { echo "[!] 没有可扫描的文件（检查路径）"; exit 1; }
N=$(printf '%s\n' "$FILES" | wc -l)
echo "== 扫描面：$N 个文件；比对源：$SECDIRS 里的每一个凭据值（值本身不外显）"

TOTAL=0
for d in $SECDIRS; do
  [ -d "$d" ] || { echo "  [skip] 保管目录不存在：$d"; continue; }
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    # 私钥/证书本体不比对：它们是 PEM（多行、超长），拿整串去 grep 只会因参数过长报错，
    # 而且"私钥有没有抄进仓库"应该用 PEM 头这种形态判（见下面的兜底段），不是用整串比对。
    case "$(basename "$f")" in *KEY*|*key*|*.pem|*CRT*|*crt*) continue ;; esac
    v=$(head -c 4096 "$f" | tr -d '\r\n')
    [ "${#v}" -ge 8 ] || continue          # 短值（如纯数字端口）比对会产生大量假阳性，跳过
    [ "${#v}" -le 200 ] || continue        # 超长值多半是 PEM 或打包内容，同上不用整串比对
    # 只统计"该值出现在待扫文件中的次数"，绝不输出行内容
    c=$(printf '%s\n' "$FILES" | xargs -d '\n' grep -F -o -- "$v" 2>/dev/null | wc -l)
    if [ "$c" -gt 0 ]; then
      printf '  [命中] %-28s 次数=%s ⇒ 该凭据已出现在仓库文件里，按泄露处理（本脚本不打印任何内容）\n' "$(basename "$f")" "$c"
      TOTAL=$((TOTAL + c))
    fi
  done
done
printf '== 结论：%s\n' "$([ "$TOTAL" -eq 0 ] && echo "零命中 ⇒ 保管目录中的任何凭据值都未出现在扫描面内" || echo "$TOTAL 处命中 ⇒ 必须逐条处置（脱敏 + 轮换），且不得把这些文件外发")"

echo "== 形态兜底（只报计数，不报内容）：无 scheme 的 MySQL 形态 / 带口令的通用 DSN 形态"
for pat in '@tcp(' '://[A-Za-z0-9_-]*:[^ "@]*@' 'eyJ[A-Za-z0-9_-]{20,}' '-----BEGIN'; do
  c=$(printf '%s\n' "$FILES" | xargs -d '\n' grep -E -o -- "$pat" 2>/dev/null | wc -l)
  printf '  %-32s 命中=%s\n' "$pat" "$c"
done
# 上面 `://user:pw@` 形态若命中>0，必须把每一处**归类**掉才算干净：真口令 / 已打码 / 文档占位符。
# 归类同样只报计数（这三个标记本身不是凭据，出现即说明那一处不是明文）。
echo "== 归类计数（应与上面的 DSN 形态命中数能对上，对不上就说明有未归类的那一处）"
for pat in '\*\*\*@' 'user:pass@' '<账号>:<口令>@' 'PLACEHOLDER' 'XXX@'; do
  c=$(printf '%s\n' "$FILES" | xargs -d '\n' grep -E -o -- "$pat" 2>/dev/null | wc -l)
  printf '  %-24s = %s\n' "$pat" "$c"
done
echo "--- 本脚本全程只输出计数与文件名；命中时也不得改成打印内容"
