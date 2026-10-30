# mesh-router-nameserver

The mesh's authoritative DNS. It is **stock PowerDNS Authoritative 5.1** with this repo's
config baked in: one image, two roles, no DNS code of our own beyond one Lua include.

It serves two kinds of names under the server zone (`nsl.sh` on prod, `inojob.com` on
staging):

- **IP-encoded names**, our own nip.io: `<app>-<dashed-ip>.ip.<zone>` → `<ip>`, answered
  only for IPs registered by a real box's agent. The CF Worker and the gateway reach
  boxes directly through them.
- **Per-user zones** (`<user>.<zone>`) for users whose zone is delegated to us: the box
  or gateway address, plus the `_acme-challenge` TXT records that give the box its DNS-01
  wildcard certificate.

The records come from `mesh-router-backend`. This service only stores and serves them.

## How it works

```
mesh-router-backend ── allowlist, user zones, ACME challenges
   │  PowerDNS HTTP API (backend stack network only)
   ▼
hidden primary  (ROLE=primary, sidecar in the backend stack, in no NS record)
   │  NOTIFY + AXFR, transfers allowed only to the secondaries' IPs
   ├──► public secondary 1  (ROLE=secondary) ─┐  the zone's NS records,
   └──► public secondary 2  (ROLE=secondary) ─┘  on different hosts
```

- **One writer.** Only the backend writes, and only to the primary. Sync to the public
  nameservers is plain DNS: NOTIFY, then a zone transfer (about 1 s).
- **New zones need no config.** The primary is a catalog-zone producer (RFC 9432), and
  the secondaries consume it, so a zone created or deleted through the API appears or
  disappears on every secondary by itself.
- **`ip.<zone>` is never transferred**, because its names are unbounded. Each secondary
  builds it locally at start: one wildcard `LUA` record that calls `image/lua/ipname.lua`.
  The include parses the IP the way sslip.io does (dashed, dotted or hex IPv4, dashed
  IPv6). It then answers only if the IP is listed in the transferred allowlist zone
  `allow.<ip-zone>.invalid`. Any other IP-shaped name gets an empty answer.
- **Nothing to back up.** The primary is rebuilt from backend state by its next reconcile
  pass, and the secondaries hold only copies.

| Zone | Primary | Secondaries |
|---|---|---|
| catalog (`catalog.<zone>.invalid`) | producer | consumer |
| `allow.<ip-zone>.invalid` | written by the backend | transferred |
| `<user>.<zone>`, one per box (dormant until delegated, then live) | written by the backend | transferred |
| `ip.<zone>` | — | local Lua wildcard, built from env |

Design and rationale: [`docs/architecture.md`](docs/architecture.md). IP-encoded names
and the Cloudflare tests behind them: [`docs/ip-names.md`](docs/ip-names.md).

## Image

`ghcr.io/yundera/mesh-router-nameserver`, published by `.github/workflows/docker.yml`
after the smoke test passes: `:main` on every push to `main`, `X.Y.Z` and `X.Y` on a
`vX.Y.Z` tag. The base is `powerdns/pdns-auth-51`, pinned by digest. A host carries only a
compose file and an `.env`.

| `ROLE` | Required env | Optional |
|---|---|---|
| `primary` | `PDNS_AUTH_API_KEY`, `DNS_SOA_NS` (first public NS name), `DNS_SECONDARY_IPS` (every secondary, as the primary sees it) | — |
| `secondary` | `IP_ZONE`, `NS_HOSTS` (every public NS name, comma list, first = SOA mname), `SOA_RNAME`, `CATALOG_ZONE`, `PRIMARY_IP` | `PRIMARY_PORT` (53) |

If a variable is missing, the container stops and prints its name. Each secondary
rebuilds `ip.<zone>` from env on every start, so changing `NS_HOSTS` only needs a
recreate. `TEMPLATE_FILES` adds an operator template mounted in
`/etc/powerdns/templates.d/`.

## Running it

**Public secondary**: one per host, on UDP and TCP 53:

```yaml
services:
  nameserver:
    image: ghcr.io/yundera/mesh-router-nameserver:1.3.2
    restart: unless-stopped
    environment:
      - ROLE=secondary
      - IP_ZONE=ip.example.com
      - NS_HOSTS=ns1.example.com,ns2.example.com
      - SOA_RNAME=dns.example.com
      - CATALOG_ZONE=catalog.example.com.invalid
      - PRIMARY_IP=203.0.113.10        # the primary's host
      - PRIMARY_PORT=5300              # the primary's published port
    volumes:
      - nameserver-data:/var/lib/powerdns
    ports:
      # the public IP, not 0.0.0.0: systemd-resolved holds 127.0.0.53/54:53
      - "198.51.100.20:53:53/udp"
      - "198.51.100.20:53:53/tcp"
volumes:
  nameserver-data:
```

**Hidden primary**: a sidecar in the backend's compose. It shares a network with the
backend, which sets `PDNS_API_URL=http://pdns-primary:8081`, `PDNS_API_KEY` and
`DNS_IP_ZONE`. It publishes nothing unless a secondary lives on another host. In that
case, publish it on a non-standard port (`<host-ip>:5300:53`, TCP and UDP) and list that
secondary's public IP in `DNS_SECONDARY_IPS`. Transfers are restricted by IP only, not
TSIG, because PowerDNS gives catalog member zones no TSIG key on the consumer.

**Secondary on the primary's host**: put both on a shared network with fixed
addresses, and point `PRIMARY_IP` at the primary's address on that network (port 53).
The secondary's address on it goes into `DNS_SECONDARY_IPS`.

`test/smoke/docker-compose.yml` is a complete working primary + secondary pair. CI runs
it on every build.

In the parent zone, each public name needs an `A` record (not proxied), plus
`NS ip.<zone>` listing every one of them. A user moves to our nameservers with one more
record there, `NS <user>.<zone>` (one of them is enough): its zone already exists, and
the backend turns it live by itself.

## Checking a node

```sh
dig +short @<node> NS ip.<zone>                       # every NS_HOSTS name
dig +short @<node> maison-<dashed-box-ip>.ip.<zone>   # the box IP (allowlisted)
dig +short @<node> 1-2-3-4.ip.<zone>                  # empty: not allowlisted
dig +short @<node> SOA allow.<ip-zone>.invalid        # same serial on every node
docker compose exec nameserver pdnsutil zone show <catalog-zone>   # "Last time we got update from primary"
```

The backend's `GET /router/api/dns/health` compares the primary with every
nameserver. Don't treat it as proof that a new node has transferred, though: check the
catalog consumer with `pdnsutil zone show` until it reports an update.

## Tests

- `sh test/smoke/run.sh` builds the image and runs a primary, a secondary and a client.
  It checks API writes, catalog consumption, the allowlist transfer, gated answers and
  NOTIFY.
- `test/ipname/` compares `ipname.lua` against the sslip.io server, answer for answer,
  over a 581-name corpus.

## Layout

```
mesh-router-nameserver/
├── Dockerfile            stock pdns-auth-51 + the files below
├── image/
│   ├── entrypoint.sh     checks env per ROLE, builds the secondary's local zones
│   ├── templates/        primary.j2, secondary.j2 (rendered by the stock startup)
│   └── lua/ipname.lua    ip.<zone> wildcard: sslip.io parsing + allowlist lookup
├── test/
│   ├── smoke/            CI: primary + secondary end to end
│   └── ipname/           parity of ipname.lua with the sslip.io server
└── docs/
    ├── architecture.md   design: answers, certificates, gateway edge, topology
    └── ip-names.md       IP-encoded names, Cloudflare subzone tests
```
