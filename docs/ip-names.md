# IP-encoded names — our own nip.io

> Design + test notes, 2026-10-21. **Live on staging** (nameserver on the nasselle
> staging server, worker `IP_ZONE=ip.inojob.com`); rollout record and prod cookbook:
> [`ip-names-rollout.md`](ip-names-rollout.md). §7 used an interim test nameserver on holyhorse.

## 1. Goal

Serve the **nip.io scheme 1:1** under a Yundera domain, so that `<anything>-<ip>.<zone>`
resolves straight to `<ip>` from our own authoritative DNS — no tunnel, no Cloudflare
Worker, no third-party service. In the long run `*.nip.io` is replaced everywhere in the
stack by the Yundera equivalent.

This is the **stateless** sibling of the per-user resolver in
[`architecture.md`](architecture.md) (`<user>.nsl.sh → that user's PCS IP`). Both need
the same thing — an authoritative nameserver we run — and differ only in the answer
rule. They can be one service with two rules.

Why bother replacing nip.io:

- third-party dependency on the hot path (the CF Worker reaches every PCS through
  `<app>-<ip>.nip.io`); nip.io is now operated by the sslip.io project;
- shared reputation: nip.io is blocked by some corporate filters / resolvers;
- branding, and one less name in certificates, the auth suffix list and the store labels.

## 2. The scheme — what "1:1 with nip.io" means

Observed against live `nip.io` on 2026-10-21 (`dig`):

| Query | Answer |
|---|---|
| `app-161-97-177-252.nip.io` | `A 161.97.177.252` |
| `app.161.97.177.252.nip.io` | `A 161.97.177.252` |
| `foo.bar-10.0.0.1.nip.io` | `A 10.0.0.1` (dash prefix before a dotted IP; private IPs answered) |
| `app-a161b1fc.nip.io` | `A 161.97.177.252` (8-digit hex) |
| `admin-2001-bc8-3021--1.nip.io` / `admin.2001-…` | `AAAA 2001:bc8:3021::1` |
| `AAAA` for an IPv4 name | `NOERROR`, empty (NODATA) |
| `foo.nip.io`, `1-2-3.nip.io` | `NXDOMAIN` |

So: any prefix, separated by `.` or `-`, followed by an IPv4 in dotted, dashed or hex
form, or an IPv6 in dashed form (`::` → `--`). The `<app>-<ip>` form is the one the
stack uses today (`caddy_1: <app>-${PUBLIC_IP_DASH}.nip.io`, CF Worker `ipToNipHost`),
which is why exact parity matters.

## 3. Where the names live

`nsl.sh` (and staging `inojob.com`) is hosted on **Cloudflare** with a proxied wildcard
and the Worker route `*.nsl.sh/*`. Cloudflare DNS cannot compute answers from the name,
so the IP rule needs a zone whose authoritative servers are ours.

| Phase | Names | How | Touches user traffic? |
|---|---|---|---|
| **1** | `<app>-<ip>.ip.nsl.sh` | `NS` delegation of the `ip` subzone from Cloudflare to our servers | No |
| **later** | `<app>-<ip>.nsl.sh` | the whole `nsl.sh` zone moves to our NS (the cutover in `architecture.md` §7: user names answered as `CNAME gw-edge.nsl.sh`) | Yes |

Phase 1 names keep working after the move, so nothing has to be migrated twice.
(Per-name records created through the Cloudflare API were considered and dropped.)

### Collision with `<app>-<user>` (apex phase only)

Inside `ip.nsl.sh` nothing collides. Once both rules share the `nsl.sh` apex, every
resolver that splits `<app>-<user>` on the last dash (CF Worker, `resolver.lua`, the
future NS) must **test for an IP-shaped tail first**: `admin-1-2-3-4.nsl.sh` would
otherwise parse as app `admin-1-2-3`, user `4`. User names are `[a-z0-9]+`
(`mesh-router-backend/src/services/Domain.ts`), so a dashed IP is never a user name,
but purely numeric (`4`) and 8-hex (`a161b1fc`) user names collide with the
IP forms. Reserve them in `Domain.ts` (and audit Firestore for existing ones) before
the apex phase.

## 4. Server

