#!/usr/bin/env bash

# Internet access stability checker.
# Probes HTTPS endpoints across worldwide regions and reports latency / packet loss.
# Also verifies DNS resolution via public resolvers from multiple regions.

set -uo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
INTERVAL=30          # seconds between rounds
ROUNDS=0             # 0 = run forever; >0 = stop after N rounds
TIMEOUT=10           # curl connect+max-time timeout per probe
PARALLEL=1           # probe all targets in parallel
NO_DNS=0             # set to 1 to skip DNS checks
HAS_DIG=1            # resolved at runtime

# ---------------------------------------------------------------------------
# Worldwide probe targets  [region|label|url]
# ---------------------------------------------------------------------------
TARGETS=(
  # North America
  "North America|Google (US)"          "https://www.google.com"
  "North America|Cloudflare (US)"      "https://www.cloudflare.com"
  "North America|AWS (US)"             "https://aws.amazon.com"

  # Europe
  "Europe|BBC (UK)"                    "https://www.bbc.co.uk"
  "Europe|Deutsche Welle (DE)"         "https://www.dw.com"
  "Europe|Wikipedia (NL CDN)"          "https://www.wikipedia.org"

  # Asia-Pacific
  "Asia-Pacific|Yahoo Japan (JP)"      "https://www.yahoo.co.jp"
  "Asia-Pacific|NHK (JP)"             "https://www3.nhk.or.jp"
  "Asia-Pacific|Alibaba Cloud (CN)"    "https://www.aliyun.com"
  "Asia-Pacific|ABC Australia (AU)"    "https://www.abc.net.au"
  "Asia-Pacific|Stuff.co.nz (NZ)"     "https://www.stuff.co.nz"

  # South & Central America
  "South America|Globo (BR)"          "https://www.globo.com"
  "South America|MercadoLibre (AR)"   "https://www.mercadolibre.com.ar"

  # Africa
  "Africa|News24 (ZA)"                "https://www.news24.com"
  "Africa|Al-Ahram (EG)"             "https://www.ahram.org.eg"

  # Middle East
  "Middle East|Al Jazeera (QA)"       "https://www.aljazeera.net"
  "Middle East|Haaretz (IL)"          "https://www.haaretz.com"
)

# ---------------------------------------------------------------------------
# DNS probe targets  [region|label|server_ip|hostname_to_resolve]
# Each entry uses a well-known public resolver from a distinct region.
# ---------------------------------------------------------------------------
DNS_TARGETS=(
  # Americas
  "Americas|Google DNS (US)"         "8.8.8.8"           "www.google.com"
  "Americas|Cloudflare (US)"         "1.1.1.1"           "www.cloudflare.com"
  "Americas|OpenDNS (US)"            "208.67.222.222"    "www.wikipedia.org"
  "Americas|Quad9 (Anycast/CH)"      "9.9.9.9"           "www.example.com"

  # Europe
  "Europe|AdGuard DNS (EU)"          "94.140.14.14"      "www.bbc.co.uk"
  "Europe|CleanBrowsing (EU)"        "185.228.168.9"     "www.dw.com"
  "Europe|Yandex DNS (RU)"           "77.88.8.8"         "www.yandex.ru"

  # Asia-Pacific
  "Asia-Pacific|Alibaba DNS (CN)"    "223.5.5.5"         "www.aliyun.com"
  "Asia-Pacific|DNSPod (CN)"         "119.29.29.29"      "www.baidu.com"
  "Asia-Pacific|Cloudflare v2 (AP)" "1.0.0.1"           "www.abc.net.au"

  # Middle East / Africa
  "Middle East|Shecan DNS (IR)"      "178.22.122.100"    "www.aljazeera.net"
  "Africa|Google DNS alt (ZA)"       "8.8.4.4"           "www.news24.com"
)

# ---------------------------------------------------------------------------
# Colour helpers (auto-disabled when stdout is not a TTY)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET='\033[0m'
  C_BOLD='\033[1m'
  C_GREEN='\033[32m'
  C_YELLOW='\033[33m'
  C_RED='\033[31m'
  C_CYAN='\033[36m'
  C_DIM='\033[2m'
