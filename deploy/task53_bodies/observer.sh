#!/usr/bin/env bash
# =============================================================================
# 任务 53 · 观测器 + 写入器 v2（在 ACK worker 节点内执行，由 task53_sync_convergence.sh 下发）
#
# 参数由驱动脚本写在头部（本文件不展开任何本地变量）：
#   SITE=sg|mnl  RUN_ID  SENTINEL  NS  PROBE  WRITE_ROLE=yes|no  LEAD  HOLD  WINDOW
#
# 时钟基准：延迟以**本节点自己观测到的 DB 值翻转时刻**为基准 ⇒ 不需要跨集群时钟对齐，
#           两地各出一份相对本地时钟的延迟表（timedatectl 的 synchronized 状态一并取证）。
#
# 代码事实（决定判据）：
#   main.go:115 / model/option.go:222   SyncOptions 每 SYNC_FREQUENCY 秒全量拉 options，**无主从分支**
#   model/option.go:196-220             loadOptionsFromDatabase → updateOptionMap(逐行) ⇒ 选项同步不经 Redis
#   model/option.go:586                 case "Footer": common.Footer = value（全仓唯一写点）
#   controller/misc.go:70               "footer_html": common.Footer（无鉴权，见 router/api-router.go:26）
#   main.go:83-85                       RedisEnabled ⇒ MemoryCacheEnabled 被强制 true（覆盖 CM 的 false）
#   main.go:106                         SyncChannelCache 仅在 MemoryCacheEnabled 时启动
#   model/channel_cache.go:122          无内存缓存 ⇒ 路由每请求查 DB（渠道改动即刻生效）
#
# v2 相对 v1 的两处硬修正（都来自 2026-10-06 16:01 实测踩到的坑）：
#   坑 A｜v1 用 sha256(value)[:12] 当状态指纹，而 sha(None) == sha("") ⇒ 「curl 失败 / data
#         缺失 / 值真是空串」三者指纹相同，mnl 腿 t=158.1 的"5 副本同时回落空值"因此无法归因。
#         ⇒ v2 改成显式三态标签 SENT / EMPTY / ABSENT / OTHER / ERR(http 码+详情)，
#           只有**成功读到**的非哨兵值才算"回落"，ERR 单独计数且绝不参与延迟计算。
#   坑 B｜v1 的"连续 5 次读库失败 ⇒ break"会把收尾 DELETE 一起带走，实测留下 options 残留行。
#         ⇒ v2：读库失败只告警不中止；每个写动作内置 5 次重试；循环外再加**强制复原**段，
#           退出前必复核 options 行数与目标键值长度。
#   附带｜mode=existing 且原值为空串时，v1 的 `old_b64 = (got or "").splitlines()[0]` 会 IndexError
#         ⇒ v2 对空结果返回 ""，且回滚 SQL 用字面 ''（不走 decode('','base64')，避免 NULL 语义）。
#
# 哨兵实验的可回退性（实况：options 原本只有 3 行，卡片给的候选键都不存在）：
#   existing 路径：键已存在 → 记录原值（base64）→ UPDATE 哨兵 → UPDATE 回原值（幂等可重跑）
#   insert  路径：键不存在 → INSERT 哨兵 → UPDATE 空串 → DELETE 该行（回到"无此行"初始态）
#   两种路径结束都会复核行数/键值长度。当前实况= 行已存在且值为空串 ⇒ 走 existing，零结构性写入。
#
# 密钥纪律：只输出 len 与 sha12，绝不输出 value 原文（options 里可能有配置口令）。
# =============================================================================
set -uo pipefail
export KUBECONFIG=${KUBECONFIG:-/tmp/k8s/kubeconfig}
: "${SITE:?}"; : "${RUN_ID:?}"; : "${SENTINEL:?}"; : "${NS:=new-api}"; : "${PROBE:=t53-pg}"
: "${WRITE_ROLE:=no}"; : "${LEAD:=75}"; : "${HOLD:=150}"; : "${WINDOW:=360}"
[ "$PROBE" = "t53-pg" ] || { echo "  [XX] 探针名必须与 manifest 固定名 t53-pg 一致（给了：$PROBE）"; exit 1; }

echo "== SITE=$SITE RUN_ID=$RUN_ID UTC=$(date -u '+%F %T') local=$(date '+%F %T %Z') =="
echo "   时钟: $(timedatectl 2>/dev/null | awk -F': ' '/synchronized/{printf "synced=%s ", $2}')$(timedatectl 2>/dev/null | awk -F': ' '/NTP service/{printf "ntp=%s", $2}')"

