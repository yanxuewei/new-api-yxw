# G8 探针 / 指标暴露面的集群侧清单（菲律宾 new-api）
#
# 配套：deploy/G8探针与指标_2026-09-28.patch（代码侧）、
#       deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md §3.9
#
# ⚠️ 未在任何集群上 apply 过。上线前必须逐项人工核对：
#   - containerPort / app 端口是否与现网 ConfigMap 的 PORT 一致（默认 3000）
#   - labels.selector 是否与现有 Deployment 的 selector 一致（此处不重复定义 selector，
#     只做增量 patch，避免和既有 spec 冲突）
#   - Prometheus 抓取来源是 ARMS 托管版还是自建 kube-prometheus-stack，
#     两者 ServiceMonitor 的 apiVersion 不同（monitoring.coreos.com/v1 vs alpha1）
#
# 渲染方式与目录内其它 .tpl 一致（替换占位后使用）。
#
# ⚠️ 三份资源用法不同，别一把 kubectl apply -f 整份：
#   - 第 1 段是 **strategic merge patch**，只能用 `kubectl patch`（见该段命令）。
#     直接 apply 会因缺少 selector/image 被 API Server 拒绝。
#   - 第 2、3 段是独立资源，可 apply。
#
# 先做这两项前置核对（错一项就可能把站点摘干净）：
#   kubectl -n new-api get deploy new-api \
#     -o jsonpath='{.spec.template.spec.containers[*].name}{"\n"}'   # 容器名必须与下面一致
#   kubectl -n new-api get deploy new-api \
#     -o jsonpath='{.spec.template.spec.containers[*].ports[*].containerPort}{"\n"}'
#   kubectl get networkpolicy -n new-api                             # 确认没有同 podSelector 的既有策略

# ---------------------------------------------------------------------------
# 1) Deployment 增量：探针 + 指标容器端口
#    用法（只改这一份，不覆盖 CI/CD 生成的 image/tag）：
#      sed -n '1,/^---$/p' g8-probe-manifests.yaml.tpl > /tmp/g8-probes.patch.yaml
#      kubectl -n new-api patch deployment new-api --type=strategic --patch-file /tmp/g8-probes.patch.yaml
#    ⚠️ containers[].name 必须与现网容器名完全一致；名字对不上时 strategic merge 会
#       追加第二个同名容器之外的空容器，pod 立刻 CrashLoop。改完先 rollout status 再看 ALB 后端。
# ---------------------------------------------------------------------------
apiVersion: apps/v1
kind: Deployment
metadata:
  name: new-api
  namespace: new-api
spec:
  template:
    spec:
      containers:
        - name: new-api
          ports:
            - name: http
              containerPort: 3000
            # 指标只在这里暴露；不加 ALB Ingress 后端、不加 Service 的公网路径
            - name: metrics
              containerPort: 9090
          env:
            - name: METRICS_ENABLED
              value: "true"
            - name: METRICS_PORT
              value: "9090"
            # 存活：绝不做依赖检查。依赖故障时重启只会把 pod 换成另一批起不来的 pod。
          livenessProbe:
            httpGet:
              path: /healthz
              port: 3000
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          # 就绪：主库硬失败→摘流量；Redis/日志库软失败→仍 200，只是响应体标 degraded。
          # periodSeconds 5 + failureThreshold 3 = 最快 15s 摘 pod，
          # 与 terminationGracePeriodSeconds、ALB 健康检查阈值要一起看，别只改这里。
          # timeoutSeconds 必须 > READY_PROBE_TIMEOUT_MILLIS(默认 1000ms)，
          # 否则探针自身先超时，等价于把"依赖慢"误判成"pod 死"。
          readinessProbe:
            httpGet:
              path: /readyz
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 3
          startupProbe:
            httpGet:
              path: /healthz
              port: 3000
            failureThreshold: 30
            periodSeconds: 2

---
# ---------------------------------------------------------------------------
# 2) 指标只允许集群内抓取（NetworkPolicy 是这里唯一的强制层，
#    不要指望 METRICS_BIND_ADDR 收敛——pod IP 网段本身也是内网可达的）
#    先确认现网是否有其它 NetworkPolicy 与本条同 podSelector 冲突：
#    kubectl get networkpolicy -n new-api
# ---------------------------------------------------------------------------
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: new-api-metrics-only-scrape
  namespace: new-api
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: new-api
  policyTypes:
    - Ingress
  ingress:
    # 业务端口：ALB Ingress 控制器 / WAF 回源所在命名空间放行
    - ports:
        - port: 3000
          protocol: TCP
    # 指标端口：只给监控命名空间
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: arms-prom
      ports:
        - port: 9090
          protocol: TCP

---
# ---------------------------------------------------------------------------
# 3) ServiceMonitor：ARMS 托管版可换成 Service 注解，不必建 CR
# ---------------------------------------------------------------------------
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: new-api-metrics
  namespace: new-api
  labels:
    release: arms-prometheus
spec:
  namespaceSelector:
    matchNames:
      - new-api
  selector:
    matchLabels:
      app.kubernetes.io/name: new-api
  endpoints:
    - port: metrics
      path: /metrics
      interval: 30s
      # 抓 3000 端口的 http endpoint 是另一条（业务指标不在这个 Service 上暴露）
      relabelings:
        - targetLabel: team
          replacement: newapi
          action: replace