else
  C_RESET=''; C_BOLD=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_CYAN=''; C_DIM=''
fi

log()   { printf '%s\n' "$*"; }
info()  { printf "${C_CYAN}%s${C_RESET}\n" "$*"; }
warn()  { printf "${C_YELLOW}%s${C_RESET}\n" "$*" >&2; }
die()   { printf "${C_RED}error: %s${C_RESET}\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Internet access stability checker — continuously probes HTTPS endpoints and
DNS resolvers across worldwide regions, refreshing the display each round.

Press Ctrl+C to exit.

Options:
  -i, --interval N     Seconds between rounds (default: $INTERVAL)
  -r, --rounds N       Stop after N rounds; 0 = run forever (default: $ROUNDS)
  -t, --timeout N      Per-probe timeout in seconds (default: $TIMEOUT)
  -p, --parallel       Probe all targets in parallel (default: on)
      --no-parallel    Probe targets sequentially
      --no-dns         Skip DNS resolution checks
  -h, --help           Show this help

Examples:
  $(basename "$0")                     # run forever, refresh every 30 s
  $(basename "$0") -i 60               # refresh every 60 s
  $(basename "$0") -r 5 -i 10         # 5 rounds, 10 s apart, then exit
  $(basename "$0") --no-dns -i 15     # HTTPS only, 15 s interval

Exit codes:
  0   Exited cleanly (Ctrl+C or --rounds reached, all probes OK)
  1   One or more probes failed on the final round
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--interval)   INTERVAL="${2:?--interval requires a value}"; shift 2 ;;
      -r|--rounds)     ROUNDS="${2:?--rounds requires a value}";     shift 2 ;;
      -t|--timeout)    TIMEOUT="${2:?--timeout requires a value}";   shift 2 ;;
      -p|--parallel)   PARALLEL=1; shift ;;
      --no-parallel)   PARALLEL=0; shift ;;
      --no-dns)        NO_DNS=1;   shift ;;
      -h|--help)       usage; exit 0 ;;
      *) die "unknown option: $1  (try --help)" ;;
    esac
  done

  [[ "$INTERVAL" =~ ^[0-9]+$ ]] || die "--interval must be a non-negative integer"
  [[ "$ROUNDS"   =~ ^[0-9]+$ ]] || die "--rounds must be a non-negative integer"
  [[ "$TIMEOUT"  =~ ^[0-9]+$ ]] || die "--timeout must be a positive integer"
}

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
check_deps() {
  local missing=()
  for cmd in curl awk bc; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "missing required commands: ${missing[*]}"

  # dig is optional; disable DNS checks gracefully if absent
  if ! command -v dig &>/dev/null; then
    warn "'dig' not found — DNS checks will be skipped (install bind-utils / dnsutils to enable)"
    HAS_DIG=0
  fi
}

# ---------------------------------------------------------------------------
# Probe one URL.  Prints a tab-separated result line:
#   <status> <http_code> <latency_ms> <region> <label> <url>
# ---------------------------------------------------------------------------
probe() {
  local region="$1" label="$2" url="$3"

  local result http_code time_total
  # --write-out outputs HTTP code and total time (seconds); --output /dev/null discards body
  result=$(curl \
    --silent \
    --location \
    --max-redirs 3 \
    --connect-timeout "$TIMEOUT" \
    --max-time "$TIMEOUT" \
    --write-out '%{http_code}\t%{time_total}' \
    --output /dev/null \
    "$url" 2>/dev/null) || true

  http_code=$(printf '%s' "$result" | cut -f1)
  time_total=$(printf '%s' "$result" | cut -f2)

  # Convert seconds → milliseconds (integer)
  local latency_ms=0
  if [[ -n "$time_total" ]]; then
    latency_ms=$(printf '%.0f' "$(echo "$time_total * 1000" | bc -l 2>/dev/null || echo 0)")
  fi

  local status="OK"
  if [[ -z "$http_code" ]] || [[ "$http_code" == "000" ]]; then
    status="FAIL"
    http_code="---"
    latency_ms="-"
  elif [[ "$http_code" -ge 500 ]]; then
    status="WARN"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$status" "$http_code" "$latency_ms" "$region" "$label" "$url"
}

