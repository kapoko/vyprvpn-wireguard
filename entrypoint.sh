#!/bin/sh
set -eu

VYPRVPN_SERVER="${VYPRVPN_SERVER:-eu1}"
WG_IFACE="${WG_IFACE:-wg0}"
WG_CONF="/etc/wireguard/${WG_IFACE}.conf"
VPN_INPUT_PORTS="${VPN_INPUT_PORTS:-}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
COMMAND_ADAPTER="${COMMAND_ADAPTER:-production}"
COMMAND_LOG="${COMMAND_LOG:-}"
COMMAND_STUB_DIR="${COMMAND_STUB_DIR:-}"
COMMAND_INDEX=0

log() {
  echo "[$(date -Iseconds)] $*"
}

record_command() {
  first=1
  for arg in "$@"; do
    if [ "$first" -eq 1 ]; then
      first=0
    else
      printf ' ' >> "$COMMAND_LOG"
    fi
    printf '%s' "$arg" >> "$COMMAND_LOG"
  done
  printf '\n' >> "$COMMAND_LOG"
}

next_command_index() {
  if [ -n "$COMMAND_STUB_DIR" ]; then
    index_file="${COMMAND_STUB_DIR}/.index"
    if [ ! -f "$index_file" ]; then
      printf '0\n' > "$index_file"
    fi
    IFS= read -r current_index < "$index_file"
    COMMAND_INDEX=$((current_index + 1))
    printf '%s\n' "$COMMAND_INDEX" > "$index_file"
  else
    COMMAND_INDEX=$((COMMAND_INDEX + 1))
  fi
}

run_cmd() {
  case "$COMMAND_ADAPTER" in
    production)
      "$@"
      ;;
    record)
      if [ -z "$COMMAND_LOG" ]; then
        echo "COMMAND_LOG must be set when COMMAND_ADAPTER=record" >&2
        exit 1
      fi

      next_command_index
      record_command "$@"

      if [ -n "$COMMAND_STUB_DIR" ] && [ -f "${COMMAND_STUB_DIR}/${COMMAND_INDEX}.out" ]; then
        cat "${COMMAND_STUB_DIR}/${COMMAND_INDEX}.out"
      fi

      if [ -n "$COMMAND_STUB_DIR" ] && [ -f "${COMMAND_STUB_DIR}/${COMMAND_INDEX}.status" ]; then
        status="$(cat "${COMMAND_STUB_DIR}/${COMMAND_INDEX}.status")"
        return "$status"
      fi

      return 0
      ;;
    *)
      echo "Unknown COMMAND_ADAPTER: $COMMAND_ADAPTER" >&2
      exit 1
      ;;
  esac
}

firewall_flush() {
  run_cmd iptables -F
}

firewall_delete_chains() {
  run_cmd iptables -X
}

firewall_policy() {
  run_cmd iptables -P "$1" "$2"
}

firewall_append() {
  run_cmd iptables -A "$@"
}

route_show_default() {
  run_cmd ip route show default
}

route_replace_endpoint() {
  endpoint_ip="$1"
  default_gateway="$2"

  run_cmd ip route replace "${endpoint_ip}/32" via "$default_gateway" dev eth0
}

interface_exists() {
  run_cmd ip link show "$1" >/dev/null 2>&1
}

wireguard_show() {
  run_cmd wg show "$@"
}

wireguard_quick_down() {
  run_cmd wg-quick down "$1"
}

vypr_connect() {
  run_cmd vyprvpn-wireguard-go connect -server "$1"
}

vypr_disconnect() {
  run_cmd vyprvpn-wireguard-go disconnect
}

dns_lookup_a() {
  run_cmd dig +short A "$1"
}

http_get() {
  run_cmd curl "$@"
}

vpn_killswitch_reset() {
  # Only touch the filter table.
  # Do NOT flush nat: Docker uses nat rules for its embedded DNS at 127.0.0.11.
  firewall_flush || true
  firewall_delete_chains || true

  firewall_policy INPUT DROP
  firewall_policy OUTPUT DROP
  firewall_policy FORWARD DROP
}

vpn_killswitch_hold() {
  vpn_killswitch_reset
}

vpn_killswitch_apply_pre_connect() {
  vpn_killswitch_reset

  firewall_append INPUT -i lo -j ACCEPT
  firewall_append OUTPUT -o lo -j ACCEPT

  firewall_append INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  firewall_append OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # Docker embedded DNS resolver.
  firewall_append OUTPUT -p udp -d 127.0.0.11 --dport 53 -j ACCEPT
  firewall_append OUTPUT -p tcp -d 127.0.0.11 --dport 53 -j ACCEPT

  # Fallback DNS, depending on Docker/network setup.
  firewall_append OUTPUT -p udp --dport 53 -j ACCEPT
  firewall_append OUTPUT -p tcp --dport 53 -j ACCEPT

  # Vypr WireGuard API/client setup traffic.
  firewall_append OUTPUT -p tcp --dport 443 -j ACCEPT

  # Initial WireGuard handshake.
  firewall_append OUTPUT -p udp --dport 51820 -j ACCEPT
}

