#!/bin/bash
# 创建（幂等）NodePort Service，供 ALB 服务器组以 Ecs 类型挂后端
say() { printf '\n===== %s =====\n' "$*"; }

say "ResourceQuota（nodeports 是否被限）"
kubectl -n new-api get resourcequota -o yaml 2>&1 | grep -E -A3 "nodeports|services" | head -20

say "apply NodePort svc / newapi-np（nodePort 固化 32656）"
# ★ nodePort 显式固化（2026-10-06）：ALB 服务器组 sgp-fm7kdwz99wtzbffkfx 里写死了
#   「节点 IP:32656」，若让 k8s 从 30000-32767 随机分配，重建后端口一变后端全失效。
#   权威副本：deploy/manifests/newapi-np.yaml
cat > /tmp/newapi-np.yaml <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: newapi-np
  namespace: new-api
  labels:
    purpose: pre-cert-direct-access
    managed-by: manual-task19
spec:
  type: NodePort
  externalTrafficPolicy: Cluster
  selector:
    app: new-api
    track: stable
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: 3000
      nodePort: 32656
YAML
kubectl apply -f /tmp/newapi-np.yaml 2>&1

say "回读 + 断言 nodePort=32656"
kubectl -n new-api get svc newapi-np -o wide 2>&1
NP=$(kubectl -n new-api get svc newapi-np -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
echo "NODE_PORT=$NP"
if [ "$NP" = "32656" ]; then echo "OK nodePort pinned = 32656"; else echo "FAIL nodePort=$NP (期望 32656) —— ALB 服务器组后端会失效，须排查端口占用"; fi
kubectl -n new-api get endpoints newapi-np -o wide 2>&1

say "节点本地自测 nodeIP:$NP/api/status"
MYIP=$(ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
[ -z "$MYIP" ] && MYIP=$(hostname -I | awk '{print $1}')
echo "self=$MYIP"
for i in 1 2 3; do
  curl --noproxy '*' -s -o /dev/null -w "  try$i http://$MYIP:$NP/api/status -> %{http_code}\n" -m 5 "http://$MYIP:$NP/api/status"
done

say "打印 nodePort 供云侧挂载（唯一输出行）"
echo "RESULT node_port=$NP"
echo; echo "done"
