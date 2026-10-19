#!/bin/bash
# poll_invocation.sh —— 直接读云助手调用的**当前**输出（跑长命令时用来观察进度）
# 为什么要它：ack_remote_jkt_dev.sh 只在远端收口后一次性打印，本地管道 `| tail` 会全部缓冲住 ⇒
#   长跑（阶梯压测 4×60s+）时本地看不到任何中间态，容易误判成"卡死"。这里用 InvokeId 现取现解。
# usage: bash deploy/jakarta_pre/poll_invocation.sh <InvokeId> [tail行数]
set -uo pipefail
INV="${1:?InvokeId required}"; N="${2:-30}"
REGION=ap-southeast-5
RESP=$(aliyun ecs DescribeInvocationResults --RegionId "$REGION" --InvokeId "$INV" 2>&1)
jq -r '.Invocation.InvocationResults.InvocationResult[0].InvocationStatus // "?"' <<<"$RESP"
jq -r '.Invocation.InvocationResults.InvocationResult[0].Output // empty' <<<"$RESP" | base64 -d 2>&1 | tail -"$N"
