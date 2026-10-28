# Multi-gateway

> Started 2026-10-28. Extends [`architecture.md`](architecture.md) §6 ("two gateway
> instances on separate providers, both returned in the gateway answer") and §12.

## Goal

Resilience and redundancy at the gateway level: a second `mesh-router-gateway` on another
server, answered by DNS next to the first, so losing one gateway (process, host or
provider) leaves every gateway-routed name working.

## Decisions (2026-10-28)

| Topic | Decision |
|---|---|
| DNS | Every gateway answer lists all healthy gateways (`DNS_GATEWAY_IPS`, two `A`, TTL 30). The backend health-checks them and drops a dead one; none healthy = all listed. |
| Backend down | Each gateway keeps the last resolution (serve-stale, 24 h) and uses it while the backend cannot answer. Gateway 2 therefore outlives the backend's host for every name it has served recently. |
| NAT boxes | A **tunnel provider next to each gateway**; every box connects to all of them (dual-homed) and each gateway uses only its own host's provider (2026-10-28, replaces the first idea of gateway 2 peering with provider 1). Boxes on the legacy provider-HTTP path (no `tunnelIp`) are out of scope. |
| Provider discovery | The backend lists the extra providers in `/version` (`tunnelProviders`, from `TUNNEL_PROVIDERS`); the box's requester connects to each besides its own `PROVIDER`. Adding a provider = backend env, no template change. |
| Provider 2 API | Its own port with self-signed TLS (`PROVIDER_API_TLS_PORT`), since the gateway owns 80/443 on that host. |
| Edge | Gateway 2 is the edge on its host: no Traefik, `GATEWAY_TLS_PORT=443`, ports 80 + 443 published, `GATEWAY_FORWARDED_FOR=replace`. |
| First target | Staging (nasselle) first. |

## Components

### Gateway: serve-stale (`mesh-router-gateway`)

- Every resolution is also stored under `stale:` for `RESOLVE_STALE_TTL` seconds (default
  86400, `0` = off): the HTTP routes (`resolver.lua`) and the TLS passthrough decision
  (`sni_router.lua`).
- Used only when the backend cannot answer: transport error or 5xx. A 404 is an answer
  (unknown name) and never falls back. A stale answer is not re-cached as fresh, so the
  backend is asked again as soon as it is back.
- After a transport failure the backend is skipped for 30 s (`backend:down`), so requests
  don't each wait out the timeouts; the connect timeout is 2 s (TLS front 1 s). A 5xx is
  one name's problem and does not start the hold.
- A 5xx used to read as "not found" (landing page); it is now a 502, or the stale answer.
- Limit: the cache is in memory. A gateway restarted while the backend is down knows
  nothing until the backend is back.

### Backend: gateway health (`mesh-router-backend`, `GatewayHealth.ts`)

- Runs when user zones are on and `DNS_GATEWAY_IPS` lists at least two gateways.
- Every 15 s, one TLS handshake per gateway on `:443` with SNI `gateway.entrypoint.<zone>`
  (always terminated by the gateway itself, not verified): the same check whether the
  gateway is the edge or behind a TCP passthrough.
- Down after 2 failed checks in a row, up after 2 good ones; every gateway starts up.
- User zones answer the healthy set; a change triggers a zone pass at once (queued if one
  is running). `/version` `gatewayIps` keeps the **full** list: boxes trust every
  gateway's PROXY header, a gateway coming back must not be distrusted.
- The NAT-box probe goes through a healthy gateway.
- `/dns/health` gains `gateways[]`; a down gateway is a problem (`degraded`, HTTP 500), so
  the external monitor alerts.
- Failover time ≈ 30 s detection + zone write and NOTIFY/IXFR to the secondaries
  (seconds) + up to 30 s record TTL. Browsers already retry the other `A` on a refused
  or timed-out connect in the meantime.

### Tunnel: several providers per box (`mesh-router-tunnel`, `mesh-router-backend`)

- **Backend:** `TUNNEL_PROVIDERS=https://<host>:<port>[,…]` → `/version` `tunnelProviders`.
- **Requester (box):** reads the list from its backend every `ROUTE_REFRESH_INTERVAL` (a
  backend that can't answer keeps the current list) and connects to each provider, one
  WireGuard interface each (`wg_<host>`), one key pair each. The version check goes to the
  backend, not the provider. Providers start independently: one that is down retries on
  its own and no longer blocks the others; only a failure of the box's own `PROVIDER`
  still exits the container (51) as before.
- **One registration for all providers:** the backend keeps one route list per source
  and a POST replaces it, so the requester sends every connected provider's routes
  together (two per provider, one refresh loop). Stopping a provider re-registers the rest.
- **`tunnelIp` on both routes** (HTTPS and HTTP): the HTTPS route is served routed as
  before; on the HTTP route it only names the provider (by subnet).
- **Gateway:** a tunnel route whose `tunnelIp` lies outside its `TUNNEL_SUBNET` belongs to
  another host's provider and is never used. Each provider needs its own `VPN_IP_RANGE`
  (staging: nasselle `10.78.0.0/16`, nss1 `10.79.0.0/16`). **Rollout order: gateways
  first** — an older gateway would read another provider's routes as legacy HTTP routes.
- **Provider:** `PROVIDER_API_TLS_PORT` serves `/api/` over TLS (self-signed) on its own
  port; port 80 keeps serving the tunnels.

### Tunnel provider: gateway peers (`mesh-router-tunnel`, built, unused)

`TUNNEL_GATEWAY_PEERS=<wireguard public key>@<ip in VPN_IP_RANGE>[,…]`:

- each entry is pinned as a `wg0` peer named `gateway:<ip>` (persisted in `wg0.conf`),
  its address is never leased to a box, and a box already holding it blocks the peer
  (logged, never taken over);
- its address joins the forward sources (`MESH_FWD` tcp/443 into `wg0`, `MESH_NAT`
  masquerade to the provider's address, the only one boxes accept);
- an entry removed from the variable is removed from `wg0` at the next start.

Tested in containers (provider, a box peer, a gateway-2 sidecar, a client routed through
it): box `:443` reached; any other port and the provider itself refused; restart,
removal and re-add behave.

## Staging (2026-10-28)

| Host | What |
|---|---|
| nasselle 151.115.96.14 | backend `TUNNEL_PROVIDERS=https://51.15.79.231:8444`, `DNS_GATEWAY_IPS=151.115.96.14,51.15.79.231`; gateway 1 + provider 1 (`10.78/16`) |
| nss1 51.15.79.231 | `/workspace/config/mesh-router/{gateway,tunnel}`: gateway 2 (edge, 80/443) + provider 2 (`10.79/16`, WireGuard 51820/udp, API 8444), next to nameserver nss1 |
| wisera | requester on the new image: tunnels to both providers, four tunnel routes |

Verified: both gateways serve dash names, dot passthrough (box LE cert) and the routed
tunnel (`tunnel-routed`, each through its own provider); provider 2 down → gateway 1
unaffected, the box's tunnel container keeps running and reconnects; gateway 2 down →
out of a forced host's answer in 24 s, back 28 s after start; `/dns/health` names it.

Found on the way: the gateway's Lua HTTP client trusted only the mesh CA, so an https
`BACKEND_URL` (a gateway on another host) failed every lookup; it now trusts the public
roots + the mesh CA. And a `mesh-cli dns force|delegate` could be undone by the server's
next pass for up to ~5 min (cached scope in another process); the backend now reloads
its scope after any change (`dns:scope:changed` in Redis).

## Deploying gateway 2 with a peer link (superseded)

Kept for reference: gateway 2 reaching provider 1 over WireGuard instead of a local
provider.


On its own host (Docker, the `wireguard` kernel module present). Key pair first:
`wg genkey | tee wg.key | wg pubkey`. The public key goes into the provider's
`TUNNEL_GATEWAY_PEERS` as `<pub>@10.78.255.254`.

```yaml
# /workspace/config/mesh-router/gateway/docker-compose.yml (gateway 2)
networks:
  gw:
    ipam: {config: [{subnet: 172.31.0.0/24}]}
services:
  gateway:
    image: ghcr.io/yundera/mesh-router-gateway:<tag with serve-stale>
    restart: unless-stopped
    cap_add: [NET_ADMIN]                      # route 10.78/16 via the wg sidecar
    ports: ["80:80", "443:443"]
    environment:
      SERVER_DOMAIN: <zone>
      BACKEND_URL: https://<zone>/router/api  # the backend's public URL
      GATEWAY_TLS_PORT: "443"
      GATEWAY_FORWARDED_FOR: replace
      TUNNEL_SUBNET: 10.78.0.0/16
      TUNNEL_VIA: 172.31.0.3
      USAGE_INGEST_URL: ""                    # until /internal/usage/ingest is reachable from here
    networks: {gw: {ipv4_address: 172.31.0.2}}
  wg:
    image: alpine:3.20
    restart: unless-stopped
    cap_add: [NET_ADMIN]
    sysctls: {net.ipv4.ip_forward: "1"}
    volumes: ["./wg0.conf:/etc/wg/wg0.conf:ro"]
    command: >-
      sh -c "apk add -q --no-cache wireguard-tools iptables &&
      ip link add wg0 type wireguard && wg setconf wg0 /etc/wg/wg0.conf &&
      ip addr add 10.78.255.254/32 dev wg0 && ip link set wg0 up &&
      ip route add 10.78.0.0/16 dev wg0 &&
      iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE &&
      iptables -A INPUT -i wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT &&
      iptables -A INPUT -i wg0 -j DROP &&
      exec sleep infinity"
    networks: {gw: {ipv4_address: 172.31.0.3}}
```

```ini
# wg0.conf (wg setconf format: no Address line), mode 0600
[Interface]
PrivateKey = <wg.key>

[Peer]
PublicKey = <provider's wg0 public key: wg show wg0 public-key>
Endpoint = <provider VPN_ENDPOINT_ANNOUNCE>:<VPN_PORT>
AllowedIPs = 10.78.0.0/16
PersistentKeepalive = 25
```

Order:

1. Provider: add `TUNNEL_GATEWAY_PEERS`, recreate (boxes re-handshake within seconds).
2. Gateway 2 up; check through it with `curl --resolve` (direct box, NAT box, dot name
   passthrough, dash name, unknown name) before DNS knows it.
3. Backend: append its IP to `DNS_GATEWAY_IPS`, recreate. Boxes add it to their PROXY
   allow list within 30 min (until then they only lose the client address from it).
4. Failover drill: stop gateway 1 → `/dns/health` names it down, delegated zones answer
   gateway 2 only; start it → back in both. Stop the backend → gateway 2 keeps serving
   names it has seen.

## Open points

- **A NAT box is answered by gateways that can't reach it.** The gateway answer lists
  every healthy gateway, but a NAT box is reachable only through the gateways whose local
  provider it is connected to: today every box on an older requester (provider 1 only),
  and any box while provider 2 is down (the health check sees the gateway, not its
  provider). Half the clients then reach a gateway that can't serve the box; a connect
  succeeds, so browsers don't retry the other `A`. Proposal: per-user gateway set — map
  each gateway to its tunnel subnet (e.g. `DNS_GATEWAY_IPS=151.115.96.14=10.78.0.0/16,…`)
  and answer a NAT box only with the healthy gateways whose subnet holds one of its
  `tunnelIp`s (all of them when none does). Blocking before any NAT box is delegated
  with two gateways; staging is safe today (only wisera is delegated, and it is direct).
- **Shared `*.<zone>` certificate (brainstorm).** After the Cloudflare cutoff dash names
  and reserved labels terminate at the gateway with one `*.<zone>` certificate (Phase 1.1
  step 1). Decided: both gateways share **one** certificate. Open: who orders and holds
  it, and how each gateway gets it. Candidates to weigh: the backend orders it (DNS-01
  into its own zone, it already writes `_acme-challenge`) and serves it to gateways over
  an authenticated route; one gateway orders and the other pulls; an external store.
  Questions: key distribution and its auth, renewal and reload, what a gateway serves
  while the backend is down (it keeps the last one on disk).
- **Gateway start needs the backend:** the entrypoint fetches the mesh CA (60 s of
  retries, then exit). A restart keeps the previous file; a *recreate* during a backend
  outage fails. Fix: keep the CA on a volume.
- **Gateway peers** (`TUNNEL_GATEWAY_PEERS`) are built but unused with one provider per
  gateway host: keep as a fallback option, or remove.
- **Usage (DAU) ingest** from gateway 2: out of scope for now (`USAGE_INGEST_URL=""`).
- **Fleet:** boxes act on `tunnelProviders` only with the new requester (tunnel image
  bump + template pin); wisera runs it by hand until the 03:00 self-check reverts it.