cleanup() {
  kubectl -n "$NS" delete pod "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1
  rm -f "/tmp/t53-readers-$RUN_ID.txt"
}
trap cleanup EXIT

kubectl -n "$NS" delete pod "$PROBE" --ignore-not-found --wait=true >/dev/null 2>&1
cat <<'YAML' | kubectl -n "$NS" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: t53-pg, labels: {app: t53-probe, run: task53}}
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
  containers:
  - name: p
    image: postgres:17
    imagePullPolicy: IfNotPresent
    command: ["sleep","3600"]
    env:
    - name: SQL_DSN
      valueFrom: {secretKeyRef: {name: new-api-secrets, key: SQL_DSN}}
    volumeMounts:
    - {name: ca, mountPath: /etc/ssl/rds, readOnly: true}
    resources: {requests: {cpu: 200m, memory: 256Mi}, limits: {cpu: 200m, memory: 256Mi}}
  volumes:
  - name: ca
    secret: {secretName: rds-ca-apse6, optional: true}
YAML
if ! kubectl -n "$NS" wait --for=condition=Ready pod/"$PROBE" --timeout=180s; then
  echo "  [XX] 探针 Pod 未就绪，事件如下："
  kubectl -n "$NS" describe pod "$PROBE" 2>/dev/null | sed -n '/Events:/,$p' | head -12
  exit 1
fi
echo "  [i] 探针 Pod Ready"

# psql 走 stdin；值一律 encode/decode(base64)，杜绝引号注入
q() { printf '%s\n' "$1" | kubectl -n "$NS" exec -i "$PROBE" -- sh -c 'psql "$SQL_DSN" -qAt -F"|"' 2>&1; }

echo "-- 目标实例 / 权限自检 --"
q "SELECT current_user, current_database(), split_part(version(),' ',1)||' '||split_part(version(),' ',2), pg_postmaster_start_time()::date" | sed 's/^/    /'
q "SELECT count(*) FROM options" | sed 's/^/    options 行数: /'
[ "$WRITE_ROLE" = "yes" ] && q "SELECT has_table_privilege(current_user,'options','UPDATE'), has_table_privilege(current_user,'options','INSERT'), has_table_privilege(current_user,'options','DELETE')" | sed 's/^/    UPDATE|INSERT|DELETE 权限: /'
echo "    options 键清单（只报键名与长度，值可能是配置口令 ⇒ 不回显）:"
q "SELECT key, length(value) FROM options ORDER BY key" | sed 's/^/      /'

echo "-- 每副本同步参数与循环节拍（只读） --"
kubectl -n "$NS" get pods --no-headers -o custom-columns=N:.metadata.name,I:.status.podIP,P:.status.phase 2>/dev/null | \
  awk -v probe="$PROBE" '$1 ~ /^new-api-/ && $3=="Running" && $1!=probe {print $1" "$2}' > "/tmp/t53-readers-$RUN_ID.txt"
NP=$(wc -l < "/tmp/t53-readers-$RUN_ID.txt" | tr -d ' ')
[ "$NP" -gt 0 ] || { echo "  [XX] 无可观测副本"; exit 1; }
while read -r name ip; do
  [ -n "$name" ] || continue
  echo "=== POD $name ($ip) ==="
  kubectl -n "$NS" get "pod/$name" -o json 2>/dev/null | python3 -c '
import sys, json
o = json.load(sys.stdin)
print("    image   =", o["spec"]["containers"][0]["image"])
print("    started =", o["status"].get("startTime"))
print("    node    =", o["spec"].get("nodeName"))
print("    restarts=", (o["status"].get("containerStatuses") or [{}])[0].get("restartCount"))
'
  kubectl -n "$NS" exec "pod/$name" -- sh -c '
    echo "    env: SYNC_FREQUENCY=[$SYNC_FREQUENCY] MEMORY_CACHE_ENABLED=[$MEMORY_CACHE_ENABLED] NODE_TYPE=[$NODE_TYPE]"
    if [ -n "${REDIS_CONN_STRING:-}" ]; then echo "    redis: set len=${#REDIS_CONN_STRING}"; else echo "    redis: unset"; fi
  ' 2>/dev/null || echo "    exec 失败"
  kubectl -n "$NS" logs "pod/$name" --tail=4000 2>/dev/null | \
    awk '/syncing options from database/{print "OPT "$2" "$4} /syncing channels from database/{print "CHN "$2" "$4} /Redis is enabled/{print "EVT redis-enabled"} /REDIS_CONN_STRING not set/{print "EVT redis-disabled"} /memory cache enabled/{print "EVT memory-cache-on"}' | \
    python3 -c '
