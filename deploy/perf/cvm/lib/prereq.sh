#!/usr/bin/env bash
# deploy/perf/cvm/lib/prereq.sh —— 压测前置依赖处理（source 使用）
#
#   source "$(dirname "$0")/lib/prereq.sh"
#   ensure_tool k6        # 有则跳过；没有则自动安装（默认重试 3 次）；全失败则给自助方案并退出
#   ensure_tool vegeta
#
# 设计约束：
#   · 不要求 root：优先装到 $PERF_BIN_DIR（默认 ~/.local/bin）并临时加 PATH；
#   · 不假设有 curl：curl / wget 二选一；
#   · 安装来源固定为 GitHub Releases 的官方 tar.gz，校验「能执行 + version 可跑」才算成功；
#   · 3 次失败后**不静默继续**：打印原因 + 三条自助路径（手动装 / docker / 代理），然后退出。
set -uo pipefail

PERF_BIN_DIR="${PERF_BIN_DIR:-$HOME/.local/bin}"
PERF_RETRIES="${PERF_RETRIES:-3}"
K6_VERSION="${K6_VERSION:-0.54.0}"
VEGETA_VERSION="${VEGETA_VERSION:-12.13.0}"

_perf_arch() {
  case "$(uname -m 2>/dev/null)" in
    x86_64|amd64)  echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *)             echo unsupported ;;
  esac
}

_perf_url() {
  local tool="$1" arch; arch="$(_perf_arch)"
  [ "$arch" = unsupported ] && return 1
  case "$tool" in
    k6)     echo "https://github.com/grafana/k6/releases/download/v${K6_VERSION}/k6-v${K6_VERSION}-linux-${arch}.tar.gz" ;;
    # 注意 vegeta 资产名是下划线：vegeta_12.13.0_linux_amd64.tar.gz（k6 才是连字符）
    vegeta) echo "https://github.com/tsenart/vegeta/releases/download/v${VEGETA_VERSION}/vegeta_${VEGETA_VERSION}_linux_${arch}.tar.gz" ;;
    *)      return 1 ;;
  esac
}

_perf_dl() { # url out
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --max-time 300 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --timeout=30 -O "$2" "$1"
  else
    return 127
  fi
}

_perf_verify() { # tool path —— 注意二者版本参数不同
  case "$1" in
    k6)     "$2" version    >/dev/null 2>&1 ;;   # k6 version
    vegeta) "$2" -version   >/dev/null 2>&1 ;;   # vegeta -version（没有 version 子命令）
    *)      "$2" --version  >/dev/null 2>&1 ;;
  esac
}

_perf_version_string() { # tool path -> 一行版本
  case "$1" in
    k6)     "$2" version  2>&1 | head -1 ;;
    vegeta) "$2" -version 2>&1 | head -1 ;;
    *)      "$2" --version 2>&1 | head -1 ;;
  esac
}

_perf_install_once() { # tool -> 0/1
  local tool="$1" url tmp bin
  url="$(_perf_url "$tool")" || return 1
  mkdir -p "$PERF_BIN_DIR" 2>/dev/null || return 1
  tmp="$(mktemp -d 2>/dev/null)" || return 1

  if ! _perf_dl "$url" "$tmp/pkg.tar.gz"; then rm -rf "$tmp"; return 1; fi
  if ! tar -xzf "$tmp/pkg.tar.gz" -C "$tmp" 2>/dev/null; then rm -rf "$tmp"; return 1; fi

  bin="$(find "$tmp" -maxdepth 3 -type f -name "$tool" 2>/dev/null | head -1)"
  [ -n "$bin" ] || { rm -rf "$tmp"; return 1; }

  if command -v install >/dev/null 2>&1; then
    install -m 0755 "$bin" "$PERF_BIN_DIR/$tool" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  else
    cp -f "$bin" "$PERF_BIN_DIR/$tool" 2>/dev/null || { rm -rf "$tmp"; return 1; }
    chmod 0755 "$PERF_BIN_DIR/$tool"
  fi
  rm -rf "$tmp"

  case ":${PATH}:" in *":$PERF_BIN_DIR:"*) : ;; *) export PATH="$PERF_BIN_DIR:$PATH" ;; esac
  _perf_verify "$tool" "$PERF_BIN_DIR/$tool"
}

perf_die_help() { # tool
  local tool="$1" url arch
  arch="$(_perf_arch)"; url="$(_perf_url "$tool" 2>/dev/null || true)"
  cat <<EOF

────────────────────────────────────────────────────────────
[XX] 自动安装 $tool 失败（已重试 ${PERF_RETRIES} 次），压测无法继续。

可能原因：
  1) 机器没有外网，或到 github.com / objects.githubusercontent.com 不通
  2) 既没有 curl 也没有 wget
  3) CPU 架构不在支持范围（当前 uname -m=$(uname -m 2>/dev/null || echo '?')，支持 x86_64 / aarch64）
  4) 目标目录不可写：${PERF_BIN_DIR}

自助解决（任选其一，完成后重跑本脚本即可）：

  A. 手动安装到用户目录（无需 root）
     mkdir -p ~/.local/bin
     curl -fsSL ${url:-<官方 tar.gz>} -o /tmp/${tool}.tar.gz
     tar -xzf /tmp/${tool}.tar.gz -C /tmp
     install -m 0755 \$(find /tmp -name ${tool} -type f | head -1) ~/.local/bin/${tool}
     ~/.local/bin/${tool} version

  B. 改用 docker（本仓 run.sh 会自动回退到 docker，只要机器上有 docker）
     docker --version

  C. 走代理后重试
     export https_proxy=http://<代理地址>:<端口>
     bash deploy/perf/cvm/run.sh ...

  D. 换内网/镜像源（把 tar.gz 放到内网可下载处，再按 A 的方式安装）

验证通过的标准：\`$([ "$tool" = vegeta ] && echo "vegeta -version" || echo "${tool} version")\` 有输出。
更多说明：deploy/perf/cvm/README.md 的「前置」一节。
────────────────────────────────────────────────────────────
EOF
}

# ensure_tool <k6|vegeta> [fallback:docker]
ensure_tool() {
  local tool="$1" allow_docker="${2:-}" i
  if command -v "$tool" >/dev/null 2>&1; then
    echo "[prereq] $tool 已就绪：$(command -v "$tool")"
    return 0
  fi

  echo "[prereq] 未检测到 $tool，开始自动安装（最多 ${PERF_RETRIES} 次，装到 ${PERF_BIN_DIR}）"
  for i in $(seq 1 "$PERF_RETRIES"); do
    echo "[prereq] 第 ${i}/${PERF_RETRIES} 次尝试…"
    if _perf_install_once "$tool"; then
      echo "[prereq] $tool 安装成功：$(command -v "$tool")（$(_perf_version_string "$tool" "$(command -v "$tool")")）"
      return 0
    fi
    sleep $((i * 2))
  done

  if [ "$allow_docker" = docker ] && command -v docker >/dev/null 2>&1; then
    echo "[prereq] $tool 装不上，但检测到 docker ⇒ 改用容器方式运行"
    return 10   # 调用方据此切 docker 分支
  fi
  perf_die_help "$tool"
  exit 3
}
