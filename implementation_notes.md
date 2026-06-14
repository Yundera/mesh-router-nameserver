# Implementation Notes — mesh-router-nameserver

> Working notes to start implementation from. Pairs with
> [`docs/architecture.md`](docs/architecture.md). Path A (HTTP-01, no custom Caddy
> build). File paths are relative to `packages/mesh-router-root/` unless noted.

## 0. TL;DR of the work

1. Build the DNS server (this repo) — a stateless DNS→HTTP adapter over
   `/resolve/v2`.
2. Add a backend `dnsDirect` flag (most of the signal already exists).
3. Extend the prober to check TCP :443/:80 + TLS, not just ICMP.
4. Switch PCS Caddy on-demand TLS to real LE for `*.nsl.sh` + add an `ask` endpoint.
5. Ops: delegate `nsl.sh`, keep `gw-edge.nsl.sh` on Cloudflare, list `nsl.sh` on the
   PSL.

Each is small; the only brand-new daemon is item 1.

---

## 1. The DNS server (this repo)

### Technology choice

Three viable options, in rough order of "least new code":

- **PowerDNS + remote backend** — pdns calls an HTTP endpoint per query; we point it
  at a thin adapter (or directly at `/resolve/v2` via a shim). Least DNS code, but
  two moving parts (pdns + shim).
- **CoreDNS + custom plugin (Go)** — single binary, plugin does the `/resolve/v2`
  call and builds the answer. Good middle ground; CoreDNS handles SOA/NS/EDNS/etc.
- **Custom Go server using `miekg/dns`** — what sslip.io itself uses. Most control,
  most boilerplate (you own SOA, negative caching, TCP fallback, EDNS).

**Recommendation: CoreDNS with a small custom plugin.** It gives correct DNS
behaviour for free and keeps our logic to "lookup user → A or CNAME". Revisit if we
later want DNS-01 TXT injection (Path B), which may favour PowerDNS or the custom
server.

### Responsibilities

- Authoritative for the `nsl.sh` zone: serve `SOA`, `NS`, and the per-user
  `A`/`CNAME` answers.
- For a query `<labels...>.<user>.nsl.sh`: strip everything left of `<user>`, call
  `GET {BACKEND_URL}/resolve/v2/<user>`, then:
  - `404` → negative answer (SOA-backed NXDOMAIN/NODATA).
  - `dnsDirect && directIp` → `A directIp`, TTL 30.
  - else → `CNAME gw-edge.nsl.sh`, TTL 30.
- **Fail safe**: if the backend is unreachable and no cached answer exists, return
  `CNAME gw-edge.nsl.sh` rather than failing — a known user should never go dark.
- Short internal cache of `/resolve/v2` responses (a few seconds, < DNS TTL) to
  absorb bursts. Keyed by user label.

### Config / env

| Var | Meaning |
|---|---|
| `BACKEND_URL` | e.g. `https://nsl.sh/router/api` |
| `ZONE` | `nsl.sh` |
| `GATEWAY_CNAME` | `gw-edge.nsl.sh` |
| `ANSWER_TTL` | default `30` |
| `RESOLVE_CACHE_TTL` | default `5` |
| `NS_NAMES` | `ns1.nsl.sh`, `ns2.nsl.sh` for SOA/NS records |

### HA / deployment

- Run **≥2 instances** behind two delegated NS names (`ns1`/`ns2.nsl.sh`) with glue.
- Stateless → trivially horizontally scalable; no shared state, no DB.
- Publish image to `rg.fr-par.scw.cloud/aptero` like the rest of the stack.
- Health: a synthetic query for a known test user should return the expected record.

### Open questions for this service

- Where do `ns1/ns2.nsl.sh` themselves resolve? (A records / glue at the registrar.)
- Do we need DNSSEC now or later? (CoreDNS can sign; adds key management.)
- Negative-answer TTL — keep low so a just-registered user resolves quickly.

---

## 2. Backend: the `dnsDirect` flag

Goal: `GET /resolve/v2/:user` returns a backend-computed `dnsDirect` boolean (+ the
`directIp` to use). The pieces are mostly present.

### Already exists (reuse)

- **`mesh-router-backend/src/services/RouteValidator.ts`** — `validateWithHttps`
  already **races the system CA against the custom CA** (`customCaAgent` loaded from
  `CA_CERT_PATH`). A success against the **system CA** = the PCS is serving a
  publicly-trusted cert. That is signal (3) of eligibility. We need to *record which
  CA won*, not just `valid: true`. Extend `ValidationResult` with e.g.
  `trustedByPublicCa: boolean`.
