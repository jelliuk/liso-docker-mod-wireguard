# liso-docker-mod-wireguard

A Docker Mod for [linuxserver/wireguard](https://github.com/linuxserver/docker-wireguard) that adds NordVPN conf rotation + health monitoring.

## How it works
- Put one or more NordVPN WireGuard files (`ch368-nordvpn.conf`, `uk2-nordvpn.conf`, ...) in the directory mounted at `/nordvpn`. Files are tried in alphabetical order. Anything without `[Interface]` and `[Peer]` sections is ignored.
- The mode turns on automatically when `/nordvpn` holds `*.conf` files and `PEERS` is unset. Force it with `NORDVPN_ENABLED=true|false`.
- `svc-mod-wireguard-nordvpn` connects, then every `NORDVPN_CHECK_INTERVAL` seconds (default 3600) checks that the interface exists, a recent handshake is present and a request through the tunnel succeeds. On failure it reconnects with the same conf; if that fails it moves to the next conf (wrapping around). If nothing works it waits `NORDVPN_RETRY_DELAY` seconds and starts another pass.
- New or removed conf files are picked up at the next check. The last working conf is saved in `/config/nordvpn/last_conf` and tried first after a restart.
- A kill switch (iptables) blocks all egress except the tunnel, loopback, `NET_LOCAL`, the docker subnet and the WireGuard handshake to the endpoints. Containers sharing the network namespace (`network_mode: service:...`) are covered.
- The healthcheck (`/app/nordvpn-healthcheck`, declared in compose) is healthy only while the tunnel is connected and passing traffic, so `depends_on: condition: service_healthy` works. Inspect with (use your container name) `docker exec CONTAINER cat /run/nordvpn/status`.

## Variables
| Variable | Default | Meaning |
|---|---|---|
| `NORDVPN_ENABLED` | `auto` | `true`, `false` or `auto` |
| `NORDVPN_CHECK_INTERVAL` | `3600` | seconds between health checks |
| `NORDVPN_RETRY_DELAY` | `30` | wait after a full failed pass |
| `NORDVPN_CONNECT_TIMEOUT` | `30` | seconds to wait for a handshake |
| `NORDVPN_CHECK_TIMEOUT` / `NORDVPN_CHECK_RETRIES` | `10` / `3` | per-request timeout / attempts |
| `NORDVPN_MAX_HANDSHAKE_AGE` | `180` | max handshake age (s) for "healthy" |
| `NORDVPN_CHECK_URLS` | NordVPN insights + 1.1.1.1 trace | probed through the tunnel |
| `NORDVPN_KILLSWITCH` | `true` | block non-VPN egress |
| `NORDVPN_BOOTSTRAP_DNS` | `true` | allow port 53 while the tunnel is down (resolves Endpoint hostnames) |
| `NORDVPN_START_FROM_LAST` | `true` | resume with last working conf |
| `NET_LOCAL` | | LAN CIDRs routed outside the tunnel (comma/space separated) |

## Install Process
1. Use `lscr.io/linuxserver/wireguard`
2. Set `DOCKER_MODS=ghcr.io/jelliuk/liso-docker-mod-wireguard:latest`
3. Put one or more NordVPN WireGuard files (`ch368-nordvpn.conf`, `uk2-nordvpn.conf`, ...) in the directory mounted at `/nordvpn`.
   Each NordVPN conf contains a private key: mount in your container `/nordvpn` as read-only and keep it out of publicly accessible locations, etc.
4. Include Healthcheck in your `docker-compose.yml` if you wish, this cannot be implemented via the mod environment variable alone.

```
      healthcheck: # a mod cannot ship a HEALTHCHECK, so it is declared here
      test: ["CMD", "/app/nordvpn-healthcheck"]
      interval: 30s
      timeout: 15s
      start_period: 120s
      retries: 3
```

### Example Docker Compose
```
services:
  wireguard-nord:
    image: lscr.io/linuxserver/wireguard:latest
    container_name: wireguard-nord
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "/app/nordvpn-healthcheck"]
      interval: 30s
      timeout: 15s
      start_period: 120s
      retries: 3
    cap_add:
      - NET_ADMIN # required
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1 # required
      - net.ipv6.conf.all.disable_ipv6=1 # recommended
    networks:
      # Define your network here
    ports:
      # Include your ports here
    volumes:
      - ./nordvpn:/nordvpn:ro
      - ./config:/config
    environment:
      # Define any environment variables here
      - DOCKER_MODS=ghcr.io/jelliuk/docker-mod-wireguard-nordvpn:latest
```

### Why these settings?
Container requirements and recommendations: `NET_ADMIN`, `net.ipv4.conf.all.src_valid_mark=1` and `net.ipv6.conf.all.disable_ipv6=1`.

| Setting | Why |
|---|---|
| `cap_add: NET_ADMIN` | **Required.** Docker drops this capability by default. WireGuard needs it to create the tunnel interface, set routes and apply the kill-switch firewall rules. |
| `net.ipv4.conf.all.src_valid_mark=1` | **Required.** With a full tunnel (`AllowedIPs = 0.0.0.0/0`), `wg-quick` marks WireGuard's own packets so they bypass the tunnel. This sysctl lets the kernel accept replies to those marked packets. `wg-quick` can't set it from inside a container (`/proc/sys` is read-only), so it must be set here. |
| `net.ipv6.conf.all.disable_ipv6=1` | **Recommended.** NordVPN's configs tunnel IPv4 only, so IPv6 traffic would bypass the VPN and expose your real IP. Disabling IPv6 closes that leak. |

## Maintenance Note
An init script (`init-mod-wireguard-nordvpn-guard`) patches `svc-wireguard/run` at startup so the stock service steps aside in NordVPN mode (it would otherwise delete the default route). If upstream changes that file and the anchor line is missing, the container log says so.