# ---------------------------------------------------------------------------
# Probe one DNS resolver.  Prints a tab-separated result line:
#   <status> <latency_ms> <region> <label> <server> <hostname>
# ---------------------------------------------------------------------------
probe_dns() {
  local region="$1" label="$2" server="$3" hostname="$4"

  local start_ns end_ns latency_ms output status
  start_ns=$(date +%s%N)
  output=$(dig +short +time="$TIMEOUT" +tries=1 "@${server}" "${hostname}" A 2>/dev/null)
  local rc=$?
  end_ns=$(date +%s%N)

  latency_ms=$(( (end_ns - start_ns) / 1000000 ))

  if [[ $rc -eq 0 ]] && [[ -n "$output" ]]; then
    status="OK"
  else
    status="FAIL"
    latency_ms="-"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$status" "$latency_ms" "$region" "$label" "$server" "$hostname"
}

# ---------------------------------------------------------------------------
# Run all DNS probes for one round.
# ---------------------------------------------------------------------------
run_dns_round() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local pids=()
  local i=0

  local n=${#DNS_TARGETS[@]}
  local idx=0
  while [[ $idx -lt $n ]]; do
    local region_label="${DNS_TARGETS[$idx]}"
    local server="${DNS_TARGETS[$((idx+1))]}"
    local hostname="${DNS_TARGETS[$((idx+2))]}"
    local region="${region_label%%|*}"
    local label="${region_label##*|}"
    idx=$((idx + 3))

    if [[ "$PARALLEL" -eq 1 ]]; then
      probe_dns "$region" "$label" "$server" "$hostname" >"$tmpdir/$i.result" &
      pids+=($!)
    else
      probe_dns "$region" "$label" "$server" "$hostname" >"$tmpdir/$i.result"
    fi
    i=$((i + 1))
  done

  if [[ "$PARALLEL" -eq 1 ]]; then
    for pid in "${pids[@]}"; do
      wait "$pid" || true
    done
  fi

  local j=0
  while [[ $j -lt $i ]]; do
    cat "$tmpdir/$j.result"
    j=$((j + 1))
  done

  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# Run all probes for one round.  Returns results as newline-separated lines.
# ---------------------------------------------------------------------------
run_round() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local pids=()
  local i=0

  # Iterate pairs: TARGETS[i]=region, TARGETS[i+1]=url
  local n=${#TARGETS[@]}
  local idx=0
  while [[ $idx -lt $n ]]; do
    local region_label="${TARGETS[$idx]}"
    local url="${TARGETS[$((idx+1))]}"
    local region="${region_label%%|*}"
    local label="${region_label##*|}"
    idx=$((idx + 2))

    if [[ "$PARALLEL" -eq 1 ]]; then
      probe "$region" "$label" "$url" >"$tmpdir/$i.result" &
      pids+=($!)
    else
      probe "$region" "$label" "$url" >"$tmpdir/$i.result"
    fi
    i=$((i + 1))
  done

  # Wait for parallel jobs
  if [[ "$PARALLEL" -eq 1 ]]; then
    for pid in "${pids[@]}"; do
      wait "$pid" || true
    done
  fi

  # Collect in order
  local j=0
  while [[ $j -lt $i ]]; do
    cat "$tmpdir/$j.result"
    j=$((j + 1))
  done

  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# Print a formatted results table
# ---------------------------------------------------------------------------
print_table() {
  local -a lines=("$@")

  local col_region=6 col_label=4 col_status=6 col_code=4 col_ms=10

  # Find column widths
  for line in "${lines[@]}"; do
    IFS=$'\t' read -r status code ms region label url <<<"$line"
    [[ ${#region} -gt $col_region ]] && col_region=${#region}
    [[ ${#label}  -gt $col_label  ]] && col_label=${#label}
  done

  local sep_line
  sep_line=$(printf '%*s' $((col_region + col_label + col_status + col_code + col_ms + 14)) '' | tr ' ' '-')

  local fmt="${C_DIM}%-${col_region}s${C_RESET}  %-${col_label}s  %-${col_status}s  %${col_code}s  %${col_ms}s  %s\n"

  printf "${C_BOLD}${fmt}${C_RESET}" "REGION" "TARGET" "STATUS" "CODE" "LATENCY(ms)" "URL"
  printf '%s\n' "$sep_line"

  local ok_count=0 fail_count=0 warn_count=0
  local total_ms=0 count_ms=0

  for line in "${lines[@]}"; do
    IFS=$'\t' read -r status code ms region label url <<<"$line"
    local color="$C_RESET"
    case "$status" in
      OK)   color="$C_GREEN";  ok_count=$((ok_count+1))
            [[ "$ms" =~ ^[0-9]+$ ]] && total_ms=$((total_ms + ms)) && count_ms=$((count_ms+1))
            ;;
      WARN) color="$C_YELLOW"; warn_count=$((warn_count+1))
            [[ "$ms" =~ ^[0-9]+$ ]] && total_ms=$((total_ms + ms)) && count_ms=$((count_ms+1))
            ;;
      FAIL) color="$C_RED";    fail_count=$((fail_count+1)) ;;
    esac

    local ms_display="$ms"
    [[ "$ms" =~ ^[0-9]+$ ]] && ms_display="${ms} ms"

    printf "${color}%-${col_region}s${C_RESET}  %-${col_label}s  ${color}%-${col_status}s${C_RESET}  %${col_code}s  %${col_ms}s  ${C_DIM}%s${C_RESET}\n" \
      "$region" "$label" "$status" "$code" "$ms_display" "$url"
  done

  printf '%s\n' "$sep_line"

  # Summary line
  local avg_ms="-"
  [[ $count_ms -gt 0 ]] && avg_ms="$((total_ms / count_ms)) ms"

  local total=$((ok_count + warn_count + fail_count))
  printf "${C_BOLD}Summary:${C_RESET} %d/%d reachable" $((ok_count + warn_count)) $total
  [[ $warn_count -gt 0 ]] && printf "  ${C_YELLOW}(%d server-error)${C_RESET}" "$warn_count"
  [[ $fail_count -gt 0 ]] && printf "  ${C_RED}(%d unreachable)${C_RESET}" "$fail_count"
  printf "  ${C_DIM}avg latency: %s${C_RESET}\n" "$avg_ms"
}

# ---------------------------------------------------------------------------
# Print formatted DNS results table
# ---------------------------------------------------------------------------
print_dns_table() {
  local -a lines=("$@")

  local col_region=6 col_label=4 col_server=6 col_ms=10

  for line in "${lines[@]}"; do
    IFS=$'\t' read -r status ms region label server hostname <<<"$line"
    [[ ${#region} -gt $col_region ]] && col_region=${#region}
    [[ ${#label}  -gt $col_label  ]] && col_label=${#label}
    [[ ${#server} -gt $col_server ]] && col_server=${#server}
  done

  local sep_line
  sep_line=$(printf '%*s' $((col_region + col_label + col_server + col_ms + 30)) '' | tr ' ' '-')

  local fmt="${C_DIM}%-${col_region}s${C_RESET}  %-${col_label}s  %-6s  %${col_ms}s  %${col_server}s  %s\n"

  printf "\n"
  printf "${C_BOLD}${fmt}${C_RESET}" "REGION" "RESOLVER" "STATUS" "LATENCY(ms)" "SERVER IP" "HOSTNAME"
  printf '%s\n' "$sep_line"

  local ok_count=0 fail_count=0
  local total_ms=0 count_ms=0

  for line in "${lines[@]}"; do
    IFS=$'\t' read -r status ms region label server hostname <<<"$line"
    local color="$C_RESET"
    case "$status" in
      OK)   color="$C_GREEN"; ok_count=$((ok_count+1))
            [[ "$ms" =~ ^[0-9]+$ ]] && total_ms=$((total_ms + ms)) && count_ms=$((count_ms+1))
            ;;
      FAIL) color="$C_RED";   fail_count=$((fail_count+1)) ;;
    esac

    local ms_display="$ms"
    [[ "$ms" =~ ^[0-9]+$ ]] && ms_display="${ms} ms"

    printf "${color}%-${col_region}s${C_RESET}  %-${col_label}s  ${color}%-6s${C_RESET}  %${col_ms}s  %${col_server}s  ${C_DIM}%s${C_RESET}\n" \
      "$region" "$label" "$status" "$ms_display" "$server" "$hostname"
  done

  printf '%s\n' "$sep_line"

  local avg_ms="-"
  [[ $count_ms -gt 0 ]] && avg_ms="$((total_ms / count_ms)) ms"

  local total=$((ok_count + fail_count))
  printf "${C_BOLD}DNS Summary:${C_RESET} %d/%d resolvers responded" "$ok_count" "$total"
  [[ $fail_count -gt 0 ]] && printf "  ${C_RED}(%d failed)${C_RESET}" "$fail_count"
  printf "  ${C_DIM}avg latency: %s${C_RESET}\n" "$avg_ms"
}

# ---------------------------------------------------------------------------
# Clear the terminal screen (only when stdout is a TTY)
# ---------------------------------------------------------------------------
clear_screen() {
  [[ -t 1 ]] && printf '\033[2J\033[H'
}

# ---------------------------------------------------------------------------
# Countdown footer — overwrites a single line, counts down to 0
# Exits the countdown early if the round limit is reached.
# ---------------------------------------------------------------------------
countdown() {
  local secs=$1
  local round=$2
  local max_rounds=$3
  local i=$secs
  while [[ $i -gt 0 ]]; do
    local ts
    ts=$(date '+%H:%M:%S')
    if [[ $max_rounds -gt 0 ]]; then
      printf "\r${C_DIM}  [%s]  Next refresh in %ds  (round %d/%d — Ctrl+C to quit)   ${C_RESET}" \
        "$ts" "$i" "$round" "$max_rounds"
    else
      printf "\r${C_DIM}  [%s]  Next refresh in %ds  (Ctrl+C to quit)   ${C_RESET}" \
        "$ts" "$i"
    fi
    sleep 1
    i=$((i - 1))
  done
  # Erase the countdown line before redrawing
  printf '\r%*s\r' 70 ''
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  check_deps

  # Graceful Ctrl+C / SIGTERM — restore cursor and exit cleanly
  trap 'printf "\n${C_RESET}Stopped.\n"; exit 0' INT TERM

  local last_fail=0
  local round=1

  while true; do
    clear_screen

    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S %Z')

    if [[ "$ROUNDS" -gt 0 ]]; then
      info "=== Internet Stability Check — ${ts}  [round ${round}/${ROUNDS}] ==="
    else
      info "=== Internet Stability Check — ${ts}  [round ${round}] ==="
    fi

    # --- HTTPS probes ---
    local -a results=()
    while IFS= read -r line; do
      results+=("$line")
    done < <(run_round)

    print_table "${results[@]}"

    # --- DNS probes ---
    local -a dns_results=()
    if [[ "$NO_DNS" -eq 0 ]] && [[ "$HAS_DIG" -eq 1 ]]; then
      while IFS= read -r line; do
        dns_results+=("$line")
      done < <(run_dns_round)
      print_dns_table "${dns_results[@]}"
    fi

    # Determine overall status for this round
    last_fail=0
    for line in "${results[@]}" ${dns_results[@]+"${dns_results[@]}"}; do
      status="${line%%$'\t'*}"
      [[ "$status" == "FAIL" ]] && last_fail=1 && break
    done

    # Stop if round limit reached
    if [[ "$ROUNDS" -gt 0 ]] && [[ $round -ge "$ROUNDS" ]]; then
      printf '\n'
      break
    fi

    round=$((round + 1))
    countdown "$INTERVAL" "$round" "$ROUNDS"
  done

  return $last_fail
}

main "$@"
