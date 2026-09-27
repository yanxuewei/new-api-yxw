#!/usr/bin/env bash
# push.sh — new-api 镜像「本地登录 → build → 打标 → 推送 ACR」一键脚本
#
# 目标仓库：马尼拉 ACR 企业版实例 acr-newapi-mnl（Regional 域名，见控制台「镜像指南」）
#   registry : acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com
#   login 用户名 : yanxuewei@5108890064395960   （阿里云账号全名，密码 = 开通服务时设置的访问凭证密码）
#   镜像地址 : <registry>/<命名空间>/<仓库名>:<tag>
#
# 四个命名空间（-n 支持简写）：
#   prod → newapi-prod      pre  → newapi-pre
#   test → newapi-test      dev  → newapi-dev
#
# 用法示例
#   bash push.sh -n prod -t v1.2.0                 # 构建并推送生产
#   bash push.sh -n test -t 20260927 --extra-tags latest
#   bash push.sh -n dev --no-build                 # 只推送本地已有镜像
#   bash push.sh -n pre --build-only               # 只构建不推送
#   bash push.sh -n prod -t v1.2.0 --dry-run        # 只打印命令不执行
#
# 密码来源优先级：--password > 环境变量 ACR_PASSWORD > 交互式隐藏输入
#
# 依赖：docker（buildx 可选，有则用 --load 构建）、git（可选，用于默认 tag）、
#       aliyun CLI（可选，用于命名空间/仓库/tag 预检；无则跳过并提示）
set -uo pipefail

# ============================ 默认值 ============================
REGISTRY="${ACR_REGISTRY:-acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com}"
ACR_USER="${ACR_USER:-yanxuewei@5108890064395960}"
ACR_PASSWORD="${ACR_PASSWORD:-}"
NS_INPUT=""
TAG=""
REPO_NAME="${ACR_REPO_NAME:-newapi-master}"
LOCAL_IMAGE="${ACR_LOCAL_IMAGE:-new-api:local}"
DOCKERFILE="Dockerfile"
CONTEXT="."
PLATFORM="linux/amd64"
EXTRA_TAGS=""
BUILD_ARGS=""
DO_BUILD=1
DO_PUSH=1
DO_LOGIN=1
DO_LOGOUT=0
NO_CACHE=""
PULL_BASE=""
PRE_CHECK=1
CREATE_REPO=0
OPEN_ENDPOINT=0
ALLOW_IPS=""
PRUNE_CACHE=0
DISK_CHECK=1
MIN_FREE_GIB=4
# npm 源：本地默认走国内镜像（官方源在国内拉大包易超时/integrity 失败）；
# --npm-registry official 可切回 registry.npmjs.org，或直接给具体 URL
NPM_REGISTRY_SEL="${ACR_NPM_REGISTRY:-cn}"
NPM_REGISTRY_SKIPPED=0
# 构建期代理：auto = 本机 Clash。注入 Docker 预定义 ARG，因此**无需改 Dockerfile**
BUILD_PROXY="${ACR_BUILD_PROXY:-}"
NO_PROXY_LIST="${ACR_NO_PROXY:-localhost,127.0.0.1,.aliyuncs.com}"
DRY_RUN=0
PLAIN=0
VERBOSE=0
REGION="${ACR_REGION:-ap-southeast-6}"
INSTANCE_ID="${ACR_INSTANCE_ID:-cri-avfqy9xkqi5bj8ee}"

# 脚本位于仓库根目录；REPO_ROOT = 脚本所在目录（即仓库根）
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 日志集中放 deploy/logs（.gitignore 的 `logs` 规则已覆盖）；兼容旧的 .deploy/logs
if [[ -d "${REPO_ROOT}/deploy" ]]; then
  LOG_DIR="${REPO_ROOT}/deploy/logs"
else
  LOG_DIR="${REPO_ROOT}/.deploy/logs"
fi
ALIYUN="${HOME}/.workbuddy/binaries/aliyun-cli/aliyun"
PY="${HOME}/.workbuddy/binaries/python/versions/3.13.12/bin/python3"
[[ -x "$PY" ]] || PY="$(command -v python3 2>/dev/null)"
[[ -n "$PY" ]] || PY="$(command -v python 2>/dev/null)"

# ============================ 颜色 / 日志 ============================
if [[ -t 2 && "$PLAIN" == "0" ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_CYN=$'\033[36m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_DIM=""; C_OFF=""
fi

LOG=""
_ts() { date '+%Y-%m-%d %H:%M:%S'; }

# 说明：本机 `tee` 单次开销约 0.6s（已实测），因此**逐行日志不用 tee**，
#       只对 docker build / push 这类需要实时透传的大段输出用 tee（`run()`）。
# 控制台走 stderr（带色），日志文件走 append（纯文本、无色码）。
_say() {  # $1=颜色 $2=标签(可空) $3=正文
  local c="$1" tag="$2" msg="$3" t
  t="$(_ts)"
  if [[ -n "$tag" ]]; then
    printf '%s[%s] %s %s%s\n' "$c" "$t" "$tag" "$msg" "$C_OFF" >&2
    printf '[%s] %s %s\n' "$t" "$tag" "$msg" >>"${LOG:-/dev/null}"
  else
    printf '%s[%s] %s%s\n' "$c" "$t" "$msg" "$C_OFF" >&2
    printf '[%s] %s\n' "$t" "$msg" >>"${LOG:-/dev/null}"
  fi
}
# 一行进两处：$1=控制台版(可带色) $2=日志版(纯文本)
_out2() { printf '%s\n' "$1" >&2; printf '%s\n' "$2" >>"${LOG:-/dev/null}"; }
_out()  { _out2 "$1" "$1"; }

log()  { _say "$C_DIM" "" "$*"; }
ok()   { _say "$C_GRN" "✔" "$*"; }
warn() { _say "$C_YEL" "▲" "$*"; }
err()  { _say "$C_RED" "✖" "$*"; }
die()  { err "$*"; finish_stage "FAIL"; print_summary; exit 1; }

now_ms() {
  if [[ -n "$PY" ]]; then "$PY" -c 'import time;print(int(time.time()*1000))';
  else printf '%s000' "$(date +%s)"; fi
}
fmt_ms() {
  local ms="${1:-0}"
  [[ "$ms" -lt 0 ]] && ms=0
  if [[ "$ms" -lt 60000 ]]; then
    printf '%d.%03ds' "$((ms / 1000))" "$((ms % 1000))"
  else
    printf '%dm%02d.%03ds' "$((ms / 60000))" "$(((ms % 60000) / 1000))" "$((ms % 1000))"
  fi
}
human_size() {  # bytes -> MB
  local b="${1:-0}"
  printf '%d MB' "$((b / 1024 / 1024))"
}

# 执行并记录（stdout+stderr 同时进控制台与日志文件）
run() {
  log "  ${C_CYN}\$ $*${C_OFF}"
  if [[ "$DRY_RUN" == "1" ]]; then warn "  dry-run：跳过执行"; return 0; fi
  "$@" 2>&1 | tee -a "$LOG"
  return ${PIPESTATUS[0]}
}

# ============================ 阶段计时 ============================
STAGE=""
STAGE_START=0
STAGE_ROWS=""   # 每行: name|status|elapsed_ms|note
TOTAL_START=0

begin_stage() {
  STAGE="$1"; STAGE_START="$(now_ms)"
  log "──────── ${C_CYN}[${STAGE}]${C_OFF} 开始 ────────"
}
finish_stage() {  # $1=OK/FAIL/SKIP, $2=note(optional)
  local st="${1:-OK}" note="${2:-}" el
  [[ -n "$STAGE" ]] || return 0
  el=$(( $(now_ms) - STAGE_START ))
  STAGE_ROWS="${STAGE_ROWS}${STAGE}|${st}|${el}|${note}
"
  case "$st" in
    OK)   ok  "[${STAGE}] 完成 用时 $(fmt_ms "$el") ${note:+· $note}" ;;
    SKIP) warn "[${STAGE}] 跳过 用时 $(fmt_ms "$el") ${note:+· $note}" ;;
    *)    err  "[${STAGE}] 失败 用时 $(fmt_ms "$el") ${note:+· $note}" ;;
  esac
  STAGE=""
  return 0
}

