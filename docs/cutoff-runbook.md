# Cutoff runbook — the zone leaves Cloudflare

> Phase 3 of [`architecture.md`](architecture.md) §13.3: the registrar points the zone at
> our nameservers, Cloudflare stops answering, the Worker is retired. Run by hand,
> **`inojob.com` (staging) first**, then `nsl.sh`. Written 2026-10-28; facts below were
> read that day, and §0 re-reads them.

| | staging | prod |
|---|---|---|
| zone | `inojob.com` | `nsl.sh` |
| registrar | Namecheap | to confirm |
| parent NS TTL (registry) | 172800 s (`.com`) | 3600 s (`.sh`) |
| DNSSEC at the parent | none (`delegationSigned: false`) | none (no DS at `a0.nic.sh`) |
| our NS (`DNS_NS_HOSTS`) | `nss1.inojob.com` 51.15.79.231, `nss2.inojob.com` 151.115.96.14 | `nsp1.nsl.sh` 51.15.79.11, `nsp2.nsl.sh` 151.115.97.163 |
| gateways (`DNS_GATEWAY_IPS`) | 151.115.96.14, 51.15.79.231 | 151.115.97.163 |
| host of the backend, primary, Traefik | nasselle `ubuntu@151.115.96.14` | yundera-prod `ubuntu@151.115.97.163` |
| config root | `/workspace/config/mesh-router-inojob/` | `/workspace/config/mesh-router-nsl/` |
| static zone file | `backend/zone/inojob.com.zone` | `backend/zone/nsl.sh.zone` |

**What changes at the switch.** Every name of the zone resolves through our
nameservers. The apex (`<zone>`, `/router/api`, `/dashboard`, `/api`) reaches Traefik
directly, so Traefik needs a real certificate. `*.<zone>` answers the gateways, so the
gateway's `*.<zone>` certificate is what browsers see on every dash name. A user apex
or dot name reaches the box raw (passthrough), so the box needs its own certificate:
only a delegated user's box has one. Outbound mail depends on the SendGrid records
being served by us. Boxes call `https://<zone>/router/api` and stop working without
the apex certificate.

**Rollback** is the registrar's NS set back to Cloudflare, as long as the Cloudflare
zone still exists (§4). The lag is the parent NS TTL plus resolver caches: up to an hour
on `.sh`, up to two days on `.com`. Nothing is deleted on our side before §3 is done.

## 0. Gates (all must hold before the switch day)

| # | Gate | How to check |
|---|---|---|
| G1 | **Backend ≥ 2.0.49** with the zone file mounted (`./zone:/app/config/zone:ro`, `DNS_STATIC_ZONE_FILE`) | `docker exec <backend> mesh-cli dns zone --dry-run`: no change, nothing unexpected skipped |
| G2 | **Static zone matches Cloudflare** | `mesh-cli dns zone diff`: every static record "same"; the only differences are the NS set, proxied names (Cloudflare addresses), `ip` and delegated users (referrals) |
| G3 | **Every public NS serves the same zone** | §1 query loop: same SOA serial on each NS |
| G4 | **Gateway ≥ 1.7.0** (`stream_realip`, client address on terminated connections) | `docker ps` image tag |
| G5 | **Traefik holds a trusted certificate for the apex** | §1.1, then `curl --resolve <zone>:443:<host ip> https://<zone>/router/api/available/x` with no `-k` |
| G6 | **Gateway holds a trusted `*.<zone>`** (deferred item, `phase-1.1-gateway-tls.md` §6) | `curl --resolve <app>-<user>.<zone>:443:<gw ip> https://…` with no `-k`, through each gateway |
| G7 | **Every active user delegated** (`dns.delegated`), boxes on a mesh-router-caddy with `caddy-dns/acmedns` | see §0.1 |
| G8 | **Inbound mail decided** (open point 3); MX, SPF, `cf2024-1` DKIM and DMARC `rua` lines of the zone file rewritten accordingly | read the file; `dns zone --dry-run` |
| G9 | **≥ 2 gateways** in `DNS_GATEWAY_IPS`, on separate hosts (`architecture.md` §6, `multi-gateway.md`) | prod has one today |
| G10 | **Glue registered** at the registrar: host objects for both NS names with their IPv4 (they sit inside the zone) | registrar UI; after §2: `dig +norec NS <zone> @<registry ns>` lists them with glue in ADDITIONAL |
| G11 | **No DNSSEC** at the parent, and DNSSEC off in the Cloudflare zone | `dig +norec DS <zone> @<registry ns>` empty; Cloudflare › DNS › Settings |
| G12 | **Cloudflare export saved** (BIND file, dated) next to the zone file | file present |

