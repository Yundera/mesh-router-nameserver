# Phase 1 on prod (nsl.sh) — cookbook

Brings prod to what staging (`inojob.com`) runs since 2026-10-25: PowerDNS hidden primary +
secondary instead of the stock sslip.io server, per-user zones ready (none delegated),
gateway TLS edge, Worker owner force, and the box side (zone TLS in mesh-router-caddy,
dot form rendered beside the dash form). Written 2026-10-25 from staging's verified
config and a read-only look at prod.

**Prod is never automated: you run these steps.** Every step has its check and its
rollback; stop at the first check that fails.

## What users see

Nothing, for every user whose zone is not delegated (all of them: no NS record is added
for any user here). Two visible moments:

- **Step 4, the nameserver swap:** a few seconds without an answer for uncached
  `ip.nsl.sh` names (one nameserver on prod). The Worker (step 1) falls back to sslip.io
  for those requests.
- **Step 6, the template promotion:** at each box's next self-check (03:00), every app
  restarts once (new dot-form labels: ~1 min of 502 per app, as on 2026-10-22), Caddy and
  the platform stacks are recreated.

## Prod today (read 2026-10-25)

| Part | Prod | Staging (target) |
|---|---|---|
| Worker (gateway-cf) | `d6b87118` = v1.1.4 (2026-10-22) | v1.1.6 |
| Backend | `mesh-router-backend:2.0.25`, no PowerDNS | 2.0.36 + `pdns-primary` sidecar |
| Nameserver | `cunnie/sslip.io-dns-server` as `ns1-ip.nsl.sh` (151.115.97.163) | `mesh-router-nameserver:1.3.1` secondary |
| Gateway | `mesh-router-gateway:1.2.11`, HTTP only | 1.3.1, TLS listener + TCP passthrough |
| Demo | `pcs-demo:1.2.18` | 1.2.20 |
| Orchestrator | `pcs-orchestrator:1.10.0` | 1.10.1 |
| Dashboard | `mesh-dashboard:2.3.3` | 2.3.4 |
| Template `stable` | template-root `7526eee`, mesh template `e9a97c6` | `main`: template-root `a7bef5d`, mesh template `615b0dc` |

Checked, nothing to change:

- **Cloudflare SSL mode is "Full", not strict:** the origin serves Traefik's default
  self-signed certificate for every `*.nsl.sh` name and dash names answer through
  Cloudflare. The gateway's own fallback (step 5) is accepted the same way. **Do not move
  the zone to "Full (strict)"** after step 5: every dash name would fail (526).
- **Traefik on yundera-prod:** only the apex `nsl.sh` has routers of its own (landing,
  backend API, dashboard, tunnel API); everything under `*.nsl.sh` already goes to the
  gateway. The TCP passthrough rule of step 5 captures nothing else.
- **`ip.nsl.sh` is delegated to `ns1-ip.nsl.sh`** (A 151.115.97.163). The swap keeps that
  name and address: **no Cloudflare change in this cookbook.**

Config lives in `/workspace/config/mesh-router-nsl/<stack>/` (backend, gateway,
nameserver) and `/workspace/config/yundera/<stack>/` (pcs-demo, pcs-orchestrator).
Before each step: `cp docker-compose.yml docker-compose.yml.bak-<date>-phase1`.
Never print the stack `.env` files or `SERVICE_API_KEY` (session logs keep them).

## Order

```
1 Worker ─► 2 demo (+ orchestrator) ─► 3 backend + primary ─► 4 nameserver swap ─► 5 gateway ─► 6 template stable
```

- **1 before 4 and 6:** the swap's gap and agent 1.1.3 (no nip.io route any more) rely
  on the Worker's sslip.io fallback (v1.1.5+).
- **2 before 6:** the template-root promotion removes `PUBLIC_IP_DASH` from the yundera
  `.env`; demo 1.2.18 aborts every create on that (staging, 2026-10-23..25).