print_summary() {
  local total_ms=$(( $(now_ms) - TOTAL_START ))
  _out ""
  _out2 "${C_CYN}================ 执行汇总 ================${C_OFF}" "================ 执行汇总 ================"
  _out2 "$(printf '%-12s %-6s %12s  %s' '阶段' '状态' '耗时' '备注')" "$(printf '%-12s %-6s %12s  %s' '阶段' '状态' '耗时' '备注')"
  _out "------------------------------------------------------------"
  while IFS='|' read -r n st el note; do
    [[ -n "$n" ]] || continue
    case "$st" in
      OK)   sc="$C_GRN" ;;
      SKIP) sc="$C_YEL" ;;
      *)    sc="$C_RED" ;;
    esac
    _out2 "$(printf '%-12s %s%-6s%s %12s  %s' "$n" "$sc" "$st" "$C_OFF" "$(fmt_ms "$el")" "$note")" \
          "$(printf '%-12s %-6s %12s  %s' "$n" "$st" "$(fmt_ms "$el")" "$note")"
  done <<< "$STAGE_ROWS"
  _out "------------------------------------------------------------"
  _out2 "$(printf '%-12s %s%-6s%s %12s' 'TOTAL' "$C_CYN" '—' "$C_OFF" "$(fmt_ms "$total_ms")")" \
        "$(printf '%-12s %-6s %12s' 'TOTAL' '—' "$(fmt_ms "$total_ms")")"
  _out2 "${C_CYN}===========================================${C_OFF}" "==========================================="
}

# ============================ 帮助 ============================
usage() {
  cat >&2 <<'EOF'
push.sh — new-api 镜像 build/推送 ACR 一键脚本

用法: bash push.sh -n <命名空间> [-t <tag>] [选项]

必选
  -n, --namespace <ns>     prod | pre | test | dev（或全名 newapi-prod / newapi-pre / newapi-test / newapi-dev）

常用
  -t, --tag <tag>         镜像 tag；默认 <yyyymmdd>-<git短SHA>
  -r, --repo <name>       仓库名（默认 newapi-master）
  -i, --image <name:tag>  本地镜像名（默认 new-api:local）
      --extra-tags <a,b>  额外 tag，如 latest,stable（逐个推送）
      --no-build          跳过构建，直接推送本地已有镜像
      --build-only        只构建，不推送
      --no-login          跳过 docker login（已登录时）
      --logout            推送结束后 docker logout
      --create-repo       仓库不存在时用 aliyun CLI 自动创建（生产默认开 tag 不可变）
      --open-endpoint     登录前检查并【开启实例公网访问入口】（Enable=false 时本地推送必 EOF）
      --allow-ip <v,..>   追加公网 ACL 白名单（逗号分隔，可省略 /32）
                          关键字 auto = 自动探测本机出口 IP；all = 全放行（0.0.0.0/1 + 128.0.0.0/1）
      --skip-precheck     跳过 ACR 命名空间/仓库/tag 预检
      --dry-run           只打印命令，不实际执行
      --plain             关闭彩色输出
  -v, --verbose           打印详细命令（含 docker 原始输出）
  -h, --help              显示帮助

构建
  -f, --dockerfile <path> 默认 Dockerfile
  -c, --context <path>    构建上下文，默认仓库根目录
  -p, --platform <plat>   默认 linux/amd64
      --build-arg K=V     （可重复）
      --proxy <url|auto>  构建期 HTTP(S) 代理。注入 Docker **预定义 ARG**
                          （HTTP_PROXY/HTTPS_PROXY/NO_PROXY…），Dockerfile 无需声明。
                          auto = http://host.docker.internal:7890（本机 Clash）
      --no-proxy <list>   NO_PROXY 列表，默认 localhost,127.0.0.1,.aliyuncs.com
      --no-cache          构建禁用缓存
      --pull              构建前拉取基础镜像新版本
      --prune             构建前清理 BuildKit 构建缓存（镜像/容器/卷不受影响）
      --min-disk <GiB>    Docker VM 可用空间告警阈值，默认 4（低于 2 直接阻断）
      --skip-disk-check   跳过构建前的 Docker 磁盘水位检查
      --npm-registry <v>  bun install 的 npm 源：cn（默认，registry.npmmirror.com）
                          | official（registry.npmjs.org）| 任意 URL
                          注意：仅当 Dockerfile 声明了 `ARG NPM_REGISTRY` 才生效；
                          上游原版 Dockerfile 无该 ARG 时会自动跳过并提示改用 --proxy

注册表
      --registry <host>   默认 acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com
      --user <name>       默认 yanxuewei@5108890064395960
      --password <pwd>    不推荐（会进 shell history）；建议 ACR_PASSWORD 环境变量
      --instance <id>     默认 cri-avfqy9xkqi5bj8ee

日志: deploy/logs/push_<命名空间>_<tag>_<时间戳>.log
EOF
}

