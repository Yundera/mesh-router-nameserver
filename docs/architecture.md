# Architecture — mesh-router-nameserver

> Design document, decided 2026-10-22; nameserver topology (§10) revised 2026-10-23:
> stock PowerDNS everywhere, the backend writes to a hidden primary, the public
> nameservers are zone-transfer secondaries. Built so far: the topology (§10), the
> gated `ip.<zone>` ([`ip-names.md`](ip-names.md)), per-user zone delegation with
> DNS-01 and gateway certificates (Phase 1, §13.2). Staging has a delegated user
> (wisera); prod runs the same stack with none delegated yet. It
> replaces the June 2026 design (per-user `dnsDirect` flag, Cloudflare kept in front);
> §14 records what changed and why.

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
                   ┌────────────▼─────────────┐     zone transfer   ┌────────────────┐
                   │  ns1 / ns2 (PowerDNS,    │ ◄────────────────── │ hidden primary │ ◄── backend writes
                   │  secondaries)            │   NOTIFY + AXFR     │ (backend stack)│     answers + TXT
                   └────────────┬─────────────┘                     └────────────────┘
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
| DNS software | **Stock PowerDNS Authoritative 5.1** (`powerdns/pdns-auth-51`, 5.1.5 tested 2026-10-23), pinned, on every node. No DNS server of our own: the dynamic part lives in the backend (§10); the only code on the DNS path is a ~100-line Lua include for IP names (§10.2). |
| Source of truth | **The backend.** It computes every record and writes it to a **hidden primary** (PowerDNS sidecar in the backend stack). The public nameservers are secondaries fed by NOTIFY + zone transfer (IP allowlist); they hold no state of their own (§10). |
| DNSSEC | After the full zone move, not before (§10.5). PowerDNS online signing keeps the door open. |
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

