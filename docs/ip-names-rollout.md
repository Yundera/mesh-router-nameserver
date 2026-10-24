# ip.<zone> nameserver — rollout cookbook

**Status: LIVE ON STAGING 2026-10-21** (`inojob.com`, nameserver on the nasselle staging
server, staging worker `a163fb13`) **and ON PROD 2026-10-22** (`nsl.sh`, one nameserver on
`yundera-prod`, prod worker `d6b87118`, box side shipped on the `stable` channel). Prod
record: §3.6.

What this ships: the Cloudflare Worker reaches each PCS through our own nip.io-style
subzone (`<app>-<ip>.ip.<zone>`) instead of nip.io. Design and the tests that justify it:
[`ip-names.md`](ip-names.md) (§7.5 delegation, §7.6 `resolveOverride`).

## 1. Moving parts

| Piece | Where | Notes |
|---|---|---|
| Nameserver | `mesh-router-nameserver/deploy/` → `/workspace/config/<stack>/nameserver/` on the control-plane server | `cunnie/sslip.io-dns-server`, pinned by digest, UDP+TCP 53 on the public IP. `docker-compose.peer.yml` for a two-server pair |
| Delegation | Cloudflare, the zone itself | `A <ns-host>` (DNS only) + `NS ip → <ns-host>` |
| Worker | `mesh-router-gateway-cf`, var `IP_ZONE` | Set → fetch the original URL with `cf.resolveOverride = <app>-<ip-dashed>.<IP_ZONE>`; Cloudflare 52x/530 or exception → bodyless requests retry on nip.io. `X-Mesh-Force: nip` skips it |

Nothing changes on the boxes: Host and SNI stay `<app>-<user>.<zone>`, which every box
already serves (`caddy_0` labels, `*.<zone>` SAN). nip.io stays in place as the fallback
and for the agent, backend route validation, auth suffixes and Caddy (§5).

## 2. Staging (inojob.com) — as executed 2026-10-21

### 2.1 Nameserver

```bash
# from mesh-router-nameserver/deploy/
ssh ubuntu@151.115.96.14 'mkdir -p /workspace/config/mesh-router/nameserver'
scp docker-compose.yml compose-update.sh ubuntu@151.115.96.14:/workspace/config/mesh-router/nameserver/
scp .env.example ubuntu@151.115.96.14:/workspace/config/mesh-router/nameserver/.env   # values are staging's
ssh ubuntu@151.115.96.14 'cd /workspace/config/mesh-router/nameserver && docker compose up -d'
```

`.env`: `PUBLIC_IP=151.115.96.14`, `NS_HOST=ns-ip.inojob.com`, `SOA_RNAME=dns.inojob.com`,
`SOA_SERIAL=2026102101`. Container `nameserver-nameserver-1`.

