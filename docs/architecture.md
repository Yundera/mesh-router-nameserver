# Architecture — mesh-router-nameserver

> Design document, decided 2026-10-22. Nothing in this document is built yet except
> the `ip.<zone>` nameserver it grows out of ([`ip-names.md`](ip-names.md), live on
> staging and prod). It replaces the June 2026 design (per-user `dnsDirect` flag,
> Cloudflare kept in front); §14 records what changed and why.

## 1. Goal

The nameserver becomes **authoritative for the whole server zone** (`nsl.sh` on prod,
`inojob.com` on staging), and **Cloudflare leaves the platform entirely**: no
Cloudflare DNS, no Cloudflare proxy, no Worker, no Email Routing.

For every hostname a user can reach, the nameserver answers **one of two addresses**:

- the **box's public IP**, when the box can serve that exact name itself with a
  browser-trusted certificate;
- the **gateway's IP** otherwise, and in every case of doubt.

The decision is taken **per hostname**, not per user: one app can already have its
Let's Encrypt certificate while another is still waiting for it. The name the user
types never changes; only what it resolves to.

Behind the gateway nothing changes conceptually: it routes each request to the box
over the box's best route, the public IP (`<app>-<ip>.ip.<zone>`, mesh-CA cert) or the
WireGuard tunnel.

```
                     DNS: A? immich.john.nsl.sh
                                │
                   ┌────────────▼─────────────┐
                   │  mesh-router-nameserver  │  ◄── host state (backend)
                   │  static zone + dynamic   │  ◄── TXT challenges (backend)
                   └────────────┬─────────────┘
                 direct ?       │        otherwise / in doubt
              ┌─────────────────┴───────────────────┐
              ▼                                     ▼
       A <box public IP>                     A <gateway IP>
              │                                     │
              ▼                              ┌──────▼───────┐
   box Caddy, trusted cert                   │   gateway    │ SNI passthrough if the
   for immich.john.nsl.sh                    │ (our edge)   │ box has a trusted cert,
                                             └──────┬───────┘ else terminate TLS
                                        ┌───────────┴───────────┐
                                        ▼                       ▼
                             box public IP (ip route)     WireGuard tunnel
```

## 2. Decisions

| Topic | Decision |
|---|---|
| Zone ownership | The nameserver serves the entire zone, apex included. Registrar NS records point at it. |
| Cloudflare | Dropped entirely. The Worker cannot survive: it runs only on proxied traffic, and proxying needs Cloudflare to be authoritative for the name (the route `*.nsl.sh/*` is bound to the Cloudflare zone). |
| Gateway | `mesh-router-gateway` becomes the public edge (≥2 instances). SNI passthrough first, TLS termination as fallback (§6). |
| DNS answers | Two only: box IP or gateway IP. Tunnel vs IP route is the gateway's business, never DNS's. |
| Granularity | Per hostname, with a per-hostname force override (§4.3). |
| Certificates | One workflow, two challenge types: **DNS-01 wildcard by default** when the box's ACME client supports it, **HTTP-01 per name** otherwise (§7). |
| DNS-01 API | The backend implements the **acme-dns API**, so Caddy (`caddy-dns/acmedns`), lego, certbot and acme.sh all work unchanged. |
| Box Caddy | `mesh-router-caddy` moves from the stock `caddy-docker-proxy:ci-alpine` image (unpinned) to an xcaddy build with `caddy-docker-proxy` + `caddy-dns/acmedns`, pinned. |
| IP names | `<app>-<dashed-ip>.ip.<zone>` stays, permanently (§3.3). `nip.io` is removed; `sslip.io` stays as the break-glass fallback. |
| Public Suffix List | `nsl.sh` submission in progress. |
| Migration | Users move one at a time through per-user NS delegation while Cloudflare keeps the zone (§13.1). Staging first, wisera as test user. |
| Mail | Outbound SendGrid records move with the zone and must exist from minute one. The inbound contact alias moves to another domain or a forwarding service (§9). |

## 3. Names in the zone

### 3.1 User names

| Shape | Example | Status |
|---|---|---|
| user apex | `john.nsl.sh` | kept |
| dash form | `immich-john.nsl.sh` | **today's canonical form**, kept as a legacy alias |
| dot form | `immich.john.nsl.sh` | **becomes canonical** |

