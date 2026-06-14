# Architecture — mesh-router-nameserver

> Design document. Nothing here is built yet. This describes the target design
> (referred to as **Path A** in the design discussion: HTTP-01 certificates, no
> custom Caddy build, no DNS-01 control plane). The discarded alternative
> (**Path B**, DNS-01 wildcard) is recorded at the end for completeness.

## 1. Problem statement

Users access their PCS exclusively via the **vanity** name `app.<user>.nsl.sh`.
Today that name is *always* served through a gateway:

- **Cloudflare Worker** path: CF Worker resolves `<user>` via the backend, then
  proxies to `app-<dashed-ip>.nip.io` (a custom-CA cert, which is why CF must sit
  in front). ~38 ms.
- **OpenResty** path: resolves `<user>` and proxies to the PCS IP directly. Used for
  tunnel/private-IP PCS. ~137 ms with tunnel.

The ugly IP-encoded names (`*.sslip.io`, `*.nip.io`) are **break-glass fallbacks**.

For a PCS that has a **public IPv4** and can serve a **real, browser-trusted cert**,
routing through the gateway is pure overhead. We want `app.<user>.nsl.sh` to resolve
**straight to the PCS** in that case — and to keep falling back to the gateway when
it can't. The user-facing name never changes; only what it resolves to changes.

The blocker is DNS: there is currently **no authoritative nameserver** under
Yundera's control answering `*.nsl.sh` queries with per-user logic. This service is
that nameserver.

## 2. The core constraint that shapes everything

**A DNS server cannot observe TLS, SNI, certificates, or HTTP at query time.** It
only maps a name to an address. So "does this PCS have a public IP *and* a working
cert *and* is it reachable on :443" **cannot be decided inside the DNS answer path**.

Therefore eligibility must be **precomputed** into a flag (`dnsDirect`) that the
nameserver merely reads. The intelligence lives in *who sets that flag* (the
backend prober + route validator), not in the DNS server. The DNS server stays a
dumb, fast, stateless adapter.

Corollary: **never trust the PCS's self-report.** Eligibility is decided by an
**active probe from the public internet** (backend vantage point), not by what the
agent claims about itself.

## 3. Resolution flow (target)

```
Browser: https://app.john.nsl.sh/
   │
   │ DNS: A? app.john.nsl.sh
   ▼
┌─────────────────────────────┐
│  mesh-router-nameserver     │   GET /router/api/resolve/v2/john
│  - strip app/* labels       │ ───────────────────────────────► mesh-router-backend
│  - look up user "john"      │ ◄─────────────────────────────── { routes, dnsDirect, ... }
│  - apply policy             │
└──────────────┬──────────────┘
               │
       dnsDirect == true ?
        │                  │
        ▼ yes              ▼ no
  A  203.0.113.10     CNAME  gw-edge.nsl.sh   (Cloudflare-proxied gateway)
  TTL 30s             TTL 30s
        │                  │
        ▼                  ▼
  Browser → PCS:443   Browser → CF Worker → (nip.io|OpenResty) → PCS
  real LE cert        existing path, unchanged
  for app.john.nsl.sh
```

Wildcard handling: `app.john.nsl.sh`, `db.john.nsl.sh`, … all strip to the **user
label** `john` and share the same per-user decision. The left-most labels are app
prefixes and do not affect resolution.

### Zone responsibilities

| QNAME pattern | Answer |
|---|---|
| `<app>.<user>.nsl.sh` (eligible) | `A <pcs-ipv4>` (low TTL) |
| `<app>.<user>.nsl.sh` (not eligible) | `CNAME gw-edge.nsl.sh` |
| `<user>.nsl.sh` apex-of-user | same per-user decision |
| `gw-edge.nsl.sh` | **delegated/kept on Cloudflare** — NOT served by this NS (see §6) |
| `nsl.sh` SOA/NS | served by this NS (it is authoritative for the zone) |

## 4. The `dnsDirect` eligibility signal

`dnsDirect` is true for a user iff their PCS currently satisfies **all**:

1. Has a **public IPv4** route (not RFC1918/CGNAT/tunnel — `Probe.isLanOrReserved`
   already encodes this filter).
2. That IPv4 is **reachable on :443** from the public internet.
3. It serves a **publicly-trusted** TLS cert valid for the vanity name (i.e. an
   HTTPS handshake against the **system CA** succeeds — not the mesh-router custom
   CA).
4. The route registration is **fresh** (within the Redis route TTL, ~600 s).

Most of this signal already exists in the backend:

- **`RouteValidator.ts`** already validates routes over HTTPS by **racing the system
  CA against the custom CA in parallel**. A success against the *system* CA is
  exactly signal (3): the PCS is presenting a real, browser-trusted cert. A success
  only against the *custom* CA means it's still on the mesh-router CA → not eligible.
- **`Probe.ts` / `POST /probe`** already probes candidate public IPs and rejects
  LAN/reserved ranges. Today it uses **ICMP ping**; for eligibility it needs to also
  confirm **TCP :443 + TLS** (see implementation notes — ICMP alone is insufficient
  because :443 is what actually matters and ICMP is frequently filtered).
