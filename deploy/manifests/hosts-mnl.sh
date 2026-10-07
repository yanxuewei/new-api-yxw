#!/bin/bash
# hosts-mnl.sh — 给本机 /etc/hosts 增删「马尼拉主站」域名映射（对称件：hosts-sg-standby.sh）
#
# 用途：ALB 走 Host 路由。虽然已 apply `ingress-mnl-stable-ip.yaml`（无 Host Ingress，
#       IP 直访本就 200），但按**域名**访问仍需要 Host 头 ⇒ 本脚本用于
#       ① 用域名而非 IP 验收；② 证书到位后无缝切到 https://域名。
#
# 用法：
#   ./hosts-mnl.sh add       # 加映射（幂等，重复执行不叠加）
#   ./hosts-mnl.sh del       # 删映射
#   ./hosts-mnl.sh status    # 看当前映射 + 直测两 AZ
#
# 集群/资源：cd57e40ce9a634c1698c2f5c5e09bd93c（ap-southeast-6）
#   ALB alb-1riqckb1h8ezm0y7s9 → 8.212.161.49(6a) / 8.212.183.7(6b)
#   Ingress new-api-verify（host ph-verify.internal.likha.hk，order 1）  → svc new-api-stable:80
#   Ingress new-api-stable-ip（无 host，order 50）                        → svc new-api-stable:80
#   Ingress new-api-catchall-404（无 host，order 100）                     → FixedResponse 404（被 order 50 遮蔽）
#
# 说明：
#   · 改 /etc/hosts 需 root，脚本内部自动 sudo（非 root 时）。
#   · 用 BEGIN/END 标记包裹，del 只删自己这一段，**不动系统其他行**。
#   · macOS 加完自动 flush DNS 缓存。
#   · HOSTS_FILE 可覆盖（自测用，不碰系统文件）：
#       HOSTS_FILE=/tmp/h ./hosts-mnl.sh add
set -uo pipefail

IP_A=8.212.161.49            # ap-southeast-6a
IP_B=8.212.183.7             # ap-southeast-6b
DOM_A=ph-verify.internal.likha.hk
DOM_B=ph-verify-b.internal.likha.hk

BEGIN="# >>> mnl-verify (task19) >>>"
END="# <<< mnl-verify (task19) <<<"
HOSTS="${HOSTS_FILE:-/etc/hosts}"

ACTION="${1:-status}"
case "$ACTION" in add|del|status) ;; *) echo "usage: $0 add|del|status"; exit 2 ;; esac

# ---------- sudo 包装 ----------
if [ "$(id -u)" -eq 0 ] || [ "$HOSTS" != /etc/hosts ]; then SUDO=""
else
  command -v sudo >/dev/null 2>&1 || { echo "[!] 非 root 且无 sudo，无法改 $HOSTS"; exit 1; }
  SUDO="sudo"
fi

# ---------- 写 hosts（标记段整体重写，原子替换）----------
rewrite_hosts() {  # $1 = add | del
  $SUDO env ACT="$1" B="$BEGIN" E="$END" DA="$DOM_A" IA="$IP_A" DB="$DOM_B" IB="$IP_B" HP="$HOSTS" python3 - <<'PY'
import os
p = os.environ['HP']
act = os.environ['ACT']
B, E = os.environ['B'], os.environ['E']

lines = open(p, encoding='utf-8', errors='replace').read().splitlines()
out, skip = [], False
for l in lines:
    s = l.strip()
    if s == B: skip = True; continue
    if s == E: skip = False; continue
    if skip: continue
    out.append(l)
while out and not out[-1].strip():
    out.pop()

if act == 'add':
    out += ['', B,
            '%s\t%s' % (os.environ['IA'], os.environ['DA']),
            '%s\t%s' % (os.environ['IB'], os.environ['DB']),
            E]

new = '\n'.join(out) + '\n'
if new != open(p, encoding='utf-8', errors='replace').read():
    tmp = p + '.tmp-mnlverify'
    open(tmp, 'w', encoding='utf-8').write(new)
    os.chmod(tmp, 0o644)
    os.replace(tmp, p)
    print('  写入完成')
else:
    print('  内容无变化（幂等 no-op）')
PY
}

case "$ACTION" in
  add)
    echo "== 添加 =="
    rewrite_hosts add
    case "$(uname -s)" in Darwin) $SUDO dscacheutil -flushcache 2>/dev/null; $SUDO killall -HUP mDNSResponder 2>/dev/null; esac
    echo "  $IP_A  $DOM_A"
    echo "  $IP_B  $DOM_B"
    echo
    echo "浏览器打开： http://$DOM_A/"
    echo "            http://$DOM_B/"
    ;;
  del)
    echo "== 删除 =="
    rewrite_hosts del
    case "$(uname -s)" in Darwin) $SUDO dscacheutil -flushcache 2>/dev/null; $SUDO killall -HUP mDNSResponder 2>/dev/null; esac
    echo "  已移除 task19 标记段"
    ;;
  status)
    echo "== 当前 /etc/hosts 标记段 =="
    if grep -qF "$BEGIN" "$HOSTS" 2>/dev/null; then
      awk -v b="$BEGIN" -v e="$END" '$0==b{p=1} p{print} $0==e{p=0}' "$HOSTS"
    else
      echo "  (未配置)"
    fi
    ;;
esac

# ---------- 连通性直测 ----------
if [ "$ACTION" != "del" ]; then
  echo
  echo "== 直测（HTTP :80）=="
  for u in "http://$IP_A/api/status|IP-A 无Host" \
           "http://$IP_B/api/status|IP-B 无Host" \
           "http://$DOM_A/api/status|域名A" \
           "http://$DOM_B/api/status|域名B"; do
    url="${u%%|*}"; name="${u##*|}"
    printf '  %-14s %-16s -> ' "$name" "${url#http://}"
    curl --noproxy '*' -s -o /dev/null -w '%{http_code}\n' -m 8 "$url" 2>/dev/null || echo 'conn-fail'
  done
  echo "  (200=通 · 404=Prio3 catchall 生效 · 503=default 空占位组 · 000=DNS/网络不通)"
fi
