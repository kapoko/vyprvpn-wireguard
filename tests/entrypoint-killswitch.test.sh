#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT INT TERM

ENTRYPOINT_TESTING=1
COMMAND_ADAPTER=record
COMMAND_LOG="$tmpdir/commands.log"
COMMAND_STUB_DIR=""
export ENTRYPOINT_TESTING COMMAND_ADAPTER COMMAND_LOG COMMAND_STUB_DIR

. "$repo_root/entrypoint.sh"

assert_commands() {
  expected="$1"
  actual="$2"

  if ! diff -u "$expected" "$actual"; then
    echo "command log did not match: $actual" >&2
    exit 1
  fi
}

test_pre_connect_killswitch() {
  : > "$COMMAND_LOG"
  expected="$tmpdir/pre-connect.expected"

  cat > "$expected" <<'EOF'
iptables -F
iptables -X
iptables -P INPUT DROP
iptables -P OUTPUT DROP
iptables -P FORWARD DROP
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p udp -d 127.0.0.11 --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp -d 127.0.0.11 --dport 53 -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT
iptables -A OUTPUT -p udp --dport 51820 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp -j ACCEPT
EOF

  vpn_killswitch_apply_pre_connect
  assert_commands "$expected" "$COMMAND_LOG"
}

test_connected_killswitch() {
  : > "$COMMAND_LOG"
  stub_dir="$tmpdir/stubs"
  mkdir "$stub_dir"
  printf 'default via 172.18.0.1 dev eth0\n' > "$stub_dir/1.out"
  COMMAND_STUB_DIR="$stub_dir"
  export COMMAND_STUB_DIR
  expected="$tmpdir/connected.expected"

  cat > "$expected" <<'EOF'
ip route show default
ip route replace 203.0.113.10/32 via 172.18.0.1 dev eth0
iptables -F
iptables -X
iptables -P INPUT DROP
iptables -P OUTPUT DROP
iptables -P FORWARD DROP
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -o wg0 -j ACCEPT
iptables -A OUTPUT -o eth0 -p udp -d 203.0.113.10 --dport 51820 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp -j ACCEPT
iptables -A INPUT -i wg0 -p tcp --dport 31770 -j ACCEPT
iptables -A INPUT -i wg0 -p udp --dport 31770 -j ACCEPT
iptables -A INPUT -i wg0 -p tcp --dport 6881 -j ACCEPT
iptables -A INPUT -i wg0 -p udp --dport 6881 -j ACCEPT
EOF

  vpn_killswitch_apply_connected "203.0.113.10" "51820" "wg0" "31770 6881" >/dev/null
  assert_commands "$expected" "$COMMAND_LOG"
}

test_local_tcp_allow() {
  VPN_LOCAL_TCP_ALLOW="192.0.2.10:12345 198.51.100.20:23456"
  COMMAND_STUB_DIR="$tmpdir/local-stubs"
  mkdir "$COMMAND_STUB_DIR"
  printf 'default via 172.18.0.1 dev eth0\n' > "$COMMAND_STUB_DIR/1.out"
  : > "$COMMAND_LOG"
  vpn_killswitch_apply_connected "203.0.113.10" "51820" "wg0" "" >/dev/null
  grep -Fx 'ip route replace 192.0.2.10/32 via 172.18.0.1 dev eth0' "$COMMAND_LOG" >/dev/null
  grep -Fx 'iptables -A OUTPUT -o eth0 -p tcp -d 192.0.2.10 --dport 12345 -j ACCEPT' "$COMMAND_LOG" >/dev/null
  grep -Fx 'ip route replace 198.51.100.20/32 via 172.18.0.1 dev eth0' "$COMMAND_LOG" >/dev/null
  grep -Fx 'iptables -A OUTPUT -o eth0 -p tcp -d 198.51.100.20 --dport 23456 -j ACCEPT' "$COMMAND_LOG" >/dev/null

  COMMAND_STUB_DIR=""
  : > "$COMMAND_LOG"
  vpn_killswitch_hold
  if grep -E '192\.0\.2\.10|198\.51\.100\.20|OUTPUT .*ACCEPT' "$COMMAND_LOG"; then
    echo "hold state must not allow local exceptions" >&2
    exit 1
  fi
  VPN_LOCAL_TCP_ALLOW=""
}

test_invalid_local_tcp_allow() {
  for value in 'example.com:443' '192.168.1.1' '192.168.1.1:0' \
    '192.168.1.1:65536' '192.168.1.256:80' '192.168.01.1:80' \
    '192.168.1.1:80:90' '192.168.1.0/24:80' '*:80' \
    '192.168.1.1:80 10.0.0.1:bad'; do
    VPN_LOCAL_TCP_ALLOW="$value"
    if validate_local_tcp_allow 2>/dev/null; then
      echo "accepted invalid VPN_LOCAL_TCP_ALLOW: $value" >&2
      exit 1
    fi
  done
  VPN_LOCAL_TCP_ALLOW=""
}

test_pre_connect_killswitch
test_connected_killswitch
test_local_tcp_allow
test_invalid_local_tcp_allow

echo "entrypoint-killswitch.test.sh: ok"
