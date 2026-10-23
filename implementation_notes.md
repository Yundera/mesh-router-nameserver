# Implementation Notes — Phase 1 (compatible preparation)

> The file-by-file plan for Phase 1 of [`docs/architecture.md`](docs/architecture.md)
> (§13.2). Written 2026-10-22 from a read of the code at that date; `file:line`
> references are relative to `mesh-router-root/` unless stated otherwise.
> **Revised 2026-10-23:** the nameserver is stock PowerDNS (hidden primary in the
> backend stack + public secondaries, architecture §10); N1, N2, B3–B5, B9 and the
> checklist follow. DNSSEC stays out of Phase 1.
> **Staging (`inojob.com`) first, test user wisera.** Prod only once staging is
> confirmed. Replaces the June 2026 notes (per-user `dnsDirect`, "Path A"): their
> Phase 0 (P0.1–P0.4) was marked implemented on 2026-06-14 but is not what the code
> holds today; this file starts from the code.

## 0. What the code says (and older docs get wrong)

These facts shape the plan more than the design does:

| Fact | Where | Consequence |
|---|---|---|
| The agent registers **only domain routes**: nip.io (priority 1) and, with `IP_ZONE`, `<ip>.ip.<zone>` (priority 2). No raw `ip` route, no sslip.io route. The ip/sslip/nip table in `CLAUDE.md`, `doc/DATA_FLOW.md`, `doc/architecture/README.md` is stale. | `mesh-router-agent/src/services/IpRegistrar.ts:286-304` | The public IP is the `ip` field of the agent's routes. Removing nip.io means replacing those routes, not deleting them. |
| Box Caddy has **no on-demand TLS and no `ask` endpoint**. Sites without a `tls` line use the default issuer chain `acme` then `internal`; `gateway_tls` sites use the mesh cert loaded as `cert0` through the admin API. | `mesh-router-template-root/Caddyfile:36,52-55,61-69`; `mesh-router-caddy/entrypoint.sh:38-50,99-117` | Any label host without `import gateway_tls` makes Caddy start ACME for it. See the next row. |
| `immich.john.nsl.sh` **already resolves to Cloudflare** for every user: a DNS wildcard matches any depth, and the Worker parses dot form (`resolver.lua:93`, worker `parseHost`). Cloudflare presents a cert that doesn't cover two levels. | public DNS | If a non-delegated box rendered a dot-form host with no TLS line, Caddy would order a cert per app via HTTP-01 through the Worker, and the fleet would burn `nsl.sh`'s shared bucket (50/week, no PSL yet). **Dot form is rendered only on delegated boxes, and only once their wildcard exists.** |
| Tunnel routes point at the tunnel server's private Docker address (`172.30.0.3:80` on staging, checked live), reachable only from containers on that host's `mesh-internal` network. The tunnel server forwards **HTTP** by `Host`, not raw TLS. | `mesh-router-tunnel/src/requester/RouteRegistrar.ts:79-96`, `nginx/provider/*` | A gateway must sit next to the tunnel server to reach NAT boxes. TLS passthrough to a tunnel box needs tunnel work: Phase 2. |
| Staging Traefik (v3.1) has **no ACME resolver**: it serves static certs from `/etc/certs` and routes through a watched file provider plus the docker provider. | `/workspace/config/admin/traefik/traefik.yml` on nasselle | Serving delegated names through the existing gateway needs a cert resolver on Traefik (static config change → Traefik restart). |
| The box credential is a **static Ed25519 signature over the user id**: a replayable bearer token, the same one in `PROVIDER_STR`. | `mesh-router-backend/src/library/KeyLib.ts:15-33`, callers `RouterAPI.ts:85,127,278,424,832` | The acme-dns API uses it unchanged; it grants nothing a holder can't already do (register routes). |
| `/resolve/v2` has **no cache**: one Firestore query + Redis per call. | `RouterAPI.ts:481-510`, `services/Domain.ts:42-63` | The nameserver must cache; never query per DNS packet. |
| Usernames are `^[a-z0-9]+$`, ≤63 (backend) and `{1,63}` (pcs-dashboard). Reserved: `root`, `app`, `www`, checked by `/available` only, **not** by `POST /domain`. | `services/Domain.ts:15-35,65,115-152`; `pcs-dashboard/src/components/domainName.ts:5` | No dashes already: no audit needed for that. Reserved list must grow and be enforced on write. |
| The dashboard has **no per-user page and no admin role**: `authenticate` accepts any Firebase user. | `mesh-dashboard/.../app/pages/DomainsPage.tsx`; `services/ExpressAuthenticateMiddleWare.ts:35-70` | Admin actions go through `mesh-cli` in the backend container (decided 2026-10-22), not the dashboard: no admin role to build. The dashboard only carries the owner's own actions. |
| Maison accepts a dot-form domain as is: `Domain.Template()` keeps a host containing `{name}`, and `checkOverlap` compares `.${APP_DOMAIN}` with `-${APP_DOMAIN}` (no overlap). The **template** hard-codes the `{name}-` prefix. | `maison/internal/domains/domains.go:59-64`, `internal/routing/setting.go:135-148`; `mesh-router-template-root/scripts/library/common.sh:258-265` | No Maison change for dot form; a template change. |
| The auth registrar validates app redirect hosts as `<client_id>-<suffix>`. | `mesh-router-template-root/docker-compose.yml:182-187` (comment), `mesh-router-auth` | SSO apps on dot-form names fail login until the registrar also accepts `<client_id>.<suffix>`. |
| Platform stacks (mesh-console, maison gate, Dex, Authelia, auth-console; admin and kopia in template-root) hard-code three label hosts: `<name>-${DOMAIN}`, nip.io, sslip.io. | `mesh-router-template-root/docker-compose.yml:244-255`, `stacks/maison/docker-compose.yml:122-132`, `stacks/auth/docker-compose.yml:157-167,208-219,372-382`; `template-root/root/docker-compose.yml:130-141`, `root/template/stacks/kopia/docker-compose.yml:154-162` | Platform UIs stay dash-form in Phase 1 (still reachable for delegated users through Cloudflare). Their nip labels go with the nip removal. |

