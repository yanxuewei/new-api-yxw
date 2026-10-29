# OmniTradeERP 503 修复全流程记录

> 时间：2026-10-23  
> 环境：单节点服务器，3.5GB 内存，Docker Compose 部署，9 个 Java 微服务 + Nacos + MySQL  
> 目标：消除所有功能模块 `Request failed with status code 503`

---

## 一、问题现象

前端所有功能模块调用后端 API 均返回 503，服务器上多个 Java 容器持续 Restarting。

---

## 二、根因链路（按发现顺序）

| # | 根因 | 症状 |
|---|------|------|
| 1 | 内存不足（OOM） | MySQL 容器被反复 kill，exit(137) |
| 2 | `docker compose up` 触发 Maven 重新构建 | rc=17，依赖拉取失败 |
| 3 | compose.yml 引用了无镜像的 AI 类服务 | 启动阻断 |
| 4 | Nacos 连 MySQL 认证失败 | `Public Key Retrieval is not allowed` |
| 5 | Nacos volume 内缺 jdbc.properties | `No DataSource set`，容器 exit(1) |
| 6 | 各 Java 服务的 `NACOS_HOST` 变量名不匹配 | 实际连接阿里云 MSE 而非本地 Nacos |
| 7 | Nacos `erp-dev` namespace 不存在 | 服务注册失败 |
| 8 | datasource URL 硬编码 `localhost:3306` | 容器内 localhost=自身，连不到 MySQL |
| 9 | customer/supplier pom.xml 缺 mysql-connector-j | `Cannot load driver class` |

---

## 三、修复步骤详解

### 3.1 解决 OOM（fix_oom.py）

**问题**：主机仅 3.5GB 内存，9 个 Java 服务默认堆 350MB+ 加 Nacos 512MB，导致 MySQL 被 kill。

**修复**：

```bash
# 创建 2GB swapfile
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

所有 Java 服务在 compose.yml 中加入：
```yaml
environment:
  JAVA_OPTS: "-Xms64m -Xmx256m -XX:MaxMetaspaceSize=128m -XX:+UseSerialGC"
```

Nacos JVM 从 512m 降至 192m，MySQL 加参数：
```yaml
command: --innodb-buffer-pool-size=128M --performance-schema=OFF
```

---

### 3.2 修复 compose.yml 构建方式（rewrite_compose.py）

**问题**：原 compose.yml 用 `build:` 段，`docker compose up` 会触发 Maven 构建，依赖拉取失败。

**修复**：将所有服务的 `build:` 改为 `image:` 引用已构建镜像，删除无镜像的 AI 类服务（ai-assistant 等）。

最终有效服务列表：

| 服务 | 镜像 | 端口 |
|------|------|------|
| gateway | omnitrade/gateway:latest | 8080 |
| order | omnitrade/order:latest | 8081 |
| product | omnitrade/product:latest | 8083 |
| warehouse | omnitrade/warehouse:latest | 8085 |
| inventory | omnitrade/inventory:latest | 8086 |
| customer | omnitrade/customer:latest | 8087 |
| supplier | omnitrade/supplier:latest | 8088 |

启动命令：
```bash
docker compose up -d --no-build
```

> ⚠️ 必须加 `--no-build`，否则 compose 检测到 `build:` 段会尝试重新构建。

---

### 3.3 修复 Nacos MySQL 认证（fix_nacos.py）

**问题**：MySQL 8.0 默认 `caching_sha2_password`，Nacos JDBC 驱动不支持。

**修复**：
```sql
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'your_password';
FLUSH PRIVILEGES;
CREATE DATABASE IF NOT EXISTS nacos CHARACTER SET utf8mb4;
```

---

### 3.4 切换 Nacos 为 Derby 内置存储（fix_nacos2.py）

**问题**：Nacos volume 内缺 `jdbc.properties`，即使 MySQL 认证成功也报 `No DataSource set`。

**修复**：删除 compose.yml 中 Nacos 的所有 `SPRING_DATASOURCE_*` 环境变量，清除 nacos-data volume，使用 Nacos standalone 默认的内置 Derby 存储。

```yaml
# 删除以下环境变量（不再需要）
# SPRING_DATASOURCE_PLATFORM: mysql
# SPRING_DATASOURCE_URL: ...
# SPRING_DATASOURCE_USERNAME: ...
# SPRING_DATASOURCE_PASSWORD: ...
```

```bash
docker volume rm omnitrade_nacos-data
docker compose up -d nacos
```

Nacos 约 15 秒内健康启动。

---

### 3.5 修复 Nacos 变量名不匹配（fix_nacos_vars.py）

**问题**：各 Java 服务 `application.yml` 中用 `${NACOS_HOST}:${NACOS_PORT}`，但 compose.yml 里设的是 `NACOS_SERVER_ADDR`，变量名不对，服务连接阿里云 MSE 而非本地 Nacos。

**修复**：compose.yml 所有 Java 服务加：
```yaml
environment:
  NACOS_HOST: nacos
  NACOS_PORT: 8848
```

通过 Nacos API 创建 `erp-dev` namespace：
```bash
curl -X POST 'http://localhost:8848/nacos/v1/console/namespaces' \
  -d 'customNamespaceId=erp-dev&namespaceName=erp-dev&namespaceDesc=dev'