import sys, datetime
rows = [ln.split() for ln in sys.stdin if ln.strip()]
bad = 0
for kind in ("OPT", "CHN"):
    ts = []
    for r in rows:
        if r[0] != kind: continue
        try:
            ts.append(datetime.datetime.strptime(r[1].replace("/", "-") + " " + r[2], "%Y-%m-%d %H:%M:%S"))
        except Exception:
            bad += 1
    if len(ts) < 2:
        print("    %s 循环: 窗口内 %d 次%s" % (kind, len(ts), "（%d 行时间戳无法解析）" % bad if bad else ""))
        continue
    d = [(b - a).total_seconds() for a, b in zip(ts, ts[1:])]
    print("    %s 循环: n=%d 间隔 min/avg/max = %.1f/%.1f/%.1f s（末次 %s）" %
          (kind, len(ts), min(d), sum(d) / len(d), max(d), ts[-1].strftime("%H:%M:%S")))
    if max(d) > 45: print("      [!!] 间隔 > 45s，周期任务可能被阻塞")
for e in [r for r in rows if r[0] == "EVT"][:4]:
    print("    启动标志:", " ".join(e[1:]))
'
  # 观测前先做一次连通性判定：节点 → podIP:3000 不通的副本会在主循环里记 ERR，
  # 这里先给一条基线，免得把"路径本来就不通"误读成"配置没收敛"。
  curl -s -o /dev/null --max-time 3 -w '    基线连通性 http=%{http_code} time=%{time_total}s\n' "http://$ip:3000/api/status" || echo "    基线连通性 curl 失败"
done < "/tmp/t53-readers-$RUN_ID.txt"

echo "-- 观测/写入主循环（WRITE_ROLE=$WRITE_ROLE LEAD=${LEAD}s HOLD=${HOLD}s WINDOW=${WINDOW}s）--"
python3 - "$SITE" "$RUN_ID" "$SENTINEL" "$NS" "$PROBE" "$WRITE_ROLE" "$LEAD" "$HOLD" "$WINDOW" <<'PY'
import hashlib, json, subprocess, sys, time

site, run_id, sentinel, ns, probe, write_role = sys.argv[1:7]
lead, hold, window = float(sys.argv[7]), float(sys.argv[8]), float(sys.argv[9])

# 只做"纯展示"键，绝不用带业务语义的开关（额度/演示模式/自助模式一律排除）
CANDIDATES = [("Footer", "footer_html"), ("SystemName", "system_name"), ("Logo", "logo")]


def sql(text):
    try:
        p = subprocess.run(["kubectl", "-n", ns, "exec", "-i", probe, "--", "sh", "-c",
                            'psql "$SQL_DSN" -qAt -F"|"'],
                           input=text, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, timeout=40)
    except Exception as e:
        return None, "kubectl-exec %s" % type(e).__name__
    out = (p.stdout or "").strip()
    # psql -q 对 UPDATE/DELETE 无输出 ⇒ 成功即空串，绝不能当成错误；
    # rc==0 时的 stderr（NOTICE/WARNING）只是信息，不参与判错，否则幂等写会被反复重试。
    if p.returncode != 0:
        return None, "psql rc=%d %s" % (p.returncode, ((p.stderr or "") or out).replace("\n", " ")[:160])
    return out, None


def sha(v):
    return hashlib.sha256((v or "").encode()).hexdigest()[:12]


def first(res):
    lines = (res or "").splitlines()
    return lines[0].strip() if lines else ""


def db_read(key):
    return sql("SELECT coalesce((SELECT value FROM options WHERE key='%s'),'@@NONE@@')" % key)


def db_label(v):
    if v is None:
        return "READ_FAIL"
    if v == sentinel:
        return "sentinel"
    if v == "@@NONE@@":
        return "NONE"
    return "other(len=%d,sha12=%s)" % (len(v), sha(v))