### 0.1 G7: users at the switch

After the switch the `*.<zone>` wildcard also matches `<user>.<zone>` and
`<app>.<user>.<zone>`. For a user who is **not** delegated those names reach the box
through the passthrough, and the box presents its gateway-CA certificate: the user apex
breaks (it works today through Cloudflare's edge certificate and the Worker). Dash
names keep working (the gateway terminates them).

Two ways to meet the gate:

- **Phase 2 first** (`architecture.md` §13.3): users delegated in batches while
  Cloudflare holds the zone (one Cloudflare NS record per user). Each box gets its
  DNS-01 wildcard before the switch; the switch changes nothing for it.
- **All at once at the switch**: `mesh-cli dns delegate <user> on` for every user just
  before §2, which only adds `<user> NS` to *our* apex zone (no Cloudflare record).
  After the switch the public resolvers see the delegations, the backend's live check
  (1.1.1.1 and 8.8.8.8, refreshed every 10 min) flips, and each box orders its
  certificates. Until it has them (minutes, more if Let's Encrypt is slow) its apex and
  dot names fail the TLS handshake. Fewer steps, one visible window.

Boxes whose mesh-router-caddy lacks `caddy-dns/acmedns` (FOSS boxes off the template
channels) never get a certificate either way: list them in §1 and accept, or update
them first.

## 1. Preparation (days before, no user-visible change)

### 1.1 Traefik: certificate for the apex

Traefik has no ACME resolver today, and its storage mount source
`/workspace/data/traefik/acme.json` is a **directory** on both hosts (Docker created it
when the file was missing). Cloudflare forwards plain HTTP to the origin (checked
2026-10-28: `http://<zone>/.well-known/acme-challenge/x` gets Traefik's own 302), so
HTTP-01 works before the switch and keeps working after it.

```bash
cd /workspace/config/admin/traefik
cp traefik.yml traefik.yml.bak-<date>-cutoff
docker compose stop traefik                 # every site on the host is down until the start below
sudo rmdir /workspace/data/traefik/acme.json
sudo install -m 600 /dev/null /workspace/data/traefik/acme.json
```

Append to `traefik.yml` (the address is the ACME account contact, not `contact@<zone>`
until point 3 is settled):

```yaml
certificatesResolvers:
  le:
    acme:
      email: <ops address>
      storage: /acme.json
      httpChallenge:
        entryPoint: web
```

One router asks for the certificate. The other apex routers (`/router/api`,
`/dashboard`, `/api`) already have `tls=true`, and Traefik serves the stored
certificate to every router on that SNI. In `<config root>/landing-page/docker-compose.yml`:

```yaml
      - "traefik.http.routers.landing-<env>.tls.certresolver=le"
```

```bash
docker compose -f /workspace/config/admin/traefik/docker-compose.yml up -d traefik
(cd <config root>/landing-page && docker compose up -d)
docker logs --since 5m traefik 2>&1 | grep -i acme
echo | openssl s_client -connect <host ip>:443 -servername <zone> 2>/dev/null | openssl x509 -noout -issuer -subject -enddate
```

Expect a Let's Encrypt issuer. Behind Cloudflare "Full" nothing changes for visitors.
Other hosts on that Traefik (`nasselle.com`, `yundera.com`) are untouched.

### 1.2 Zone and nameservers

```bash
B=$(docker ps --format '{{.Names}}' | grep -E 'mesh-router-backend-(inojob|nsl)' | head -1)
docker exec $B mesh-cli dns zone --dry-run
docker exec $B mesh-cli dns zone diff
for ns in <ns1 ip> <ns2 ip>; do
  echo "== $ns"
  dig +short SOA <zone> @$ns
  for q in "NS <zone>" "A <zone>" "MX <zone>" "TXT <zone>" "TXT _dmarc.<zone>" \
           "CNAME s1._domainkey.<zone>" "A probe-x.<zone>" "NS ip.<zone>" "NS <delegated user>.<zone>"; do
    printf '%-40s %s\n' "$q" "$(dig +short +norec $q @$ns | tr '\n' ' ')"
  done
done
```

Expect the same serial on both, `A probe-x` = the gateway IPs, the NS sets = our two names.

### 1.3 Dress rehearsal without touching the registrar

A client whose resolver is forced onto our nameservers sees the zone exactly as after
the switch. For example an `unbound` container with
`stub-zone: name: "<zone>" stub-addr: <ns1 ip> stub-addr: <ns2 ip>`, then browse with
it as DNS: the apex, a dash name, a delegated user's apex and dot names, holyhorse
(prod) / wisera (staging). Every certificate must validate.

## 2. Switch day

1. Re-run §1.2. Re-check G11 (`dig +norec DS <zone> @<registry ns>`).
2. If G7 is met "all at once": `mesh-cli dns delegate <user> on` for each user, wait one
   reconcile pass (60 s), check `dig NS <user>.<zone> @<ns1 ip>`.
3. **Registrar: set the NS to our two names** (staging: Namecheap › Domain › Nameservers
   › Custom DNS; the glue of G10 must already exist).
4. Watch the registry, then the public resolvers:

   ```bash
   watch -n 30 'dig +norec NS <zone> @<registry ns> | grep -A3 AUTHORITY;
     for r in 1.1.1.1 8.8.8.8 9.9.9.9; do echo "$r $(dig +short NS <zone> @$r | tr "\n" " ")"; done'
   ```

   Shorten the wait with https://one.one.one.one/purge-cache/ and
   https://dns.google/cache (NS and A of the zone and of a few user names).
5. Once 1.1.1.1 and 8.8.8.8 answer our NS:
   - `curl -s https://<zone>/router/api/available/x` (no `-k`);
   - a dash name, through each gateway, with `X-Mesh-Trace: 1`: no `cf-worker` segment
     any more;
   - delegated users: `mesh-cli dns status <user>` shows live, and the box's Caddy log
     shows the DNS-01 orders;
   - an agent and a tunnel box re-register (backend log), `ip.<zone>` still answers.
6. **CAA at the apex**, now that Cloudflare no longer issues for the zone (Traefik and the
   gateway use Let's Encrypt; user zones carry their own CAA):

   ```
   @   CAA 0 issue "letsencrypt.org"
   @   CAA 0 issuewild "letsencrypt.org"
   ```

   added to the zone file, then `mesh-cli dns zone --dry-run` and wait one pass.
7. **SendGrid**: Settings › Sender Authentication › the domain › Verify. Send a test
   mail from a box and check DKIM=pass and DMARC=pass in the received headers.
8. Inbound mail as decided in G8: send a mail to the contact address.

## 3. Drain (≥ 48 h after the switch)

Resolvers that cached Cloudflare's own NS set (child TTL, up to a day) keep sending
some visitors to Cloudflare, and the Worker keeps serving them. Leave the Cloudflare
zone, the Worker and its route untouched during the drain.

1. Watch the Worker's request count (Cloudflare › Workers › the worker › Metrics) fall
   to background noise.
2. **`GATEWAY_FORWARDED_FOR=replace`** on every gateway (compose env, `docker compose
   up -d`): once no request comes from the Worker, the client-chosen leftmost
   `X-Forwarded-For` is the only thing `append` still adds. Check the client address
   in an app behind the gateway (whoami on a test box).
3. **Retire the Worker**: delete the `*.<zone>/*` route, then the Worker. Remove the
   `gateway.entrypoint` line from the zone file (`dns zone --dry-run`, one pass). Unset
   `GATEWAY_FALLBACK_URL` wherever it is still set.
4. Commit the zone file and the Traefik/compose edits in the env's config repo.

## 4. After the drain

- The Cloudflare zone stays until the rollback window is closed. Cloudflare deletes a
  zone whose nameservers have moved away after a few days in "Moved" status (check the
  current delay before relying on it); the saved export (G12) is the fallback.
- `mesh-router-gateway-cf` is retired: archive the repo, drop the deploy steps from the
  docs and the `cf-worker` trace segment from CLAUDE.md files.
- Later, separately: DNSSEC (`architecture.md` §10.5, never in the same step as an NS
  change), PSL entry.

## 5. Staging rehearsal: what differs

- `.com` parent NS TTL is 2 days: a rollback can take that long for some resolvers.
  Rehearse at a time when a slow rollback of `inojob.com` is acceptable.
- Staging already runs two gateways (nasselle and nss1), so G9 is met there.
- The staging backend container must be redeployed on an image ≥ 2.0.49 first (G1);
  it currently runs another session's local build.
- Record what the rehearsal found in this file before scheduling prod.
