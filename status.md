# Status — box zone in caddy (2026-10-25)

Released (pushed): **mesh-router-caddy v1.4.0** (`14b53b0`) and template `b4f0f4f`:
the box decides its own zone TLS from the backend's `dns.live` (no `.env` flag, no
self-check script), dot form always on. Details: `implementation_notes.md`
"Box zone, revised".

- Staging backend on `ghcr.io/yundera/mesh-router-backend:2.0.33` (backup
  `docker-compose.yml.bak-2026-10-25-2033`); wisera still `live`, answer direct.
- wisera back on template `main` (`UPDATE_URL` = main tarball; backup
  `.env.bak-2026-10-25-main`), caddy `1.4.0` published image, zone file "delegated",
  root + dot names on Let's Encrypt; test image and tarballs removed.
- DNS monitor: `GET /router/api/dns/health` (backend, uncommitted), staging on
  `mesh-router-backend:2.0.34-health-local` (backup `docker-compose.yml.bak-2026-10-25-health`);
  UptimeRobot monitors on `https://inojob.com/router/api/dns/health` and later
  `https://nsl.sh/router/api/dns/health` (user).
- N3 decided: zone file in server_conf, loaded into the primary outside the catalog;
  needs the Cloudflare export (O1).
- Gateway certificate list (uncommitted): backend `GET /gateway/certs`, gateway
  `certlist.lua` (only listed users are fetched; dash-name handshakes cost no backend
  call) + the per-worker certificate cache fixed (1.3.0 fetched on every handshake).
  Staging on `mesh-router-backend:2.0.35-certlist-local` and
  `mesh-router-gateway:1.3.1-certlist-local` (backups `*.bak-2026-10-25-certlist`).
- `data/dns/` cleanup: template migration `2026-10-25-10-remove-stale-dns-state.always.sh`
  (waits until the running Caddy no longer mounts it).
- Open (user, 2026-10-25): a switch (env or a button somewhere relevant) between the
  dash and the dot form as the box's primary name.
- Owner "route through the gateway" switch in mesh-dashboard: postponed to Phase 2
  (mesh-console has it; the backend route stays).

---

# Status — DNS delegation track (2026-10-24)

Plan and results: [`implementation_notes.md`](implementation_notes.md) ("Built", §5
results). **wisera.inojob.com is delegated** to nss1/nss2 (Cloudflare NS records,
TTL 300) and answers its own IP with its own Let's Encrypt certificates.

## Released (pushed)

| Repo | Release | What |
|---|---|---|
| mesh-router-backend | v2.0.29, v2.0.30, v2.0.31 | per-user zones + probe; acme-dns API + httpreq + owner toggle; gateway certificates (`GatewayCerts.ts`), `live` |
| mesh-router-gateway | v1.3.0 | TLS listener, certificate per SNI from the backend |
| mesh-router-caddy | v1.3.0, v1.3.1, v1.3.2 | acmedns module (pinned xcaddy), `tls_passthrough`, `tls_automate` |
| mesh-router-auth | v1.1.9 | `REDIRECT_DOT_SUFFIXES` |
| mesh-router-gateway-cf | v1.1.6 | owner force from the `dns` block; **staging deployed 2026-10-24** (version `1575954c`, rollback `56dbe7c0`): forced dash name traces `cf-worker,owner-force,gateway,agent,pcs` within the 60 s resolve cache |
| mesh-console | v1.7.0 | Nameserver card + "Route through the gateway" |
| mesh-dashboard | v2.3.4 | Nameserver column |
| mesh-router-template-root | `294cbaa`, `2589e87` (main) | DNS-01 wildcard for a delegated box, dot form, `set-dns-force.sh`; pins caddy 1.3.2, mesh-auth 1.1.9, mesh-console 1.7.0 |
| mesh-router-nameserver | v1.3.0 tag, v1.3.1 | v1.3.0 has **no CI image** (its push event was dropped; re-pushing an unchanged tag sends none). v1.3.1 = v1.3.0 + docs + `workflow_dispatch`; staging moves to `:1.3.1` once published |

Backend **v2.0.32**: catalog serial bumped on zone deletion, serial catch-up above the
secondaries, empty `hostForce` removed.

## Where staging is