- **`mesh-router-backend/src/services/Probe.ts`** + `POST /probe` — public-internet
  reachability probe with `isLanOrReserved` pre-filter and per-source rate limiting.
- **`mesh-router-backend/src/services/Routes.ts`** — `Route` model (`ip`, `port`,
  `priority`, `scheme`, `source`, `type`, `domain`) and Redis storage with TTL;
  `routesTtl` already surfaced.
- **`RouterAPI.ts`** — `GET /resolve/v2/:domain` (the response to extend),
  `POST /routes/:userid/:sig` (where validation runs), `POST /probe`.

### To add

1. **Extend `Probe.ts`** beyond ICMP: ICMP reachability is necessary-but-not-
   sufficient. Add a **TCP-connect + TLS-handshake check on :443** (and a TCP :80
   check, since HTTP-01 needs :80). Eligibility should hinge on **:443 TLS**, not
   ICMP — many hosts filter ICMP. Keep the LAN/reserved guard and rate limiting.
2. **Extend `RouteValidator.ts`** to report `trustedByPublicCa`.
3. **Compute `dnsDirect`** at route-registration / validation time:
   ```
   dnsDirect = route is type "ip"
            && ip is public IPv4 (!isLanOrReserved && isIPv4)
            && :443 reachable + TLS ok
            && trustedByPublicCa
            && routesTtl > 0 (fresh)
   ```
   Store alongside the route (Redis) or recompute on read if cheap.
4. **Surface it** in the `/resolve/v2` response: `dnsDirect`, `directIp`.

### Re-validation cadence

`dnsDirect` must be refreshed on the same heartbeat that keeps routes alive (route
TTL ~600 s). On each `POST /routes` re-registration, re-run the probe+validate so the
flag tracks reality (IP change, cert expiry, box going behind NAT).

---

## 3. PCS Caddy: real-LE on-demand TLS for `*.nsl.sh`

Files: `mesh-router-caddy/Caddyfile`, `mesh-router-caddy/entrypoint.sh`
(also `template-root/root/Caddyfile` + `docker-compose.yml` for the shipped config).

### What exists today

- Stock `lucaslorentz/caddy-docker-proxy` (no xcaddy, no DNS plugin). **Good — Path A
  needs no custom build.**
- `Caddyfile`: global `email {$PCS_EMAIL}`; `(gateway_tls)` snippet serves the custom
  CA `/certs/cert.pem`; three root blocks — `{$DOMAIN}` and `{$PUBLIC_IP_DASH}.nip.io`
  (custom CA via `gateway_tls`) and `{$PUBLIC_IP_DASH}.sslip.io` (**no tls directive
  → falls through to LE via HTTP-01**).
- `entrypoint.sh` injects via the Caddy Admin API: a **catch-all TLS connection
  policy** serving the custom CA (`cert0`), and a **`*.sslip.io` passthrough policy**
  (default cert selection) ordered *before* the catch-all so sslip SNIs serve their
  LE cert. On-demand TLS today uses the **internal CA** only.

### What to add (mirror the sslip.io pattern for nsl.sh)

1. **Site/label for direct nsl.sh apps** analogous to the sslip.io block: serve
   `<app>.<user>.nsl.sh` with **LE (HTTP-01)**, not the custom CA.
2. **On-demand TLS → real LE** for `*.nsl.sh` names (today on-demand = internal CA).
   Add an on-demand TLS config whose **`ask` endpoint** authorizes the hostname.
3. **TLS connection policy** for `*.<user>.nsl.sh` SNIs that uses default (LE) cert
   selection, ordered before the custom-CA catch-all — exactly like the sslip
   passthrough policy in `entrypoint.sh` (`inject_sslip_passthrough_policy` is the
   template to copy).

The PCS only ever serves **one user's** domain, so the names are concrete
(`<user>` is fixed per box). On-demand keeps it from having to enumerate every app
subdomain up front.

### The `ask` endpoint

Caddy on-demand TLS calls `ask` before issuing. It must answer "yes" only for names
this box legitimately owns:

