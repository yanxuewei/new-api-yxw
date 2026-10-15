#!/usr/bin/env bash
# =============================================================================
# deploy/jakarta_pre/pre_deploy.sh —— 雅加达 pre / perf 底座执行器（任务 45 改写版）
#
# 通道：deploy/lib/ack_remote_jkt_dev.sh（ECS 云助手 → 节点内 kubectl，15 分钟临时私网 kubeconfig）
#   该通道只服务雅加达集群 cb0abf5bc06034f7bbdb991752f6f3e62（ap-southeast-5）⇒ 结构上打不到马尼拉。
#
# 结构：远端脚本 = 静态 body（deploy/jakarta_pre/bodies/*.sh）+ 本地拼的 header（临时目录 + 载荷）。
#
# 子命令：
#   --ns-base               建 new-api-pre / new-api-perf 的 Namespace/Quota/SA（幂等，只写这两 ns）
#   --addon-verify          只读：免密组件作用域双路取证（CS API + 集群内 SA/Secret）
#   --pull-check <ns>       只读：指定 ns 里探针 Pod 能否拉到镜像（不落业务负载）
#
# 凭据纪律：本执行器当前步骤**不投递任何凭据**；Secret 面走后续 --apply-pre（沿用 dev 的保管目录口径）。
# =============================================================================
set -uo pipefail

REGION=ap-southeast-5
CID=cb0abf5bc06034f7bbdb991752f6f3e62
ADDON=managed-aliyun-acr-credential-helper
DEV_NS=newapi-dev
APP_SA=new-api-app
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BODIES="$HERE/bodies"
REMOTE="$ROOT/deploy/lib/ack_remote_jkt_dev.sh"
WORK=$(mktemp -d); chmod 700 "$WORK"; trap 'rm -rf "$WORK"' EXIT

notice() { echo "[pre-deploy] $*"; }
die() { echo "[pre-deploy][!] $*" >&2; exit 1; }

header() {
  cat <<HDR
#!/bin/bash
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/local/bin:\$PATH
HDR
  local pair
  for pair in "$@"; do printf 'export %s=%s\n' "${pair%%=*}" "'${pair#*=}'"; done
}

run_body() {
  local bname="$1" tag="$2"; shift 2
  [ -s "$BODIES/$bname" ] || die "缺 body：$BODIES/$bname"
  local full="$WORK/full_${tag}.sh"
  { header "$@"; cat "$BODIES/$bname"; } > "$full"
  chmod 700 "$full"
  notice "→ 云助手调用（$tag，body=$bname，载荷 $(( $# )) 项，命令体 $(wc -c <"$full") 字节）"
  bash "$REMOTE" "$full" || die "远端调用失败（$tag）"
}

ns_base() {
  if [ -n "${ONLY:-}" ]; then
    case "$ONLY" in new-api-pre|new-api-perf) : ;; *) die "--ns-base 的 ONLY 只能是 new-api-pre / new-api-perf（当前='$ONLY'）" ;; esac
    notice "只建一个 ns：$ONLY"
    run_body create_ns.sh creans "ONLY=$ONLY"
  else
    run_body create_ns.sh creans
  fi
}
addon_verify() { run_body verify_addon_scope.sh addverify; }
pull_check() {
  [ -n "${TGT:-}" ] || die "--pull-check 必须给第二参命名空间（new-api-pre / new-api-perf）"
  case "$TGT" in new-api-pre|new-api-perf) : ;; *) die "--pull-check 只允许 new-api-pre / new-api-perf（当前='$TGT'）" ;; esac
  run_body pull_probe.sh pullprobe "NS=$TGT"
}

A="${1:---help}"
TGT="${2:-}"
case "$A" in
  --ns-base)     ns_base ;;
  --addon-verify) addon_verify ;;
  --pull-check)  pull_check ;;
  *) die "未知子命令：$A（--ns-base / --addon-verify / --pull-check <ns>；ONLY=new-api-pre 可只建一个）" ;;
esac
