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
MODE="both"
GEO_AWARE=1
CN_SAFE=1
GEO_CACHE_FILE="${GEO_CACHE_FILE:-.reality-sni-geo-cache.tsv}"
GEO_API_TIMEOUT="${GEO_API_TIMEOUT:-4}"

declare -A SOURCE_IPS=()
declare -A SOURCE_COUNTRIES=()
declare -A SOURCE_REGIONS=()
declare -A SOURCE_CITIES=()
declare -A SOURCE_ASNS=()
declare -A SOURCE_ORGS=()

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
  -m MODE    Address family: both, ipv4, or ipv6. Default: both
  --strict   Keep only domains that pass TLS 1.3 + certificate verification.
  --no-geo   Disable source/edge IP region and ASN scoring bonus.
  --include-risky
             Include domains that are commonly blocked or unstable in mainland China.
  -h         Show help.

Examples:
  ./reality-sni-bench.sh -f candidates.txt -r 5 -o report.csv
  ./reality-sni-bench.sh -f candidates.txt --strict
  ./reality-sni-bench.sh -f candidates.txt -m ipv6
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2
}

need_cmd() {
  has_cmd "$1" || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

csv_escape() {
  local s=${1:-}
  s=${s//\"/\"\"}
  printf '"%s"' "$s"
}

candidate_note() {
  local raw=$1
  local note=""
  if [[ "$raw" == *"#"* ]]; then
    note=${raw#*#}
    note=$(printf '%s' "$note" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')
  fi
  printf '%s' "$note"
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

is_cn_risky_domain() {
  local domain=$1
  case "$domain" in
    aadcdn.msauth.net|aadcdn.msftauth.net|acctcdn.msauth.net|\
    *google*|*.gstatic.com|*.googleapis.com|*.googleusercontent.com|*.gvt1.com|gcr.io|\
    *facebook*|*.fbcdn.net|connect.facebook.net|\
    *.twitter.com|*.twimg.com|*.x.com|\
    *.discordapp.com|*.discord.com|\
    download.docker.com|registry-1.docker.io|auth.docker.io|production.cloudflare.docker.com|\
    github.githubassets.com|objects.githubusercontent.com|raw.githubusercontent.com|codeload.github.com|avatars.githubusercontent.com|\
    registry.npmjs.org|unpkg.com|nodejs.org|static.rust-lang.org|static.crates.io|crates.io|pypi.org|files.pythonhosted.org|\
    a.slack-edge.com|emoji.slack-edge.com|cdn.segment.com|js.stripe.com|m.stripe.network)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_ips() {
  local domain=$1
  local family=$2
  local ips=""

  if [[ "$family" == "ipv4" ]] && command -v dig >/dev/null 2>&1; then
    ips=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9.]+$' | sort -u | paste -sd '|' - || true)
  elif [[ "$family" == "ipv6" ]] && command -v dig >/dev/null 2>&1; then
    ips=$(dig +short AAAA "$domain" 2>/dev/null | grep -E '^[0-9a-fA-F:]+$' | sort -u | paste -sd '|' - || true)
  fi

  if [[ -z "$ips" ]] && command -v getent >/dev/null 2>&1; then
    if [[ "$family" == "ipv4" ]]; then
      ips=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd '|' - || true)
    else
      ips=$(getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd '|' - || true)
    fi
  fi

  printf '%s' "$ips"
}

openssl_probe() {
  local domain=$1
  local family=$2
  local output rc protocol alpn verify verify_ok tls13 h2 http11
  local ip_flag=()

  if [[ "$family" == "ipv4" ]]; then
    ip_flag=(-4)
  elif [[ "$family" == "ipv6" ]]; then
    ip_flag=(-6)
  fi

  set +e
  output=$(
    timeout "$TIMEOUT" openssl s_client \
      "${ip_flag[@]}" \
      -connect "${domain}:443" \
      -servername "$domain" \
      -verify_hostname "$domain" \
      -tls1_3 \
      -alpn "h2,http/1.1" \
      </dev/null 2>&1 | tr -d '\000'
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

  printf '%s,%s,%s,%s,%s,%s\n' "$tls13" "$verify_ok" "$h2" "$http11" "$protocol" "$alpn"
}

curl_once() {
  local domain=$1
  local family=$2
  local tmp
  local ip_flag=()
  tmp=$(mktemp)

  if [[ "$family" == "ipv4" ]]; then
    ip_flag=(--ipv4)
  elif [[ "$family" == "ipv6" ]]; then
    ip_flag=(--ipv6)
  fi

  set +e
  curl \
    --silent --show-error --location \
    "${ip_flag[@]}" \
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
    printf '0,0,0,,999\n'
    return 0
  fi

  cat "$tmp"
  printf '\n'
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

apply_geo_bonus() {
  local base_score=$1
  local geo_bonus=$2

  awk -v base="$base_score" -v geo="$geo_bonus" '
    BEGIN {
      score = base + geo
      if (score > 100) score = 100
      printf "%.1f", score
    }'
}

public_ip_for_family() {
  local family=$1
  local ip_flag=()
  local endpoint="https://api.ipify.org"

  if [[ "$family" == "ipv4" ]]; then
    ip_flag=(--ipv4)
  else
    ip_flag=(--ipv6)
    endpoint="https://api64.ipify.org"
  fi

  curl --silent --show-error --fail "${ip_flag[@]}" --max-time "$GEO_API_TIMEOUT" "$endpoint" 2>/dev/null || true
}

lookup_ip_geo() {
  local ip=$1
  local cached result

  if [[ $GEO_AWARE -ne 1 || -z "$ip" || ! "$ip" =~ ^[0-9a-fA-F:.]+$ ]]; then
    printf '\t\t\t\t\n'
    return 0
  fi

  if [[ -f "$GEO_CACHE_FILE" ]]; then
    cached=$(awk -F '\t' -v ip="$ip" '$1 == ip { print; exit }' "$GEO_CACHE_FILE" 2>/dev/null || true)
    if [[ -n "$cached" ]]; then
      printf '%s\n' "$cached" | cut -f2-
      return 0
    fi
  fi

  result=$(
    python3 - "$ip" "$GEO_API_TIMEOUT" <<'PY'
import json
import re
import sys
import urllib.request

ip = sys.argv[1]
timeout = float(sys.argv[2])
url = f"http://ip-api.com/json/{ip}?fields=status,countryCode,regionName,city,as,asname,org,query"

def clean(value):
    return str(value or "").replace("\t", " ").replace("\n", " ").strip()

try:
    with urllib.request.urlopen(url, timeout=timeout) as response:
        data = json.load(response)
except Exception:
    print("\t\t\t\t")
    raise SystemExit

if data.get("status") != "success":
    print("\t\t\t\t")
    raise SystemExit

as_text = clean(data.get("as"))
match = re.match(r"AS(\d+)", as_text)
asn = f"AS{match.group(1)}" if match else ""
org = clean(data.get("asname") or data.get("org") or re.sub(r"^AS\d+\s*", "", as_text))
fields = [
    clean(data.get("countryCode")),
    clean(data.get("regionName")),
    clean(data.get("city")),
    asn,
    org,
]
print("\t".join(fields))
PY
  )

  printf '%s\t%s\n' "$ip" "$result" >>"$GEO_CACHE_FILE" 2>/dev/null || true
  printf '%s\n' "$result"
}

init_geo_context() {
  [[ $GEO_AWARE -eq 1 ]] || return 0

  if ! has_cmd python3; then
    log "Geo scoring disabled: python3 not found"
    GEO_AWARE=0
    return 0
  fi

  : >"$GEO_CACHE_FILE" 2>/dev/null || true

  local family ip country region city asn org
  for family in "${FAMILIES[@]}"; do
    ip=$(public_ip_for_family "$family")
    [[ -n "$ip" ]] || continue
    IFS=$'\t' read -r country region city asn org < <(lookup_ip_geo "$ip")
    SOURCE_IPS[$family]=$ip
    SOURCE_COUNTRIES[$family]=$country
    SOURCE_REGIONS[$family]=$region
    SOURCE_CITIES[$family]=$city
    SOURCE_ASNS[$family]=$asn
    SOURCE_ORGS[$family]=$org

    if [[ -n "$country$asn" ]]; then
      log "Source $family: $ip ${country:-unknown} ${region:-} ${city:-} ${asn:-} ${org:-}"
    fi
  done
}

geo_bonus_for_ip() {
  local family=$1
  local ip=$2
  local country region city asn org
  local src_country=${SOURCE_COUNTRIES[$family]:-}
  local src_region=${SOURCE_REGIONS[$family]:-}
  local src_city=${SOURCE_CITIES[$family]:-}
  local src_asn=${SOURCE_ASNS[$family]:-}
  local src_org=${SOURCE_ORGS[$family]:-}
  local bonus=0
  local notes=()

  if [[ $GEO_AWARE -ne 1 || -z "$ip" || -z "$src_country$src_asn" ]]; then
    printf '0\t\n'
    return 0
  fi

  IFS=$'\t' read -r country region city asn org < <(lookup_ip_geo "$ip")

  if [[ -n "$asn" && -n "$src_asn" && "$asn" == "$src_asn" ]]; then
    bonus=$((bonus + 12))
    notes+=("same ASN $asn")
  elif [[ -n "$org" && -n "$src_org" && "${org,,}" == "${src_org,,}" ]]; then
    bonus=$((bonus + 8))
    notes+=("same org $org")
  fi

  if [[ -n "$country" && -n "$src_country" && "$country" == "$src_country" ]]; then
    bonus=$((bonus + 6))
    notes+=("same country $country")
  fi

  if [[ -n "$region" && -n "$src_region" && "${region,,}" == "${src_region,,}" ]]; then
    bonus=$((bonus + 4))
    notes+=("same region $region")
  fi

  if [[ -n "$city" && -n "$src_city" && "${city,,}" == "${src_city,,}" ]]; then
    bonus=$((bonus + 4))
    notes+=("same city $city")
  fi

  if [[ $bonus -gt 18 ]]; then
    bonus=18
  fi

  if [[ ${#notes[@]} -eq 0 && -n "$country$asn" ]]; then
    notes+=("edge ${country:-unknown} ${asn:-unknown}")
  fi

  local match_note=""
  if [[ ${#notes[@]} -gt 0 ]]; then
    match_note=$(IFS='; '; printf '%s' "${notes[*]}")
  fi
  printf '%s\t%s\n' "$bonus" "$match_note"
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
    -m) MODE=${2:?}; shift 2 ;;
    --strict) STRICT_TLS13=1; shift ;;
    --no-geo) GEO_AWARE=0; shift ;;
    --include-risky) CN_SAFE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "$VERSION"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ "$MODE" != "both" && "$MODE" != "ipv4" && "$MODE" != "ipv6" ]]; then
  echo "Invalid mode: $MODE. Use both, ipv4, or ipv6." >&2
  exit 1
fi

need_cmd curl
need_cmd openssl
need_cmd awk
need_cmd sed
need_cmd sort
need_cmd timeout
need_cmd tr

if [[ ! -f "$INPUT_FILE" ]]; then
  echo "Candidate file not found: $INPUT_FILE" >&2
  exit 1
fi

TMP_CSV=$(mktemp)
trap 'rm -f "$TMP_CSV"' EXIT

printf 'rank,family,domain,score,avg_appconnect_ms,success_rounds,total_rounds,tls13,cert_verify,alpn,http_code,last_remote_ip,dns_ips,geo_bonus,geo_match,note\n' >"$TMP_CSV"

declare -A DOMAIN_SEEN=()
declare -A DOMAIN_NOTES=()
DOMAINS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  d=$(trim_domain "$line")
  if [[ -n "$d" ]]; then
    if is_domain "$d"; then
      if [[ $CN_SAFE -eq 1 ]] && is_cn_risky_domain "$d"; then
        log "Skip CN-risky domain: $d"
        continue
      fi
      note=$(candidate_note "$line")
      if [[ -z "${DOMAIN_SEEN[$d]+x}" ]]; then
        DOMAINS+=("$d")
        DOMAIN_SEEN[$d]=1
      fi
      if [[ -n "$note" && -z "${DOMAIN_NOTES[$d]+x}" ]]; then
        DOMAIN_NOTES[$d]=$note
      fi
    else
      log "Skip invalid domain: $d"
    fi
  fi
done <"$INPUT_FILE"

if [[ ${#DOMAINS[@]} -gt 0 ]]; then
  mapfile -t DOMAINS < <(printf '%s\n' "${DOMAINS[@]}" | sort -u)
fi

if [[ ${#DOMAINS[@]} -eq 0 ]]; then
  echo "No candidate domains found in $INPUT_FILE" >&2
  exit 1
fi

if [[ "$MODE" == "both" ]]; then
  FAMILIES=(ipv4 ipv6)
else
  FAMILIES=("$MODE")
fi

init_geo_context

log "Testing ${#DOMAINS[@]} candidate domains, mode=${MODE}, rounds=${ROUNDS}, timeout=${TIMEOUT}s"

for domain in "${DOMAINS[@]}"; do
  for family in "${FAMILIES[@]}"; do
    log "Probe $domain over $family"

    ips=$(resolve_ips "$domain" "$family")
    ip_count=0
    [[ -n "$ips" ]] && ip_count=$(awk -F'|' '{print NF}' <<<"$ips")

    IFS=',' read -r tls13 verify_ok h2 http11 protocol alpn < <(openssl_probe "$domain" "$family")

    success=0
    http_good=0
    total_appconnect=0
    last_code=0
    last_ip=""

    for ((i=1; i<=ROUNDS; i++)); do
      IFS=',' read -r code appconnect total remote_ip ssl_verify < <(curl_once "$domain" "$family")
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

    IFS=$'\t' read -r geo_bonus geo_match < <(geo_bonus_for_ip "$family" "$last_ip")

    if [[ $STRICT_TLS13 -eq 1 && ( $tls13 -ne 1 || $verify_ok -ne 1 ) ]]; then
      score="0.0"
    else
      base_score=$(score_domain "$success" "$ROUNDS" "$avg_ms" "$tls13" "$verify_ok" "$h2" "$http11" "$http_good" "$ip_count")
      score=$(apply_geo_bonus "$base_score" "$geo_bonus")
    fi

    {
      printf '0,%s,' "$family"
      csv_escape "$domain"; printf ','
      printf '%s,%s,%s,%s,%s,%s,' "$score" "$avg_ms" "$success" "$ROUNDS" "$tls13" "$verify_ok"
      csv_escape "$alpn"; printf ','
      printf '%s,' "$last_code"
      csv_escape "$last_ip"; printf ','
      csv_escape "$ips"; printf ','
      printf '%s,' "$geo_bonus"
      csv_escape "$geo_match"; printf ','
      csv_escape "${DOMAIN_NOTES[$domain]:-}"; printf '\n'
    } >>"$TMP_CSV"
  done
done

{
  head -n 1 "$TMP_CSV"
  tail -n +2 "$TMP_CSV" | sort -t',' -k4,4nr -k14,14nr -k5,5n | awk -F',' 'BEGIN { OFS="," } { $1=NR; print }'
} >"$OUT_CSV"

best_ipv4=$(awk -F',' '$2=="ipv4" && $4+0 > 0 { gsub(/^"|"$/, "", $3); gsub(/""/, "\"", $3); print $3; exit }' "$OUT_CSV")
best_ipv6=$(awk -F',' '$2=="ipv6" && $4+0 > 0 { gsub(/^"|"$/, "", $3); gsub(/""/, "\"", $3); print $3; exit }' "$OUT_CSV")
snippet_ipv4=${best_ipv4:-REPLACE_WITH_BEST_IPV4_SNI}
snippet_ipv6=${best_ipv6:-REPLACE_WITH_BEST_IPV6_SNI}

if [[ -n "$best_ipv4" || -n "$best_ipv6" ]]; then
  cat >"$OUT_SNIPPET" <<EOF
{
  "serverInboundRealitySettingsIPv4": {
    "dest": "${snippet_ipv4}:443",
    "xver": 0,
    "serverNames": ["${snippet_ipv4}"],
    "privateKey": "REPLACE_WITH_YOUR_XRAY_PRIVATE_KEY",
    "shortIds": ["REPLACE_WITH_YOUR_SHORT_ID"]
  },
  "clientOutboundRealitySettingsIPv4": {
    "serverName": "${snippet_ipv4}",
    "fingerprint": "chrome",
    "publicKey": "REPLACE_WITH_YOUR_XRAY_PUBLIC_KEY",
    "shortId": "REPLACE_WITH_YOUR_SHORT_ID",
    "spiderX": "/"
  },
  "serverInboundRealitySettingsIPv6": {
    "dest": "${snippet_ipv6}:443",
    "xver": 0,
    "serverNames": ["${snippet_ipv6}"],
    "privateKey": "REPLACE_WITH_YOUR_XRAY_PRIVATE_KEY",
    "shortIds": ["REPLACE_WITH_YOUR_SHORT_ID"]
  },
  "clientOutboundRealitySettingsIPv6": {
    "serverName": "${snippet_ipv6}",
    "fingerprint": "chrome",
    "publicKey": "REPLACE_WITH_YOUR_XRAY_PUBLIC_KEY",
    "shortId": "REPLACE_WITH_YOUR_SHORT_ID",
    "spiderX": "/"
  }
}
EOF
fi

log "Done. CSV: $OUT_CSV"
if [[ -n "${best_ipv4:-}" ]]; then
  log "Best IPv4 candidate: $best_ipv4"
fi
if [[ -n "${best_ipv6:-}" ]]; then
  log "Best IPv6 candidate: $best_ipv6"
fi
if [[ -n "${best_ipv4:-}" || -n "${best_ipv6:-}" ]]; then
  log "Snippet: $OUT_SNIPPET"
fi

echo
echo "Top ${TOP_N}:"
awk -F',' 'NR==1 { next } NR<=n+1 {
  gsub(/^"|"$/, "", $3)
  gsub(/^"|"$/, "", $10)
  geo=$15
  note=$16
  gsub(/^"|"$/, "", geo)
  gsub(/^"|"$/, "", note)
  suffix=""
  if (geo != "") suffix = suffix " geo=" geo
  if (note != "") suffix = suffix " # " note
  if (suffix != "") {
    printf "%2s  %-5s %-36s score=%5s geo+%s avg_tls=%sms success=%s/%s alpn=%s code=%s%s\n", $1, $2, $3, $4, $14, $5, $6, $7, $10, $11, suffix
  } else {
    printf "%2s  %-5s %-36s score=%5s geo+%s avg_tls=%sms success=%s/%s alpn=%s code=%s\n", $1, $2, $3, $4, $14, $5, $6, $7, $10, $11
  }
}' n="$TOP_N" "$OUT_CSV"
