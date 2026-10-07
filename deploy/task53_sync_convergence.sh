#!/usr/bin/env bash
# =============================================================================
# Day 2 · 任务 53｜配置热更新跨节点收敛验证 SYNC_FREQUENCY=30 —— 驱动脚本
#
# 权威卡片：deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md（任务 53 卡）
# 执行体：  deploy/task53_bodies/observer.sh（节点侧观测/写入器，参数由本脚本以 env 头注入）
# 通道：    deploy/ack_remote.sh <mnl|sg>（两集群 endpoint_public_access=false）
#           ⚠ 卡片写的 `kubectl --context mnl/sg` 在本环境不可执行。
#
# 代码事实（本仓实测，决定判据；详见 observer.sh 头注释与本卡报告）：
#   main.go:115 / model/option.go:222   SyncOptions 每 SYNC_FREQUENCY 秒全量拉 options（**无主从分支**）
#   model/option.go:26-31               AllOption = DB.Find ⇒ 选项同步**不经 Redis**
#   main.go:83-85                       RedisEnabled ⇒ MemoryCacheEnabled 被强制 true（覆盖 CM 的 false）
#   main.go:106                         SyncChannelCache 仅在 MemoryCacheEnabled 时启动
#   model/channel_cache.go:122          无内存缓存时路由直接查 DB ⇒ 渠道改动即刻生效（但每请求多一次查询）
#   common/sys_log.go:17                SysLog 走 stdout ⇒ kubectl logs 可见循环节拍
#   router/api-router.go:26             GET /api/status 无鉴权；响应包在 {"success":..,"data":{..}}
#   model/option.go:586                 option key "Footer" → data.footer_html
#
# 模式：
#   --precheck  只读：两地副本（含 master）env / 循环节拍 / /api/status 字段结构 / 键存在性
#   --probe     ⚠ 集群写：建探针 Pod → 把选定 option 改成哨兵值 → 观测两地每副本首次读到新值的
#               延迟 → **回滚为原值**（base64 精确复原）→ 再测一次 → 删探针 Pod
#               可回退性：只动 1 行 1 键，原值在节点侧以 base64 暂存并用于 decode 回滚
#   --status    只读现状（= --precheck 精简）
#   --cleanup   删两地残留探针 Pod（破坏性，需核准）
#
# 密钥纪律：脚本与日志不含任何凭据值。DSN 只在集群内经 secretKeyRef 注入探针 Pod；
#           取值一律以 sha12+len 呈现；哨兵值本身不含敏感信息。
# =============================================================================
set -uo pipefail
MODE="${1:---status}"
shift || true

HERE="$(cd "$(dirname "$0")" && pwd)"
ACK="$HERE/ack_remote.sh"
BODY_SRC="$HERE/task53_bodies/observer.sh"
NS=new-api
PROBE=t53-pg
RUN_ID="t53-$(date +%Y%m%d-%H%M%S)-$$"
SENTINEL="T53PROBE-$(date +%s)-${RANDOM}"
LOGDIR="$HERE/logs/task53_${MODE#--}_$(date +%Y%m%d-%H%M%S)"
# ⚠ 严禁把 ACKCTL_DIR 指成两地共用一个目录：ack_remote.sh 的 kubeconfig 缓存键是
#   $KCDIR/kubeconfig（不含站点），2026-10-06 15:42 的 precheck 就是这么把 **mnl** 的
#   kubeconfig（server=https://10.0.22.182:6443）喂给了 sg 节点，表现为跨区 i/o timeout
#   而不是认证失败。⇒ 这里显式不覆盖，走默认 /tmp/ackctl-<site>（按站点隔离，两地并发安全）。
: "${ACKCTL_DIR:=}"
unset ACKCTL_DIR   # 见上：绝不向子进程传递两地共用的缓存目录

say() { printf '%s\n' "$*" >&2; }
die() { printf '  [XX] %s\n' "$*" >&2; exit 1; }
[[ -f "$ACK" ]] || die "缺 $ACK"
[[ -f "$BODY_SRC" ]] || die "缺 $BODY_SRC"
mkdir -p "$LOGDIR"

case "$MODE" in --precheck|--probe|--status|--cleanup) : ;; *) die "MODE 必须 --precheck|--probe|--status|--cleanup（给了：$MODE）" ;; esac

