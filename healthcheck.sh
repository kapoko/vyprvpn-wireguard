#!/bin/sh
set -eu

WG_IFACE="${WG_IFACE:-wg0}"
HEALTHCHECK_MAX_HANDSHAKE_AGE="${HEALTHCHECK_MAX_HANDSHAKE_AGE:-180}"
HEALTHCHECK_DNS_HOST="${HEALTHCHECK_DNS_HOST:-cloudflare.com}"
HEALTHCHECK_EGRESS_URL="${HEALTHCHECK_EGRESS_URL:-https://1.1.1.1/cdn-cgi/trace}"
HEALTHCHECK_TIMEOUT="${HEALTHCHECK_TIMEOUT:-5}"

if [ "${HEALTHCHECK_DISABLED:-0}" = "1" ]; then
  exit 0
fi

if ! ip link show "$WG_IFACE" >/dev/null 2>&1; then
  echo "$WG_IFACE is missing" >&2
  exit 1
fi

latest="$(wg show "$WG_IFACE" latest-handshakes 2>/dev/null | awk '{print $2; exit}')"
now="$(date +%s)"

if [ -z "$latest" ] || [ "$latest" -le 0 ]; then
  echo "$WG_IFACE has no WireGuard handshake" >&2
  exit 1
fi

age=$((now - latest))
if [ "$age" -gt "$HEALTHCHECK_MAX_HANDSHAKE_AGE" ]; then
  echo "$WG_IFACE WireGuard handshake is stale: ${age}s" >&2
  exit 1
fi

if ! nslookup "$HEALTHCHECK_DNS_HOST" >/dev/null 2>&1; then
  echo "DNS lookup failed for $HEALTHCHECK_DNS_HOST" >&2
  exit 1
fi

if ! curl -4 -fsS --max-time "$HEALTHCHECK_TIMEOUT" "$HEALTHCHECK_EGRESS_URL" >/dev/null; then
  echo "VPN egress check failed for $HEALTHCHECK_EGRESS_URL" >&2
  exit 1
fi