**Phase 1: run the sslip.io DNS server unmodified** (`cunnie/sslip.io-dns-server`,
Go, Apache-2.0). It is what answers for nip.io today, so parity is exact by
construction, and it answers for any suffix delegated to it. Relevant flags:

```
-ns .=ns1-ip.nsl.sh. -ns .=ns2-ip.nsl.sh.        # NS returned for every query
-soa ns1-ip.nsl.sh.,dns.nsl.sh.,<serial>,900,900,604800,60
-a ns1-ip.nsl.sh=<ip1> -a ns2-ip.nsl.sh=<ip2>     # glue it serves itself
-blocklistURL <url|file:///dev/null>              # their phishing blocklist, or ours
-public=true                                      # default; see Phase 2
-quiet                                            # drop per-query logs in prod
```

Upstream nip.io (PowerDNS pipe backend, `exentriquesolutions/nip.io`) is the
alternative; it has `NIPIO_WHITELIST` CIDR ranges but its IPv6/hex coverage is not
documented, so it is not the parity reference any more.

Run **two instances** on two hosts (different providers ideally), pinned by digest,
published on UDP+TCP 53.

## 5. Phase 2 — answer only for registered PCS IPs

An open nip.io under our brand lets anyone point `login-<ip>.nsl.sh` at a phishing
server; Safe Browsing / corporate filters then flag the domain and every customer's
`<user>.nsl.sh` with it. Phase 2 closes that:

- answer only for IPs that currently have a route in the backend route store
  (Redis, `/resolve/v2`); everything else → `NXDOMAIN`;
- refuse private / reserved ranges outright (`Probe.isLanOrReserved`) — the Worker
  cannot reach them anyway, and it removes the DNS-rebinding use;
- needs code: either a fork of the sslip.io server with an allowlist hook, or the
  rule moves into the per-user NS (CoreDNS plugin, `implementation_notes.md` §1) which
  already reads the backend. Cache the IP set locally and fail **open to the last
  known set**, never to "answer everything".

Not done in Phase 1 by decision: parity first, restriction second.

## 6. Prerequisites and consumers

