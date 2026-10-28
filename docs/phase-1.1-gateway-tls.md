# Phase 1.1 — one key per name

> Design, decided 2026-10-27. Follows Phase 1 ([`architecture.md`](architecture.md) §13.2),
> which shipped the gateway terminating TLS with a backend-issued `<user>.<zone>` +
> `*.<user>.<zone>` certificate per delegated user. Phase 1.1 removes that certificate
> and makes the gateway's TLS behaviour coherent ahead of the full zone delegation and
> the Cloudflare removal. Nothing here is built yet.

## 1. Why

Phase 1 left two copies of every delegated user's wildcard: one key on the box (DNS-01
through the acme-dns API) and one in the backend's Redis, served to every gateway. So:

- whoever reads the backend's Redis or a gateway can impersonate `*.<user>.<zone>`, even
  for names the nameserver currently answers **direct**;
- every newly delegated user costs **two** new certificates against the shared
  Let's Encrypt bucket (50 per registered domain per week until `nsl.sh` is on the PSL),
  so about 25 delegations per week, not 50.

## 2. The rule

**A name's private key lives in exactly one place.**

| Name | Example | Key holder | Through the gateway |
|---|---|---|---|
| dash form | `immich-john.nsl.sh` | gateway (`*.<zone>`) | always; TLS terminated at the gateway, re-encrypted to the box |
| dot form | `immich.john.nsl.sh` | box (`*.<user>.<zone>`) | only when there is no direct answer; **raw TLS passthrough**, never terminated |
| user apex | `john.nsl.sh` | box (`<user>.<zone>`) | as dot form (see §7: the gateway's `*.<zone>` also matches it) |
| reserved / static | `www.nsl.sh`, `router.nsl.sh` | gateway or its own service | terminated |

Decisions behind it:

- **Option A (no fallback key for dot names).** A dot name works only while the box holds
  its own Let's Encrypt certificate. The gateway has no certificate it could present for
  it. Consequences, accepted: a dot name of an offline box fails at the TLS handshake
  instead of showing the gateway's offline page; a delegated box that has not obtained
  its certificate yet has no working dot names (dash names still work). Dot names are
  only advertised once the box is ready (`dot_form_ready`, `MESH_PRIMARY_FORM` gate).
- `force=gateway` on a dot name now means "route through the gateway", still ending TLS
  on the box.
- **HTTP-01 is dropped** from the design: dash names are never direct and dot names use
  DNS-01, so the gateway needs no ACME challenge forwarding (architecture.md §7.4).
- Dash → dot redirects are **out of scope** for 1.1 (after the delegation).

## 3. The gateway as an SNI router

The gateway's TLS port (`GATEWAY_TLS_PORT`, behind the generic Traefik TCP passthrough
with PROXY v2 today, `:443` on its own host later) becomes an OpenResty `stream` server
with `ssl_preread`. The decision is **syntactic on the SNI**, no backend lookup needed to
choose the mode:

```
SNI under <zone>?
 ├─ no                                → terminate (default cert), as today
 ├─ first label under the zone is reserved (§3.4)  → terminate
 ├─ one label containing a dash       → dash form  → terminate with *.<zone>
 └─ otherwise (user apex, dot form)   → passthrough to that user's box
```

Usernames cannot contain dashes (architecture.md §3.1), so a dashless single label is a
user apex and never a dash name.

**Passthrough:** `preread_by_lua` resolves the user's routes (same `/resolve/v2` data and
cache as `resolver.lua`, cosockets are available in preread), picks the best route and
`proxy_pass`es the raw stream to `<route ip>:443`: the public IP for an IP route, the
box's WireGuard address for a tunnel route (§5). The gateway sees SNI, client IP, sizes
and timing; not a byte of content. No route → close the connection (nothing to show).

