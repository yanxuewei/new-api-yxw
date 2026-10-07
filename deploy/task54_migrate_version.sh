#!/bin/bash
# task54_migrate_version.sh — 任务 54：把 migrations/ 下发到 mnl 节点，用 golang-migrate
# 对 staging 库（newapi_stage）跑 version → up → down 1 → up → up(no change)，
# 并在 down3→up 期间开并发 writer + pg_stat_activity 锁采样。
#
# usage:
#   bash deploy/task54_migrate_version.sh            # 生成 body 并下发执行
#   T54_BODY_ONLY=1 bash deploy/task54_migrate_version.sh   # 只生成 body（/tmp/t54_body.sh）
#
# 为什么在节点里跑：RDS 只有内网/受白名单保护；节点已在 mnl_vpc 白名单内，
# 且实测可直连 GitHub 下载 migrate 二进制（本机 macOS 无 go/docker/psql）。
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
MIG="$ROOT/migrations"
BODY="${T54_BODY:-/tmp/t54_body.sh}"
NODE="${T54_NODE:-i-5ts9wk588cliiweawind}"
LOOPS="${T54_LOOPS:-70}"

python3 - "$MIG" "$BODY" <<'GENPY'
import sys, os, glob
mig, out = sys.argv[1], sys.argv[2]
files = sorted(glob.glob(os.path.join(mig, "*.sql")))
if not files:
    raise SystemExit("no migrations/*.sql found")

head = r'''#!/bin/bash
# 任务54 主体（由 deploy/task54_migrate_version.sh 生成，自包含）
set -uo pipefail
export KUBECONFIG=${KUBECONFIG:-/tmp/k8s/kubeconfig}
NS=new-api; SECRET=new-api-secrets; STAGE_DB=newapi_stage
MIGBIN=/tmp/migbin/migrate; MIGDIR=/tmp/mig54
mkdir -p "$MIGDIR"
step(){ printf '\n===== %s =====\n' "$*"; }

step "0 - migrate 二进制"
if [ ! -x "$MIGBIN" ]; then
  mkdir -p /tmp/migbin && cd /tmp/migbin
  curl -fLsS --max-time 180 -o m.tar.gz \
    https://github.com/golang-migrate/migrate/releases/download/v4.19.1/migrate.linux-amd64.tar.gz \
    && tar xzf m.tar.gz && chmod +x migrate && mv migrate "$MIGBIN"
fi
printf 'migrate version := %s\n' "$("$MIGBIN" -version 2>&1)"
printf 'migrate sha256  := %s\n' "$(openssl sha256 -r "$MIGBIN" 2>/dev/null | awk '{print $1}')"

step "1 - staging DSN（只改 dbname，口令不落屏）"
RAW=$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.SQL_DSN_MIGRATE}' | base64 -d)
export RAW_DSN="$RAW" STAGE_DB="$STAGE_DB"
DSN=$(python3 - <<'PYDSN'
import os, urllib.parse as u
p = u.urlsplit(os.environ['RAW_DSN'])
print(u.urlunsplit((p.scheme, p.netloc, '/' + os.environ['STAGE_DB'], p.query, p.fragment)))
PYDSN
)
unset RAW RAW_DSN
export DSN MIGBIN MIGDIR
python3 - <<'PYSHOW'
import os, urllib.parse as u
p = u.urlsplit(os.environ['DSN'])
print('target host=%s port=%s db=%s user=%s sslmode=%s' %
      (p.hostname, p.port, p.path.lstrip('/'), p.username, (p.query or '-')))
PYSHOW

step "2 - 落盘迁移文件（先清空，否则上一轮的旧版本号会与新一轮冲突）"
# 这是节点上的**临时工作目录**（本脚本自建），必须每轮清空：
# migrate 会对 /tmp/mig54 做全量扫描，残留的 000003_backfill_*.sql 与新写的
# 000003_expand_concurrent_index.* 同版本号 ⇒ "duplicate migration file" 直接拒绝执行。
rm -rf "$MIGDIR"; mkdir -p "$MIGDIR"
'''