- **`Routes.ts`** holds the route set + TTL; freshness (4) is the Redis TTL already
  returned as `routesTtl` by `/resolve/v2`.

So `dnsDirect` is a derived boolean the backend computes at route-registration /
validation time and **adds to the `/resolve/v2` response**. The nameserver reads it;
it does not compute it.

## 5. Seamless upgrade / downgrade lifecycle

```
PCS boots / agent registers route (public IPv4 candidate)
        │
        ▼
backend validates route:
   reachable :443  &&  system-CA TLS ok ?
        │                         │
        │ not yet                 │ yes
        ▼                         ▼
   dnsDirect = false          dnsDirect = true
        │                         │
   NS returns CNAME→gateway   NS returns A→PCS  (UPGRADE, within ~TTL)
        │                         │
        └──────────┬──────────────┘
                   │  heartbeat keeps it fresh (route TTL ~600s)
                   ▼
        if heartbeat lapses / IP changes / cert expires / :443 unreachable
                   ▼
        dnsDirect flips back to false  →  NS returns CNAME→gateway  (DOWNGRADE)
```

Key properties:

- **A failed upgrade is invisible.** If the cert never issues or :443 isn't
  reachable, `dnsDirect` simply stays false and the user keeps getting the gateway.
  Nothing breaks; the user notices nothing.
- **Downgrade is the same mechanism in reverse**, driven by the same heartbeat/TTL
  that already keeps routes alive.
- **TTL is the seam.** Because resolvers cache, the upgrade/downgrade lag is bounded
  by the record TTL. Use a **low TTL (~30 s)** on `*.nsl.sh` answers. The NS is
  cheap, so the extra query volume is fine.

## 6. Certificate bootstrap (the chicken-and-egg, and how Path A avoids it)

To serve `app.john.nsl.sh` directly, the PCS needs a cert for **that literal name**.
A CNAME to sslip.io does *not* help — the browser sends SNI `app.john.nsl.sh` and
Caddy must present a cert valid for it.

The PCS already proves it can do this: it issues a **real Let's Encrypt cert for
`<dashed-ip>.sslip.io` via HTTP-01** today (`mesh-router-caddy/Caddyfile`, the
`{$PUBLIC_IP_DASH}.sslip.io` block; `entrypoint.sh` injects a `*.sslip.io`
passthrough TLS connection policy so that LE cert is served for sslip SNIs while the
catch-all keeps serving the custom CA). Path A reuses that exact machinery, pointed
at the vanity name.

Bootstrap ordering that sidesteps the chicken-and-egg:

```
1. Agent registers public-IPv4 route.
2. Backend prober confirms :80 AND :443 reachable from outside.
   (Eligibility already needs :443; HTTP-01 needs :80. If 443 is open, 80 almost
    always is — same NAT/firewall posture.)
3. Backend flips dnsDirect = true  →  NS starts returning A → PCS.
4. First HTTPS hit to app.john.nsl.sh reaches the PCS. Caddy on-demand TLS triggers
   an HTTP-01 challenge for that exact hostname, obtains a real LE cert, serves it.
5. Subsequent requests are served directly with a browser-trusted cert.
```

The brief window in step 4 (DNS already direct, cert not yet issued) is covered by
**Caddy on-demand TLS**: the first TLS handshake triggers issuance. This requires:

- switching on-demand TLS from the current **internal CA** to **real Let's Encrypt**
  for `*.nsl.sh` names, and
