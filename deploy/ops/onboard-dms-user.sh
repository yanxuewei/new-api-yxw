#!/usr/bin/env bash
# ============================================================================
# onboard-dms-user.sh — 新用户接入 DMS（控制台可进 + 实例可登录/查询）
# ----------------------------------------------------------------------------
# 背景：2026-10-16 把 DMS「进不去」的四层坑全部闭环，其中两层是
#【一次性 / 组级】的，新用户只要加进组就自动继承，**无需重配**：
#   ① RAM 策略级：newapi-enforce-mfa **v4** 已把 dms-console:* / dms:* 补进 NotAction
#   ② RAM 组级  ：同名 Custom 策略 AliyunDMSLoginConsoleAccess 已挂在
#                  dev_group / ops-prod_group / dev-program_group 上
# 因此本脚本只负责【DMS 侧 per-user 的三件事】：
#   ① RegisterUser          把 RAM 用户注册进 DMS 租户
#   ② UpdateUser            补昵称（昵称为空会让复核接口报 InvalidParameterValid）
#   ③ GrantUserPermission   逐实例授 LOGIN（实测足以「登录 + 正常查询」）
#
# 用法：
#   bash onboard-dms-user.sh <RAM用户名> [选项]
# 选项：
#   --nick <昵称>              DMS 昵称，默认 = RAM 用户名
#   --group <组名>             确保在该 RAM 组内（可重复；不在则 AddUserToGroup）
#   --instances "<id:名> ..."  目标实例，默认 3 个未托管实例
#   --dry-run                  只打印将执行的写操作，不真正调用
#   --revoke                   反向：撤销 LOGIN 授权
#   --yes                      配合 --revoke，跳过交互确认
#   -h | --help
#
# 幂等：重复执行安全（已注册 / 已授权 自动跳过）。
# 示例：
#   bash onboard-dms-user.sh lisi --group dev_group --group ops-prod_group --dry-run
#   bash onboard-dms-user.sh lisi --group dev_group --group ops-prod_group
#   bash onboard-dms-user.sh lisi --revoke --yes
# ============================================================================
set -uo pipefail

# —— PATH 自愈（bash -c 不读 profile，go/aliyun 常找不到）——
case ":${PATH}:" in
  *:/usr/local/bin:*) ;;
  *) export PATH="/usr/local/bin:${PATH}" ;;
esac

# ⚠ dms-enterprise 无 ap-southeast-* 端点，必须走 cn-hangzhou
DMS_REGION="${DMS_REGION:-cn-hangzhou}"
TID="${DMS_TID:-7659207}"
EXPIRE="${DMS_EXPIRE:-2099-12-31 23:59:59}"

# 默认目标实例：3 个「未托管」实例（需显式授 LOGIN）
#   排除 redis/Tair（2998669 / 3004344 / 3000947）—— 天然「免登录实例」，
#   授 LOGIN 会报「安全托管实例，无需申请登录权限」
#   排除 2998662 ck-mnl-newapi —— 已释放的 CK，DMS 陈旧条目（fanyan 2026-10-16 裁定不清理）
DEFAULT_INSTANCES="2997880:rds-mnl-newapi 3004426:rds-newapi-jkt-dev 3004473:newapi-logs-mysql"

DRY_RUN=0
REVOKE=0
ASSUME_YES=0
FAILED=0
USER_NAME=""
NICK=""
# ⚠ 变量名勿用 GROUPS —— bash 内建保留数组（当前用户组 ID，root 下 = (0)），
#    赋值会被忽略 ⇒ 数组恒非空、元素恒为 "0"（与 UID 只读同源的坑）。
REQ_GROUPS=()
INSTANCES="$DEFAULT_INSTANCES"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; }

# —— 稳健只读（通用）：3 次重试；exit 0 = 成功（stdout 可能为空串），exit 1 = 失败 ——
read_retry() {
  local i out
  for i in 1 2 3; do
    if out=$(aliyun "$@" 2>&1); then printf '%s' "$out"; return 0; fi
    sleep 1
  done
  log "WARN     只读查询失败（已重试 3 次）：$* :: $(printf '%s' "$out" | tail -n1)"
  return 1
}

