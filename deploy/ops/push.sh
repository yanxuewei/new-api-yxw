#!/usr/bin/env bash
# deploy/ops/push.sh —— service_ops 模块的镜像构建与推送（通用，支持后续多语言模块）
#
# 约定（模块侧）：service_ops/<module>/ 至少包含 Dockerfile；
#   - Go 模块：含 *.go 且无 build.sh 时，脚本自动 CGO_ENABLED=0 交叉编译出同名二进制；
#   - 其他语言/复杂构建：在模块里放可执行的 build.sh，脚本会先跑它（工作目录=模块根）；
#   - 已有镜像不重建：加 --no-build。
#
# usage:
#   bash deploy/ops/push.sh mock-upstream                # 构建 + 推送，tag=日期-gitsha
#   bash deploy/ops/push.sh mock-upstream 20261021-foo   # 指定 tag
#   bash deploy/ops/push.sh mock-upstream --no-build     # 只推已有二进制
#   bash deploy/ops/push.sh --list                       # 列出 service_ops 下的模块
#
# env:
#   SERVICE_OPS_DIR  默认 $REPO_ROOT/../service_ops
#   ACR_REGISTRY     默认 acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com
#   ACR_NAMESPACE    默认 newapi-dev
#   ACR_INSTANCE_ID  默认 cri-avfqy9xkqi5bj8ee
#   ACR_REGION       默认 ap-southeast-6
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SERVICE_OPS_DIR="${SERVICE_OPS_DIR:-$REPO_ROOT/../service_ops}"
ACR_REGISTRY="${ACR_REGISTRY:-acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com}"
ACR_NAMESPACE="${ACR_NAMESPACE:-newapi-dev}"
ACR_INSTANCE_ID="${ACR_INSTANCE_ID:-cri-avfqy9xkqi5bj8ee}"
ACR_REGION="${ACR_REGION:-ap-southeast-6}"

die() { echo "[XX] $*" >&2; exit 1; }
info() { echo "[..] $*"; }
ok() { echo "[ok] $*"; }

[ -d "$SERVICE_OPS_DIR" ] || die "service_ops 目录不存在：$SERVICE_OPS_DIR"

list_modules() {
  info "service_ops: $SERVICE_OPS_DIR"
  for d in "$SERVICE_OPS_DIR"/*/; do
    [ -d "$d" ] || continue
    m="$(basename "$d")"
    if [ -f "$d/Dockerfile" ]; then
      printf '  %-24s Dockerfile ✓%s\n' "$m" "$([ -f "$d/build.sh" ] && echo '  build.sh ✓')"
    else
      printf '  %-24s （无 Dockerfile，跳过）\n' "$m"
    fi
  done
}

[ "${1:-}" = "--list" ] && { list_modules; exit 0; }

MODULE="${1:?usage: push.sh <module> [tag] [--no-build]}"; shift || true
TAG=""; NO_BUILD=0
for a in "$@"; do
  case "$a" in
    --no-build) NO_BUILD=1 ;;
    *) TAG="$a" ;;
  esac
done

MOD_DIR="$SERVICE_OPS_DIR/$MODULE"
[ -d "$MOD_DIR" ] || die "模块不存在：$MOD_DIR"
[ -f "$MOD_DIR/Dockerfile" ] || die "模块缺 Dockerfile：$MOD_DIR/Dockerfile"

# tag 默认：日期 + 主仓 git 短 sha（service_ops 暂非 git 仓库），无 git 时用时分
if [ -z "$TAG" ]; then
  SHA=$(git -C "$REPO_ROOT" rev-parse --short=9 HEAD 2>/dev/null || date +%H%M)
  TAG="$(date +%Y%m%d)-$SHA"
fi
IMAGE="$ACR_REGISTRY/$ACR_NAMESPACE/$MODULE:$TAG"

# ---- 1) 构建二进制（模块自述优先）----
if [ "$NO_BUILD" = "0" ]; then
  if [ -x "$MOD_DIR/build.sh" ]; then
    info "执行模块构建脚本：$MOD_DIR/build.sh"
    ( cd "$MOD_DIR" && ./build.sh ) || die "build.sh 失败"
  elif ls "$MOD_DIR"/*.go >/dev/null 2>&1; then
    command -v go >/dev/null || die "模块含 Go 代码但本机没有 go"
    info "Go 交叉编译：$MODULE（linux/amd64，静态）"
    ( cd "$MOD_DIR" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
        go build -trimpath -ldflags="-s -w" -o "$MODULE" . ) || die "go build 失败"
  else
    info "非 Go 模块且无 build.sh，跳过二进制构建（由 Dockerfile 负责）"
  fi
fi

# ---- 2) 确保 ACR 仓库存在（幂等）----
if command -v aliyun >/dev/null; then
  EXIST=$(aliyun cr GetRepository --InstanceId "$ACR_INSTANCE_ID" --RegionId "$ACR_REGION" \
            --RepoNamespaceName "$ACR_NAMESPACE" --RepoName "$MODULE" 2>&1 | jq -r '.RepoName // empty' 2>/dev/null)
  if [ -z "$EXIST" ]; then
    info "ACR 仓库不存在，创建 $ACR_NAMESPACE/$MODULE"
    aliyun cr CreateRepository --InstanceId "$ACR_INSTANCE_ID" --RegionId "$ACR_REGION" \
      --RepoNamespaceName "$ACR_NAMESPACE" --RepoName "$MODULE" --RepoType PRIVATE \
      --Summary "ops tool: $MODULE" >/dev/null 2>&1 \
      && ok "仓库已创建" || info "创建返回非零（可能已存在），继续"
  else
    ok "ACR 仓库已存在：$ACR_NAMESPACE/$MODULE"
  fi

  # 临时口令登录（1 小时有效；不落盘持久凭据）
  TOK=$(aliyun cr GetAuthorizationToken --InstanceId "$ACR_INSTANCE_ID" --RegionId "$ACR_REGION" 2>/dev/null)
  TU=$(printf '%s' "$TOK" | jq -r '.TempUsername // empty')
  TP=$(printf '%s' "$TOK" | jq -r '.AuthorizationToken // empty')
  if [ -n "$TU" ] && [ -n "$TP" ]; then
    printf '%s' "$TP" | docker login --username "$TU" --password-stdin "$ACR_REGISTRY" >/dev/null 2>&1 \
      && ok "docker login 成功（临时口令）" || die "docker login 失败"
  else
    info "未取到 CR 临时口令，沿用本机已有 docker 凭据"
  fi
else
  info "本机无 aliyun CLI：跳过仓库创建/登录，直接 docker push"
fi

# ---- 3) 构建并推送镜像 ----
info "docker build -> $IMAGE"
docker build -q -t "$IMAGE" "$MOD_DIR" || die "docker build 失败"
info "docker push"
docker push "$IMAGE" || die "docker push 失败（检查 RAM 授权/仓库是否存在）"

DIGEST=$(docker inspect --format '{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null || true)
ok "已推送：$IMAGE"
[ -n "$DIGEST" ] && ok "digest：$DIGEST"
echo
echo "下一步（部署）：把 YAML 里的镜像 tag 替换为 $TAG 后 apply，例如："
echo "  sed 's/__IMAGE_TAG__/$TAG/' $MOD_DIR/*.yaml | kubectl apply -f -"