# ============================ 参数解析 ============================
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)   NS_INPUT="${2:-}"; shift 2 ;;
    -t|--tag)         TAG="${2:-}"; shift 2 ;;
    -r|--repo)        REPO_NAME="${2:-}"; shift 2 ;;
    -i|--image)       LOCAL_IMAGE="${2:-}"; shift 2 ;;
    -f|--dockerfile)  DOCKERFILE="${2:-}"; shift 2 ;;
    -c|--context)     CONTEXT="${2:-}"; shift 2 ;;
    -p|--platform)    PLATFORM="${2:-}"; shift 2 ;;
    --extra-tags)     EXTRA_TAGS="${2:-}"; shift 2 ;;
    --build-arg)      BUILD_ARGS="${BUILD_ARGS} --build-arg ${2:-}"; shift 2 ;;
    --registry)       REGISTRY="${2:-}"; shift 2 ;;
    --user)           ACR_USER="${2:-}"; shift 2 ;;
    --password)       ACR_PASSWORD="${2:-}"; shift 2 ;;
    --instance)       INSTANCE_ID="${2:-}"; shift 2 ;;
    --region)         REGION="${2:-}"; shift 2 ;;
    --no-build)       DO_BUILD=0; shift ;;
    --build-only)     DO_PUSH=0; shift ;;
    --no-login)       DO_LOGIN=0; shift ;;
    --logout)         DO_LOGOUT=1; shift ;;
    --create-repo)    CREATE_REPO=1; shift ;;
    --open-endpoint)  OPEN_ENDPOINT=1; shift ;;
    --allow-ip)       ALLOW_IPS="${2:-}"; shift 2 ;;
    --prune)          PRUNE_CACHE=1; shift ;;
    --min-disk)       MIN_FREE_GIB="${2:-4}"; shift 2 ;;
    --skip-disk-check) DISK_CHECK=0; shift ;;
    --npm-registry)   NPM_REGISTRY_SEL="${2:-}"; shift 2 ;;
    --proxy)          BUILD_PROXY="${2:-}"; shift 2 ;;
    --no-proxy)       NO_PROXY_LIST="${2:-}"; shift 2 ;;
    --skip-precheck)  PRE_CHECK=0; shift ;;
    --no-cache)       NO_CACHE="--no-cache"; shift ;;
    --pull)           PULL_BASE="--pull"; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --plain)          PLAIN=1; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_DIM=""; C_OFF=""; shift ;;
    -v|--verbose)     VERBOSE=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) printf 'ERROR: 未知参数 %s\n\n' "$1" >&2; usage; exit 2 ;;
  esac
done

# ============================ 参数校验 ============================
[[ -n "$NS_INPUT" ]] || { printf 'ERROR: 必须指定 -n/--namespace\n\n' >&2; usage; exit 2; }

case "$NS_INPUT" in
  prod|production|newapi-prod) NS="newapi-prod" ;;
  pre|preview|newapi-pre)      NS="newapi-pre" ;;
  test|testing|newapi-test)    NS="newapi-test" ;;
  dev|develop|newapi-dev)      NS="newapi-dev" ;;
  *) printf 'ERROR: 未知命名空间 "%s"（可用 prod|pre|test|dev 或 newapi-prod|newapi-pre|newapi-test|newapi-dev）\n' "$NS_INPUT" >&2; exit 2 ;;
esac

cd "$REPO_ROOT" || exit 1

# 默认 tag：<yyyymmdd>-<git短SHA>，非法字符归一为 '-'
sanitize_tag() { printf '%s' "$1" | sed 's/[^A-Za-z0-9_.-]/-/g'; }

if [[ -z "$TAG" ]]; then
  _sha="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null)"
  if [[ -n "$_sha" ]]; then TAG="$(date +%Y%m%d)-${_sha}"; else TAG="$(date +%Y%m%d-%H%M%S)"; fi
fi
TAG="$(sanitize_tag "$TAG")"

# 额外 tag 归一
EXTRA_TAGS_NORM=""
if [[ -n "$EXTRA_TAGS" ]]; then
  _saved="$IFS"; IFS=','
  for t in $EXTRA_TAGS; do
    t="$(printf '%s' "$t" | tr -d ' ')"
    [[ -n "$t" ]] || continue
    EXTRA_TAGS_NORM="${EXTRA_TAGS_NORM} $(sanitize_tag "$t")"
  done
  IFS="$_saved"
fi

# npm 源归一：cn → npmmirror；official/none → 留空走 Dockerfile 默认源
case "$NPM_REGISTRY_SEL" in
  cn|CN|china|npmmirror)          NPM_REGISTRY_SEL="https://registry.npmmirror.com" ;;
  official|npmjs|npm|none|off|"") NPM_REGISTRY_SEL="" ;;
esac

# 构建期代理归一：auto/clash/local → 本机 Clash
case "$BUILD_PROXY" in
  auto|AUTO|clash|local) BUILD_PROXY="http://host.docker.internal:7890" ;;
esac

# Dockerfile 是否声明了 ARG NPM_REGISTRY —— 只有声明了，--build-arg 才会被消费
DOCKERFILE_ARG_NPMREG=0
if [[ -f "$DOCKERFILE" ]] && grep -qE '^[[:space:]]*ARG[[:space:]]+NPM_REGISTRY' "$DOCKERFILE" 2>/dev/null; then
  DOCKERFILE_ARG_NPMREG=1
fi

if [[ "$DO_BUILD" == "1" ]]; then
  if [[ -n "$NPM_REGISTRY_SEL" ]]; then
    if [[ "$DOCKERFILE_ARG_NPMREG" == "1" ]]; then
      BUILD_ARGS="${BUILD_ARGS} --build-arg NPM_REGISTRY=${NPM_REGISTRY_SEL}"
    else
      # 未声明 ARG：传了也是 BuildKit 的一条 "not consumed" 警告，直接跳过
      NPM_REGISTRY_SKIPPED=1
      NPM_REGISTRY_SEL=""
    fi
  fi
  # 代理注入：HTTP_PROXY/HTTPS_PROXY 属 Docker 预定义 ARG，Dockerfile 不需要 ARG 声明
  if [[ -n "$BUILD_PROXY" ]]; then
    for _v in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
      BUILD_ARGS="${BUILD_ARGS} --build-arg ${_v}=${BUILD_PROXY}"
    done
    for _v in NO_PROXY no_proxy; do
      BUILD_ARGS="${BUILD_ARGS} --build-arg ${_v}=${NO_PROXY_LIST}"
    done
  fi
fi

REMOTE_REPO="${REGISTRY}/${NS}/${REPO_NAME}"
REMOTE_REF="${REMOTE_REPO}:${TAG}"

mkdir -p "$LOG_DIR"
LOG="${LOG_DIR}/push_${NS}_${TAG}_$(date +%Y%m%d_%H%M%S).log"
: > "$LOG"

TOTAL_START="$(now_ms)"

# ============================ 阶段 1：环境预检 ============================
cmd_exists() { command -v "$1" >/dev/null 2>&1; }
DOCKER=""