Check from outside (Scaleway's security group let UDP/TCP 53 through without a change):

```bash
dig +short @151.115.96.14 app-1-2-3-4.ip.inojob.com        # 1.2.3.4
dig +short +tcp @151.115.96.14 app-1-2-3-4.ip.inojob.com   # 1.2.3.4
```

### 2.2 Cloudflare (inojob.com)

| Type | Name | Value | Proxy |
|---|---|---|---|
| A | `ns-ip` | `151.115.96.14` | DNS only |
| NS | `ip` | `ns-ip.inojob.com` | — |

**Since 2026-10-23** (PowerDNS secondaries, `deploy/secondary/`): two nameservers, renamed
after their hosts. `ns-ip` is gone from the delegation; its `A` record is removed once
nothing resolves it any more.

| Type | Name | Value | Proxy |
|---|---|---|---|
| A | `nss1` | `51.15.79.231` (own host) | DNS only |
| A | `nss2` | `151.115.96.14` (nasselle, next to the primary) | DNS only |
| NS | `ip` | `nss1.inojob.com` | — |
| NS | `ip` | `nss2.inojob.com` | — |

Both nodes: `NS_HOSTS=nss1.inojob.com,nss2.inojob.com`; primary `DNS_SOA_NS=nss1.inojob.com`.
The `.env` must list exactly the Cloudflare `NS ip` set. DNS only matters: `*.inojob.com`
is a proxied wildcard, so a proxied NS host would resolve to Cloudflare.

Check: `dig NS ip.inojob.com @peaches.ns.cloudflare.com +norec` shows the NS in the
AUTHORITY section (`dig +short NS` prints nothing for a delegation — that is normal), and
`dig +short @1.1.1.1 app-1-2-3-4.ip.inojob.com` returns `1.2.3.4`.

### 2.3 Worker

`wrangler.jsonc` → `env.staging.vars.IP_ZONE = "ip.inojob.com"`, then from
`mesh-router-gateway-cf/`: `pnpm test` (19/19) and `pnpm deploy:staging`.
Previous staging version, for rollback: `350252ef-ea50-44f5-ac9a-7370b3476a1a`.

### 2.4 Verification results

| Check | Result |
|---|---|
| `curl -sD- -o/dev/null -H 'X-Mesh-Trace: 1' https://maison-wisera.inojob.com/` | `302`, `x-mesh-route: cf-worker,ip-dns,pcs` |
| same with `-H 'X-Mesh-Force: nip'` | `cf-worker,nip.io,pcs` |
| Root `wisera.inojob.com`, `auth-wisera` | `ip-dns` |
| All online staging boxes (wisera, demostaging2, followingcaterpillar), root + `maison-` | `ip-dns` |
| Redirect `Location` (AppShield login) | identical on both paths |
| Headers seen by the app (echo container) | `Host`, `X-Forwarded-Host`, `X-Original-Host` = user name on both paths |
| WebSocket (echo, `ws` client) | echo OK on both; SNI capture on wisera: user name (ip-dns) then `…nip.io` (forced) |
| POST with JSON body | `200`, body echoed, `ip-dns` |
| Latency `auth-wisera`, 20 requests each | median 0.134 s (ip-dns) vs 0.131 s (nip) — same box, same cost |
| **Fallback drill**: nameserver stopped, never-seen names | `200/302`, `cf-worker,ip-dns-fail,nip.io,pcs`, **~1.5 s** per request (vs ~0.2 s); back to `ip-dns` on restart |
| Nameserver serving the delegation | ✅ after `A ns-ip` moved to `151.115.96.14` (16:20 UTC): `docker logs nameserver-nameserver-1` shows the `…ip.inojob.com` queries from Cloudflare resolvers (`172.71.x`). For a few minutes a resolver still used the old address (A record TTL 300 s) — keep the old NS running ~10 min when moving `ns-ip`. The fallback drill above ran against the interim test NS on holyhorse; same server, same behaviour |

Answers carry a 3600 s TTL, so an outage only costs the fallback for names Cloudflare
hasn't cached yet; cached names keep working for up to an hour.

### 2.5 Direct `<app>-<ip>.ip.<zone>` names on the box (2026-10-21)

Optional, and separate from the worker path above: lets a browser or a client open an
app straight on `https://immich-80-241-218-30.ip.inojob.com/`, like the nip.io names.
Two pieces:

**Box certificate SAN — backend `CERT_EXTRA_SANS`.** The mesh CA signs every box
certificate with `*.<SERVER_DOMAIN>`, `*.nip.io` and the IP. A wildcard covers one label
only, so `*.inojob.com` does not cover `x.ip.inojob.com`. New backend env var
`CERT_EXTRA_SANS` (comma-separated DNS names, default none) adds names per deployment.

- Staging backend (`/workspace/config/mesh-router/backend/docker-compose.yml`, backup
  `docker-compose.yml.bak-2026-10-21-certsans`): `CERT_EXTRA_SANS=*.ip.inojob.com`. First
  run on a local build of v2.0.24 + this change; since the evening of 2026-10-21 on the
  released `ghcr.io/yundera/mesh-router-backend:2.0.25`.
- Boxes pick it up on their next certificate request (renewal, ≤ 72 h) or at once with
  `docker restart mesh-router-agent`. wisera: cert now
  `*.inojob.com, *.nip.io, *.ip.inojob.com, IP 80.241.218.30`.

**Maison domain.** Maison 1.1.77 (wisera) publishes every app on the box's further
domains (`settings.domains`, Settings › Domains). Added:

```json
{ "name": "ip", "domain": "${APP_PUBLIC_IP_DASH}.ip.inojob.com", "labels": { "import": "gateway_tls" } }
```

through `PUT /api/settings/domains` (from the box: `curl -X PUT -H 'Host: localhost'
http://<maison-app ip>:8080/api/settings/domains`). Saving republishes every app; immich
got `caddy_3: immich-${APP_PUBLIC_IP_DASH}.ip.inojob.com` (cloned from `caddy_0`, with
`import: gateway_tls`) in its override.

| Check | Result |
|---|---|
| `curl https://immich-80-241-218-30.ip.inojob.com/ --cacert <mesh CA>` | `200`, certificate verifies (name covered) |
| Browser | mesh-CA warning, same as nip.io names today |

The zone is spelled out in the domain entry because an app's environment has no
variable carrying the server domain (`APP_DOMAIN` is `wisera.inojob.com`). For the fleet
it should come from the deployment, as a managed setting the template writes (`maison
settings set domains --owner Yundera`, or `routing` with Maison's new routing setting)
from a template env value such as `IP_ZONE` — built the same day, §2.6. Apps behind
AppShield on this name finish login on `<app>-<user>.<zone>` (registered redirect URI)
until `ip.<zone>` is in the auth `REDIRECT_HOST_SUFFIXES` (§2.6).

### 2.6 Additive box config: `IP_ZONE` (2026-10-21)

The fleet version of §2.5, with nip.io untouched:

| Piece | Change |
|---|---|
| `mesh-router-agent` | `IP_ZONE` env: also registers `<ip-dashed>.<IP_ZONE>` routes (HTTPS + HTTP), one priority step behind nip.io (`buildAgentRoutes`). The backend validates each route on its own, so a zone route that fails leaves the nip.io ones in place |
| `mesh-router-template-root` | `IP_ZONE` in the mesh `.env` (README key table) → agent env and `APP_IP_ZONE` in Maison's `.env.app`; `ensure-maison-stack.sh` asserts Maison's managed `routing`: gateway, nip, `ip` (only with `IP_ZONE`), sslip — hosts templated with `${APP_…}` |
| `template-root` | `mesh.sh` writes `IP_ZONE=ip.<server domain>` into the mesh `.env` once `<box-ipv4-dashed>.ip.<server domain>` resolves to the box (`getent`); `.pcs.env` `IP_ZONE` overrides, empty turns it off; a failed lookup changes nothing |

So a box turns it on by itself at the first self-check after its zone's `ip.` subzone is
delegated (§3.2) — on prod, from 2026-10-22.

Tested on wisera with a `file://` tarball of the mesh template and a local agent image
(`mesh-router-agent:1.1.1-ipzone-local`): the contract writer added only
`IP_ZONE=ip.inojob.com` (second run: no change); the agent registered 4 routes and the
backend accepted all 4 (`80-241-218-30.ip.inojob.com` at priority 2); Maison 1.1.80 took
the managed routing ("Managed by Yundera"); immich got
`caddy_3: immich-${APP_PUBLIC_IP_DASH}.${APP_IP_ZONE}` → `immich-80-241-218-30.ip.inojob.com`
`200`; the worker path stayed `cf-worker,ip-dns,pcs`.

Login redirects: mesh template `b8a4eb0` (2026-10-22) derives the auth
`REDIRECT_HOST_SUFFIXES` from the same routing-domain list as Maison's `routing`
(`ensure-routing-domains.sh`), so `<ip-dashed>.<IP_ZONE>` is an allowed callback host
wherever the box routes apps on it. On `main` only as of 2026-10-22 (not in the `stable`
promotion of §3.6): until it reaches `stable`, a login started on an `ip.<zone>` name
finishes on `<app>-<user>.<zone>`.

Not covered yet: the platform stacks' own labels (`maison-…`, `auth-…`, `mesh-console-…`,
`admin-…`, `kopia-…` in the template compose files) — they are template-owned, not
Maison-generated, and an empty `IP_ZONE` would leave a broken host there, so they need a
conditional of their own. Those pages have no `ip.<zone>` name.

## 3. Prod (nsl.sh) — cookbook

Prod is read-first: **the user runs these steps** (or authorizes them for a session).
Same shape as staging, plus an optional second nameserver. What was actually run on
2026-10-22 is in §3.6.

### 3.0 Decide first

- **Second nameserver host.** One is the prod control-plane server `yundera-prod`
  (`151.115.97.163`, `/workspace/config/mesh-router-nsl/`; public :53 free, resolved holds
  only 127.0.0.53/54, checked 2026-10-21). The other should be a different provider or at
  least a different machine. If there's none yet, prod can start with one, as staging did:
  a dead nameserver costs ~1.5 s on uncached names, never an outage (§2.4).
- Optional, before or after: zone SSL mode **Full (strict)** — see §4.

### 3.1 Nameserver(s)

On each host, from `mesh-router-nameserver/deploy/`:

```bash
ssh ubuntu@151.115.97.163 'mkdir -p /workspace/config/mesh-router-nsl/nameserver'
scp docker-compose.yml docker-compose.peer.yml compose-update.sh \
    ubuntu@151.115.97.163:/workspace/config/mesh-router-nsl/nameserver/
```

`.env` on host 1:

```
PUBLIC_IP=151.115.97.163
NS_HOST=ns1-ip.nsl.sh
SOA_RNAME=dns.nsl.sh
SOA_SERIAL=2026MMDD01
# only with a second host:
COMPOSE_FILE=docker-compose.yml:docker-compose.peer.yml
NS_PEER=ns2-ip.nsl.sh
NS_PEER_IP=<host 2 IP>
```

Host 2 mirrors it (`NS_HOST=ns2-ip.nsl.sh`, `NS_PEER=ns1-ip.nsl.sh`, `NS_PEER_IP=151.115.97.163`).

```bash
docker compose up -d && docker compose logs --tail 5     # "Ready to answer queries"
# from outside, for each host:
dig +short @<host-ip> app-1-2-3-4.ip.nsl.sh               # 1.2.3.4
dig +short +tcp @<host-ip> app-1-2-3-4.ip.nsl.sh          # 1.2.3.4
dig +short @<host-ip> NS ip.nsl.sh                       # both ns names with the peer file
```

If a `dig` from outside times out, open UDP and TCP 53 in the provider firewall
(Scaleway security group for `yundera-prod`).

### 3.2 Cloudflare (nsl.sh)

| Type | Name | Value | Proxy |
|---|---|---|---|
| A | `ns1-ip` | `151.115.97.163` | DNS only |
| A | `ns2-ip` | `<host 2 IP>` | DNS only |
| NS | `ip` | `ns1-ip.nsl.sh` | — |
| NS | `ip` | `ns2-ip.nsl.sh` | — |

The explicit `NS ip` records override the proxied `*.nsl.sh` wildcard for everything
under `ip.nsl.sh`. Check:

```bash
dig NS ip.nsl.sh @elisa.ns.cloudflare.com +norec | sed -n '/AUTHORITY/,/^$/p'
dig +short @1.1.1.1 app-1-2-3-4.ip.nsl.sh                 # 1.2.3.4
dig +short @8.8.8.8 app-1-2-3-4.ip.nsl.sh                 # 1.2.3.4
```

Nothing uses `ip.nsl.sh` yet at this point; this step is safe on its own.

### 3.3 Worker

In `mesh-router-gateway-cf/wrangler.jsonc`, top-level `vars`: add
`"IP_ZONE": "ip.nsl.sh"`. Then:

```bash
npx wrangler deployments list          # note the current version id for rollback
pnpm test
pnpm deploy:prod
```

The tests run against the top-level (prod) vars, so `vitest.config.mts` pins
`IP_ZONE` empty through `miniflare.bindings`; the ip.<zone> tests set it themselves.

### 3.4 Verify

```bash
# a few real boxes, root and an app
curl -s -D- -o /dev/null -H 'X-Mesh-Trace: 1' https://<user>.nsl.sh/ | grep -i x-mesh-route
#   → cf-worker,ip-dns,pcs
curl -s -D- -o /dev/null -H 'X-Mesh-Trace: 1' -H 'X-Mesh-Force: nip' https://<user>.nsl.sh/ | grep -i x-mesh-route
#   → cf-worker,nip.io,pcs
# nameserver sees Cloudflare's queries
docker logs --since 5m nameserver-nameserver-1 | grep -c 'ip.nsl.sh'
# watch for fallbacks in the worker logs (Cloudflare dashboard → Workers → Logs, or):
npx wrangler tail --format pretty | grep 'falling back to nip.io'
```

Also: one login round-trip through AppShield, one WebSocket app (terminal), one upload
(POST with a body — it is not retried, so it must work first time).

A steady trickle of `falling back to nip.io` means the nameserver is unreachable or a box
doesn't answer on its IP; a box behind NAT never reaches this path (no public route, or
private IP → gateway).

