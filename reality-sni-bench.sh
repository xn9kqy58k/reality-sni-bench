#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.0"
ROUNDS=3
TIMEOUT=8
CONNECT_TIMEOUT=4
PARALLEL="${PARALLEL:-8}"
MAX_CANDIDATES="${MAX_CANDIDATES:-0}"
INPUT_FILE="candidates.txt"
OUT_CSV="reality-sni-report.csv"
OUT_SNIPPET="reality-best-snippet.json"
TOP_N=3
STRICT_TLS13=0
MODE="both"
GEO_AWARE=1
GEO_PREFILTER="${GEO_PREFILTER:-0}"
CN_DNS_CHECK="${CN_DNS_CHECK:-auto}"
MIN_CN_DNS_OK="${MIN_CN_DNS_OK:-0}"
GEO_CACHE_FILE="${GEO_CACHE_FILE:-.reality-sni-geo-cache.tsv}"
GEO_API_TIMEOUT="${GEO_API_TIMEOUT:-4}"
CN_DNS_TIMEOUT="${CN_DNS_TIMEOUT:-1}"
FULL_TLS_PROBE="${FULL_TLS_PROBE:-0}"
CN_DNS_RESOLVERS=("223.5.5.5" "119.29.29.29" "180.76.76.76" "114.114.114.114")
CN_DNS_TEST_DOMAINS=("apple.com" "microsoft.com")

declare -A SOURCE_IPS=()
declare -A SOURCE_COUNTRIES=()
declare -A SOURCE_REGIONS=()
declare -A SOURCE_CITIES=()
declare -A SOURCE_ASNS=()
declare -A SOURCE_ORGS=()
declare -A CN_DNS_FAMILY_CHECK=()

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
  -p NUM     Concurrent domain/family probes. Default: 8
  -l NUM     Limit candidate domains after filtering. Default: all
  -o FILE    Output CSV path. Default: reality-sni-report.csv
  -s FILE    Output best Reality snippet path. Default: reality-best-snippet.json
  -n NUM     Print top N suitable unique domains. Default: 3
  -m MODE    Address family: both, ipv4, or ipv6. Default: both
  --strict   Keep only domains that pass TLS 1.3 + certificate verification.
  --no-geo   Disable source/edge IP region and ASN scoring bonus.
  --geo-prefilter
             Prefer candidates whose resolved edge IP is near the VPS before probing.
  --no-geo-prefilter
             Disable pre-probe geo candidate ordering.
  --cn-dns-check
             Force mainland public DNS scoring signal.
  --no-cn-dns-check
             Disable mainland public DNS scoring signal. Default: auto.
  --full-tls-probe
             Also run the older openssl ALPN probe for each candidate.
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

geo_lookup_enabled() {
  [[ $GEO_AWARE -eq 1 || $GEO_PREFILTER -eq 1 ]]
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

is_valid_public_ip() {
  local ip=$1
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    case "$ip" in
      0.*|10.*|127.*|169.254.*|172.16.*|172.17.*|172.18.*|172.19.*|172.2[0-9].*|172.30.*|172.31.*|192.168.*|224.*|240.*)
        return 1
        ;;
    esac
    return 0
  fi

  if [[ "$ip" =~ : ]]; then
    case "${ip,,}" in
      ::1|fe80:*|fc*|fd*)
        return 1
        ;;
    esac
    return 0
  fi

  return 1
}

cn_dns_enabled_for_family() {
  local family=$1
  [[ "${CN_DNS_FAMILY_CHECK[$family]:-0}" == "1" ]]
}

