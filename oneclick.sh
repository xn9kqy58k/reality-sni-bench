#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/xn9kqy58k/reality-sni-bench.git}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/xn9kqy58k/reality-sni-bench/main}"
INSTALL_DIR="${INSTALL_DIR:-}"
MODE="${MODE:-both}"
ROUNDS="${ROUNDS:-1}"
TIMEOUT="${TIMEOUT:-6}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-3}"
PARALLEL="${PARALLEL:-12}"
MAX_CANDIDATES="${MAX_CANDIDATES:-25}"
TOP_N="${TOP_N:-3}"
STRICT="${STRICT:-1}"
GEO_AWARE="${GEO_AWARE:-0}"
GEO_PREFILTER="${GEO_PREFILTER:-1}"
GEO_API_TIMEOUT="${GEO_API_TIMEOUT:-2}"
CN_DNS_CHECK="${CN_DNS_CHECK:-auto}"
FULL_TLS_PROBE="${FULL_TLS_PROBE:-0}"
SKIP_INSTALL=0
ASSUME_YES=0
INTERACTIVE=0
CUSTOM_DOMAINS=()

usage() {
  cat <<'EOF'
Reality SNI Bench one-click runner

Usage:
  bash oneclick.sh [options]

Options:
  -m, --mode MODE          both, ipv4, or ipv6
  -4, --ipv4               test IPv4 only
  -6, --ipv6               test IPv6 only
  --dual, --both           test IPv4 + IPv6, default
  --add DOMAIN             append one candidate SNI domain before testing
  -r, --rounds NUM         test rounds per domain, default: 1
  -t, --timeout SEC        total timeout per probe, default: 6
  -c, --connect-timeout S  curl connect timeout, default: 3
  -p, --parallel NUM       concurrent domain/family probes, default: 12
  -l, --limit NUM          candidate domain limit, default: 25; 0 means all
  -n, --top NUM            print top N suitable unique domains, default: 3
  --full                   run the full slower profile: all candidates, 3 rounds, geo on
  --no-strict              do not require TLS 1.3 + certificate verification
  --geo-prefilter          prefer same ASN/region/country candidates before testing, default
  --no-geo-prefilter       disable same-region prefiltering
  --geo                    enable source/edge IP region and ASN scoring bonus
  --no-geo                 disable geo scoring, default
  --cn-dns-check           force mainland public DNS scoring signal
  --no-cn-dns-check        disable mainland public DNS scoring signal, default is auto
  --full-tls-probe         also run the older openssl ALPN probe for each candidate
  --no-install             skip dependency installation
  --install-dir DIR        clone/update project in this directory
  --interactive            ask for custom domains and mode
  -y, --yes                non-interactive defaults, kept for compatibility
  -h, --help               show help

Examples:
  bash oneclick.sh
  bash oneclick.sh --ipv4
  bash oneclick.sh --ipv6 --rounds 3 --limit 0
  bash oneclick.sh --full
  bash oneclick.sh --add www.cloudflare.com --add www.microsoft.com
  MODE=ipv6 ROUNDS=3 MAX_CANDIDATES=0 bash oneclick.sh
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

sudo_cmd() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    "$@"
  elif has_cmd sudo; then
    sudo "$@"
  else
    return 1
  fi
}

default_install_dir() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    printf '/opt/reality-sni-bench'
  else
    printf '%s/reality-sni-bench' "${HOME:-.}"
  fi
}

normalize_mode() {
  case "${1,,}" in
    1|4|ip4|ipv4|v4) printf 'ipv4' ;;
    2|6|ip6|ipv6|v6) printf 'ipv6' ;;
    3|both|all|dual) printf 'both' ;;
    *) return 1 ;;
  esac
}

