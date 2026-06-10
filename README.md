# VyprVPN WireGuard Docker Container

A small Docker image that connects to VyprVPN using VyprVPN's WireGuard Go client and keeps traffic kill-switched through the VPN interface.

The container can run by itself as a VPN gateway, or other containers can share its network namespace so their traffic exits through VyprVPN.

## Features

- Connects to VyprVPN WireGuard on startup
- Uses `wg-quick` with the generated VyprVPN WireGuard config
- Applies an iptables killswitch after the tunnel is up
- Blocks normal outbound traffic unless it goes through `wg0`
- Allows only the WireGuard transport packet outside the tunnel
- Supports optional inbound VPN ports with `VPN_INPUT_PORTS`
- Keeps running and monitors the WireGuard handshake when no command is supplied

## Requirements

- Docker
- Docker Compose
- A valid VyprVPN account
- Host support for `/dev/net/tun`

## Quick Start

Create a `.env` file next to `docker-compose.yml`:

```env
VYPRVPN_USER=your-vyprvpn-username
VYPRVPN_PASS=your-vyprvpn-password
```

Start the container:

```sh
docker compose up -d --build
```

Check the logs:

```sh
docker logs -f vyprvpn-wireguard
```

A successful startup should show a WireGuard interface, an egress IP, and then:

```text
No command supplied; keeping VPN container alive
```

That message is normal. It means the VPN container is staying alive as a gateway.

## Configuration

The compose file passes these environment variables to the container:

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `VYPRVPN_USER` | Yes | none | VyprVPN account username |
| `VYPRVPN_PASS` | Yes | none | VyprVPN account password |
| `VYPRVPN_SERVER` | No | `eu1` | VyprVPN server code to connect to |
| `WG_IFACE` | No | `wg0` | WireGuard interface name |
| `VPN_INPUT_PORTS` | No | empty | Space-separated TCP/UDP ports to allow inbound over the VPN |
| `CHECK_INTERVAL` | No | `30` | VPN monitor interval in seconds |
| `TZ` | No | unset | Container timezone |

Example compose environment:

```yaml
environment:
  - VYPRVPN_USER=${VYPRVPN_USER}
  - VYPRVPN_PASS=${VYPRVPN_PASS}
  - VYPRVPN_SERVER=eu1
  - VPN_INPUT_PORTS=31770
  - TZ=Europe/Amsterdam
```

## Running A Command Through The VPN

You can run a one-off command inside the VPN container:

```sh
docker compose run --rm vyprvpn curl https://ifconfig.me
```

If a command is supplied, the entrypoint connects the VPN first and then executes the command.

## Using It As A VPN Gateway

Other containers can use this container's network stack with `network_mode: "service:vyprvpn"`.

Example:

```yaml
services:
  vyprvpn:
    build:
      context: .
    container_name: vyprvpn-wireguard
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - VYPRVPN_USER=${VYPRVPN_USER}
      - VYPRVPN_PASS=${VYPRVPN_PASS}
      - VYPRVPN_SERVER=eu1
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=1
    restart: unless-stopped

  app:
    image: curlimages/curl:latest
    network_mode: "service:vyprvpn"
    depends_on:
      - vyprvpn
    command: ["sh", "-c", "while true; do curl -fsS https://ifconfig.me; sleep 300; done"]
```

When using `network_mode: "service:vyprvpn"`, publish ports on the `vyprvpn` service, not on the app service.

## Inbound Ports

Set `VPN_INPUT_PORTS` to allow inbound TCP and UDP traffic over the VPN interface.

Example:

```yaml
environment:
  - VPN_INPUT_PORTS=31770 6881
```

This only opens the container firewall on `wg0`. VyprVPN must also support/allow the inbound traffic you expect.

## Killswitch Behavior

Before connecting, the container allows only the traffic needed for DNS, VyprVPN API access, and the initial WireGuard handshake.

After connecting, the container:

- Drops inbound, outbound, and forwarded traffic by default
- Allows outbound traffic through `wg0`
- Allows established and related connections
- Allows the VyprVPN WireGuard endpoint over `eth0`
- Adds a host route for the VyprVPN endpoint so the WireGuard transport packet does not route into the tunnel itself

If the tunnel goes down, normal traffic remains blocked.

## Troubleshooting

Check startup logs:

```sh
docker logs vyprvpn-wireguard
```

Check WireGuard status:

```sh
docker exec vyprvpn-wireguard wg show
```

Look for `latest handshake` and non-zero received traffic. If received traffic stays at `0 B`, the tunnel is not passing return traffic.

Check routes:

```sh
docker exec vyprvpn-wireguard ip route
```

There should be a host route for the VyprVPN endpoint via `eth0`, plus the split default routes through `wg0`.

Test egress IP:

```sh
docker exec vyprvpn-wireguard curl -fsS https://ifconfig.me
```

If the egress test times out, check that the container has `NET_ADMIN`, `/dev/net/tun`, and the required sysctls from `docker-compose.yml`.

## Stop The Container

```sh
docker compose down
```