- **3 before 4:** the new nameserver only answers IPs on the backend's allowlist, filled
  by agent route registrations (about 10 minutes for the whole fleet).
- **3 before 5:** gateway 1.3.1 polls `GET /gateway/certs`, new in backend 2.0.35.

## 1. Worker v1.1.6

```bash
cd mesh-router-gateway-cf          # at v1.1.6 (584a167)
npx wrangler deployments list      # note the current version id (d6b87118…) for rollback
pnpm test
pnpm deploy:prod
```

Check on a few boxes (yunderalabs, yunderateam, holyhorse, watch), root and an app:

```bash
curl -s -D- -o /dev/null -H 'X-Mesh-Trace: 1' https://<user>.nsl.sh/ | grep -i x-mesh-route
#   → cf-worker,ip-dns,pcs
curl -s -D- -o /dev/null -H 'X-Mesh-Trace: 1' -H 'X-Mesh-Force: sslip' https://<user>.nsl.sh/ | grep -i x-mesh-route
#   → cf-worker,sslip.io,pcs
curl -s -D- -o /dev/null -H 'X-Mesh-Trace: 1' -H 'X-Mesh-Force: gateway' https://<user>.nsl.sh/ | grep -i x-mesh-route
#   → cf-worker,gateway,agent,pcs
```

Rollback: `npx wrangler rollback <noted version>`.

## 2. Demo 1.2.20 (and orchestrator 1.10.1)

`/workspace/config/yundera/pcs-demo/docker-compose.yml`: image `ghcr.io/yundera/pcs-demo:1.2.20`,
then `docker compose pull && docker compose up -d`. The fix reads `PUBLIC_IP_DASH` from the
mesh `.env` and no longer aborts without it; it is inert until a demo rebuilds.

Check at the next rebuild (demo1 07:05, demo 15:05 UTC), or trigger one:
`docker compose exec -T pcs-demo wget -qO- --post-data= http://localhost:3000/demo/admin/cleanup/demo1.nsl.sh`,
then `curl -s https://app.yundera.com/demo/api/health` → `ok`.

Optional, same pattern: orchestrator `1.10.1` (`pcs list-health-check` probes
`<ip>.ip.nsl.sh` instead of nip.io). No create may be running when it restarts.

Rollback: the previous image.

## 3. Backend 2.0.36 + PowerDNS hidden primary

One-time secret in `backend/.env` (compose reads it, nothing else does):

```bash
cd /workspace/config/mesh-router-nsl/backend
grep -q '^PDNS_API_KEY=' .env 2>/dev/null || echo "PDNS_API_KEY=$(openssl rand -hex 32)" >> .env
```

`docker-compose.yml`, on `mesh-router-backend-nsl` (the rest unchanged):

```yaml
    image: ghcr.io/yundera/mesh-router-backend:2.0.36
    networks:
      - webtraefik
      - mesh-internal
      - pdns-api
    environment:
      # … existing entries …
      # nameserver hidden primary: ip.<zone> allowlist
      - PDNS_API_URL=http://pdns-primary:8081
      - PDNS_API_KEY=${PDNS_API_KEY}
      - DNS_IP_ZONE=ip.nsl.sh
      # per-user zones: delegated users only (none on prod); NS = the one nameserver
      - DNS_GATEWAY_IPS=151.115.97.163
      - DNS_NS_HOSTS=ns1-ip.nsl.sh
      - DNS_SHADOW_ZONES=0
      # gateway certificates for live delegated users (none: nothing is ordered)
      - GATEWAY_ACME_DIRECTORY=https://acme-v02.api.letsencrypt.org/directory
```

New service and declarations (the nameserver of step 4 joins `dns-xfr` as `.11`):

