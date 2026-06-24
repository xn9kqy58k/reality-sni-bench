#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.0"
ROUNDS=3
TIMEOUT=8
CONNECT_TIMEOUT=4
INPUT_FILE="candidates.txt"
OUT_CSV="reality-sni-report.csv"
OUT_SNIPPET="reality-best-snippet.json"
TOP_N=10
STRICT_TLS13=0

usage() {
  cat <<'EOF'
Reality SNI Bench

Usage:
  ./reality-sni-bench.sh -f candidates.txt [options]

Options:
  -f FILE    Candidate domain list. One domain per line. # comments allowed.
  -r NUM     Test rounds per domain. Default: 3
  -t SEC     Total timeout for each curl/openssl probe. Default: 8
  -c SEC     Curl connect timeout. Default: 4
  -o FILE    Output CSV path. Default: reality-sni-report.csv
  -s FILE    Output best Reality snippet path. Default: reality-best-snippet.json
  -n NUM     Print top N results. Default: 10
  --strict   Keep only domains that pass TLS 1.3 + certificate verification.
  -h         Show help.

Examples:
  ./reality-sni-bench.sh -f candidates.txt -r 5 -o report.csv
  ./reality-sni-bench.sh -f candidates.txt --strict
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

csv_escape() {
  local s=${1:-}
  s=${s//\"/\"\"}
  printf '"%s"' "$s"
}

trim_domain() {
  local raw=$1
  raw=${raw%%#*}
  raw=$(printf '%s' "$raw" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')
  raw=${raw#https://}
  raw=${raw#http://}
  raw=${raw%%/*}
  raw=${raw%%:*}
  printf '%s' "$raw" | tr '[:upper:]' '[:lower:]'
}

is_domain() {
  local domain=$1
  [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

resolve_ips() {
  local domain=$1
  local ips=""

  if command -v dig >/dev/null 2>&1; then
    ips=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9.]+$' | sort -u | paste -sd '|' -)
  fi

  if [[ -z "$ips" ]] && command -v getent >/dev/null 2>&1; then
    ips=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd '|' -)
  fi

  printf '%s' "$ips"
}

openssl_probe() {
  local domain=$1
  local output rc protocol alpn verify verify_ok tls13 h2 http11

  set +e
  output=$(
    timeout "$TIMEOUT" openssl s_client \
      -connect "${domain}:443" \
      -servername "$domain" \
      -verify_hostname "$domain" \
      -tls1_3 \
      -alpn "h2,http/1.1" \
      </dev/null 2>&1
  )
  rc=$?
  set -e

  protocol="no"
  alpn="none"
  verify="no"
  tls13=0
  h2=0
  http11=0
  verify_ok=0

  if [[ $rc -eq 0 ]] && grep -qiE 'TLSv1\.3|Protocol *: *TLSv1\.3|New, TLSv1\.3' <<<"$output"; then
    protocol="TLSv1.3"
    tls13=1
  fi

  if grep -qiE 'ALPN protocol: h2|Protocol *: *h2' <<<"$output"; then
    alpn="h2"
    h2=1
  elif grep -qiE 'ALPN protocol: http/1\.1|Protocol *: *http/1\.1' <<<"$output"; then
    alpn="http/1.1"
    http11=1
  fi

  if grep -qiE 'Verify return code: 0 \(ok\)|Verification: OK' <<<"$output"; then
    verify="ok"
    verify_ok=1
  fi

  printf '%s,%s,%s,%s,%s,%s' "$tls13" "$verify_ok" "$h2" "$http11" "$protocol" "$alpn"
}

curl_once() {
  local domain=$1
  local tmp
  tmp=$(mktemp)

  set +e
  curl \
    --silent --show-error --location \
    --output /dev/null \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$TIMEOUT" \
    --tlsv1.3 \
    --write-out '%{http_code},%{time_appconnect},%{time_total},%{remote_ip},%{ssl_verify_result}' \
    "https://${domain}/" >"$tmp" 2>/dev/null
  local rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    rm -f "$tmp"
    printf '0,0,0,,999'
    return 0
  fi

  cat "$tmp"
  rm -f "$tmp"
}

score_domain() {
  local success=$1
  local rounds=$2
  local avg_ms=$3
  local tls13=$4
  local verify_ok=$5
  local h2=$6
  local http11=$7
  local http_good=$8
  local ip_count=$9

  awk -v success="$success" -v rounds="$rounds" -v avg="$avg_ms" \
      -v tls13="$tls13" -v verify="$verify_ok" -v h2="$h2" -v http11="$http11" \
      -v httpgood="$http_good" -v ipcount="$ip_count" '
    BEGIN {
      score = 0
      if (rounds > 0) score += (success / rounds) * 25
      if (tls13 == 1) score += 22
      if (verify == 1) score += 22
      if (h2 == 1) score += 10
      else if (http11 == 1) score += 4
      if (httpgood == 1) score += 8
      if (ipcount >= 1 && ipcount <= 8) score += 5
      else if (ipcount > 8 && ipcount <= 32) score += 2

      if (avg > 0 && avg <= 150) score += 8
      else if (avg > 0 && avg <= 300) score += 6
      else if (avg > 0 && avg <= 600) score += 4
      else if (avg > 0 && avg <= 1000) score += 2

      if (score > 100) score = 100
      printf "%.1f", score
    }'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f) INPUT_FILE=${2:?}; shift 2 ;;
    -r) ROUNDS=${2:?}; shift 2 ;;
    -t) TIMEOUT=${2:?}; shift 2 ;;
    -c) CONNECT_TIMEOUT=${2:?}; shift 2 ;;
    -o) OUT_CSV=${2:?}; shift 2 ;;
    -s) OUT_SNIPPET=${2:?}; shift 2 ;;
    -n) TOP_N=${2:?}; shift 2 ;;
    --strict) STRICT_TLS13=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "$VERSION"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

need_cmd curl
need_cmd openssl
need_cmd awk
need_cmd sed
need_cmd sort
need_cmd timeout

if [[ ! -f "$INPUT_FILE" ]]; then
  echo "Candidate file not found: $INPUT_FILE" >&2
  exit 1
fi

TMP_CSV=$(mktemp)
trap 'rm -f "$TMP_CSV"' EXIT

printf 'rank,domain,score,avg_appconnect_ms,success_rounds,total_rounds,tls13,cert_verify,alpn,http_code,last_remote_ip,dns_ips\n' >"$TMP_CSV"

mapfile -t DOMAINS < <(while IFS= read -r line || [[ -n "$line" ]]; do
  d=$(trim_domain "$line")
  if [[ -n "$d" ]]; then
    if is_domain "$d"; then
      printf '%s\n' "$d"
    else
      log "Skip invalid domain: $d"
    fi
  fi
done <"$INPUT_FILE" | sort -u)

if [[ ${#DOMAINS[@]} -eq 0 ]]; then
  echo "No candidate domains found in $INPUT_FILE" >&2
  exit 1
fi

log "Testing ${#DOMAINS[@]} candidate domains, rounds=${ROUNDS}, timeout=${TIMEOUT}s"

for domain in "${DOMAINS[@]}"; do
  log "Probe $domain"

  ips=$(resolve_ips "$domain")
  ip_count=0
  [[ -n "$ips" ]] && ip_count=$(awk -F'|' '{print NF}' <<<"$ips")

  IFS=',' read -r tls13 verify_ok h2 http11 protocol alpn < <(openssl_probe "$domain")

  success=0
  http_good=0
  total_appconnect=0
  last_code=0
  last_ip=""

  for ((i=1; i<=ROUNDS; i++)); do
    IFS=',' read -r code appconnect total remote_ip ssl_verify < <(curl_once "$domain")
    last_code=$code
    last_ip=$remote_ip

    if [[ "$code" =~ ^[0-9]+$ ]] && [[ "$code" -gt 0 ]] && [[ "$ssl_verify" == "0" ]]; then
      success=$((success + 1))
      app_ms=$(awk -v t="$appconnect" 'BEGIN { printf "%.0f", t * 1000 }')
      total_appconnect=$(awk -v a="$total_appconnect" -v b="$app_ms" 'BEGIN { printf "%.0f", a + b }')
      if [[ "$code" =~ ^(200|204|301|302|307|308|401|403|404)$ ]]; then
        http_good=1
      fi
    fi
  done

  avg_ms=0
  if [[ $success -gt 0 ]]; then
    avg_ms=$(awk -v total="$total_appconnect" -v success="$success" 'BEGIN { printf "%.0f", total / success }')
  fi

  if [[ $STRICT_TLS13 -eq 1 && ( $tls13 -ne 1 || $verify_ok -ne 1 ) ]]; then
    score="0.0"
  else
    score=$(score_domain "$success" "$ROUNDS" "$avg_ms" "$tls13" "$verify_ok" "$h2" "$http11" "$http_good" "$ip_count")
  fi

  {
    printf '0,'
    csv_escape "$domain"; printf ','
    printf '%s,%s,%s,%s,%s,%s,' "$score" "$avg_ms" "$success" "$ROUNDS" "$tls13" "$verify_ok"
    csv_escape "$alpn"; printf ','
    printf '%s,' "$last_code"
    csv_escape "$last_ip"; printf ','
    csv_escape "$ips"; printf '\n'
  } >>"$TMP_CSV"
done

{
  head -n 1 "$TMP_CSV"
  tail -n +2 "$TMP_CSV" | sort -t',' -k3,3nr -k4,4n | awk -F',' 'BEGIN { OFS="," } { $1=NR; print }'
} >"$OUT_CSV"

best_domain=$(awk -F',' 'NR==2 { gsub(/^"|"$/, "", $2); gsub(/""/, "\"", $2); print $2 }' "$OUT_CSV")

if [[ -n "$best_domain" ]]; then
  cat >"$OUT_SNIPPET" <<EOF
{
  "serverInboundRealitySettings": {
    "dest": "${best_domain}:443",
    "xver": 0,
    "serverNames": ["${best_domain}"],
    "privateKey": "REPLACE_WITH_YOUR_XRAY_PRIVATE_KEY",
    "shortIds": ["REPLACE_WITH_YOUR_SHORT_ID"]
  },
  "clientOutboundRealitySettings": {
    "serverName": "${best_domain}",
    "fingerprint": "chrome",
    "publicKey": "REPLACE_WITH_YOUR_XRAY_PUBLIC_KEY",
    "shortId": "REPLACE_WITH_YOUR_SHORT_ID",
    "spiderX": "/"
  }
}
EOF
fi

log "Done. CSV: $OUT_CSV"
if [[ -n "${best_domain:-}" ]]; then
  log "Best candidate: $best_domain"
  log "Snippet: $OUT_SNIPPET"
fi

echo
echo "Top ${TOP_N}:"
awk -F',' 'NR==1 { next } NR<=n+1 {
  printf "%2s  %-36s score=%5s avg_tls=%sms success=%s/%s alpn=%s code=%s\n", $1, $2, $3, $4, $5, $6, $9, $10
}' n="$TOP_N" "$OUT_CSV"