cn_dns_signal_available_for_family() {
  local family=$1
  local qtype="A"
  local resolver domain answer
  local test_domains=()

  [[ "$family" == "ipv6" ]] && qtype="AAAA"
  has_cmd dig || return 1

  if [[ ${#DOMAINS[@]} -gt 0 ]]; then
    for domain in "${DOMAINS[@]}"; do
      test_domains+=("$domain")
      [[ ${#test_domains[@]} -ge 3 ]] && break
    done
  else
    test_domains=("${CN_DNS_TEST_DOMAINS[@]}")
  fi

  for resolver in "${CN_DNS_RESOLVERS[@]}"; do
    for domain in "${test_domains[@]}"; do
      while IFS= read -r answer; do
        if is_valid_public_ip "$answer"; then
          return 0
        fi
      done < <(dig @"$resolver" +short "$qtype" "$domain" +time="$CN_DNS_TIMEOUT" +tries=1 2>/dev/null | grep -E '^[0-9a-fA-F:.]+$' || true)
    done
  done

  return 1
}

init_cn_dns_signal() {
  local mode="${CN_DNS_CHECK,,}"
  local family

  case "$mode" in
    1|true|yes|y|on)
      for family in "${FAMILIES[@]}"; do
        CN_DNS_FAMILY_CHECK[$family]=1
      done
      ;;
    0|false|no|n|off)
      for family in "${FAMILIES[@]}"; do
        CN_DNS_FAMILY_CHECK[$family]=0
      done
      ;;
    auto)
      for family in "${FAMILIES[@]}"; do
        if cn_dns_signal_available_for_family "$family"; then
          CN_DNS_FAMILY_CHECK[$family]=1
          log "CN DNS signal enabled for $family"
        else
          CN_DNS_FAMILY_CHECK[$family]=0
          log "CN DNS signal unavailable for $family from this VPS; scoring without cn-dns cap"
        fi
      done
      ;;
    *)
      echo "Invalid CN_DNS_CHECK value: $CN_DNS_CHECK. Use auto, 1, or 0." >&2
      exit 1
      ;;
  esac
}

cn_dns_probe() {
  local domain=$1
  local family=$2
  local qtype="A"
  local resolver answer ok=0 total=0
  local tmp_dir pids=() pid result_file

  [[ "$family" == "ipv6" ]] && qtype="AAAA"

  if ! cn_dns_enabled_for_family "$family" || ! has_cmd dig; then
    printf 'skip\tcn-dns skipped\n'
    return 0
  fi

  tmp_dir=$(mktemp -d)

  for resolver in "${CN_DNS_RESOLVERS[@]}"; do
    total=$((total + 1))
    result_file="$tmp_dir/$resolver"
    {
      local found=0
      while IFS= read -r answer; do
        if is_valid_public_ip "$answer"; then
          found=1
          break
        fi
      done < <(dig @"$resolver" +short "$qtype" "$domain" +time="$CN_DNS_TIMEOUT" +tries=1 2>/dev/null | grep -E '^[0-9a-fA-F:.]+$' || true)
      printf '%s\n' "$found"
    } >"$result_file" &
    pids+=("$!")
  done

  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done

  for result_file in "$tmp_dir"/*; do
    [[ -f "$result_file" ]] || continue
    if [[ $(<"$result_file") == "1" ]]; then
      ok=$((ok + 1))
    fi
  done
  rm -rf "$tmp_dir"

  printf '%s/%s\tcn-dns %s/%s\n' "$ok" "$total" "$ok" "$total"
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
  local output
  local ip_flag=()

  if [[ "$family" == "ipv4" ]]; then
    ip_flag=(--ipv4)
  elif [[ "$family" == "ipv6" ]]; then
    ip_flag=(--ipv6)
  fi

  set +e
  output=$(curl \
    --silent --show-error --location \
    "${ip_flag[@]}" \
    --output /dev/null \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$TIMEOUT" \
    --tlsv1.3 \
    --write-out '%{http_code},%{time_appconnect},%{time_total},%{remote_ip},%{ssl_verify_result},%{http_version}' \
    "https://${domain}/" 2>/dev/null
  )
  local rc=$?
  set -e

  if [[ $rc -ne 0 || -z "$output" ]]; then
    printf '0,0,0,,999,0\n'
    return 0
  fi

  printf '%s\n' "$output"
}

score_domain() {
  local success=$1
  local rounds=$2
  local avg_ms=$3
  local tls13=$4
  local verify_ok=$5
  local h2=$6
  local http11=$7
  local http_score=$8
  local ip_count=$9

  awk -v success="$success" -v rounds="$rounds" -v avg="$avg_ms" \
      -v tls13="$tls13" -v verify="$verify_ok" -v h2="$h2" -v http11="$http11" \
      -v httpscore="$http_score" -v ipcount="$ip_count" '
    BEGIN {
      score = 0
      if (rounds > 0) score += (success / rounds) * 25
      if (tls13 == 1) score += 22
      if (verify == 1) score += 22
      if (h2 == 1) score += 10
      else if (http11 == 1) score += 4
      score += httpscore
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

cap_score() {
  local score=$1
  local cap=$2

  awk -v score="$score" -v cap="$cap" '
    BEGIN {
      if (score > cap) score = cap
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

  if ! geo_lookup_enabled || [[ -z "$ip" || ! "$ip" =~ ^[0-9a-fA-F:.]+$ ]]; then
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
  geo_lookup_enabled || return 0

  if ! has_cmd python3; then
    log "Geo lookup disabled: python3 not found"
    GEO_AWARE=0
    GEO_PREFILTER=0
    return 0
  fi

  touch "$GEO_CACHE_FILE" 2>/dev/null || true

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

prefetch_ip_geos() {
  local records_file=$1
  local ips_file missing_file results_file
  local ip cached

  geo_lookup_enabled || return 0
  has_cmd python3 || return 0
  [[ -s "$records_file" ]] || return 0

  ips_file=$(mktemp)
  missing_file=$(mktemp)
  results_file=$(mktemp)

  awk -F '\t' '{ print $4 }' "$records_file" | sort -u >"$ips_file"
  while IFS= read -r ip; do
    [[ -n "$ip" ]] || continue
    cached=""
    if [[ -f "$GEO_CACHE_FILE" ]]; then
      cached=$(awk -F '\t' -v ip="$ip" '$1 == ip { print; exit }' "$GEO_CACHE_FILE" 2>/dev/null || true)
    fi
    [[ -n "$cached" ]] || printf '%s\n' "$ip" >>"$missing_file"
  done <"$ips_file"

  if [[ -s "$missing_file" ]]; then
    python3 - "$GEO_API_TIMEOUT" "$missing_file" >"$results_file" <<'PY' || true
import json
import re
import sys
import urllib.request

timeout = float(sys.argv[1])
with open(sys.argv[2], encoding="utf-8") as handle:
    ips = [line.strip() for line in handle if line.strip()]
url = "http://ip-api.com/batch?fields=status,countryCode,regionName,city,as,asname,org,query"

def clean(value):
    return str(value or "").replace("\t", " ").replace("\n", " ").strip()

def row(data):
    as_text = clean(data.get("as"))
    match = re.match(r"AS(\d+)", as_text)
    asn = f"AS{match.group(1)}" if match else ""
    org = clean(data.get("asname") or data.get("org") or re.sub(r"^AS\d+\s*", "", as_text))
    fields = [
        clean(data.get("query")),
        clean(data.get("countryCode")),
        clean(data.get("regionName")),
        clean(data.get("city")),
        asn,
        org,
    ]
    return "\t".join(fields)

for start in range(0, len(ips), 100):
    chunk = ips[start:start + 100]
    try:
        req = urllib.request.Request(
            url,
            data=json.dumps(chunk).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=timeout) as response:
            payload = json.load(response)
    except Exception:
        continue

    for item in payload if isinstance(payload, list) else []:
        if item.get("status") == "success" and item.get("query"):
            print(row(item))
PY
    if [[ -s "$results_file" ]]; then
      cat "$results_file" >>"$GEO_CACHE_FILE" 2>/dev/null || true
    fi
  fi

  rm -f "$ips_file" "$missing_file" "$results_file"
}

geo_prefilter_candidates() {
  [[ $GEO_PREFILTER -eq 1 ]] || return 0
  geo_lookup_enabled || return 0

  local records_file scored_file selected_file
  local domain family ips ip order
  local country region city asn org score note
  local src_country src_region src_city src_asn src_org
  local best current matched limit_count total_count

  if [[ -z "${SOURCE_COUNTRIES[*]:-}${SOURCE_ASNS[*]:-}" ]]; then
    log "Geo prefilter skipped: source geo is unavailable"
    return 0
  fi

  records_file=$(mktemp)
  scored_file=$(mktemp)
  selected_file=$(mktemp)

  order=0
  for domain in "${DOMAINS[@]}"; do
    order=$((order + 1))
    for family in "${FAMILIES[@]}"; do
      src_country=${SOURCE_COUNTRIES[$family]:-}
      src_asn=${SOURCE_ASNS[$family]:-}
      [[ -n "$src_country$src_asn" ]] || continue
      ips=$(resolve_ips "$domain" "$family")
      [[ -n "$ips" ]] || continue
      ip=${ips%%|*}
      is_valid_public_ip "$ip" || continue
      printf '%s\t%s\t%s\t%s\n' "$order" "$domain" "$family" "$ip" >>"$records_file"
    done
  done

  if [[ ! -s "$records_file" ]]; then
    log "Geo prefilter skipped: no candidate DNS records"
    rm -f "$records_file" "$scored_file" "$selected_file"
    return 0
  fi

  prefetch_ip_geos "$records_file"

  declare -A BEST_SCORES=()
  declare -A BEST_NOTES=()

  while IFS=$'\t' read -r order domain family ip; do
    IFS=$'\t' read -r country region city asn org < <(lookup_ip_geo "$ip")
    src_country=${SOURCE_COUNTRIES[$family]:-}
    src_region=${SOURCE_REGIONS[$family]:-}
    src_city=${SOURCE_CITIES[$family]:-}
    src_asn=${SOURCE_ASNS[$family]:-}
    src_org=${SOURCE_ORGS[$family]:-}
    score=0
    note=""

    if [[ -n "$asn" && -n "$src_asn" && "$asn" == "$src_asn" ]]; then
      score=$((score + 70))
      note="${note}${note:+; }$family same ASN $asn"
    elif [[ -n "$org" && -n "$src_org" && "${org,,}" == "${src_org,,}" ]]; then
      score=$((score + 50))
      note="${note}${note:+; }$family same org $org"
    fi
    if [[ -n "$country" && -n "$src_country" && "$country" == "$src_country" ]]; then
      score=$((score + 20))
      note="${note}${note:+; }same country $country"
    fi
    if [[ -n "$region" && -n "$src_region" && "${region,,}" == "${src_region,,}" ]]; then
      score=$((score + 15))
      note="${note}${note:+; }same region $region"
    fi
    if [[ -n "$city" && -n "$src_city" && "${city,,}" == "${src_city,,}" ]]; then
      score=$((score + 15))
      note="${note}${note:+; }same city $city"
    fi

    best=${BEST_SCORES[$domain]:-0}
    if [[ $score -gt $best ]]; then
      BEST_SCORES[$domain]=$score
      BEST_NOTES[$domain]=$note
    fi
  done <"$records_file"

  order=0
  for domain in "${DOMAINS[@]}"; do
    order=$((order + 1))
    current=${BEST_SCORES[$domain]:-0}
    printf '%s\t%s\t%s\t%s\n' "$current" "$order" "$domain" "${BEST_NOTES[$domain]:-}" >>"$scored_file"
  done

  if [[ "$MAX_CANDIDATES" -gt 0 ]]; then
    sort -t "$(printf '\t')" -k1,1nr -k2,2n "$scored_file" | head -n "$MAX_CANDIDATES" >"$selected_file"
  else
    sort -t "$(printf '\t')" -k1,1nr -k2,2n "$scored_file" >"$selected_file"
  fi

  mapfile -t DOMAINS < <(awk -F '\t' '{ print $3 }' "$selected_file")
  matched=$(awk -F '\t' '$1 > 0 { count++ } END { print count + 0 }' "$selected_file")
  limit_count=${#DOMAINS[@]}
  total_count=$(wc -l <"$scored_file" | tr -d ' ')
  log "Geo prefilter selected ${limit_count}/${total_count} candidate domains (${matched} with same ASN/region/country signal)"

  rm -f "$records_file" "$scored_file" "$selected_file"
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
    -p) PARALLEL=${2:?}; shift 2 ;;
    -l|--limit) MAX_CANDIDATES=${2:?}; shift 2 ;;
    -o) OUT_CSV=${2:?}; shift 2 ;;
    -s) OUT_SNIPPET=${2:?}; shift 2 ;;
    -n) TOP_N=${2:?}; shift 2 ;;
    -m) MODE=${2:?}; shift 2 ;;
    --strict) STRICT_TLS13=1; shift ;;
    --no-geo) GEO_AWARE=0; shift ;;
    --geo-prefilter) GEO_PREFILTER=1; shift ;;
    --no-geo-prefilter) GEO_PREFILTER=0; shift ;;
    --cn-dns-check) CN_DNS_CHECK=1; shift ;;
    --no-cn-dns-check) CN_DNS_CHECK=0; shift ;;
    --full-tls-probe) FULL_TLS_PROBE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "$VERSION"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ "$MODE" != "both" && "$MODE" != "ipv4" && "$MODE" != "ipv6" ]]; then
  echo "Invalid mode: $MODE. Use both, ipv4, or ipv6." >&2
  exit 1
fi

if ! [[ "$PARALLEL" =~ ^[0-9]+$ ]] || [[ "$PARALLEL" -lt 1 ]]; then
  echo "Invalid parallel value: $PARALLEL. Use a positive integer." >&2
  exit 1
fi

if ! [[ "$MAX_CANDIDATES" =~ ^[0-9]+$ ]]; then
  echo "Invalid candidate limit: $MAX_CANDIDATES. Use 0 for all, or a positive integer." >&2
  exit 1
fi

if ! [[ "$GEO_PREFILTER" =~ ^(0|1)$ ]]; then
  echo "Invalid geo prefilter value: $GEO_PREFILTER. Use 0 or 1." >&2
  exit 1
fi

need_cmd curl
need_cmd awk
need_cmd sed
need_cmd sort
need_cmd tr
if [[ "$FULL_TLS_PROBE" =~ ^(1|true|yes|y)$ ]]; then
  need_cmd openssl
  need_cmd timeout
fi

if [[ ! -f "$INPUT_FILE" ]]; then
  echo "Candidate file not found: $INPUT_FILE" >&2
  exit 1
fi

TMP_CSV=$(mktemp)
TMP_RESULTS_DIR=$(mktemp -d)
cleanup() {
  rm -f "$TMP_CSV"
  rm -rf "$TMP_RESULTS_DIR"
}
trap cleanup EXIT

printf 'rank,family,domain,score,decision,avg_appconnect_ms,success_rounds,total_rounds,tls13,cert_verify,alpn,http_code,last_remote_ip,dns_ips,cn_dns,cn_dns_bonus,geo_bonus,geo_match,reason,note\n' >"$TMP_CSV"

declare -A DOMAIN_SEEN=()
declare -A DOMAIN_NOTES=()
DOMAINS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  d=$(trim_domain "$line")
  if [[ -n "$d" ]]; then
    if is_domain "$d"; then
      if is_cn_risky_domain "$d"; then
        log "Drop CN-unusable domain: $d"
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
geo_prefilter_candidates

if [[ "$GEO_PREFILTER" -ne 1 && "$MAX_CANDIDATES" -gt 0 && ${#DOMAINS[@]} -gt "$MAX_CANDIDATES" ]]; then
  DOMAINS=("${DOMAINS[@]:0:$MAX_CANDIDATES}")
fi

init_cn_dns_signal

probe_candidate() {
  local domain=$1
  local family=$2
  local output_file=$3
  local ips ip_count cn_dns cn_dns_note cn_dns_ok cn_dns_bonus
  local tls13 verify_ok h2 http11 protocol alpn
  local success http_score total_appconnect last_code last_ip
  local code appconnect total remote_ip ssl_verify http_version app_ms avg_ms
  local geo_bonus geo_match base_score score decision reason
  local dns_primary_ok=1
  local reason_parts=()

  log "Probe $domain over $family"

  ips=$(resolve_ips "$domain" "$family")
  ip_count=0
  [[ -n "$ips" ]] && ip_count=$(awk -F'|' '{print NF}' <<<"$ips")

  IFS=$'\t' read -r cn_dns cn_dns_note < <(cn_dns_probe "$domain" "$family")
  cn_dns_ok=0
  cn_dns_bonus=0
  if [[ "$cn_dns" =~ ^([0-9]+)/([0-9]+)$ ]]; then
    cn_dns_ok=${BASH_REMATCH[1]}
    if [[ $cn_dns_ok -ge 3 ]]; then
      cn_dns_bonus=5
    elif [[ $cn_dns_ok -ge 1 ]]; then
      cn_dns_bonus=2
    fi
    if cn_dns_enabled_for_family "$family" && [[ $MIN_CN_DNS_OK -gt 0 && $cn_dns_ok -lt $MIN_CN_DNS_OK ]]; then
      log "Skip CN-DNS-failed domain: $domain over $family ($cn_dns_note)"
      return 0
    fi
    if cn_dns_enabled_for_family "$family" && [[ $cn_dns_ok -lt 2 ]]; then
      dns_primary_ok=0
    fi
  fi

  tls13=0
  verify_ok=0
  h2=0
  http11=0
  protocol="no"
  alpn="none"
  success=0
  http_score=0
  total_appconnect=0
  last_code=0
  last_ip=""

  for ((i=1; i<=ROUNDS; i++)); do
    IFS=',' read -r code appconnect total remote_ip ssl_verify http_version < <(curl_once "$domain" "$family")
    last_code=$code
    last_ip=$remote_ip

    if [[ "$code" =~ ^[0-9]+$ ]] && [[ "$code" -gt 0 ]] && [[ "$ssl_verify" == "0" ]]; then
      success=$((success + 1))
      tls13=1
      verify_ok=1
      protocol="TLSv1.3"

      case "$http_version" in
        2|2.0)
          h2=1
          alpn="h2"
          ;;
        1.1|1)
          http11=1
          [[ $h2 -ne 1 ]] && alpn="http/1.1"
          ;;
      esac

      app_ms=$(awk -v t="$appconnect" 'BEGIN { printf "%.0f", t * 1000 }')
      total_appconnect=$(awk -v a="$total_appconnect" -v b="$app_ms" 'BEGIN { printf "%.0f", a + b }')
      if [[ "$code" =~ ^(200|204|301|302|307|308)$ ]]; then
        [[ $http_score -lt 8 ]] && http_score=8
      elif [[ "$code" =~ ^(401|403|404)$ ]]; then
        [[ $http_score -lt 4 ]] && http_score=4
      fi
    fi
  done

  if [[ "$FULL_TLS_PROBE" =~ ^(1|true|yes|y)$ ]]; then
    local probe_tls13 probe_verify_ok probe_h2 probe_http11 probe_protocol probe_alpn
    IFS=',' read -r probe_tls13 probe_verify_ok probe_h2 probe_http11 probe_protocol probe_alpn < <(openssl_probe "$domain" "$family")
    [[ $probe_tls13 -eq 1 ]] && tls13=1 && protocol="$probe_protocol"
    [[ $probe_verify_ok -eq 1 ]] && verify_ok=1
    if [[ $probe_h2 -eq 1 ]]; then
      h2=1
      alpn="$probe_alpn"
    elif [[ $probe_http11 -eq 1 && $h2 -ne 1 ]]; then
      http11=1
      alpn="$probe_alpn"
    fi
  fi

  avg_ms=0
  if [[ $success -gt 0 ]]; then
    avg_ms=$(awk -v total="$total_appconnect" -v success="$success" 'BEGIN { printf "%.0f", total / success }')
  fi

  IFS=$'\t' read -r geo_bonus geo_match < <(geo_bonus_for_ip "$family" "$last_ip")

  if [[ $STRICT_TLS13 -eq 1 && ( $tls13 -ne 1 || $verify_ok -ne 1 ) ]]; then
    score="0.0"
  else
    base_score=$(score_domain "$success" "$ROUNDS" "$avg_ms" "$tls13" "$verify_ok" "$h2" "$http11" "$http_score" "$ip_count")
    score=$(apply_geo_bonus "$base_score" "$((geo_bonus + cn_dns_bonus))")
    if cn_dns_enabled_for_family "$family" && [[ $dns_primary_ok -ne 1 ]]; then
      score=$(cap_score "$score" 89)
    fi
  fi

  decision="AVOID"
  if [[ "$score" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v s="$score" 'BEGIN { exit !(s >= 95) }' \
    && [[ $success -eq $ROUNDS && $tls13 -eq 1 && $verify_ok -eq 1 && $http_score -ge 4 && $dns_primary_ok -eq 1 ]]; then
    decision="PRIMARY"
  elif [[ "$score" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v s="$score" 'BEGIN { exit !(s >= 85) }' \
    && [[ $success -gt 0 && $tls13 -eq 1 && $verify_ok -eq 1 ]]; then
    decision="BACKUP"
  fi

  [[ $cn_dns_bonus -gt 0 ]] && reason_parts+=("$cn_dns_note")
  [[ -n "$geo_match" ]] && reason_parts+=("$geo_match")
  if [[ $http_score -eq 8 ]]; then
    reason_parts+=("good HTTP $last_code")
  elif [[ $http_score -eq 4 ]]; then
    reason_parts+=("acceptable HTTP $last_code")
  else
    reason_parts+=("weak HTTP $last_code")
  fi
  reason=$(IFS='; '; printf '%s' "${reason_parts[*]}")

  {
    printf '0,%s,' "$family"
    csv_escape "$domain"; printf ','
    printf '%s,' "$score"
    csv_escape "$decision"; printf ','
    printf '%s,%s,%s,%s,%s,' "$avg_ms" "$success" "$ROUNDS" "$tls13" "$verify_ok"
    csv_escape "$alpn"; printf ','
    printf '%s,' "$last_code"
    csv_escape "$last_ip"; printf ','
    csv_escape "$ips"; printf ','
    csv_escape "$cn_dns"; printf ','
    printf '%s,' "$cn_dns_bonus"
    printf '%s,' "$geo_bonus"
    csv_escape "$geo_match"; printf ','
    csv_escape "$reason"; printf ','
    csv_escape "${DOMAIN_NOTES[$domain]:-}"; printf '\n'
  } >"$output_file"
}

throttle_jobs() {
  local running
  while true; do
    running=$(jobs -pr | wc -l | tr -d ' ')
    [[ "$running" -lt "$PARALLEL" ]] && break
    if ! wait -n 2>/dev/null; then
      sleep 0.1
    fi
  done
}

log "Testing ${#DOMAINS[@]} candidate domains, mode=${MODE}, rounds=${ROUNDS}, timeout=${TIMEOUT}s, parallel=${PARALLEL}"

job_id=0
for domain in "${DOMAINS[@]}"; do
  for family in "${FAMILIES[@]}"; do
    throttle_jobs
    job_id=$((job_id + 1))
    probe_candidate "$domain" "$family" "$(printf '%s/%05d.csv' "$TMP_RESULTS_DIR" "$job_id")" &
  done
done
wait || true

for result_file in "$TMP_RESULTS_DIR"/*.csv; do
  [[ -s "$result_file" ]] || continue
  cat "$result_file" >>"$TMP_CSV"
done

{
  head -n 1 "$TMP_CSV"
  tail -n +2 "$TMP_CSV" | sort -t',' -k4,4nr -k16,16nr -k17,17nr -k6,6n | awk -F',' 'BEGIN { OFS="," } { $1=NR; print }'
} >"$OUT_CSV"

best_ipv4=$(awk -F',' '$2=="ipv4" && $4+0 > 0 && $5!="\"AVOID\"" { gsub(/^"|"$/, "", $3); gsub(/""/, "\"", $3); print $3; exit }' "$OUT_CSV")
best_ipv6=$(awk -F',' '$2=="ipv6" && $4+0 > 0 && $5!="\"AVOID\"" { gsub(/^"|"$/, "", $3); gsub(/""/, "\"", $3); print $3; exit }' "$OUT_CSV")
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
echo "Top ${TOP_N} suitable SNI domains:"
awk -F',' 'NR==1 { next } {
  gsub(/^"|"$/, "", $3)
  if (seen[$3]++) next
  decision=$5
  gsub(/^"|"$/, "", decision)
  if (decision == "AVOID") next
  alpn=$11
  gsub(/^"|"$/, "", alpn)
  cn=$15
  geo_bonus=$17
  reason=$19
  note=$20
  gsub(/^"|"$/, "", cn)
  gsub(/^"|"$/, "", reason)
  gsub(/^"|"$/, "", note)
  suffix=""
  if (reason != "") suffix = suffix " " reason
  if (note != "") suffix = suffix " # " note
  count++
  printf "%2s  %-7s best=%-5s %-36s score=%5s cn=%s geo+%s avg_tls=%sms success=%s/%s alpn=%s code=%s%s\n", count, decision, $2, $3, $4, cn, geo_bonus, $6, $7, $8, alpn, $12, suffix
  if (count >= n) exit
}
END {
  if (count == 0) {
    print "No suitable SNI domains found. Try --limit 0, --geo, or add your own candidates with --add."
  }
}' n="$TOP_N" "$OUT_CSV"
