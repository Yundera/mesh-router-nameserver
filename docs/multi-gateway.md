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
| NAT box answer | A NAT box is answered only by the gateways that can reach it: those whose tunnel subnet holds one of its `tunnelIp`s and whose local provider is up (`DNS_GATEWAY_TUNNELS`, option A of 2026-10-28; gateway-to-gateway forwarding was set aside). Only in a **live** user zone: dash names and dormant zones get every healthy gateway, hence the handoff below (2026-11-03). |
| Handoff | A gateway that cannot reach a NAT box hands the request to the gateway that can: directly when it has no route of its own, or as a retry when its own tunnel fails to connect. HTTPS between gateways, verified by the mesh CA against a per-gateway certificate (decided 2026-11-03, #947; option (a) + retry, mesh CA certificates). |
| Backend down | Each gateway keeps the last resolution (serve-stale, 24 h) and uses it while the backend cannot answer. Gateway 2 therefore outlives the backend's host for every name it has served recently. |
| NAT boxes | A **tunnel provider next to each gateway**; every box connects to all of them (dual-homed) and each gateway uses only its own host's provider (2026-10-28, replaces the first idea of gateway 2 peering with provider 1). |
| Boxes without `tunnelIp` | A NAT box on the legacy provider-HTTP path (old tunnel, no `tunnelIp`) matches no subnet, so it is answered by **every** healthy gateway (`pickForBox` in `GatewayHealth.ts`), yet only the gateway next to its own provider reaches it: with two gateways about half its requests fail. No code for it (decided 2026-11-02): no Yundera box is in that state; the owners of the three non-Yundera boxes on prod that are (old agent + tunnel) are asked to update before prod gets a second gateway. |
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
- Mesh CA on a volume (gateway 1.10.0, 2026-11-03): the CA from the last good fetch is
  kept in `GATEWAY_STATE_DIR` (`/var/lib/mesh-gateway`, a named volume), so a gateway
  *recreated* during a backend outage starts on it after 5 tries (~10–25 s) instead of
  exiting; without a stored copy it still waits 30 tries and exits. Staging: both gateways
  on 1.10.0 with the volume, stored-CA start checked on nasselle. The same volume will
  hold the gateway's own `*.<zone>` certificate.

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

### Gateway: handoff (`mesh-router-gateway` 1.11.0, backend 2.0.58)

Covers what the answers cannot: dash names (`<app>-<user>.<zone>`, answered by the parent
zone with every healthy gateway), boxes whose zone is dormant, a NAT box connected to one
provider only, and the seconds before the backend notices a dead provider.

- **Backend, `/resolve/v2`:** each tunnel route carries `gateway`, the gateway whose
  `DNS_GATEWAY_TUNNELS` subnet holds its `tunnelIp`; the routes of a provider that is down
  are dropped (unless that would drop every tagged one); `gatewayIps` lists the gateways
  (`routesForGateways` in `GatewayHealth.ts`).
- **Gateway, direct:** no route of its own (only routes through another host's provider) →
  the request goes to that route's `gateway`. `x-mesh-route: handoff,…`.
- **Gateway, retry:** its own tunnel route fails to connect (connect error or the 10 s
  connect timeout, before any byte reached the box) → the same, once, body included.
  `x-mesh-route: retry,handoff,…`. A failure after the connection opened stays an error.
- **The hop:** HTTPS to `<peer>:443` with SNI `<ip-dashed>.gw.<zone>`, verified against the
  mesh CA. Each gateway holds a certificate for that name (RSA, 30 days), signed by the
  backend on `POST /gateway-cert/<ip>` (`Authorization: Bearer <GATEWAY_CERT_TOKEN>`, `<ip>`
  must be in `DNS_GATEWAY_IPS`), kept in the state volume, renewed at 10 days left. `gw` is
  a reserved label: no box certificate can carry the name, and the TLS front terminates it
  (Traefik's `HostSNIRegexp` passthrough on nasselle carries it like any `*.<zone>` name).
- **Loops and client address:** the request carries `X-Mesh-Handoff: 1`, never handed on
  and never sent to a box. The receiver believes the sender's `X-Real-IP` /
  `X-Forwarded-For` only when the sender's address is in `gatewayIps`; boxes trust every
  gateway, so they read past the sender to the client.
- **Not covered:** boxes on the legacy provider-HTTP tunnel path (no `tunnelIp`, #936):
  their route names no provider.

Tested locally 2026-11-03 (two gateways, a mock backend, a mock box behind gateway 1's
"tunnel", gateway 2's tunnel dead): own route ok; retry 200 after the ~3 s failed
connect; direct handoff 200 in 70 ms; 3 MB POST through the retry intact; a client's own
`X-Mesh-Handoff` gets no handoff and no trust; a peer is verified by its gateway name only.

**Staging (2026-11-03, backend 2.0.58, gateway 1.11.0 on both).** `GATEWAY_CERT_TOKEN` in
the backend's `.env` and in a `.env` beside each gateway compose, `GATEWAY_PUBLIC_IP` per
gateway; each gateway got its certificate at start (gateway 1 presents it through Traefik's
passthrough). NAT drill on `competentleopon` again, provider 2 stopped ~100 s, the box's
dash name through each gateway every 5 s: **no failed request**. Through gateway 2:
`retry,handoff` for ~55 s (the first two 10 s, the connect timeout; then ~3 s, the failed
connect), then `handoff` in ~0.2 s once its cached routes expired (the backend dropped
provider 2's route 39 s after the stop), a short `retry,handoff` after the start while the
box's WireGuard reconnected, then its own tunnel again. Gateway 1 saw the handed-over
requests from 51.15.79.231 (trusted, in `gatewayIps`) with the client in
`X-Forwarded-For`, and served them over its own tunnel.

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

**Fleet rollout (2026-11-02/03).** Tunnel 1.5.2 is pinned on the mesh template's `main`
and `stable` channels (template 8a47288), so every box on the template connects to all
providers since its 03:00 run on 2026-11-03. Staging runs published images only: nss1
tunnel 1.5.2 + gateway 1.9.0, nasselle provider 1.5.2. Re-checked 2026-11-03: `/dns/health`
ok with both gateways and both providers up; wisera holds a tunnel route on each provider
(`10.78.0.6`, `10.79.0.2`); `files-wisera.inojob.com` with `X-Mesh-Force: tunnel` gives
`x-mesh-route: tunnel-routed` through each gateway; nss1 after the run: provider 122 MiB,
344 MB of 962 MB available, 4 peers with a handshake (25 before, mostly stale).

**Failover drill (2026-11-03, gateway 1.10.0, tunnel 1.5.2, backend 2.0.56).** Watched
every 5 s: both nameservers' answer for `files-wisera.inojob.com` (TTL 30) and a forced
tunnel request through each gateway (`curl --resolve`).

| Stopped (~90 s) | Detected | Effect | Recovered |
|---|---|---|---|
| gateway 2 (nss1) | DOWN 30 s after the stop | out of both secondaries' answers ≤ 3 s later; gateway 1 served throughout | UP 28 s after the start, back in the answers ≤ 4 s later |
| provider 2 (nss1) | DOWN 37 s after the stop | answers unchanged for wisera (public IP, as designed); gateway 2's forced tunnel timed out, then 502. NAT box: see below | UP 26 s after the start; gateway 2's tunnel path served again 41 s after the start (WireGuard reconnect) |
| backend (nasselle) | — | both gateways kept serving the name (`resolve_stale … backend_down_hold` / `status_503`); the secondaries kept answering | `/dns/health` ok ≤ 8 s after the start |

Notes: `/dns/health` is computed at most once a minute (`CACHE_MS`), so it can show a
state up to 60 s old (it still said gateway 2 down a minute after it was back); the
backend log (`[gateways] … DOWN/UP`) has the exact times.

**NAT box, provider 2 down (same day, 14:55).** Test box `competentleopon.inojob.com`
(185.194.219.222, fresh install, agent stopped so it is tunnel-only, `10.78.0.27` +
`10.79.0.6`; backend: "public IP —", zone **dormant**). Provider 2 DOWN 34 s after the stop
and the backend logged "NAT boxes not through 51.15.79.231", but the box's names kept
both gateways in their answer, and gateway 2 gave 502 for them until the provider was back
(~2 min). **Gap:** the per-box gateway set is only written into a *live* user zone.
Dash names (`<app>-<user>.<zone>`) are always answered by the parent zone with every
healthy gateway, and so is every name of a box whose zone is dormant (not delegated).
So a dead provider, or a NAT box connected to only one provider, fails about half of
its dash-name requests. The 2026-10-28 drill passed because wisera's zone is live and it
checked wisera's own name. Blocks G9 for prod (most boxes are not delegated, and dash
names are the main path after the cutoff); see Open points.

## Adding a gateway host

A gateway host runs a gateway and a tunnel provider side by side (nss1 on staging:
`/workspace/config/mesh-router/{gateway,tunnel}`, network `mesh-internal` 172.31.0.0/24).

- **Provider:** its own `VPN_IP_RANGE` (a subnet no other provider uses), WireGuard port
  published, `PROVIDER_API_TLS_PORT` (the gateway owns 80/443), `PROVIDER_ROUTE_IP` = its
  address on the shared network, `TUNNEL_FORWARD_FROM` = the gateway's address.
- **Gateway:** edge on 80/443, `BACKEND_URL` = the backend's public https URL,
  `GATEWAY_TLS_PORT=443`, `GATEWAY_FORWARDED_FOR=replace`, `TUNNEL_SUBNET` = the provider's
  range, `TUNNEL_VIA` = the provider's address, `NET_ADMIN`, and a volume on
  `/var/lib/mesh-gateway` (gateway ≥ 1.10.0: mesh CA kept across recreates).
  Handoff (gateway ≥ 1.11.0): `GATEWAY_PUBLIC_IP` = its address and `GATEWAY_CERT_TOKEN`,
  on **every** gateway (the one behind Traefik too); the backend sets the same
  `GATEWAY_CERT_TOKEN`.

Order:

1. Gateway and provider up; check through the gateway with `curl --resolve` (direct box,
   dot name passthrough, dash name, unknown name) before DNS knows it.
2. Backend: append the provider's URL to `TUNNEL_PROVIDERS`, the gateway's IP to
   `DNS_GATEWAY_IPS`, and `<gateway ip>=<range>=<provider url>` to `DNS_GATEWAY_TUNNELS`;
   recreate. Boxes on tunnel 1.5+ connect to the new provider within 5 min, and add the
   gateway to their PROXY allow list at their next zone tick (≤ 2 min) on mesh-router-caddy
   ≥ 1.5.2. Older images apply it only at an unrelated caddy-docker-proxy generation: it
   rebuilds only when the Caddyfile text it generates changes, and an `import` line never
   does (the "within 30 min" seen on staging 2026-10-28 was luck).
3. Failover drill: stop the gateway → `/dns/health` names it down and zones answer the
   others; stop the provider → it leaves NAT boxes' answers only; stop the backend → the
   gateway keeps serving names it has seen.

## Open points

- **`*.<zone>` certificate: one per gateway** (decided 2026-11-02, replaces the earlier
  "one shared certificate"). Each gateway orders its own by DNS-01 through our
  nameserver, so no private key travels between hosts and a gateway renews while the
  backend is down. Design in [`phase-1.1-gateway-tls.md`](phase-1.1-gateway-tls.md) §6;
  built once a zone we serve ourselves is available to test on (cutoff gate G6).
- **NAT boxes' dash names ignore the per-box gateway set** (found in the 2026-11-03
  drill, above; #947). Decided: handoff with retry and mesh CA gateway certificates
  (section above): gateway 1.11.0 and backend 2.0.58, live on staging 2026-11-03, NAT
  drill passed. Prod gets it with G9. Left: the first retries wait the 10 s connect timeout
  (WireGuard to a dead provider times out rather than failing fast).
- **Second prod gateway** (cutoff gate G9): gateway 2 + provider 2 on nsp1
  (51.15.79.11), deferred. Prod sets `TUNNEL_PROVIDERS` only then; boxes are already on
  tunnel 1.5.2.

Closed: usage (DAU) is reported by the boxes themselves (mesh-router-agent,
`POST /usage/:userid/:sig`), not by a gateway; the fleet runs the multi-provider requester
(tunnel 1.5.2, see the staging section).
