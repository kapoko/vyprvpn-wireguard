# Context

## Domain Terms

### VPN killswitch

The firewall and route policy that prevents normal traffic from leaving the container outside the WireGuard interface. Before connection it permits only setup traffic; after connection it permits normal traffic through WireGuard and only the WireGuard transport packet outside the tunnel.

### Command-running seam

The internal seam where runtime shell behavior reaches external commands such as `iptables`, `ip`, `wg`, `dig`, `curl`, and `vyprvpn-wireguard-go`. Production execution and test recording should vary here.
