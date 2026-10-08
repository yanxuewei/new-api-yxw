#!/bin/bash
# 任务 30 · 步骤 2：新加坡侧 → 马尼拉 RDS 公网链路网络/TLS 实测（节点级，零凭据）
# 判据：TCP RTT ≤45ms、TLS 握手成功率 100%、建连耗时；ICMP 通不通都要记录。
set -uo pipefail

H=pgm-5tstdhko64x2c01wpub.pgsql.ap-southeast-6.rds.aliyuncs.com
P=6432

echo "== 工具可用性 =="
for t in openssl getent ping tracepath; do
  command -v "$t" >/dev/null 2>&1 && echo "  have $t" || echo "  MISSING $t"
done

echo "== DNS =="
getent hosts "$H" | head -2

echo "== 1) TCP 建连耗时 50 次（bash /dev/tcp，含 SYN/ACK 一个 RTT）=="
: >/tmp/tcp_ms.txt
i=0
while [ "$i" -lt 50 ]; do
  t0=$(date +%s%N)
  (exec 3<>/dev/tcp/"$H"/"$P") 2>/dev/null && { exec 3<&-; exec 3>&-; ok=1; } || ok=0
  t1=$(date +%s%N)
  [ "$ok" = 1 ] && echo $(( (t1 - t0) / 1000000 )) >>/tmp/tcp_ms.txt
  i=$((i+1))
done
n=$(wc -l </tmp/tcp_ms.txt)
echo "  成功 $n/50"
sort -n /tmp/tcp_ms.txt | awk '{a[NR]=$1} END{if(NR==0){print "  无成功样本";exit} printf "  min=%s p50=%s p95=%s max=%s (ms)\n", a[1], a[int(NR*0.5)], a[int(NR*0.95)], a[NR]}'

echo "== 2) TLS 握手 20 次（TLS1.2+ 成功率）=="
ok=0; fail=0
i=0
while [ "$i" -lt 20 ]; do
  if echo Q | timeout 15 openssl s_client -connect "$H:$P" -servername "$H" -brief >/dev/null 2>&1; then
    ok=$((ok+1))
  else
    fail=$((fail+1))
  fi
  i=$((i+1))
done
echo "  handshake ok=$ok fail=$fail"

echo "== 3) 一次完整握手细节（协议/密码套件/签发者）=="
echo Q | timeout 15 openssl s_client -connect "$H:$P" -servername "$H" 2>/dev/null \
  | sed -n '/^Protocol[ ]*:/p;/^\s*Cipher[ ]*:/p;/^\s*Protocol :/p' | head -4
echo Q | timeout 15 openssl s_client -connect "$H:$P" -servername "$H" -showcerts 2>/dev/null \
  | awk '/^subject=/{print "  subject  ",$0} /^issuer=/{print "  issuer   ",$0}' | head -4
echo Q | timeout 15 openssl s_client -connect "$H:$P" -servername "$H" 2>/dev/null \
  | sed -n '/Certificate chain/,/---/p' | grep -c 'BEGIN CERTIFICATE' | sed 's/^/  chain cert count = /'

echo "== 4) 证书链导出 + 主机名校验（只出公钥，不含私钥）=="
echo Q | timeout 15 openssl s_client -connect "$H:$P" -servername "$H" -showcerts 2>/dev/null \
  | awk '/BEGIN CERT/,/END CERT/' >/tmp/rds_chain.pem
cp /tmp/rds_chain.pem /tmp/rds_leaf.pem
openssl x509 -in /tmp/rds_leaf.pem -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null | sed 's/^/  /'
openssl x509 -in /tmp/rds_leaf.pem -noout -checkhost "$H" >/dev/null 2>&1 \
  && echo "  checkhost($H) = MATCH（有效证据）" || echo "  checkhost($H) = NO MATCH"
openssl verify -CAfile /tmp/rds_chain.pem /tmp/rds_leaf.pem 2>&1 | sed 's/^/  verify -CAfile(chain): /'

echo "== 5) TLS 版本下限复验（任务 15 的 TLSv1.2 下限应拒 TLS1.0/1.1）=="
for v in tls1 tls1_1 tls1_2; do
  if echo Q | timeout 15 openssl s_client -connect "$H:$P" -$v >/dev/null 2>&1; then
    echo "  $v = ACCEPTED"
  else
    echo "  $v = REJECTED"
  fi
done

echo "== 6) ICMP / tracepath（可能被 NAT 过滤，通不通都记录）=="
if command -v ping >/dev/null 2>&1; then
  ping -c 10 -W 2 "$H" 2>&1 | tail -3 | sed 's/^/  /'
else
  echo "  无 ping"
fi
command -v tracepath >/dev/null 2>&1 && timeout 40 tracepath -n "$H" 2>&1 | tail -8 | sed 's/^/  /' || echo "  无 tracepath"

echo "== 7) 5432 对照（同一证书/同一实例的另一端口）=="
echo Q | timeout 15 openssl s_client -connect "$H:5432" -servername "$H" -brief >/dev/null 2>&1 \
  && echo "  5432 TLS = OK" || echo "  5432 TLS = FAIL"
(exec 3<>/dev/tcp/"$H"/5432) 2>/dev/null && { echo "  5432 TCP = OPEN"; exec 3<&-; } || echo "  5432 TCP = CLOSED"
echo DONE
