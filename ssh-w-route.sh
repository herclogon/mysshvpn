#!/usr/bin/env bash

set -euo pipefail

STATE_DIR="/tmp/ssh-w-route"
STATE_FILE="$STATE_DIR/state"

ACTION="${1:-}"
shift || true

REMOTE_HOST=""
REMOTE_USER="root"
SSH_PORT="22"
SSH_BIN="${SSH_BIN:-ssh}"
TUN_DEV=""
LOCAL_TUN_ID="auto"
REMOTE_TUN_ID="0"
LOCAL_TUN_IP="10.10.10.1/30"
REMOTE_TUN_IP="10.10.10.2"
REMOTE_TUN_PEER="10.10.10.2"
REMOTE_OUT_IF=""
DNS_SERVER=""

usage() {
  cat <<'EOF'
Usage:
  sudo ./ssh-w-route.sh up --remote HOST [options]
  sudo ./ssh-w-route.sh down
  sudo ./ssh-w-route.sh status

Required for "up":
  --remote HOST          SSH server IP/hostname

Options for "up":
  --user USER            SSH user (default: root)
  --port PORT            SSH port (default: 22)
  --tun-dev NAME         Local TUN device name (default: tun<local-tun-id>)
  --local-tun-id N       Local tunnel id for ssh -w (default: first free)
  --remote-tun-id N      Remote tunnel id for ssh -w (default: 0)
  --local-ip CIDR        Local TUN IP/mask (default: 10.10.10.1/30)
  --remote-ip IP         Remote TUN peer IP (default: 10.10.10.2)
  --remote-out-if IFACE  Remote server uplink interface for NAT
  --dns IP               Replace resolver while tunnel is up
  --ssh-bin PATH         Path to ssh binary

Examples:
  sudo ./ssh-w-route.sh up --remote 46.101.146.88 --remote-out-if eth0 --dns 8.8.8.8
  sudo ./ssh-w-route.sh status
  sudo ./ssh-w-route.sh down

Notes:
  - The script will try to enable PermitTunnel on the remote SSH server if needed.
  - This script configures the remote tun interface and enables IPv4 forwarding/NAT.
  - The remote user must have sudo without an interactive password prompt, or be root.
EOF
}

log() {
  printf '[ssh-w-route] %s\n' "$*"
}

die() {
  printf '[ssh-w-route] error: %s\n' "$*" >&2
  exit 1
}

need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run this script as root (sudo)"
}