**Terminate:** the stream server hands the connection to the existing HTTP TLS listener
on a local address, with PROXY v2 so `resolver.lua` keeps the client IP. That listener
serves `*.<zone>` (§6) and proxies to the box as today, with the hop identity of §4.

**Client IP on passthrough:** the gateway prepends PROXY v2 towards the box. The box's
Caddy accepts it through the `proxy_protocol` listener wrapper, **only** from the gateway
addresses and the tunnel relay; every other client is a plain direct connection.

Decided 2026-10-28 (user), box side built the same day (unstaged):

- **Caddy 2.11.4, tested** (`tmp-claude/caddy-pp-test/`): with `allow`, the header is
  *optional* from an allowed source, whatever the policy; `fallback_policy` only decides
  what a header from any other source does: `ignore` (chosen) parses and discards it
  and keeps the socket address, `skip`/`reject` break the connection, `use` believes it.
  `ignore` fails safe: a gateway missing from the list costs the client address, never
  the connection. `ignore` is the JSON zero value, so the running config omits it.
- **Allow list** = the backend's `DNS_GATEWAY_IPS` (published as `gatewayIps` in
  `/router/api/version`; staging checked: the gateway's egress IP is that address) + the
  tunnel container's address on `pcs` (the gateway's tunnel path arrives through its
  relay), looked up by name at each tick. The same list is the server's
  `trusted_proxies`, so terminated dash-form requests keep the X-Forwarded-For the
  gateway sets; from anyone else X-Forwarded-For is replaced.
- **Where:** mesh-router-caddy's entrypoint writes `/data/mesh-proxy.caddy` (a
  `servers :443` block) and the Caddyfile's global options import it by **glob**
  (`import /data/mesh-proxy*.caddy`): an image that does not write it yet only logs "No
  files matching import glob pattern", where a plain import would make caddy-docker-proxy
  drop the block.
- **Rollout, per box:** the box reports `PUT /hop/v1/proxy-protocol/:userid/:sig
  {enabled}` from its *running* config (admin API `listener_wrappers`), on change and every
  30 min; the backend keeps it 2 h (`hop:proxy:<uid>`) and `/resolve/v2` says
  `proxyProtocol: true`. The gateway sends the header only to such boxes, so no fleet-wide
  wait, and a box rolled back to an older Caddy drops out within 2 h. Tested: new image +
  old Caddyfile reports `false`; old image 1.4.3 + new Caddyfile serves normally.
- **Gateway side waits for `stream_realip`** (below): without it, the header the gateway
  would send carries Traefik's address, not the client's.
- **Box Caddy `trusted_proxies_strict`** (caddy 1.4.5): the gateway *appends* the client to
  X-Forwarded-For, and without strict Caddy takes the *leftmost* value from a trusted
  proxy, which the client controls. Tested: `X-Forwarded-For: 6.6.6.6, 203.0.113.9` from a
  trusted source gives `client_ip` 6.6.6.6 without strict, 203.0.113.9 with it.

**Gateway side built 2026-10-28 (option A, user decision), local test only:** the image
rebuilds nginx from the same OpenResty 1.29.2.5 sources and configure line with
`--with-stream_realip_module` (43 s build; only the binary is copied, linked to the image's
own OpenSSL 3.5.6 / PCRE2 / LuaJIT). The front trusts `GATEWAY_TLS_REALIP_FROM` (default
the private ranges) and sends `proxy_protocol on` to everything; `proxy_protocol` is per
server, not per connection, so a box without `proxyProtocol` goes through a strip relay
(a second stream server on a unix socket, `listen … proxy_protocol`, same SNI decision)
that ends the header. The HTTP TLS server listens with `proxy_protocol` and
`real_ip_header proxy_protocol`. Rejected: parsing the PROXY header and ClientHello in Lua
(two hand-written binary parsers, a different mode once the gateway is its own edge);
moving the split into Traefik (naming rules in Traefik, passthrough still unsolved).
Local harness (`tmp-claude/gateway-realip-test/`), "Traefik" sending PROXY for
203.0.113.9: box with the report → `remote=203.0.113.9` on dot name and apex; box without
→ unchanged (gateway address) through the relay; terminated → `X-Real-IP 203.0.113.9`,
`X-Forwarded-For` appended after a client-supplied value; header from an untrusted source →
its socket address.