say "[i] 模式   = $MODE"
say "[i] RUN_ID = $RUN_ID"
say "[i] 哨兵   = $SENTINEL（本卡专用标记串，不含凭据）"
say "[i] 日志   = $LOGDIR"

render() { # $1=site $2=write_role $3=window $4=lead $5=hold
  local site="$1" wr="$2" win="$3" lead="$4" hold="$5" out="$LOGDIR/body-$1.sh"
  {
    echo "#!/usr/bin/env bash"
    echo "# 由 task53_sync_convergence.sh 渲染（$MODE · site=$site · $RUN_ID）"
    printf 'SITE=%s\nRUN_ID=%s\nSENTINEL=%s\nNS=%s\nPROBE=%s\nWRITE_ROLE=%s\nWINDOW=%s\nLEAD=%s\nHOLD=%s\nexport SITE RUN_ID SENTINEL NS PROBE WRITE_ROLE WINDOW LEAD HOLD\n' \
      "$site" "$RUN_ID" "$SENTINEL" "$NS" "$PROBE" "$wr" "$win" "$lead" "$hold"
    cat "$BODY_SRC"
  } > "$out"
  bash -n "$out" || die "渲染后的 body 语法不通过：$out"
  printf '%s\n' "$out"
}

case "$MODE" in
  --precheck|--status)
    WIN=20; [[ "$MODE" = "--status" ]] && WIN=12
    for s in mnl sg; do
      body="$(render "$s" no "$WIN" 0 0)"
      say "[i] $s 只读侦察（观测窗口 ${WIN}s，不写任何值）"
      bash "$ACK" "$s" "$body" "" 90 2>&1 | tee "$LOGDIR/$s.out"
    done
    say "[i] 完整输出：$LOGDIR"
    ;;

  --probe)
    LEAD=75; HOLD=150; SGWIN=340
    say "[i] ⚠ 写动作：UPDATE options SET value='$SENTINEL' WHERE key=<选定键> ⇒ ${HOLD}s 后按 base64 精确回滚"
    say "[i]    只动 1 行；不重启、不改 ConfigMap/Secret、不新增云资源、不产生云费用"
    say "[i]    mnl = 写入+观测（T_WRITE=+${LEAD}s，T_REVERT=+$((LEAD+HOLD))s），sg = 纯观测 ${SGWIN}s"
    bm="$(render mnl yes "$SGWIN" "$LEAD" "$HOLD")"
    bs="$(render sg no "$SGWIN" 0 0)"
    bash "$ACK" mnl "$bm" "" 150 > "$LOGDIR/mnl.out" 2>&1 &
    MPID=$!
    sleep 8
    bash "$ACK" sg "$bs" "" 150 > "$LOGDIR/sg.out" 2>&1 &
    SPID=$!
    say "[i] 已并发下发（mnl pid=$MPID / sg pid=$SPID），等待执行完成…"
    wait "$MPID"; mrc=$?
    wait "$SPID"; src=$?
    say "[i] 通道 rc：mnl=$mrc sg=$src（非 0 也必须先看输出再判）"
    for f in mnl sg; do
      echo "===================== $f ====================="
      cat "$LOGDIR/$f.out"
    done
    say "[i] 完整输出：$LOGDIR"
    ;;

  --cleanup)
    for s in mnl sg; do
      b="$LOGDIR/cleanup-$s.sh"
      {
        echo '#!/usr/bin/env bash'
        echo 'export KUBECONFIG=${KUBECONFIG:-/tmp/k8s/kubeconfig}'
        echo "kubectl -n $NS get pod $PROBE --ignore-not-found -o name | xargs -r kubectl -n $NS delete pod --wait=false"
        echo "echo '  剩余探针 Pod:'; kubectl -n $NS get pod $PROBE --no-headers 2>/dev/null | sed 's/^/    /'; echo '    (空=已清)'"
        echo "echo '  业务副本:'; kubectl -n $NS get pods -l app=new-api --no-headers | awk '{print \"    \"\$1\" \"\$2\" \"\$3}'"
      } > "$b"
      bash "$ACK" "$s" "$b" "" 40 2>&1 | tee "$LOGDIR/cleanup-$s.out"
    done
    ;;
esac
