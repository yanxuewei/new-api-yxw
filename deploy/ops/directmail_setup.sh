#!/usr/bin/env bash
# =============================================================================
# 阿里云邮件推送 DirectMail —— 发信域名 + DNS 记录 + 验证（一键 / 幂等）
# -----------------------------------------------------------------------------
# 目标：让 new-api 能以 noreply@dm.likha.hk 发信（注册验证码 / 通知）
#   发信域名 DOMAIN : dm.likha.hk    （子域名，隔离主域信誉）
#   云解析主域 ZONE : likha.hk       （DomainId 3b4321ce86d3436aa46e3a8ba96a6133）
#   SMTP 服务器     : smtpdm.aliyun.com:465 (SSL/TLS)
#
# 用法：bash directmail_setup.sh {status|plan|apply|verify}
#   status  只读：DirectMail 通道可用性 + 现有发信域名
#   plan    干跑：拉取权威 DNS 值并打印将写入的记录（零写操作）
#   apply   执行：CreateDomain（如需）+ 幂等 AddDomainRecord
#   verify  校验：实时 DNS 解析 + 四个验证状态位
#
# 环境变量：DOMAIN(默认 dm.likha.hk) ZONE(默认 likha.hk) TTL(600) LINE(default)
#           SENDER(noreply)  RR_SUFFIX(默认空，用于修正主机记录后缀)
# 依赖：aliyun CLI（PATH 自愈）、python3、dig
# =============================================================================
set -uo pipefail

DOMAIN="${DOMAIN:-dm.likha.hk}"
ZONE="${ZONE:-likha.hk}"
TTL="${TTL:-600}"
LINE="${LINE:-default}"
SENDER="${SENDER:-noreply}"
RR_SUFFIX="${RR_SUFFIX:-}"

case ":$PATH:" in
  *".workbuddy/binaries/aliyun-cli:"*) ;;
  *) export PATH="$HOME/.workbuddy/binaries/aliyun-cli:$PATH" ;;
esac