The dash form exists only because Cloudflare's Universal SSL covers one label under
the zone. With Cloudflare gone that constraint goes too, and the dot form is the only
shape a per-user wildcard can cover: `*.john.nsl.sh` matches `immich.john.nsl.sh`, but
nothing short of `*.nsl.sh` matches `immich-john.nsl.sh`. Both resolvers (gateway
`resolver.lua`, this nameserver) already accept both forms (the user is the right-most
label, or the right-most dash segment of a single label).

Consequences:

- A box on a DNS-01 wildcard serves **dot-form names directly** and the dash-form
  aliases through the gateway (or with per-name HTTP-01 certs, §7.4).
- Maison's renderer (router-neutral routing) and the mesh template's managed domains
  switch `APP_DOMAIN` routes to the dot form; the dash form keeps being rendered
  until the fleet has moved and existing bookmarks have had time to fade.
- Usernames must not contain dashes (already implied by the dash-form parser) nor
  match a reserved label (§3.4).

### 3.2 PSL interaction

With `nsl.sh` on the Public Suffix List, the registrable domain of `immich.john.nsl.sh`
is `john.nsl.sh`: rate limits and cookies are **per user**. In dash form each
`immich-john.nsl.sh` is its own registrable domain: rate limits per app (fine), but no
cookie can be shared between a user's apps, and **any cookie set today with
`Domain=nsl.sh` stops working**. That has to be checked before the PSL entry lands.

### 3.3 IP-encoded names

`<app>-<dashed-ip>.ip.<zone>` keeps its `ip.` label. Flattening it into the zone
(`<app>-1-2-3-4.nsl.sh`) was considered and rejected:

- it shares the user namespace: the dash-form parser would read user `4`, and signup
  would have to forbid dashed-IP-shaped names;
- boxes carry a mesh-CA cert with `CERT_EXTRA_SANS=*.ip.<zone>`; flattened it would
  have to be `*.nsl.sh`, valid for every user's names;
- `ip.nsl.sh` can get its own PSL entry, like `sslip.io`.

These names are answered statelessly (the IP is in the name), exactly as the sslip.io
server does today.

### 3.4 Reserved labels

Signup and the nameserver share one reserved list: `ip`, `ns1`…`nsN`, `gw`/`gw1`…,
`www`, `mail`, `acme`, `_acme-challenge`, `_dmarc`, `_domainkey`, `s1`, `s2`, `router`,
plus every label present in the static zone (§9). Existing users are audited against
it before delegation.

### 3.5 Static records

Everything that is not a user or IP name (apex, verification TXT, mail records, NS
glue, the backend's hostname) lives in a **versioned zone file in git**, reviewed like
code. §9 has the inventory.

## 4. The answer rule

### 4.1 Per-host state

The backend keeps one record per hostname a box has asked to serve:

```jsonc
{
  "name": "immich.john.nsl.sh",
  "user": "john",
  "path": "ip",                       // ip | tunnel — best route behind the gateway
  "publicIp": "203.0.113.10",         // null behind NAT
  "cert": {
    "state": "trusted",               // none | mesh-ca | trusted
    "method": "dns-01",               // dns-01 | http-01
    "covers": "*.john.nsl.sh",
    "notAfter": "2027-01-20T00:00:00Z"
  },
  "lastProbe": "2026-10-22T14:02:11Z",
  "probeOk": true,
  "force": "auto",                    // auto | gateway | direct
  "answer": "direct",                 // direct | gateway — what the nameserver serves
  "reason": "trusted cert verified on 203.0.113.10:443"
}
```

The host list comes from the box's route registration (`POST /routes/:userid/:sig`
gains the list of hostnames it serves), so the backend knows which names exist without
guessing from DNS queries.

### 4.2 Rule

```
answer = direct   iff  force != gateway
                  and  publicIp != null
                  and  cert.state == trusted  (covers name, notAfter > now + margin)
                  and  probeOk               (verified by the backend, §5)
                  and  routes fresh          (within the Redis route TTL)
           or      force == direct           (admin only, §4.3)
answer = gateway  otherwise
```