# —— 稳健只读：查某实例上 NICK 的权限类型 ——
#    exit 0 = 查询成功（stdout = 类型列表，可能为空）；exit 1 = 查询失败（已重试 3 次）
#    ⚠ 必须区分「查得到但为空」（=真没授）与「查询失败」（=未知）：
#      早期版本用 q() 静默吞错，会把 API 抖动误判成「没授权」⇒ 重复授权。
#      服务端虽幂等，但诊断失真、日志误导（本项目大忌：静默漏判）。
has_login() {
  local iid="$1" i out
  for i in 1 2 3; do
    if out=$(aliyun dms-enterprise ListInstanceUserPermissions \
               --Tid "$TID" --region "$DMS_REGION" \
               --InstanceId "$iid" --UserName "$NICK" \
               --cli-query 'UserPermissions.UserPermission[].PermDetails.PermDetail[].PermType' 2>&1); then
      printf '%s' "$out"
      return 0
    fi
    sleep 1
  done
  log "WARN     查询实例 ${iid} 现有权限失败（已重试 3 次）：$(printf '%s' "$out" | tail -n1)"
  return 1
}

# —— 取某实例上 LOGIN 的 UserAccessId（撤销用）；exit 1 = 查询失败 ——
login_access_id() {
  local iid="$1" i out
  for i in 1 2 3; do
    if out=$(aliyun dms-enterprise ListInstanceUserPermissions \
               --Tid "$TID" --region "$DMS_REGION" \
               --InstanceId "$iid" --UserName "$NICK" \
               --cli-query "UserPermissions.UserPermission[].PermDetails.PermDetail[?PermType=='LOGIN'].UserAccessId | [0]" 2>&1); then
      # ⚠ JMESPath 的 `| [0]` 在本 CLI 上不稳（有时仍回 [ .. ] 包裹）⇒ 取首个数字串兜底
      printf '%s' "$out" | tr -d '"' | grep -o '[0-9][0-9]*' | head -n1
      return 0
    fi
    sleep 1
  done
  log "WARN     查询 ${iid} 的 UserAccessId 失败（已重试 3 次）：$(printf '%s' "$out" | tail -n1)"
  return 1
}

# —— 带 3 次重试的写操作包装（VPC 端点偶发抖动 ⇒ 铁律：写操作重试 ≥3）——
run() {
  local desc="$1"; shift
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY-RUN  ${desc}"
    log "         \$ $*"
    return 0
  fi
  local i out rc
  for i in 1 2 3; do
    out=$("$@" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
      log "OK       ${desc}"
      return 0
    fi
    log "RETRY(${i}/3) ${desc} :: $(printf '%s' "$out" | tail -n1)"
    sleep 2
  done
  log "FAIL     ${desc} :: ${out}"
  return 1
}

# —— 授权（单独处理：安全托管实例的报错属正常跳过）——
grant_login() {
  local iid="$1" iname="$2" i out rc
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY-RUN  GrantUserPermission ${NICK} <- LOGIN @ ${iname}(${iid})"
    return 0
  fi
  for i in 1 2 3; do
    out=$(aliyun dms-enterprise GrantUserPermission \
            --Tid "$TID" --region "$DMS_REGION" \
            --UserId "$DMS_USER_ID" --DsType INSTANCE --InstanceId "$iid" \
            --PermTypes LOGIN --ExpireDate "$EXPIRE" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then log "OK       LOGIN @ ${iname}(${iid})"; return 0; fi
    case "$out" in
      *安全托管*) log "SKIP     ${iname}(${iid}) 为安全托管实例，天然免登录"; return 0 ;;
    esac
    log "RETRY(${i}/3) LOGIN @ ${iname}(${iid}) :: $(printf '%s' "$out" | tail -n1)"
    sleep 2
  done
  log "FAIL     LOGIN @ ${iname}(${iid}) :: ${out}"
  return 1
}

# —— 撤销（需 UserAccessId）——
revoke_login() {
  local iid="$1" iname="$2" acc
  acc=$(login_access_id "$iid") || return 1
  case "$acc" in
    ""|null)
      log "SKIP     ${iname}(${iid}) 无 LOGIN 记录"
      return 0 ;;
    *[!0-9]*)
      log "FAIL     ${iname}(${iid}) 取到非法 UserAccessId「${acc}」→ 中止，避免发脏参数"
      return 1 ;;
  esac
  run "RevokeUserPermission ${NICK} x LOGIN @ ${iname}(${iid}) [accessId=${acc}]" \
    aliyun dms-enterprise RevokeUserPermission \
      --Tid "$TID" --region "$DMS_REGION" \
      --UserId "$DMS_USER_ID" --DsType INSTANCE --InstanceId "$iid" \
      --PermTypes LOGIN --UserAccessId "$acc"
}

