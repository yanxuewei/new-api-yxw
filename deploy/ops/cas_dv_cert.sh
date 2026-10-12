#!/usr/bin/env bash
# ============================================================================
# CAS（SSL 证书管理 V2.0）DV 证书全流程 —— 申请 / DCV / 签发 / 链校验
# 落地背景：2026-10-12 G5「Plan C」用本流程把 *.likha.hk 从 pending 推到 issued。
# 用法：
#   bash deploy/ops/cas_dv_cert.sh status
#   bash deploy/ops/cas_dv_cert.sh issue   <InstanceId> <Domain> <ContactId> [VerifyMethod]
#   bash deploy/ops/cas_dv_cert.sh dcv     <InstanceId>
#   bash deploy/ops/cas_dv_cert.sh publish <InstanceId> [Zone] [TTL]
#   bash deploy/ops/cas_dv_cert.sh wait    <InstanceId> [MaxTries]
#   bash deploy/ops/cas_dv_cert.sh verify  <CertId>
#   bash deploy/ops/cas_dv_cert.sh all     <InstanceId> <Domain> <ContactId> <Zone>
# 环境变量：REG（默认 ap-southeast-1）、TTL（默认 600）
# ============================================================================
set -u
REG=${REG:-ap-southeast-1}
TTL=${TTL:-600}
ZONE_DEFAULT=${ZONE_DEFAULT:-likha.hk}

# PATH 自愈（与项目其它脚本同口径）
case ":${PATH}:" in
  *".workbuddy/binaries/aliyun-cli:"*) ;;
  *) export PATH="${HOME}/.workbuddy/binaries/aliyun-cli:${PATH}" ;;
esac

die() { echo "ERR: $*" >&2; exit 1; }

cmd_status() {
  echo "=== instances (${REG}) ==="
  aliyun cas ListInstances --region "${REG}" \
    --cli-query 'InstanceList[].[InstanceId,Spec,CertificateType,Status,CertificateStatus,CertificateId,CertIdentifier,Domain]'
  echo
  echo "=== summary ==="
  aliyun cas GetInstanceSummary --region "${REG}"
}

cmd_issue() {
  local IID=${1:?instanceId required}
  local DOMAIN=${2:?domain required}
  local CONTACT=${3:?contactId required}
  local VM=${4:-DNS}
  echo "=== UpdateInstance: bind ${DOMAIN} (${VM}) ==="
  aliyun cas UpdateInstance --region "${REG}" \
    --InstanceId "${IID}" \
    --Domain "${DOMAIN}" \
    --ValidationMethod "${VM}" \
    --GenerateCsrMethod online \
    --KeyAlgorithm RSA_2048 \
    --ContactIdList.1 "${CONTACT}" \
    --CountryCode HK --Province "Hong Kong" --City "Hong Kong" || die "UpdateInstance failed"
  echo "=== ApplyCertificate ==="
  aliyun cas ApplyCertificate --region "${REG}" --InstanceId "${IID}" || die "ApplyCertificate failed"
  echo "OK: application submitted"
}

# V2 的 DCV 通道：GetInstanceDetail 响应中的 DomainValidationList
# （该字段在 CLI 文本帮助里不出现，属实测发现）
cmd_dcv() {
  local IID=${1:?instanceId required}
  aliyun cas GetInstanceDetail --region "${REG}" --InstanceId "${IID}" \
    --cli-query 'DomainValidationList'
}

cmd_publish() {
  local IID=${1:?instanceId required}
  local ZONE=${2:-${ZONE_DEFAULT}}
  local RR VAL TYPE
  read -r RR TYPE VAL < <(
    aliyun cas GetInstanceDetail --region "${REG}" --InstanceId "${IID}" \
      --cli-query 'DomainValidationList[0].[ValidationKey,ValidationType,ValidationValue]' \
      | python3 -c "import sys,json;d=json.load(sys.stdin);print(*[str(x) for x in d])"
  )
  [ -n "${RR}" ] || die "no DomainValidationList yet (run 'dcv' first / wait a bit)"

  echo "DCV => RR=${RR} TYPE=${TYPE} VALUE=${VAL}"
  local EXIST
  EXIST=$(aliyun alidns DescribeDomainRecords --region "${REG}" --DomainName "${ZONE}" \
    --RRKeyWord "${RR}" --Type "${TYPE}" --PageSize 50 \
    --cli-query "length(DomainRecords.Record[?Value=='${VAL}'])" 2>/dev/null || echo 0)
  if [ "${EXIST:-0}" != "0" ]; then
    echo "SKIP: record already present (idempotent)"
    return 0
  fi
  echo "=== AddDomainRecord ${RR} ${TYPE} @${ZONE} ==="
  aliyun alidns AddDomainRecord --region "${REG}" \
    --DomainName "${ZONE}" --RR "${RR}" --Type "${TYPE}" --Value "${VAL}" --TTL "${TTL}" \
    || die "AddDomainRecord failed"
  echo "OK: TXT published"
}