## 1. Phase 1 decisions that narrow the architecture

- **Per user, with per-host exceptions.** Phase 1 certificates are DNS-01 wildcards,
  so one probe decides every dot-form name of a user. The per-host part is the force
  override. A reported host list (architecture §4.1) is only needed for HTTP-01
  per-name certs: Phase 2.
- **The box learns it is delegated from the backend**, not from a new contract key:
  `/resolve/v2` gains a `dns` block, and the self-check reads it. Works the same for
  Yundera and FOSS boxes.
- **Gateway = existing Traefik + OpenResty, unchanged code.** Traefik gets a DNS-01
  cert resolver against our backend and a router for delegated names; OpenResty
  already parses dot form. The OpenResty edge mode (SNI passthrough, ACME
  forwarding) moves to Phase 2: passthrough needs tunnel work (§0) and ACME
  forwarding only serves HTTP-01, which Phase 1 doesn't use.
- **Stock PowerDNS, no DNS code of ours** (revised 2026-10-23; replaces the Go
  `miekg/dns` service). The backend is the only writer, through the API of a hidden
  primary that ships as a sidecar of the backend stack; the public nameservers are
  PowerDNS secondaries (NOTIFY + AXFR, IP allowlist, catalog zone). Same image everywhere.
  DNSSEC only after the full zone move (architecture §10.5).
- **No new Firestore collection**: delegation and force live on the existing
  `nsl-router/{uid}` document; probe results in Redis.

## 2. Work packages

IDs are used in §3 (order) and §5 (checklist). Each package lists files, change,
why it is compatible, and tests.

### N — mesh-router-nameserver

**N1. PowerDNS config** (this repo: `deploy/primary/`, `deploy/secondary/`, no
code). Image `powerdns/pdns-auth-<major>` pinned by digest, the same on every node.

Settled by test on 2026-10-23 (harness `/d/workspace/tmp-claude/pdns-ipname/`):
`powerdns/pdns-auth-51` (5.1.5 tested; pin the current 5.1.x by digest at build).