# —— 复核：断言 LOGIN 存在（区分「无权限」与「查询失败」）——
check_login() {
  local iid="$1" iname="$2" types
  if ! types=$(has_login "$iid"); then
    printf '  %-28s %-8s ⚠️  查询失败（未知）\n' "${iname}" "${iid}" >&2
    return 1
  fi
  if printf '%s\n' "$types" | tr -d '" \t' | grep -qx 'LOGIN'; then
    printf '  %-28s %-8s ✅ LOGIN\n' "${iname}" "${iid}" >&2
    return 0
  fi
  printf '  %-28s %-8s ❌ 未检出 LOGIN\n' "${iname}" "${iid}" >&2
  return 1
}

# ============================== 参数解析 ==============================
while [ $# -gt 0 ]; do
  case "$1" in
    --nick)      NICK="$2"; shift 2 ;;
    --group)     REQ_GROUPS+=("$2"); shift 2 ;;
    --instances) INSTANCES="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --revoke)    REVOKE=1; shift ;;
    --yes)       ASSUME_YES=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    -*)          die "未知选项：$1" ;;
    *)           if [ -z "$USER_NAME" ]; then USER_NAME="$1"; else die "多余参数：$1"; fi; shift ;;
  esac
done
[ -n "$USER_NAME" ] || { usage; exit 2; }
[ -n "$NICK" ] || NICK="$USER_NAME"

command -v aliyun >/dev/null 2>&1 || die "aliyun CLI 未找到（PATH 自愈后仍缺）"

log "=== DMS 用户接入：${USER_NAME}（dms-region=${DMS_REGION} tid=${TID} dry-run=${DRY_RUN}）==="

# ============================ 步骤 1/5：RAM 用户 ============================
log "步骤 1/5 · 解析 RAM 用户"
if ! _raw=$(read_retry ram GetUser --UserName "$USER_NAME" --cli-query 'User.UserId'); then
  die "查询 RAM 用户 ${USER_NAME} 失败（网络/权限问题）—— 注意：这**不是**「用户不存在」"
fi
RAM_UID=$(printf '%s' "$_raw" | tr -d '"' | grep -o '[0-9][0-9]*' | head -n1)
[ -n "$RAM_UID" ] || die "RAM 用户 ${USER_NAME} 不存在（或当前身份无权 GetUser）"
log "         RAM UserId = ${RAM_UID}"

# ========================== 步骤 2/5：RAM 组归属 ============================
log "步骤 2/5 · 校验 RAM 组归属（组级策略在此继承）"
CUR_GROUPS=$(read_retry ram ListGroupsForUser --UserName "$USER_NAME" --cli-query 'Groups.Group[].GroupName' | tr -d '"[], \t')
log "         当前组：$(printf '%s ' $CUR_GROUPS)"
if [ "${#REQ_GROUPS[@]}" -gt 0 ]; then
  for g in "${REQ_GROUPS[@]}"; do
    if printf '%s\n' "$CUR_GROUPS" | grep -qx "$g"; then
      log "         已在 ${g}，跳过"
    else
      run "AddUserToGroup ${USER_NAME} -> ${g}" \
        aliyun ram AddUserToGroup --UserName "$USER_NAME" --GroupName "$g" || FAILED=1
    fi
  done
else
  log "         （未指定 --group；请确认用户已在 dev_group / ops-prod_group / dev-program_group 之一）"
fi

# ========================== 步骤 3/5：DMS 注册 ==============================
log "步骤 3/5 · DMS 注册状态"
dms_uid_of() {
  read_retry dms-enterprise ListUsers --Tid "$TID" --region "$DMS_REGION" \
    --cli-query "UserList.User[?Uid=='${RAM_UID}'].UserId | [0]" \
  | tr -d '" \t' | grep -o '[0-9][0-9]*' | head -n1
}
DMS_USER_ID=$(dms_uid_of)
if [ -z "$DMS_USER_ID" ] || [ "$DMS_USER_ID" = "null" ]; then
  log "         未注册 → RegisterUser"
  run "RegisterUser --Uid ${RAM_UID}" \
    aliyun dms-enterprise RegisterUser --Uid "$RAM_UID" --Tid "$TID" --region "$DMS_REGION" || FAILED=1
  DMS_USER_ID=$(dms_uid_of)
