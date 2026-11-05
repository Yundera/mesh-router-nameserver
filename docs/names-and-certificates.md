# Names and certificates on a box

> Reference, written 2026-11-05. It describes the state on that date: Cloudflare still
> serves the zone, the cutoff has not happened, and staging is the only environment with
> delegated users (wisera, demostaging1). The design behind it is in
> [`architecture.md`](architecture.md) §3–§7 and [`phase-1.1-gateway-tls.md`](phase-1.1-gateway-tls.md).
> Examples use `john` as the user, `nsl.sh` as the zone, `203.0.113.10` as the box IP.

## Summary

| Name | Example | Who presents the certificate | Issued by | User-facing | Our Let's Encrypt quota |
|---|---|---|---|---|---|
| dot form | `immich.john.nsl.sh` | the box while it holds a trusted certificate; the gateway otherwise (fallback) | Let's Encrypt `*.john.nsl.sh`, DNS-01 (box) / ZeroSSL `*.john.nsl.sh`, Let's Encrypt as backup (gateway) | yes, delegated users only | 1 wildcard per box (gateway: none, unless its backup is used) |
| user apex | `john.nsl.sh` | the box; the gateway while the box has none | Let's Encrypt (box) / the gateway's `*.nsl.sh` | yes (dashboard landing) | 1 per box, when delegated |
| dash form | `immich-john.nsl.sh` | today Cloudflare; after the cutoff the gateway | Cloudflare edge / ZeroSSL `*.nsl.sh` per gateway (Let's Encrypt as backup) | yes, today's main form, to be deprecated | none (backup only) |
| IP name | `immich-203-0-113-10.ip.nsl.sh` | the box (cert0) | Mesh Router CA | no: the Worker's direct path to the box | none |
| hop name | `john.box.nsl.sh` | the box (cert0) | Mesh Router CA | no: gateway → box hop | none |
| sslip.io | `immich-203-0-113-10.sslip.io` | the box | Let's Encrypt, HTTP-01, one per name | break-glass fallback, public-IP boxes only | none (sslip.io's) |
| nip.io | — | — | was Mesh Router CA | removed 2026-10-28 | — |

On a box only two kinds of certificate are publicly trusted: the delegated zone's wildcard and
apex, and the sslip.io names. Everything else the box presents is **cert0**, signed by the Mesh
Router CA, and only machines (the Cloudflare Worker, the gateway) ever see it.

**cert0** is issued by the backend to every box and renewed by it. Its SANs (backend ≥ 2.0.43):
`*.ip.<zone>` (from `CERT_EXTRA_SANS`), `<label>.box.<zone>`, the box IP. It no longer carries
`*.<zone>` or `*.nip.io`.

## Per name

### Dot form `<app>.<user>.<zone>`

- **Exists only for a delegated user** (parent `NS` record for `<user>.<zone>` → our
  nameservers). On a non-delegated user the name has no valid certificate anywhere: Cloudflare's
  Universal SSL covers one label under the zone.
- **Certificate:** the box's own `*.<user>.<zone>` from Let's Encrypt, DNS-01 through the
  backend's acme-dns API (Caddy `caddy-dns/acmedns`). Works behind NAT: DNS-01 needs no
  inbound port.
- **DNS answer** ([`architecture.md`](architecture.md) §4.2): the box IP only when the box has a
  public IP, a trusted certificate verified by the backend's probe, and fresh routes; the
  gateway otherwise (NAT/tunnel boxes, no certificate yet, failed probe).
- **Through the gateway:** while the box holds its certificate, the gateway's SNI router passes
  the raw TLS through to the box (PROXY v2 in front), over the public IP or the WireGuard
  tunnel. Without one, the gateway terminates the name with its fallback certificate (below).
  Before gateway 1.15.0 ("Option A") a box without its certificate failed at the TLS handshake.