Unknown names under a known user answer gateway (the gateway shows the landing page or
the box's own 404). Unknown users answer gateway too, so a freshly created user works
before its first registration; NXDOMAIN only for names that can never exist (reserved
labels with no static record, malformed IP names).

### 4.3 Force

| Value | Who | Effect |
|---|---|---|
| `auto` | default | §4.2 |
| `gateway` | user (dashboard) or admin (`mesh-cli`) | Always the gateway, e.g. when the user's ISP breaks direct access. Always safe. |
| `direct` | admin only (`mesh-cli`, with a warning) | Box IP even if checks fail. Breaks the site if the box cannot serve the name. For debugging. |

Settable per hostname or per user (applies to all its names). The mesh dashboard
shows the state above and lets the owner pick `gateway` or `auto`. Every admin action
(`direct`, delegation, inspection) goes through `mesh-cli` in the backend container,
never the dashboard, so there is no admin role to build.

## 5. Where the decision comes from

**A DNS server cannot see TLS, certificates or HTTP at query time**, so the decision is
precomputed by the backend and the nameserver only reads it. And **the box's own
report is never trusted**: the backend checks it from the outside.

| Signal | How it is checked |
|---|---|
| public IP | `Probe.ts` candidate filter (`isLanOrReserved`) on the registered route |
| reachable | TCP `:443` from the backend's vantage point (ICMP is not enough) |
| trusted cert | TLS handshake to `publicIp:443` with **SNI = the hostname**, validated against the **system** CA (`RouteValidator.ts` already races system vs mesh CA) |
| fresh | route TTL (`routesTtl` in `/resolve/v2`) |

Probe cadence: on registration, on a cert change reported by the box (a hint that
triggers a probe, never a verdict), then every few hours and shortly before
`notAfter`. One probe covers every name of a wildcard (one handshake per wildcard,
plus a spot check of one dash-form name if any).

## 6. The gateway as the edge

Without Cloudflare the gateway is the public entry point for every name that is not
direct. It does three things, in this order:

1. **ACME challenge forwarding.** `GET /.well-known/acme-challenge/<token>` on `:80`:
   if the token is one of the gateway's own pending challenges, answer it; otherwise
   forward the request to the box with the original `Host` (Caddy matches challenges
   by Host). This is what lets a box pass HTTP-01 **before** DNS points at it, even
   behind NAT (§7.4).
2. **SNI passthrough.** If the host state says the box holds a trusted cert for the
   SNI name, the gateway forwards the raw TLS stream (OpenResty `stream` +
   `ssl_preread`) over the box's route, IP or tunnel. TLS ends on the user's box: the
   gateway cannot read the traffic.
3. **Termination fallback.** Otherwise the gateway terminates TLS with its own
   certificate and proxies to the box as today (`<app>-<ip>.ip.<zone>` with the mesh
   CA, or the tunnel).

Gateway certificates, all via DNS-01 against our own nameserver:

- `*.nsl.sh`: covers every dash-form name and every user apex in one cert;
- `*.<user>.nsl.sh`: issued on demand for dot-form names of users whose box has no
  trusted cert yet (and renewed only while needed).

What Cloudflare gave us for free and the gateway now owns: DDoS absorption, edge
presence, HTTP/3. Minimum: two gateway instances on separate providers, both returned
in the gateway answer (two `A` records), connection and request rate limits, and a
flood runbook.

## 7. Certificates

### 7.1 One workflow, two challenges

```
box ACME client wants a cert
 ├─ DNS-01 (default):  *.john.nsl.sh + john.nsl.sh
 │    box → backend acme-dns API: update TXT _acme-challenge.john.nsl.sh
 │    backend: credentials ⇒ user john; name under john? ⇒ store TXT (TTL 60s)
 │    nameserver serves the TXT → Let's Encrypt validates → wildcard issued
 │
 └─ HTTP-01 (fallback): immich-john.nsl.sh, or any name on a client without acme-dns
      Let's Encrypt resolves the name → gateway (default answer) or box (if direct)
      gateway forwards /.well-known/acme-challenge/* to the box (§6)
      → cert issued while DNS still points at the gateway
              │
              ▼
backend probe (§5) sees a system-CA-valid cert → host state cert=trusted
              ▼
nameserver switches the covered names to direct (if public IP and not forced)
```

The method used is recorded but changes nothing downstream: the nameserver, gateway
and dashboard only look at `cert.state`.

### 7.2 DNS-01: the acme-dns API

The backend implements the [acme-dns](https://github.com/joohoi/acme-dns) HTTP API, so
no client needs anything custom:

| acme-dns | Our mapping |
|---|---|
| `POST /update`, headers `X-Api-User` / `X-Api-Key` | user id / the box's existing Ed25519 signature over its user id (the same credential as `POST /routes/:userid/:sig` and the mail relay's provider string) |
| body `subdomain` | the user's domain label (`john`), checked against the credential |
| body `txt` | the 43-character challenge value |
| `POST /register` | not exposed: every box is already registered by its user id |

Rules:

- A credential can only set `_acme-challenge.<user>.<zone>` for **its own user**.
  Nothing else: no other names, no other record types.
- At most two TXT values per name (acme-dns semantics: the wildcard and the apex
  validate in the same order), **TTL 60 s**, deleted automatically after 10 minutes.
- Rate limit per user (a few updates per hour is plenty: an order every ~60 days).
- No CNAME delegation is needed (acme-dns normally asks for
  `_acme-challenge.<name> CNAME <uuid>.auth.example`); our nameserver answers the TXT
  for the real name directly.

Since the credential is the box's provider signature, any FOSS box registered with the
backend can use it, Yundera-managed or not.

The gateway is not a user, so it gets a second door onto the same challenge store:
lego's `httpreq` protocol (`POST /present` and `/cleanup` with `{fqdn, value}`),
authenticated with the backend's service key and limited to
`_acme-challenge.<user>.<zone>` of delegated users. Traefik (lego) and any lego-based
client use it as is.

### 7.3 Box Caddy

`mesh-router-caddy` becomes a two-stage build:

```dockerfile
FROM caddy:<pinned>-builder-alpine AS build
RUN xcaddy build \
      --with github.com/lucaslorentz/caddy-docker-proxy/v2@<pinned> \
      --with github.com/caddy-dns/acmedns@<pinned>
FROM caddy:<pinned>-alpine
COPY --from=build /usr/bin/caddy /usr/bin/caddy
# … entrypoint, Caddyfile as today, with CMD ["docker-proxy"]
```

The Caddyfile gains a site block for `*.{$DOMAIN}, {$DOMAIN}` using
`tls { dns acmedns … }` with the credentials from the mesh `.env`. The existing
on-demand catch-all (mesh CA) stays for IP names and for anything not covered.
Pinning the base image also fixes today's unpinned `ci-alpine` tag.

### 7.4 HTTP-01

Used for dash-form aliases on a direct box, and for boxes whose ACME client has no
acme-dns support. Caddy on-demand TLS with **real Let's Encrypt** for the user's names,
gated by the `ask` endpoint (the box only asks for names under its own user). Because
the gateway forwards challenges, issuance works whatever DNS currently answers,
including behind NAT. A NAT box gets no direct answer anyway, but with a trusted cert
the gateway can pass its TLS through (§6) instead of terminating it.

### 7.5 Rate limits

Let's Encrypt allows 50 new certificates per registered domain per week. Until `nsl.sh`
is on the PSL every user shares that bucket:

- DNS-01 wildcard: one order per user per renewal cycle. A fleet of a few hundred
  boxes fits if the first issuance is spread over a few weeks (stagger by a hash of
  the user id) and renewals are spread naturally.
- HTTP-01 per name: one order per app per user. This is what needs the PSL, so it
  stays limited to aliases and third-party boxes until the entry lands.
- Renewals of the same set of names are exempt from the new-certificates limit.

## 8. Upgrade and downgrade

```
box registers routes + hostnames
        │
        ▼
gateway answer (default) ──► box obtains cert (DNS-01, or HTTP-01 through the gateway)
        │                              │
        │                     backend probe: system-CA TLS ok on publicIp:443?
        │                       │ no                    │ yes
        │                       ▼                       ▼
        │               stays gateway           answer = direct  (within TTL 30 s)
        │                                               │
        └──────── downgrade ◄── route expires / IP changes / probe fails /
                               cert near expiry / force=gateway
```

- **A failed upgrade is invisible**: the name keeps resolving to the gateway.
- **Downgrade is safe by construction**: the gateway can always serve the name.
- **TTL is the seam**: dynamic answers use TTL 30 s; static records keep normal TTLs.

## 9. Static zone and mail

### 9.1 Inventory

Taken from public DNS on 2026-10-22. The zone has a **`*.nsl.sh` wildcard**, so public
lookups cannot list every record: the complete inventory comes from a Cloudflare zone
export, which becomes the first version of the git zone file.

| Name | Type | Value | Purpose | After the move |
|---|---|---|---|---|
| `nsl.sh` | A / AAAA | Cloudflare proxy | backend + landing (`nsl.sh/router/api`) | `A` to the server-tier ingress (yundera-prod Traefik) |
| `nsl.sh` | TXT | `google-site-verification=…` | Google | copy |
| `nsl.sh` | MX ×3 | `route{1,2,3}.mx.cloudflare.net` | Cloudflare Email Routing, contact alias | replaced (§9.2) |
| `nsl.sh` | TXT | `v=spf1 include:_spf.mx.cloudflare.net ~all` | SPF | rewritten (§9.2) |
| `cf2024-1._domainkey` | TXT | DKIM key | Email Routing forwarding | dropped with Email Routing |
| `s1._domainkey`, `s2._domainkey` | CNAME | `s{1,2}.domainkey.u49916735.wl236.sendgrid.net` | **SendGrid DKIM for app mail** | **copy, verified before delegation** |
| `_dmarc` | TXT | `v=DMARC1; p=none;` | DMARC | copy |
| `ns1-ip`, `ip` | A / NS | yundera-prod | `ip.nsl.sh` delegation | absorbed: the nameserver answers `ip.` itself |
| `*` | A | Cloudflare proxy | every user name | replaced by dynamic answers |

### 9.2 Mail

- **Outbound (critical).** Every box sends app mail as `<app>.<user>@nsl.sh` through
  `mail-gateway` → backend `/email/send` → SendGrid
  (`mesh-router-backend/src/services/Email.ts`). DMARC passes on SendGrid's DKIM
  (`s1/s2._domainkey`) alone, since SPF lists only Cloudflare. Those CNAMEs (and any
  SendGrid link-branding records the export reveals) must resolve from our nameserver
  before the registrar switch; verify with SendGrid's domain-authentication check on
  staging first. Rewrite SPF to `v=spf1 include:sendgrid.net ~all` at the same time.
- **Inbound (not critical).** The contact alias moves to another domain, or the MX
  records point at a forwarding service. Either way the Cloudflare MX, SPF include and
  `cf2024-1` DKIM go away.

## 10. The nameserver itself

### 10.1 What it serves

| Query | Source |
|---|---|
| SOA, NS, static records | zone file (git) |
| user names (§3.1) | host state from the backend, §4.2 |
| `<app>-<ip>.ip.<zone>` | computed from the name |
| `_acme-challenge.<user>.<zone>` TXT | backend challenge store |
| anything else | NXDOMAIN with SOA |

The sslip.io server running today for `ip.<zone>` covers only one row. The target is a
single service covering all of them. Candidates:

- **Own Go service on `miekg/dns`**: fits the rest of the stack, full control over
  caching and fail-safe behaviour; DNSSEC would be our work.
- **PowerDNS Authoritative** (bind backend for the zone file, remote/HTTP backend for
  dynamic names): online DNSSEC signing for free, one more moving part.

The zone has no DNSSEC today (no DS at the registrar), so it is not a launch blocker;
pick with DNSSEC as a later step in mind.

### 10.2 Availability

Once the apex is ours, a nameserver outage takes down the backend API and outbound
mail as well as every app. Requirements:

- **≥2 instances on different providers/networks**, both in the registrar NS set. Prod
  runs one today (yundera-prod); the second host is still to be chosen.
- Zone transfer cannot replicate dynamic answers, so **each instance has its own
  backend client** with a serve-stale cache: last known answer, else gateway.
- **Never block the DNS path on the backend.** Lookups are asynchronous with a short
  timeout; the cache answers meanwhile.
- Abuse: response rate limiting, negative caching, and no backend lookup at all for
  names that cannot exist. Random-subdomain floods under a real user hit the cache.

### 10.3 IPv4 only

Direct answers are `A` only, as before. `AAAA` for boxes with public IPv6 is a later
extension; it needs the same probe on v6.

## 11. Components

| Component | Change |
|---|---|
| **mesh-router-nameserver** | Grows from the sslip.io server for `ip.<zone>` to the whole zone: static file, dynamic names, IP names, challenge TXT (§10). |
| **mesh-router-backend** | Per-host state + probes (§4, §5); hostnames in route registration; acme-dns API + challenge store (§7.2); force overrides; `mesh-cli dns` admin commands; reserved labels at signup (§3.4). |
| **mesh-router-gateway** | Public edge: ACME forwarding, SNI passthrough, termination fallback with DNS-01 certs, rate limits, ≥2 instances (§6). |
| **mesh-router-caddy** | Pinned xcaddy build with `caddy-dns/acmedns`; wildcard site block; entrypoint passes the user zone SNIs through instead of pinning cert0 (C3); real-LE on-demand for HTTP-01 names (§7.3, §7.4). |
| **mesh-router-agent** | Sends hostnames with route registration; hints the backend on cert change. |
| **Maison + mesh template** | Dot-form routes canonical, dash form as alias; nip.io routes no longer rendered. |
| **mesh-dashboard** | Per-host state table and the owner's `gateway`/`auto` toggle (§4.3). |
| **mesh-router-gateway-cf** | Retired. |
| **Ops** | Zone export → git; mail moves (§9.2); second NS host; registrar delegation; PSL (in progress). |

## 12. Failure modes

| Failure | Behaviour |
|---|---|
| Backend unreachable | Nameserver serves cached answers, else gateway. Gateway serves its cached routes. |
| Box offline | Route expires → gateway → gateway shows the offline/landing page. |
| Cert issuance fails | Stays gateway. Invisible to the user; visible in the dashboard `reason`. |
| Cert about to expire | Downgraded to gateway before `notAfter` (margin), back up once renewed. |
| One nameserver down | The other answers. |
| Both nameservers down | Everything under the zone fails, apex and mail included. This is why §10.2 is a hard requirement. |
| One gateway down | Clients retry the second `A`; remove it from the answer when its health check fails. |
| Gateway flooded | Direct boxes are unaffected; gateway-routed names degrade. |
| Stolen box credential | Can publish TXT for that one user (and already could register its routes). Revoke via `pcs revoke` / key rotation. |

## 13. Rollout

### 13.1 The bridge: delegating one user at a time

Cloudflare can keep the zone while single users move to the new design. One record per
nameserver in Cloudflare, `<user>.<zone> NS ns1/ns2`, hands everything **under** that
user to our nameserver: the user apex, `*.<user>.<zone>` and
`_acme-challenge.<user>.<zone>`. A specific record wins over the `*.<zone>` wildcard,
so nobody else is affected.

For a delegated user:

- **dot form** (`immich.john.nsl.sh`) runs entirely on the new design: our
  nameserver, DNS-01 wildcard, direct answer or the new gateway;
- **dash form** (`immich-john.nsl.sh`) is a sibling of `john.nsl.sh`, not under it, so
  it stays on Cloudflare and the Worker, unchanged. Both forms work side by side;
- **rollback** is deleting the NS records; the lag is their TTL (300 s).

Each phase is done on **staging (`inojob.com`) first**, and on prod only once
confirmed there. Cloudflare's record quota is not a concern (under 1000 records with
two NS records per user).