- `deploy/primary/`: compose fragment to merge into the backend stack
  (`pdns-primary` service, SQLite volume, `api=yes` + `api-key` + `webserver` on the
  stack network only, `primary=yes`, `allow-axfr-ips` + `also-notify` = the
  secondaries' IPs, catalog producer zone `catalog.<zone>.invalid` (`pdnsutil zone
  set-kind … producer`), `default-soa-content=<ns1> hostmaster.@ 0 900 900 1209600 30`,
  `default-soa-edit-api=DEFAULT`). Port 53 published on a non-standard host port,
  firewalled to the secondaries. **No TSIG**: catalog member zones on the consumer get
  no `AXFR-MASTER-TSIG`, so required TSIG blocks their transfers (tested).
- `deploy/secondary/`: `secondary=yes`, catalog consumer of the primary
  (`zone create-secondary catalog.<zone>.invalid <primary>` + `set-kind … consumer`),
  `allow-notify-from` = the primary; `enable-lua-records=yes`,
  `lua-global-include-dir` → `deploy/secondary/lua/` (**`ipname.lua`, written and
  tested**, gated on the allowlist zone below), `lua-records-exec-limit=20000`; a
  start hook that creates `ip.<zone>` as a **native** zone idempotently (SOA/NS +
  `*.ip.<zone> LUA A ";return ipname4()"` and `AAAA ";return ipname6()"`, TTL 300).
  `enable-lua-record-updates` stays **off** on every node: Lua never travels by API or
  transfer.
- Primary start hook also creates `allow.<ip-zone>.invalid` (kind **primary** —
  `pdnsutil zone create` makes a native zone, which a catalog ignores — and catalog
  member); the backend fills it (B5). Env: `ZONE`, `IP_ZONE`, `NS_HOSTS`, `SOA_RNAME`,
  `PRIMARY_ADDR`, `PUBLIC_IP`.
- **Gate for the swap:** `test/ipname/` (corpus + `diff.sh`, README with the run
  commands): 579/581 identical to the sslip.io server, the 2 differences expected.
  Rerun against the real deploy before switching `ns-ip.inojob.com`.
- No shadow log or backend client here any more: the shadow log moves to the
  backend reconciler (B5), metrics come from PowerDNS's own `/metrics` webserver.

**N2. Deploy** (`deploy/docker-compose.yml` → `deploy/secondary/docker-compose.yml`).
The public NS hosts switch from `cunnie/sslip.io-dns-server@sha256:…` to the N1
secondary. Keep the `${PUBLIC_IP}:53` binding (systemd-resolved holds
127.0.0.53). On nasselle, the secondary reaches the primary over the backend stack
network; on any other host, over the published primary port.

**N3. Static zone file** (`zones/inojob.com.zone`, `zones/nsl.sh.zone`,
`scripts/check-zone.sh`). From the Cloudflare export (still to get). The check
queries each record against Cloudflare's NS and fails on drift; run it in CI on a
schedule. **Not served** in Phase 1.

### B — mesh-router-backend

**B1. Delegation and force fields** (`DataBaseDTO/DataBaseNSLRouter.ts`,
`services/Domain.ts`). Optional `dns?: { delegated?: boolean; force?:
"auto"|"gateway"|"direct"; hostForce?: Record<string, "gateway"|"direct"> }` on
`NSLRouterData`. Absent = not delegated, auto.

**B2. Probe** (new `services/DnsProbe.ts`, scheduled in `index.ts` beside the
cleanup cron). For delegated users only, every 10 min and on route registration:

1. public IP = `ip` of the user's `source: "agent"` routes (`Routes.ts:109-137`);
   none → no direct answer;
2. TLS to `publicIp:443` with SNI `<label>.<zone>` and SNI
   `mesh-probe.<label>.<zone>` (exercises the wildcard), verified against the
   **system** CA only (unlike `RouteValidator.ts:57-100`, which also accepts the mesh
   CA and any HTTP status);
3. store `dns:state:<uid>` in Redis: `{publicIp, probeOk, certNotAfter, issuer,
   reason, at}`, TTL 1 h (stale state = not direct).

Also extend `RouteValidator`? No: it decides route acceptance and must keep
accepting the mesh CA.

**B3. acme-dns API** (new `services/AcmeDns.ts`, mounted in `RouterAPI.ts` as
`POST /acme-dns/update`):

- headers `X-Api-User: <userid>`, `X-Api-Key: <sig>`; verify like
  `RouterAPI.ts:276-287`;
- body `{subdomain, txt}`: `subdomain` must equal the user's `domainName`; `txt` must
  be 43 base64url characters;
- store in Redis list `acme:txt:<domainName>`, keep the last 2 values, TTL 600 s,
  then `DnsZones.sync(label)` (B5) writes the TXT RRset on the primary before
  answering (expiry is applied by the next full pass);
- rate limit: 10 updates per user per hour (Redis counter);
- response as acme-dns: `{"txt": "<value>"}`.

**B4. Gateway credential: lego `httpreq`** (same service, `POST /acme-dns/present`
and `/cleanup`, `Authorization: Bearer SERVICE_API_KEY` via
`authenticateService`, `ExpressAuthenticateMiddleWare.ts:90`). Body `{fqdn, value}`;
fqdn must be `_acme-challenge.<label>.<zone>.` for a **delegated** label. This is how
Traefik (lego) obtains `*.<label>.<zone>` for the gateway. Same store and same sync
as B3.

**B5. Zone reconciler** (new `services/PowerDns.ts` API client, new
`services/DnsZones.ts`; replaces the 2026-10-22 pull endpoint `/dns/v1/zone/:label`).

- `PowerDns.ts`: thin client over the PowerDNS HTTP API (`GET/POST/DELETE
  /api/v1/servers/localhost/zones…`, `PATCH` RRsets with `changetype REPLACE|DELETE`),
  env `PDNS_API_URL`, `PDNS_API_KEY`. Unset = reconciler disabled (all existing
  deployments).
- `DnsZones.desired(label)`: from the `dns` block (B1), `dns:state` (B2), route
  freshness and `acme:txt:*` (B3):

  ```jsonc
  {
    "zone": "wisera.inojob.com.",
    "rrsets": [
      {"name": "wisera.inojob.com.",   "type": "A",   "ttl": 30, "records": ["80.241.218.30"]},
      {"name": "*.wisera.inojob.com.", "type": "A",   "ttl": 30, "records": ["80.241.218.30"]},
      {"name": "immich.wisera.inojob.com.", "type": "A", "ttl": 30, "records": ["151.115.96.14"]},
      {"name": "_acme-challenge.wisera.inojob.com.", "type": "TXT", "ttl": 60, "records": ["\"…\""]}
    ]
  }
  ```

  Gateway answer = env `DNS_GATEWAY_IPS`; NS set = env `DNS_NS_HOSTS`.
- `DnsZones.sync(label)`: create the zone if missing (kind `Primary`, NS set,
  `catalog` = the producer zone), diff against `GET` on the zone, `PATCH` only what
  differs, then **`PUT /zones/<zone>/notify`** (an API write sends no NOTIFY by
  itself: ~1 s to the secondaries with it, up to 60 s without, measured). `delegated=false` → delete the zone. One log line per change ("wisera:
  A direct 80.241.218.30 → gateway, reason probe failed") = the shadow log.
- **Allowlist** (`DnsZones.syncAllow()`): `<key>.allow.<ip-zone>.invalid` A/AAAA for
  every public agent-route IP (`Routes.ts` `source: "agent"`, filtered with
  `Probe.ts` `isLanOrReserved`), key = dashed IPv4 or 32-digit expanded IPv6. Added
  from `POST /routes/:userid/:sig` when the IP is new (then notify); removed by the full
  pass once unseen for `DNS_ALLOW_GRACE` (env, default 6 h; last-seen per IP in Redis).
  Applies to every user, delegated or not: it is what `ip.<zone>` answers.
- Triggers: B2 probe result, B3/B4 TXT, B7/B9 force, B9 delegate; plus a full pass
  every 60 s over delegated users (drift, route expiry, TXT expiry) and over the
  primary's zones (delete zones of users no longer delegated).
- Compatibility: off unless `PDNS_API_URL` is set; without delegated users it writes
  nothing.

**B6. `/resolve/v2` additive field** (`RouterAPI.ts:481-510`): `dns: {delegated,
answer, certNotAfter}`. Old gateways and the Worker ignore it; the box self-check
(T3) reads `delegated`.

**B7. Owner force API** (`PUT /dns/v1/force/:userid`, body `{force, host?}`): the
owner's Firebase token (`authenticate`, uid must match) may set `gateway` or `auto`
only. Nothing else goes through HTTP: `direct` and delegation are admin actions in
B9.

**B9. Admin commands in `mesh-cli`** (`src/cli/index.ts`, new
`src/scripts/dns-*.ts`, same `main(argv)` shape and table helpers as the usage
commands). Run with `docker compose exec mesh-router-backend mesh-cli …`; they write
Firestore/Redis directly with the backend's own credentials, so no admin role and no
new endpoint:

- `dns status <user> [--json]`: `dns` block, `dns:state`, last probe, cert expiry,
  the answer each known host would get;
- `dns delegate <user> on|off`: sets `dns.delegated` and prints the matching
  `<user>.<zone> NS …` record to add/remove in Cloudflare (O4 stays manual);
- `dns force <user> [--host <name>] auto|gateway|direct`: `direct` prints a warning
  and asks for `--yes`;
- `dns acme <user>`: current `acme:txt:*` values and the per-user update count
  (debugging B3);
- `dns sync [<user>|--all]`: run B5 now and print what changed (`--dry-run` prints
  the diff only);
- `dns status` also prints the zone's SOA serial on the primary and on each
  `DNS_NS_HOSTS` entry (a lagging secondary shows up here).

**B8. Reserved labels** (`services/Domain.ts:65`, enforcement in
`updateUserDomain` :115). Extend `RESERVED_DOMAINS` with `ip`, `ns`, `ns1`…`ns9`,
`ns-ip`, `ns1-ip`, `ns2-ip`, `gw`, `gateway`, `mail`, `acme`, `router`, `s1`, `s2`,
`mesh-probe`, `entrypoint`, `dns`, and every label in the static zone (N3). Enforce
it in `updateUserDomain`, not only in `/available`. One-off audit: list existing
`domainName`s that hit the list (expected none).

**Tests** (`src/tests/`, Docker per `backend-dev/test.sh`, which gains a
`pdns-primary` service): `acme-dns.spec.ts` (wrong user, wrong subdomain, bad txt,
rate limit, expiry), `dns-zones.spec.ts` (desired state per case; against the real
PowerDNS container: create, idempotent second sync = no PATCH, flip, TXT, delete),
`reserved.spec.ts`; the probe gets a unit test with a local TLS server and a test CA
injected.

### C — mesh-router-caddy

**C1. Pinned xcaddy image** (`Dockerfile`):

```dockerfile
FROM caddy:2.11-builder-alpine AS build
RUN xcaddy build \
      --with github.com/lucaslorentz/caddy-docker-proxy/v2@<tag> \
      --with github.com/caddy-dns/acmedns@<tag>
FROM caddy:2.11-alpine
COPY --from=build /usr/bin/caddy /usr/bin/caddy
RUN apk add --no-cache inotify-tools curl jq
COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
```

`entrypoint.sh:222` runs `caddy docker-proxy`; the module provides that subcommand,
so nothing else changes. `ci-alpine` floats: mesh-router-caddy 1.2.7 runs **Caddy
v2.11.4 + docker_proxy v2.13.1** (checked 2026-10-22), so pin those two. **Compatibility:** same Caddyfile, same behaviour; the acmedns module is
unused until T3 writes a block.

**C2. Verified 2026-10-22** on the real `mesh-router-caddy:1.2.7` image with the T1
Caddyfile, a labelled test app and `tls internal` standing in for the DNS-01 issuer
(harness: `/d/workspace/tmp-claude/caddy-wildcard-test/`, `run.sh`):

- **`auto_https prefer_wildcard` does not exist in 2.11** (`must be one of 'off',
  'disable_redirects', 'disable_certs', 'ignore_loaded_certs'`). Worse,
  caddy-docker-proxy then **drops the whole global block** (email, acme_ca, issuer
  chain, log filter) with an `[ERROR] Removing invalid block` line and serves on.
  Not needed: with a `*.<domain>` site present, Caddy 2.11 orders **no** cert for a
  covered label site (`immich.<domain>`: zero `tls.obtain`; without the wildcard
  site: one obtain). Re-check on wisera with the real acmedns issuer (§5 #4).
- Non-delegated T1 config (`site_tls` = `import gateway_tls`, empty
  `wildcard.caddy`): the adapted JSON is **identical** to today's. An empty import
  only logs `Import file is empty`; a snippet defined in an imported file may import
  `gateway_tls`. A missing file was not tested: T3 always writes both.
- Routes: exact hosts sort before `*.<domain>`, so label routes win and the wildcard
  site only catches unknown dot names.
- **The entrypoint's catch-all TLS policy hides the wildcard**: it pins `any_tag:
  cert0` on the match-less policy (`entrypoint.sh:69-107`), so every SNI without its
  own policy (dot-form names and the root) gets the gateway cert even though Caddy
  holds the wildcard. Inserting `{"match":{"sni":["<domain>","*.<domain>"]}}` before
  it (like the `*.sslip.io` passthrough) fixed it live: dot names → `*.<domain>`, root
  → its own cert, dash names and unknown hosts → cert0 unchanged. → **C3**.
- The gateway verifies the box against the system bundle plus the mesh CA
  (`mesh-router-gateway/entrypoint.sh:43`, `gateway.conf:79-80`), so the box serving
  the LE wildcard to the gateway is fine.

**C3. Zone passthrough policy** (`entrypoint.sh`, catch-all jq at :99-107). Read
`/data/dns/tls_passthrough` (one SNI pattern per line, absent = none) on every loop
iteration and insert one `{"match":{"sni":[…]}}` policy right before the cert0
catch-all, next to `*.sslip.io`; extend the "already injected" check so a changed
file re-injects. Absent file = today's behaviour exactly.

### T — mesh-router-template-root (and template-root)

**T1. Caddyfile hooks** (`Caddyfile`):

- **no** `auto_https prefer_wildcard` (C2: invalid in 2.11, and it would drop the
  whole global block);
- `import /data/dns/site_tls.caddy` near the top, which defines a `(site_tls)`
  snippet;
- the `{$DOMAIN}` root block (:93-107) imports `site_tls` instead of `gateway_tls`;
- `import /data/dns/wildcard.caddy` at the end (empty unless delegated).

New volume in `docker-compose.yml:113-116`: `${DATA_ROOT}/AppData/mesh/data/dns:/data/dns:ro`.

**T2. Caddy pin** (`docker-compose.yml:95`) to the C1+C3 release.

**T3. `scripts/self-check/ensure-dns-delegation.sh`** (new; in
`scripts-config.txt` after `ensure-public-ip`, before `ensure-routing-domains`):

1. `GET <backend>/router/api/resolve/v2/<label>` → `dns.delegated`;
2. not delegated: write `site_tls.caddy` = `(site_tls) { import gateway_tls }` and an
   empty `wildcard.caddy`; unset `DNS_DOT_FORM` in `.env`; done (today's behaviour);
3. delegated: write `wildcard.caddy` (`*.{$DOMAIN}` only: `{$DOMAIN}` already has
   its block in the Caddyfile, and a second definition of the same address is
   rejected):
   ```
   *.{$DOMAIN} {
       tls {
           dns acmedns {
               username {$ACME_DNS_USER}
               password {$ACME_DNS_KEY}
               subdomain {$ACME_DNS_SUBDOMAIN}
               server_url {$ACME_DNS_URL}
           }
       }
       reverse_proxy {$DEFAULT_SERVICE_HOST}:{$DEFAULT_SERVICE_PORT}
   }
   ```
   with the values derived from `PROVIDER_STR` (url, userid, sig) and `DOMAIN`, written
   to `.env` (or the mesh `.stack.env` holding secrets, per the stack-env split);
4. once Caddy's storage holds the wildcard (`caddy/data/caddy/certificates/*/wildcard_.<domain>/`
   with a future `notAfter`): `site_tls` = the same `tls { dns acmedns … }` block
   (the root is not covered by `*.<domain>`, so it gets its own DNS-01 cert: two
   orders per user per renewal), `tls_passthrough` = `<domain>` and `*.<domain>`
   (C3), and `DNS_DOT_FORM=1` in `.env`. Not delegated: `tls_passthrough` removed;
5. when a file changed, restart `mesh-router-caddy`. The entrypoint has no Caddyfile
   watcher on purpose (`entrypoint.sh:7-28`), and an admin-API reload would be
   overwritten by caddy-docker-proxy's next generation.

**Compatibility:** non-delegated boxes get byte-identical behaviour (`site_tls` =
`gateway_tls`, empty wildcard file).

**T4. Dot-form routing domain** (`scripts/library/common.sh:243-265`):

- `routing_domains`: when `DNS_DOT_FORM=1`, add `dot|{name}.${DOMAIN}|` (no labels:
  the wildcard serves it) **after** `gateway`, so the dash form stays Maison's primary
  domain. Moving `dot` first (primary) is Phase 2;
- `routing_setting_json`: use the suffix as the template when it contains `{name}`,
  otherwise keep prefixing `{name}-`;
- `routing_host_suffixes` (:269-280): unchanged (it feeds the dash-form redirect
  check; see A1).

**T5. nip.io removal on the box side** (after W1 is live everywhere):

- `common.sh:243-253`: drop the `nip|…` line;
- platform labels: drop the `caddy_1 … nip.io` groups (files in §0) and in
  template-root `root/docker-compose.yml:130-141`, `root/template/stacks/kopia/docker-compose.yml:154-162`;
- `REDIRECT_HOST_SUFFIXES` fallbacks drop `${PUBLIC_IP_DASH}.nip.io`
  (`stacks/auth/docker-compose.yml:264,347`, `stacks/maison/docker-compose.yml:85`,
  `docker-compose.yml:206`; template-root literals `root/docker-compose.yml:42`,
  `stacks/kopia/docker-compose.yml:126`);
- Caddyfile `{$PUBLIC_IP_DASH}.nip.io` block (:47 in the image Caddyfile and its
  template copy);
- `README.md:295-317` `.env` table.

### A — mesh-router-auth (registrar)

**A1. Dot-form redirect hosts.** Accept `<client_id>.<suffix>` beside
`<client_id>-<suffix>` for the suffix `${DOMAIN}`, so SSO apps log in on dot-form
names. **AppShield needs no change** (checked 2026-10-22, `sandbox/AppShield`
8458606): it adopts the registrar's `redirect_uris` as its allowed origins
(`internal/oidcrp/oidcrp.go:316-321`), so dot-form callbacks follow A1. Its own
fallback list is dash-only (`internal/config/config.go:159-168`), used only with a
pre-1.2.0 registrar; `CANONICAL_ORIGIN` (the OAuth broker issuer) stays the dash host
and must not move. Without A1 a dot-form visit still logs in, but the callback lands
on the dash host and the user stays there. Session cookies are host-only
(`authn.go:346`, `oidcrp.go:623`), so the PSL entry changes nothing.

### M — mesh-router-agent

**M1. sslip.io routes replace nip.io** (`src/services/IpRegistrar.ts:286-304`):
register `buildDomainRoute(…, 'sslip.io')` where it registers nip.io today; keep the
`IP_ZONE` pair. The Worker needs domain-type routes (`index.ts:391-412`), so a box
without `IP_ZONE` (FOSS) still has one. Ship with W1. Template pin bump in
`docker-compose.yml:60`.

### W — mesh-router-gateway-cf

**W1. Fallback on sslip.io** (`src/index.ts:184-231`): when the ip.<zone> fetch fails
(`:201-209`), retry on `<app>-<ip-dashed>.sslip.io`, built from `route.ip` like
`buildIpZoneHost` (`:476-486`), so it works before and after M1. `X-Mesh-Force: nip`
→ `sslip` (keep `nip` as an alias until the docs are updated). Trace segment
`sslip.io`.

**W2. Honour the backend force** (`:96`, `:137-147`): `dns.force === "gateway"` in
the `/resolve/v2` answer behaves like `X-Mesh-Force: gateway`.

**Tests** (`test/index.spec.ts`, suite `ip.<zone> path` at :389): change the
nip.io expectations to sslip.io; add W2 cases. `pnpm test`.

### G — mesh-router-gateway

**G1. Hygiene, no behaviour change for valid traffic:**

- pin `FROM openresty/openresty:alpine` (`Dockerfile:4`) to a version;
- `resolver.lua:103`: `if not host:sub(-#suffix) == suffix` → `if host:sub(-#suffix) ~= suffix`
  (the suffix check never rejects today);
- `resolver.lua:517,541`: cache the unfiltered route list and filter per request, so
  the first request's scheme doesn't decide later hits;
- `doc/architecture/SERVER_DEPLOYMENT.md:81-95`: tunnel route is the tunnel server's
  address (`172.30.0.3` on staging), not the gateway's.

**G2. Traefik on the gateway host (staging nasselle, config only):**

- `traefik.yml`: a `certificatesResolvers.meshdns` with `acme.dnsChallenge.provider:
  httpreq`, env `HTTPREQ_ENDPOINT=http://mesh-router-backend-inojob:8192/router/api/acme-dns`
  and the service key as bearer (lego `HTTPREQ_*` variables), storage in a new
  `acme-dns.json`. **Static config: Traefik restarts**, which briefly drops every site
  on nasselle (staging: restart whenever, user OK 2026-10-22);
- `dynamic_conf.yml`: per delegated user, a router
  `Host(\`wisera.inojob.com\`) || HostRegexp(\`^[a-z0-9-]+\\.wisera\\.inojob\\.com$\`)`
  → the gateway service, `tls.certResolver: meshdns`, `tls.domains: [{main:
  "wisera.inojob.com", sans: ["*.wisera.inojob.com"]}]`. Hand-written for wisera in
  Phase 1; generated in Phase 2.

### D — mesh-dashboard

**D1. Read-only DNS state** (`app/pages/DomainsPage.tsx:50-85`,
`providers/mesh-router/DomainsAPI.ts`): `/domains/active` entries gain the `dns`
block (B6 shape) and the page shows *delegated*, *answer*, *cert until*, *reason*.
Also show the routes the backend already returns (the `DomainEntry` type drops them
today). Plus the owner's own toggle *route through the gateway* (B7, `gateway`/`auto`). Admin actions are not in the dashboard (B9).

### O — ops

- **O1** Cloudflare zone export for `inojob.com` and `nsl.sh` → N3.
- **O2** Mail: SPF `v=spf1 include:sendgrid.net ~all` (prod) after checking nothing
  else sends as `@nsl.sh`; DMARC `rua=`; contact alias destination decided.
- **O3** PSL submission (in progress); AppShield cookies checked host-only (A1).
- **O4** Staging: `wisera.inojob.com NS ns-ip.inojob.com`, TTL 300, added in
  Cloudflare (the existing `A ns-ip` record is the glue). A second staging nameserver
  host is the user's call; with one, a staging NS outage takes down wisera's
  dot-form names and apex (dash form unaffected).

## 3. Order (staging)

```
G1, B8, W1+M1 ──────────────────────────────► independent, ship any time
N1 ─► N2 (secondary replaces sslip.io on ns-ip.inojob.com, diff-gated)
B1..B9 (backend release) + pdns-primary sidecar in the staging backend stack ─► D1
C1+C3 ─► T1+T2+T3 ─► T4                (template main; no effect until delegated)
A1                                   (before dot-form SSO apps are tested)
G2 (Traefik resolver + wisera router)
O4 (delegate wisera) ─► §4 verification on wisera
T5 after W1+M1 are on the whole staging fleet
```

Mark wisera delegated (`nsl-router/{uid}.dns.delegated = true`, via `mesh-cli dns delegate wisera on`) **before** O4, so
the nameserver and Traefik are ready when the first query lands; T3 on wisera then
fetches the wildcard (DNS-01 works through the nameserver as soon as O4 is in
place).

## 4. Staging run on wisera

1. Before: `dig wisera.inojob.com`, `dig immich.wisera.inojob.com` → Cloudflare.
2. `mesh-cli dns delegate wisera on`; add the Traefik router (G2); add the NS record (O4).
3. `dig +trace immich.wisera.inojob.com` → our nameserver, `A` = gateway (no cert
   yet).
4. Run the self-check on wisera (or wait for 03:00): T3 writes the wildcard block,
   Caddy obtains `*.wisera.inojob.com` via B3. Backend log shows the TXT update.
5. Next probe: `dns:state` `probeOk`, answer flips to `A 80.241.218.30` within 30 s.
6. T3's next pass sets `DNS_DOT_FORM=1`; Maison renders dot-form labels.
7. **Rollback** at any step: delete the NS record (300 s), then clear
   `dns.delegated` with `mesh-cli dns delegate wisera off` (T3 restores `gateway_tls` on its next run).

## 5. Verification checklist

| # | Check | Expected |
|---|---|---|
| 1 | N1 vs sslip.io corpus diff | no difference |
| 2 | `immich-wisera.inojob.com` (dash) during the whole run | unchanged, Cloudflare + Worker |
| 3 | `wisera.inojob.com`, `immich.wisera.inojob.com` before cert | resolve to gateway, valid cert (Traefik `meshdns`) |
| 4 | Same after cert | resolve to box IP, cert `*.wisera.inojob.com` from Let's Encrypt |
| 5 | `mesh-cli dns force wisera --host immich gateway` (B9), then the same from the dashboard (B7) | that host → gateway within 30 s; others stay direct |
| 6 | Stop wisera's agent | routes expire → gateway → offline page |
| 7 | Stop the backend, then the primary | secondaries keep answering the last state; after restart the full pass converges with no manual step |
| 7b | Wipe the primary volume | full pass recreates every delegated zone; secondaries end with identical records |
| 7c | Edit a record by hand on the primary | next full pass restores it |
| 8 | Stop the nameserver | dot-form names fail (single staging NS); dash form fine |
| 9 | SSO app (A1) on dot form | login round trip OK |
| 10 | A non-delegated staging box | byte-identical Caddy config, no dot-form labels, no ACME orders |
| 11 | acme-dns with another user's credential | 401/403, nothing stored |
| 12 | W1: block ip.<zone> (stop N1) | Worker falls back on sslip.io, trace `ip-dns-fail,sslip.io` |

## 6. Open points

- **Tunnel reachability from a gateway not co-located with the tunnel server** (the
  planned new VPS): chain to the co-located gateway, or have the tunnel server
  announce a reachable route. Needed before that host serves NAT boxes.
- **Second staging nameserver**: host to choose (user).
- ~~`createForward()` parity~~ settled 2026-10-23: built-in rejected, own Lua include
  579/581 (N1).
- ~~PowerDNS major version~~ settled 2026-10-23: 5.1 (`pdns-auth-51`), same on
  primary and secondaries.
- ~~`ip.<zone>` gated on the allowlist~~ settled 2026-10-23: behaviour change against
  sslip.io checked, nothing uses ip names for a non-agent IP; grace 6 h, configurable
  (`DNS_ALLOW_GRACE`).

## 7. Phase 2 preview (not planned here)

OpenResty edge mode (TLS passthrough including tunnel L4, ACME forwarding,
termination with DNS-01 certs) replacing Traefik for user names; generated Traefik /
gateway config per delegated user; HTTP-01 per-name certs and the host list; batch
delegation; dot form as the primary name (Maison primary domain, platform stacks,
Dex issuer). DNSSEC after the full zone move (architecture §10.5).