- Backend `mesh-router-backend:2.0.32-serial-local` (= v2.0.32; switch to the published
  image), `DNS_SHADOW_ZONES=0` (delegated users only = wisera;
  the other shadow zones were removed), `GATEWAY_ACME_DIRECTORY` = Let's Encrypt.
  Compose backups `…/backend/docker-compose.yml.bak-2026-10-24-*`.
- Gateway `ghcr.io/yundera/mesh-router-gateway:1.3.0` + TCP passthrough labels
  (`HostSNIRegexp(^.+\.inojob\.com$)`, port 8443, PROXY v2). Backup `.bak-2026-10-24-tls`.
- Primary + nss2 `:a45078f`; nss1 (51.15.79.231) `:a45078f`.
- wisera on template `main` (published images), `DNS_DOT_FORM=1`, `REDIRECT_DOT_SUFFIXES=wisera.inojob.com`.
- Worker v1.1.6 (W2) deployed on staging; prod Worker untouched.

## Open

- Checklist #12 (real ip.<zone> outage: needs both NS down). #9 passed in the browser
  (see implementation_notes §5 results).
- Rotate the staging SendGrid key (printed in a session log on 2026-10-24).
- Let's Encrypt pacing for batch delegation (implementation_notes §6) until the PSL entry.
- Out of scope for now: IPv6 (dot names have no AAAA), second gateway host and tunnel
  reachability, prod rollout.

## Gotchas met (2026-10-24)

- PowerDNS does not bump a producer catalog's serial when a member zone is deleted:
  the secondaries keep serving it. A recreated zone starts at `YYYYMMDD01`, possibly
  below the secondaries' copy, which then ignore every change. Both handled by the
  backend now.
- Caddy automatic HTTPS skips a name a loaded certificate covers: cert0 (`*.<zone>`)
  covers the box root → `tls_automate`. `local/` in Caddy's storage = internal CA.
- `DNS_DOT_FORM` flip → one Maison republish (apps recreated, ~1 min of 502).
- lego httpreq sends only Basic auth.
- Pushing more than three tags at once: GitHub creates no tag events, so no CI image.

---

# Status — Phase 1 independent items (2026-10-23, end of day)

Plan: [`implementation_notes.md`](implementation_notes.md) §2–§3. This file covers the
items that ship without moving any zone to our nameserver: **G1, B8, W1, M1, T5**, plus
a backend fix found on the way. The nameserver track itself (N1/N2, backend
allowlist B-items) is the user's: see nameserver commits `9a4f240`, `3d83ea3`,
`a45078f` and backend `v2.0.27`.