**Staging 2026-10-28** (nasselle gateway `mesh-router-gateway:realip-local`, backup
`gateway/docker-compose.yml.bak-2026-10-28-realip`; wisera Caddy
`mesh-router-caddy:1.4.5-strict-local` + template Caddyfile, backups
`*.bak-2026-10-28-pp`, reverted by its 03:00 self-check to template main = caddy 1.4.4):
wisera reported `proxyProtocol: true` ~80 s after the switch. A whoami app on wisera saw
the client (88.187.147.189) on the dot name through the gateway (before: the gateway's
151.115.96.14), `X-Real-Ip` = client on the dash name over the agent route and the routed
tunnel (1.6.1 sent `unix:`), demostaging1/2 (no report) unchanged through the strip relay,
0 errors in the gateway log.

**X-Forwarded-For: append until the cutoff** (`GATEWAY_FORWARDED_FOR`, default `append`).
Replacing it with the gateway's own view loses the client on every Cloudflare → gateway
request (forced gateway, all NAT boxes): the Worker puts the client in X-Forwarded-For, and
the gateway sees only the Cloudflare edge. Appending keeps that, at the price of a
client-chosen leftmost value on requests that reach the gateway directly (today only by
`--resolve`). The box's Caddy is unaffected either way (`trusted_proxies_strict`).
**Cutoff runbook: set `GATEWAY_FORWARDED_FOR=replace`** once no request comes through
Cloudflare.

**Built 2026-10-27 (step 4), staging.** The gateway's TLS port is an OpenResty `stream`
server (`sni_router.lua`); the HTTP TLS server moved to a local unix socket behind it.
Passthrough needs a real user (the label resolves) and a TLS-capable route, so
`gateway.entrypoint.<zone>` (the Worker's fallback host, two labels) and unknown names
are terminated. OpenResty has no `stream_realip` module, so terminated connections
reach the HTTP server without a client address (behind Cloudflare it was the edge's
anyway): **to solve before the cutoff**, when dash names reach the gateway directly
(custom OpenResty build with `stream_realip`, or the split moved into Traefik). The box's
Caddy has no `trusted_proxies`, so apps behind the gateway already saw the gateway as
client: passthrough without PROXY to the box loses nothing; PROXY to the box is a later
improvement. Verified on wisera: through the gateway, its dot names and apex present the
box's own certificates (same SHA-256 as a direct connection; before: the gateway's own
per-user certificate), over the public IP and over the tunnel. Per-user issuance turned
off on the staging backend (`GATEWAY_ACME_DIRECTORY` commented out), wisera's gateway
certificate revoked (reason superseded) and deleted, `/gateway/certs` empty. The
`GatewayCerts` / `certs.lua` / `certlist.lua` code was removed in step 6 (backend 2.0.43,
gateway 1.6.0); only the `acme-client` dependency stays, for the gateway's `*.<zone>` (§6).

## 4. Gateway → box hop identity: `<label>.box.<zone>`

On the terminated path the gateway re-encrypts to the box. Today it sends SNI
`<ip-dashed>.ip.<zone>` and verifies against the system bundle with the mesh CA appended,
and every box's cert0 carries `*.<zone>`, so any box's certificate verifies for any
name. Trust really comes from the route (an IP from a signed registration), and that
stays the model, but two cases slip through:

- **recycled IP**: a stale route for user A pointing at an IP now held by box B (pool VM
  reuse, zombie PCS) verifies against B's certificate, and B receives A's traffic until
  the route expires;
- **tunnel routes** have no `<ip>.ip.<zone>` name to verify.