do_precheck() {
  begin_stage "precheck"
  DOCKER=""
  USE_BUILDX=0

  # docker 客户端与 daemon（dry-run 下缺失只告警，便于离线演练）
  if ! cmd_exists docker; then
    if [[ "$DRY_RUN" == "1" ]]; then warn "未找到 docker 命令（dry-run 继续）";
    else die "未找到 docker 命令"; fi
  else
    DOCKER="docker"
    if ! docker info >/dev/null 2>&1; then
      if [[ "$DRY_RUN" == "1" ]]; then warn "docker daemon 未运行（dry-run 继续）";
      else die "docker daemon 未运行（先启动 Docker Desktop）"; fi
    fi
    if docker buildx version >/dev/null 2>&1; then USE_BUILDX=1; fi
  fi

  # Dockerfile / 上下文
  if [[ "$DO_BUILD" == "1" ]]; then
    [[ -f "${REPO_ROOT}/${DOCKERFILE}" || -f "$DOCKERFILE" ]] || die "Dockerfile 不存在：${DOCKERFILE}"
    local ctx_abs="$CONTEXT"
    [[ "$ctx_abs" = /* ]] || ctx_abs="${REPO_ROOT}/${CONTEXT}"
    [[ -d "$ctx_abs" ]] || die "构建上下文目录不存在：${CONTEXT}"
    CONTEXT_ABS="$ctx_abs"
  else
    CONTEXT_ABS="${REPO_ROOT}"
  fi

  # git 状态（脏工作区提示，不阻断）
  if cmd_exists git && [[ -d "${REPO_ROOT}/.git" ]]; then
    GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null)"
    if [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | head -1)" ]]; then
      warn "工作区有未提交改动（镜像内容 ≠ 提交 ${GIT_SHA}）"
    fi
    log "git: ${GIT_SHA:-未知} 分支 $(git -C "$REPO_ROOT" branch --show-current 2>/dev/null)"
  else
    GIT_SHA=""
  fi

  log "参数：namespace=${NS} tag=${TAG} repo=${REPO_NAME} platform=${PLATFORM}"
  log "本地镜像：${LOCAL_IMAGE}    目标镜像：${REMOTE_REF}"
  log "构建方式：$([[ "${USE_BUILDX:-0}" == "1" ]] && echo 'buildx --load' || echo 'docker build')  build=${DO_BUILD} push=${DO_PUSH} login=${DO_LOGIN}"

  # ACR 侧预检（可选）
  if [[ "$PRE_CHECK" == "1" ]]; then
    if [[ ! -x "$ALIYUN" ]] && ! cmd_exists aliyun; then
      warn "未找到 aliyun CLI，跳过 ACR 预检（无法校验命名空间/仓库/tag 冲突）"
    else
      [[ -x "$ALIYUN" ]] || ALIYUN="$(command -v aliyun)"
      acr_precheck
    fi
  fi

  finish_stage "OK"
}

# 读取仓库信息：输出 repoId|repoType|tagImmutability
acr_repo_info() {
  "$ALIYUN" cr ListRepository --region "$REGION" --InstanceId "$INSTANCE_ID" \
    --RepoNamespaceName "$NS" --RepoName "$REPO_NAME" --PageSize 10 2>&1 | "$PY" -c '
import sys, json
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print("__PARSE_ERROR__||") ; raise SystemExit
if not d.get("IsSuccess", False):
    print("__API_ERROR__||"); raise SystemExit
for r in (d.get("Repositories") or []):
    if r.get("RepoName") == sys.argv[1]:
        ti = r.get("TagImmutability")
        print("%s|%s|%s" % (r.get("RepoId", ""), r.get("RepoType", ""), ti))
        raise SystemExit(0)
print("||")
' "$REPO_NAME"
}

acr_tag_exists() {  # $1=RepoId $2=tag
  "$ALIYUN" cr ListRepoTag --region "$REGION" --InstanceId "$INSTANCE_ID" --RepoId "$1" --PageSize 100 2>&1 | "$PY" -c '
import sys, json
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print("UNKNOWN"); raise SystemExit
if not d.get("IsSuccess", False):
    print("UNKNOWN"); raise SystemExit
for t in (d.get("Images") or []):
    if t.get("Tag") == sys.argv[1]:
        print("YES"); raise SystemExit
print("NO")
' "$2"
}

acr_precheck() {
  local info rid rtype ti verdict
  info="$(acr_repo_info)"
  rid="$(printf '%s' "$info" | cut -d'|' -f1)"
  rtype="$(printf '%s' "$info" | cut -d'|' -f2)"
  ti="$(printf '%s' "$info" | cut -d'|' -f3)"

  case "$rid" in
    __PARSE_ERROR__) warn "ACR 预检：ListRepository 返回无法解析，跳过"; return 0 ;;
    __API_ERROR__)   warn "ACR 预检：ListRepository 返回失败（检查 --region/--instance），跳过"; return 0 ;;
  esac

  if [[ -z "$rid" ]]; then
    warn "ACR 预检：仓库 ${NS}/${REPO_NAME} 不存在"
    if [[ "$CREATE_REPO" == "1" ]]; then
      local ti_flag="false"
      [[ "$NS" == "newapi-prod" ]] && ti_flag="true"
      if [[ "$DRY_RUN" == "1" ]]; then
        warn "  dry-run：将创建 ${NS}/${REPO_NAME}（RepoType=PRIVATE, TagImmutability=${ti_flag}）"
        return 0
      fi
      log "  --create-repo 生效：创建 ${NS}/${REPO_NAME}（RepoType=PRIVATE, TagImmutability=${ti_flag}）"
      if run "$ALIYUN" cr CreateRepository --region "$REGION" --InstanceId "$INSTANCE_ID" \
           --RepoNamespaceName "$NS" --RepoName "$REPO_NAME" --RepoType PRIVATE \
           --Summary "new-api ${NS} image repo (managed by push.sh)" --TagImmutability "$ti_flag"; then
        info="$(acr_repo_info)"; rid="$(printf '%s' "$info" | cut -d'|' -f1)"
        ti="$(printf '%s' "$info" | cut -d'|' -f3)"
        ok "ACR 预检：仓库已创建 RepoId=${rid} TagImmutability=${ti}"
      else
        die "创建仓库失败（AutoCreateRepo=false 时须显式建仓）"
      fi
    else
      warn "  CI/推送前需先建仓：加 --create-repo，或用 deploy/acr_namespace_init.sh / 控制台创建"
    fi
    return 0
  fi

  log "ACR 预检：仓库存在 RepoId=${rid} type=${rtype} tagImmutability=${ti}"

  verdict="$(acr_tag_exists "$rid" "$TAG")"
  case "$verdict" in
    YES)
      if [[ "$ti" == "True" || "$ti" == "true" ]]; then
        die "tag 已存在且该仓库开启「tag 不可变」→ 推送必被拒：${REMOTE_REF}（换 -t，或先在控制台关闭不可变）"
      fi
      warn "tag ${TAG} 已存在，推送将覆盖远端同名 tag（该仓库 tag 不可变关闭）"
      ;;
    NO)      log "ACR 预检：tag ${TAG} 未占用" ;;
    UNKNOWN) warn "ACR 预检：tag 占用情况未知（ListRepoTag 异常），继续" ;;
  esac
}

# ============================ 阶段 2：登录 ============================
# 读取实例公网访问入口状态：输出 "enable|domain1,domain2|aclEnable|entry1,entry2"
acr_internet_endpoint() {
  "$ALIYUN" cr GetInstanceEndpoint --region "$REGION" --InstanceId "$INSTANCE_ID" \
    --EndpointType internet 2>&1 | "$PY" -c '
import sys, json
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print("__PARSE_ERROR__|||"); raise SystemExit
if not d.get("IsSuccess", False):
    print("__API_ERROR__|||"); raise SystemExit
doms = [x.get("Domain", "") for x in (d.get("Domains") or [])]
ents = [x.get("Entry", "") for x in (d.get("AclEntries") or [])]
print("%s|%s|%s|%s" % (d.get("Enable"), ",".join(doms), d.get("AclEnable"), ",".join(ents)))
'
}

# 探测本机出口公网 IP（docker login / push 出网所经过的那条链路）
detect_egress_ip() {
  local u ip
  for u in https://checkip.amazonaws.com https://api.ipify.org https://ifconfig.me/ip; do
    ip="$(curl -s --max-time 8 "$u" 2>/dev/null | tr -d '[:space:]')"
    case "$ip" in
      [0-9]*.[0-9]*.[0-9]*.[0-9]*) printf '%s' "$ip"; return 0 ;;
    esac
  done
  return 1
}

# 单条 ACL 放行
acr_acl_add() {
  local cidr="$1"
  if run "$ALIYUN" cr CreateInstanceEndpointAclPolicy --region "$REGION" --InstanceId "$INSTANCE_ID" \
       --EndpointType internet --Entry "$cidr" --Comment "local push (push.sh)"; then
    ok "白名单已放行 ${cidr}"
    return 0
  fi
  warn "放行 ${cidr} 失败（可能已存在）"
  return 1
}

# 追加 IP 白名单（ACL）；$1=逗号分隔 CIDR 列表；关键字 all=全放行、auto=探测本机出口 IP
# 注：ACR 拒收 0.0.0.0/0（INSTANCE_ACCESS_ACL_ENTRY_INVALID），全放行用 0.0.0.0/1 + 128.0.0.0/1 拼出
acr_allow_ips() {
  local list="$1" cidr rc=0
  local saved="$IFS"; IFS=','
  for cidr in $list; do
    cidr="$(printf '%s' "$cidr" | tr -d ' ')"
    [[ -n "$cidr" ]] || continue
    case "$cidr" in
      all|ALL)
        log "  all：ACR 不接受 0.0.0.0/0 → 用 0.0.0.0/1 + 128.0.0.0/1 覆盖全部 IPv4"
        acr_acl_add "0.0.0.0/1"   || rc=1
        acr_acl_add "128.0.0.0/1" || rc=1
        continue ;;
      auto|AUTO)
        cidr="$(detect_egress_ip)"
        if [[ -z "$cidr" ]]; then
          warn "auto：探测本机出口 IP 失败（curl 外网不通），跳过"
          rc=1; continue
        fi
        log "  auto：探测到本机出口 IP = ${cidr}"
        cidr="${cidr}/32" ;;
    esac
    [[ "$cidr" == */* ]] || cidr="${cidr}/32"
    acr_acl_add "$cidr" || rc=1
  done
  IFS="$saved"
  return "$rc"
}