say()  { printf '%s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

dm()  { aliyun dm "$@"; }
dns() { aliyun alidns "$@"; }

if [ "$DOMAIN" = "$ZONE" ]; then APEX_RR="@"; else APEX_RR="${DOMAIN%.$ZONE}"; fi

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

cat > "$TMPD/fields.py" <<'PY'
import sys, json
def pick(d, *names):
    for src in (d, d.get('data') or {}):
        if not isinstance(src, dict):
            continue
        for n in names:
            v = src.get(n)
            if v not in (None, ''):
                return str(v)
    return ''
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
print('\t'.join((pick(d, *n) or '-') for n in (
    ('HostRecord', 'hostRecord'),
    ('DnsTxt', 'dnsTxt'),
    ('DnsSpf', 'dnsSpf'),
    ('SpfRecord', 'spfRecord'),
    ('DkimRR', 'dkimRR'),
    ('DkimPublicKey', 'dkimPublicKey'),
    ('DmarcHostRecord', 'dmarcHostRecord'),
    ('DnsDmarc', 'dnsDmarc'),
    ('DmarcRecord', 'dmarcRecord'),
    ('MxRecord', 'mxRecord'),
    ('CnameRecord', 'cnameRecord'),
    ('TracefRecord', 'tracefRecord'),
    ('DomainId', 'domainId'),
    ('DomainStatus', 'domainStatus'),
    ('SpfAuthStatus', 'spfAuthStatus'),
    ('DkimAuthStatus', 'dkimAuthStatus'),
    ('MxAuthStatus', 'mxAuthStatus'),
    ('DmarcAuthStatus', 'dmarcAuthStatus'),
)))
PY

cat > "$TMPD/list.py" <<'PY'
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
rows = ((d.get('data') or {}).get('domain') or [])
for r in rows:
    print('\t'.join(str(r.get(k) or '') for k in
                    ('DomainName', 'DomainId', 'DomainStatus',
                     'SpfAuthStatus', 'MxAuthStatus', 'CnameAuthStatus')))
PY

cat > "$TMPD/dns.py" <<'PY'
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
rows = ((d.get('DomainRecords') or {}).get('Record') or [])
for r in rows:
    print('\t'.join(str(r.get(k) or '') for k in ('RR', 'Type', 'Value')))
PY

# --- 发信域名是否存在；存在则输出 DomainId ---
get_domain_id() {
  dm QueryDomainByParam --KeyWord "$DOMAIN" --PageSize 50 2>/dev/null \
  | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in ((d.get('data') or {}).get('domain') or []):
    if r.get('DomainName') == '$DOMAIN':
        print(r.get('DomainId') or ''); break
"
}

# --- DescDomain → 待写入记录清单（TSV: RR TYPE VALUE PRIORITY DESC）---
build_plan() {
  local id="$1" realtime="$2" f="$TMPD/desc.json"
  dm DescDomain --DomainId "$id" --RequireRealTimeDnsRecords "$realtime" > "$f" 2>"$TMPD/desc.err" \
    || { warn "DescDomain 失败: $(head -3 "$TMPD/desc.err" | tr '\n' ' ')"; return 1; }

  local row host dns_txt dns_spf spf_rec dkim_rr dkim_key dmarc_host dns_dmarc dmarc_rec mx cname trace
  IFS=$'\t' read -r host dns_txt dns_spf spf_rec dkim_rr dkim_key dmarc_host dns_dmarc dmarc_rec mx cname trace \
    _id _st _spf _dkim _mxa _dmarca < <(python3 "$TMPD/fields.py" "$f")

  # '-' 是空字段占位（避免 read 丢列），此处还原为空串
  [ "$host" = '-' ]       && host=''
  [ "$dns_txt" = '-' ]    && dns_txt=''
  [ "$dns_spf" = '-' ]    && dns_spf=''
  [ "$spf_rec" = '-' ]    && spf_rec=''
  [ "$dkim_rr" = '-' ]    && dkim_rr=''
  [ "$dkim_key" = '-' ]   && dkim_key=''
  [ "$dmarc_host" = '-' ] && dmarc_host=''
  [ "$dns_dmarc" = '-' ]  && dns_dmarc=''
  [ "$dmarc_rec" = '-' ]  && dmarc_rec=''
  [ "$mx" = '-' ]         && mx=''
  [ "$cname" = '-' ]      && cname=''
  [ "$trace" = '-' ]      && trace=''

  [ -n "$host" ]      && printf '%s\tTXT\t%s\t\t所有权验证\n' "$host" "$dns_txt"
  [ -n "$dns_spf" ]   && printf '%s\tTXT\t%s\t\tSPF\n' "$APEX_RR" "$dns_spf"
  [ -z "$dns_spf" ] && [ -n "$spf_rec" ] && printf '%s\tTXT\tv=spf1 %s -all\t\tSPF\n' "$APEX_RR" "$spf_rec"
  if [ -n "$dkim_rr" ] && [ -n "$dkim_key" ]; then printf '%s\tTXT\t%s\t\tDKIM\n' "$dkim_rr" "$dkim_key"; fi
  if [ -n "$dmarc_host" ]; then printf '%s\tTXT\t%s\t\tDMARC\n' "$dmarc_host" \
       "${dns_dmarc:-${dmarc_rec:-v=DMARC1; p=quarantine; rua=mailto:dmarc@$ZONE; pct=100}}"; fi
  [ -n "$mx" ]        && printf '%s\tMX\t%s\t5\tMX 回信路由\n' "$APEX_RR" "$mx"
  if [ -n "$cname" ] && [ -n "$trace" ]; then printf '%s\tCNAME\t%s\t\t点击跟踪(可选)\n' "$cname" "$trace"; fi
}

# 主机记录是否需要补后缀（RR_SUFFIX 非空时统一追加）
fix_rr() { if [ -n "$RR_SUFFIX" ]; then printf '%s.%s' "$1" "$RR_SUFFIX"; else printf '%s' "$1"; fi; }

dump_existing() {
  dns DescribeDomainRecords --DomainName "$ZONE" --PageSize 500 2>/dev/null \
  | python3 "$TMPD/dns.py" > "$TMPD/existing.tsv" 2>/dev/null
  [ -s "$TMPD/existing.tsv" ] || : > "$TMPD/existing.tsv"
}

has_record() {
  awk -F'\t' -v rr="$1" -v ty="$2" -v v="$3" \
    '$1==rr && $2==ty && $3==v {f=1} END{exit !f}' "$TMPD/existing.tsv"
}

cmd="${1:-status}"

case "$cmd" in
  status)
    say "== DirectMail 通道 =="
    out="$(dm QueryDomainByParam --PageSize 50 2>&1)"
    if printf '%s' "$out" | grep -q '"TotalCount"'; then
      say "  通道: OK"
      say "  发信域名:"
      printf '%s' "$out" | python3 "$TMPD/list.py" | awk -F'\t' 'NF{printf "    %-28s id=%-10s status=%s spf=%s mx=%s cname=%s\n",$1,$2,$3,$4,$5,$6}'
      printf '%s' "$out" | python3 "$TMPD/list.py" | grep -q . || say "    (无) —— 需执行 apply"
    else
      say "  通道: 异常"
      printf '%s\n' "$out" | head -6 | sed 's/^/    /'
      warn "如为 InvalidUser.NotFound，重试一次或加 --region ap-southeast-1"
    fi
    say
    say "== 目标 =="
    say "  发信域名 : $DOMAIN   (zone: $ZONE, apex RR: $APEX_RR)"
    say "  发信地址 : $SENDER@$DOMAIN"
    say "  SMTP     : smtpdm.aliyun.com:465 (SSL/TLS)"
    ;;

  plan)
    ID="$(get_domain_id)"
    if [ -z "$ID" ]; then
      say "发信域名 '$DOMAIN' 尚未创建 —— 先执行: bash $0 apply"
      exit 0
    fi
    say "== 待写入 DNS 计划（$DOMAIN / zone $ZONE, DomainId=$ID）=="
    build_plan "$ID" false | tee "$TMPD/plan.tsv" | awk -F'\t' \
      '{printf "  [%s] %-38s -> %s   %s\n",$2,$1,substr($3,1,60),$5}'
    say
    say "  ⚠️ 请对照控制台『发信域名 → 配置』页核对主机记录；"
    say "     如主机记录缺少子域后缀，用 RR_SUFFIX=$APEX_RR bash $0 plan 复跑。"
    ;;

  apply)
    ID="$(get_domain_id)"
    if [ -z "$ID" ]; then
      say "== 创建发信域名 $DOMAIN =="
      out="$(dm CreateDomain --DomainName "$DOMAIN" --method POST 2>&1)"
      say "  $out"
      ID="$(get_domain_id)"
      [ -n "$ID" ] || die "域名创建后仍未查询到，请用控制台确认"
      say "  DomainId=$ID（DNS 生效后需等待校验，通常 4 小时内）"
    else
      say "== 发信域名已存在 DomainId=$ID，跳过创建 =="
    fi

    say "== 拉取权威记录值 =="
    build_plan "$ID" false > "$TMPD/plan.tsv" || die "无法获取 DNS 记录值"
    [ -s "$TMPD/plan.tsv" ] || die "未返回任何记录值，可能服务未开通：请在控制台确认『邮件推送』已开通"

    say "== 写入云解析（幂等）=="
    dump_existing
    while IFS=$'\t' read -r rr type value prio desc; do
      [ -z "${rr:-}" ] && continue
      rr="$(fix_rr "$rr")"
      if has_record "$rr" "$type" "$value"; then
        say "  SKIP  [$type] $rr（已存在且值一致）"
        continue
      fi
      if [ "$type" = "MX" ]; then
        resp="$(dns AddDomainRecord --DomainName "$ZONE" --RR "$rr" --Type "$type" \
                --Value "$value" --Priority "${prio:-5}" --TTL "$TTL" --Line "$LINE" --method POST 2>&1)"
      else
        resp="$(dns AddDomainRecord --DomainName "$ZONE" --RR "$rr" --Type "$type" \
                --Value "$value" --TTL "$TTL" --Line "$LINE" --method POST 2>&1)"
      fi
      if printf '%s' "$resp" | grep -q 'RecordId'; then
        say "  ADD   [$type] $rr"
      else
        warn "ADD 失败 [$type] $rr : $(printf '%s' "$resp" | head -2 | tr '\n' ' ')"
      fi
    done < "$TMPD/plan.tsv"

    say
    say "== 回读 =="
    dump_existing
    awk -F'\t' -v rr="$APEX_RR" '$1==rr || $1 ~ /_domainkey/ || $1 ~ /_dmarc/ || $1 ~ /aliyundm/ \
      {printf "  [%s] %-38s -> %s\n",$2,$1,substr($3,1,60)}' "$TMPD/existing.tsv"
    say
    say "下一步: bash $0 verify"
    ;;

  verify)
    ID="$(get_domain_id)"
    [ -n "$ID" ] || die "发信域名 $DOMAIN 不存在，先执行 apply"
    say "== 主动触发校验 =="
    dm CheckDomain --DomainId "$ID" --method POST >/dev/null 2>&1 || warn "CheckDomain 返回非 0（可忽略）"
    dm DescDomain --DomainId "$ID" --RequireRealTimeDnsRecords true > "$TMPD/desc.json" 2>"$TMPD/desc.err" || true
    IFS=$'\t' read -r _h _t _ds _sp _dr _dk _dh _dd _dm2 _mx _cn _tf _id _st _spf _dkim _mxa _dmarca \
      < <(python3 "$TMPD/fields.py" "$TMPD/desc.json")
    [ "$_st" = '-' ]     && _st=''
    [ "$_spf" = '-' ]    && _spf=''
    [ "$_dkim" = '-' ]   && _dkim=''
    [ "$_mxa" = '-' ]    && _mxa=''
    [ "$_dmarca" = '-' ] && _dmarca=''
    show() { if [ "$2" = "0" ]; then printf '  %-8s %s\n' "$1" "✅ 通过"; else printf '  %-8s %s (0=通过/1=未通过)\n' "$1" "$2"; fi; }
    show DomainStatus  "$_st"
    show SPF          "$_spf"
    show DKIM         "$_dkim"
    show MX           "$_mxa"
    show DMARC        "$_dmarca"
    say
    say "== 实际 DNS 解析 =="
    for q in "TXT $DOMAIN" "TXT _dmarc.$DOMAIN" "MX $DOMAIN"; do
      set -- $q
      printf '  %-6s %-30s : %s\n' "$1" "$2" "$(dig +short "$1" "$2" @8.8.8.8 2>/dev/null | tr '\n' ' ' | cut -c1-90)"
    done
    say
    say "  ⚠️ 新域名需 SPF/DKIM/DMARC/MX 四项全部通过才算验证通过；"
    say "     未通过时等待 DNS 生效（≤4h）后重跑本命令。"
    ;;

  *) say "用法: bash $0 {status|plan|apply|verify}"; exit 2 ;;
esac
