#!/bin/bash
# mock_ctl.sh —— 把 mock 上游的运行时参数**广播到全部副本**（节点侧执行，经 ack_remote_jkt_dev.sh 投递）
#
# 为什么需要广播：POST /__ctrl 走 Service 只会命中随机一个 Pod（压测时就踩到过），
# S5「50% 请求 5xx / 延迟 5s」必须所有副本同时劣化。Terway ENIIP 下 Pod IP 是 VPC 地址，
# 节点可直接连 => 用 kubectl 取全部 podIP 逐个 POST，不依赖任何 mesh/DNS。
#
# usage: bash mock_ctl.sh <normal|s5|429|raw> [raw-json]
#   normal  恢复压测默认档（300ms 首字 / 30ms 间隔 / 50 token / 12B / 0 错误）
#   s5      S5 上游劣化：50% 5xx + 额外 5s 延迟
#   429     全量 429（验证限流/重试路径）
#   raw     直接下发第二参 JSON（原样）
set -uo pipefail
NS=new-api-perf
MODE="${1:-normal}"
RAW="${2:-}"

case "$MODE" in
  normal) JSON='{"first_token_delay_ms":300,"token_interval_ms":30,"tokens_per_response":50,"token_text_bytes":12,"error_rate":0,"error_status":500,"extra_latency_ms":0}' ;;
  s5)     JSON='{"first_token_delay_ms":300,"token_interval_ms":30,"tokens_per_response":50,"token_text_bytes":12,"error_rate":0.5,"error_status":500,"extra_latency_ms":5000}' ;;
  429)    JSON='{"first_token_delay_ms":300,"token_interval_ms":30,"tokens_per_response":50,"token_text_bytes":12,"error_rate":1,"error_status":429,"extra_latency_ms":0}' ;;
  raw)    [ -n "$RAW" ] || { echo "[XX] raw 模式需要第二参 JSON"; exit 2; }; JSON="$RAW" ;;
  *)      echo "[XX] 未知模式：$MODE（normal|s5|429|raw）"; exit 2 ;;
esac

IPS=$(kubectl -n $NS get pod -l app=mock-upstream -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}')
[ -n "$IPS" ] || { echo "[XX] 取不到 mock pod IP"; exit 2; }

OK=0; FAIL=0
for IP in $IPS; do
  OUT=$(curl -sS -m 5 -X POST -H 'Content-Type: application/json' -d "$JSON" "http://$IP:8080/__ctrl" 2>&1)
  if printf '%s' "$OUT" | grep -q 'first_token_delay_ms'; then
    OK=$((OK+1)); printf '  [ok] %-15s %s\n' "$IP" "$(printf '%s' "$OUT" | head -c 120)"
  else
    FAIL=$((FAIL+1)); printf '  [XX] %-15s %s\n' "$IP" "$(printf '%s' "$OUT" | head -c 120)"
  fi
done
echo "--- mode=$MODE  ok=$OK fail=$FAIL"
[ "$FAIL" -eq 0 ]