# 打开公网访问入口（危险动作，仅 --open-endpoint 时执行）
acr_open_internet_endpoint() {
  local info enable dom acl ents
  info="$(acr_internet_endpoint)"
  enable="$(printf '%s' "$info" | cut -d'|' -f1)"
  dom="$(printf '%s' "$info" | cut -d'|' -f2)"
  acl="$(printf '%s' "$info" | cut -d'|' -f3)"
  ents="$(printf '%s' "$info" | cut -d'|' -f4)"
  case "$enable" in
    __PARSE_ERROR__) warn "无法读取公网入口状态，跳过"; return 0 ;;
    __API_ERROR__)   warn "GetInstanceEndpoint 返回失败，跳过"; return 0 ;;
  esac

  if [[ "$enable" != "True" && "$enable" != "true" ]]; then
    warn "ACR 公网访问入口当前为【关闭】（Enable=false）→ 本地 docker login/push 必然 EOF"
    if [[ "$DRY_RUN" == "1" ]]; then
      warn "  dry-run：将执行 UpdateInstanceEndpointStatus --Enable true"
    else
      log "  --open-endpoint 生效：开启实例公网访问入口"
      if run "$ALIYUN" cr UpdateInstanceEndpointStatus --region "$REGION" --InstanceId "$INSTANCE_ID" \
           --EndpointType internet --Enable true; then
        info="$(acr_internet_endpoint)"
        ok "公网入口已开启：$(printf '%s' "$info" | cut -d'|' -f2)"
        warn "  入口为异步创建（Status 由 CREATING → RUNNING，约 1–2 分钟），期间 DNS 可能尚未发布"
      else
        die "开启公网访问入口失败（需 cr:UpdateInstanceEndpointStatus 权限）"
      fi
    fi
  else
    log "ACR 公网访问入口已开启：${dom}"
  fi

  # ACL 白名单：ACR 无独立开关接口，AclEnable 由条目决定；入口开启后常预置 127.0.0.1/32 占位
  if [[ "$acl" == "True" || "$acl" == "true" ]]; then
    log "  ACL 白名单：aclEnable=${acl} 现有条目 [${ents:-空}]"
    if [[ -n "$ALLOW_IPS" ]]; then
      log "  --allow-ip 生效：追加白名单 ${ALLOW_IPS}"
      [[ "$DRY_RUN" == "1" ]] && warn "  dry-run：将执行 CreateInstanceEndpointAclPolicy" || acr_allow_ips "$ALLOW_IPS"
    elif [[ -z "$ents" ]]; then
      warn "  白名单为空 → ACR 视为【全放行】（官方口径，不限制来源 IP），实例公网对全网开放"
      warn "  收紧：bash push.sh -n … --allow-ip auto"
    elif [[ "$ents" == "127.0.0.1/32" || "$ents" == "127.0.0.1/32,"* ]]; then
      warn "  ⚠ 白名单只有 127.0.0.1/32（ACR 默认占位）→ 你的真实出口 IP 会被拒（表现为 EOF / 直连 timeout）"
      warn "  放行本机出口 IP：bash push.sh -n … --allow-ip auto"
      warn "  或全放行        ：bash push.sh -n … --allow-ip all"
    fi
  fi
}