So:

- cert0 gains the SAN **`<label>.box.<zone>`**, a name that never exists in public DNS;
- the gateway sets `proxy_ssl_name <label>.box.<zone>` for box routes and verifies
  against the **mesh CA only** (separate trust file; the mesh CA stops being appended
  to the system bundle);
- once every gateway sends it, cert0 drops `*.<zone>` and `*.nip.io` and keeps
  `<label>.box.<zone>`, `*.ip.<zone>` (user-facing break-glass names) and the IP SAN.

The same hop then works over an IP route and over the tunnel, and a recycled IP fails
closed. `box` joins the reserved labels.

Compatibility: adding the SAN is additive; switching the gateway's SNI needs every box
re-issued (cert0 renewal, or a forced re-issue); dropping `*.<zone>` comes last, after the
non-delegated root `<domain>` (still `import gateway_tls`) is checked against it.

**Built 2026-10-27 (step 2), staging:** the backend signs every cert0 with
`<label>.box.<zone>` and records it (`cert:hop:<uid>`, until the certificate expires);
`/resolve/v2` returns `hopName` only while that record exists, and the gateway uses it as
SNI for agent and tunnel routes, falling back to the previous SNI otherwise. cert0 lives
72 h and the agent renews it at 36 h, so every live box carries the name within 36 h of
the backend deploy. Verified on wisera after a forced re-issue: Caddy serves cert0 for the
hop name, a capture of the gateway's handshakes shows only `wisera.box.inojob.com`, agent
and routed tunnel paths answer. *Since backend 2.0.47 (2026-10-28) the record and
`hopName` are gone: gateway 1.6+ always sends the hop name, so only the SAN remains.*

**Mesh-CA-only trust is deferred to step 6.** nginx takes one
`proxy_ssl_trusted_certificate` per location, and while some boxes are still reached
with the old SNI (host name, possibly answered with a Let's Encrypt certificate on a
delegated box), the gateway needs the system bundle too. Once every box has a hop name,
step 6 switches the bundle to the mesh CA alone in the same release that drops `*.<zone>`
from cert0.

## 5. Tunnel: network layer, not HTTP

Today a tunnel route is `http`: the gateway speaks HTTP to the tunnel entrance, TLS
already ended on the gateway. In 1.1 the box's WireGuard address becomes routable from
the gateway (the gateway already sits next to the tunnel provider on `mesh-internal`),
and a tunnel route is registered as `https://<wg-ip>:443`, the same shape as an IP route:

- passthrough (§3) works for NAT boxes: they get their certificate by DNS-01 without any
  inbound port, so their dot names end TLS on the box too;
- the tunnel stops being HTTP-aware (the `source == "tunnel"` → `http` special case in
  `resolver.lua` goes);
- the backend can probe a NAT box's certificate over the same path (today it only
  probes `publicIp:443`).

### Today (read 2026-10-27, staging)

```
gateway (TLS ends) ─HTTP─► provider nginx :80 (172.30.0.3)
                           Host → /api/get_ip → http://<peer wg ip>:80
                       ─HTTP over WireGuard─► requester nginx :80 (tunnel container on the box)
                           X-Forwarded-Proto https → https://caddy:443 (proxy_ssl_verify off)
                                              http  → http://caddy:80
```

- Three HTTP hops, two nginx proxies, both parsing Host, headers, WebSocket upgrades and
  body limits (`client_max_body_size 20G`). The box-side requester forwards the client's
  `X-Real-IP` / `X-Forwarded-For` as received.
- Addressing: the provider is `10.78.0.1` in `10.78.0.0/16` (staging), each box gets a
  `/32`; the provider pins each peer to its `/32`, but gives every box
  `AllowedIPs = 10.78.0.0/16`. The WireGuard endpoint on the box is the tunnel
  container, not Caddy.