Decision (user, 2026-10-23): **ip.<zone> replaces nip.io; sslip.io is untouched** and
stays as the alternative (box serves it with Let's Encrypt; the Worker falls back on it).

## Released (all pushed)

| Item | Repo | Commit / tag | What |
|---|---|---|---|
| G1 | mesh-router-gateway | `6a9018e` **v1.2.12** | openresty pinned 1.29.2.5; domain suffix check fixed; route cache unfiltered by scheme |
| G1 doc | mesh-router-root | `4279234` | `PROVIDER_ROUTE_IP` = the tunnel server's own address |
| B8 | mesh-router-backend | `276329d` **v2.0.26** | reserved labels (`ip`, `ns`, `ns1`–`ns9`, `gw`, `mail`, `acme`, …) refused on `/available` and on domain writes (existing holder keeps it). Audit: none in use, staging and prod |
| — | mesh-router-backend | `d9fd8b5` **v2.0.28** | known route sources mirrored in Redis set `routes:sources`: a restarted backend no longer hides agent routes for up to 5 min |
| W1 | mesh-router-gateway-cf | `f854247` **v1.1.5** | ip.<zone> failure falls back on `<app>-<ip>.sslip.io` (was nip.io); `X-Mesh-Force: sslip` (`nip` = alias) |
| M1 | mesh-router-agent | `21511de` **v1.1.3** | with `IP_ZONE`: only the `<ip>.<IP_ZONE>` route pair, priority 1; nip.io only without `IP_ZONE` (FOSS) |
| M1 pin | mesh-router-template-root | `6dd1f4d` | agent pinned 1.1.3 (`main` only) |
| T5 | mesh-router-template-root | `182ef31` | `routing_domains`: nip.io only when `IP_ZONE` is empty (labels, Maison routing, redirect hosts, template-root admin/kopia all follow); `migrate.sh` verifies the target on `mesh-console-$DOMAIN` pinned with `--resolve`; static Caddyfile root nip block kept |
| docs | agent `8b5c29b`, gateway-cf `62f07e9`, mesh-router-root `5392199`, template (in `182ef31`) | | route tables now describe the ip.<zone> model |

## Where each environment is

**Staging (inojob.com)**
- Worker: version `6f18ef17` (W1 code; rollback `a163fb13`).
- nasselle backend: `ghcr.io/yundera/mesh-router-backend:2.0.27` (your allowlist release,
  with the `pdns-primary` sidecar and the `nameserver` container on image `a45078f`),
  **not yet 2.0.28**. Compose backups `…/backend/docker-compose.yml.bak-2026-10-23-*`.
- nasselle gateway: `ghcr.io/yundera/mesh-router-gateway:1.2.12`. Backup `.bak-2026-10-23-g1`.
- wisera: agent `1.1.3` from template `main`. Routes: `80-241-218-30.ip.inojob.com`
  https+http priority 1, tunnel `172.30.0.3` priority 2. **T5 not on wisera yet**
  (pushed after its last self-check; arrives at 03:00 or on a manual run).
- Path matrix on wisera, all 302 (AppShield): default `cf-worker,ip-dns,pcs`;
  force `sslip`/`nip` `cf-worker,sslip.io,pcs`; `gateway` `cf-worker,gateway,agent,pcs`;
  `tunnel` `cf-worker,gateway,tunnel,pcs`.

**Prod (nsl.sh)**: nothing deployed from this list (out of scope for now). Template
`stable` does not carry M1/T5.

## Next (Monday)

Staging:
1. **Backend 2.0.28 on nasselle** (2.0.27 + the route-sources fix). Then restart the backend and check `/resolve/v2/wisera` lists agent
   routes immediately. *Blocked on 2026-10-23 by the auto-mode permission check
   for compose edits on nasselle — approve or add a rule.*
2. **T5 on wisera**: run `sudo /DATA/AppData/yundera/template/scripts/self-check/ensure-mesh-installed.sh`;
   expect no `nip.io` labels (`docker inspect` / Caddy config), one Maison republish,
   dash-form URLs still 302/200, `REDIRECT_HOST_SUFFIXES` without nip.io.
3. **Checklist #12, real outage**: stop the staging nameserver on nasselle
   (`ns-ip.inojob.com` = 151.115.96.14) for ~1 min; an uncached name
   (`xyz-wisera.inojob.com`) → `cf-worker,ip-dns-fail,sslip.io,pcs`. Boxes whose route
   refresh lands in that window get their routes rejected and wait on the tunnel.

Follow-ups (nothing breaks meanwhile):
4. pcs-orchestrator `src/scripts/list-health-check.ts` HEADs `<ip>.nip.io`: now a false
   "ok" via Caddy's catch-all; retarget to `<ip>.<IP_ZONE>`.
5. mesh-console Domain/Certificates pages show the nip.io name; settings-center
   string "Backup address (sslip.io / nip.io)"; demo's own `demo-auth-<ip>.nip.io` label.
6. Meta-root (`mesh-router-root`) submodule pointers to today's commits.

Decisions (user):
7. **Second nameserver**, staging and prod — more pressing since M1 (route validation
   goes through our single nameserver).
8. **Prod rollout**, in this order: Worker `pnpm deploy:prod` (note the current version
   first) → backend 2.0.28 → gateway 1.2.12 → template `stable` promotion (carries agent
   1.1.3 + T5 together; must come after the Worker, or prod boxes lose the nip.io
   fallback the old Worker relies on).

## Gotchas met

- Windows checkouts: several working copies show CRLF on every file. Commit only the
  files you changed and check `git show --stat` for whole-file rewrites.
- Backend tests: the dev `.env` (`SERVER_DOMAIN=inojob.com`) makes 21 route tests fail
  on validation; unrelated to these changes. Stale `dist/tests/dnsdirect.spec.js`
  breaks mocha: delete it. Use `mocha --exit`.
- Docker here is the host engine: bind-mount `/d/workspace/...`, never `/tmp/...`.