```

---

### 3.6 修复 datasource localhost 问题（fix_ds.py）

**问题**：所有服务 JDBC URL 硬编码 `localhost:3306`，容器内 localhost=容器自身，无法连接 MySQL 容器。

**修复**：compose.yml 所有 Java 服务注入：
```yaml
environment:
  SPRING_DATASOURCE_URL: "jdbc:mysql://mysql:3306/erp_xxx?useSSL=false&serverTimezone=UTC&allowPublicKeyRetrieval=true"
  SPRING_DATASOURCE_USERNAME: root
  SPRING_DATASOURCE_PASSWORD: your_password
```

同时创建缺失数据库：
```sql
CREATE DATABASE IF NOT EXISTS erp_customer CHARACTER SET utf8mb4;
CREATE DATABASE IF NOT EXISTS erp_supplier CHARACTER SET utf8mb4;
```

最终数据库清单（共 10 个）：
`erp_order` / `erp_product` / `erp_warehouse` / `erp_inventory` / `erp_customer` / `erp_supplier` / `erp_gateway` / `erp_user` / `erp_customer`（已合并）/ `erp_supplier`

---

## 四、当前状态（截至 2026-10-23）

| 服务 | 状态 | 说明 |
|------|------|------|
| nacos | ✅ healthy | Derby 模式，erp-dev namespace 已创建 |
| mysql | ✅ running | native password 已配置，10 个库均存在 |
| gateway | ⚠️ unhealthy | Nacos gRPC 连接偶发不稳定 |
| order | ⚠️ 503 | 需进一步排查 |
| product | ⚠️ /actuator/health 404 | actuator endpoint 未暴露 |
| warehouse | ⚠️ /actuator/health 404 | 同上 |
| inventory | ⚠️ /actuator/health 404 | 同上 |
| customer | ❌ Restarting | pom.xml 缺 mysql-connector-j 依赖，驱动加载失败 |
| supplier | ❌ Restarting | 同上 |

---

## 五、待处理问题

### 5.1 customer / supplier：缺 mysql-connector-j

**现象**：`Cannot load driver class: com.mysql.cj.jdbc.Driver`

**原因**：pom.xml 未声明 `mysql-connector-j` 依赖，fat jar 里没有 JDBC 驱动。

**修复方案**：

方案 A（推荐）——修改 pom.xml 重新构建：
```xml
<!-- pom.xml dependencies 中添加 -->
<dependency>
    <groupId>com.mysql</groupId>
    <artifactId>mysql-connector-j</artifactId>
    <version>8.0.33</version>
    <scope>runtime</scope>
</dependency>
```
然后在服务器上重新 `mvn package -DskipTests` 并重建镜像。

方案 B（临时）——将驱动 jar 挂载进容器：
```yaml
volumes:
  - /opt/mysql-connector-j-8.0.33.jar:/app/lib/mysql-connector-j.jar
environment:
  JAVA_OPTS: "-Xms64m -Xmx256m -loader.path=/app/lib"
```

---

### 5.2 product / warehouse / inventory：actuator health 返回 404

**原因**：`spring-boot-actuator` 未在 pom.xml 声明，或 `application.yml` 未暴露 health endpoint。

**检查**：
```bash
# 进容器确认配置
docker exec <container> cat /app/config/application.yml | grep management
```

**修复**：`application.yml` 中添加：
```yaml
management:
  endpoints:
    web:
      exposure:
        include: health,info
  endpoint:
    health:
      show-details: always
```

若 pom.xml 缺依赖，需补：
```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>
```

---

### 5.3 gateway：unhealthy

**现象**：Nacos gRPC（9848 端口）连接不稳定导致 gateway 标记 unhealthy。

**排查**：
```bash
docker logs omnitrade_gateway_1 --tail 50 | grep -i 'nacos\|grpc\|error'
```

---

## 六、关键运维命令

```bash
# 查看所有容器状态
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# 查看某服务日志
docker logs omnitrade_customer_1 --tail 100 -f

# 重启单个服务
docker compose restart customer

# 不重建直接启动
docker compose up -d --no-build

# 检查 Nacos namespace
curl -s http://localhost:8848/nacos/v1/console/namespaces | python3 -m json.tool

# 检查服务健康
for svc in gateway order product warehouse inventory customer supplier; do
  port=$(docker inspect omnitrade_${svc}_1 --format '{{range $p, $conf := .NetworkSettings.Ports}}{{$p}}->{{end}}' 2>/dev/null)
  echo "$svc: $port"
done
```

---

## 七、架构示意

```
前端 (React)
    ↓ HTTP
Gateway :8080
    ↓ 路由
┌───────────┬──────────┬───────────┬──────────┬──────────┬──────────┐
order:8081  product:8083  warehouse:8085  inventory:8086  customer:8087  supplier:8088
    ↓ 服务注册/发现
Nacos :8848 (standalone Derby)
    ↓ JDBC (mysql:3306)
MySQL :3306
    ↓ 缓存
Redis :6379
```

---

## 八、后续建议

1. **customer/supplier** 重新构建镜像（补 mysql-connector-j）是最终解法，临时挂载驱动只作应急。
2. **actuator 统一配置**：建议在公共配置模板里默认暴露 `health,info`，避免各服务遗漏。
3. **内存**：当前 swap 救场，生产应升级到 8GB+，或迁到 K8s 按服务设 resource limits。
4. **Nacos 持久化**：Derby 存储仅适合 dev，生产需切回 MySQL（解决 jdbc.properties 问题后）。
5. **健康检查**：compose healthcheck 统一改为探测实际业务端口，而非依赖 `/actuator/health`（部分服务不配置）。