### 13.2 Phase 1: compatible preparation

Ships to prod with no change for any user who is not delegated. Staging test user:
**wisera** (`wisera.inojob.com`); prod pilot users to be chosen.

| Area | Work | Why it is compatible |
|---|---|---|
| Naming | Dot form rendered **alongside** the dash form for app routes, **on delegated boxes only and once their wildcard exists**; auth registrar accepts dot-form redirect hosts. Platform stacks stay dash-form until Phase 2 | Dot-form names already resolve to Cloudflare for everyone (the `*.<zone>` wildcard matches any depth), so a non-delegated box rendering them would make Caddy order a cert per app through the Worker and drain the shared Let's Encrypt bucket. Non-delegated boxes render nothing new |
| Naming | Reserved labels + no-dash rule at signup (§3.4); audit existing usernames | Signup-only |
| Naming | Cookie check (AppShield gates host-only; Authelia already is) and PSL submission (in progress) | No change |
| Nameserver | Own service replaces the stock sslip.io server, first as a drop-in for `ip.<zone>` compared answer for answer, then serving delegated user zones and challenge TXT | `ip.<zone>` answers unchanged |
| Nameserver | Static zone file in git from the Cloudflare export, checked in CI against live Cloudflare answers, not served | Not served |
| Nameserver | Metrics, external DNS monitor, shadow log of the answer it would give for every user | Observation only |
| Backend | Hostnames in route registration (optional field), per-host state, probes, force overrides, acme-dns API, new `/resolve/v2` fields | Additive; old agents and gateways ignore them |
| Box | Pinned xcaddy image with `caddy-dns/acmedns`; wildcard site block enabled only for delegated boxes (flag in the mesh `.env`, set by Yundera); agent sends hostnames | Same behaviour as today otherwise, with a pinned tag |
| Gateway | Delegated names go through the **existing** Traefik + OpenResty: Traefik gets a DNS-01 resolver (lego `httpreq` against the backend) and one router per delegated user. OpenResty only gets hygiene fixes. The edge mode (SNI passthrough, ACME forwarding) is Phase 2: passthrough to NAT boxes needs tunnel work, and ACME forwarding only serves HTTP-01, which Phase 1 doesn't use | Routers for delegated names only; other traffic unchanged |
| nip.io | Worker fallback moves from nip.io to sslip.io; Maison stops rendering nip routes; agent drops its nip route | The `ip.<zone>` path already carries the traffic (116 requests, 0 fallbacks at the prod switch) |
| Mail | SPF `include:sendgrid.net`, DMARC reports; contact alias off Email Routing | Improves today's setup |
| Dashboard | Per-host state table + force toggle; the Worker honours `force=gateway` too | Force works for every user, delegated or not |