- **Forwarding on the provider is wide open:** `FORWARD` policy `ACCEPT`,
  `-i wg0 -j ACCEPT`, `-o wg0 -j ACCEPT`, and `MASQUERADE` for `10.78.0.0/16` out of
  `eth0`, which is `mesh-internal` (backend, gateway and the backend's Redis, which has no
  password on staging). The provider container is also on `webtraefik`. A box owner who
  adds a route through their WireGuard interface can, by these rules, reach
  `mesh-internal` and the other boxes. Not tested; prod not checked. To fix whatever 1.1
  decides below.

### Decision (2026-10-27): routed tunnel (option A), staging first

The gateway routes the WireGuard subnet through the tunnel container and speaks TLS to
the box's WireGuard address on `:443`; the box's tunnel container relays that TCP stream
to Caddy unchanged. Rejected: a TCP relay with SNI parsing in the provider (option B),
since it keeps name parsing in the tunnel.

**Zero host modification, verified on staging 2026-10-27** (Docker 28.3.2,
`bridge-nf-call-iptables=1`): a throwaway container on `mesh-internal` with
`ip route add 10.78.0.0/16 via 172.30.0.3`, plus one temporary
`MASQUERADE -o wg0` inside the tunnel container, reached wisera's tunnel endpoint
`10.78.0.6:80` (HTTP 308 from its Caddy). Everything happens inside container network
namespaces; the host only bridges the frames.

What changes, and where:

| Where | Change |
|---|---|
| **Host** | Nothing |
| Server compose, gateway | `cap_add: NET_ADMIN` (its own namespace only), env with the WireGuard subnet and the tunnel container's IP |
| Server compose, tunnel | env with the gateway IP(s) allowed to forward (already has `NET_ADMIN` + `ip_forward=1`) |
| mesh-router-tunnel, provider | Firewall from code after `wg-quick up` (the persisted `wg0.conf` keeps its creation-time `PostUp`, so strip `PostUp`/`PostDown` from it at start): `FORWARD` drop by default, established/related only, gateway → `wg0` tcp/443 allowed, `MASQUERADE -o wg0` for that traffic only, no masquerade out of `eth0`, `INPUT` from `wg0` established only. Peers get `AllowedIPs = <provider>/32` |
| mesh-router-tunnel, requester | `stream` listener `:443` → `caddy:443`, raw TCP; registers its WireGuard IP as `tunnelIp` on its tunnel route |
| mesh-router-backend | accept and return the optional `tunnelIp` route field (the route whitelist drops unknown fields today) |
| mesh-router-gateway | entrypoint adds the subnet route when configured; `resolver.lua` uses `https://<tunnelIp>:443` (SNI = host, verify on) when the route has a `tunnelIp` and routing is configured, the legacy HTTP path otherwise |
| mesh-router-template-root | tunnel image pin |

Compatibility: an old box keeps the legacy HTTP path (the provider's nginx runs inside
the tunnel container, so the firewall does not touch it); an old gateway ignores
`tunnelIp`. The provider security fix ships on its own first.

NAT boxes are probed **through the gateway** (decided 2026-10-28): a box with no public IP
gets the same two handshakes against the first `DNS_GATEWAY_IPS` address, which passes
the dot name and the apex through to the box over its tunnel; the state says
`via: gateway` and keeps `publicIp: null`, so the answer rule still answers the gateway.
It feeds `mesh-cli dns status` and the readiness check before a delegation; no route or
capability in the backend. Checked on staging: from the backend container, wisera through
151.115.96.14 shows its own Let's Encrypt certificates (same fingerprints as direct), a
non-delegated box the mesh CA.

### Staging record (2026-10-27)

- Hole confirmed before the fix: from wisera, widening its own `allowed-ips` gave
  `+PONG` from the backend's Redis (`172.30.0.4:6379`) through the tunnel.
