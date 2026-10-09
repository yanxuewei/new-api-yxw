#!/bin/bash
# 任务54 诊断：staging 库 dirty/锁状态 + 是否有残留 migrate 进程
set -uo pipefail
export KUBECONFIG=${KUBECONFIG:-/tmp/k8s/kubeconfig}
NS=new-api; SECRET=new-api-secrets; STAGE_DB=newapi_stage

echo "### A) 节点上是否有残留 migrate 进程"
pgrep -af migrate 2>/dev/null || echo "(无)"

echo "### B) DSN 与库状态"
RAW=$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.SQL_DSN_MIGRATE}' | base64 -d)
export RAW_DSN="$RAW" STAGE_DB="$STAGE_DB"
DSN=$(python3 - <<'PYDSN'
import os, urllib.parse as u
p = u.urlsplit(os.environ['RAW_DSN'])
print(u.urlunsplit((p.scheme, p.netloc, '/' + os.environ['STAGE_DB'], p.query, p.fragment)))
PYDSN
)
unset RAW RAW_DSN
export DSN

timeout 60 python3 - <<'PYCHK'
import os, json, urllib.parse as u
import pg8000
p = u.urlsplit(os.environ['DSN'])
kw = dict(user=u.unquote(p.username or ''), password=u.unquote(p.password or ''),
          host=p.hostname, port=int(p.port or 5432), database=p.path.lstrip('/'), timeout=8)
try:
    c = pg8000.connect(ssl_context=True, **kw)
except Exception:
    c = pg8000.connect(**kw)
cur = c.cursor()
cur.execute("set statement_timeout = '5000'")
out = {}
try:
    cur.execute("select version, dirty from schema_migrations")
    out['schema_migrations'] = cur.fetchall()
except Exception as e:
    out['schema_migrations_err'] = str(e)[:200]
try:
    cur.execute("select column_name from information_schema.columns where table_name='drill_accounts' order by ordinal_position")
    out['drill_columns'] = [r[0] for r in cur.fetchall()]
except Exception as e:
    out['drill_cols_err'] = str(e)[:150]
try:
    cur.execute("select count(*) from drill_accounts")
    out['drill_rows'] = cur.fetchone()[0]
except Exception as e:
    out['drill_rows_err'] = str(e)[:150]
try:
    cur.execute("select pid, usename, state, coalesce(wait_event_type,'-')||'/'||coalesce(wait_event,'-'), "
                "left(coalesce(query,''), 70) from pg_stat_activity where pid <> pg_backend_pid() order by pid")
    out['sessions'] = cur.fetchall()
except Exception as e:
    out['sessions_err'] = str(e)[:150]
c.close()
print(json.dumps(out, ensure_ascii=False, indent=2, default=str))
PYCHK
echo "rc_py=$?"
echo "BODY DONE"
