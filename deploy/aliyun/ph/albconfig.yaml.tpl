# G6 配置模板 · 马尼拉 ALB AlbConfig（对应指南 §3.8 / §6.3 任务 19）
# 渲染方式：envsubst 或 Kustomize helmChartPostRenderer 替换 ${...} 后 kubectl apply。
# 管理红线（§6.3 坑 4）：ALB 只能经 AlbConfig/Ingress 声明式管理，禁止控制台手工改 listener/转发规则。
#   ★ 技术强制（2026-10-12 实测）：ACK 托管的 ALB 是 **ServiceManagedResource**，直接调 alb OpenAPI
#     会被服务端拒绝 `OperationDenied.ServiceManagedResource` ⇒ 控制台/OpenAPI 想改也改不了。
#   ★ 现网基线（2026-10-12，443 已上线）：`deploy/aliyun/ph/albconfig.rendered.yaml`（本模板的渲染件，
#     已按实况回填真实 ID 与 CertIdentifier `606823-ap-southeast-1`）；改证书/监听器请以该件为 SSOT。
#
# 占位符清单（D1–D3 产出后回填 Git，不在本文件硬编码）：
#   ${VSW_MNL_PUB_A}  马尼拉公网 vSwitch 6a（§4.1 产出）
#   ${VSW_MNL_PUB_B}  马尼拉公网 vSwitch 6b（§4.1 产出）
#   ${CERT_ID_ALB}    CAS 证书 ID（D6 任务 40 回填，见 cert-deployment-task.md）
#
# 关键参数依据（P0-5，勿改回方案 v2.1 原值）：
#   requestTimeout 上限就是 600s（方案写 180 是保守值；>600s 的单请求 ALB 无法承载）
#   idleTimeout 60s 是"两包之间静默间隔"，SSE 保活靠网关 15s ping（留 4 倍余量）
apiVersion: alibabacloud.com/v1
kind: AlbConfig
metadata:
  name: mnl-alb
  # ⚠ AlbConfig 是 **Cluster-scoped**（实测 spec.scope=Cluster）⇒ **不写 namespace**（旧模板误带，2026-10-12 订正）
spec:
  config:
    name: alb-newapi-mnl
    addressType: Internet
    zoneMappings:
      - vSwitchId: ${VSW_MNL_PUB_A}   # ALB 强制 >=2 AZ；马尼拉只有 6a/6b（P1-8）
      - vSwitchId: ${VSW_MNL_PUB_B}
    accessLogConfig:
      logProject: sls-newapi-mnl      # ⚠ 必须先建 SLS Project/Logstore（§9.2）再配，否则日志静默丢失（坑 5）
      logStore: alb_access
    tags:
      - { key: project, value: new-api }
      - { key: site, value: ph-mnl }
      - { key: env, value: prod }
  listeners:
    - port: 80
      protocol: HTTP
      idleTimeout: 60
      requestTimeout: 600
      # ⚠ 不要写 `httpDefaultActions`/`defaultActions`：实测被 Controller 的 ForwardGroup 覆盖（2026-10-06 定论），
      #   旧写法还带已废弃域名 `api.likha.com`。HTTP→HTTPS 301 走 Ingress：
      #   deploy/manifests/ingress-mnl-http-redirect.yaml（order=1，对 www.likha.hk / likha.hk）
    - port: 443
      protocol: HTTPS
      securityPolicyId: tls_cipher_policy_1_2_strict_with_1_3   # 显式指定，否则可协商 TLS1.0 被安全核查判不合格（坑 3）
      caEnabled: false
      requestTimeout: 600             # 硬上限，见文件头注释
      idleTimeout: 60
      certificates:
        # ⚠⚠ 字段名**必须是 `CertificateId`**（值才是 CertIdentifier，如 `606823-ap-southeast-1`）。
        #   写成 `CertIdentifier:` 会被 CRD `x-kubernetes-preserve-unknown-fields` **静默忽略**
        #   ⇒ 证书不绑定、443 形同虚设，且不报任何错（2026-10-12 实测订正，本模板旧写法即此坑）。
        - CertificateId: ${CERT_ID_ALB}
          IsDefault: true
---
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: alb
  # ⚠ IngressClass 亦为集群级资源 ⇒ 不写 namespace（旧模板误带，2026-10-12 订正）
spec:
  controller: ingress.k8s.alibabacloud/alb
  parameters:
    apiGroup: alibabacloud.com
    kind: AlbConfig
    name: mnl-alb
---
# 健康检查注解挂在业务 Ingress 上（stable/canary 各一条，§8.4 部署）：
# G8 未完成前只能用 /api/status；/readyz 合并后必须切换，因为 /api/status 不反映 DB，
# 会把"进程活着但连不上库"的 Pod 判成健康（§6.3 注）。
#
#   alb.ingress.kubernetes.io/healthcheck-enabled: "true"
#   alb.ingress.kubernetes.io/healthcheck-path: "/api/status"        # -> G8 后改 /readyz
#   alb.ingress.kubernetes.io/healthcheck-interval-seconds: "6"
#   alb.ingress.kubernetes.io/healthcheck-timeout-seconds: "3"
#   alb.ingress.kubernetes.io/healthy-threshold-count: "2"
#   alb.ingress.kubernetes.io/unhealthy-threshold-count: "3"
#   alb.ingress.kubernetes.io/healthcheck-method: "GET"
#   alb.ingress.kubernetes.io/healthcheck-httpcode: "http_2xx"
#   alb.ingress.kubernetes.io/connection-drain-enabled: "true"
#   alb.ingress.kubernetes.io/connection-drain-timeout: "120"        # 对齐 SHUTDOWN_TIMEOUT_SECONDS=150 的排空窗口