tail = r'''
step "3 - 清 dirty + 清理残留 idle-in-transaction 会话"
python3 - <<'PYKILL'
import os, urllib.parse as u
import pg8000
p = u.urlsplit(os.environ['DSN'])
kw = dict(user=u.unquote(p.username or ''), password=u.unquote(p.password or ''),
          host=p.hostname, port=int(p.port or 5432), database=p.path.lstrip('/'), timeout=8)
try:
    c = pg8000.connect(ssl_context=True, **kw)
except Exception:
    c = pg8000.connect(**kw)
c.autocommit = True
cur = c.cursor()
# 只杀本库、非本会话的 idle-in-transaction：这类会话会让 CREATE INDEX CONCURRENTLY 无限等待
cur.execute("select count(*) from pg_stat_activity where pid <> pg_backend_pid() "
            "and datname = current_database() and state = 'idle in transaction'")
n = cur.fetchone()[0]
cur.execute("select pg_terminate_backend(pid) from pg_stat_activity where pid <> pg_backend_pid() "
            "and datname = current_database() and state = 'idle in transaction'")
cur.fetchall()
print('idle-in-transaction sessions terminated:', n)
c.close()
PYKILL
V=$("$MIGBIN" -path "$MIGDIR" -database "$DSN" version 2>&1 || true)
printf 'current: %s\n' "$V"
case "$V" in
  *dirty*)
    # ⚠ 默认 force 到 1 的前提：dirty 一定发生在 000001 已成功之后（本次场景）。
    #    若在更后的版本 dirty，必须人工确认「上一个干净版本」并改 T54_FORCE_VER，
    #    否则版本号会与真实 schema 脱节（force 不执行任何 DDL）。
    printf 'force -> %s（只改 schema_migrations，不执行 DDL）\n' "${T54_FORCE_VER:-1}"
    "$MIGBIN" -path "$MIGDIR" -database "$DSN" force "${T54_FORCE_VER:-1}"
    "$MIGBIN" -path "$MIGDIR" -database "$DSN" version
    ;;
esac

step "4 - migrate version（期望 no migration 或已就位）"
mig(){ printf -- '--- migrate %s\n' "$*"; "$MIGBIN" -path "$MIGDIR" -database "$DSN" "$@" 2>&1; rc=$?; printf 'rc=%d\n' "$rc"; }
mig version

step "5 - migrate up"
T0=$(date +%s.%N); mig up; T1=$(date +%s.%N)
python3 -c "print('up elapsed = %.3f s' % ($T1-$T0))"
mig version

step "6 - schema 断言"
python3 - <<'PYCHK'
import os, json, urllib.parse as u
import pg8000
def connect():
    p = u.urlsplit(os.environ['DSN'])
    kw = dict(user=u.unquote(p.username or ''), password=u.unquote(p.password or ''),
              host=p.hostname, port=int(p.port or 5432), database=p.path.lstrip('/'), timeout=10)
    try:
        c = pg8000.connect(ssl_context=True, **kw)
    except Exception:
        c = pg8000.connect(**kw)
    c.autocommit = True   # 不留 idle in transaction（否则会阻塞 CREATE INDEX CONCURRENTLY）
    return c
c = connect(); cur = c.cursor()
def q(sql, flat=False):
    try:
        cur.execute(sql); rows = cur.fetchall()
    except Exception as e:
        return 'ERR: %s' % str(e)[:120]
    return [r[0] for r in rows] if flat else rows
out = {}
out['schema_migrations'] = q("select version, dirty from schema_migrations order by version")
out['drill_columns'] = q("select column_name from information_schema.columns where table_name='drill_accounts' order by ordinal_position", flat=True)
out['drill_indexes'] = q("select indexname from pg_indexes where tablename='drill_accounts' order by 1", flat=True)
out['drill_rows_total_and_nickname'] = q("select count(*), count(nickname) from drill_accounts")
out['baseline'] = q("select baseline_source, notes from schema_baseline")
out['server_version'] = q("show server_version")
print(json.dumps(out, ensure_ascii=False, indent=2))
c.close()
PYCHK

step "7 - 幂等：再 up 期望 no change"
mig up

step "8 - 锁观测（down 4 -> up，期间并发 writer + lock 采样）"
cat > /tmp/mig54/observe.py <<'PYOBS'
import os, sys, time, json, random, subprocess, threading, urllib.parse as u
import pg8000
DSN = os.environ['DSN']; MIGBIN = os.environ['MIGBIN']; MIGDIR = os.environ['MIGDIR']

def connect():
    p = u.urlsplit(DSN)
    kw = dict(user=u.unquote(p.username or ''), password=u.unquote(p.password or ''),
              host=p.hostname, port=int(p.port or 5432), database=p.path.lstrip('/'), timeout=8)
    try:
        c = pg8000.connect(ssl_context=True, **kw)
    except Exception:
        c = pg8000.connect(**kw)
    # ★★ 必须关掉隐式事务：pg8000 默认每条 execute 后事务保持打开 ⇒ 连接停在
    #    `idle in transaction`，而 CREATE INDEX CONCURRENTLY 必须等所有并发事务结束
    #    ⇒ 采样连接会把「要观测的迁移」本身卡死（本卡实测踩过：observe.py 永不退出，
    #      云助手任务停在 Running，pg_stat_activity 里留下 usename=newapi_migrate 的
    #      `idle in transaction` 会话）。autocommit=True 后每次查询自成事务。
    c.autocommit = True
    return c

stop = threading.Event()
res = {'samples': 0, 'max_lock_wait': 0, 'lock_events': 0, 'max_active_sec': 0.0}

def sampler():
    try:
        c = connect()
    except Exception as e:
        res['sampler_err'] = str(e); return
    cur = c.cursor()
    cur.execute("set statement_timeout = '5000'")
    while not stop.is_set():
        try:
            cur.execute("select count(*) from pg_stat_activity where wait_event_type='Lock' and pid<>pg_backend_pid()")
            n = cur.fetchone()[0]
            res['samples'] += 1
            if n > 0:
                res['lock_events'] += 1
            res['max_lock_wait'] = max(res['max_lock_wait'], n)
            cur.execute("select coalesce(max(extract(epoch from (now()-query_start))),0) from pg_stat_activity "
                        "where state<>'idle' and query_start is not null and pid<>pg_backend_pid()")
            res['max_active_sec'] = max(res['max_active_sec'], float(cur.fetchone()[0] or 0))
        except Exception as e:
            res['sampler_err'] = str(e); break
        time.sleep(0.2)
    try: c.close()
    except Exception: pass

def writer():
    try:
        c = connect()
    except Exception as e:
        res['writer_err'] = str(e); return
    cur = c.cursor(); lat = []
    cur.execute("set statement_timeout = '5000'")
    for _ in range(320):
        t0 = time.time()
        try:
            cur.execute("update drill_accounts set quota = quota + 1 where id = %s", (random.randint(1, 2000),))
            c.commit()
        except Exception as e:
            res['writer_err'] = str(e); break
        lat.append((time.time() - t0) * 1000.0)
        time.sleep(0.02)
    try: c.close()
    except Exception: pass
    lat.sort()
    if lat:
        res['writer'] = {'n': len(lat), 'p50_ms': round(lat[len(lat) // 2], 2),
                         'p95_ms': round(lat[int(len(lat) * 0.95) - 1], 2), 'max_ms': round(lat[-1], 2)}

ts = threading.Thread(target=sampler, daemon=True)
tw = threading.Thread(target=writer, daemon=True)
# 兜底硬超时：即使两个线程都异常退出不了，也让 observe.py 在 90s 内结束
hard = threading.Timer(90.0, lambda: os._exit(3))
hard.daemon = True
hard.start()
ts.start(); tw.start()
time.sleep(1.2)
logs = []
for c in (['down', '4'], ['up']):
    t0 = time.time()
    try:
        p = subprocess.run([MIGBIN, '-path', MIGDIR, '-database', DSN] + c,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           universal_newlines=True, timeout=120)
        logs.append({'cmd': ' '.join(c), 'rc': p.returncode, 'sec': round(time.time() - t0, 3),
                     'out': (p.stdout or '').strip()[:400]})
    except Exception as e:
        logs.append({'cmd': ' '.join(c), 'rc': None, 'sec': round(time.time() - t0, 3),
                     'out': 'EXC: %s' % e})
tw.join(timeout=60); stop.set(); ts.join(timeout=10)
hard.cancel()
res['migrate'] = logs
print(json.dumps(res, ensure_ascii=False, indent=2))
PYOBS
python3 /tmp/mig54/observe.py

step "9 - 回滚闭环 down 1 && up"
mig down 1 && mig up
mig version

step "10 - 最终幂等 + 指纹"
mig up
python3 - <<'PYFP'
import os, hashlib, urllib.parse as u
import pg8000
def connect():
    p = u.urlsplit(os.environ['DSN'])
    kw = dict(user=u.unquote(p.username or ''), password=u.unquote(p.password or ''),
              host=p.hostname, port=int(p.port or 5432), database=p.path.lstrip('/'), timeout=10)
    try:
        c = pg8000.connect(ssl_context=True, **kw)
    except Exception:
        c = pg8000.connect(**kw)
    c.autocommit = True   # 不留 idle in transaction（否则会阻塞 CREATE INDEX CONCURRENTLY）
    return c
c = connect(); cur = c.cursor()
cur.execute("select table_name from information_schema.tables where table_schema='public' order by 1")
tables = [r[0] for r in cur.fetchall()]
# ⚠ 只有一个 select 表达式时不能 `order by 1,2`（PG: ORDER BY position 2 is not in select list）
cur.execute("select table_name||'.'||column_name||'|'||data_type from information_schema.columns "
            "where table_schema='public' order by 1")
cols = [r[0] for r in cur.fetchall()]
cur.execute("select indexname||'|'||indexdef from pg_indexes where schemaname='public' order by 1")
idx = [r[0] for r in cur.fetchall()]
fp = "%d|%s|%s" % (len(tables),
                   hashlib.md5("\n".join(cols).encode()).hexdigest(),
                   hashlib.md5("\n".join(idx).encode()).hexdigest())
print("schema_fingerprint =", fp)
print("public_tables =", len(tables))
c.close()
PYFP

echo "TASK54 BODY DONE"
'''

chunks = [head]
for i, f in enumerate(files):
    name = os.path.basename(f)
    content = open(f, encoding="utf-8").read().replace("\r\n", "\n").rstrip("\n")
    tag = "SQL54_%03d_EOF" % i
    chunks.append("cat > \"$MIGDIR/%s\" <<'%s'\n%s\n%s\n\n" % (name, tag, content, tag))
chunks.append(tail)
open(out, "w", encoding="utf-8").write("".join(chunks))
print("body written: %s (%d migrations, %d bytes)" % (out, len(files), os.path.getsize(out)))
GENPY
rc=$?
[ "$rc" -eq 0 ] || { echo "[!] body 生成失败"; exit 1; }
bash -n "$BODY" || { echo "[!] body 语法错误"; exit 1; }
echo "[i] body syntax OK"

if [ "${T54_BODY_ONLY:-0}" = "1" ]; then
  echo "[i] T54_BODY_ONLY=1，跳过下发"; exit 0
fi

bash "$HERE/ack_remote.sh" mnl "$BODY" "$NODE" "$LOOPS"