def pod_state(ip, field):
    """三态判读：把「读不到」和「读到空串」彻底分开，这是 v1 判不了 158.1 的根因。"""
    try:
        p = subprocess.run(["curl", "-s", "--max-time", "3", "-w", "\n%{http_code}",
                            "http://%s:3000/api/status" % ip],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, timeout=8)
    except Exception as e:
        return "ERR", "curl %s" % type(e).__name__
    raw = p.stdout or ""
    code = raw.rsplit("\n", 1)[-1].strip() if "\n" in raw else ""
    body = raw[:len(raw) - len(code) - 1] if code else raw
    if p.returncode != 0:
        return "ERR", "curl rc=%d http=%s" % (p.returncode, code or "-")
    try:
        o = json.loads(body)
    except Exception:
        return "ERR", "http=%s 非JSON(%dB)" % (code or "-", len(body))
    d = o.get("data") if isinstance(o, dict) else None
    if not isinstance(d, dict):
        return "ERR", "http=%s data=%s" % (code or "-", type(d).__name__)
    if field not in d:
        return "ABSENT", "http=%s" % code
    v = d.get(field)
    if v == sentinel:
        return "SENT", "http=%s" % code
    if v == "":
        return "EMPTY", "http=%s" % code
    return "OTHER", "http=%s len=%d sha12=%s" % (code, len(v), sha(v))


key = field = mode = old_b64 = None
for k, f in CANDIDATES:
    got, err = sql("SELECT count(*) FROM options WHERE key='%s'" % k)
    if err:
        print("    [XX] 读 %s 失败: %s" % (k, err))
        continue
    if got and got.splitlines()[0].strip() == "1":
        key, field, mode = k, f, "existing"
        got, err = sql("SELECT encode(value::bytea,'base64') FROM options WHERE key='%s'" % k)
        if err:
            print("    [XX] 取原值失败: %s ⇒ 放弃写入" % err)
            sys.exit(1)
        old_b64 = first(got)          # 空值时 encode 返回空行 ⇒ ""，v1 在这里 IndexError
        break
    if key is None:
        key, field, mode = k, f, "insert"
if not key:
    print("    [XX] 无法选定候选键"); sys.exit(1)
rows0 = first(sql("SELECT count(*) FROM options")[0])
print("    选定键=%s 字段=data.%s 路径=%s（options 初始行数=%s）" % (key, field, mode, rows0))
if mode == "existing":
    print("      原值 len=%d sha12=%s ⇒ 回滚 SQL=%s" %
          (len(old_b64), sha(old_b64), "字面 ''" if old_b64 == "" else "decode(base64)"))
else:
    print("      该键当前不存在 ⇒ 实验将 INSERT/UPDATE/DELETE 这一行，结束时回到「无此行」状态")

write_stmt = ("UPDATE options SET value='%s' WHERE key='%s'" % (sentinel, key) if mode == "existing"
              else "INSERT INTO options (key, value) VALUES ('%s','%s')" % (key, sentinel))
revert_stmt = ("UPDATE options SET value=%s WHERE key='%s'" %
               ("''" if old_b64 == "" else "decode('%s','base64')::text" % old_b64, key)
               if mode == "existing" else "UPDATE options SET value='' WHERE key='%s'" % key)
delete_stmt = "DELETE FROM options WHERE key='%s' AND value=''" % key


def act(label, stmt):
    """写动作一律带重试：v1 因为 break 把收尾 DELETE 带走了，实测留下残留行。"""
    for i in range(1, 6):
        got, err = sql(stmt)
        if err:
            print("    [W] %s 第%d次失败：%s" % (label, i, err)); sys.stdout.flush()
            time.sleep(3)
            continue
        print("    [W] %s 第%d次成功（t=%.1f）" % (label, i, time.time() - t0)); sys.stdout.flush()
        return True
    print("    [XX] %s 5 次全部失败 ⇒ 立刻升级人工复核" % label); sys.stdout.flush()
    return False


t0 = time.time()
t_write = t0 + lead if write_role == "yes" else None
t_revert = t_write + hold if write_role == "yes" else None
if write_role == "yes":
    print("    计划: T_WRITE=+%.0fs（写哨兵） T_REVERT=+%.0fs（回滚）%s" %
          (lead, lead + hold, " T_CLEAN=+%.0fs（DELETE，仅 insert 路径）" % (lead + hold + 150) if mode == "insert" else "（existing 路径不删行）"))
else:
    print("    计划: 纯观测窗口 %.0fs（不写任何值）" % window)

readers = []
for ln in open("/tmp/t53-readers-%s.txt" % run_id):
    n, ip = ln.split()
    readers.append({"name": n, "ip": ip, "label": None, "detail": "", "seen": [], "err": 0})