- **Public Suffix List**: `nsl.sh` submission in progress. Required before these
  names replace **sslip.io** (Let's Encrypt, 50 certs/week per registered domain) and
  it also scopes cookies per user. Replacing **nip.io** alone (custom-CA hop) does not
  depend on it.
- Consumers to switch from `nip.io` (run both names side by side during the move):
  - `mesh-router-agent` — `buildDomainRoute(…, 'nip.io')`, `IpRegistrar.ts`
  - `mesh-router-gateway-cf` — `ipToNipHost`, `buildBackendUrl`
  - `mesh-router-backend` — `CertificateAuthority.ts` SAN `*.nip.io` → `*.ip.nsl.sh`
  - `mesh-router-auth` — allowed-suffix list in `config.ts` / `validation.ts`
  - Caddyfiles (`mesh-router-caddy`, `mesh-router-template-root`, `template-root`) — root
    `{$PUBLIC_IP_DASH}.nip.io` block
  - template self-checks (`ensure-public-ip.sh`, `ensure-root-domain.sh`, …)
  - ~90 store compose files carrying a `caddy_1 … .nip.io` label — better generated by
    Maison's route renderer (router-neutral `routes`) than edited by hand

## 7. Test: can the CF Worker reach a subzone delegated away from its own zone?

The Worker runs on the `nsl.sh` zone and would fetch `<app>-<ip>.ip.nsl.sh` — a name
inside its own zone but **not served** by Cloudflare. Open question: does the
subrequest resolve through our NS and go straight to the box, or does Cloudflare
treat it as same-zone traffic (loop / error 1000 / 1016)? Tested on staging
(`inojob.com`, same account shape as prod).

### 7.1 Test nameserver (running)

On **holyhorse** (test box, pre-authorized), since 2026-10-21:

```
docker run -d --name nsl-ip-dns-test --restart unless-stopped \
  --cpu-shares 128 -m 128m \
  -p 161.97.177.252:53:53/udp -p 161.97.177.252:53:53/tcp \
  cunnie/sslip.io-dns-server@sha256:0c51490361aa5b5682b766d0d9e0e6644fc4a475b90e55e39a5a5b2a41503397 \
  -ns .=ns-ip.inojob.com. \
  -soa ns-ip.inojob.com.,dns.inojob.com.,2026102101,900,900,604800,60 \
  -a ns-ip.inojob.com=161.97.177.252 -blocklistURL file:///dev/null
```

Verified from outside: `dig @161.97.177.252 app-161-97-177-252.ip.inojob.com` →
`161.97.177.252`, dotted/hex/IPv6 forms match nip.io, TCP works. Remove with
`docker rm -f nsl-ip-dns-test`. holyhorse's IP changes on rebuild — redo 7.2 if it does.

### 7.2 Delegation (Cloudflare dashboard, `inojob.com` zone)

| Type | Name | Value | Proxy |
|---|---|---|---|
| A | `ns-ip` | `161.97.177.252` | **DNS only** |
| NS | `ip` | `ns-ip.inojob.com` | — |

The explicit `NS ip` record overrides the proxied wildcard for everything under
`ip.inojob.com`. Check: `dig @1.1.1.1 app-161-97-177-252.ip.inojob.com` →
`161.97.177.252` (not `188.114.x.x`).

### 7.3 Probe worker

A throwaway Worker that fetches a target and reports what came back:

```js
export default {
  async fetch(req) {
    const target = new URL(req.url).searchParams.get("t");
    try {
      const r = await fetch(target, { redirect: "manual" });
      return Response.json({
        target, status: r.status,
        server: r.headers.get("server"), location: r.headers.get("location"),
        body: (await r.text()).slice(0, 300),
      });
    } catch (e) {
      return Response.json({ target, error: String(e) }, { status: 500 });
    }
  },
};
```

Deploy it twice:

- **control** — `workers.dev` only, no zone route;
- **subject** — route `inojob.com/__ipdns-probe*` on the `inojob.com` zone (apex is
  proxied; the path keeps it off the router API and off `*.inojob.com/*`).

Then call each with:

1. `?t=http://app-161-97-177-252.ip.inojob.com/` — plain HTTP isolates the DNS
   question from TLS. holyhorse's Caddy answers with a redirect, `server: Caddy`.
2. `?t=https://app-161-97-177-252.ip.inojob.com/` — the TLS question: the box serves
   the mesh custom CA (COTS), whose SAN has `*.nip.io` but not `*.ip.inojob.com`, so
   a cert failure is **expected** here until the CA adds the SAN.

Also run `docker logs nsl-ip-dns-test` on holyhorse: queries from Cloudflare's
resolver addresses confirm the name was resolved through our NS.

### 7.4 Reading the result

| Subject worker, test 1 | Meaning |
|---|---|
| `status 30x`, `server: Caddy`, query in the NS log | ✅ Works: same-zone subrequest leaves Cloudflare and follows our delegation |
| `error code: 1016` | Cloudflare did not follow the delegation (origin DNS error) |
| `error code: 1000` / `1003` / Worker loop | treated as same-zone / prohibited IP |
| control ✅, subject ❌ | the zone is the problem → host the IP names on a **separate domain** instead of a subzone |

### 7.5 Result (2026-10-21) — ✅ subzone works

Setup as above; probe worker `ipdns-probe` deployed on the `aptero` account, reachable as
`https://ipdns-probe.aptero.workers.dev/` (control) and `https://inojob.com/__ipdns-probe`
(subject). Each run used a unique prefix (`ctrl<ts>-…`, `zone<ts>-…`) to trace it.

| Probe | DNS (our NS log) | holyhorse :80 (tcpdump `Host:`) | Result |
|---|---|---|---|
| control, `http://ctrl…-161-97-177-252.ip.inojob.com/` | queried from CF resolvers (`162.158.x`) → `161.97.177.252` | seen | `308` → https (Caddy) |
| subject, `http://zone…-161-97-177-252.ip.inojob.com/` | queried from CF resolvers (`172.68/69.x`) → `161.97.177.252` | seen | `308` → https (Caddy) |
| subject, `https://zone…` | ↑ | — | `302` → `/nhl-auth/oidc/login` (AppShield on holyhorse) |
| control, `https://ctrl…` | ↑ | — | `526` invalid SSL certificate |

**A Worker on the zone can fetch a delegated subzone of its own zone**: Cloudflare
resolves it through our NS and connects straight to the box, no loop, no 1000/1016. The
subzone design (`ip.nsl.sh`) is viable.

Things learned on the way:

- Cloudflare rewrites the `Server` header of Worker subrequest responses to
  `cloudflare`, so it cannot be used to tell who answered. Use the NS log / a capture.
- **TLS differs between the two.** holyhorse serves the mesh CA cert
  (`SAN *.nsl.sh, *.nip.io, IP`, prod `NSL.SH` CA) — it covers neither the
  `ip.inojob.com` name nor is it the staging CA. The zone-less control rejects it
  (`526`), but the **zone-bound subrequest accepted it**: a same-zone subrequest
  appears to follow the zone's SSL/TLS mode (likely *Full*, i.e. no validation) rather
  than strict COTS validation as for an external name like nip.io. Before production:
  check the `nsl.sh` SSL mode, prefer *Full (strict)*, add `*.ip.nsl.sh` to the mesh CA
  SAN, and re-run this probe to confirm validation actually happens — otherwise the
  move from nip.io would silently drop certificate checking on the Worker → PCS hop.
- `dig +short NS ip.<zone>` prints nothing for a working delegation (the parent answers
  with a referral in the AUTHORITY section); check with `+norec` against the parent's NS.

### 7.6 Result (2026-10-21) — `resolveOverride` works; same-zone TLS is not validated

Target wisera (`80.241.218.30`, staging CA, cert `SAN *.inojob.com, *.nip.io, IP`). The
probe gained `&ro=<host>` (`cf.resolveOverride`). Evidence = SNI seen by `tcpdump` on
the box's :443 + our NS log.

| # | From | Request | Reached | Result |
|---|---|---|---|---|
| 1 | zone | `https://p…-80-241-218-30.ip.inojob.com/` (name not in cert) | wisera | `302` (4/4 retries) |
| 2 | workers.dev | same | wisera | `526` (4/4) |
| 3 | zone | `https://p…-80-241-218-30.nip.io/` | wisera | `200` |
| 4 | zone | `https://ro…-wisera.inojob.com/` + `ro=ro…-80-241-218-30.ip.inojob.com` | wisera, **SNI `ro…-wisera.inojob.com`** | `200` |
| 5 | zone | `https://rw…-wisera.inojob.com/` + `ro=rw…-161-97-177-252.ip.inojob.com` | holyhorse (cert has no `*.inojob.com`) | `302` — wrong cert accepted |
| 6 | zone | `https://rn…-wisera.inojob.com/`, no `ro` | not the box directly (zone origin) | `200` |
| 7 | workers.dev | as 4 | `ro` ignored → staging gateway worker → `wo…-…nip.io` | `200` |

(A first run of 1–2 returned `525`: wisera's Caddy was reloading — 7 config reloads in
2 min — and the catch-all TLS policy is briefly absent during a reload. Retries were
stable.)

Conclusions:

- **`resolveOverride` to the delegated subzone works** from a zone-bound Worker: the
  connection goes straight to the box via our NS, while Host and **SNI stay the
  original `<app>-<user>.<zone>`** (test 4). That name is already covered by the
  `caddy_0` labels and the `*.<zone>` SAN, so the Worker needs **no `caddy_1`-style
  label, no new SAN and no `X-Original-Host` rewrite**. It is ignored on `workers.dev`
  (test 7) — fine, the production Worker is zone-bound (`*.nsl.sh/*`).
- **Same-zone subrequests are not certificate-checked** (tests 1, 5), while external
  ones are (test 2, and nip.io today goes through COTS). This is the zone SSL/TLS mode
  (presumably *Full*). Today's nip.io hop is therefore stricter than the new path would
  be. To keep the check: set the zone to **Full (strict)** — COTS is the zone-level
  trust store for exactly that mode — and re-run test 5, which must then fail. With
  `resolveOverride` the SNI matches the existing SAN, so strict mode needs no cert
  change. Strict applies to every proxied origin in the zone, so audit the other
  proxied records (apex / router API, `gateway.entrypoint`) first.

Leftovers: none. The `ipdns-probe` Worker and `nsl-ip-dns-test` on holyhorse were removed
2026-10-21 once the staging nameserver served the delegation.