Hosts (out of scope for this document, managed separately): a new VPS runs the main
nameserver + gateway; yundera-prod runs the second nameserver + gateway. Staging
equivalents are chosen the same way.

**Exit criteria:** wisera delegated on staging for a few weeks with direct, gateway,
tunnel and force all exercised on dot-form names; nip.io gone from the staging fleet;
static zone file in sync; then the same on prod with pilot users.

### 13.3 Later phases

2. **Batch delegation**: delegate users in batches (scripted Cloudflare API calls,
   reversible per user). Dot form becomes the name shown in the UI.
3. **Cutoff**: SendGrid records verified on our nameserver, static zone served,
   registrar NS switch, Worker retired. Rehearsed on `inojob.com` first.

## 14. What changed from the June 2026 design

| June (Path A) | Now |
|---|---|
| Per-user `dnsDirect` flag | Per-hostname state with a force override |
| Gateway answer = `CNAME gw-edge.nsl.sh` kept on Cloudflare | Doesn't work: `gw-edge.nsl.sh` is inside the zone the nameserver now owns, and Cloudflare rejects proxied hosts from zones it doesn't host. Gateway answer = `A` to our own gateway |
| Cloudflare Worker kept in front | Cloudflare dropped entirely |
| HTTP-01 only, DNS-01 rejected (needed a custom Caddy build; NAT boxes couldn't use direct anyway) | Owning the zone makes DNS-01 cheap, a wildcard per user removes per-app issuance and most rate-limit pressure, and NAT boxes benefit too (TLS passthrough). The custom build is a short Dockerfile change that also pins the image |
| DNS switched to the box first, cert issued on the first hit | Cert first (DNS-01, or HTTP-01 forwarded by the gateway), DNS switched only after the backend verifies it: no window without a cert |
| Dash-form names | Dot form canonical (wildcard-coverable), dash form as alias |
| `ip.<zone>` delegated as a separate subzone | Absorbed into the main zone; same names |