cmd_wait() {
  local IID=${1:?instanceId required}
  local MAX=${2:-30}
  local i Q
  for i in $(seq 1 "${MAX}"); do
    Q=$(aliyun cas GetInstanceDetail --region "${REG}" --InstanceId "${IID}" \
      --cli-query '{Status:Status,CertificateStatus:CertificateStatus,CertIdentifier:CertIdentifier,CertificateId:CertificateId}' \
      2>/dev/null | tr -d '\n\t ')
    echo "[$(date '+%H:%M:%S')] ${i}/${MAX} ${Q}"
    case "${Q}" in
      *'"CertificateStatus":"issued"'*) echo ">>> ISSUED"; return 0 ;;
    esac
    sleep 20
  done
  echo ">>> TIMEOUT (still not issued)"; return 1
}

cmd_verify() {
  local CID=${1:?certId required}
  local TMP
  TMP=$(mktemp -d)
  aliyun cas GetUserCertificateDetail --region "${REG}" --CertId "${CID}" --cli-query 'Cert' 2>/dev/null \
    | python3 -c "import sys,json;print(json.load(sys.stdin))" > "${TMP}/leaf.pem" \
    || die "cannot fetch leaf certificate"
  echo "=== subject / issuer / dates ==="
  openssl x509 -in "${TMP}/leaf.pem" -noout -subject -issuer -dates
  echo "=== SAN ==="
  openssl x509 -in "${TMP}/leaf.pem" -noout -ext subjectAltName
  local URL
  URL=$(openssl x509 -in "${TMP}/leaf.pem" -noout -text | grep -F 'CA Issuers' | grep -oE 'https?://[^ ]+' | head -1)
  echo "=== chain ==="
  echo "AIA(caIssuers): ${URL}"
  if [ -n "${URL}" ]; then
    curl -s --max-time 20 "${URL}" -o "${TMP}/inter.raw" || true
    if openssl x509 -inform DER -in "${TMP}/inter.raw" -out "${TMP}/inter.pem" 2>/dev/null; then :; else cp "${TMP}/inter.raw" "${TMP}/inter.pem" 2>/dev/null || true; fi
    openssl x509 -in "${TMP}/inter.pem" -noout -subject -issuer 2>/dev/null || true
    echo "--- openssl verify (vs system trust store) ---"
    openssl verify -untrusted "${TMP}/inter.pem" "${TMP}/leaf.pem" || true
  fi
  echo "=== expiry budget ==="
  local NB NA DAYS
  NB=$(openssl x509 -in "${TMP}/leaf.pem" -noout -startdate | cut -d= -f2)
  NA=$(openssl x509 -in "${TMP}/leaf.pem" -noout -enddate | cut -d= -f2)
  DAYS=$(( ( $(date -d "${NA}" +%s) - $(date -d "${NB}" +%s) ) / 86400 ))
  echo "notBefore=${NB}  notAfter=${NA}  =>  ${DAYS} days"
  echo "NOTE: CA/B 新规下单张证书有效期上限约 199 天，订阅期 1 年 ≠ 证书有效期 1 年，须提前续签。"
  rm -rf "${TMP}"
}

cmd_all() {
  local IID=${1:?instanceId required}
  local DOMAIN=${2:?domain required}
  local CONTACT=${3:?contactId required}
  local ZONE=${4:-${ZONE_DEFAULT}}
  cmd_issue "${IID}" "${DOMAIN}" "${CONTACT}" DNS
  echo "--- waiting for DomainValidationList ---"
  local i
  for i in $(seq 1 10); do
    if [ "$(cmd_dcv "${IID}")" != "null" ]; then break; fi
    sleep 15
  done
  cmd_publish "${IID}" "${ZONE}"
  cmd_wait "${IID}" 30
  cmd_status
}

case "${1:-}" in
  status)  cmd_status ;;
  issue)   shift; cmd_issue "$@" ;;
  dcv)     shift; cmd_dcv "$@" ;;
  publish) shift; cmd_publish "$@" ;;
  wait)    shift; cmd_wait "$@" ;;
  verify)  shift; cmd_verify "$@" ;;
  all)     shift; cmd_all "$@" ;;
  *) sed -n '2,16p' "$0"; exit 1 ;;
esac
