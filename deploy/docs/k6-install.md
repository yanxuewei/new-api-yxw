# k6 安装指南

## 环境

Linux/Ubuntu（amd64）

## 方式一：apt 官方源（推荐）

```bash
# 添加 GPG key
curl -fsSL https://dl.k6.io/key.gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/k6-archive-keyring.gpg

# 添加 apt 源
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/k6.list

# 安装
sudo apt update && sudo apt install -y k6
```

验证：

```bash
k6 version
# k6 v2.3.0 (commit/e088784614, go1.26.8, linux/amd64)
```

## 方式二：直接下载二进制（keyserver 不可达时使用）

```bash
K6_VER=v0.54.0
curl -fsSL "https://github.com/grafana/k6/releases/download/${K6_VER}/k6-${K6_VER}-linux-amd64.tar.gz" \
  | tar -xz --strip-components=1 -C /usr/local/bin k6-${K6_VER}-linux-amd64/k6
k6 version
```

## 常见问题

**`E: Unable to locate package k6`** — k6 不在默认 Ubuntu apt 源中，需先按方式一添加官方源。

**keyserver 连接超时** — 国内网络访问 `hkp://keyserver.ubuntu.com:80` 不稳定，改用方式一中的 `curl -fsSL https://dl.k6.io/key.gpg` 直接拉取 GPG key。
