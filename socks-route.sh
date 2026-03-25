#!/usr/bin/env bash

set -euo pipefail

STATE_DIR="/tmp/socks-route"
STATE_FILE="$STATE_DIR/state"

ACTION="${1:-}"
shift || true

SOCKS_ADDR="127.0.0.1:1080"
REMOTE_HOST=""
TUN_DEV="tun0"
TUN_IP="198.18.0.1"
TUN_MTU="8500"
DNS_SERVER=""
HEV_BIN="${HEV_BIN:-hev-socks5-tunnel}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
GITHUB_API_URL="https://api.github.com/repos/heiher/hev-socks5-tunnel/releases/latest"
ROUTE_TABLE="${ROUTE_TABLE:-20}"
BYPASS_RULE_PREF="${BYPASS_RULE_PREF:-10015}"
PROXY_RULE_PREF="${PROXY_RULE_PREF:-10020}"

usage() {
  cat <<'EOF'
Usage:
  sudo ./socks-route.sh up --remote <ssh-server-ip-or-host> [options]
  sudo ./socks-route.sh down
  sudo ./socks-route.sh status

Required for "up":
  --remote HOST        SSH server IP/hostname used by your local SOCKS tunnel

Options for "up":
  --socks HOST:PORT    Local SOCKS5 endpoint (default: 127.0.0.1:1080)
  --tun-dev NAME       TUN device name (default: tun0)
  --tun-ip IP          TUN local IP (default: 198.18.0.1)
  --tun-mtu N          TUN MTU (default: 8500)
  --dns IP             Replace resolver with this DNS server while tunnel is up
  --bin PATH           Path to hev-socks5-tunnel binary

Examples:
  ssh -N -D 127.0.0.1:1080 user@203.0.113.10
  sudo ./socks-route.sh up --remote 203.0.113.10 --dns 1.1.1.1
  sudo ./socks-route.sh status
  sudo ./socks-route.sh down

Notes:
  - If hev-socks5-tunnel is missing, the script will try to install it.
  - The SSH SOCKS tunnel must already be running locally.
  - If --dns is omitted, DNS may bypass the tunnel.
EOF
}

log() {
  printf '[socks-route] %s\n' "$*"
}

die() {
  printf '[socks-route] error: %s\n' "$*" >&2
  exit 1
}

need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run this script as root (sudo)"
}

need_cmd() {
  has_cmd "$1" || die "missing required command: $1"
}

