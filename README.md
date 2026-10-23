# mesh-router-nameserver

Authoritative DNS server for the `nsl.sh` zone (and any other vanity zones Yundera
delegates to it). It answers `<user>.nsl.sh` / `*.<user>.nsl.sh` queries with a
**per-user policy decision**:

- if the user's PCS has been confirmed **direct-eligible** (public IPv4 + a real,
  browser-trusted TLS cert reachable on `:443`) → return an `A` record pointing
  **straight at the PCS public IP**;
- otherwise → return a `CNAME` to the **gateway** (Cloudflare Worker / OpenResty),
  exactly as traffic flows today.

This lets a user's connection **transparently upgrade** from "proxied through the
gateway" to "direct to my own box, on my own pretty domain, with a real
certificate", and silently **downgrade** back to the gateway if the box goes behind
NAT, loses reachability, or its cert lapses — with no change to the name the user
types.

> **Status: design / not yet implemented.** This repo currently contains only the
> design docs. See [`docs/architecture.md`](docs/architecture.md) for the full
> picture and [`implementation_notes.md`](implementation_notes.md) for the build plan
> mapped to concrete files in the rest of the mesh-router stack.

## Why this exists

Today users only ever type `app.john.nsl.sh`. That name is always served **through
the gateway** (CF Worker → `nip.io`, or OpenResty → PCS IP). The `*.sslip.io` /
`*.nip.io` names are ugly, IP-encoded **break-glass fallbacks** that nobody types.

A PCS with a public IPv4 is perfectly capable of serving its own apps directly with
a real Let's Encrypt certificate — in fact it **already does** for
`<dashed-ip>.sslip.io` via HTTP-01 (see `mesh-router-caddy/Caddyfile`). The only
missing piece is a nameserver that hands out the PCS's own IP for the **vanity**
`nsl.sh` name when (and only when) the box can actually serve it. That nameserver is
this service.

## What it does NOT do

- It is **not** stateless like sslip.io/nip.io. Those encode the IP in the hostname
  (`1-2-3-4.nsl.sh → 1.2.3.4`, pure pattern match). This service does a **per-user
  lookup**: `<user>.nsl.sh → that user's registered PCS IP`. Different problem.
- It holds **no state of its own**. Every answer is derived from the existing route
  store (Firestore `nsl-router` identity + Redis routes) read through the backend's
  `GET /resolve/v2/:user` API. Restarting it loses nothing.
- It does **not** terminate TLS, proxy traffic, or issue certs. It only answers DNS.

## Where it sits

```
                         ┌────────────────────────────┐
   DNS query             │   mesh-router-nameserver    │   HTTP
 *.nsl.sh  ───────────►  │   (this service, x2 for HA) │ ───────► mesh-router-backend
                         │   stateless DNS→HTTP adapter │   GET /router/api/resolve/v2/:user
                         └──────────────┬──────────────┘          (+ dnsDirect flag)
                                        │
              direct-eligible? ─────────┴───────── not eligible
                    │                                   │
            A  <PCS public IPv4>              CNAME  gw-edge.nsl.sh
            (low TTL, real LE cert)           (Cloudflare-proxied gateway)
```

## Companion changes (live in other repos)

This service is the only genuinely new daemon, but the feature needs small changes
elsewhere in `mesh-router-root` — all detailed in
[`implementation_notes.md`](implementation_notes.md):

| Repo / file | Change |
|---|---|
| `mesh-router-backend` — `Probe.ts`, `RouteValidator.ts`, `Routes.ts`, `RouterAPI.ts` | Compute & expose a `dnsDirect` eligibility flag in `/resolve/v2` (much of this already exists) |
| `mesh-router-caddy` — `Caddyfile`, `entrypoint.sh` | On-demand TLS for `*.nsl.sh` via real Let's Encrypt (mirror the existing sslip.io block) |
| `mesh-router-agent` | Report candidate public IPv4; host the on-demand TLS `ask` endpoint |
| DNS registrar + ops | Delegate `nsl.sh` NS to this service; submit `nsl.sh` to the **Public Suffix List** |

## Layout

```
mesh-router-nameserver/
├── README.md               ← you are here
├── Dockerfile              ← image: stock PowerDNS + the config below, ROLE=primary|secondary
├── image/
│   ├── entrypoint.sh       ← checks env per role, builds the secondary's local zones, starts pdns
│   ├── templates/          ← primary.j2, secondary.j2 (rendered by the stock startup)
│   └── lua/ipname.lua      ← gated ip.<zone> wildcard (sslip.io rule + allowlist lookup)
├── deploy/
│   ├── primary/            ← pdns-primary sidecar for the backend stack (compose fragment)
│   ├── secondary/          ← public nameserver: compose, colocated override, .env.example
│   └── *.yml, .env.example ← legacy ip.<zone> nameserver (sslip.io server), until prod switches
├── test/
│   ├── smoke/              ← CI: primary + secondary + gated answers + NOTIFY (`sh test/smoke/run.sh`)
│   └── ipname/             ← parity of ipname.lua with the sslip.io server
├── docs/
│   ├── architecture.md     ← resolution flow, eligibility, cert bootstrap, fallback tiers
│   ├── ip-names.md         ← stateless nip.io-style names (<app>-<ip>.ip.nsl.sh), CF test
│   └── ip-names-rollout.md ← staging record + prod cookbook for the ip.<zone> nameserver
└── implementation_notes.md ← build plan, file-by-file mapping, rollout order, open questions
```

## Image

`ghcr.io/yundera/mesh-router-nameserver`, published by `.github/workflows/docker.yml`:
`:main` on every push to `main`, `X.Y.Z` + `X.Y` on a `vX.Y.Z` tag, after the smoke
test passes. It is `powerdns/pdns-auth-51` (pinned by digest) with this repo's config
baked in, so a host carries only `docker-compose.yml` + `.env`: no scripts, no
templates, no Lua.

| `ROLE` | Required env | Optional |
|---|---|---|
| `primary` | `PDNS_AUTH_API_KEY`, `DNS_SOA_NS`, `DNS_SECONDARY_IPS` | — |
| `secondary` | `IP_ZONE`, `NS_HOSTS`, `SOA_RNAME`, `CATALOG_ZONE`, `PRIMARY_IP` | `PRIMARY_PORT` (53) |

A missing variable stops the container with its name. `TEMPLATE_FILES` still works
for an extra template mounted into `/etc/powerdns/templates.d/` (rendered after the
role's own).

## Quick links

- **Architecture & rationale** → [`docs/architecture.md`](docs/architecture.md)
- **Build plan & file mapping** → [`implementation_notes.md`](implementation_notes.md)
- Parent stack context → `../CLAUDE.md` (mesh-router-root), the resolvers
  (`mesh-router-gateway/nginx/lua/resolver.lua`,
  `mesh-router-gateway-cf/src/index.ts`), and the backend API
  (`https://nsl.sh/router/api/`).