- an **`ask` endpoint** that authorizes *which* hostnames may get a cert (so the box
  only mints certs for its own user's `*.nsl.sh`, never arbitrary names). The PCS
  knows its own user domain locally, so the `ask` endpoint is trivial and local.

**No wildcard, no DNS-01, no custom Caddy build** — one cert per app subdomain via
the already-working HTTP-01 path.

### Public Suffix List (mandatory for multi-user)

Let's Encrypt rate-limits per **registered domain** (eTLD+1). If `nsl.sh` is the
registered domain, then `*.alice.nsl.sh`, `*.bob.nsl.sh`, … **all share one bucket**
(~50 certs/week) and you exhaust it almost immediately at real user counts.

Submitting **`nsl.sh` to the Public Suffix List** makes each `<user>.nsl.sh` its own
registered domain for rate-limiting → limits become **per-user**. This is exactly
why nip.io / sslip.io / Heroku are PSL-listed. Submit early; PSL propagation into LE
and browsers is slow (weeks).

## 7. The Cloudflare-vs-self-authoritative nuance

You cannot simultaneously run *your own* authoritative nameserver for `nsl.sh` **and**
keep the Cloudflare Worker in front via CF's orange-cloud proxy — CF proxying
requires CF to be authoritative for the proxied name.

Resolution: the gateway-fallback answer is a **`CNAME` to a CF-proxied hostname**
(`gw-edge.nsl.sh`) that stays delegated to / hosted on Cloudflare. CNAME at a
non-apex name is fine, and it preserves the existing CF Worker path untouched. So:

- This NS is authoritative for `nsl.sh` and answers `<user>.nsl.sh` queries.
- For non-eligible users it returns `CNAME → gw-edge.nsl.sh`.
- `gw-edge.nsl.sh` resolves via Cloudflare (orange cloud) → CF Worker → existing
  resolution. The CF Worker code is unchanged.

(Alternative if you'd rather not depend on CF for the fallback: return
`A → <OpenResty gateway public IP>` instead. Loses the CF Worker edge performance
for fallback traffic but removes the CF coupling.)

## 8. IPv4-only

Eligibility requires a **public IPv4**. IPv6 is explicitly out of scope (not well
supported across the fleet). The NS only ever returns an `A` record for the direct
case — never `AAAA`. The prober only checks the v4 candidate on :80/:443. Behind
NAT / no public v4 → never eligible → always gateway. Clean and simple.

## 9. Components & responsibilities

| Component | New? | Responsibility |
|---|---|---|
| **mesh-router-nameserver** (this) | **new** | Authoritative DNS for `nsl.sh`; per-user A-vs-CNAME policy; stateless adapter over `/resolve/v2`. Run ≥2 for HA. |
| backend `RouteValidator.ts` | extend | Already races system/custom CA; surface "publicly-trusted cert present" as part of `dnsDirect`. |
| backend `Probe.ts` / `POST /probe` | extend | Add TCP :443 (+:80) + TLS reachability check; today ICMP only. |
| backend `Routes.ts` / `RouterAPI.ts` | extend | Persist & expose `dnsDirect` in `GET /resolve/v2`. |
| `mesh-router-caddy` | extend | On-demand TLS via real LE for `*.nsl.sh`; mirror sslip.io connection-policy pattern. |
| `mesh-router-agent` | extend | Report public-IPv4 candidate; host local `ask` endpoint for on-demand TLS. |
| DNS registrar + PSL | ops | Delegate `nsl.sh`; keep `gw-edge.nsl.sh` on Cloudflare; list `nsl.sh` on PSL. |

## 10. Data the NS consumes

From `GET /router/api/resolve/v2/:user` (existing response, **+ proposed field**):

```jsonc
{
  "userId": "abc123",
  "domainName": "john",
  "serverDomain": "nsl.sh",
  "routes": [
    { "ip": "203.0.113.10", "port": 443, "priority": 1, "type": "ip" }
  ],
  "routesTtl": 580,            // Redis TTL → freshness signal
  "lastSeenOnline": "...",
  "dnsDirect": true,           // ← PROPOSED: backend-computed eligibility
  "directIp": "203.0.113.10"   // ← PROPOSED: the public IPv4 to return (or derive from routes)
}
```

The NS logic per query:

```
res = GET /resolve/v2/<user>
if res == 404                      → NXDOMAIN (or SOA-only negative)
if res.dnsDirect && res.directIp   → A res.directIp           (TTL 30)
else                               → CNAME gw-edge.nsl.sh      (TTL 30)
```

The NS may cache `/resolve/v2` responses for a few seconds to absorb query bursts,
but should keep that cache shorter than the DNS TTL it hands out.

## 11. Failure modes

| Failure | Behaviour |
|---|---|
| Backend `/resolve/v2` unreachable | Serve last-known-good from short NS cache; if none, return `CNAME → gw-edge.nsl.sh` (fail safe to gateway, never NXDOMAIN a known user). |
| PCS goes offline | Route TTL expires → `dnsDirect=false` → CNAME to gateway (which also can't reach it, but behaviour is consistent with today). |
| Cert issuance fails on PCS | `dnsDirect` stays false (validator never sees a system-CA cert) → gateway. Invisible to user. |
| NS instance dies | Second NS answers (run ≥2). Stateless, so no data loss. |
| IP changes (DHCP/failover) | New route registered → re-validated → A updated within TTL. |

## 12. Why not Path B (DNS-01 wildcard) — recorded for posterity

Path B would have this same NS also expose an **authenticated TXT-injection
endpoint** so each PCS could solve ACME **DNS-01** and obtain a **wildcard**
`*.<user>.nsl.sh` cert (one cert per user, issued regardless of routing/NAT). It was
rejected as the *first* implementation because:

- It needs a **custom xcaddy build** with a DNS-provider plugin on every PCS — none
  exists today (stock `lucaslorentz/caddy-docker-proxy`).
- Its main advantage (issue certs behind NAT) is **moot here**: behind NAT a PCS is
  not direct-eligible anyway, so it stays on the gateway and never needs the cert.
- Path A reuses the **already-working** sslip.io HTTP-01 flow with near-zero new cert
  infrastructure.

DNS-01 remains a clean **future extension** (this very service is the natural place
to host the TXT endpoint), gated behind the existing Ed25519 key→domain binding for
per-user authorization. If wildcard certs or per-subdomain rate-limit pressure ever
justify it, see `implementation_notes.md` §"Path B sketch".