- **Advertised** only once the box is ready (`dot_form_ready`, `MESH_PRIMARY_FORM=dot`).
- **Planned main form**: once dash names are deprecated, this is the only per-app name.
- **Gateway fallback** (gateway 1.15.0 / backend 2.0.62, `GATEWAY_FALLBACK_CERTS=on`,
  Trello #966): each gateway holds a `*.<user>.<zone>` per live user, from ZeroSSL (Let's
  Encrypt as a capped backup, so the Let's Encrypt bucket stays for the boxes), and
  terminates the user's dot names while the box has no trusted certificate. The box's own
  certificate is a privacy upgrade (end to end), not a condition for the name to work.
  Design: [`phase-1.1-gateway-tls.md`](phase-1.1-gateway-tls.md) §6.3; transparency: §7.

### User apex `<user>.<zone>`

- **Delegated:** the box's own Let's Encrypt certificate (same order as the wildcard). The
  gateway passes it through while the backend's last probe found a browser-trusted certificate
  naming the apex exactly (`dns.certNotAfter` in `/resolve/v2`); otherwise it terminates it with
  its own `*.<zone>`, which matches one label, and forwards it like a dash name (gateway ≥ 1.14.0,
  backend ≥ 2.0.61, [`phase-1.1-gateway-tls.md`](phase-1.1-gateway-tls.md) §3.1).
- **Not delegated:** behaves like a dash name (Cloudflare today, the gateway after the cutoff).

### Dash form `<app>-<user>.<zone>`

- Exists because Cloudflare's certificate covers one label under the zone. Today it is every
  box's main form (`MESH_PRIMARY_FORM` defaults to `dash`).
- **Today:** Cloudflare terminates it with its edge certificate. The Worker then
  - for a box with a public IP (agent route, most traffic): fetches
    `<app>-<ip-dashed>.ip.<zone>`, straight to the box (`x-mesh-route: cf-worker,ip-dns,pcs`);
  - for a NAT box, or on fallback: goes to the gateway, which terminates (`*.<zone>` on staging,
    still a self-signed certificate on prod until gate G6) and forwards over the tunnel.
  Cloudflare runs SSL mode "Full", not strict, so it does not check the origin's certificate.
- **After the cutoff:** our nameservers answer the gateway for every dash name. The gateway
  terminates with its own Let's Encrypt `*.<zone>` (lego, one certificate per gateway) and
  re-encrypts to the box with SNI `<label>.box.<zone>`, trusting only the Mesh Router CA.
- **On the box: never a Let's Encrypt certificate.** The `(gateway_tls)` Caddy snippet loads
  cert0 with `issuer internal` (mesh-router-caddy ≥ 1.5.1, Trello #958/#959). Caddy makes a
  self-signed certificate per dash name; nothing ever receives it (the gateway uses the hop
  name, the Worker the IP name). Before 1.5.1 every box ordered one Let's Encrypt certificate per
  dash name and filled the `nsl.sh` 50-per-week bucket.
- **Future:** to be deprecated in favour of the dot form.

### IP name `<app>-<ip-dashed>.ip.<zone>`

- Our own nip.io, its direct replacement ([`ip-names.md`](ip-names.md)). `ip.<zone>` is a
  separate delegated zone served locally by each public nameserver from one Lua record, and it
  **answers only for IPs a real user's agent has registered** (no open nip.io for phishing or DNS
  rebinding).
- **Why it exists:** a Cloudflare Worker cannot fetch an IP address (error 1003); it needs a
  hostname. The agent registers `<ip-dashed>.<IP_ZONE>` as its route, and the Worker builds
  `<app>-<ip-dashed>.<IP_ZONE>` from it.
- **Certificate:** cert0's `*.ip.<zone>` (Mesh Router CA). Not browser-trusted, not meant for
  users. No Let's Encrypt order.
- Kept permanently after the cutoff as the stable per-IP name ([`architecture.md`](architecture.md) §3.3).

### Hop name `<label>.box.<zone>`

- The box's identity on the gateway → box hop: the gateway sends it as SNI and accepts only a
  certificate signed by the Mesh Router CA (`mesh-ca.pem`). On cert0. `box` is a reserved label.

### sslip.io `<app>-<ip-dashed>.sslip.io`

- Public third-party wildcard DNS. The box's Caddy orders one Let's Encrypt certificate per name
  over HTTP-01; the quota is sslip.io's, not ours. A root `<ip-dashed>.sslip.io` site is in the
  Caddyfile.
- **Works only for a box with a public IP and port 80 reachable**: a NAT box has no sslip.io
  fallback.
- Also the Worker's fallback when the IP-name path fails (`ip-dns-fail`) and the target of
  `X-Mesh-Force: sslip`.
- Off on demo boxes (`SSLIP_ROUTES=off`).

### nip.io (removed)

- Same role the IP name has now, with a Mesh Router CA certificate. Removed from the fleet,
  cert0 and the Worker on 2026-10-28; `IP_ZONE` is mandatory instead.

## Let's Encrypt budget

Until `nsl.sh` is on the Public Suffix List (application in progress, `_psl` TXT), every
certificate under the zone shares **50 new certificates per week** for the whole registered domain,
plus 5 per week per identical name set. What draws from it: each gateway's `*.<zone>`, the
Traefik apex, and each delegated box's apex + `*.<user>.<zone>`. Dash names and IP names must
never draw from it. Once the PSL entry lands, the bucket is per user (`john.nsl.sh`).