do_login() {
  if [[ "$DO_LOGIN" != "1" ]]; then begin_stage "login"; finish_stage "SKIP" "已 --no-login"; return 0; fi
  begin_stage "login"
  # 公网入口检查放在 dry-run 早退之前：读状态永远做，写操作由 acr_open_internet_endpoint 内部判 dry-run
  [[ "$OPEN_ENDPOINT" == "1" ]] && acr_open_internet_endpoint
  if [[ "$DRY_RUN" == "1" ]]; then warn "dry-run：跳过 docker login"; finish_stage "SKIP" "dry-run"; return 0; fi
  local pwd="$ACR_PASSWORD"
  if [[ -z "$pwd" ]]; then
    if [[ -t 0 ]]; then
      printf '%s请输入 ACR 访问凭证密码（%s，输入不回显）: %s' "$C_CYN" "$ACR_USER" "$C_OFF" >&2
      read -rs pwd
      printf '\n' >&2
    else
      die "非交互环境且未提供密码：请设置 ACR_PASSWORD 或传 --password"
    fi
  fi
  [[ -n "$pwd" ]] || die "密码为空"
  log "  ${C_CYN}\$ docker login --username ${ACR_USER} --password-stdin ${REGISTRY}${C_OFF}"
  if printf '%s' "$pwd" | docker login --username "$ACR_USER" --password-stdin "$REGISTRY" >>"$LOG" 2>&1; then
    ok "已登录 ${REGISTRY}（用户 ${ACR_USER}）"
  else
    tail -3 "$LOG" >&2
    diagnose_login_failure
    die "docker login 失败"
  fi
  finish_stage "OK"
}

# 登录失败的定向诊断：区分「网络/入口未开」与「凭证错误」
diagnose_login_failure() {
  local last enable dom
  last="$(tail -5 "$LOG" 2>/dev/null)"
  err "—— 失败诊断 ——"
  case "$last" in
    *EOF*|*"connection reset"*|*"TLS handshake"*|*"i/o timeout"*|*"no such host"*)
      warn "症状为**连接层失败**（EOF / reset / timeout），不是用户名密码问题——凭证根本没被校验"
      if [[ -x "$ALIYUN" ]] || command -v aliyun >/dev/null 2>&1; then
        [[ -x "$ALIYUN" ]] || ALIYUN="$(command -v aliyun)"
        local info
        info="$(acr_internet_endpoint)"
        enable="$(printf '%s' "$info" | cut -d'|' -f1)"
        dom="$(printf '%s' "$info" | cut -d'|' -f2)"
        if [[ "$enable" == "False" || "$enable" == "false" ]]; then
          err "根因：实例【公网访问入口未开启】（GetInstanceEndpoint --EndpointType internet → Enable=false）"
          log "  域名 ${dom} 已分配但未启用监听 → 外部直连被拒 → docker 报 EOF"
          log "  修复① 开公网入口（本地能直连，注意来源 IP 风险）："
          log "    aliyun cr UpdateInstanceEndpointStatus --region ${REGION} --InstanceId ${INSTANCE_ID} --EndpointType internet --Enable true"
          log "  修复② 本脚本一键开：加 --open-endpoint"
          log "  修复③ 不开公网：改用 VPC 域名 ${REGISTRY%-registry.ap-southeast-6.cr.aliyuncs.com}-registry-vpc.ap-southeast-6.cr.aliyuncs.com（在 VPC 内 / VPN 内构建推送）"
        else
          local acl ents
          acl="$(printf '%s' "$info" | cut -d'|' -f3)"
          ents="$(printf '%s' "$info" | cut -d'|' -f4)"
          if [[ "$acl" == "True" || "$acl" == "true" ]]; then
            case "$ents" in
              "") log "  公网 ACL 白名单为空 = 全放行（不限制来源 IP），不是拦截原因" ;;
              127.0.0.1/32|127.0.0.1/32,*) err "根因：公网 ACL 白名单仅 127.0.0.1/32（ACR 默认占位）→ 你的真实出口 IP 不在名单内，被直接拒绝" ;;
              *) warn "  公网 ACL 白名单已启用，条目 [${ents}] → 确认其中包含你当前的出口 IP" ;;
            esac
            log "  修复① 自动放行本机出口 IP：加 --allow-ip auto"
            log "  修复② 全放行（ACR 拒收 0.0.0.0/0，脚本用 0.0.0.0/1 + 128.0.0.0/1 拼）：加 --allow-ip all"
            log "  修复③ 手工：aliyun cr CreateInstanceEndpointAclPolicy --region ${REGION} --InstanceId ${INSTANCE_ID} --EndpointType internet --Entry <你的IP>/32"
            log "        （注意 Docker Desktop 走 Clash 时代理节点 IP 会变 → 建议把 ${REGISTRY} 加入代理直连规则）"
          fi
          log "  公网入口 Enable=${enable}（已开启）→ 逐项排查连接链："
          log "    ① DNS 是否解析：host ${REGISTRY}（入口开启后才发布解析记录）"
          log "    ② 本机/Docker 代理是否拦了该域名：docker info | grep -i proxy；必要时把 ${REGISTRY} 加入代理直连规则，或清空 Docker Desktop → Settings → Resources → Proxies"
          log "    ③ 手工验证：curl -sv https://${REGISTRY}/v2/  （正常应返回 401 Unauthorized 的 JSON）"
          log "    ④ 公司网络/VPN 是否放行 443 出海到菲律宾"
        fi
      else
        warn "  未找到 aliyun CLI，无法自动核对公网入口状态；自检：curl -sv https://${REGISTRY}/v2/"
      fi
      ;;
    *"unauthorized"*|*"401"*)
      err "根因：凭证错误（HTTP 401 unauthorized）→ 密码应为「访问凭证密码」，用户名是阿里云账号全名（如 yanxuewei@5108890064395960）"
      ;;
    *) warn "无法归类，完整输出见日志 ${LOG}" ;;
  esac
}

# ============================ Docker 磁盘水位（构建前置检查） ============================
# Docker Desktop 虚拟盘上限（MiB）：读 macOS 设置文件（新名 settings-store.json / 旧名 settings.json）
docker_disk_limit_mib() {
  local f v
  for f in "${HOME}/Library/Group Containers/group.com.docker/settings-store.json" \
           "${HOME}/Library/Group Containers/group.com.docker/settings.json"; do
    [[ -f "$f" ]] || continue
    v="$("$PY" -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit
v = d.get("DiskSizeMiB")
print(v if isinstance(v, (int, str)) and str(v).strip() else "")
' "$f" 2>/dev/null)"
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
  done
  return 1
}