The IP is in the name, but **only IPs registered by a real user's agent are
answered** (decided 2026-10-23, against abuse: no answers for arbitrary or private
IPs, no open nip.io for anyone's phishing or DNS rebinding). Any other IP-shaped
name gets an empty answer. `ip.<zone>` stays a **separate zone**, delegated from the parent
(`ip NS ns1, ns2`) and served **locally by each public nameserver** from one wildcard
`LUA` record in the image config (§10.2): there is nothing to replicate.

### 3.4 Reserved labels

Signup and the nameserver share one reserved list: `ip`, `ns1`…`nsN`, `gw`/`gw1`…,
`www`, `mail`, `acme`, `box`, `_acme-challenge`, `_dmarc`, `_domainkey`, `s1`, `s2`, `router`,
plus every label present in the static zone (§9). Existing users are audited against
it before delegation.

### 3.5 Static records

Everything that is not a user or IP name (apex, verification TXT, mail records, NS
glue, the backend's hostname) lives in a **static zone file**: server config, kept in
each environment's config repo next to the backend compose and bind-mounted into it
(`DNS_STATIC_ZONE_FILE`), never baked into an image. The backend reads it on every
reconcile pass, adds the records it derives and writes the whole apex zone to the
hidden primary (§10.2). §9 has the inventory.

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
precomputed by the backend and written into the zone as a plain `A` record (§10.3). And **the box's own
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

> Revised 2026-10-27 by [`phase-1.1-gateway-tls.md`](phase-1.1-gateway-tls.md) (Phase
> 1.1, not built yet). Phase 1 as shipped terminates every name at the gateway, with a
> backend-issued `*.<user>.<zone>` per delegated user; 1.1 removes that certificate.

Without Cloudflare the gateway is the public entry point for every name that is not
direct. The rule: **a name's private key lives in exactly one place.** The gateway is
an SNI router (OpenResty `stream` + `ssl_preread`), and the choice is syntactic:

1. **Dash form, reserved labels → terminate** with the gateway's own `*.<zone>`
   (DNS-01, challenge delegated to `acme.<zone>`), then re-encrypt to the box with SNI
   `<label>.box.<zone>`, verified against the mesh CA only.
2. **Dot form and user apex → raw passthrough** to the box's best route (public IP or
   WireGuard address), with PROXY v2 for the client IP. TLS ends on the box; the
   gateway holds no certificate for these names, so a box without its own certificate
   has no working dot names (dash names still work), and an offline box fails at the
   handshake instead of showing an offline page.

No ACME challenge forwarding: dash names are never direct and dot names use DNS-01.

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
- The value is written to the user's zone on the hidden primary at once and reaches
  the secondaries by NOTIFY within seconds. Clients check propagation themselves
  (Caddy/certmagic and lego query every authoritative nameserver before telling the
  CA to validate), so the API returns as soon as the primary has it.
- Rate limit per user (a few updates per hour is plenty: an order every ~60 days).
- No CNAME delegation is needed (acme-dns normally asks for
  `_acme-challenge.<name> CNAME <uuid>.auth.example`); our nameserver answers the TXT
  for the real name directly.

Since the credential is the box's provider signature, any FOSS box registered with the
backend can use it, Yundera-managed or not.

The gateways' own certificates for delegated users are issued by the backend itself
(it owns the zone, so its DNS-01 needs no API) and fetched by every gateway per SNI
(`GET /gateway/cert/<user>`). Phase 1 only: Phase 1.1 replaces them with a single
`*.<zone>` and revokes the per-user ones ([`phase-1.1-gateway-tls.md`](phase-1.1-gateway-tls.md) §6). A lego-based client can still use the challenge store
through `httpreq` (`POST /present` and `/cleanup` with `{fqdn, value}`, service key,
delegated users only).

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

> **Dropped in Phase 1.1** (2026-10-27): dash names terminate at the gateway and are
> never direct, dot names use DNS-01, so nothing needs HTTP-01 or the gateway's
> challenge forwarding. Kept below for the record.

Used for dash-form aliases on a direct box, and for boxes whose ACME client has no
acme-dns support. Caddy on-demand TLS with **real Let's Encrypt** for the user's names,
gated by the `ask` endpoint (the box only asks for names under its own user). Because
the gateway forwards challenges, issuance works whatever DNS currently answers,
including behind NAT. A NAT box gets no direct answer anyway, but with a trusted cert
the gateway can pass its TLS through (§6) instead of terminating it.

### 7.5 Rate limits

Let's Encrypt allows 50 new certificates per registered domain per week. Until `nsl.sh`
is on the PSL every user shares that bucket:

- Phase 1 as shipped spends **two** orders per delegated user (box + gateway, same
  names), so about 25 delegations per week; Phase 1.1 brings it back to one (the
  gateway's single `*.<zone>` replaces the per-user ones).
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
export, which becomes the first version of the static zone file (§3.5).

| Name | Type | Value | Purpose | After the move |
|---|---|---|---|---|
| `nsl.sh` | A / AAAA | Cloudflare proxy | backend + landing (`nsl.sh/router/api`) | `A` to the server-tier ingress (yundera-prod Traefik) |
| `nsl.sh` | TXT | `google-site-verification=…` | Google | copy |
| `nsl.sh` | MX ×3 | `route{1,2,3}.mx.cloudflare.net` | Cloudflare Email Routing, contact alias | replaced (§9.2) |
| `nsl.sh` | TXT | `v=spf1 include:_spf.mx.cloudflare.net ~all` | SPF | rewritten (§9.2) |
| `cf2024-1._domainkey` | TXT | DKIM key | Email Routing forwarding | dropped with Email Routing |
| `s1._domainkey`, `s2._domainkey` | CNAME | `s{1,2}.domainkey.u49916735.wl236.sendgrid.net` | **SendGrid DKIM for app mail** | **copy, verified before delegation** |
| `_dmarc` | TXT | `v=DMARC1; p=none;` | DMARC | copy |
| `ns1-ip`, `ip` | A / NS | yundera-prod | `ip.nsl.sh` delegation | `ip NS ns1, ns2` in the parent; each public nameserver serves `ip.` locally (§10.2) |
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

### 10.1 Topology

```
mesh-router-backend ── decision (§4), challenge store (§7.2), static zone (§9)
   │  PowerDNS HTTP API, backend stack network only
   ▼
hidden primary: PowerDNS + SQLite, sidecar in the backend stack
   │  not in any NS record, never queried by the public
   │  NOTIFY + AXFR, primary allows transfers only from the secondaries' IPs
   ├──► ns1: PowerDNS secondary  ─┐  public, in the registrar /
   └──► ns2: PowerDNS secondary  ─┘  Cloudflare NS records
```

- **One writer.** Only the backend changes records, and only on the primary. The two
  public nameservers never take writes and run a stock image: no code of ours sits on
  the DNS path.
- **Sync is the DNS protocol's job.** After each write the backend asks the primary
  to NOTIFY (`PUT /zones/<zone>/notify`); each secondary compares SOA serials and
  transfers the zone. A missed NOTIFY is caught by the primary's 60 s check cycle and
  the secondaries' SOA refresh. There is no push from the backend to two servers for
  us to keep consistent. Measured 2026-10-23: **~1 s** from API write to the new
  answer on a secondary with the explicit notify; up to 60 s without it (an API write
  alone sends no NOTIFY).
- **Zone per user, also after the cutover.** The secondaries transfer whole zones
  (AXFR observed, no IXFR), so a flip or a challenge moves only that user's handful of
  records. One big `nsl.sh` zone would move every user's records on every change.
- **Transfers are protected by IP, not TSIG.** PowerDNS's catalog consumer gives the
  member zones it creates no `AXFR-MASTER-TSIG`, so with TSIG required the secondaries
  can't transfer them (tested). The primary's `allow-axfr-ips` lists the secondaries,
  the published port is firewalled to them, and the secondaries accept NOTIFY only from
  the primary. Zone contents are public DNS data either way.
- **The primary is disposable.** Every record it holds is derived from backend state
  (Firestore, Redis, the static zone file): a full reconcile (§10.3) rebuilds it from
  an empty volume. Once DNSSEC is on, the signing keys become the only state that
  must be backed up.
- **New zones reach the secondaries by themselves**: the primary is a catalog-zone
  producer (RFC 9432) and the secondaries consume it, so creating a user zone through
  the API (with `catalog` set) is enough; it appears on the secondaries within the
  primary's 60 s cycle, and a deleted zone disappears the same way (both tested).
  The secondaries' config only knows the primary's address and the catalog name.
- **A third-party secondary** (anycast, DDoS absorption) can be added later with no
  change on our side: it is just another AXFR client.

Placement: the primary runs next to the backend (prod: yundera-prod; staging:
nasselle) and reaches the public secondaries over the internet on a non-standard port
published only to their IPs. A secondary on the same host reaches it over the stack
network instead.

### 10.2 What each node serves

| Zone | Primary | ns1 / ns2 |
|---|---|---|
| `<user>.<zone>`, one per delegated user (§13.1) | written by the backend | secondary |
| `<zone>` itself (served from the first load, delegated at the cutover, §13.3) | static zone file + backend records (below) | secondary |
| `ip.<zone>` | — | **local**: one wildcard `LUA` record from the image config |
| `allow.<ip-zone>.invalid` (allowlist for `ip.<zone>`) | written by the backend | secondary |
| catalog zone | producer | consumer |

A delegated user's zone holds a handful of records, all written by the backend:

| Name | Type | Value | TTL |
|---|---|---|---|
| `<user>.<zone>` | SOA, NS | PowerDNS SOA (serial bumped on every API change), `ns1`, `ns2` | 3600 |
| `<user>.<zone>` | A | box IP or gateway IPs (§4.2) | 30 |
| `*.<user>.<zone>` | A | same as the apex | 30 |
| `<host>.<user>.<zone>` | A | only for a host whose answer differs from the user's (per-host force) | 30 |
| `_acme-challenge.<user>.<zone>` | TXT | 0–2 challenge values (§7.2) | 60 |

The apex zone `<zone>` is the static zone file (§3.5) plus what the backend derives; the
backend owns the whole zone and deletes a record that is in neither, so a hand edit on
the primary does not survive a pass. In the file, the derived names are ignored (listed
by `mesh-cli dns zone --dry-run`), and a file that does not parse changes nothing:

| Name | Type | Value | TTL |
|---|---|---|---|
| `<zone>` | SOA, NS | PowerDNS SOA, `DNS_NS_HOSTS` | 3600 |
| `*.<zone>` | A | the healthy gateways (`DNS_GATEWAY_IPS`) | 30 |
| `ip.<zone>` | NS | `DNS_NS_HOSTS` (delegation of the local zone) | 3600 |
| `<user>.<zone>` | NS | `DNS_NS_HOSTS`, for each delegated user (`mesh-cli dns delegate`) | 3600 |
| everything else | any | the static zone file, `$TTL 300` by default (Cloudflare's "auto") | file |

`ip.<zone>` is the one zone that can't be transferred: its names are unbounded. Each
public node serves it from config, with no data to sync: a wildcard `LUA` record
(`*.ip.<zone> LUA A ";return ipname4()"`, `AAAA ";return ipname6()"`) calling a Lua
include shipped with the image (`image/lua/ipname.lua`). It follows
sslip.io's rule: four octets joined by `-` (leftmost), else by `.` (leftmost), else one
8-digit hex label; IPv6 in dashed form inside one label; no IP → empty answer.
The parsed IP is then looked up (`dblookup`) in the allowlist zone: one plain
`A`/`AAAA` record per allowed IP, `<key>.allow.<ip-zone>.invalid`, key = the dashed
IPv4 (`161-97-177-252`) or the 32-digit expanded IPv6. Not listed → empty answer.
The allowlist is its own zone, not records inside `ip.<zone>`, because PowerDNS
refuses Lua records both through the API (`enable-lua-record-updates=no`) and in an
incoming transfer: the Lua stays in the image, the backend only writes plain records
(all tested 2026-10-23).
PowerDNS's built-in `createForward()` was tested first and rejected: it answers
`0.0.0.0`/`::` for names without an IP and misses dotted or IPv6 addresses after a
prefix (20 of 35 hand-picked cases differ). Parity of the include with the sslip.io
server running today, 2026-10-23: **579 of 581** queries identical
(`test/ipname/`); the two differences are sslip.io's `MX 0 <name>` answers and its
own NS glue, neither of which we serve. Gated, with every corpus IP allowed: every
IP answer identical. Allow or remove an IP: 0.4–4 s to the secondaries' answer,
up to ~21 s while the packet cache (20 s) still holds the previous empty answer. It needs `lua-records-exec-limit=20000` (the
default 1000 fails 86 queries).

### 10.3 The reconciler (backend)

The dynamic part of the design is a backend service, not a DNS server feature:

- **Desired state** per delegated user = §4.2 answer from Firestore (`dns` block),
  Redis (probe state, route freshness) and the challenge store.
- **Event-driven write**: a probe result, a force change, a TXT update, a
  delegation or route expiry recomputes that user and `PATCH`es only the RRsets that
  differ. Nothing changed → no write → no serial bump.
- **Periodic full pass** (every minute over delegated users; cheap: one GET per
  zone) repairs drift and catches route expiry, which has no event.
- **Delegation on/off** creates/deletes the zone on the primary (with its catalog
  membership); the secondaries follow.
- **The `ip.<zone>` allowlist**: the public IPs of agent routes (`source: agent`,
  signature-verified, `isLanOrReserved` filtered) of every registered user, kept for a
  grace period after the last registration (`DNS_ALLOW_GRACE_SECONDS`, default 6 h: short
  outages and backend restarts don't break names, little churn). Written on registration (new IP → allowed
  within seconds) and pruned by the full pass. The whole allowlist zone is transferred
  on each change; at a few thousand boxes, shard it (one zone per first octet).
- The primary's API key and URL are backend env; the API is never published.

### 10.4 Availability

Once the apex is ours, a nameserver outage takes down the backend API and outbound
mail as well as every app.

- **≥2 public secondaries on different providers/networks**, both in the NS set. Prod:
  the new VPS and yundera-prod (hosts are managed separately). Staging runs one until a
  second host is chosen.
- **Backend or primary down** freezes the zone at its last state: the secondaries keep
  answering until the SOA `expire` (set to 2 weeks); only changes stop (flips, new
  challenges). Unlike the 2026-10-22 design there is no serve-stale fallback to the
  gateway: a box that goes offline during the outage keeps its `direct` answer until
  the backend is back. Acceptable, since the gateway resolves through the backend too.
- **Abuse**: PowerDNS packet cache, response rate limiting (dnsdist in front if
  needed later), no backend involvement at query time at all.

### 10.5 DNSSEC

Not before the full zone move:

- During the per-user bridge the parent zone stays on Cloudflare, so a signed user zone
  would need a DS record per user in Cloudflare for little gain.
- **Never change the nameservers and DNSSEC in the same step.** If Cloudflare signs the
  zone at cutover time, either run a multi-signer transition (RFC 8901) or remove the
  DS at the registrar and wait out its TTL before switching.
- When enabled: online signing on the primary, a single CSK (ECDSA P-256), no
  scheduled rollover; the secondaries receive signed transfers. `ip.<zone>` is signed
  locally on each public node with the same key, installed from a secret. The `.sh`
  registry and our registrar must accept DS records (to check).

### 10.6 IPv4 only

Direct answers are `A` only, as before. `AAAA` for boxes with public IPv6 is a later
extension; it needs the same probe on v6.

## 11. Components

| Component | Change |
|---|---|
| **mesh-router-nameserver** | No DNS code: one PowerDNS image (`ROLE=primary|secondary`) for the hidden primary (backend sidecar) and the public secondaries, the `ip.<zone>` LUA zone, the static zone file and its checks (§10). |
| **mesh-router-backend** | Per-host state + probes (§4, §5); hostnames in route registration; acme-dns API + challenge store (§7.2); force overrides; the **zone reconciler** writing to the hidden primary (§10.3); `mesh-cli dns` admin commands; reserved labels at signup (§3.4). |
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
| Backend or hidden primary down | Zone frozen at its last state; secondaries keep answering until SOA expire (2 weeks). No flips, no new challenges. Gateways serve their last resolution for 24 h (serve-stale, [`multi-gateway.md`](multi-gateway.md)). |
| Primary volume lost | Recreated empty; the backend's full reconcile rewrites every zone, the secondaries pull the result. |
| Backend down, box changes IP | Its new `<app>-<ip>.ip.<zone>` names answer empty until the backend is back (allowlist frozen). The old IP stays allowed. |
| Box offline | Route expires → gateway → gateway shows the offline/landing page. |
| Cert issuance fails | Stays gateway. Invisible to the user; visible in the dashboard `reason`. |
| Cert about to expire | Downgraded to gateway before `notAfter` (margin), back up once renewed. |
| One public nameserver down | The other answers; the returning one catches up by IXFR. |
| Both nameservers down | Everything under the zone fails, apex and mail included. This is why §10.4 is a hard requirement. |
| One gateway down | Clients retry the second `A`; the backend drops it from the answer after two failed checks ([`multi-gateway.md`](multi-gateway.md)). |
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
| Naming | Dot form rendered **alongside** the dash form on every box, for store apps and platform stacks (Dex and Authelia dash-form only: their issuer URLs); the dash form stays the primary (Maison's default domain). Auth registrar accepts dot-form redirect hosts (revised 2026-10-25) | No certificate is ordered for a dot name: the box's static `*.<domain>` site covers them, with a local certificate until the zone is delegated. On a non-delegated box the dot names resolve to Cloudflare, whose edge certificate covers one level only, so nothing reaches the box by them |
| Naming | Reserved labels + no-dash rule at signup (§3.4); audit existing usernames | Signup-only |
| Naming | Cookie check (AppShield gates host-only; Authelia already is) and PSL submission (in progress) | No change |
| Nameserver | PowerDNS secondaries replace the stock sslip.io server on the public NS hosts: `ip.<zone>` from the LUA wildcard, compared answer for answer with the sslip.io server first; delegated user zones and challenge TXT by transfer from the hidden primary in the backend stack | `ip.<zone>` answers unchanged; user zones exist only for delegated users |
| Nameserver | Static zone file (server config, §3.5) from the Cloudflare export, loaded by the backend into the apex zone on the primary; `mesh-cli dns zone diff` compares it with live Cloudflare answers. Served by our nameservers, asked by nobody until the registrar switch | Not delegated |
| Nameserver | Metrics, external DNS monitor (SOA serial of primary vs every secondary), shadow log in the backend of the answer each user would get | Observation only |
| Backend | Hostnames in route registration (optional field), per-host state, probes, force overrides, acme-dns API, new `/resolve/v2` fields | Additive; old agents and gateways ignore them |
| Box | Pinned xcaddy image with `caddy-dns/acmedns`; mesh-router-caddy itself asks the backend whether the zone is delegated (`dns.live`) and switches the root and `*.<domain>` to DNS-01 certificates (no `.env` flag, nothing set by Yundera; revised 2026-10-25); agent sends hostnames | Not delegated: the root keeps the gateway CA, the wildcard a local certificate, no ACME order |
| Gateway | OpenResty terminates TLS itself (self-signed behind Cloudflare "Full"); since phase 1.1 dot names and user apexes pass through raw to the box, which holds its own certificate, and the backend-issued per-user certificates are gone (`phase-1.1-gateway-tls.md`). Behind a shared Traefik, one generic TCP passthrough rule for `*.<zone>`; on its own host it listens on 443. Nothing per user in Traefik (revised 2026-10-24). ACME forwarding and passthrough to NAT boxes are Phase 2 | Dash names unchanged (same self-signed origin cert behind Cloudflare) |
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
| `ip.<zone>` delegated as a separate subzone | Still a separate zone, now served by the same public nameservers from a local LUA wildcard; same names |
| (2026-10-22) Own Go nameserver on `miekg/dns`, each instance pulling from the backend with a serve-stale cache | (2026-10-23) Stock PowerDNS everywhere; the backend writes to a hidden primary in its own stack, the public nameservers are secondaries (IP-allowlisted transfers, catalog zone). A tested base with DNSSEC available, no DNS server of ours (one Lua include for IP names), and no two-writer sync problem |