install_deps() {
  [[ $SKIP_INSTALL -eq 1 ]] && return 0

  local missing=()
  local cmd
  for cmd in curl awk sed sort tr git; do
    has_cmd "$cmd" || missing+=("$cmd")
  done
  if [[ "$FULL_TLS_PROBE" =~ ^(1|true|yes|y)$ ]]; then
    for cmd in openssl timeout; do
      has_cmd "$cmd" || missing+=("$cmd")
    done
  fi
  if [[ "$GEO_AWARE" =~ ^(1|true|yes|y)$ || "$GEO_PREFILTER" =~ ^(1|true|yes|y)$ ]]; then
    has_cmd python3 || missing+=("python3")
  fi

  if has_cmd dig || has_cmd getent; then
    :
  else
    missing+=("dig-or-getent")
  fi

  [[ ${#missing[@]} -eq 0 ]] && return 0

  log "Installing missing dependencies if possible: ${missing[*]}"

  if has_cmd apt-get; then
    sudo_cmd apt-get update
    sudo_cmd apt-get install -y curl openssl dnsutils coreutils gawk sed git python3
  elif has_cmd dnf; then
    sudo_cmd dnf install -y curl openssl bind-utils coreutils gawk sed git python3
  elif has_cmd yum; then
    sudo_cmd yum install -y curl openssl bind-utils coreutils gawk sed git python3
  elif has_cmd apk; then
    sudo_cmd apk add --no-cache curl openssl bind-tools coreutils gawk sed git python3
  elif has_cmd pacman; then
    sudo_cmd pacman -Sy --noconfirm curl openssl bind coreutils gawk sed git python
  else
    die "No supported package manager found. Install curl openssl dnsutils/coreutils/gawk/sed/git/python3 manually."
  fi
}

ensure_project() {
  if [[ -f "./reality-sni-bench.sh" ]]; then
    PROJECT_DIR=$(pwd)
    chmod +x "$PROJECT_DIR/reality-sni-bench.sh"
    return 0
  fi

  INSTALL_DIR=${INSTALL_DIR:-$(default_install_dir)}
  mkdir -p "$(dirname "$INSTALL_DIR")"

  if [[ -d "$INSTALL_DIR/.git" ]]; then
    log "Updating $INSTALL_DIR"
    if ! git -C "$INSTALL_DIR" diff --quiet || ! git -C "$INSTALL_DIR" diff --cached --quiet; then
      local backup_patch
      backup_patch="$INSTALL_DIR/local-changes-$(date +%Y%m%d-%H%M%S).patch"
      log "Local tracked-file changes found. Backing them up to $backup_patch"
      git -C "$INSTALL_DIR" diff >"$backup_patch" || true
      git -C "$INSTALL_DIR" diff --cached >>"$backup_patch" || true
      git -C "$INSTALL_DIR" fetch origin main
      git -C "$INSTALL_DIR" reset --hard origin/main
      log "Synced tracked files to origin/main. candidates.txt is kept."
    elif ! git -C "$INSTALL_DIR" pull --ff-only; then
      log "Fast-forward update failed. Syncing tracked files to origin/main."
      git -C "$INSTALL_DIR" fetch origin main
      git -C "$INSTALL_DIR" reset --hard origin/main
    fi
  elif has_cmd git; then
    log "Cloning $REPO_URL to $INSTALL_DIR"
    git clone "$REPO_URL" "$INSTALL_DIR"
  else
    log "Git not found; downloading scripts to $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    curl -fsSL "$RAW_BASE/reality-sni-bench.sh" -o "$INSTALL_DIR/reality-sni-bench.sh"
    curl -fsSL "$RAW_BASE/candidates.example.txt" -o "$INSTALL_DIR/candidates.example.txt"
  fi

  PROJECT_DIR=$INSTALL_DIR
  chmod +x "$PROJECT_DIR/reality-sni-bench.sh"
}

filter_candidate_file() {
  local file=$1
  local tmp_filter
  tmp_filter=$(mktemp)
  awk '
    function norm(line, d) {
      d = line
      sub(/#.*/, "", d)
      gsub(/^[ \t]+|[ \t]+$/, "", d)
      sub(/^https:\/\//, "", d)
      sub(/^http:\/\//, "", d)
      sub(/\/.*/, "", d)
      sub(/:.*/, "", d)
      return tolower(d)
    }
    function old_default(d) {
      return (d ~ /^(www\.cloudflare\.com|www\.microsoft\.com|www\.apple\.com|www\.mozilla\.org|www\.github\.com|www\.wikipedia\.org|www\.bing\.com|www\.ubuntu\.com|www\.debian\.org|www\.akamai\.com)$/ ||
              d ~ /(alicdn\.com|aliyun\.com|tencent-cloud\.com|cloud\.tencent\.com|gtimg\.(com|cn)|qq\.com|bdstatic\.com|baidu\.com|bytecdntp\.com|bytednsdoc\.com|douyinstatic\.com|hc-cdn\.cn|huawei\.com|huaweicloud\.com|bootcdn\.net|baomitu\.com|qhres2\.com|kujiale\.com)/ ||
              d ~ /(shopify\.com|shopifycdn\.net|zdassets\.com|zendesk\.com|hsforms\.net|hs-analytics\.net|cookielaw\.org)/ ||
              d ~ /(awsstatic\.com|amazon\.com|aboutamazon\.com|media-amazon\.com|ssl-images-amazon\.com)/ ||
              d == "community.akamai.steamstatic.com")
    }
    function cn_risky(d) {
      return d ~ /(google|gstatic\.com|googleapis\.com|googleusercontent\.com|gvt1\.com|gcr\.io|facebook|fbcdn\.net|twitter\.com|twimg\.com|^x\.com$|discordapp\.com|discord\.com|docker\.com|docker\.io|githubassets\.com|githubusercontent\.com|github\.com|npmjs\.org|unpkg\.com|nodejs\.org|rust-lang\.org|crates\.io|pypi\.org|pythonhosted\.org|slack-edge\.com|segment\.com|stripe\.com|stripe\.network|aadcdn\.msauth\.net|aadcdn\.msftauth\.net|acctcdn\.msauth\.net)/
    }
    {
      d = norm($0)
      if (d == "") {
        if ($0 ~ /^#/ && !seen_comment[$0]++) print
        next
      }
      if (old_default(d) || cn_risky(d)) next
      if (!seen_domain[d]++) print
    }
  ' "$file" >"$tmp_filter"
  mv "$tmp_filter" "$file"
}

ensure_candidates() {
  cd "$PROJECT_DIR"

  if [[ ! -f candidates.txt ]]; then
    cp candidates.example.txt candidates.txt
    log "Created candidates.txt from candidates.example.txt"
  fi

  local tmp_candidates
  tmp_candidates=$(mktemp)
  awk '
    function norm(line, d) {
      d = line
      sub(/#.*/, "", d)
      gsub(/^[ \t]+|[ \t]+$/, "", d)
      sub(/^https:\/\//, "", d)
      sub(/^http:\/\//, "", d)
      sub(/\/.*/, "", d)
      sub(/:.*/, "", d)
      return tolower(d)
    }
    function old_default(d) {
      return (d ~ /^(www\.cloudflare\.com|www\.microsoft\.com|www\.apple\.com|www\.mozilla\.org|www\.github\.com|www\.wikipedia\.org|www\.bing\.com|www\.ubuntu\.com|www\.debian\.org|www\.akamai\.com)$/ ||
              d ~ /(alicdn\.com|aliyun\.com|tencent-cloud\.com|cloud\.tencent\.com|gtimg\.(com|cn)|qq\.com|bdstatic\.com|baidu\.com|bytecdntp\.com|bytednsdoc\.com|douyinstatic\.com|hc-cdn\.cn|huawei\.com|huaweicloud\.com|bootcdn\.net|baomitu\.com|qhres2\.com|kujiale\.com)/ ||
              d ~ /(shopify\.com|shopifycdn\.net|zdassets\.com|zendesk\.com|hsforms\.net|hs-analytics\.net|cookielaw\.org)/ ||
              d ~ /(awsstatic\.com|amazon\.com|aboutamazon\.com|media-amazon\.com|ssl-images-amazon\.com)/ ||
              d == "community.akamai.steamstatic.com")
    }
    function cn_risky(d) {
      return d ~ /(google|gstatic\.com|googleapis\.com|googleusercontent\.com|gvt1\.com|gcr\.io|facebook|fbcdn\.net|twitter\.com|twimg\.com|^x\.com$|discordapp\.com|discord\.com|docker\.com|docker\.io|githubassets\.com|githubusercontent\.com|github\.com|npmjs\.org|unpkg\.com|nodejs\.org|rust-lang\.org|crates\.io|pypi\.org|pythonhosted\.org|slack-edge\.com|segment\.com|stripe\.com|stripe\.network|aadcdn\.msauth\.net|aadcdn\.msftauth\.net|acctcdn\.msauth\.net)/
    }
    {
      d = norm($0)
      if (d != "" && (old_default(d) || cn_risky(d))) next
      print
    }
  ' candidates.txt >"$tmp_candidates"
  cat candidates.example.txt "$tmp_candidates" | awk '
    function norm(line, d) {
      d = line
      sub(/#.*/, "", d)
      gsub(/^[ \t]+|[ \t]+$/, "", d)
      sub(/^https:\/\//, "", d)
      sub(/^http:\/\//, "", d)
      sub(/\/.*/, "", d)
      sub(/:.*/, "", d)
      return tolower(d)
    }
    {
      d = norm($0)
      if (d == "") {
        if ($0 ~ /^#/ && !seen_comment[$0]++) print
        next
      }
      if (!seen_domain[d]++) print
    }
  ' > candidates.txt
  rm -f "$tmp_candidates"

  if [[ ${#CUSTOM_DOMAINS[@]} -gt 0 ]]; then
    local domain
    for domain in "${CUSTOM_DOMAINS[@]}"; do
      printf '%s\n' "$domain" >> candidates.txt
    done
    tmp_candidates=$(mktemp)
    awk '
      function norm(line, d) {
        d = line
        sub(/#.*/, "", d)
        gsub(/^[ \t]+|[ \t]+$/, "", d)
        sub(/^https:\/\//, "", d)
        sub(/^http:\/\//, "", d)
        sub(/\/.*/, "", d)
        sub(/:.*/, "", d)
        return tolower(d)
      }
      {
        d = norm($0)
        if (d == "") {
          if ($0 ~ /^#/ && !seen_comment[$0]++) print
          next
        }
        if (!seen_domain[d]++) print
      }
    ' candidates.txt >"$tmp_candidates"
    mv "$tmp_candidates" candidates.txt
    log "Added ${#CUSTOM_DOMAINS[@]} custom candidate domain(s)"
  fi

  if [[ $INTERACTIVE -eq 1 && $ASSUME_YES -eq 0 && -t 0 ]]; then
    printf 'Append custom candidate SNI domains now? [y/N]: '
    read -r answer || true
    case "${answer,,}" in
      y|yes)
        echo "Paste one domain per line. Press Enter on an empty line to finish."
        while IFS= read -r line; do
          [[ -z "$line" ]] && break
          printf '%s\n' "$line" >> candidates.txt
        done
        ;;
    esac
  fi

  filter_candidate_file candidates.txt
}

select_mode() {
  MODE=$(normalize_mode "$MODE") || die "Invalid mode: $MODE"

  if [[ $INTERACTIVE -eq 0 || $ASSUME_YES -eq 1 || ! -t 0 ]]; then
    return 0
  fi

  cat <<'EOF'

Select test mode:
  1) IPv4 only
  2) IPv6 only
  3) IPv4 + IPv6
EOF
  printf 'Choice [3]: '
  read -r choice || true
  choice=${choice:-3}
  MODE=$(normalize_mode "$choice") || die "Invalid choice: $choice"
}

prompt_numbers() {
  [[ $INTERACTIVE -eq 0 || $ASSUME_YES -eq 1 || ! -t 0 ]] && return 0

  printf 'Rounds per domain [%s]: ' "$ROUNDS"
  read -r answer || true
  [[ -n "$answer" ]] && ROUNDS=$answer

  printf 'Probe timeout seconds [%s]: ' "$TIMEOUT"
  read -r answer || true
  [[ -n "$answer" ]] && TIMEOUT=$answer

  printf 'Use strict TLS 1.3 + cert verification? [Y/n]: '
  read -r answer || true
  case "${answer,,}" in
    n|no) STRICT=0 ;;
    *) STRICT=1 ;;
  esac
}

run_bench() {
  cd "$PROJECT_DIR"

  local strict_arg=()
  local geo_arg=()
  local geo_prefilter_arg=()
  local cn_dns_arg=()
  local full_tls_arg=()
  if [[ "$STRICT" =~ ^(1|true|yes|y)$ ]]; then
    strict_arg=(--strict)
  fi
  if [[ ! "$GEO_AWARE" =~ ^(1|true|yes|y)$ ]]; then
    geo_arg=(--no-geo)
  fi
  if [[ "$GEO_PREFILTER" =~ ^(1|true|yes|y)$ ]]; then
    geo_prefilter_arg=(--geo-prefilter)
  else
    geo_prefilter_arg=(--no-geo-prefilter)
  fi
  if [[ "$CN_DNS_CHECK" =~ ^(1|true|yes|y)$ ]]; then
    cn_dns_arg=(--cn-dns-check)
  elif [[ "$CN_DNS_CHECK" =~ ^(0|false|no|n|off)$ ]]; then
    cn_dns_arg=(--no-cn-dns-check)
  fi
  if [[ "$FULL_TLS_PROBE" =~ ^(1|true|yes|y)$ ]]; then
    full_tls_arg=(--full-tls-probe)
  fi

  log "Running Reality SNI bench: mode=$MODE rounds=$ROUNDS parallel=$PARALLEL limit=$MAX_CANDIDATES geo=$GEO_AWARE geo_prefilter=$GEO_PREFILTER"
  GEO_API_TIMEOUT="$GEO_API_TIMEOUT" ./reality-sni-bench.sh \
    -f candidates.txt \
    -m "$MODE" \
    -r "$ROUNDS" \
    -t "$TIMEOUT" \
    -c "$CONNECT_TIMEOUT" \
    -p "$PARALLEL" \
    -l "$MAX_CANDIDATES" \
    -n "$TOP_N" \
    "${strict_arg[@]}" \
    "${geo_arg[@]}" \
    "${geo_prefilter_arg[@]}" \
    "${cn_dns_arg[@]}" \
    "${full_tls_arg[@]}"

  echo
  echo "Done."
  echo "Report:  $PROJECT_DIR/reality-sni-report.csv"
  echo "Snippet: $PROJECT_DIR/reality-best-snippet.json"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--mode) MODE=${2:?}; shift 2 ;;
    -4|--ipv4) MODE=ipv4; shift ;;
    -6|--ipv6) MODE=ipv6; shift ;;
    --dual|--both) MODE=both; shift ;;
    --add) CUSTOM_DOMAINS+=("${2:?}"); shift 2 ;;
    -r|--rounds) ROUNDS=${2:?}; shift 2 ;;
    -t|--timeout) TIMEOUT=${2:?}; shift 2 ;;
    -c|--connect-timeout) CONNECT_TIMEOUT=${2:?}; shift 2 ;;
    -p|--parallel) PARALLEL=${2:?}; shift 2 ;;
    -l|--limit) MAX_CANDIDATES=${2:?}; shift 2 ;;
    -n|--top) TOP_N=${2:?}; shift 2 ;;
    --full) ROUNDS=3; TIMEOUT=8; CONNECT_TIMEOUT=4; PARALLEL=8; MAX_CANDIDATES=0; GEO_AWARE=1; GEO_PREFILTER=0; GEO_API_TIMEOUT=4; shift ;;
    --no-strict) STRICT=0; shift ;;
    --geo-prefilter) GEO_PREFILTER=1; shift ;;
    --no-geo-prefilter) GEO_PREFILTER=0; shift ;;
    --geo) GEO_AWARE=1; shift ;;
    --no-geo) GEO_AWARE=0; shift ;;
    --cn-dns-check) CN_DNS_CHECK=1; shift ;;
    --no-cn-dns-check) CN_DNS_CHECK=0; shift ;;
    --full-tls-probe) FULL_TLS_PROBE=1; shift ;;
    --no-install) SKIP_INSTALL=1; shift ;;
    --install-dir) INSTALL_DIR=${2:?}; shift 2 ;;
    --interactive) INTERACTIVE=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

install_deps
ensure_project
ensure_candidates
select_mode
prompt_numbers
run_bench