# Docker.raw 路径（macOS，Docker Desktop）
docker_raw_path() {
  local d="${HOME}/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
  [[ -f "$d" ]] && printf '%s' "$d"
}

# macOS 宿主可用空间（KB）
host_free_kb() { df -Pk "${HOME}" 2>/dev/null | sed -n 2p | tr -s ' ' | cut -d' ' -f4; }

# Docker VM 内部根分区可用空间（KB）——起一个轻量探针容器读 df；无镜像则返回非 0
docker_vm_free_kb() {
  local d="${DOCKER:-docker}" img kb
  for img in alpine:3.20 alpine:latest alpine busybox:latest; do
    kb="$("$d" run --rm --privileged --pull=never --entrypoint sh "$img" \
          -c 'df -Pk / | sed -n 2p | tr -s " " | cut -d" " -f4' 2>/dev/null)"
    case "$kb" in [0-9]*) printf '%s' "$kb"; return 0 ;; esac
  done
  return 1
}

kb_to_gib() { awk -v k="${1:-0}" 'BEGIN{printf "%.1f", k/1048576}'; }
gib_int()   { printf '%s' "${1:-0}" | cut -d. -f1; }

# 磁盘不足时的修复指引（$1=上限 MiB $2=当前可用 GiB）
print_disk_fix_hint() {
  local lim="${1:-16384}" free="${2:-?}"
  _out "  —— Docker 磁盘空间不足：修复三选一 ——"
  _out "  ① 清理可回收空间（最快，不动镜像/容器/卷）："
  _out "       bash push.sh -n … --prune        # 构建前自动清 BuildKit 缓存"
  _out "       docker buildx prune -af          # 仅清构建缓存"
  _out "       docker image prune -f            # 清无标签（dangling）镜像"
  _out "       docker system df                 # 查看可回收量"
  _out "  ② 扩容虚拟磁盘（根治，当前上限 $(( ${lim} / 1024 )) GiB → 建议 64 GiB）："
  _out "       Docker Desktop → Settings → Resources → Disk image size = 64 GB → Apply & restart"
  _out "       命令行等价：先 Quit Docker Desktop，再改"
  _out "         ~/Library/Group Containers/group.com.docker/settings-store.json 的 \"DiskSizeMiB\": 65536"
  _out "  ③ 换构建机：在 VPC 内 ECS/ACK 上构建推送（不受本机虚拟盘限制）"
  _out "  注：当前 VM 可用 ${free} GiB；阈值用 --min-disk <GiB> 调整，或 --skip-disk-check 跳过"
}

check_docker_disk() {
  if [[ "${DISK_CHECK:-1}" != "1" ]]; then
    log "  --skip-disk-check：跳过 Docker 磁盘水位检查"
    return 0
  fi
  local lim="" vmkb="" hkb="" raw="" rawsz="" free_gib="" fi_=""

  # 显式 --prune 才清理（不擅自删用户数据）
  if [[ "${PRUNE_CACHE:-0}" == "1" ]]; then
    warn "  --prune：清理 BuildKit 构建缓存（镜像/容器/卷不受影响）"
    if [[ "$DRY_RUN" == "1" ]]; then
      warn "  dry-run：将执行 docker buildx prune -af"
    elif "${DOCKER}" buildx version >/dev/null 2>&1; then
      run "${DOCKER}" buildx prune -af || warn "  buildx prune 返回非 0（忽略）"
    else
      run "${DOCKER}" builder prune -af || warn "  builder prune 返回非 0（忽略）"
    fi
  fi

  lim="$(docker_disk_limit_mib || true)"
  raw="$(docker_raw_path || true)"
  [[ -n "$raw" ]] && rawsz="$(du -h "$raw" 2>/dev/null | cut -f1)"
  hkb="$(host_free_kb || true)"
  vmkb="$(docker_vm_free_kb || true)"

  if [[ -n "$lim" ]]; then
    log "  Docker 虚拟盘上限：$(( ${lim} / 1024 )) GiB（DiskSizeMiB=${lim}）$([[ -n "$rawsz" ]] && printf '，Docker.raw 宿主占用 %s' "$rawsz")"
  fi
  [[ -n "$hkb" ]] && log "  macOS 宿主可用：$(kb_to_gib "$hkb") GiB"

  if [[ -z "$vmkb" ]]; then
    warn "  无法读取 Docker VM 内部剩余空间（本机无 alpine/busybox 探针镜像）→ 跳过水位判定"
    return 0
  fi
  free_gib="$(kb_to_gib "$vmkb")"
  fi_="$(gib_int "$free_gib")"
  log "  Docker VM 可用空间：${free_gib} GiB（本项目构建峰值通常需 4–8 GiB）"

  if [[ "${fi_:-0}" -lt "${MIN_FREE_GIB:-4}" ]]; then
    err "Docker VM 空间不足：仅剩 ${free_gib} GiB，低于阈值 ${MIN_FREE_GIB} GiB"
    print_disk_fix_hint "${lim:-16384}" "$free_gib"
    if [[ "${fi_:-0}" -lt 2 ]]; then
      die "空间过低，构建必然 no space left on device"
    fi
  elif [[ "${fi_:-0}" -lt 8 ]]; then
    warn "  Docker VM 空间偏紧（${free_gib} GiB）→ 构建中途可能耗尽；建议 --prune 或扩容（见 --help）"
  else
    ok "  Docker 磁盘水位正常"
  fi
}

# 构建失败的定向诊断
diagnose_build_failure() {
  local txt lim vmkb
  txt="$(tail -30 "$LOG" 2>/dev/null)"
  err "—— 构建失败诊断 ——"
  case "$txt" in
    *"no space left on device"*|*ResourceExhausted*)
      err "根因：Docker 虚拟磁盘写满（BuildKit 写 /var/lib/docker/buildkit/... 报 ENOSPC）"
      lim="$(docker_disk_limit_mib || printf '16384')"
      vmkb="$(docker_vm_free_kb || printf '0')"
      print_disk_fix_hint "$lim" "$(kb_to_gib "$vmkb")"
      ;;
    *"failed to authorize"*|*"pull access denied"*|*"manifest unknown"*|*"dial tcp"*|*"i/o timeout"*|*"no such host"*)
      warn "根因倾向：基础镜像拉取失败（网络 / 代理 / 私有仓库凭证）"
      log "  排查：手工复现 docker pull <基础镜像>; 检查 Docker Desktop → Settings → Resources → Proxies"
      ;;
    *"returned a non-zero code"*|*"exit code:"*)
      warn "根因：某条 RUN 指令返回非 0（构建逻辑问题，非环境问题）→ 看日志中最后一次失败的 RUN 输出"
      ;;
    *) warn "未能归类，完整输出见日志 ${LOG}" ;;
  esac
}