- Provider `mesh-router-tunnel:1.4.0-routed-local` with `TUNNEL_FORWARD_FROM=172.30.0.2`:
  hooks stripped from the persisted `wg0.conf`, `MESH_FWD` / `MESH_IN` / `MESH_NAT`
  chains, 25 peers. After: box → Redis, box → provider API, box → box all blocked;
  provider ping and the legacy HTTP path still work.
- Backend `mesh-router-backend:2.0.37-tunnelip-local` (v2.0.37 + `tunnelIp`), gateway
  `mesh-router-gateway:1.3.1-routed-local` (`NET_ADMIN`, `TUNNEL_SUBNET=10.78.0.0/16`,
  `TUNNEL_VIA=172.30.0.3`; the temporary `entrypoint.sh` bind mount is commented out, the
  image carries the same change).
- wisera on the new tunnel image (mesh `docker-compose.yml` edited, reverted by the 03:00
  self-check): `allowed-ips 10.78.0.1/32`, inbound filter on `wg_inojobcom`, `:443` relay,
  route with `tunnelIp 10.78.0.6`. Forced tunnel on three names:
  `cf-worker,gateway,tunnel-routed,pcs`, a 20 MB POST passes. WebSocket not checked
  (every reachable app is behind the login gate).
- Backups: `*.bak-2026-10-27-fw` (tunnel compose + `wg/wg0.conf`),
  `*.bak-2026-10-27-tunnelip` (backend, gateway), wisera
  `mesh/docker-compose.yml.bak-2026-10-27-routed`.

## 6. The gateway's own certificate: `*.<zone>`

> **Deferred to the cutoff (decided 2026-10-27).** A `_acme-challenge.<zone>` CNAME in
> Cloudflare would sit where Cloudflare's Universal SSL validates its own `*.<zone>` edge
> certificate (TXT records it adds itself; a CNAME excludes other records at that name),
> so the edge certificate every dash name depends on could fail to renew, silently, weeks
> later. Before the cutoff the gateway's certificate only matters behind Cloudflare
> ("Full (strict)"), and nothing else in 1.1 needs it. At the cutoff the zone is ours: the
> backend writes `_acme-challenge.<zone>` TXT directly, no CNAME, no `acme.` zone. The
> CNAME design below is kept for the record.

One Let's Encrypt certificate for `*.<zone>`, issued by the backend by DNS-01 (it
replaces the per-user `GatewayCerts` orders; the machinery stays). While Cloudflare still
holds the zone, the challenge is delegated with one static record:

```
_acme-challenge.<zone>  CNAME  gw.acme.<zone>     (Cloudflare now, static zone file later)
acme.<zone>             NS     ns1, ns2           (a zone on our hidden primary, like ip.)
```

The backend writes the TXT at `gw.acme.<zone>`; Let's Encrypt follows the CNAME. Works
before the cutoff and survives it unchanged. `acme` joins the reserved labels.

Side benefit before the cutoff: the gateway's origin certificate becomes valid for every
dash name, so the Cloudflare zone can move from "Full" to **"Full (strict)"** (apex
`<zone>` excluded: Traefik serves it with its own routers).

The per-user gateway certificates already issued (staging: wisera) are **revoked** once
passthrough is live, and their Redis entries deleted.

## 7. What the user can verify

The claim, stated precisely: **for a dot name, no certificate Yundera holds is valid.**
The gateway's `*.<zone>` matches one label only, so it cannot be presented for
`immich.john.nsl.sh`. Reading that traffic would need a new certificate for a name
under `john.<zone>`, and that is both restricted and public:

- **CAA (tried in 1.1).** The user zone carries
  `<user>.<zone> CAA 0 issue "letsencrypt.org; accounturi=<box account>"` and the same
  `issuewild`. Let's Encrypt then refuses to issue for the user's names to any ACME
  account but the box's. The box reports its account URI through a signed endpoint (same
  credential as the acme-dns API); the backend writes the record. Yundera owns the zone and
  could rewrite the record, but that is a deliberate, logged change, visible in public DNS.