### 3.4b Box certificates and direct names (optional, §2.5)

1. Prod backend env: `CERT_EXTRA_SANS=*.ip.nsl.sh`, image → `mesh-router-backend:2.0.25`
   (or later), restart. Boxes pick it up at their next certificate request (prod
   `CERT_VALIDITY_HOURS=168`: within 7 days, at half-life) or at once with
   `docker restart mesh-router-agent`.
2. Box side: the `IP_ZONE` template changes (§2.6) reach customer boxes only through the
   `stable` channel — fast-forward `stable` to `main` in `template-root` and
   `mesh-router-template-root`. Each box enables it at its next self-check.

### 3.5 Rollback

| Symptom | Action |
|---|---|
| Anything worker-related | remove `IP_ZONE` from prod vars and `pnpm deploy:prod`, or `npx wrangler rollback <previous-version>` — instant, back to nip.io. Prod's pre-rollout version: `6aeebfa1-cd93-4e96-b959-d101223243cf` |
| Nameserver misbehaving | `docker compose down` on that host; the worker falls back on its own. Remove its `NS ip` record if it stays down |
| Full undo | both of the above, then delete the `NS ip` and `A ns*-ip` records |
| `CERT_EXTRA_SANS` | remove the variable and restart the backend; staging: restore `docker-compose.yml.bak-2026-10-21-certsans` (back to `ghcr.io/yundera/mesh-router-backend:2.0.24`); prod: restore `docker-compose.yml.bak-2026-10-22-certsans` (back to `2.0.23`) |
| Box side | push `stable` back: `template-root` `8941772`, `mesh-router-template-root` `ebb98b8` (the pre-rollout tips); boxes follow at their next self-check |