- Host it in **`mesh-router-agent`** (it knows the box's `DOMAIN` / user domain) or as
  a tiny sidecar next to Caddy.
- Authorize `*.<own-user-domain>` (+ the existing sslip/nip names). Reject anything
  else, so a misconfig can't make the box request arbitrary certs.
- Keep it local (loopback) — it's an internal gate, not a public endpoint.

---

## 4. mesh-router-agent

Files: `mesh-router-agent/src/index.ts`, `mesh-router-agent/src/services/`.

- Already detects `PUBLIC_IP` and registers `ip` + `nip.io`/`sslip.io` `domain`
  routes (see the route-type table in `../CLAUDE.md`).
- Add: surface the **public-IPv4 candidate** clearly for the backend prober (it may
  already via the registered `ip` route — confirm).
- Add: host (or proxy to) the **`ask` endpoint** for Caddy on-demand TLS.

---

## 5. Ops / one-time

- **Delegate `nsl.sh`**: registrar `NS` → `ns1.nsl.sh` / `ns2.nsl.sh` with glue A
  records pointing at the two NS instances.
- **Keep `gw-edge.nsl.sh` on Cloudflare** (orange-cloud) as the CNAME fallback target
  so the CF Worker path is preserved. (See architecture §7 for why you can't have
  both self-authoritative `nsl.sh` *and* CF-proxied `nsl.sh` for the same names.)
- **Public Suffix List**: submit `nsl.sh` to https://github.com/publicsuffix/list .
  Without it, all users share one LE rate-limit bucket. Slow to propagate — **do this
  first**, before broad rollout.
- Decide `gw-edge` vs a bare OpenResty A-record fallback (CF coupling trade-off).

---

## 6. Suggested rollout order

1. **PSL submission for `nsl.sh`** (long lead time — kick off immediately).
2. **Backend `dnsDirect`** flag + extended probe/validator, shipped *dark* (computed
   and exposed in `/resolve/v2`, nothing consumes it yet). Verifiable via curl.
3. **Caddy on-demand LE + `ask` endpoint** on PCS, gated so it only kicks in for
   `*.nsl.sh`. Verify a PCS can obtain an LE cert for `app.<user>.nsl.sh` when the
   name is pointed at it manually (e.g. `/etc/hosts` or a test sub-delegation).
4. **Build the nameserver**, run ≥2 instances, but **delegate only a test subzone**
   first (e.g. `*.dev.nsl.sh` or a throwaway domain) to validate end-to-end.
5. **Flip a pilot user** to direct, watch upgrade → verify `X-Mesh-Trace` shows
   `pcs` directly (no `cf-worker`), confirm downgrade by stopping the box.
6. **Delegate `nsl.sh`** for real and enable fleet-wide.

Each step is independently reversible; nothing user-visible changes until step 5.

---

## 7. Verification checklist

- `dig app.<pilot>.nsl.sh` → `A <pcs-ip>` when eligible; `CNAME gw-edge.nsl.sh` when
  not.
- `curl -D- -H 'X-Mesh-Trace: 1' https://app.<pilot>.nsl.sh/` → route path is `pcs`
  directly (no `cf-worker`) when direct; reverts to `cf-worker,...` after downgrade.
- TLS: `openssl s_client -connect <pcs-ip>:443 -servername app.<pilot>.nsl.sh` shows
  a **Let's Encrypt** chain (not the mesh-router custom CA).
- Kill the PCS → within ~TTL+routeTTL the name resolves back to `gw-edge.nsl.sh` and
  the app still loads via the gateway.
- LE rate limits: confirm `nsl.sh` is treated as a public suffix (per-user buckets)
  before onboarding many users.

---

## 8. Path B sketch (DNS-01 wildcard) — future, not now

If wildcard certs or per-subdomain rate pressure later justify it, this service can
also host an **authenticated TXT-injection endpoint** for ACME DNS-01:

- PCS runs an ACME client (lego/Caddy DNS module) → generates its **own** keypair
  locally (no shared private key, ever) → asks LE for `*.<user>.nsl.sh`.
- To answer the challenge, PCS calls `POST /acme-dns/<user>.nsl.sh { txt, sig }` on
  this NS, **signed with the existing Ed25519 route-registration key**.
- Authorization (critical): verify sig → look up the owning domain for that key
  (Firestore `nsl-router` `publicKey`→`domainName` binding) → **reject if the name
  isn't that key's own `_acme-challenge.<domain>`**. Otherwise it's a domain-takeover
  machine.
- Gotchas: support **multiple coexisting TXT values** at the same
  `_acme-challenge.<user>` name (apex + wildcard SAN write two values — RRset, not
  overwrite); short TTL + cleanup after validation.
- Cost: a **custom xcaddy build** with a DNS-provider plugin on every PCS. This is the
  reason Path B is deferred.
