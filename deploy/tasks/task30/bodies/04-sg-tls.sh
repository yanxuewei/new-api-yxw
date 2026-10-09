#!/bin/bash
# 任务 30 · 步骤 3b：新加坡 → 马尼拉 RDS 公网链路「TLS」段（节点级零凭据）
set -uo pipefail

H=pgm-5tstdhko64x2c01wpub.pgsql.ap-southeast-6.rds.aliyuncs.com
P=6432

echo "== 工具 =="
command -v openssl >/dev/null 2>&1 && echo "  have openssl" || echo "  MISSING openssl"

echo "== 1) TLS 握手 10 次（timeout 6s/次）=="
ok=0; fail=0; i=0
while [ "$i" -lt 10 ]; do
  if echo Q | timeout 6 openssl s_client -connect "$H:$P" -servername "$H" -brief >/dev/null 2>&1; then
    ok=$((ok+1))
  else
    fail=$((fail+1))
  fi
  i=$((i+1))
done
echo "  handshake ok=$ok fail=$fail"

echo "== 2) 一次完整握手（协议/套件/主体/签发者/链长）=="
echo Q | timeout 10 openssl s_client -connect "$H:$P" -servername "$H" -showcerts 2>/dev/null > /tmp/tls_full.txt
grep -E "^ *Protocol *:|^ *Cipher *:|^ *Verify return code" /tmp/tls_full.txt | head -4 | sed 's/^/  /'
awk '/^subject=/{print "  subject  "$0} /^issuer=/{print "  issuer   "$0}' /tmp/tls_full.txt | head -4
echo "  chain cert count = $(grep -c 'BEGIN CERTIFICATE' /tmp/tls_full.txt)"

echo "== 3) 主机名校验（叶子证书，只含公钥）=="
awk '/BEGIN CERT/,/END CERT/' /tmp/tls_full.txt > /tmp/leaf.pem
grep -c 'BEGIN CERTIFICATE' /tmp/leaf.pem | sed 's/^/  导出块数 = /'
openssl x509 -in /tmp/leaf.pem -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null | sed 's/^/  /'
if openssl x509 -in /tmp/leaf.pem -noout -checkhost "$H" >/dev/null 2>&1; then
  echo "  checkhost($H) = MATCH"
else
  echo "  checkhost($H) = NO MATCH"
fi

echo "== 4) TLS 版本下限（应拒 tls1/tls1_1，收 tls1_2）=="
for v in tls1 tls1_1 tls1_2; do
  if echo Q | timeout 6 openssl s_client -connect "$H:$P" -$v >/dev/null 2>&1; then echo "  $v = ACCEPTED"; else echo "  $v = REJECTED"; fi
done

echo "== 5) 5432 对照 =="
if echo Q | timeout 6 openssl s_client -connect "$H:5432" -servername "$H" -brief >/dev/null 2>&1; then echo "  5432 TLS = OK"; else echo "  5432 TLS = FAIL"; fi
echo DONE-3B