```yaml
  pdns-primary:
    image: ghcr.io/yundera/mesh-router-nameserver:1.3.1
    restart: unless-stopped
    environment:
      - ROLE=primary
      - PDNS_AUTH_API_KEY=${PDNS_API_KEY}
      - DNS_SOA_NS=ns1-ip.nsl.sh
      - DNS_SECONDARY_IPS=172.16.53.11
    volumes:
      - pdns-primary-data:/var/lib/powerdns
    networks:
      pdns-api: {}
      dns-xfr:
        ipv4_address: 172.16.53.10
    cpu_shares: 256
    mem_limit: 256m
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  redis-data:
  ca-certs:
  pdns-primary-data:

networks:
  webtraefik:
    external: true
  mesh-internal:
    external: true
  pdns-api:
  dns-xfr:
    name: dns-xfr
    ipam:
      config:
        - subnet: 172.16.53.0/24
```

No published port: the only secondary is on this host.

```bash
docker compose pull && docker compose up -d
docker compose logs --since 2m mesh-router-backend-nsl | grep -E '\[dns\]|\[gwcert\]|Listening'
#   [dns] allowlist on: allow.ip.nsl.sh.invalid every 60s, grace 21600s
#   [dns] user zones on (delegated users): gateway 151.115.97.163, NS ns1-ip.nsl.sh
#   [gwcert] gateway certificates on: https://acme-v02…
```

After ~10 minutes, the allowlist holds every agent IP of the fleet:

```bash
docker compose exec -T pdns-primary pdnsutil zone list allow.ip.nsl.sh.invalid | awk '$4=="A"' | wc -l
#   ≈ the number of boxes with a public IP (pcs list-health-check, ipname column)
```

Also: `GET https://nsl.sh/router/api/resolve/v2/<user>` still answers (now with a `dns`
block: `delegated: false`); route re-registrations accepted in the log.

`/router/api/dns/health` reports **degraded (500)** until step 4: the sslip.io server
holds none of the primary's zones. Expected; don't create its monitor yet.

Rollback: restore the compose backup, `docker compose up -d` (the `pdns-primary` volume
can stay; it is disposable).

## 4. Nameserver swap (sslip.io server → PowerDNS secondary)

### 4a. Side by side on a spare port

The new secondary runs next to the sslip.io server first, on port 5353 of the same
address, so its answers can be compared before it takes port 53. New folder
`/workspace/config/mesh-router-nsl/nameserver-pdns/` with `docker-compose.yml` and
`docker-compose.colocated.yml` from this repo's `deploy/secondary/` (as on nasselle), and
`.env`:

```
PUBLIC_IP=151.115.97.163
PUBLIC_PORT=5353
IP_ZONE=ip.nsl.sh
NS_HOSTS=ns1-ip.nsl.sh
SOA_RNAME=dns.nsl.sh
CATALOG_ZONE=catalog.nsl.sh.invalid
PRIMARY_IP=172.16.53.10
COMPOSE_FILE=docker-compose.yml:docker-compose.colocated.yml
```

```bash
cd /workspace/config/mesh-router-nsl/nameserver-pdns && docker compose up -d
docker compose logs --since 2m | tail -20      # catalog consumer created, allow zone transferred
```

### 4b. Compare, answer for answer (on yundera-prod)