### 3.6 Prod record — as executed 2026-10-22

| Step | What was done |
|---|---|
| 3.0 | One nameserver (`yundera-prod`) for now; second host deferred. Zone stays *Full* (§4.1) |
| 3.1 | `/workspace/config/mesh-router-nsl/nameserver/` on `151.115.97.163`, container `nameserver-nameserver-1`; `.env` `NS_HOST=ns1-ip.nsl.sh`, `SOA_RNAME=dns.nsl.sh`, `SOA_SERIAL=2026102201`, no peer file. UDP + TCP 53 reachable from outside with no security-group change (the public IP sits on `eno1`) |
| 3.2 | `A ns1-ip` → `151.115.97.163` (DNS only), `NS ip` → `ns1-ip.nsl.sh`. 1.1.1.1, 8.8.8.8 and 9.9.9.9 answered `app-1-2-3-4.ip.nsl.sh` → `1.2.3.4` within minutes |
| 3.3 | Prod worker `d6b87118-f326-478d-9ccf-2abffa537d12` (gateway-cf `v1.1.4`), replacing `6aeebfa1` of 2026-06-03 — so the only code change was `bf5bb91` (v1.1.3) |
| 3.4 | `cf-worker,ip-dns,pcs` on yunderalabs, yunderateam, holyhorse, watch (root, `maison-`, `auth-`); `nip` force → `cf-worker,nip.io,pcs`; same status and AppShield redirect on both paths; latency equal or lower. `wrangler tail`, 75 s of live traffic: 116 requests, 0 fallbacks |
| 3.4b | Backend `2.0.23` → `2.0.25` + `CERT_EXTRA_SANS=*.ip.nsl.sh` (2.0.24 only adds a `reason` to availability answers). The prod compose files were CRLF — converted to LF on the way (backups `*.bak-2026-10-22-crlf`). holyhorse's new cert: `*.nsl.sh, *.nip.io, *.ip.nsl.sh, IP` |
| Box side | holyhorse (main channel) self-check by hand: `IP_ZONE=ip.nsl.sh`, routes at priority 2, Maison routing with `ip`, `immich-161-97-177-252.ip.nsl.sh` `200`. Then `stable` fast-forwarded to `main` (`template-root` `8266bed`, `mesh-router-template-root` `284161a`) — also shipping Maison 1.1.76 → 1.1.80, agent 1.1.2, admin app 2.2.1. mestio and yunderalabs self-checked by hand: same result, every store app has its `ip.nsl.sh` name. The rest of the fleet follows at its 03:00 run |