has_cmd() {
  local cmd="$1"
  if [[ "$cmd" == */* ]]; then
    [[ -x "$cmd" ]]
  else
    command -v "$cmd" >/dev/null 2>&1
  fi
}

need_any_cmd() {
  local cmd
  for cmd in "$@"; do
    if command -v "$cmd" >/dev/null 2>&1; then
      return 0
    fi
  done
  die "missing required command: one of [$*]"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)
      printf 'x86_64\n'
      ;;
    aarch64|arm64)
      printf 'arm64\n'
      ;;
    armv7l|armv7|armhf)
      printf 'arm32\n'
      ;;
    *)
      die "unsupported architecture: $(uname -m)"
      ;;
  esac
}

fetch_latest_hev_download_url() {
  local arch="$1"
  local api_output

  api_output="$(curl -fsSL "$GITHUB_API_URL")" || die "failed to query GitHub release API"
  awk -v arch="$arch" -F'"' '
    /"browser_download_url":/ && $4 ~ ("hev-socks5-tunnel-linux-" arch "$") {
      print $4
      exit
    }
  ' <<<"$api_output"
}

install_hev() {
  local arch url tmpfile install_path

  if has_cmd "$HEV_BIN"; then
    return 0
  fi

  need_any_cmd curl install chmod uname awk mktemp

  arch="$(detect_arch)"
  url="$(fetch_latest_hev_download_url "$arch")"
  [[ -n "$url" ]] || die "no release asset found for linux-$arch"

  tmpfile="$(mktemp)"
  install_path="$INSTALL_DIR/hev-socks5-tunnel"

  log "installing hev-socks5-tunnel for linux-$arch from official release"
  curl -fL "$url" -o "$tmpfile" || {
    rm -f "$tmpfile"
    die "download failed: $url"
  }

  install -d "$INSTALL_DIR"
  install -m 0755 "$tmpfile" "$install_path"
  rm -f "$tmpfile"

  HEV_BIN="$install_path"
}

resolve_ipv4() {
  local host="$1"
  if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s\n' "$host"
    return 0
  fi

  getent ahostsv4 "$host" | awk 'NR==1 {print $1; exit}'
}

load_state() {
  [[ -f "$STATE_FILE" ]] || die "no active state found"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

save_state() {
  mkdir -p "$STATE_DIR"
  {
    printf 'PID=%q\n' "$PID"
    printf 'TUN_DEV=%q\n' "$TUN_DEV"
    printf 'TUN_IP=%q\n' "$TUN_IP"
    printf 'TUN_MTU=%q\n' "$TUN_MTU"
    printf 'SOCKS_ADDR=%q\n' "$SOCKS_ADDR"
    printf 'REMOTE_HOST=%q\n' "$REMOTE_HOST"
    printf 'REMOTE_IP=%q\n' "$REMOTE_IP"
    printf 'ORIG_DEFAULT_ROUTE=%q\n' "$ORIG_DEFAULT_ROUTE"
    printf 'ORIG_DEV=%q\n' "$ORIG_DEV"
    printf 'ORIG_GW=%q\n' "${ORIG_GW:-}"
    printf 'ROUTE_PROBE_IP=%q\n' "$ROUTE_PROBE_IP"
    printf 'ROUTE_TABLE=%q\n' "$ROUTE_TABLE"
    printf 'BYPASS_RULE_PREF=%q\n' "$BYPASS_RULE_PREF"
    printf 'PROXY_RULE_PREF=%q\n' "$PROXY_RULE_PREF"
    printf 'RP_FILTER_ALL_OLD=%q\n' "${RP_FILTER_ALL_OLD:-}"
    printf 'RP_FILTER_TUN_OLD=%q\n' "${RP_FILTER_TUN_OLD:-}"
    printf 'DNS_SERVER=%q\n' "${DNS_SERVER:-}"
    printf 'RESOLV_CONF_TARGET=%q\n' "${RESOLV_CONF_TARGET:-}"
    printf 'CONFIG_FILE=%q\n' "$CONFIG_FILE"
  } >"$STATE_FILE"
}

parse_up_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --socks)
        SOCKS_ADDR="${2:-}"
        shift 2
        ;;
      --remote)
        REMOTE_HOST="${2:-}"
        shift 2
        ;;
      --tun-dev)
        TUN_DEV="${2:-}"
        shift 2
        ;;
      --tun-ip)
        TUN_IP="${2:-}"
        shift 2
        ;;
      --tun-mtu)
        TUN_MTU="${2:-}"
        shift 2
        ;;
      --dns)
        DNS_SERVER="${2:-}"
        shift 2
        ;;
      --bin)
        HEV_BIN="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$REMOTE_HOST" ]] || die "--remote is required for 'up'"
}

ensure_not_running() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE" || true
    if [[ -n "${PID:-}" ]] && kill -0 "$PID" 2>/dev/null; then
      die "tunnel is already active (pid $PID)"
    fi
    rm -f "$STATE_FILE"
  fi
}

get_default_route() {
  ip -4 route show default | head -n1
}

set_dns() {
  [[ -n "$DNS_SERVER" ]] || return 0

  RESOLV_CONF_TARGET="$(readlink -f /etc/resolv.conf)"
  [[ -n "$RESOLV_CONF_TARGET" ]] || die "unable to resolve /etc/resolv.conf target"

  cp "$RESOLV_CONF_TARGET" "$STATE_DIR/resolv.conf.backup"
  cat >"$RESOLV_CONF_TARGET" <<EOF
nameserver $DNS_SERVER
options timeout:2 attempts:2
EOF
}

restore_dns() {
  [[ -f "$STATE_DIR/resolv.conf.backup" ]] || return 0
  [[ -n "${RESOLV_CONF_TARGET:-}" ]] || return 0

  cp "$STATE_DIR/resolv.conf.backup" "$RESOLV_CONF_TARGET"
  rm -f "$STATE_DIR/resolv.conf.backup"
}

write_hev_config() {
  local socks_host="${SOCKS_ADDR%:*}"
  local socks_port="${SOCKS_ADDR##*:}"

  CONFIG_FILE="$STATE_DIR/hev.yml"
  cat >"$CONFIG_FILE" <<EOF
tunnel:
  name: $TUN_DEV
  mtu: $TUN_MTU
  ipv4: $TUN_IP

socks5:
  address: $socks_host
  port: $socks_port
  udp: 'udp'
EOF
}

set_rp_filter() {
  [[ -r /proc/sys/net/ipv4/conf/all/rp_filter ]] || return 0

  RP_FILTER_ALL_OLD="$(< /proc/sys/net/ipv4/conf/all/rp_filter)"
  printf '0\n' >/proc/sys/net/ipv4/conf/all/rp_filter

  if [[ -r "/proc/sys/net/ipv4/conf/$TUN_DEV/rp_filter" ]]; then
    RP_FILTER_TUN_OLD="$(< "/proc/sys/net/ipv4/conf/$TUN_DEV/rp_filter")"
    printf '0\n' >"/proc/sys/net/ipv4/conf/$TUN_DEV/rp_filter"
  fi
}

restore_rp_filter() {
  if [[ -n "${RP_FILTER_ALL_OLD:-}" ]] && [[ -w /proc/sys/net/ipv4/conf/all/rp_filter ]]; then
    printf '%s\n' "$RP_FILTER_ALL_OLD" >/proc/sys/net/ipv4/conf/all/rp_filter
  fi

  if [[ -n "${RP_FILTER_TUN_OLD:-}" ]] && [[ -w "/proc/sys/net/ipv4/conf/$TUN_DEV/rp_filter" ]]; then
    printf '%s\n' "$RP_FILTER_TUN_OLD" >"/proc/sys/net/ipv4/conf/$TUN_DEV/rp_filter"
  fi
}

bring_up() {
  need_root
  need_cmd ip
  need_cmd getent
  parse_up_args "$@"
  install_hev
  need_cmd "$HEV_BIN"
  ensure_not_running

  REMOTE_IP="$(resolve_ipv4 "$REMOTE_HOST")"
  [[ -n "$REMOTE_IP" ]] || die "failed to resolve remote host: $REMOTE_HOST"

  ORIG_DEFAULT_ROUTE="$(get_default_route)"
  [[ -n "$ORIG_DEFAULT_ROUTE" ]] || die "could not determine current default route"

  ROUTE_PROBE_IP="$REMOTE_IP"
  ORIG_ROUTE="$(ip -4 route get "$ROUTE_PROBE_IP" | head -n1)"
  ORIG_DEV="$(awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}' <<<"$ORIG_ROUTE")"
  ORIG_GW="$(awk '{for (i = 1; i <= NF; i++) if ($i == "via") {print $(i + 1); exit}}' <<<"$ORIG_ROUTE")"

  [[ -n "$ORIG_DEV" ]] || die "could not determine outbound interface for $REMOTE_IP"

  if ip link show "$TUN_DEV" >/dev/null 2>&1; then
    die "device $TUN_DEV already exists"
  fi

  mkdir -p "$STATE_DIR"
  write_hev_config

  log "starting $HEV_BIN via $SOCKS_ADDR"
  "$HEV_BIN" "$CONFIG_FILE" \
    >/tmp/socks-route.hev.log 2>&1 &
  PID=$!

  sleep 1
  if ! kill -0 "$PID" 2>/dev/null; then
    die "$HEV_BIN failed to start; check /tmp/socks-route.hev.log"
  fi

  if ! ip link show "$TUN_DEV" >/dev/null 2>&1; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    die "$TUN_DEV was not created; check /tmp/socks-route.hev.log"
  fi

  set_rp_filter

  if [[ -n "$ORIG_GW" ]]; then
    log "keeping SSH server $REMOTE_IP on main uplink via $ORIG_GW dev $ORIG_DEV"
  else
    log "keeping SSH server $REMOTE_IP on main uplink dev $ORIG_DEV"
  fi

  ip rule add to "$REMOTE_IP/32" lookup main pref "$BYPASS_RULE_PREF"
  ip route replace default dev "$TUN_DEV" table "$ROUTE_TABLE"
  ip rule add lookup "$ROUTE_TABLE" pref "$PROXY_RULE_PREF"

  set_dns
  save_state

  log "traffic forwarding enabled"
  log "SOCKS: $SOCKS_ADDR | remote: $REMOTE_IP | tun: $TUN_DEV"
  [[ -n "$DNS_SERVER" ]] && log "DNS forced to $DNS_SERVER"
}

bring_down() {
  need_root
  need_cmd ip
  load_state

  if [[ -n "${PID:-}" ]] && kill -0 "$PID" 2>/dev/null; then
    log "stopping tun2socks process $PID"
    kill "$PID" || true
    wait "$PID" 2>/dev/null || true
  fi

  ip rule del pref "$PROXY_RULE_PREF" 2>/dev/null || true
  ip route del default dev "$TUN_DEV" table "$ROUTE_TABLE" 2>/dev/null || true
  ip rule del pref "$BYPASS_RULE_PREF" 2>/dev/null || true

  restore_dns
  restore_rp_filter

  if ip link show "$TUN_DEV" >/dev/null 2>&1; then
    log "removing $TUN_DEV"
    ip link delete "$TUN_DEV" || true
  fi

  rm -f "${CONFIG_FILE:-}"
  rm -f "$STATE_FILE"
  log "traffic forwarding disabled"
}

show_status() {
  if [[ ! -f "$STATE_FILE" ]]; then
    printf 'inactive\n'
    return 0
  fi

  load_state
  if [[ -n "${PID:-}" ]] && kill -0 "$PID" 2>/dev/null; then
    printf 'active\n'
    printf '  socks: %s\n' "$SOCKS_ADDR"
    printf '  remote: %s (%s)\n' "$REMOTE_HOST" "$REMOTE_IP"
    printf '  tun: %s\n' "$TUN_DEV"
    printf '  pid: %s\n' "$PID"
    if [[ -n "${DNS_SERVER:-}" ]]; then
      printf '  dns: %s\n' "$DNS_SERVER"
    fi
  else
    printf 'stale state (process not running)\n'
    return 1
  fi
}

case "$ACTION" in
  up)
    bring_up "$@"
    ;;
  down)
    bring_down
    ;;
  status)
    show_status
    ;;
  -h|--help|"")
    usage
    ;;
  *)
    die "unknown action: $ACTION"
    ;;
esac