has_cmd() {
  local cmd="$1"
  if [[ "$cmd" == */* ]]; then
    [[ -x "$cmd" ]]
  else
    command -v "$cmd" >/dev/null 2>&1
  fi
}

need_cmd() {
  has_cmd "$1" || die "missing required command: $1"
}

resolve_ipv4() {
  local host="$1"
  if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s\n' "$host"
    return 0
  fi

  getent ahostsv4 "$host" | awk 'NR==1 {print $1; exit}'
}

find_free_tun_id() {
  local id
  for id in $(seq 0 255); do
    if ! ip link show "tun${id}" >/dev/null 2>&1; then
      printf '%s\n' "$id"
      return 0
    fi
  done
  die "could not find a free local tun device id"
}

normalize_tun_settings() {
  if [[ "$LOCAL_TUN_ID" == "auto" ]]; then
    LOCAL_TUN_ID="$(find_free_tun_id)"
  fi

  if [[ -z "$TUN_DEV" ]]; then
    TUN_DEV="tun${LOCAL_TUN_ID}"
  fi

  [[ "$TUN_DEV" == "tun${LOCAL_TUN_ID}" ]] || \
    die "--tun-dev must match --local-tun-id (expected tun${LOCAL_TUN_ID}, got ${TUN_DEV})"
}

remote_sudo() {
  if [[ "$REMOTE_USER" == "root" ]]; then
    printf ''
  else
    printf 'sudo -n '
  fi
}

save_state() {
  mkdir -p "$STATE_DIR"
  {
    printf 'PID=%q\n' "$PID"
    printf 'REMOTE_HOST=%q\n' "$REMOTE_HOST"
    printf 'REMOTE_IP=%q\n' "$REMOTE_IP"
    printf 'REMOTE_USER=%q\n' "$REMOTE_USER"
    printf 'SSH_PORT=%q\n' "$SSH_PORT"
    printf 'SSH_BIN=%q\n' "$SSH_BIN"
    printf 'TUN_DEV=%q\n' "$TUN_DEV"
    printf 'LOCAL_TUN_ID=%q\n' "$LOCAL_TUN_ID"
    printf 'REMOTE_TUN_ID=%q\n' "$REMOTE_TUN_ID"
    printf 'LOCAL_TUN_IP=%q\n' "$LOCAL_TUN_IP"
    printf 'REMOTE_TUN_IP=%q\n' "$REMOTE_TUN_IP"
    printf 'REMOTE_TUN_PEER=%q\n' "$REMOTE_TUN_PEER"
    printf 'REMOTE_OUT_IF=%q\n' "$REMOTE_OUT_IF"
    printf 'DNS_SERVER=%q\n' "${DNS_SERVER:-}"
    printf 'ORIG_DEFAULT_ROUTE=%q\n' "$ORIG_DEFAULT_ROUTE"
    printf 'ORIG_DEV=%q\n' "$ORIG_DEV"
    printf 'ORIG_GW=%q\n' "${ORIG_GW:-}"
    printf 'RESOLV_CONF_TARGET=%q\n' "${RESOLV_CONF_TARGET:-}"
  } >"$STATE_FILE"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || die "no active state found"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
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

parse_up_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remote)
        REMOTE_HOST="${2:-}"
        shift 2
        ;;
      --user)
        REMOTE_USER="${2:-}"
        shift 2
        ;;
      --port)
        SSH_PORT="${2:-}"
        shift 2
        ;;
      --tun-dev)
        TUN_DEV="${2:-}"
        shift 2
        ;;
      --local-tun-id)
        LOCAL_TUN_ID="${2:-}"
        shift 2
        ;;
      --remote-tun-id)
        REMOTE_TUN_ID="${2:-}"
        shift 2
        ;;
      --local-ip)
        LOCAL_TUN_IP="${2:-}"
        shift 2
        ;;
      --remote-ip)
        REMOTE_TUN_IP="${2:-}"
        REMOTE_TUN_PEER="${2:-}"
        shift 2
        ;;
      --remote-out-if)
        REMOTE_OUT_IF="${2:-}"
        shift 2
        ;;
      --dns)
        DNS_SERVER="${2:-}"
        shift 2
        ;;
      --ssh-bin)
        SSH_BIN="${2:-}"
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
  [[ -n "$REMOTE_OUT_IF" ]] || die "--remote-out-if is required for 'up'"
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

remote_exec() {
  local cmd="$1"
  "$SSH_BIN" -p "$SSH_PORT" "${REMOTE_USER}@${REMOTE_HOST}" "$cmd"
}

ensure_remote_permit_tunnel() {
  log "ensuring remote sshd allows tunnel forwarding"
  remote_exec "$(remote_sudo)mkdir -p /etc/ssh/sshd_config.d && \
    printf '%s\n' 'PermitTunnel yes' | $(remote_sudo)tee /etc/ssh/sshd_config.d/99-codex-permit-tunnel.conf >/dev/null && \
    ( $(remote_sudo)sshd -t || $(remote_sudo)/usr/sbin/sshd -t ) && \
    ( $(remote_sudo)systemctl restart ssh || \
      $(remote_sudo)systemctl restart sshd || \
      $(remote_sudo)service ssh restart || \
      $(remote_sudo)service sshd restart )"
}

bring_up() {
  need_root
  need_cmd "$SSH_BIN"
  need_cmd ip
  need_cmd getent
  parse_up_args "$@"
  normalize_tun_settings
  ensure_not_running

  REMOTE_IP="$(resolve_ipv4 "$REMOTE_HOST")"
  [[ -n "$REMOTE_IP" ]] || die "failed to resolve remote host: $REMOTE_HOST"

  ORIG_ROUTE="$(ip -4 route get "$REMOTE_IP" | head -n1)"
  ORIG_DEV="$(awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}' <<<"$ORIG_ROUTE")"
  ORIG_GW="$(awk '{for (i = 1; i <= NF; i++) if ($i == "via") {print $(i + 1); exit}}' <<<"$ORIG_ROUTE")"
  ORIG_DEFAULT_ROUTE="$(ip -4 route show default | head -n1)"

  [[ -n "$ORIG_DEV" ]] || die "could not determine outbound interface for $REMOTE_IP"
  [[ -n "$ORIG_DEFAULT_ROUTE" ]] || die "could not determine current default route"

  ensure_remote_permit_tunnel

  log "starting ssh -w ${LOCAL_TUN_ID}:${REMOTE_TUN_ID} to ${REMOTE_USER}@${REMOTE_HOST}"
  "$SSH_BIN" \
    -p "$SSH_PORT" \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -w "${LOCAL_TUN_ID}:${REMOTE_TUN_ID}" \
    "${REMOTE_USER}@${REMOTE_HOST}" \
    -N \
    >/tmp/ssh-w-route.log 2>&1 &
  PID=$!

  sleep 2
  if ! kill -0 "$PID" 2>/dev/null; then
    die "ssh tunnel failed to start; check /tmp/ssh-w-route.log"
  fi

  if ! ip link show "$TUN_DEV" >/dev/null 2>&1; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    die "$TUN_DEV was not created; check remote PermitTunnel and local privileges"
  fi

  log "configuring local $TUN_DEV as $LOCAL_TUN_IP"
  ip addr flush dev "$TUN_DEV"
  ip addr add "$LOCAL_TUN_IP" dev "$TUN_DEV"
  ip link set "$TUN_DEV" up

  log "configuring remote tun${REMOTE_TUN_ID} and enabling NAT on $REMOTE_OUT_IF"
  remote_exec "$(remote_sudo)ip addr flush dev tun${REMOTE_TUN_ID} && \
    $(remote_sudo)ip addr add ${REMOTE_TUN_IP}/30 dev tun${REMOTE_TUN_ID} && \
    $(remote_sudo)ip link set tun${REMOTE_TUN_ID} up && \
    $(remote_sudo)sysctl -w net.ipv4.ip_forward=1 >/dev/null && \
    ( $(remote_sudo)iptables -C FORWARD -i tun${REMOTE_TUN_ID} -o ${REMOTE_OUT_IF} -j ACCEPT 2>/dev/null || \
      $(remote_sudo)iptables -A FORWARD -i tun${REMOTE_TUN_ID} -o ${REMOTE_OUT_IF} -j ACCEPT ) && \
    ( $(remote_sudo)iptables -C FORWARD -i ${REMOTE_OUT_IF} -o tun${REMOTE_TUN_ID} -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
      $(remote_sudo)iptables -A FORWARD -i ${REMOTE_OUT_IF} -o tun${REMOTE_TUN_ID} -m state --state RELATED,ESTABLISHED -j ACCEPT ) && \
    ( $(remote_sudo)iptables -t nat -C POSTROUTING -o ${REMOTE_OUT_IF} -j MASQUERADE 2>/dev/null || \
      $(remote_sudo)iptables -t nat -A POSTROUTING -o ${REMOTE_OUT_IF} -j MASQUERADE )"

  if [[ -n "$ORIG_GW" ]]; then
    log "preserving direct route to $REMOTE_IP via $ORIG_GW dev $ORIG_DEV"
    ip route replace "$REMOTE_IP/32" via "$ORIG_GW" dev "$ORIG_DEV"
  else
    log "preserving direct route to $REMOTE_IP dev $ORIG_DEV"
    ip route replace "$REMOTE_IP/32" dev "$ORIG_DEV"
  fi

  log "switching default route via $REMOTE_TUN_PEER dev $TUN_DEV"
  ip route replace default via "$REMOTE_TUN_PEER" dev "$TUN_DEV"

  set_dns
  save_state

  log "traffic forwarding enabled"
  log "remote: $REMOTE_IP | tun: $TUN_DEV | peer: $REMOTE_TUN_PEER"
}

bring_down() {
  need_root
  need_cmd ip
  if [[ ! -f "$STATE_FILE" ]]; then
    printf 'inactive\n'
    return 0
  fi
  load_state

  if [[ -n "${ORIG_DEFAULT_ROUTE:-}" ]]; then
    log "restoring default route"
    ip route replace ${ORIG_DEFAULT_ROUTE}
  fi

  if [[ -n "${REMOTE_IP:-}" ]]; then
    ip route del "$REMOTE_IP/32" 2>/dev/null || true
  fi

  restore_dns

  if ip link show "$TUN_DEV" >/dev/null 2>&1; then
    log "removing local IP from $TUN_DEV"
    ip addr flush dev "$TUN_DEV" || true
    ip link set "$TUN_DEV" down || true
  fi

  if [[ -n "${PID:-}" ]] && kill -0 "$PID" 2>/dev/null; then
    log "stopping ssh tunnel process $PID"
    kill "$PID" || true
    wait "$PID" 2>/dev/null || true
  fi

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
    printf '  remote: %s (%s)\n' "$REMOTE_HOST" "$REMOTE_IP"
    printf '  tun: %s\n' "$TUN_DEV"
    printf '  pid: %s\n' "$PID"
    printf '  peer: %s\n' "$REMOTE_TUN_PEER"
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
