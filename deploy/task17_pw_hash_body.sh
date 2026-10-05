#!/usr/bin/env bash
NS=new-api
echo "### DSN 口令指纹（只输出 sha256 前 12 位与长度，绝不输出值）"
for k in SQL_DSN SQL_DSN_MIGRATE REDIS_CONN_STRING LOG_SQL_DSN SESSION_SECRET; do
  raw=$(kubectl -n $NS get secret new-api-secrets -o jsonpath="{.data.$k}" 2>/dev/null)
  if [ -z "$raw" ]; then echo "  $k = (键不存在)"; continue; fi
  printf %s "$raw" | base64 -d | python3 -c "
import sys,re,hashlib
v=sys.stdin.read()
m=re.search(r'://([^:/@\s]+):([^@/\s]*)@', v)
if m:
    print('  %-20s user=%-14s pw_sha[:12]=%s pw_len=%d' % ('$k', m.group(1), hashlib.sha256(m.group(2).encode()).hexdigest()[:12], len(m.group(2))))
else:
    # 非 DSN 形态的键（如 SESSION_SECRET）只输出指纹；2026-10-05 本分支曾误打印值前 12 位，禁止改回明文
    print('  %-20s 无 user:pw 形态  value_sha[:12]=%s len=%d' % ('$k', hashlib.sha256(v.encode()).hexdigest()[:12], len(v)))
"
done
echo "DONE-T17-PWHASH"