db_last, flips = None, []
wrote = reverted = cleaned = False
stop_at = t0 + (window if write_role != "yes" else lead + hold + 260)
db_err = 0
while time.time() < stop_at:
    now = time.time()
    if write_role == "yes" and not wrote and now >= t_write:
        wrote = act("T_WRITE 写哨兵", write_stmt)
    if write_role == "yes" and wrote and not reverted and now >= t_revert:
        reverted = act("T_REVERT 回滚", revert_stmt)
    if write_role == "yes" and reverted and not cleaned and mode == "insert" and now >= t_revert + 150:
        cleaned = act("T_CLEAN 删行", delete_stmt)

    v, err = db_read(key)
    if err:
        db_err += 1
        if db_err in (1, 3, 10, 20, 40):
            print("    [DB] t=%.1f 读库失败 x%d：%s（不中止，继续观测）" % (now - t0, db_err, err))
            sys.stdout.flush()
    else:
        db_err = 0
        if v != db_last:
            flips.append({"t": now, "label": db_label(v), "sent": v == sentinel})
            print("    [DB] t=%.1f 翻转 -> %s" % (now - t0, db_label(v))); sys.stdout.flush()
            db_last = v

    for r in readers:
        label, detail = pod_state(r["ip"], field)
        if label == "ERR":
            r["err"] += 1
        if label != r["label"]:
            r["seen"].append((now, label))
            print("    [POD] %-42s t=%.1f %s %s" % (r["name"], now - t0, label, detail)); sys.stdout.flush()
            r["label"] = label
            r["detail"] = detail

    if write_role == "yes" and t_revert and now > t_revert + 200:
        break
    time.sleep(1.0)

print("  ---- 收尾强制复原（循环内没做完的在这里补做）----")
if write_role == "yes":
    if not wrote:
        print("    哨兵从未写入过 ⇒ 无需复原")
    else:
        if not reverted:
            act("T_REVERT 补做", revert_stmt)
        if mode == "insert" and not cleaned:
            act("T_CLEAN 补做", delete_stmt)
    v, err = db_read(key)
    print("    库侧终态: %s%s" % (db_label(v), "" if not err else "（读库失败：%s）" % err))
print("    读库失败累计次数（本腿）: %d" % db_err)

print("  ---- 收敛汇总（site=%s，基准=本节点观测到的 DB 翻转时刻）----" % site)
idx = next((i for i, f in enumerate(flips) if f["sent"]), None)
sent_flip = flips[idx] if idx is not None else None
back_flip = next((f for f in flips[idx + 1:] if not f["sent"]), None) if idx is not None else None
print("    DB 翻转序列: %s" % " ".join("t=%.0f:%s" % (f["t"] - t0, f["label"]) for f in flips))
print("    %-42s %-11s %-11s %s" % ("pod", "→哨兵", "→离开哨兵", "备注"))
for r in readers:
    d1 = d2 = None
    if sent_flip:
        c = [t for (t, lb) in r["seen"] if lb == "SENT" and t >= sent_flip["t"] - 1.0]
        d1 = min(c) - sent_flip["t"] if c else None
    if back_flip:
        c = [t for (t, lb) in r["seen"] if lb in ("EMPTY", "ABSENT", "OTHER") and t >= back_flip["t"] - 1.0]
        d2 = min(c) - back_flip["t"] if c else None
    note = ""
    if r["err"]:
        note = "读取失败 %d 次%s" % (r["err"], "（全程读不到 ⇒ 不参与判据）" if d1 is None else "")
    if d1 is None and not r["err"]:
        note = "成功读到但始终未见哨兵"
    print("    %-42s %-11s %-11s %s" % (r["name"], ("+%.1fs" % d1) if d1 is not None else "-",
          ("+%.1fs" % d2) if d2 is not None else "-", note))
    print("      末态=%s %s" % (r["label"], r["detail"]))
rows1 = first(sql("SELECT count(*) FROM options")[0])
got, _ = sql("SELECT key, length(value) FROM options WHERE key='%s'" % key)
print("    收尾复核: options 行数 %s（初始 %s）｜目标键 %s｜路径=%s" % (rows1 or "?", rows0, got or "(无此行)", mode))
if write_role != "yes":
    print("    （本轮为纯观测窗口，未写入 ⇒ DB 翻转来自另一站的写入）")
PY

echo "== DONE SITE=$SITE RUN_ID=$RUN_ID =="
