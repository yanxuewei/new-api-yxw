# 集群内 Service 地址是怎么来的（以 mock 上游为例）

> 问题：`http://mock-upstream.new-api-perf.svc.cluster.local` 这个地址是怎么来的？如何获取？
> 结论：**不是手填的，也不是"查询"出来的**，而是按 Kubernetes 规则由「Service 名 + 命名空间 + 集群域名」拼出来的 Service DNS 名。
> 记录日期 2026-10-20；实测环境：雅加达 dev 集群 `cb0abf5bc06034f7bbdb991752f6f3e62`、命名空间 `new-api-perf`。

## 1. 来源：我们自己部署的 Service 清单

`deploy/perf/mock-upstream/mock-upstream.yaml`：

```yaml
kind: Service
metadata:
  name: mock-upstream
  namespace: new-api-perf
spec:
  ports: [{name: http, port: 80, targetPort: http}]   # 80 → 容器 8080
  selector: {app: mock-upstream}
```

K8s 为它自动分配 ClusterIP，并由 CoreDNS 生成一条 DNS 记录，格式固定为：

```
<Service名>.<命名空间>.svc.<集群域名>
   mock-upstream  .  new-api-perf  . svc .  cluster.local
```

- `cluster.local` 是集群域名（CoreDNS 的 `kubernetes` 域默认值）；
- 端口取 Service 的 `spec.ports[].port`（这里是 80），不是容器的 8080；
- 协议按实际入口写（集群内是 `http://`）。

## 2. 实测佐证（2026-10-20 回读）

| 项 | 实测值 |
|---|---|
| Service | `mock-upstream`，ClusterIP **172.23.2.0**，`80 → targetPort http(8080)`，selector `app=mock-upstream` |
| 后端 Endpoints | 6 个：`10.2.25.198:8080`、`10.2.25.202:8080`、`10.2.25.206:8080` + 3 个 |
| Pod 内解析 FQDN | `172.23.2.0  mock-upstream.new-api-perf.svc.cluster.local` |
| 同 ns 短名 `mock-upstream` | 同样解析到 172.23.2.0 |
| 跨 ns 短名 `mock-upstream.new-api-perf` | 同样解析到 172.23.2.0 |
| HTTP 探测 `/v1/models` | 返回 `mock-gpt` ⇒ 链路通 |

## 3. 怎么自己查

```bash
# 1) 看 Service 与 ClusterIP、端口映射
kubectl -n new-api-perf get svc mock-upstream -o wide
kubectl -n new-api-perf get svc mock-upstream -o jsonpath='{.spec.clusterIP}'

# 2) 看后端是谁（EndpointSlice 是新 API，Endpoints 仍可读）
kubectl -n new-api-perf get endpoints mock-upstream

# 3) 在集群内某个 Pod 里验证解析（**只有 Pod 内能解析**）
getent hosts mock-upstream.new-api-perf.svc.cluster.local

# 4) 直接验证服务（Pod 内）
wget -qO- http://mock-upstream.new-api-perf.svc.cluster.local/v1/models
```

## 4. 三种等价写法（都只在集群内有效）

| 写法 | 适用位置 |
|---|---|
| `mock-upstream` | 同命名空间（`new-api-perf`）内 |
| `mock-upstream.new-api-perf` | 集群内任意命名空间 |
| `mock-upstream.new-api-perf.svc.cluster.local` | 全限定名，最稳，推荐写进配置 |

## 5. 三个使用要点

1. **只有 Pod 能解析**：节点（`kubectl` 所在的 ECS）与本地 WSL 都不在集群 DNS 域内。节点侧脚本要访问时只能用 ClusterIP（`172.23.2.0`）或 Pod IP——这也是 `deploy/perf/k6/bodies/*.sh` 里用 `kubectl get svc -o jsonpath='{.spec.clusterIP}'` 取地址、而不用域名做 HTTP 探测的原因。
2. **换部署位置就要换地址**：Service 名或命名空间一变，DNS 名随之改变；mock 若挪到别的 ns，`new-api` channel 的 API 地址要同步改。
3. **不要填网关自己的域名**：channel 的「API 地址」是**上游地址**。填 `https://perf.likha.hk` 会让请求回到网关自身 ⇒ 自环，表现为 `401 Invalid token`（channel 的 key 被当成客户 token），key 恰好有效时退化为无限递归。事故记录见 `deploy/jakarta_dev_ledger.md` §23.1。

## 6. 相关文件

| 路径 | 说明 |
|---|---|
| `deploy/perf/mock-upstream/mock-upstream.yaml` | Service/Deployment 定义（地址的来源） |
| `deploy/perf/mock-upstream/README.md` | mock 参数矩阵与验证记录 |
| `deploy/perf/k6/` | 压测脚本（`stage`/`dual1500`/`summary`/`readback`） |
| `deploy/jakarta_dev_ledger.md` §23 | 任务 33 压测结果与本地址相关的自环事故 |