- **Certificate Transparency.** Chrome, Safari and Firefox refuse a certificate without
  CT proofs, so any certificate usable against a browser is in the public logs, where
  anyone can look up the certificates issued for `<user>.<zone>` and below.
- **Per request, in the browser.** JavaScript cannot read the TLS certificate of its own
  page, but the browser's certificate viewer shows it: a dot name presents the box's
  `*.<user>.<zone>` (the box's own key), a dash name presents the gateway's `*.<zone>`.
  The user sees the certificate, and which side holds its key, switch with the mode.

> **Side note (decided 2026-10-27): no transparency feature to build.** What the browser
> shows per request is enough. The transparency comes from the architecture itself:
> one key per name, dot names never terminated on the path. No fingerprint display, no
> CT watcher in the box UI.

Limits, to say as plainly in the UI:

- **dash names terminate at the gateway** by design: Yundera can read that traffic;
- **the user apex** is matched by the gateway's `*.<zone>`: it is passed through by
  policy, not provably (cookie note: with `<zone>` on the PSL, a cookie set for
  `Domain=<user>.<zone>` reaches every dot app; AppShield and Authelia set host-only
  cookies);
- **the network path is not the software supplier.** On a Yundera-managed box, Yundera
  ships the code that runs it (template updates, Maison, the admin app). The guarantee is
  that nothing on the path (gateway, tunnel, DNS) can read the traffic, not that the
  vendor of the box software could not.

CAA as built (step 5, staging 2026-10-27):

- **Box (mesh-router-caddy zone watcher).** While the zone is delegated, the box reads the
  Let's Encrypt account URIs in Caddy's storage (`acme[-staging]-v02…/users/*/*.json`,
  status valid: one per email it ever used, plus the staging account Caddy creates for a
  test issuance after a failure) and sends them to `PUT /dns/v1/caa/:userid/:sig`
  (box signature, as acme-dns) when the list changes, and once a day. **Never an empty
  list**: a rebuilt box with fresh storage would otherwise remove the CAA, and the
  restriction with it, until its first order. Removing the CAA is deliberate (`[]`).
- **Backend.** `dns.caaAccounts` on the user's `nsl-router` document (at most 4 Let's
  Encrypt URIs, production or staging); the user zone gets
  `<user>.<zone> CAA 0 issue|issuewild "letsencrypt.org; accounturi=<uri>"` per account,
  TTL 300. No account = no CAA RRset. The apex CAA is managed like the A/NS/TXT sets.
- **Issuers.** The DNS-01 policy (`tls { dns acmedns … }`) has one issuer, Let's Encrypt:
  no ZeroSSL fallback for the zone, so the CAA names `letsencrypt.org` only. The sslip.io
  names keep Caddy's defaults; they are outside the user zone.
- **Rebuild, measured on wisera.** Accounts and zone certificates set aside, Caddy
  restarted: new account, both orders refused (`urn:ietf:params:acme:error:caa`, CAA
  record prevents issuance); the next watcher tick (≤ 120 s) reported the new account;
  Caddy's retry obtained both certificates. 14:56:51 → 15:00:15 UTC, ~4 min including the
  passthrough list catching up. On a real rebuild the box has no certificate then anyway.
- **Not covered.** The record is Yundera's to rewrite (owner of the zone): a change is
  public in DNS and logged (`[caa]` in the backend). A box still on mesh-router-caddy <
  the CAA release reports nothing: no CAA, as before.
- **No CAA at `<zone>` before the cutoff**: it would also restrict Cloudflare's own edge
  certificates for dash names. User zones are safe (Cloudflare never issues below one
  level).

## 8. Work by component

