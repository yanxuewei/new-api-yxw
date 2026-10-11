#!/bin/bash
# 只读：排除代理干扰后复测 pod 可达性 + TCP 层 + NodePort 环境
say() { printf '\n===== %s =====\n' "$*"; }

say "代理环境变量（干扰源排查）"
env | grep -i -E "^[a-z_]*proxy=" || echo "  (无 proxy 变量)"

say "TCP 层直连（/dev/tcp，N=3）"
for ip in 10.0.22.218 10.0.22.219 10.0.43.215 10.0.43.218; do
  ok=0
  for i in 1 2 3; do
    if timeout 3 bash -c "exec 3<>/dev/tcp/$ip/3000" 2>/dev/null; then ok=$((ok+1)); fi
  done
  printf '  %-16s :3000  tcp_ok=%d/3\n' "$ip" "$ok"
done

say "HTTP 复测（curl --noproxy + env 清空）"
for ip in 10.0.22.218 10.0.43.215; do
  for p in /api/status /; do
    c1=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -m 4 "http://$ip:3000$p" 2>/dev/null)
    c2=$(env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY curl -s -o /dev/null -w '%{http_code}' -m 4 "http://$ip:3000$p" 2>/dev/null)
    printf '  %-14s %-12s noproxy=%s env-unset=%s\n' "$ip" "$p" "$c1" "$c2"
  done
done

say "带 Host 与不带 Host 的差异（vhost 检查）"
curl --noproxy '*' -s -D- -o /dev/null -m 5 -H 'Host: ph-verify.internal.likha.hk' http://10.0.43.215:3000/api/status 2>&1 | head -8
echo "---"
curl --noproxy '*' -s -o /dev/null -w 'no-host /api/status -> %{http_code}\n' -m 5 http://10.0.43.215:3000/api/status 2>&1

say "stable ClusterIP:80"
curl --noproxy '*' -s -o /dev/null -w '  172.21.15.220:80 -> %{http_code}\n' -m 5 "http://172.21.15.220:80/api/status" 2>&1

say "kube-system 里的 fake-svc / 占位服务"
kubectl -n kube-system get svc 2>&1 | head -12

say "NodePort 已占用"
kubectl get svc -A -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
n=0
for s in d.get('items',[]):
    if s['spec'].get('type')=='NodePort':
        print(' ',s['metadata']['namespace']+'/'+s['metadata']['name'],[ (p.get('port'),p.get('nodePort')) for p in s['spec']['ports']]); n+=1
print('  total NodePort svc =',n)
"

say "节点网段与 pod 网段（terway 配置）"
ip -4 -o addr show 2>/dev/null | awk '{print "  "$2, $4}' | head -10
echo "--- 到 pod IP 的路由 ---"
ip route get 10.0.22.218 2>&1 | head -3
ip route get 10.0.43.215 2>&1 | head -3
echo; echo "done"
