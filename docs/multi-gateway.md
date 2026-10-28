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
| DNS | A gateway answer lists the healthy gateways (`DNS_GATEWAY_IPS`, two `A`, TTL 30). The backend health-checks them and drops a dead one; none healthy = all listed. |
| NAT box answer | A NAT box is answered only by the gateways that can reach it: those whose tunnel subnet holds one of its `tunnelIp`s and whose local provider is up (`DNS_GATEWAY_TUNNELS`, option A of 2026-10-28; gateway-to-gateway forwarding was set aside). |
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
- **Per-box gateway set.** `DNS_GATEWAY_TUNNELS` maps each gateway to the subnet of its
  local provider and that provider's API, e.g.
  `151.115.96.14=10.78.0.0/16=https://inojob.com,51.15.79.231=10.79.0.0/16=https://51.15.79.231:8444`.
  The same loop checks each provider (`GET <url>/api/ping`, same hysteresis). A box with a
  public IP gets every healthy gateway (each reaches it directly). A NAT box gets the
  healthy gateways whose subnet holds one of its `tunnelIp`s, preferring those whose
  provider is up; if all of those providers are down, the reaching ones; if no subnet
  matches (no mapping, offline, no `tunnelIp`), every healthy gateway. A box on an older
  requester (provider 1 only) is therefore answered by gateway 1 only.
- The provider check is needed because the box cannot see a dead provider: WireGuard keeps
  no connection, so the requester keeps registering the dead provider's route. A dead
  provider takes its gateway out of NAT boxes' answers only; boxes with a public IP keep it.
- The NAT-box probe goes through the first gateway of the box's set.
- `/dns/health` gains `gateways[]` (with `tunnel` when the provider is checked); a down
  gateway or provider is a problem (`degraded`, HTTP 500), so the external monitor alerts.
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

### Removed: gateway peers

The first plan had gateway 2 join provider 1's WireGuard network as a pinned peer
(`TUNNEL_GATEWAY_PEERS`, shipped dormant in tunnel 1.5.0). With a provider next to each
gateway and the per-box gateway set it had no use left, and it added an exception to the
provider firewall, so it was removed on 2026-10-28 (tunnel 1.5.1). It is in the git
history of `mesh-router-tunnel` if a gateway without a local provider is ever needed.

## Staging (2026-10-28)

| Host | What |
|---|---|
| nasselle 151.115.96.14 | `/workspace/config/mesh-router-inojob/` (renamed twice by another session on 2026-10-28). Backend `TUNNEL_PROVIDERS=https://51.15.79.231:8444`, `DNS_GATEWAY_IPS=151.115.96.14,51.15.79.231`, `DNS_GATEWAY_TUNNELS=151.115.96.14=10.78.0.0/16=https://inojob.com,51.15.79.231=10.79.0.0/16=https://51.15.79.231:8444`; gateway 1 + provider 1 (`10.78/16`) |
| nss1 51.15.79.231 | `/workspace/config/mesh-router/{gateway,tunnel}`: gateway 2 (edge, 80/443) + provider 2 (`10.79/16`, WireGuard 51820/udp, API 8444), next to nameserver nss1 |
| wisera | requester on the new image: tunnels to both providers, four tunnel routes |

Verified: both gateways serve dash names, dot passthrough (box LE cert) and the routed
tunnel (`tunnel-routed`, each through its own provider); provider 2 down → gateway 1
unaffected, the box's tunnel container keeps running and reconnects; gateway 2 down →
out of a forced host's answer in 24 s, back 28 s after start; `/dns/health` names it.

Per-box gateway set, drilled with wisera made a NAT box (agent stopped, its route
dropped): connected to both providers → both gateways answered; provider 2 stopped → out of
wisera's answer 28 s later, `/dns/health` degraded and naming it; provider 2 started →
back 30 s later and gateway 2 serving again; wisera on the old requester (provider 1
only) → gateway 1 only. wisera restored afterwards (dual-homed, agent running).

Found on the way: the gateway's Lua HTTP client trusted only the mesh CA, so an https
`BACKEND_URL` (a gateway on another host) failed every lookup; it now trusts the public
roots + the mesh CA. And a `mesh-cli dns force|delegate` could be undone by the server's
next pass for up to ~5 min (cached scope in another process); the backend now reloads
its scope after any change (`dns:scope:changed` in Redis).

## Adding a gateway host

A gateway host runs a gateway and a tunnel provider side by side (nss1 on staging:
`/workspace/config/mesh-router/{gateway,tunnel}`, network `mesh-internal` 172.31.0.0/24).

- **Provider:** its own `VPN_IP_RANGE` (a subnet no other provider uses), WireGuard port
  published, `PROVIDER_API_TLS_PORT` (the gateway owns 80/443), `PROVIDER_ROUTE_IP` = its
  address on the shared network, `TUNNEL_FORWARD_FROM` = the gateway's address.
- **Gateway:** edge on 80/443, `BACKEND_URL` = the backend's public https URL,
  `GATEWAY_TLS_PORT=443`, `GATEWAY_FORWARDED_FOR=replace`, `TUNNEL_SUBNET` = the provider's
  range, `TUNNEL_VIA` = the provider's address, `NET_ADMIN`, `USAGE_INGEST_URL=""`.

Order:

1. Gateway and provider up; check through the gateway with `curl --resolve` (direct box,
   dot name passthrough, dash name, unknown name) before DNS knows it.
2. Backend: append the provider's URL to `TUNNEL_PROVIDERS`, the gateway's IP to
   `DNS_GATEWAY_IPS`, and `<gateway ip>=<range>=<provider url>` to `DNS_GATEWAY_TUNNELS`;
   recreate. Boxes on tunnel 1.5+ connect to the new provider within 5 min, and add the
   gateway to their PROXY allow list within 30 min.
3. Failover drill: stop the gateway → `/dns/health` names it down and zones answer the
   others; stop the provider → it leaves NAT boxes' answers only; stop the backend → the
   gateway keeps serving names it has seen.

## Open points

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
- **Usage (DAU) ingest** from gateway 2: out of scope for now (`USAGE_INGEST_URL=""`).
- **Fleet:** boxes act on `tunnelProviders` only with the new requester (tunnel image
  bump + template pin); wisera runs it by hand until the 03:00 self-check reverts it.
