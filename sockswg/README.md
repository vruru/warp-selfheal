# sockswg

`sockswg` is the kernel-data-plane SOCKS mode in this repository:

```text
application -> 127.0.0.1:40000 (Dante or MicroSocks) -> sockswg interface
            -> kernel WireGuard/WARP -> Cloudflare
```

The manager converts `/etc/wireguard/proxy.conf` into a separate
`/etc/wireguard/sockswg.conf`. An explicit routing table and source rules apply
only to sockets bound to the WARP interface, so the host default route is not
changed. `sockswg` is deliberately IPv4-only: it never installs a WARP IPv6
address, `::/0`, or an IPv6 policy rule.

`sockswg-manager migrate` first starts the new stack on an unused temporary
port and requires a successful IPv4 Cloudflare trace result. It then
disables WireProxy and binds Dante to the original port. Failed cutovers restore
WireProxy automatically; successful cutovers retain its files for rollback.

The watchdog runs every 30 seconds and:

- immediately reconstructs a missing systemd service or `sockswg` interface;
- checks the WARP IPv4 data path;
- treats `warp=on` and `warp=plus` as healthy;
- rotates `2408`, `4500`, `500`, and `1701` after two consecutive failures.

Run `test_watchdog.sh` for the mocked lifecycle and failover regression tests.
Dante or MicroSocks is installed from the operating system package repository
and is not vendored in this repository. On Debian 13, where Dante is absent
from the official repository, MicroSocks runs as a dedicated system user and
an IPv4 bind address plus a UID policy rule prevent proxy traffic from leaking
to the host route. Pure IPv6 destinations are intentionally unsupported.