Every allowlisted IP, in both name forms, on both servers. The only accepted difference:
none for these names (sslip.io's extra `MX` and its own NS glue are not queried here).

```bash
cd /workspace/config/mesh-router-nsl/backend
docker compose exec -T pdns-primary pdnsutil zone list allow.ip.nsl.sh.invalid \
  | awk '$4=="A"{print $5}' | sort -u > /tmp/allow-ips
wc -l < /tmp/allow-ips
diffs=0
while read -r ip; do
  d=${ip//./-}
  for name in "$d.ip.nsl.sh" "maison-$d.ip.nsl.sh"; do
    a=$(dig +short @151.115.97.163 -p 53 "$name" A)
    b=$(dig +short @151.115.97.163 -p 5353 "$name" A)
    [ "$a" = "$b" ] || { echo "DIFF $name sslip=$a pdns=$b"; diffs=$((diffs+1)); }
  done
done < /tmp/allow-ips
echo "differences: $diffs"          # must be 0
dig +short @151.115.97.163 -p 5353 1-2-3-4.ip.nsl.sh A   # not allowlisted → empty (sslip.io answers 1.2.3.4: expected)
```

### 4c. Swap

```bash
cd /workspace/config/mesh-router-nsl/nameserver && docker compose down      # sslip.io server
cd ../nameserver-pdns && sed -i 's/^PUBLIC_PORT=5353/PUBLIC_PORT=53/' .env && docker compose up -d
```

The gap is the time between the two commands (seconds). Then, from outside:

```bash
for r in 1.1.1.1 8.8.8.8 9.9.9.9; do dig +short @$r maison-<a-box-ip-dashed>.ip.nsl.sh; done   # → the box IP
curl -s -o /dev/null -w '%{http_code}\n' https://nsl.sh/router/api/dns/health                # → 200
curl -s -D- -o /dev/null -H 'X-Mesh-Trace: 1' https://<user>.nsl.sh/ | grep -i x-mesh-route  # → cf-worker,ip-dns,pcs
npx wrangler tail --format pretty | grep -c 'falling back'       # a few during the gap, then none
```

Now add the UptimeRobot monitor on `https://nsl.sh/router/api/dns/health` (same settings
as staging's: 200 ok, 500 degraded, 503 down). Later, once nothing points back: move
`nameserver-pdns/` over `nameserver/` (keep the sslip.io files as `*.bak-<date>-sslip`, as
on nasselle).

Rollback: `docker compose down` in `nameserver-pdns/`, `docker compose up -d` in
`nameserver/` (the sslip.io server, untouched). The Worker covers the gap either way.

## 5. Gateway 1.3.1 + TLS passthrough

`/workspace/config/mesh-router-nsl/gateway/docker-compose.yml`, on `mesh-router-gateway-nsl`:

```yaml
    image: ghcr.io/yundera/mesh-router-gateway:1.3.1
    expose:
      - 80
      - 8443
    environment:
      # … existing entries (SERVICE_API_KEY is already set: it fetches the cert list) …
      - GATEWAY_TLS_PROXY_PROTOCOL=1     # behind Traefik's passthrough: client IP from PROXY v2
    labels:
      # … existing HTTP router labels unchanged (plain :80 and the apex) …
      - 'traefik.tcp.routers.mesh-router-gateway-nsl-tls.rule=HostSNIRegexp(`^.+\.nsl\.sh$$`)'
      - "traefik.tcp.routers.mesh-router-gateway-nsl-tls.entrypoints=websecure"
      - "traefik.tcp.routers.mesh-router-gateway-nsl-tls.tls.passthrough=true"
      - "traefik.tcp.routers.mesh-router-gateway-nsl-tls.service=mesh-router-gateway-nsl-tls"
      - "traefik.tcp.services.mesh-router-gateway-nsl-tls.loadbalancer.server.port=8443"
      - "traefik.tcp.services.mesh-router-gateway-nsl-tls.loadbalancer.proxyProtocol.version=2"
```

`$$` escapes `$` in compose. The rule needs a label before `.nsl.sh`, so the apex
`nsl.sh` keeps its HTTP routers. `docker compose pull && docker compose up -d`; give Traefik
~30 s to pick the container up (the first handshakes may still get Traefik's default
certificate or a 404 while it does).

```bash
for sni in nsl.sh holyhorse.nsl.sh files-holyhorse.nsl.sh; do
  echo "$sni: $(echo | openssl s_client -connect 151.115.97.163:443 -servername $sni 2>/dev/null | openssl x509 -noout -subject)"
done
#   nsl.sh                 → TRAEFIK DEFAULT CERT (apex, unchanged)
#   holyhorse.nsl.sh, …    → CN = mesh-router-gateway (the gateway's fallback)
curl -s -o /dev/null -w '%{http_code}\n' https://files-holyhorse.nsl.sh/               # 302, through Cloudflare
curl -s -D- -o /dev/null -H 'X-Mesh-Trace: 1' -H 'X-Mesh-Force: gateway' https://holyhorse.nsl.sh/ | grep -i x-mesh-route
#   → cf-worker,gateway,agent,pcs
curl -s https://nsl.sh/router/api/available/x$RANDOM                                   # backend API on the apex still answers
docker compose logs --since 2m | grep -m3 'GET'     # client addresses are real, not Traefik's
```

Also a login round trip through AppShield, a WebSocket app (terminal) and an upload on
one box, through Cloudflare.

Rollback: restore the compose backup (drops the TCP labels; Traefik terminates TLS
again), `docker compose up -d`.

## 6. Template `stable`

What the promotion carries (`git log origin/stable..origin/main` on 2026-10-25; re-run
it, other work may have landed):

- **mesh-router-template-root** `e9a97c6..615b0dc`: agent 1.1.3 (ip.<zone> routes only,
  no nip.io), T5 (nip.io routing domain only without `IP_ZONE`), the gate/registrar
  suffix fallback, `MESH_ROUTING_FORCE` + mesh-console 1.6.0 → 1.9.1 (Diagnostics, routing
  force, Nameserver card, App addresses), mesh-router-caddy 1.4.1 (zone TLS decided by
  Caddy itself, downgrade only after 3 readings), `MESH_PRIMARY_FORM` (the owner's
  dash/dot switch, inert until a box is delegated),
  dot form always on (store apps and platform stacks, Dex/Authelia dash only),
  mesh-auth 1.1.9, migrations `2026-10-25-01` and `2026-10-25-10`.
- **template-root** `7526eee..a7bef5d`: admin and kopia routes only from the mesh
  template's routing domains (`aba7424`: `PUBLIC_IP_DASH` leaves the yundera `.env`,
  hence step 2), admin app 2.2.3.

First on holyhorse (test box, prod config): put it on the `main` channel if it is not,
run its self-check, and check:

```bash
sudo bash /DATA/AppData/yundera/template/scripts/self-check.sh 2>&1 | tail -3   # completed successfully
sudo head -1 /DATA/AppData/mesh/data/caddy/data/mesh-zone.caddy                  # "zone not delegated."
sudo docker logs --since 30m mesh-router-caddy 2>&1 | grep -ci 'obtaining\|obtain certificate'   # 0
sudo docker inspect maison --format '{{json .Config.Labels}}' | grep -o 'maison.holyhorse.nsl.sh'  # dot label present
```

Then fast-forward `stable` to `main` in both repos (template-root and
mesh-router-template-root) and purge the jsDelivr installer cache for `@stable`
(`mesh-router-template-root/CLAUDE.md`, "PCS Installer Distribution"). Boxes follow at
03:00. The next morning: `pcs list-health-check` (all `ok`, `ipname` `ok`),
`pcs selfcheck-watch` (no failing box), a few boxes' Caddy logs (no orders for dot
names).

Rollback: push `stable` back to `7526eee` (template-root) and `e9a97c6` (mesh
template); boxes follow at their next self-check.

## 7. Optional

- Dashboard 2.3.4 (`/workspace/config/mesh-router-nsl/dashboard/`): Nameserver column on
  the Domains page.

## Record (fill while running)

| Step | Date | Notes (versions, backups, rollback ids) |
|---|---|---|
| 1 Worker | | previous version: |
| 2 Demo / orchestrator | | |
| 3 Backend + primary | | allowlist size after 10 min: |
| 4 Nameserver swap | | differences in 4b: , gap: |
| 5 Gateway | | |
| 6 Template stable | | template-root …, mesh template … |

## Not covered here

Delegating a prod user (pilot users, second prod nameserver, Let's Encrypt pacing):
later, see `implementation_notes.md` §6. The dash/dot switch (making the dot form the
primary name) is a separate design.
