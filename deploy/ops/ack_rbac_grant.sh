#!/usr/bin/env bash
# =============================================================================
# ACK 集群 RBAC 授权（RAM 用户 → 集群角色）
#
# 为什么需要：RAM 策略只管「能不能调 ACK 的 API」；K8s 里能不能看/改资源是
#   **第二套** RBAC 体系。两套都配齐才不报 APISERVER.403。
#   2026-10-10 daimingming 报：
#     deployments.apps is forbidden: User "218577891456544282"
#     cannot list resource "deployments" in API group "apps" in the namespace "default"
#
# ★ 关键语义：`cs GrantPermissions` 是**全量覆盖**（overwrites all existing cluster
#   permissions）。body 里必须列出该用户要保留的**所有**集群，否则会把其它集群的
#   既有授权一并抹掉。
# ★ 因此 `apply` 的设计原则是 **「读现状 → 原样保留所有集群 → 只改角色」**，
#   并带**防降权护栏**：若把已有的 admin 降为 ops/dev 等，必须显式 ALLOW_DOWNGRADE=1。
#
# 用法：
#   bash deploy/ops/ack_rbac_grant.sh check                    # 只读：现状 + dry-run
#   ROLE=ops bash deploy/ops/ack_rbac_grant.sh apply           # 改角色（保留所有已有集群）
#   bash deploy/ops/ack_rbac_grant.sh verify                   # 复核
#   ALLOW_DOWNGRADE=1 ROLE=ops bash ... apply                  # 确认降权时才允许
#
# 环境变量：RAM_UID（默认 daimingming=218577891456544282）· ROLE（默认 admin）
#   ⚠️ 不要用 UID 作变量名 —— 它是 bash 只读变量（root 下=0），赋值静默失败。
# =============================================================================
set -uo pipefail

MNL_CLUSTER="cd57e40ce9a634c1698c2f5c5e09bd93c"   # ap-southeast-6
SG_CLUSTER="ca75829e3492d491d9d434de087913798"    # ap-southeast-1
MNL_REGION="ap-southeast-6"

RAM_UID_V="${RAM_UID:-218577891456544282}"
ROLE="${ROLE:-admin}"
ALLOW_DOWNGRADE="${ALLOW_DOWNGRADE:-0}"

ALIYUN="${ALIYUN:-$(command -v aliyun || echo "$HOME/.workbuddy/binaries/aliyun-cli/aliyun")}"
PY="${PY:-$(command -v python3 || echo /usr/bin/python3)}"

say() { printf '%s\n' "$*" >&2; }
# DescribeUserPermission 不分地域，返回该用户全部集群授权
cur_raw() { "$ALIYUN" cs DescribeUserPermission --uid "$RAM_UID_V" --region "$MNL_REGION" 2>&1; }

cur_json() {
  cur_raw | "$PY" -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: d=[]
print(json.dumps([{'cluster':x.get('resource_id'),'role':x.get('role_type'),
                   'rtype':x.get('resource_type'),'created':x.get('CreatedAt')} for x in d],
                 ensure_ascii=False, indent=2))"
}

# 由现状派生 body：保留所有已授权集群，把角色改成 $ROLE
build_body() {
  cur_raw | "$PY" -c "
import sys,json
ROLE='$ROLE'
try: d=json.load(sys.stdin)
except Exception: d=[]
out=[{'cluster':x.get('resource_id'),'role_name':ROLE,'role_type':'cluster',
      'is_custom':False,'is_ram_role':False} for x in d if x.get('resource_id')]
print(json.dumps(out, ensure_ascii=False))"
}

# 输出：首行=降权条数，后续行为明细
detect_downgrade() {
  cur_raw | "$PY" -c "
import sys,json
ROLE='$ROLE'
rank={'admin':100,'admin-view':90,'ops':50,'dev':40,'restricted':10}
try: d=json.load(sys.stdin)
except Exception: d=[]
bad=[x for x in d if rank.get(x.get('role_type'),0) > rank.get(ROLE,0)]
print(len(bad))
for x in bad:
    print('  %s: %s -> %s' % (x.get('resource_id'), x.get('role_type'), ROLE))"
}

do_check() {
  say "=== RAM 用户 UID=$RAM_UID_V —— 当前集群 RBAC ==="
  cur_json
  say ""
  say "=== 拟发布 body（role=$ROLE；集群取自现状，保留全部）==="
  local b; b="$(build_body)"
  if [ -z "$b" ] || [ "$b" = "[]" ]; then
    say "  (现状为空)"
  else
    printf '%s' "$b" | "$PY" -c "import sys,json;print(json.dumps(json.load(sys.stdin),ensure_ascii=False,indent=2))"
    say ""
    say "=== 命令预演（--cli-dry-run，不实际调用）==="
    "$ALIYUN" cs GrantPermissions --uid "$RAM_UID_V" --region "$MNL_REGION" \
      --body "$(printf '%s' "$b" | tr -d '\n')" --cli-dry-run 2>&1 | tail -6
  fi
  say ""
  say "=== 防降权预检 ==="
  local n; n="$(detect_downgrade)"
  if [ "$(printf '%s' "$n" | head -1)" = "0" ]; then
    say "  无降权（目标 $ROLE 不低于现状）"
  else
    say "  ⚠️ 检测到降权，apply 将被拒绝（unless ALLOW_DOWNGRADE=1）："
    printf '%s\n' "$n" | tail -n +2
  fi
}

do_apply() {
  local n; n="$(detect_downgrade)"
  local cnt; cnt="$(printf '%s' "$n" | head -1)"
  if [ "${cnt:-0}" -gt 0 ] && [ "$ALLOW_DOWNGRADE" != "1" ]; then
    say "=== ⛔ 拒绝执行：检测到降权 ==="
    printf '%s\n' "$n" | tail -n +2
    say ""
    say "  如确实要降权：ALLOW_DOWNGRADE=1 ROLE=$ROLE bash $0 apply"
    return 1
  fi

  local b; b="$(build_body)"
  if [ -z "$b" ] || [ "$b" = "[]" ]; then
    say "=== 现状为空，无可保留的集群 → 拒绝（请先在控制台授权）==="
    return 1
  fi

  say "=== GrantPermissions（全量覆盖；保留现状全部集群，role=$ROLE）==="
  local out; out=$("$ALIYUN" cs GrantPermissions --uid "$RAM_UID_V" --region "$MNL_REGION" --body "$b" 2>&1)
  say "  raw: $(printf '%s' "$out" | head -c 300)"
  if printf '%s' "$out" | grep -qiE 'FORBIDDEN|INVALID|ClientError'; then say "  [FAIL]"; return 1; fi
  say "  [OK] 已提交；等 5s"
  sleep 5
  do_verify
}

do_verify() {
  say "=== 复核（期望：全部集群 role_type=$ROLE）==="
  cur_json
  local bad; bad="$(cur_raw | "$PY" -c "
import sys,json
ROLE='$ROLE'
try: d=json.load(sys.stdin)
except Exception: d=[]
print(sum(1 for x in d if x.get('role_type')!=ROLE))")"
  say ""
  if [ "${bad:-1}" = "0" ]; then say "  VERIFY=PASS（全部为 $ROLE）"; return 0; fi
  say "  VERIFY=FAIL（$bad 条与目标不符）"; return 1
}

case "${1:-check}" in
  check)  do_check ;;
  apply)  do_apply ;;
  verify) do_verify ;;
  *) say "用法: $0 [check|apply|verify]"; exit 2 ;;
esac
