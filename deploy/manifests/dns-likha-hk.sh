#!/usr/bin/env bash
# =============================================================================
# likha.hk 云解析记录管理（权威 NS：ns7.alidns.com / ns8.alidns.com）
# -----------------------------------------------------------------------------
# 用途：把 www.likha.hk 指向菲律宾马尼拉 ALB 的双 EIP（AZ 6a + 6b）
#   ALB: alb-1riqckb1h8ezm0y7s9 (alb-newapi-mnl, Internet)
#   DNS: alb-1riqckb1h8ezm0y7s9.ap-southeast-6.alb.aliyuncsslbintl.com
#        → A 8.212.161.49 (ap-southeast-6a) / 8.212.183.7 (ap-southeast-6b)
# 备注：两条同 RR 的 A 记录 = DNS 轮询，天然双 AZ；TTL 600（免费版下限）。
#       备选方案 CNAME → ALB 官方 DNS 名（IP 变化自动跟随，但无法做 A 级健康检查分流）。
#
# 用法：bash dns-likha-hk.sh {status|add|del|verify}
# 依赖：aliyun CLI（PATH 自愈）、dig
# =============================================================================
set -uo pipefail

DOMAIN=likha.hk
RR="${RR:-www}"
IPS=(${IPS:-8.212.161.49 8.212.183.7})
TTL="${TTL:-600}"
LINE="${LINE:-default}"

case ":$PATH:" in
  *".workbuddy/binaries/aliyun-cli:"*) ;;
  *) export PATH="$HOME/.workbuddy/binaries/aliyun-cli:$PATH" ;;
esac

say() { printf '%s\n' "$*"; }

_aliyun() { aliyun alidns "$@"; }

list_existing() {
  _aliyun DescribeDomainRecords --DomainName "$DOMAIN" --RRKeyWord "$RR" --PageSize 100 2>/dev/null \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = (d.get('DomainRecords') or {}).get('Record') or []
for r in rows:
    if r.get('RR') == '$RR':
        print('%s\t%s\t%s\t%s' % (r.get('RecordId'), r.get('Type'), r.get('Value'), r.get('Status')))
"
}

cmd="${1:-status}"

# 根域 RR="@" → FQDN 就是裸域名（dig 不接受 "@.likha.hk"）
if [ "$RR" = "@" ]; then FQDN="$DOMAIN"; else FQDN="$RR.$DOMAIN"; fi

case "$cmd" in
  status)
    say "== likha.hk / $RR 现有记录 =="
    out="$(list_existing)"
    if [ -z "$out" ]; then say "  (无)"; else printf '  id=%s type=%s value=%s status=%s\n' $out; fi
    say
    say "== 权威 NS =="
    dig +short NS "$DOMAIN" @223.5.5.5 2>/dev/null | sed 's/^/  /'
    ;;

  add)
    say "== 添加 $RR → ${IPS[*]} (TTL $TTL, Line $LINE) =="
    for ip in "${IPS[@]}"; do
      if list_existing | awk -v v="$ip" '$3==v {found=1} END {exit !found}'; then
        say "  SKIP $ip (已存在)"
        continue
      fi
      resp="$(_aliyun AddDomainRecord --DomainName "$DOMAIN" --RR "$RR" --Type A --Value "$ip" \
              --TTL "$TTL" --Line "$LINE" --method POST 2>&1)"
      say "  ADD  $ip -> $resp"
    done
    say "  --- 回读 ---"
    list_existing | sed 's/^/  /'
    ;;

  del)
    say "== 删除 $RR 的全部 A 记录 =="
    ids="$(list_existing | awk -F'\t' '$2=="A" {print $1}')"
    if [ -z "$ids" ]; then say "  (无可删)"; else
      for id in $ids; do
        _aliyun DeleteDomainRecord --RecordId "$id" --method POST 2>&1 | sed "s/^/  del $id -> /"
      done
    fi
    say "  --- 回读 ---"
    out="$(list_existing)"; if [ -z "$out" ]; then say "  (空)"; else printf '  %s\n' $out; fi
    ;;

  verify)
    say "== 解析验证（${FQDN}）=="
    for ns in ns7.alidns.com ns8.alidns.com 223.5.5.5 8.8.8.8; do
      printf '  %-18s : %s\n' "$ns" "$(dig +short A "$FQDN" @$ns 2>/dev/null | tr '\n' ' ')"
    done
    say
    say "== 端到端 HTTP =="
    for i in 1 2 3 4 5 6; do
      printf '%s ' "$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -m 12 "http://$FQDN/api/status")"
    done
    say
    ;;

  *) say "用法: bash $0 {status|add|del|verify}"; exit 2 ;;
esac
