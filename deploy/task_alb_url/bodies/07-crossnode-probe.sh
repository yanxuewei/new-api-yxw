#!/bin/bash
say() { printf '\n===== %s =====\n' "$*"; }
say "本节点"
hostname; ip -4 -o addr show eth0 | awk '{print $4}'

say "各节点 NodePort 32656 直连"
for ip in 10.0.22.194 10.0.22.195 10.0.43.200 10.0.43.201; do
  for t in 1 2; do
    c=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -m 5 "http://$ip:32656/api/status")
    printf '  %-14s try%s -> %s\n' "$ip" "$t" "$c"
  done
done

say "各 Pod IP:3000 直连"
for ip in 10.0.22.218 10.0.22.219 10.0.43.215 10.0.43.218; do
  c=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -m 5 "http://$ip:3000/api/status")
  printf '  %-14s -> %s\n' "$ip" "$c"
done

say "ClusterIP"
c=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -m 5 "http://172.21.15.220:80/api/status"); echo "  stable:80 -> $c"

say "kube-proxy 模式与规则"
kubectl -n kube-system get cm kube-proxy-config -o jsonpath='{.data.config}' 2>/dev/null | head -c 300; echo
ss -lntp 2>/dev/null | grep -E ':32656' | head -5

say "ALB 到节点的实际源地址观测（本节点抓 32656 连接）"
timeout 20 tcpdump -nni any "tcp port 32656" -c 8 2>&1 | tail -12 || echo "(tcpdump 不可用/无包)"

say "conntrack 里 32656 的转发目标"
conntrack -L 2>/dev/null | grep -E "32656" | head -8 || echo "(no conntrack / empty)"
echo; echo "done"