else
  log "         已注册（DMS UserId=${DMS_USER_ID}）"
fi
if [ "$DRY_RUN" = 0 ]; then
  [ -n "$DMS_USER_ID" ] && [ "$DMS_USER_ID" != "null" ] || die "注册后仍取不到 DMS UserId"
fi
log "         DMS UserId = ${DMS_USER_ID:-<dry-run>}"

# ========================== 步骤 4/5：DMS 昵称 ==============================
log "步骤 4/5 · DMS 昵称"
CUR_NICK=$(read_retry dms-enterprise ListUsers --Tid "$TID" --region "$DMS_REGION" \
             --cli-query "UserList.User[?Uid=='${RAM_UID}'].NickName | [0]" | tr -d '"' | head -n1)
if [ -z "$CUR_NICK" ] || [ "$CUR_NICK" = "null" ]; then
  log "         昵称为空 → UpdateUser --UserNick ${NICK}"
  run "UpdateUser --Uid ${RAM_UID} --UserNick ${NICK}" \
    aliyun dms-enterprise UpdateUser --Uid "$RAM_UID" --UserNick "$NICK" \
      --Tid "$TID" --region "$DMS_REGION" || FAILED=1
else
  NICK="$CUR_NICK"
  log "         已有昵称「${NICK}」，跳过"
fi

# ====================== 步骤 5/5：逐实例授权并复核 =========================
if [ "$REVOKE" = 1 ]; then
  log "步骤 5/5 · 撤销 LOGIN 授权"
  if [ "$ASSUME_YES" != 1 ]; then
    printf '确认撤销 %s 在以下实例的 LOGIN 权限？[y/N] ' "$NICK" >&2
    read -r ans </dev/tty || ans=""
    case "$ans" in y|Y|yes|YES) ;; *) die "已取消" ;; esac
  fi
  for item in $INSTANCES; do
    revoke_login "${item%%:*}" "${item#*:}" || FAILED=1
  done
else
  log "步骤 5/5 · 逐实例授 LOGIN（目标 ${INSTANCES}）"
  for item in $INSTANCES; do
    iid="${item%%:*}"; iname="${item#*:}"
    if have=$(has_login "$iid"); then
      if printf '%s\n' "$have" | tr -d '" \t' | grep -qx 'LOGIN'; then
        log "         ${iname}(${iid}) 已有 LOGIN，跳过"
        continue
      fi
    else
      log "         ${iname}(${iid}) 现状未知 → 仍执行授权（幂等兜底，勿据此判断）"
    fi
    grant_login "$iid" "$iname" || FAILED=1
  done
fi

# ============================== 复核 & 汇总 ==============================
log "—— 复核（ListInstanceUserPermissions）——"
if [ "$DRY_RUN" = 0 ]; then
  for item in $INSTANCES; do
    iid="${item%%:*}"; iname="${item#*:}"
    if [ "$REVOKE" = 1 ]; then
      if types=$(has_login "$iid"); then
        if printf '%s\n' "$types" | tr -d '" \t' | grep -qx 'LOGIN'; then
          printf '  %-28s %-8s ❌ 仍存在 LOGIN\n' "${iname}" "${iid}" >&2; FAILED=1
        else
          printf '  %-28s %-8s ✅ 已撤销\n' "${iname}" "${iid}" >&2
        fi
      else
        printf '  %-28s %-8s ⚠️  查询失败（未知）\n' "${iname}" "${iid}" >&2; FAILED=1
      fi
    else
      check_login "$iid" "$iname" || FAILED=1
    fi
  done
else
  log "  （dry-run：跳过复核）"
fi

echo
if [ "$FAILED" = 0 ]; then
  log "=== ✅ 完成：${NICK} 可登录 DMS 控制台并在目标实例登录/查询（ExpireDate=${EXPIRE}）==="
  exit 0
else
  log "=== ⚠️ 存在失败项，请查看上方 FAIL 行 ==="
  exit 1
fi