| Component | Work |
|---|---|
| mesh-router-gateway | `stream` front with `ssl_preread` and the SNI rule (§3); passthrough with PROXY v2 to the box; terminate listener behind it; `certs.lua` serves `*.<zone>` only; box hop `proxy_ssl_name <label>.box.<zone>` + mesh-CA-only trust; tunnel routes as `https` |
| mesh-router-backend | `*.<zone>` via `acme.<zone>`; drop per-user `GatewayCerts`, revoke issued ones; cert0 SAN `<label>.box.<zone>`, later drop `*.<zone>` / `*.nip.io`; CAA endpoint + record in user zones; probe over the tunnel; reserved labels `box`, `acme` |
| mesh-router-tunnel + agent | box WireGuard address routable from the gateway; tunnel route registered as `https://<wg-ip>:443` |
| mesh-router-caddy | `proxy_protocol` listener wrapper restricted to gateway addresses; report the ACME account URI |
| Ops | Cloudflare `_acme-challenge.<zone>` CNAME + `acme` NS (staging first); zone to "Full (strict)" |

## 9. Order (staging first, wisera as test user)

1. **Gateway `*.<zone>`** (§6): **deferred to the cutoff**, TXT written in our own zone.
2. **Hop identity, additive** (§4): SAN on cert0, gateway sends `<label>.box.<zone>` with
   mesh-CA-only trust.
3. **Tunnel at the network layer** (§5), after the study.
4. **SNI router + passthrough** (§3) with PROXY v2 to the box; then remove per-user
   gateway certificates and revoke wisera's.
5. **CAA** on wisera (§7), including a rebuild-style account change. **Done on staging
   2026-10-27.**
6. Drop `*.<zone>` / `*.nip.io` from cert0, mesh-CA-only trust on the hop, per-user
   gateway certificates removed (backend `GatewayCerts`, `/gateway/cert[s]`; gateway
   `certs.lua`, `certlist.lua`). **Built 2026-10-27, staging partly** (below).

Step 6 rollout order (each environment):

1. **Backend first, any time.** A cert0 without `*.<zone>` only comes from the new
   backend, which also notes the hop name (`cert:hop:<uid>`, `hopName` in `/resolve/v2`):
   gateway 1.5 then already connects with SNI `<label>.box.<zone>`. Staging 2026-10-27:
   wisera's cert0 reissued (`*.ip.inojob.com`, `wisera.box.inojob.com`, IP), gateway,
   routed tunnel and direct paths unchanged, no ACME attempt by Caddy for dash names
   (they keep cert0 by tag). `*.ip.<zone>` stays: deployment config (`CERT_EXTRA_SANS`)
   for the Worker's IP-name path, not a user's name.
2. **Gateway 1.6 once every live box holds a hop name**: it always sends
   `<label>.box.<zone>` and trusts the mesh CA only, so a box whose cert0 predates
   backend 2.0.40 gets a 502 ("certificate does not match <label>.box.<zone>"; seen on a
   side gateway against demostaging2). cert0 lives 72 h and renews at 36 h: wait until
   `cert:hop:*` covers every user with routes (`routes:<uid>:*` in Redis), at the latest
   72 h after the backend that adds the SAN (2.0.40: 2026-10-27 on both environments).
   Done: staging 2026-10-27, prod 2026-10-28 (29/30, the one box left a nip.io box with
   no `IP_ZONE`). Backend 2.0.47 then dropped `cert:hop:*`, `hopName` and `dns hops`.

Prod follows step by step once staging holds; no prod user is delegated yet, so steps 1,
2 and 4 change nothing visible there until the first pilot.

## 10. Open questions

- ~~Backend probe of NAT boxes~~: through the gateway (§5, 2026-10-28).
- ~~Caddy `proxy_protocol` wrapper options on 2.11.4~~: `allow` + `fallback_policy ignore`
  (§3, 2026-10-28).
- ~~Client IP on terminated connections (§3)~~: OpenResty rebuilt with `stream_realip`
  (§3, 2026-10-28), staging test pending.