# 构建环境提示：--npm-registry 是否真生效 / 构建期代理是否可达
build_env_report() {
  if [[ "${NPM_REGISTRY_SKIPPED:-0}" == "1" ]]; then
    warn "--npm-registry 未生效：Dockerfile 未声明 ARG NPM_REGISTRY（BuildKit 不消费未声明的 build-arg）"
    log "   → 不改 Dockerfile 的替代方案：--proxy auto（走本机 Clash）"
  fi
  if [[ -n "$BUILD_PROXY" ]]; then
    log "构建期代理：${BUILD_PROXY}    NO_PROXY=${NO_PROXY_LIST}"
    case "$BUILD_PROXY" in
      *host.docker.internal*)
        if (exec 3<>/dev/tcp/127.0.0.1/7890) 2>/dev/null; then
          log "  本机 127.0.0.1:7890 可达"
        else
          warn "  ⚠ 本机 127.0.0.1:7890 连不上 → 构建期代理不会生效"
          warn "    先启动 Clash，或指定其他端口：--proxy http://host.docker.internal:<port>"
        fi
        ;;
    esac
  fi
}

# ============================ 阶段 3：构建 ============================
do_build() {
  if [[ "$DO_BUILD" != "1" ]]; then begin_stage "build"; finish_stage "SKIP" "--no-build"; return 0; fi
  begin_stage "build"
  check_docker_disk
  build_env_report
  local rc=0
  if [[ "${USE_BUILDX:-0}" == "1" && "$PLATFORM" != *","* ]]; then
    # 单平台：buildx --load 直接落到本地镜像列表
    run docker buildx build --platform "$PLATFORM" --load \
      -f "$DOCKERFILE" -t "$LOCAL_IMAGE" $NO_CACHE $PULL_BASE $BUILD_ARGS "$CONTEXT_ABS" || rc=$?
  else
    [[ "$PLATFORM" == *","* ]] && warn "多平台构建不支持本地加载，改用 docker build（仅本机架构）"
    run docker build -f "$DOCKERFILE" -t "$LOCAL_IMAGE" $NO_CACHE $PULL_BASE $BUILD_ARGS "$CONTEXT_ABS" || rc=$?
  fi
  [[ "$rc" -eq 0 ]] || { diagnose_build_failure; die "docker build 失败（rc=${rc}），详见 ${LOG}"; }

  if [[ "$DRY_RUN" == "1" ]]; then
    IMAGE_SIZE="跳过（dry-run）"
    finish_stage "OK" "dry-run"
    return 0
  fi

  local size
  size="$(docker image inspect --format '{{.Size}}' "$LOCAL_IMAGE" 2>/dev/null)"
  IMAGE_SIZE="$(human_size "${size:-0}")"
  log "本地镜像 ${LOCAL_IMAGE} 大小 ${IMAGE_SIZE}"
  finish_stage "OK" "镜像 ${IMAGE_SIZE}"
}

# ============================ 阶段 4：打标 ============================
do_tag() {
  begin_stage "tag"
  run docker tag "$LOCAL_IMAGE" "$REMOTE_REF" || die "docker tag 失败"
  ok "打标 ${LOCAL_IMAGE} → ${REMOTE_REF}"
  local t
  for t in $EXTRA_TAGS_NORM; do
    [[ -n "$t" ]] || continue
    run docker tag "$LOCAL_IMAGE" "${REMOTE_REPO}:${t}" || die "docker tag 失败（${t}）"
    ok "打标额外 tag → ${REMOTE_REPO}:${t}"
  done
  finish_stage "OK" "$(( 1 + $(printf '%s' "$EXTRA_TAGS_NORM" | wc -w | tr -d ' ') )) 个 tag"
}

# ============================ 阶段 5：推送 ============================
do_push () {
  if [[ "$DO_PUSH" != "1" ]]; then begin_stage "push"; finish_stage "SKIP" "--build-only"; return 0; fi
  begin_stage "push"
  local refs="$REMOTE_REF" t
  for t in $EXTRA_TAGS_NORM; do [[ -n "$t" ]] && refs="$refs ${REMOTE_REPO}:${t}"; done
  for ref in $refs; do
    local s e
    s="$(now_ms)"
    if [[ "$DRY_RUN" != "1" ]]; then
      run docker push "$ref" || die "docker push 失败：${ref}"
    else
      warn "dry-run：跳过 docker push ${ref}"
    fi
    e="$(( $(now_ms) - s ))"
    ok "已推送 ${ref}（$(fmt_ms "$e")）"
  done
  # 摘要信息
  if [[ "$DRY_RUN" != "1" ]]; then
    IMAGE_DIGEST="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$REMOTE_REF" 2>/dev/null | head -1)"
  fi
  finish_stage "OK" "${IMAGE_DIGEST:-}"
}

# ============================ 阶段 6：登出（可选） ============================
do_logout() {
  if [[ "$DO_LOGOUT" != "1" ]]; then return 0; fi
  begin_stage "logout"
  run docker logout "$REGISTRY" || warn "docker logout 返回非 0（可忽略）"
  finish_stage "OK"
}

# ============================ 主流程 ============================
head_banner() {
  _out "============================================================"
  _out " new-api 镜像构建与推送 · ${NS}"
  _out " 目标: ${REMOTE_REF}"
  _out " Dockerfile: ${DOCKERFILE}"
  if [[ -n "$NPM_REGISTRY_SEL" ]]; then
    _out " npm 源: ${NPM_REGISTRY_SEL}"
  elif [[ "${NPM_REGISTRY_SKIPPED:-0}" == "1" ]]; then
    _out " npm 源: Dockerfile 默认（--npm-registry 未生效：Dockerfile 未声明 ARG NPM_REGISTRY）"
  else
    _out " npm 源: Dockerfile 默认"
  fi
  _out " 构建代理: ${BUILD_PROXY:-未启用}"
  _out " 日志: ${LOG}"
  _out "============================================================"
}

head_banner
do_precheck

# 本地已有镜像但跳过构建时，先确认镜像存在
if [[ "$DO_BUILD" != "1" && "$DRY_RUN" != "1" ]]; then
  docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1 || die "--no-build 但本地镜像不存在：${LOCAL_IMAGE}"
fi

do_login
do_build
do_tag
do_push
do_logout

print_summary

_out ""
_out2 "${C_CYN}最终产物${C_OFF}" "最终产物"
_out "  镜像地址 : ${REMOTE_REF}"
for t in $EXTRA_TAGS_NORM; do [[ -n "$t" ]] && _out "  额外 tag : ${REMOTE_REPO}:${t}"; done
_out "  镜像大小 : ${IMAGE_SIZE:-未知}"
_out "  Digest   : ${IMAGE_DIGEST:-未知}"
_out "  日志文件 : ${LOG}"
_out "  拉取命令 : docker pull ${REMOTE_REF}"
_out ""
