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
