# Cutoff runbook — the zone leaves Cloudflare

> Phase 3 of [`architecture.md`](architecture.md) §13.3: the registrar points the zone at
> our nameservers, Cloudflare stops answering, the Worker is retired. Run by hand,
> **`inojob.com` (staging) first**, then `nsl.sh`. Written 2026-10-28; facts below were
> read that day, and §0 re-reads them.

| | staging | prod |
|---|---|---|
| zone | `inojob.com` | `nsl.sh` |
| registrar | Namecheap | Namecheap (confirmed 2026-11-02) |
| parent NS TTL (registry) | 172800 s (`.com`) | 3600 s (`.sh`) |
| DNSSEC at the parent | none (`delegationSigned: false`; no DS, re-checked 2026-11-03) | none (no DS at `a0.nic.sh`; re-checked 2026-11-03) |
| our NS (`DNS_NS_HOSTS`) | `nss1.inojob.com` 51.15.79.231, `nss2.inojob.com` 151.115.96.14 | `nsp1.nsl.sh` 51.15.79.11, `nsp2.nsl.sh` 151.115.97.163 |
| gateways (`DNS_GATEWAY_IPS`) | 151.115.96.14, 51.15.79.231 | 151.115.97.163, 51.15.79.11 (G9, 2026-11-06) |
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
| G4 | **Gateway ≥ 1.7.0** (`stream_realip`, client address on terminated connections) | `docker ps` image tag. **Met on prod 2026-11-03** (gateway 1.9.0): a dash name of holyhorse sent straight to the prod gateway (`curl --resolve …:443:151.115.97.163`, no Cloudflare) reached a whoami behind the box's Caddy with `X-Real-Ip` = the client and `X-Forwarded-For: <client>, 151.115.97.163` (the box trusts the gateway). Today's Cloudflare path hands the client only in `Cf-Connecting-Ip` (`X-Forwarded-For` = a Cloudflare address); that path goes away at the cutoff |
| G5 | **Traefik holds a trusted certificate for the apex**. Staging met 2026-11-03 (Let's Encrypt, `le` resolver, nasselle config 0ca82d0). Prod configured 2026-11-04 (`le` resolver, requested by the `nsl-backend` router, contact@yundera.com, prod config fbf5feb; `acme.json` was already a file) but **not issued**: Let's Encrypt answered 429, 50 new certificates for `nsl.sh` already issued in the last 168 h (boxes ordering per-app dash-name certificates, mostly the recycled demo boxes). Restart Traefik to retry once a slot is free. **2026-11-06:** the bucket has room again (the box dash-name churn stopped with mesh-router-caddy 1.5.1 on `stable` 2026-11-05, and a Let's Encrypt backup order for gateway 2's `*.nsl.sh` went through that day): **Prod met 2026-11-06**: Traefik ordered it on its own at 11:28 UTC, when the backend's router came back after a recreate (Let's Encrypt `nsl.sh`, YR2, until 2027-02-04); `curl --resolve nsl.sh:443:151.115.97.163 https://nsl.sh/router/api/available/x` with no `-k` = 200 | §1.1, then `curl --resolve <zone>:443:<host ip> https://<zone>/router/api/available/x` with no `-k` |
| G6 | **Each gateway holds its own trusted `*.<zone>`** (each gateway orders it with lego by DNS-01: through Cloudflare's API before the switch, the backend's apex challenge after, `phase-1.1-gateway-tls.md` §6. **Staging met 2026-11-04** on nasselle + nss1 (gateway 1.13.0, backend 2.0.60), on ZeroSSL since 2026-11-05 (`phase-1.1-gateway-tls.md` §6.3). **Prod met 2026-11-06**: both gateways (yundera-prod, nsp1) hold a ZeroSSL `*.nsl.sh` (gateway 1.15.3, backend 2.0.64, a Cloudflare token for `nsl.sh` IP-filtered to both). Ordered from ZeroSSL first, G6 no longer draws on the zone's Let's Encrypt bucket. At the switch: `GATEWAY_ACME_DNS=mesh` on each gateway, delete the Cloudflare token. `/dns/health` lists each gateway's certificate, degraded under `DNS_GATEWAY_CERT_MIN_DAYS`) | `curl --resolve <app>-<user>.<zone>:443:<gw ip> https://…` with no `-k`, through each gateway |
| G7 | **Every active box has a user zone** (automatic since 2026-10-30: dormant on its first registration), boxes on a mesh-router-caddy with `caddy-dns/acmedns`, **≥ 1.5.2**: a delegation is loaded at once; 1.5.1 and older wait for an unrelated caddy-docker-proxy generation, so a delegated box never orders its certificates (found on the prod pilots 2026-11-06, Trello #923) | see §0.1 |
| G8 | **Inbound mail on SendGrid Inbound Parse** (decided 2026-11-02; design in `mesh-router-root/doc/USER_MAIL.md`), moved **before** the switch so the mail change stays apart from the DNS move: `MX 10 mx.sendgrid.net`, SPF `v=spf1 include:sendgrid.net ~all`, `cf2024-1._domainkey` removed, DMARC `rua=mailto:contact@<zone>` kept (an alias the backend forwards). Staging: **verified 2026-11-04** (a Gmail message to `contact@inojob.com` was forwarded). **Prod met 2026-11-04** (#956: Email Routing off, MX/SPF on SendGrid, a Gmail message to `contact@nsl.sh` forwarded; #941: zone file lines match, `dns zone diff` "same", prod config 790bc46) | a mail to `contact@<zone>` arrives; the zone file has the same lines; `dns zone --dry-run` |
| G9 | **≥ 2 gateways** in `DNS_GATEWAY_IPS`, on separate hosts (`architecture.md` §6, `multi-gateway.md`) | **Prod met 2026-11-06** (Trello #937): `DNS_GATEWAY_IPS=151.115.97.163,51.15.79.11`, `DNS_GATEWAY_TUNNELS` for both providers, handoff (`GATEWAY_PUBLIC_IP`) on both gateways, coverage gate on (`DNS_GATEWAY_FALLBACK_REQUIRED=1`); `/dns/health` ok with both gateways up, ZeroSSL, coverage 2/2; the delegated pilots answered with both IPs. Done before the switch, while only delegated users are answered by our nameservers. Boxes on mesh-router-caddy ≥ 1.5.2 take gateway 2 into their PROXY allow list within one tick; until then a box ignores its header (connection fine, client IP = the gateway's) |
| G10 | **Glue registered** at the registrar: host objects for both NS names with their IPv4 (they sit inside the zone). Namecheap › Domain › Advanced DNS › Personal DNS Server; the domain's Nameservers setting stays on Cloudflare until §2 (pick **Custom** in the host dropdown, not `ns1`–`ns5`). **Met 2026-11-04**: `nss1.inojob.com` 51.15.79.231, `nss2.inojob.com` 151.115.96.14, `nsp1.nsl.sh` 51.15.79.11, `nsp2.nsl.sh` 151.115.97.163 | before §2: `curl -s https://rdap.verisign.com/com/v1/nameserver/nss1.inojob.com` (.com) / `https://rdap.identitydigital.services/rdap/nameserver/nsp1.nsl.sh` (.sh) = 200 with the IP, for each NS name; after §2: `dig +norec NS <zone> @<registry ns>` lists them with glue in ADDITIONAL |
| G11 | **No DNSSEC** at the parent, and DNSSEC off in the Cloudflare zone. **Met 2026-11-04** on both zones: no DS at the parent, and no DNSKEY served by Cloudflare (it publishes one as soon as DNSSEC is enabled, even pending) | `dig +norec DS <zone> @<registry ns>` empty; `dig DNSKEY <zone>` empty |
| G12 | **Zone file committed** in the env's config repo, compared once with a Cloudflare export (BIND file) | the export holds no record missing from the zone file (the NS set, the proxied addresses and the user delegations aside). **Staging met 2026-11-09**: zone file committed (`ac8672a`), the day's export identical. A separate saved export was dropped (user decision 2026-11-09): the committed zone file is the reference |

### 0.1 G7: users at the switch

After the switch the `*.<zone>` wildcard also matches `<user>.<zone>` and
`<app>.<user>.<zone>`. For a user who is **not** delegated those names reach the box
through the passthrough, and the box presents its gateway-CA certificate: the user apex
breaks (it works today through Cloudflare's edge certificate and the Worker). Dash
names keep working (the gateway terminates them).

Every box that registered routes since the auto-zone backend (the release after 2.0.50) has a (dormant) zone, and our apex
zone already carries `<user> NS` for each of them, so nothing has to be done per user:

- **Before the switch, optionally** (`architecture.md` §13.3): Cloudflare NS records for
  users in batches. Each such box goes live and gets its DNS-01 wildcard before the
  switch; the switch changes nothing for it.
- **At the switch** for everyone else: the public resolvers see our apex's delegations,
  the backend's live check (1.1.1.1 and 8.8.8.8, every 10 min per user) flips each user
  live, and each box orders its certificates. Until it has them its apex and dot names
  fail the TLS handshake (dash names are unaffected). One visible window, no step.
- **Let's Encrypt limit**: every box orders at once, against one registered domain
  (50 new certificates per week). Decided 2026-11-02: **don't wait for the Public Suffix List
  and no rate-limit request**; we live with 50/week (~33 boxes at the prod switch today). The
  `nsl.sh` PSL application is in progress (`_psl` TXT in the zone file, pull request 3496): once
  merged, each user gets their own bucket.
  If the fleet outgrows that, most users are moved by Cloudflare batches over the
  preceding weeks.

Check before §2: `mesh-cli dns zone --dry-run` lists a `<user> NS` per user zone;
`mesh-cli dns sync --prune --dry-run` reports no orphan.

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
cd /workspace/config && git add -A && git commit -m "backup <date> before traefik ACME" && git push   # skip if clean
cd admin/traefik
docker compose stop traefik                 # every site on the host is down until the start below
sudo rmdir /workspace/data/traefik/acme.json
sudo install -m 600 /dev/null /workspace/data/traefik/acme.json
```

Append to `traefik.yml` (the address is the ACME account contact: `staging@yundera.com`
on staging, decided 2026-11-02; an ops address on prod):

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
# --force-recreate: the stopped container still holds the old (directory) mount and fails to start
docker compose -f /workspace/config/admin/traefik/docker-compose.yml up -d --force-recreate traefik
(cd <config root>/landing-page && docker compose up -d)
docker logs --since 5m traefik 2>&1 | grep -i acme
echo | openssl s_client -connect <host ip>:443 -servername <zone> 2>/dev/null | openssl x509 -noout -issuer -subject -enddate
```

Expect a Let's Encrypt issuer (staging 2026-11-03: issued ~35 s after start). Behind Cloudflare
"Full" nothing changes for visitors. The restart takes the host's gateway out of the DNS answers
for ~90 s (the backend's TLS check fails while Traefik is down); the other gateway keeps serving.
Commit and push the config repo afterwards.
Other hosts on that Traefik (`nasselle.com`, `yundera.com`) are untouched.

### 1.2 Static zone file (G1, G2)

The records nobody derives (apex address, NS glue addresses, mail, site verification)
live in `<config root>/backend/zone/<zone>.zone`, mounted as a directory so an edited
file is seen. Staging has it since 2026-10-28 (2026-11-03: `dns zone --dry-run` no
change, `dns zone diff` 7 same, every difference expected: NS set, proxied names,
delegations). Prod, run by the user:

```bash
cd /workspace/config/mesh-router-nsl/backend
grep -n 'zone\|DNS_STATIC_ZONE_FILE' docker-compose.yml; ls -la zone   # what is there already
cp docker-compose.yml docker-compose.yml.bak-<date>-zone
mkdir -p zone && cp <draft>/nsl.sh.zone zone/nsl.sh.zone              # draft: /d/workspace/claude/tmp/nsl.sh.zone
```

In `docker-compose.yml`, on the backend service (as on staging):

```yaml
    volumes:
      - ./zone:/app/config/zone:ro
    environment:
      - DNS_STATIC_ZONE_FILE=/app/config/zone/nsl.sh.zone
```

```bash
docker compose up -d mesh-router-backend-nsl     # recreate; the service name may differ
B=$(docker ps --format '{{.Names}}' | grep -E 'mesh-router-backend-nsl' | head -1)
docker exec $B mesh-cli dns zone --dry-run     # what the next reconcile pass writes (it creates the apex zone)
docker exec $B mesh-cli dns zone diff          # every static record "same" (G2)
```

Creating the apex zone changes nothing for users: until §2 the registrar points at
Cloudflare and nobody asks our nameservers for `nsl.sh`. The mail lines of the draft
mirror Cloudflare Email Routing until #922 (G8) moves them; the file says what replaces
them. Commit the file in the env's config repo (staging: `mesh-router-inojob/backend/`
is not tracked yet, 2026-11-03).

### 1.3 Zone and nameservers

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

### 1.4 Dress rehearsal without touching the registrar

A client whose resolver is forced onto our nameservers sees the zone exactly as after
the switch. For example an `unbound` container with
`stub-zone: name: "<zone>" stub-addr: <ns1 ip> stub-addr: <ns2 ip>`, then browse with
it as DNS: the apex, a dash name, a delegated user's apex and dot names, holyhorse
(prod) / wisera (staging). Every certificate must validate.

## 2. Switch day

1. Re-run §1.3. Re-check G11 (`dig +norec DS <zone> @<registry ns>`).
2. Spot-check a few users that are not live yet: `dig NS <user>.<zone> @<ns1 ip>` answers
   our NS (the apex delegation), `dig SOA <user>.<zone> @<ns1 ip>` answers (the zone).
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
   - users: within ~10 min `mesh-cli dns status <user>` shows live (or
     `mesh-cli dns sync <user>` to check now), and the box's Caddy log shows the DNS-01
     orders;
   - an agent and a tunnel box re-register (backend log), `ip.<zone>` still answers.
6. **Gateways: lego through our nameservers, Cloudflare token deleted.** Until now each
   gateway's `*.<zone>` renews through Cloudflare's API (`GATEWAY_ACME_DNS=cloudflare`),
   which writes into a zone nobody asks any more: the next renewal would fail. On each
   gateway, config repo commit before, then in its compose env `GATEWAY_ACME_DNS=mesh`,
   `GATEWAY_ACME_LEGO_ARGS=--dns.resolvers 1.1.1.1:53 --dns.resolvers 8.8.8.8:53`, and
   drop `CLOUDFLARE_DNS_API_TOKEN` (compose and `.env`), `docker compose up -d`, commit
   after + push. **The resolvers line is required:** lego finds the zone's authoritative
   servers through the host's resolver, which may keep Cloudflare's NS set for up to a
   day (child TTL 86400); it then waits on Cloudflare for the TXT, times out after 5 min
   and falls back to the backup CA. Staging 2026-11-09: one of nss1's two Scaleway
   resolvers still held it 20 h after the switch, so every order through it failed —
   fallback certificates included, so set it in the same recreate. Then **force one
   renewal on one gateway** to prove the path (the primary is ZeroSSL: no rate limit;
   the certificate otherwise renews only 30 days before expiry):

   ```bash
   G=$(docker ps --format '{{.Names}}' | grep -i gateway | head -1)
   # RENEW_DAYS above the days left (95 > 90: also forces a certificate renewed the same day)
   docker exec $G sh -c '
     export GATEWAY_STATE_DIR=/var/lib/mesh-gateway GATEWAY_ACME_RENEW_DAYS=95 GATEWAY_ACME_EMAIL=admin@<zone>
     export LEGO_DNS=httpreq HTTPREQ_ENDPOINT=$BACKEND_URL/acme-dns HTTPREQ_USERNAME=$GATEWAY_PUBLIC_IP \
            HTTPREQ_PASSWORD=$GATEWAY_CERT_TOKEN HTTPREQ_PROPAGATION_TIMEOUT=300
     . /usr/local/lib/mesh-acme.sh
     acme_obtain <zone> && set -- $(acme_best <zone>) &&
     cp -f $2 /etc/nginx/certs/default.key && cp -f $1 /etc/nginx/certs/default.crt && openresty -s reload'
   echo | openssl s_client -connect <gw ip>:443 -servername x-<user>.<zone> 2>/dev/null | openssl x509 -noout -startdate -enddate
   ```

   `GATEWAY_ACME_EMAIL` = the account directory under `acme/<CA host>/accounts/`. `lego
   renew` may first sleep a random delay of up to 8 min. Delete the Cloudflare token in
   the Cloudflare dashboard once both gateways run in `mesh` mode.
7. **CAA at the apex**, now that Cloudflare no longer issues for the zone. Traefik orders
   the apex from Let's Encrypt; the gateways order `*.<zone>` from ZeroSSL
   (`sectigo.com`) with Let's Encrypt as their backup. User zones carry their own CAA
   (`DNS_CAA_GATEWAY_ISSUERS`):

   ```
   @   CAA 0 issue "letsencrypt.org"
   @   CAA 0 issuewild "letsencrypt.org"
   @   CAA 0 issuewild "sectigo.com"
   ```

   added to the zone file, then `mesh-cli dns zone --dry-run` and wait one pass. Without
   `sectigo.com` the gateways' next ZeroSSL renewal is refused and they fall back to the
   zone's Let's Encrypt bucket. Narrowing to `; accounturi=…` (`phase-1.1-gateway-tls.md`
   §6.1) is possible for the Let's Encrypt lines only: Sectigo's support for it is
   unverified (Trello #968).
8. **SendGrid**: Settings › Sender Authentication › the domain › Verify. Send a test
   mail from a box and check DKIM=pass and DMARC=pass in the received headers.
9. Inbound mail (G8, already on SendGrid Inbound Parse): send a mail to `contact@<zone>`
   and check it is forwarded.

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
  current delay before relying on it); the committed zone file (G12) is the fallback.
- `mesh-router-gateway-cf` is retired: archive the repo, drop the deploy steps from the
  docs and the `cf-worker` trace segment from CLAUDE.md files.
- Later, separately: DNSSEC (`architecture.md` §10.5, never in the same step as an NS
  change). The PSL application (`_psl` TXT) runs on its own; nothing in the cutoff depends on it.

## 5. Staging rehearsal: what differs

- `.com` parent NS TTL is 2 days: a rollback can take that long for some resolvers.
  Rehearse at a time when a slow rollback of `inojob.com` is acceptable.
- Staging already runs two gateways (nasselle and nss1), so G9 is met there.
- Staging runs published images: backend 2.0.64, gateways 1.15.3, nameservers 1.3.3
  (read 2026-11-09).
- Staging users that go live at the switch: every dormant zone (2026-11-09:
  demostaging2, competentleopon, followingcaterpillar). Their apex and dot names fail TLS
  until each box or gateway holds a certificate for them (the gateways' fallback
  `*.<user>.<zone>` comes within minutes of going live). Accepted. competentleopon is the
  NAT test box: always the gateways' answer.
- Record what the rehearsal found in this file before scheduling prod.

### 5.1 Pre-switch checks, 2026-11-09 (staging)

- **G1–G11 re-read**: `dns zone --dry-run` no change; `dns zone diff` = only the NS set,
  the gateway addresses, `ip` and user delegations; nss1 = nss2 serial `2026110602`;
  `/dns/health` ok, both gateways ZeroSSL, coverage 2/2; `dns sync --prune --dry-run` no
  orphan. G12: the day's Cloudflare export has every record of the zone file and
  nothing more. All gates met.
- **§1.4 dress rehearsal**, each name resolved at nss1 and nss2 and fetched with
  `curl --resolve` (no `-k`) at every address they answered: apex `/router/api` and
  `/dashboard` 200 (Traefik, Let's Encrypt); dash names of wisera, demostaging1,
  demostaging2 through both gateways (ZeroSSL `*.inojob.com`); wisera and demostaging1
  apex + dot names direct on the boxes' own Let's Encrypt certificates; MX, SendGrid
  CNAMEs, DMARC served. Expected failures only: a dormant user's dot name (no
  certificate before it is live) and `ip.<zone>` names (the box serves no public
  certificate for them). competentleopon's 502 is the same through Cloudflare.
  Cloudflare has no apex TXT either: staging never had an SPF record.
- **Renewals**: none had run yet (every certificate under a week old). Forced on nss1
  with `GATEWAY_ACME_RENEW_DAYS=89` (ZeroSSL): the fallback `*.wisera.inojob.com` through
  the backend's acme-dns and our nameservers (the post-switch path), reinstalled by the
  fallback loop within 60 s; the public `*.inojob.com` through Cloudflare, installed and
  served (until 2027-02-07). The apex-zone `mesh` path can only be proven after the
  switch (the CA asks Cloudflare until then): §2 step 6. Box certificates renew through
  the same acme-dns path demostaging1 uses on every daily rebuild. Traefik: its daily
  renewal check runs, and the HTTP-01 handler answers on `:80` straight at the host.

### 5.2 Switch, 2026-11-09 (staging)

- ~14:10 UTC: Namecheap NS → nss1/nss2. At 14:11 the `.com` registry already gave
  nss1/nss2 with glue, 1.1.1.1 and 8.8.8.8 answered our NS; 9.9.9.9 still Cloudflare.
- §2 step 5 passed: apex `/router/api` 200 without `-k`; dash names through both
  gateways with no `cf-worker` segment; wisera + demostaging1 direct on their own
  certificates; agents and tunnels re-registered; `ip.<zone>` and MX answered.
- The 3 dormant users went live within minutes (one needed a re-check after a
  resolver's cached Cloudflare answer expired); each got its fallback `*.<user>.<zone>`
  from ZeroSSL on nasselle at once. `mesh-cli dns status` showed "parent NS none" for a
  few of them until their next live check (answer stored before the switch): display
  only.
- Step 6: gateways on `mesh` (configs nss1 38cbe43, nasselle 60eef90). nss1's lego
  orders failed on a stale host resolver (Cloudflare NS cached 20 h more) until
  `GATEWAY_ACME_LEGO_ARGS` pointed the check at public resolvers (now in step 6); then
  the fallback orders went through on ZeroSSL. Forced renewal on nasselle through our
  nameservers: new ZeroSSL `*.inojob.com` until 2027-02-07, served after the reload.
- Step 7: apex CAA added (config d789a1f), served by both NS.
