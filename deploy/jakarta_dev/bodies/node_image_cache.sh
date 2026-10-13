#!/bin/bash
# bodies/node_image_cache.sh —— 只读：节点上到底缓存了哪些 ACR 镜像（判断"冷拉"是否可能）
# 为什么看 crictl 而不是 kubectl：kubelet 走 CRI，镜像内容由 containerd 按 **digest** 存 content store。
# 只要 digest 相同，换 tag / 换命名空间都会命中缓存 ⇒ 不会真的走跨区下行，也就验不到"冷拉"。
echo "=== C1 节点上的 ACR 镜像（含 repoDigest，这是判定唯一依据）"
crictl images 2>&1 | grep -Ei 'aliyuncs|REPO' | sed 's/^/  /'
echo "=== C2 按 digest 归并：节点上有几个不同的 ACR digest"
crictl images -o json 2>/dev/null | grep -oE '"[a-z0-9.-]*cr\.aliyuncs\.com[^"]*"' | sort -u | sed 's/^/  ref: /'
# 修口径（2026-10-13）：原先 grep '"id":"sha256:<64>"' 恒为 0 ⇒ crictl 的 JSON 是带空格/缩进的，模式没命中。
# 默认表格输出的第 3 列就是 IMAGE ID，直接按列取，别猜 JSON 形状。
echo "  ACR 镜像的不同 ID 数：$(crictl images 2>/dev/null | awk '/aliyuncs/ {print $3}' | sort -u | wc -l)"
echo "=== C3 正在跑的 Pod 各自用的 digest（应与 C1 有交集 ⇒ 说明是缓存命中）"
kubectl -n newapi-dev get pod -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{range .status.containerStatuses[*]}{.imageID}{"\n"}{end}{end}' 2>&1 | sed 's/^/  /'
echo "=== C4 出口面（公网入口走的源地址；只看链路是否存在，不下载数据）"
ip -4 addr show 2>/dev/null | grep -E 'inet ' | grep -v '127.0.0.1' | sed 's/^/  /'
timeout 8 curl -sSI https://acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com/v2/ 2>&1 | head -6 | sed 's/^/  /'
echo "  （/v2/ 未授权会回 401 或 403 + WWW-Authenticate ⇒ 那正好证明 TCP+TLS 与应用层都通，且不需要任何凭据）"
echo "--- C1–C4 采集结束（只读：未删任何镜像、未拉任何载荷、未改任何对象）"
