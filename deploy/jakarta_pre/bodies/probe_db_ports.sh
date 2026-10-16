#!/bin/bash
# bodies/probe_db_ports.sh —— 从节点侧实测雅加达 RDS 的 5432 / 6432 连通性（只读，不带凭据）
# 为什么要这一步：云侧 PGBouncerEnabled=true + 参数回读 只证明"配置下发了"，
#   不证明"6432 真的在监听、VPC 内打得通"。池是否可用必须以建连结果为准。
set -uo pipefail
H="${DB_HOST:-pgm-d9j9p421lzx4gw73.pgsql.ap-southeast-5.rds.aliyuncs.com}"
echo "=== B0 目标（只允许雅加达 dev 实例域名）"
case "$H" in
  *pgm-d9j9p421lzx4gw73*) printf '  host=%s\n' "$H" ;;
  *) echo "  [XX] 目标域名不是雅加达 dev 实例，拒绝探测：$H"; exit 2 ;;
esac
printf '  节点本地时间：%s\n' "$(date -u +%FT%TZ)"

echo "=== B1 DNS 解析"
getent hosts "$H" 2>/dev/null | sed 's/^/    /' || { command -v python3 >/dev/null && python3 - "$H" <<'PY'
import socket,sys
print("    via python:", socket.gethostbyname_ex(sys.argv[1]))
PY
}

echo "=== B2 端口建连（5432=直连，6432=托管池）"
for p in 5432 6432; do
  if timeout 5 bash -c "exec 3<>/dev/tcp/$H/$p" 2>/dev/null; then
    printf '    %s/tcp OPEN\n' "$p"
  else
    printf '    %s/tcp CLOSED/不可达（rc=%s）\n' "$p" "$?"
  fi
done

echo "=== B3 PG 协议握手（发 SSLRequest，看后端是否按 PG 应答；不登录、不带任何凭据）"
for p in 5432 6432; do
  R=$(timeout 6 python3 - "$H" "$p" <<'PY' 2>&1
import socket,struct,sys
h,p=sys.argv[1],int(sys.argv[2])
try:
    s=socket.create_connection((h,p),timeout=4); s.settimeout(4)
    s.sendall(struct.pack("!ii",8,80877103))     # SSLRequest
    b=s.recv(1)
    print("应答字节=%r（S=支持TLS/N=明文/E=错误/NorR=无该协议）" % b)
    s.close()
except Exception as e:
    print("异常:", type(e).__name__, e)
PY
)
  printf '    %s/tcp %s\n' "$p" "$R"
done
echo "--- B1–B3 结束（全程只读：未建会话、未鉴权、未触碰任何凭据）"