Side effects seen on the box side:

- **Every app restarts once.** Saving the managed `routing` republishes all apps, so each
  answers 502 for the length of its own start (Immich, Stirling-PDF: about a minute).
- **A registry hiccup marks the run failed.** yunderalabs' `ensure-stack-pulled.sh` died
  on a connection reset from ghcr.io (IPv6) pulling agent 1.1.2; `ensure-stack-up.sh` pulled
  it later in the same run, so nothing was missing, but the run reports "completed with
  failures".
- **The republish exposed a store bug.** Apps whose database starts as root and drops to
  its own uid while its data dir is listed in `x-compose-app.folders` (`$PUID`) get that dir
  chowned under the running database: Redis/Valkey then refuse writes (`MISCONF`), MariaDB
  cannot restart after its next stop (`tc.log`). Seen on yunderalabs (Docmost's Redis) and
  holyhorse (Outline's Redis); MariaDB dirs on mestio, yunderalabs and holyhorse were handed
  back to uid 999 before any restart. Store fixes: YunderaAppStore `16da613` (Docmost/Outline
  Redis as `$PUID`) and the folder-entry removal for root-started databases. A box already in
  that state needs `chown 999:999` on the MariaDB dir / a Redis restart.

## 4. Later (not part of this rollout)

1. **Zone SSL mode Full (strict).** Today's zones are *Full*, so the same-zone ip.<zone>
   hop is not certificate-checked, while the nip.io hop was (external fetch, COTS).
   Strict restores the check; with `resolveOverride` the SNI already matches the box
   certificate, so no cert change is needed. Flip staging first, audit the other proxied
   origins (apex router API, `gateway.entrypoint`), then prove it by pointing a
   `resolveOverride` at a box whose cert does **not** cover the name — it must now fail
   (`ip-names.md` §7.6, test 5).
2. **Remove nip.io from the rest of the stack:** agent route (`buildDomainRoute(…, 'nip.io')`),
   backend route validation (resolves `route.domain`), auth `REDIRECT_HOST_SUFFIXES`,
   Caddy `{$PUBLIC_IP_DASH}.nip.io` block and `caddy_1` labels, the `*.nip.io` SAN. Only
   after prod traces show no `ip-dns-fail` for a while.
3. **Phase 2 allowlist** — answer only for registered PCS IPs (`ip-names.md` §5).
4. **PSL** for `nsl.sh` (in progress) — needed before these names replace sslip.io.

## 5. What was not tested

- A two-server pair under real traffic (the peer file was only checked locally: both NS
  and both glue records answered). Prod runs one nameserver.
- On prod: a full login round-trip and a WebSocket app through the ip.<zone> path (both
  passed on staging; on prod only the login redirect and a POST were checked).
- IPv6 boxes through the ip.<zone> path (the name form `…-2001-bc8--1.ip.<zone>` resolves;
  no IPv6 box was online on staging).
- `http://` (port 80) requests through the path — the code takes the route's scheme and
  port as before, but only HTTPS was exercised.
- The sslip.io server's default phishing blocklist (fetched from GitHub at start) blocking
  a PCS IP: that IP would fall back to nip.io, which uses the same list.
