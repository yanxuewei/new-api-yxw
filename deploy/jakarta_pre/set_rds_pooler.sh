#!/usr/bin/env bash
# =============================================================================
# deploy/jakarta_pre/set_rds_pooler.sh —— 雅加达 RDS 开通托管池并把 pool_mode 设为 session
#
# 事实前提（2026-10-15 实测）：pgm-d9j9p421lzx4gw73（PG 17 / Basic / pg.n2.2c.1m）
#   DescribeDBInstanceAttribute 无 PGBouncerEnabled 字段、DescribeParameters 的 254 条参数里 pgbouncer.* 命中 0
#   ⇒ 该实例当前没有连接池，必须"先开通、再设值"（任务 45 步骤 3 的 3a→3c）。
#   对照：马尼拉主实例 pgm-5tstdhko64x2c01w（HighAvailability）PGBouncerEnabled=true、pool_mode=transaction —— **本脚本绝不碰它**。
#
# 生效判据：只认回读（PGBouncerEnabled=true 且 pool_mode=session 且实例 Running）。
# 开通失败按卡片 3d 记「雅加达无池 ⇒ 直连 5432，pool_mode 不适用」，不许改马尼拉凑数。
# =============================================================================
set -uo pipefail
REGION=ap-southeast-5
INSTANCE=pgm-d9j9p421lzx4gw73
FORBIDDEN="pgm-5tstdhko64x2c01w"          # 马尼拉主实例（正式环境）
APPLY="${APPLY:-0}"

notice() { echo "[pooler] $*"; }
die() { echo "[pooler][!] $*" >&2; exit 1; }

echo "=== R0 目标门禁"
[ "$REGION" = ap-southeast-5 ] || die "REGION 不是 ap-southeast-5，拒绝"
for f in $FORBIDDEN; do
  [ "$INSTANCE" != "$f" ] || die "目标 '$INSTANCE' 是正式环境实例，本卡红线禁止改动"
done
case "$INSTANCE" in pgm-d9j9p421lzx4gw73) : ;; *) die "目标实例不在白名单（只允许雅加达 dev 实例 pgm-d9j9p421lzx4gw73）" ;; esac
printf '  目标=%s @ %s（Apply=%s；Apply=0 只做只读取证与计划）\n' "$INSTANCE" "$REGION" "$APPLY"

attr() { aliyun rds DescribeDBInstanceAttribute --RegionId "$REGION" --DBInstanceId "$INSTANCE" 2>&1; }
pgb() { attr | grep -oE '"PGBouncerEnabled":[[:space:]]*"[^"]*"' | head -1; }
status() { attr | grep -oE '"DBInstanceStatus":[[:space:]]*"[^"]*"' | head -1; }

echo "=== R1 开通前现状"
printf '  %s\n' "$(pgb | sed 's/^/  /')"
printf '  %s\n' "$(status)"
printf '  实例上 pgbouncer.* 参数条数=%s\n' "$(aliyun rds DescribeParameters --RegionId "$REGION" --DBInstanceId "$INSTANCE" 2>/dev/null | grep -ci pgbouncer)"

if [ "$APPLY" != 1 ]; then
  notice "APPLY=0 ⇒ 只出计划，未发起任何写操作："; \
  notice "  ① ModifyDBInstanceConfig --ConfigName pgbouncer --ConfigValue true"; \
  notice "  ② 轮询 PGBouncerEnabled=true 且实例 Running"; \
  notice "  ③ ModifyParameter --Parameters '{\"pgbouncer.pool_mode\":\"session\"}' --Forcerestart false"; \
  notice "  ④ 回读 pool_mode=session（生效判据）"; exit 0
fi

echo "=== R2 开通托管池（ConfigName=pgbouncer / ConfigValue=true）"
aliyun rds ModifyDBInstanceConfig --RegionId "$REGION" --DBInstanceId "$INSTANCE" \
  --ConfigName pgbouncer --ConfigValue true 2>&1 | head -c 600 | sed 's/^/  /'
echo

echo "=== R3 轮询开通结果（至多 10 分钟）"
OPEN=0
for i in $(seq 1 20); do
  sleep 30
  V=$(pgb); S=$(status)
  printf '  t+%02dm %s  %s\n' "$i" "${V:-<无该字段>}" "${S:-<查不到>}"
  if grep -q 'true' <<<"$V"; then OPEN=1; break; fi
done
[ "$OPEN" = 1 ] || { echo "  [XX] 10 分钟内未开通 ⇒ 按卡片 3d 记「雅加达无池，pool_mode 不适用」，不要再重试第 4 步"; exit 3; }
printf '  参数模板里 pgbouncer.* 条数=%s\n' "$(aliyun rds DescribeParameters --RegionId "$REGION" --DBInstanceId "$INSTANCE" 2>/dev/null | grep -ci pgbouncer)"

echo "=== R4 设 pool_mode=session（ForceRestart=false，期望热改）"
aliyun rds ModifyParameter --RegionId "$REGION" --DBInstanceId "$INSTANCE" \
  --Parameters '{"pgbouncer.pool_mode":"session"}' --Forcerestart false 2>&1 | head -c 600 | sed 's/^/  /'
echo

echo "=== R5 回读（唯一生效判据）"
for i in $(seq 1 10); do
  sleep 15
  PM=$(aliyun rds DescribeParameters --RegionId "$REGION" --DBInstanceId "$INSTANCE" 2>&1 \
        | grep -A3 -i '"pgbouncer.pool_mode"' | grep -oE '"ParameterValue":[[:space:]]*"[^"]*"' | head -1)
  printf '  t+%02dm %s  %s\n' "$((i/4))" "${PM:-<查不到>}" "$(status)"
  grep -qi session <<<"$PM" && { echo "  [ok] pool_mode=session 已生效"; break; }
done
aliyun rds DescribeParameters --RegionId "$REGION" --DBInstanceId "$INSTANCE" 2>&1 \
  | grep -i -A3 pgbouncer | grep -oE '"Parameter(Name|Value)":[[:space:]]*"[^"]*"' | paste - - | head -20 | sed 's/^/  /'
echo "--- R1–R5 结束（写入面只有 $INSTANCE 的开池与 pool_mode；马尼拉实例未被调用）"