resolve_endpoint_ip() {
  endpoint=""
  while IFS= read -r line; do
    key="${line%%=*}"
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    if [ "$key" = "Endpoint" ]; then
      endpoint="${line#*=}"
      endpoint="$(printf '%s' "$endpoint" | tr -d '[:space:]')"
      break
    fi
  done < "$WG_CONF"

  if [ -z "$endpoint" ]; then
    log "Could not find Endpoint in $WG_CONF"
    exit 1
  fi

  endpoint_host="${endpoint%:*}"
  endpoint_port="${endpoint##*:}"

  case "$endpoint_host" in
    *[!0-9.]*)
      endpoint_ip="$(dns_lookup_a "$endpoint_host" | while IFS= read -r resolved_ip; do
        if [ -n "$resolved_ip" ]; then
          printf '%s' "$resolved_ip"
          break
        fi
      done)"
      ;;
    *)
      endpoint_ip="$endpoint_host"
      ;;
  esac

  if [ -z "$endpoint_ip" ]; then
    log "Could not resolve endpoint host: $endpoint_host"
    exit 1
  fi

  echo "$endpoint_ip:$endpoint_port"
}

default_gateway() {
  route_show_default | while IFS= read -r line; do
    set -- $line
    if [ "${1:-}" = "default" ] && [ "${2:-}" = "via" ] && [ -n "${3:-}" ]; then
      printf '%s' "$3"
      break
    fi
  done
}

vpn_killswitch_apply_connected() {
  endpoint_ip="$1"
  endpoint_port="$2"
  wg_iface="$3"
  vpn_input_ports="$4"

  default_gateway="$(default_gateway)"

  if [ -z "$default_gateway" ]; then
    log "Could not determine default gateway for endpoint route"
    exit 1
  fi

  route_replace_endpoint "$endpoint_ip" "$default_gateway"

  log "Applying VPN killswitch. Endpoint: ${endpoint_ip}:${endpoint_port}"

  vpn_killswitch_reset

  firewall_append INPUT -i lo -j ACCEPT
  firewall_append OUTPUT -o lo -j ACCEPT

  firewall_append INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  firewall_append OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # Allow all normal outbound traffic only through WireGuard.
  firewall_append OUTPUT -o "$wg_iface" -j ACCEPT

  # Allow only the WireGuard transport packet outside the tunnel.
  firewall_append OUTPUT -o eth0 -p udp -d "$endpoint_ip" --dport "$endpoint_port" -j ACCEPT

  # Allow inbound VPN ports, useful for torrent incoming ports etc.
  # Example: VPN_INPUT_PORTS="31770 6881"
  for port in $vpn_input_ports; do
    firewall_append INPUT -i "$wg_iface" -p tcp --dport "$port" -j ACCEPT
    firewall_append INPUT -i "$wg_iface" -p udp --dport "$port" -j ACCEPT
  done
}

write_vypr_config() {
  mkdir -p /root/.config/vyprvpn
  mkdir -p /etc/wireguard
  touch "$WG_CONF"
  chmod 600 "$WG_CONF"

  cat > /root/.config/vyprvpn/config.yaml <<EOF
account:
  username: ${VYPRVPN_USER}
  password: ${VYPRVPN_PASS}
wireguard-config:
  filename: ${WG_CONF}
  wg-quick: true
  ignoredns: true
EOF
}

connect_vpn() {
  log "Writing VyprVPN config"
  write_vypr_config

  log "Setting pre-connect firewall"
  vpn_killswitch_apply_pre_connect

  log "Connecting to VyprVPN WireGuard server: ${VYPRVPN_SERVER}"
  vypr_connect "$VYPRVPN_SERVER"

  log "WireGuard status:"
  wireguard_show "$WG_IFACE" || true

  ep="$(resolve_endpoint_ip)"
  endpoint_ip="${ep%:*}"
  endpoint_port="${ep##*:}"
  vpn_killswitch_apply_connected "$endpoint_ip" "$endpoint_port" "$WG_IFACE" "$VPN_INPUT_PORTS"

  log "Testing VPN egress IP"
  # This request should go through wg0 or fail.
  http_get -fsS --max-time 10 https://ifconfig.me || true
  echo
}

disconnect_vpn() {
  log "Disconnecting"
  vypr_disconnect || true
  wireguard_quick_down "$WG_IFACE" || true
  vpn_killswitch_hold
}

monitor_vpn() {
  while true; do
    if ! interface_exists "$WG_IFACE"; then
      log "$WG_IFACE is down. Killswitch remains active."
      vpn_killswitch_hold
      sleep "$CHECK_INTERVAL"
      continue
    fi

    latest="$(wireguard_show "$WG_IFACE" latest-handshakes 2>/dev/null | while IFS= read -r line; do set -- $line; printf '%s' "${2:-}"; break; done || true)"
    now="$(date +%s)"

    if [ -n "$latest" ] && [ "$latest" -gt 0 ]; then
      age=$((now - latest))
      if [ "$age" -gt 180 ]; then
        log "WireGuard handshake stale: ${age}s. Traffic remains kill-switched except VPN transport."
      fi
    fi

    sleep "$CHECK_INTERVAL"
  done
}

main() {
  : "${VYPRVPN_USER:?Set VYPRVPN_USER}"
  : "${VYPRVPN_PASS:?Set VYPRVPN_PASS}"

  trap disconnect_vpn INT TERM

  connect_vpn

  if [ "$#" -gt 0 ]; then
    log "Executing command: $*"
    exec "$@"
  else
    log "No command supplied; keeping VPN container alive"
    monitor_vpn
  fi
}

if [ "${ENTRYPOINT_TESTING:-0}" != "1" ]; then
  main "$@"
fi
