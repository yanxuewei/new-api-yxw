#!/bin/bash
# 任务 30 · 步骤 8：SG 侧 V2 读侧（主站写入的 marker） + 探针清理
set -uo pipefail
NS=new-api

cat > /tmp/t30_read.sh <<'MEAS'
set -u
echo "--- V2 读侧：主站写入的 marker 是否立即可见 ---"
psql "$SQL_DSN" -Atc "select id, note, ts, now() - ts as age from ops_drill_marker order by id desc limit 3" 2>&1 | head -5
echo "--- 与主站比对：写入时刻 2026-10-05 21:17:24.289588+08（mnl 侧返回）---"
echo "--- 当前会话服务端时间 ---"
psql "$SQL_DSN" -Atc "select now()" 2>&1 | head -2
echo "--- 表结构确认（migrate 建的表在备站可见 = 同一实例）---"
psql "$SQL_DSN" -Atc "select column_name, data_type from information_schema.columns where table_name='ops_drill_marker' order by ordinal_position" 2>&1 | head -6
echo READ-DONE
MEAS

kubectl -n "$NS" exec -i t30-pg -- bash -s < /tmp/t30_read.sh 2>&1 | tail -30

echo "== 清理：删除两集群探针 Pod 由各自脚本负责，此处删 SG 侧 =="
kubectl -n "$NS" delete pod t30-pg --ignore-not-found --wait=false 2>&1 | head -2
echo DONE-08
